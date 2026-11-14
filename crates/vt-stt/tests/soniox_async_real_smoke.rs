//! Opt-in real-provider smoke for the refine path: the engine's post-stop
//! model, Soniox's async file API, and the remote clean-up ZuTalk relies on.
//!
//! Sends only the public synthetic fixture (`say`-generated English). Prints
//! counts and the model id, never transcript text, ids or the key.

use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio_util::sync::CancellationToken;
use vt_stt::{
    soniox_async_list_remote_files, soniox_async_list_remote_transcriptions,
    soniox_async_transcribe_wav, SonioxAsyncArtifactObserver, SonioxAsyncRequest,
    SonioxRemoteEndpoint, CURRENT_NOTEBOOK_CAPTURE_ENGINE, SONIOX_ASYNC_POLL_INTERVAL,
};

fn load_api_key() -> Option<String> {
    std::env::var("SONIOX_API_KEY")
        .ok()
        .filter(|value| !value.trim().is_empty())
}

#[derive(Default)]
struct Journal {
    files: Mutex<Vec<String>>,
    transcriptions: Mutex<Vec<String>>,
    cleaned: Mutex<bool>,
}

impl SonioxAsyncArtifactObserver for Journal {
    fn remote_file_created(&self, remote_id: &str) {
        self.files.lock().unwrap().push(remote_id.to_string());
    }
    fn remote_transcription_created(&self, remote_id: &str) {
        self.transcriptions
            .lock()
            .unwrap()
            .push(remote_id.to_string());
    }
    fn remote_artifacts_cleaned(&self) {
        *self.cleaned.lock().unwrap() = true;
    }
}

#[tokio::test]
#[ignore = "requires an explicitly supplied real Soniox API key"]
async fn soniox_async_real_smoke_transcribes_and_leaves_nothing_behind() {
    let api_key = load_api_key().expect("SONIOX_API_KEY must be supplied through the environment");
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    let wav = std::fs::read(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("vt-audio/tests/fixtures/test_speech_16k_mono.wav"),
    )
    .expect("read public synthetic speech fixture");
    let reference = format!(
        "zutalk-async-smoke-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock")
            .as_millis()
    );
    let request = SonioxAsyncRequest {
        base_url: engine.async_api_base_url,
        api_key: &api_key,
        model: engine.post_stop_model_id,
        language_hints: vec!["en".to_string()],
        enable_language_identification: false,
        context_json: None,
        client_reference_id: Some(reference.clone()),
        overall_deadline: Duration::from_secs(180),
        poll_interval: SONIOX_ASYNC_POLL_INTERVAL,
    };
    let journal = Journal::default();
    let cancel = CancellationToken::new();

    let tokens = soniox_async_transcribe_wav(&request, wav, &cancel, Some(&journal))
        .await
        .unwrap_or_else(|error| panic!("async transcription failed: {error:?}"));

    assert!(!tokens.is_empty(), "the refine model returned no tokens");
    assert!(
        tokens.iter().any(|token| token.end_ms > token.start_ms),
        "refined tokens carry no timing"
    );
    assert_eq!(journal.files.lock().unwrap().len(), 1, "one upload");
    assert_eq!(
        journal.transcriptions.lock().unwrap().len(),
        1,
        "one transcription"
    );
    assert!(
        *journal.cleaned.lock().unwrap(),
        "remote file and transcription must be deleted before returning"
    );

    // Nothing tagged with this run is left on the provider.
    let endpoint = SonioxRemoteEndpoint {
        base_url: engine.async_api_base_url,
        api_key: &api_key,
    };
    let files = soniox_async_list_remote_files(&endpoint)
        .await
        .expect("list remote files");
    let transcriptions = soniox_async_list_remote_transcriptions(&endpoint)
        .await
        .expect("list remote transcriptions");
    let left = files
        .iter()
        .chain(transcriptions.iter())
        .filter(|entry| {
            entry.client_reference_id.as_deref() == Some(reference.as_str())
                || entry
                    .filename
                    .as_deref()
                    .is_some_and(|name| name.contains(&reference))
        })
        .count();
    assert_eq!(left, 0, "remote artifacts left behind");

    println!(
        "model={} tokens={} result=pass",
        engine.post_stop_model_id,
        tokens.len()
    );
}
