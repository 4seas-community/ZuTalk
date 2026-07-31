//! Soniox 异步文件 API 客户端集成测试。
//!
//! 用手写的最小 HTTP/1.1 mock server 验证:上传→创建→轮询→取回→删除
//! 的完整流程,以及"删除是成功前置条件"的留存收敛语义。

use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use vt_stt::{soniox_async_transcribe_wav, wrap_pcm_s16le_in_wav, SonioxAsyncRequest, SttError};

#[derive(Debug, Clone)]
struct RecordedRequest {
    method: String,
    path: String,
    authorization: Option<String>,
    body: Vec<u8>,
}

#[derive(Clone)]
struct MockPlan {
    /// 逐次轮询返回的状态 JSON 正文。超出序列后重复最后一个。
    status_bodies: Vec<String>,
    transcript_body: String,
    /// DELETE 全部返回 500(测试清理失败路径)。
    fail_deletes: bool,
}

impl Default for MockPlan {
    fn default() -> Self {
        Self {
            status_bodies: vec![
                r#"{"status":"processing"}"#.to_string(),
                r#"{"status":"completed"}"#.to_string(),
            ],
            transcript_body: r#"{"id":"tr-1","text":"hello world","tokens":[
                {"text":"hello","start_ms":0,"end_ms":400,"confidence":0.98,"language":"en"},
                {"text":" world","start_ms":400,"end_ms":900,"confidence":0.97,"language":"en"}
            ]}"#
            .to_string(),
            fail_deletes: false,
        }
    }
}

async fn start_mock_api(plan: MockPlan) -> (String, Arc<Mutex<Vec<RecordedRequest>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let requests: Arc<Mutex<Vec<RecordedRequest>>> = Arc::new(Mutex::new(Vec::new()));
    let recorded = requests.clone();

    tokio::spawn(async move {
        let mut status_index = 0usize;
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            // 每个连接可能承载多个 keep-alive 请求。
            loop {
                let Some(request) = read_http_request(&mut stream).await else {
                    break;
                };
                let (status_line, body) = respond(&plan, &request, &mut status_index);
                recorded.lock().await.push(request);
                let response = format!(
                    "HTTP/1.1 {status_line}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                );
                if stream.write_all(response.as_bytes()).await.is_err() {
                    break;
                }
            }
        }
    });

    (format!("http://127.0.0.1:{}", addr.port()), requests)
}

fn respond(
    plan: &MockPlan,
    request: &RecordedRequest,
    status_index: &mut usize,
) -> (&'static str, String) {
    match (request.method.as_str(), request.path.as_str()) {
        ("POST", "/v1/files") => ("201 Created", r#"{"id":"file-1"}"#.to_string()),
        ("POST", "/v1/transcriptions") => (
            "201 Created",
            r#"{"id":"tr-1","status":"queued"}"#.to_string(),
        ),
        ("GET", "/v1/transcriptions/tr-1") => {
            let body = plan
                .status_bodies
                .get(*status_index)
                .or(plan.status_bodies.last())
                .cloned()
                .unwrap_or_else(|| r#"{"status":"completed"}"#.to_string());
            *status_index += 1;
            ("200 OK", body)
        }
        ("GET", "/v1/transcriptions/tr-1/transcript") => ("200 OK", plan.transcript_body.clone()),
        ("DELETE", _) if plan.fail_deletes => (
            "500 Internal Server Error",
            r#"{"error_type":"internal"}"#.to_string(),
        ),
        ("DELETE", _) => ("200 OK", "{}".to_string()),
        _ => ("404 Not Found", r#"{"error_type":"not_found"}"#.to_string()),
    }
}

async fn read_http_request(stream: &mut tokio::net::TcpStream) -> Option<RecordedRequest> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(pos) = find_subslice(&buffer, b"\r\n\r\n") {
            break pos;
        }
        let read = stream.read(&mut chunk).await.ok()?;
        if read == 0 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..read]);
    };

    let head = String::from_utf8_lossy(&buffer[..header_end]).to_string();
    let mut lines = head.lines();
    let request_line = lines.next()?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();

    let mut content_length = 0usize;
    let mut authorization = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if name == "content-length" {
            content_length = value.parse().unwrap_or(0);
        } else if name == "authorization" {
            authorization = Some(value.to_string());
        }
    }

    let mut body = buffer[header_end + 4..].to_vec();
    while body.len() < content_length {
        let read = stream.read(&mut chunk).await.ok()?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..read]);
    }
    body.truncate(content_length);

    Some(RecordedRequest {
        method,
        path,
        authorization,
        body,
    })
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn request<'a>(base_url: &'a str) -> SonioxAsyncRequest<'a> {
    SonioxAsyncRequest {
        base_url,
        api_key: "test-api-key",
        model: "stt-async-v5",
        language_hints: vec!["en".to_string()],
        enable_language_identification: false,
        client_reference_id: Some("zulangue-task-1".to_string()),
        overall_deadline: Duration::from_secs(30),
        poll_interval: Duration::from_millis(10),
    }
}

