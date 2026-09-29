//! Cleaning up a marked passage on an invitation instead of a key.
//!
//! The invite service holds a DeepSeek key, and DeepSeek has no scoped
//! temporary keys: unlike capture, the service cannot hand this device a
//! credential of its own. So the passage goes to the service, which calls the
//! model and hands the text back. That is a second party the passage passes
//! through, which is why this route exists only when the service says it does
//! (the quota response carries the offer) and never replaces a key the
//! listener configured themselves.
//!
//! The service owns the instruction. What leaves here is the passage and the
//! reading language — the same text the key path sends as its user message —
//! and nothing that would let the endpoint be used as a general-purpose model.

use std::time::Duration;

use serde::Deserialize;

use crate::digest::user_prompt;
use crate::{describe_transport_failure, LanguageModelError, PassageDigestRequest};

/// The service refuses anything longer, so a passage past this is refused
/// here instead of travelling to be refused there. Mirrors
/// `DIGEST_MAX_PASSAGE_CHARS` in services/community-invite/server.py.
pub const INVITE_MAX_PASSAGE_CHARS: usize = 12_000;

/// Where an invitation's passage cleanup is reached, and on whose behalf.
#[derive(Clone, PartialEq, Eq)]
pub struct InviteDigestRoute {
    pub service_url: String,
    pub access_token: String,
    /// The model the service advertised when it offered cleanup. Recorded
    /// against a failure, and against a success whose answer did not say.
    pub model_id: String,
}

impl std::fmt::Debug for InviteDigestRoute {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The token spends someone's shared allowance; it has no business in
        // a log line, including one printed by a failed assertion.
        f.debug_struct("InviteDigestRoute")
            .field("service_url", &self.service_url)
            .field("access_token", &"<redacted>")
            .field("model_id", &self.model_id)
            .finish()
    }
}

/// A cleaned-up passage and the model the service says produced it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteDigest {
    pub text: String,
    pub model_id: String,
}

#[derive(Deserialize)]
struct DigestResponse {
    text: String,
    #[serde(default)]
    model: Option<String>,
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    error: Option<String>,
}

/// The passage as the service receives it.
pub fn invite_passage(request: &PassageDigestRequest) -> String {
    user_prompt(request).trim().to_string()
}

/// Sends one marked passage through the invite service and returns it legible.
///
/// Like `digest_passage`, this transmits user content, and everything about
/// whether it should happen is settled before control reaches here.
pub async fn digest_passage_via_invite(
    route: &InviteDigestRoute,
    request: &PassageDigestRequest,
) -> Result<InviteDigest, LanguageModelError> {
    let access_token = route.access_token.trim();
    if access_token.is_empty() {
        return Err(LanguageModelError::EmptyCredential);
    }
    let passage = invite_passage(request);
    if passage.chars().count() > INVITE_MAX_PASSAGE_CHARS {
        return Err(LanguageModelError::PassageTooLong);
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|error| LanguageModelError::NetworkUnavailable(error.to_string()))?;

    let response = client
        .post(format!(
            "{}/v1/passage-digest",
            route.service_url.trim_end_matches('/')
        ))
        .bearer_auth(access_token)
        .header("Cache-Control", "no-store")
        .json(&serde_json::json!({
            "target_language": request.target_language,
            "passage": passage,
        }))
        .send()
        .await
        .map_err(|error| {
            LanguageModelError::NetworkUnavailable(describe_transport_failure(&error))
        })?;

    let status = response.status().as_u16();
    if !(200..=299).contains(&status) {
        let code = response
            .json::<ErrorBody>()
            .await
            .ok()
            .and_then(|body| body.error);
        return Err(classify_invite_failure(status, code.as_deref()));
    }

    let parsed: DigestResponse = response.json().await.map_err(|error| {
        LanguageModelError::NetworkUnavailable(describe_transport_failure(&error))
    })?;
    let text = parsed.text.trim().to_string();
    if text.is_empty() {
        return Err(LanguageModelError::EmptyResponse);
    }
    Ok(InviteDigest {
        text,
        model_id: parsed
            .model
            .filter(|model| !model.trim().is_empty())
            .unwrap_or_else(|| route.model_id.clone()),
    })
}

