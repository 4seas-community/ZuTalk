//! Per-connection lane credentials supplied by the app.
//!
//! A saved personal key answers every lane from memory. A community
//! invitation cannot: its keys are single-use and expire within minutes, so
//! each WebSocket connection — first attempt and every reconnect — needs one
//! fetched at that moment from the invite service, which only the app can
//! reach.
//!
//! The foreign call is deliberately synchronous and must return immediately:
//! it only starts the fetch. The answer arrives later through
//! [`LaneCredentialBroker::fulfill`] or [`LaneCredentialBroker::fail`], so a
//! network round trip on the app side never blocks a Rust runtime thread.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::oneshot;
use vt_stt::{BoxedCredentialFuture, LaneCredentialSource, SttError};

/// How long a lane waits for the app to answer a credential request. Longer
/// than a normal round trip to the invite service, shorter than the stream's
/// own connect timeout budget so a silent app surfaces as a retryable failure
/// rather than a hung capture.
const CREDENTIAL_REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// Implemented by the app. Called when a lane is about to open a connection
/// and needs a credential for it.
#[uniffi::export(callback_interface)]
pub trait FfiLaneCredentialRequester: Send + Sync {
    /// Must return immediately. Start the fetch and answer by calling
    /// `fulfill_lane_credential` or `fail_lane_credential` with this id.
    fn on_lane_credential_requested(&self, request_id: String);
}

/// Routes credential requests to the app and matches answers back to the
/// lane that is waiting.
pub struct LaneCredentialBroker {
    requester: Arc<dyn FfiLaneCredentialRequester>,
    pending: Mutex<HashMap<String, oneshot::Sender<Result<String, SttError>>>>,
    next_id: Mutex<u64>,
    timeout: Duration,
}

impl LaneCredentialBroker {
    pub fn new(requester: Arc<dyn FfiLaneCredentialRequester>) -> Arc<Self> {
        Self::with_timeout(requester, CREDENTIAL_REQUEST_TIMEOUT)
    }

    pub fn with_timeout(
        requester: Arc<dyn FfiLaneCredentialRequester>,
        timeout: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            requester,
            pending: Mutex::new(HashMap::new()),
            next_id: Mutex::new(0),
            timeout,
        })
    }

    /// Hands a fetched key to the lane waiting on `request_id`. Unknown or
    /// already-answered ids are ignored: a late answer to a lane that gave up
    /// must not resurrect anything.
    pub fn fulfill(&self, request_id: &str, api_key: String) {
        if let Some(sender) = self.take(request_id) {
            let _ = sender.send(Ok(api_key));
        }
    }

    /// Reports that no key is coming. `terminal` distinguishes a refusal the
    /// stream must not retry (invitation spent, budget exhausted, token
    /// revoked) from a transient one it should ride out with its normal
    /// reconnect backoff.
    pub fn fail(&self, request_id: &str, message: String, terminal: bool) {
        if let Some(sender) = self.take(request_id) {
            let error = if terminal {
                SttError::AuthFailed { message }
            } else {
                SttError::ConnectionFailed(message)
            };
            let _ = sender.send(Err(error));
        }
    }

    fn take(&self, request_id: &str) -> Option<oneshot::Sender<Result<String, SttError>>> {
        self.pending.lock().unwrap().remove(request_id)
    }

    fn register(&self) -> (String, oneshot::Receiver<Result<String, SttError>>) {
        let request_id = {
            let mut next = self.next_id.lock().unwrap();
            *next += 1;
            format!("lane-credential-{next}")
        };
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(request_id.clone(), tx);
        (request_id, rx)
    }
}

impl LaneCredentialSource for LaneCredentialBroker {
    fn credential_for_connection(&self) -> BoxedCredentialFuture<'_> {
        let (request_id, receiver) = self.register();
        self.requester
            .on_lane_credential_requested(request_id.clone());
        Box::pin(async move {
            match tokio::time::timeout(self.timeout, receiver).await {
                Ok(Ok(result)) => result,
                // The app dropped the request without answering.
                Ok(Err(_)) => {
                    self.take(&request_id);
                    Err(SttError::ConnectionFailed(
                        "lane credential request was abandoned".to_string(),
                    ))
                }
                Err(_) => {
                    self.take(&request_id);
                    Err(SttError::ConnectionFailed(format!(
                        "lane credential request timed out after {}s",
                        self.timeout.as_secs()
                    )))
                }
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct RecordingRequester {
        seen: Arc<Mutex<Vec<String>>>,
        calls: Arc<AtomicUsize>,
    }

    impl FfiLaneCredentialRequester for RecordingRequester {
        fn on_lane_credential_requested(&self, request_id: String) {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.seen.lock().unwrap().push(request_id);
        }
    }

    fn broker(timeout: Duration) -> (Arc<LaneCredentialBroker>, Arc<Mutex<Vec<String>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let requester = Arc::new(RecordingRequester {
            seen: seen.clone(),
            calls: Arc::new(AtomicUsize::new(0)),
        });
        (LaneCredentialBroker::with_timeout(requester, timeout), seen)
    }

    #[tokio::test]
    async fn each_request_gets_its_own_id_and_answer() {
        let (broker, seen) = broker(Duration::from_secs(5));

        // Two lanes ask concurrently; each must receive its own key.
        let first = broker.credential_for_connection();
        let second = broker.credential_for_connection();
        let ids = seen.lock().unwrap().clone();
        assert_eq!(ids.len(), 2);
        assert_ne!(ids[0], ids[1]);

        broker.fulfill(&ids[0], "key-one".to_string());
        broker.fulfill(&ids[1], "key-two".to_string());
        assert_eq!(first.await.unwrap(), "key-one");
        assert_eq!(second.await.unwrap(), "key-two");
    }

    #[tokio::test]
    async fn a_refusal_is_terminal_and_an_outage_is_not() {
        let (broker, seen) = broker(Duration::from_secs(5));

        let refused = broker.credential_for_connection();
        let id = seen.lock().unwrap().last().unwrap().clone();
        broker.fail(&id, "invitation spent".to_string(), true);
        let error = refused.await.unwrap_err();
        assert!(error.is_auth_error(), "expected terminal, got {error:?}");

        let transient = broker.credential_for_connection();
        let id = seen.lock().unwrap().last().unwrap().clone();
        broker.fail(&id, "invite service unreachable".to_string(), false);
        let error = transient.await.unwrap_err();
        assert!(
            !error.is_auth_error(),
            "a service outage must stay retryable, got {error:?}"
        );
    }

    #[tokio::test]
    async fn a_silent_app_times_out_without_blocking_forever() {
        let (broker, _seen) = broker(Duration::from_millis(50));
        let error = broker.credential_for_connection().await.unwrap_err();
        assert!(
            !error.is_auth_error(),
            "a timeout must stay retryable so the stream can back off"
        );
        // The abandoned request is not left behind to leak.
        assert!(broker.pending.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_late_answer_to_an_abandoned_request_is_ignored() {
        let (broker, seen) = broker(Duration::from_millis(50));
        let error = broker.credential_for_connection().await.unwrap_err();
        assert!(!error.is_auth_error());
        let id = seen.lock().unwrap().last().unwrap().clone();
        // Answering after the lane gave up must be a no-op, not a panic.
        broker.fulfill(&id, "too-late".to_string());
        assert!(broker.pending.lock().unwrap().is_empty());
    }
}