fn methods_and_paths(requests: &[RecordedRequest]) -> Vec<(String, String)> {
    requests
        .iter()
        .map(|r| (r.method.clone(), r.path.clone()))
        .collect()
}

#[tokio::test]
async fn async_flow_uploads_transcribes_and_deletes_remote_artifacts() {
    let (base_url, requests) = start_mock_api(MockPlan::default()).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 3200], 16_000, 1);
    let cancel = CancellationToken::new();

    let tokens = soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, None)
        .await
        .unwrap();

    assert_eq!(tokens.len(), 2);
    assert_eq!(tokens[0].text, "hello");
    assert!(tokens[0].is_final, "async transcript tokens are final");
    assert_eq!(tokens[0].language, "en");
    assert_eq!(tokens[1].text, " world");

    let recorded = requests.lock().await;
    let calls = methods_and_paths(&recorded);
    assert_eq!(calls[0], ("POST".into(), "/v1/files".into()));
    assert_eq!(calls[1], ("POST".into(), "/v1/transcriptions".into()));
    // 转录任务先删,文件后删,两者都必须发生。
    assert_eq!(
        calls[calls.len() - 2],
        ("DELETE".into(), "/v1/transcriptions/tr-1".into())
    );
    assert_eq!(
        calls[calls.len() - 1],
        ("DELETE".into(), "/v1/files/file-1".into())
    );

    // 每个请求都必须带 bearer key。
    for record in recorded.iter() {
        assert_eq!(record.authorization.as_deref(), Some("Bearer test-api-key"));
    }

    // 上传体里必须是 WAV 内容(multipart 包着 RIFF 头)。
    assert!(
        find_subslice(&recorded[0].body, b"RIFF").is_some(),
        "upload must carry the WAV payload"
    );

    // 创建请求必须选定异步模型并引用上传的文件。
    let create: serde_json::Value = serde_json::from_slice(&recorded[1].body).unwrap();
    assert_eq!(create["model"], "stt-async-v5");
    assert_eq!(create["file_id"], "file-1");
    assert_eq!(create["language_hints"], serde_json::json!(["en"]));
    // 工件必须带稳定标签:文件名与 client_reference_id,供启动扫尾识别。
    assert_eq!(create["client_reference_id"], "zulangue-task-1");
    assert!(
        find_subslice(&recorded[0].body, b"zulangue-task-1.wav").is_some(),
        "upload filename must carry the artifact tag"
    );
}

#[derive(Default)]
struct RecordingObserver {
    events: std::sync::Mutex<Vec<String>>,
}

impl vt_stt::SonioxAsyncArtifactObserver for RecordingObserver {
    fn remote_file_created(&self, remote_id: &str) {
        self.events
            .lock()
            .unwrap()
            .push(format!("file:{remote_id}"));
    }
    fn remote_transcription_created(&self, remote_id: &str) {
        self.events
            .lock()
            .unwrap()
            .push(format!("transcription:{remote_id}"));
    }
    fn remote_artifacts_cleaned(&self) {
        self.events.lock().unwrap().push("cleaned".to_string());
    }
}

#[tokio::test]
async fn observer_sees_ids_before_use_and_cleanup_confirmation() {
    let (base_url, _requests) = start_mock_api(MockPlan::default()).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 320], 16_000, 1);
    let cancel = CancellationToken::new();
    let observer = RecordingObserver::default();

    soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, Some(&observer))
        .await
        .unwrap();

    assert_eq!(
        *observer.events.lock().unwrap(),
        vec!["file:file-1", "transcription:tr-1", "cleaned"]
    );
}