/// The service's refusals, in the vocabulary the rest of the crate uses.
///
/// 401 is the invitation itself (removed, paused); the service never passes
/// its own upstream credential failures through as one. A spent daily
/// allowance and a busy upstream are both 429, told apart by the body.
pub(crate) fn classify_invite_failure(status: u16, code: Option<&str>) -> LanguageModelError {
    match status {
        401 | 403 => LanguageModelError::InvalidCredential,
        413 => LanguageModelError::PassageTooLong,
        429 if code == Some("digest_daily_limit") => LanguageModelError::QuotaExhausted,
        429 => LanguageModelError::RateLimited,
        status => LanguageModelError::ServiceUnavailable { status },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PassageLine;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn request(text: &str) -> PassageDigestRequest {
        PassageDigestRequest {
            lines: vec![PassageLine {
                speaker: None,
                source_language: "en".into(),
                source_text: text.into(),
                translated_text: None,
            }],
            target_language: "zh-Hans".into(),
        }
    }

    /// Answers exactly one request with `response`, and hands back what the
    /// client sent so the test can read it.
    async fn one_shot_service(response: String) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let handle = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut received = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let read = socket.read(&mut buffer).await.unwrap();
                received.extend_from_slice(&buffer[..read]);
                let text = String::from_utf8_lossy(&received);
                if let Some(header_end) = text.find("\r\n\r\n") {
                    let length = text[..header_end]
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if received.len() >= header_end + 4 + length {
                        break;
                    }
                }
                if read == 0 {
                    break;
                }
            }
            socket.write_all(response.as_bytes()).await.unwrap();
            socket.shutdown().await.ok();
            String::from_utf8_lossy(&received).into_owned()
        });
        (url, handle)
    }

    fn http(status: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    #[tokio::test]
    async fn the_passage_and_language_travel_with_the_invitation_and_nothing_else() {
        let (url, service) = one_shot_service(http(
            "200 OK",
            r#"{"text":"这才是问题的核心。","model":"deepseek-flash"}"#,
        ))
        .await;
        let route = InviteDigestRoute {
            service_url: format!("{url}/"),
            access_token: "invite-token".into(),
            model_id: "deepseek-flash".into(),
        };

        let digest = digest_passage_via_invite(&route, &request("and that is the crux"))
            .await
            .unwrap();

        assert_eq!(digest.text, "这才是问题的核心。");
        assert_eq!(digest.model_id, "deepseek-flash");
        let sent = service.await.unwrap();
        assert!(sent.starts_with("POST /v1/passage-digest "));
        assert!(sent
            .to_ascii_lowercase()
            .contains("authorization: bearer invite-token"));
        let body: serde_json::Value =
            serde_json::from_str(sent.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(
            body,
            serde_json::json!({
                "target_language": "zh-Hans",
                "passage": "and that is the crux",
            }),
            "no instruction, no session, no title — only the passage"
        );
    }

    #[tokio::test]
    async fn a_spent_daily_allowance_reads_as_quota_not_as_a_busy_service() {
        let (url, _service) = one_shot_service(http(
            "429 Too Many Requests",
            r#"{"error":"digest_daily_limit"}"#,
        ))
        .await;
        let route = InviteDigestRoute {
            service_url: url,
            access_token: "invite-token".into(),
            model_id: "deepseek-flash".into(),
        };
        let result = digest_passage_via_invite(&route, &request("and that is the crux")).await;
        assert!(matches!(result, Err(LanguageModelError::QuotaExhausted)));
    }

    #[test]
    fn service_refusals_map_to_what_the_listener_can_do() {
        assert!(matches!(
            classify_invite_failure(401, Some("unauthorized")),
            LanguageModelError::InvalidCredential
        ));
        assert!(matches!(
            classify_invite_failure(413, None),
            LanguageModelError::PassageTooLong
        ));
        assert!(matches!(
            classify_invite_failure(429, Some("rate_limited")),
            LanguageModelError::RateLimited
        ));
        assert!(matches!(
            classify_invite_failure(502, Some("upstream_unavailable")),
            LanguageModelError::ServiceUnavailable { status: 502 }
        ));
    }

    /// A passage the service would refuse must not leave the device only to
    /// be refused.
    #[tokio::test]
    async fn an_oversized_passage_is_refused_before_any_request() {
        let route = InviteDigestRoute {
            // Nothing listens here; reaching the network would fail differently.
            service_url: "http://127.0.0.1:9".into(),
            access_token: "invite-token".into(),
            model_id: "deepseek-flash".into(),
        };
        let long = "字".repeat(INVITE_MAX_PASSAGE_CHARS + 1);
        let result = digest_passage_via_invite(&route, &request(&long)).await;
        assert!(matches!(result, Err(LanguageModelError::PassageTooLong)));
    }

    #[tokio::test]
    async fn an_empty_token_never_becomes_a_request() {
        let route = InviteDigestRoute {
            service_url: "http://127.0.0.1:9".into(),
            access_token: "  ".into(),
            model_id: "deepseek-flash".into(),
        };
        let result = digest_passage_via_invite(&route, &request("and that is the crux")).await;
        assert!(matches!(result, Err(LanguageModelError::EmptyCredential)));
    }

    #[test]
    fn the_route_never_prints_its_token() {
        let route = InviteDigestRoute {
            service_url: "https://invite.example".into(),
            access_token: "secret-token".into(),
            model_id: "deepseek-flash".into(),
        };
        assert!(!format!("{route:?}").contains("secret-token"));
    }
}