#[tokio::test]
async fn observer_never_reports_cleaned_when_deletes_fail() {
    let plan = MockPlan {
        fail_deletes: true,
        ..Default::default()
    };
    let (base_url, _requests) = start_mock_api(plan).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 320], 16_000, 1);
    let cancel = CancellationToken::new();
    let observer = RecordingObserver::default();

    let error = soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, Some(&observer))
        .await
        .unwrap_err();
    assert!(matches!(error, SttError::ApiError { status: 500, .. }));
    assert!(
        !observer
            .events
            .lock()
            .unwrap()
            .contains(&"cleaned".to_string()),
        "cleanup confirmation must only fire after remote deletion succeeded"
    );
}

#[tokio::test]
async fn provider_error_status_still_deletes_remote_artifacts() {
    let plan = MockPlan {
        status_bodies: vec![
            r#"{"status":"error","error_type":"audio_decode_failed","error_message":"secret detail"}"#
                .to_string(),
        ],
        ..Default::default()
    };
    let (base_url, requests) = start_mock_api(plan).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 320], 16_000, 1);
    let cancel = CancellationToken::new();

    let error = soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, None)
        .await
        .unwrap_err();
    assert!(matches!(error, SttError::TranscriptionFailed { .. }));

    let recorded = requests.lock().await;
    let calls = methods_and_paths(&recorded);
    assert!(
        calls.contains(&("DELETE".into(), "/v1/transcriptions/tr-1".into())),
        "failed transcription must still be deleted: {calls:?}"
    );
    assert!(
        calls.contains(&("DELETE".into(), "/v1/files/file-1".into())),
        "uploaded audio must still be deleted after provider failure: {calls:?}"
    );
}

#[tokio::test]
async fn transcript_without_remote_cleanup_is_not_a_success() {
    let plan = MockPlan {
        fail_deletes: true,
        ..Default::default()
    };
    let (base_url, requests) = start_mock_api(plan).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 320], 16_000, 1);
    let cancel = CancellationToken::new();

    let error = soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, None)
        .await
        .unwrap_err();
    assert!(
        matches!(error, SttError::ApiError { status: 500, .. }),
        "cleanup failure must fail the task even with the transcript in hand: {error:?}"
    );

    // 删除必须带重试(转录任务 3 次 + 文件 3 次)。
    let recorded = requests.lock().await;
    let delete_count = recorded.iter().filter(|r| r.method == "DELETE").count();
    assert_eq!(delete_count, 6, "each artifact delete must be retried");
}

#[tokio::test]
async fn cancellation_mid_poll_still_deletes_remote_artifacts() {
    let plan = MockPlan {
        // 永远 processing,让流程停在轮询,由 cancel 中断。
        status_bodies: vec![r#"{"status":"processing"}"#.to_string()],
        ..Default::default()
    };
    let (base_url, requests) = start_mock_api(plan).await;
    let wav = wrap_pcm_s16le_in_wav(&vec![0u8; 320], 16_000, 1);
    let cancel = CancellationToken::new();

    let canceller = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        canceller.cancel();
    });

    let error = soniox_async_transcribe_wav(&request(&base_url), wav, &cancel, None)
        .await
        .unwrap_err();
    assert!(matches!(error, SttError::Cancelled));

    let recorded = requests.lock().await;
    let calls = methods_and_paths(&recorded);
    assert!(
        calls.contains(&("DELETE".into(), "/v1/transcriptions/tr-1".into())),
        "cancelled transcription must still be deleted: {calls:?}"
    );
    assert!(
        calls.contains(&("DELETE".into(), "/v1/files/file-1".into())),
        "cancelled upload must still be deleted: {calls:?}"
    );
}

#[tokio::test]
async fn cancelled_before_start_makes_no_remote_requests() {
    let (base_url, requests) = start_mock_api(MockPlan::default()).await;
    let cancel = CancellationToken::new();
    cancel.cancel();

    let error = soniox_async_transcribe_wav(&request(&base_url), vec![0u8; 44], &cancel, None)
        .await
        .unwrap_err();
    assert!(matches!(error, SttError::Cancelled));
    assert!(requests.lock().await.is_empty());
}
