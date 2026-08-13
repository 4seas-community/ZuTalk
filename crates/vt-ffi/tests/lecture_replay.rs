//! Accelerated long-recording replay harness.
//!
//! Two opt-in measurements over one local media file, both on the real
//! Soniox-backed pipeline and both writing their verbatim transcript out for
//! inspection:
//!
//! * `replay_lecture_realtime_accelerated` decodes the file, streams it into a
//!   live Notebook capture at `ZULANGUE_REPLAY_SPEED`× wall clock, and drives
//!   the same `project_notebook_realtime_incremental` call Swift issues on
//!   every capture event. It records where wall-clock time goes: the push
//!   call the audio thread makes, the projection the UI queue makes, and how
//!   long a Final takes to come back from the provider.
//! * `transcribe_lecture_async_file_api` runs import + post-stop async file
//!   transcription end to end and times each stage against audio duration.
//!
//! Accelerating the feed compresses the local work into a shorter wall clock,
//! so a duty cycle measured at N× is an N× magnification of the real one. The
//! report states both.
//!
//! No personal path is compiled in: media, output directory, language, and
//! credential all come from the environment or the caller's own approved
//! local profile.
//!
//! The credential is read from `SONIOX_API_KEY`, from the private file named
//! by `ZULANGUE_SONIOX_KEY_FILE`, or from the profile at `ZULANGUE_DATA_DIR`.
//! It never reaches a command line or the report.
//!
//! ```text
//! ZULANGUE_REPLAY_MEDIA=/path/to/lecture.mp4 \
//! ZULANGUE_REPLAY_OUT=/path/to/output-dir \
//! ZULANGUE_SONIOX_KEY_FILE=/path/to/private-key-file \
//! ZULANGUE_REPLAY_SPEED=8 \
//! ZULANGUE_REPLAY_LANGUAGE=en \
//! cargo test --release -p vt-ffi --test lecture_replay -- --ignored --nocapture
//! ```
//!
//! `measure_local_import_cost` needs no credential and no network at all.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use tempfile::TempDir;
use vt_audio::{canonicalize_for_soniox, decode_file};
use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureLivePreview,
    FfiNotebookCaptureUtterance,
};
use vt_ffi::ZuTalkCore;

/// How long the capture callback may stay silent before the feed treats the
/// lane as dead. Comfortably longer than the stream's own 5-minute receive
/// idle timeout would need to fire and reconnect.
const LANE_SILENCE_ABORT_MS: f64 = 90_000.0;

/// One 100 ms block of canonical 16 kHz mono s16le audio.
const PCM_CHUNK_BYTES: usize = 3_200;
const PCM_BYTES_PER_MS: usize = 32;
const CHUNK_MS: u64 = (PCM_CHUNK_BYTES / PCM_BYTES_PER_MS) as u64;

// ============================================================================
// Environment
// ============================================================================

fn media_path() -> PathBuf {
    let raw = std::env::var("ZULANGUE_REPLAY_MEDIA")
        .expect("ZULANGUE_REPLAY_MEDIA must point at the media file to replay");
    let path = PathBuf::from(raw);
    assert!(path.is_file(), "replay media is not a file");
    path
}

fn output_dir() -> PathBuf {
    let dir = std::env::var_os("ZULANGUE_REPLAY_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    std::fs::create_dir_all(&dir).expect("create replay output directory");
    dir
}

/// Replay only the first N seconds. Absent or `0` replays the whole file.
fn replay_seconds() -> Option<u64> {
    std::env::var("ZULANGUE_REPLAY_SECONDS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
}

fn replay_speed() -> f64 {
    std::env::var("ZULANGUE_REPLAY_SPEED")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .filter(|value| *value >= 1.0 && value.is_finite())
        .unwrap_or(8.0)
}

/// How much unprocessed audio the provider may be holding before the feed
/// waits for it. The realtime endpoint decodes at roughly one times realtime
/// no matter how fast bytes arrive, so an unbounded accelerated feed just
/// builds a backlog until the lane times out. `0` disables the bound and
/// reproduces that failure deliberately.
fn max_provider_lag_ms() -> u64 {
    std::env::var("ZULANGUE_REPLAY_MAX_LAG_MS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(30_000)
}

/// Selected capture languages, comma separated. One language opens a single
/// transcription stream; three open a canonical stream plus one translation
/// stream per language, which is the configuration whose lanes fall behind.
/// Comparing the two on the same audio is how the cost of a lane is measured
/// rather than argued about.
fn replay_languages() -> Vec<String> {
    let raw = std::env::var("ZULANGUE_REPLAY_LANGUAGE").unwrap_or_else(|_| "en".to_string());
    let languages = raw
        .split(',')
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    assert!(
        !languages.is_empty() && languages.len() <= 3,
        "ZULANGUE_REPLAY_LANGUAGE takes 1..=3 comma-separated languages"
    );
    languages
}

#[derive(Deserialize)]
struct ProviderCredentialDocument {
    version: u32,
    credentials: HashMap<String, String>,
}

/// Reads the credential without ever putting it on a command line or in the
/// report. Three sources, in order:
///
/// 1. `SONIOX_API_KEY`.
/// 2. `ZULANGUE_SONIOX_KEY_FILE` — a private file holding only the key, so a
///    run can be started by someone who never types the key where it can be
///    echoed back.
/// 3. `ZULANGUE_DATA_DIR` — the Soniox credential the app itself saved in the
///    caller's approved local profile.
///
/// Both file forms must be owned by the current user and mode 0600.
fn soniox_api_key() -> String {
    if let Ok(key) = std::env::var("SONIOX_API_KEY") {
        let key = key.trim().to_string();
        if !key.is_empty() {
            return key;
        }
    }
    if let Some(path) = std::env::var_os("ZULANGUE_SONIOX_KEY_FILE").map(PathBuf::from) {
        assert_private_file(&path, "Soniox key file");
        let key = std::fs::read_to_string(&path)
            .expect("read Soniox key file")
            .trim()
            .to_string();
        assert!(!key.is_empty(), "Soniox key file is empty");
        return key;
    }
    let data_dir = std::env::var_os("ZULANGUE_DATA_DIR")
        .or_else(|| std::env::var_os("ZUTALK_DATA_DIR"))
        .map(PathBuf::from)
        .expect(
            "set SONIOX_API_KEY, ZULANGUE_SONIOX_KEY_FILE, \
             or ZULANGUE_DATA_DIR for the approved local profile",
        );
    let path = data_dir.join("Secrets/provider-credentials.json");
    assert_private_file(&path, "provider credential document");
    let document: ProviderCredentialDocument =
        serde_json::from_slice(&std::fs::read(&path).expect("read provider credential document"))
            .expect("decode provider credential document");
    assert_eq!(
        document.version, 1,
        "unsupported provider credential version"
    );
    document
        .credentials
        .get("soniox")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .expect("saved Soniox credential is missing")
}

/// A provider failure mid-replay is the thing most worth explaining, and the
/// only place the reason is spelled out is the crate's own tracing output.
fn init_tracing() {
    let filter = std::env::var("RUST_LOG")
        .unwrap_or_else(|_| "vt_stt=debug,vt_ffi=info,vt_pipeline=info".to_string());
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(true)
        .try_init();
}

/// The durable provider failure the capture recorded, if any. The FFI event
/// only carries a health enum; the reason lives on the run row.
fn persisted_provider_failure(data_dir: &Path, session_id: &str) -> Option<(String, String)> {
    let connection = rusqlite::Connection::open_with_flags(
        data_dir.join("zutalk.db"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()?;
    connection
        .query_row(
            "SELECT COALESCE(provider_error_type, ''), COALESCE(provider_request_id, '')
             FROM notebook_capture_runs WHERE session_id = ?1",
            [session_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .ok()
        .filter(|(error_type, _)| !error_type.is_empty())
}

fn assert_private_file(path: &Path, label: &str) {
    let metadata =
        std::fs::symlink_metadata(path).unwrap_or_else(|error| panic!("inspect {label}: {error}"));
    assert!(
        metadata.file_type().is_file(),
        "{label} must be a regular file"
    );
    assert_eq!(metadata.mode() & 0o777, 0o600, "{label} must be mode 0600");
    assert_eq!(
        metadata.uid(),
        unsafe { libc::geteuid() },
        "{label} owner mismatch"
    );
}

// ============================================================================
// Community invitation lane
// ============================================================================

/// The app's own invite flow, driven from the harness.
///
/// A redeemed invitation has no saved Soniox key: every lane asks the app for
/// a temporary one at connect time. Reproducing that here means the replay
/// exercises the credential path invited users actually run on, and it is the
/// only way to reach the realtime provider without a personal key.
///
/// Quota is counted in lane-seconds. Settlement reports **audio** seconds, not
/// wall-clock seconds: Soniox bills the master key for the audio it decoded,
/// and an accelerated replay decodes the full recording in a fraction of the
/// wall clock. Reporting wall clock would silently undercharge the community
/// pool by the speed factor.
struct InviteLane {
    base_url: String,
    token: String,
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
    session_id: Mutex<Option<String>>,
    lane_count: u32,
    key: Mutex<Option<(String, Instant)>>,
}

/// Soniox temporary keys live an hour; renew well before the edge so a
/// reconnect late in a long replay still gets a usable key.
const INVITE_KEY_RENEW_AFTER: Duration = Duration::from_secs(45 * 60);

#[derive(Deserialize)]
struct InviteTokenDocument {
    version: u32,
    access_token: String,
}

#[derive(Deserialize)]
struct InviteQuota {
    remaining_seconds: i64,
    used_seconds: i64,
    quota_seconds: i64,
}

#[derive(Deserialize)]
struct InviteRealtimeSession {
    session_id: String,
    reserved_seconds: i64,
    api_key: String,
}

#[derive(Deserialize)]
struct InviteRenewedKey {
    api_key: String,
}

impl InviteLane {
    /// `ZULANGUE_INVITE_TOKEN_FILE` points at the `community-invite.json` the
    /// app wrote when the invitation was redeemed.
    fn from_env(lane_count: u32) -> Option<Self> {
        let path = std::env::var_os("ZULANGUE_INVITE_TOKEN_FILE").map(PathBuf::from)?;
        assert_private_file(&path, "community invite token file");
        let document: InviteTokenDocument =
            serde_json::from_slice(&std::fs::read(&path).expect("read community invite token"))
                .expect("decode community invite token");
        assert_eq!(document.version, 1, "unsupported invite token version");
        let token = document.access_token.trim().to_string();
        assert!(!token.is_empty(), "community invite token is empty");
        Some(Self {
            base_url: std::env::var("ZULANGUE_INVITE_BASE_URL")
                .unwrap_or_else(|_| "https://zulangue-invite.exe.xyz".to_string()),
            token,
            runtime: tokio::runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .expect("build invite runtime"),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()
                .expect("build invite client"),
            session_id: Mutex::new(None),
            lane_count,
            key: Mutex::new(None),
        })
    }

    fn post<T: serde::de::DeserializeOwned>(&self, path: &str, body: serde_json::Value) -> T {
        let url = format!("{}{path}", self.base_url);
        self.runtime.block_on(async {
            let response = self
                .client
                .post(&url)
                .bearer_auth(&self.token)
                .json(&body)
                .send()
                .await
                .unwrap_or_else(|error| panic!("invite service {path}: {error}"));
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            assert!(
                status.is_success(),
                "invite service {path} -> {status}: {text}"
            );
            serde_json::from_str(&text)
                .unwrap_or_else(|error| panic!("decode invite service {path} response: {error}"))
        })
    }

    fn quota(&self) -> InviteQuota {
        let url = format!("{}/v1/quota", self.base_url);
        self.runtime.block_on(async {
            let response = self
                .client
                .get(&url)
                .bearer_auth(&self.token)
                .send()
                .await
                .expect("invite service quota");
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            assert!(status.is_success(), "invite quota -> {status}: {text}");
            serde_json::from_str(&text).expect("decode invite quota")
        })
    }

    /// Reserves lane-seconds and takes the first temporary key. The reservation
    /// also caps the WebSocket duration Soniox will allow, so it must cover the
    /// whole replay.
    fn reserve(&self, requested_seconds: i64) -> i64 {
        let session: InviteRealtimeSession = self.post(
            "/v1/realtime-session",
            serde_json::json!({
                "requested_seconds": requested_seconds,
                "lane_count": self.lane_count,
            }),
        );
        *self.session_id.lock().unwrap() = Some(session.session_id.clone());
        *self.key.lock().unwrap() = Some((session.api_key, Instant::now()));
        session.reserved_seconds
    }

    /// The key a lane should connect with right now.
    fn current_key(&self) -> String {
        let cached = self.key.lock().unwrap().clone();
        if let Some((key, minted)) = cached {
            if minted.elapsed() < INVITE_KEY_RENEW_AFTER {
                return key;
            }
        }
        let session_id = self
            .session_id
            .lock()
            .unwrap()
            .clone()
            .expect("invite realtime session must be reserved before a lane connects");
        let renewed: InviteRenewedKey = self.post(
            "/v1/realtime-session/renew-key",
            serde_json::json!({ "session_id": session_id }),
        );
        *self.key.lock().unwrap() = Some((renewed.api_key.clone(), Instant::now()));
        renewed.api_key
    }

    /// Charges the audio the provider actually decoded, then closes the
    /// reservation. Safe to call twice; the second call is a no-op.
    fn settle(&self, audio_seconds: i64) {
        let Some(session_id) = self.session_id.lock().unwrap().take() else {
            return;
        };
        let used = audio_seconds.max(0) * self.lane_count as i64;
        let url = format!("{}/v1/realtime-session/settle", self.base_url);
        let outcome = self.runtime.block_on(async {
            self.client
                .post(&url)
                .bearer_auth(&self.token)
                .json(&serde_json::json!({
                    "session_id": session_id,
                    "used_seconds": used,
                }))
                .send()
                .await
                .map(|response| response.status())
        });
        match outcome {
            Ok(status) if status.is_success() => {
                eprintln!("[invite] settled {used} lane-seconds")
            }
            Ok(status) => {
                eprintln!("[invite] SETTLE FAILED with {status}; reservation will expire")
            }
            Err(error) => eprintln!("[invite] SETTLE FAILED: {error}; reservation will expire"),
        }
    }
}

/// Closes the reservation on the way out, including when the replay panics.
/// An abandoned reservation holds community seconds hostage until the service
/// expires it, and only two may be open per invitation at a time.
///
/// Charges the greater of the audio the provider demonstrably decoded and the
/// wall-clock life of the lane. Charging the whole recording would bill the
/// pool for audio a dead lane never saw; charging only decoded audio would
/// undercount a lane that was live and idle.
struct InviteSettleGuard {
    lane: Arc<InviteLane>,
    recorder: Arc<Recorder>,
}

impl Drop for InviteSettleGuard {
    fn drop(&mut self) {
        let decoded_seconds = self.recorder.state.lock().unwrap().max_utterance_end_ms / 1_000;
        let lane_life_seconds = self.recorder.started.elapsed().as_secs();
        self.lane
            .settle(decoded_seconds.max(lane_life_seconds) as i64);
    }
}

/// Answers every lane credential request from the invitation. The foreign
/// call must return immediately, so the answer is delivered from a thread.
struct InviteLaneRequester {
    core: std::sync::Weak<ZuTalkCore>,
    lane: Arc<InviteLane>,
}

impl vt_ffi::lane_credential_api::FfiLaneCredentialRequester for InviteLaneRequester {
    fn on_lane_credential_requested(&self, request_id: String) {
        let core = self.core.clone();
        let lane = self.lane.clone();
        std::thread::spawn(move || {
            let Some(core) = core.upgrade() else {
                return;
            };
            let key = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| lane.current_key()));
            match key {
                Ok(key) => core.fulfill_lane_credential(request_id, key),
                Err(_) => core.fail_lane_credential(
                    request_id,
                    "invite service did not issue a lane key".to_string(),
                    false,
                ),
            }
        });
    }
}

// ============================================================================
// Audio
// ============================================================================

struct CanonicalAudio {
    s16le: Vec<u8>,
    decode: Duration,
    canonicalize: Duration,
    source_sample_rate: u32,
    source_channels: u16,
    source_samples: usize,
}

impl CanonicalAudio {
    fn duration_ms(&self) -> u64 {
        (self.s16le.len() / PCM_BYTES_PER_MS) as u64
    }
}

/// Decode with the app's own decoder, then run the app's own canonical
/// 16 kHz mono conversion — the exact bytes any Soniox path would receive.
fn canonical_audio(path: &Path, limit_seconds: Option<u64>) -> CanonicalAudio {
    let decode_started = Instant::now();
    let decoded = decode_file(path).expect("decode replay media");
    let decode = decode_started.elapsed();

    let source_sample_rate = decoded.sample_rate;
    let source_channels = decoded.channels;
    let mut samples = decoded.samples;
    let source_samples = samples.len();
    if let Some(seconds) = limit_seconds {
        let keep = (seconds as usize)
            .saturating_mul(source_sample_rate as usize)
            .saturating_mul(source_channels as usize);
        if keep < samples.len() {
            samples.truncate(keep);
        }
    }

    let canonicalize_started = Instant::now();
    let canonical = canonicalize_for_soniox(&samples, source_sample_rate, source_channels)
        .expect("canonicalize replay media");
    drop(samples);
    let mut s16le = Vec::with_capacity(canonical.len() * 2);
    for sample in canonical {
        let value = if sample <= -1.0 {
            i16::MIN
        } else {
            (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
        };
        s16le.extend_from_slice(&value.to_le_bytes());
    }
    let canonicalize = canonicalize_started.elapsed();

    CanonicalAudio {
        s16le,
        decode,
        canonicalize,
        source_sample_rate,
        source_channels,
        source_samples,
    }
}

// ============================================================================
// Statistics
// ============================================================================

#[derive(Default)]
struct Samples {
    values: Vec<f64>,
}

impl Samples {
    fn push(&mut self, value: f64) {
        self.values.push(value);
    }

    fn len(&self) -> usize {
        self.values.len()
    }

    fn quantile(&self, q: f64) -> f64 {
        if self.values.is_empty() {
            return 0.0;
        }
        let mut sorted = self.values.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let index = ((sorted.len() - 1) as f64 * q).round() as usize;
        sorted[index]
    }

    fn max(&self) -> f64 {
        self.values.iter().copied().fold(0.0_f64, f64::max)
    }

    fn sum(&self) -> f64 {
        self.values.iter().sum()
    }

    fn summary(&self, unit: &str) -> String {
        if self.values.is_empty() {
            return "no samples".to_string();
        }
        format!(
            "n={} p50={:.1}{unit} p95={:.1}{unit} p99={:.1}{unit} max={:.1}{unit}",
            self.len(),
            self.quantile(0.5),
            self.quantile(0.95),
            self.quantile(0.99),
            self.max()
        )
    }
}

// ============================================================================
// Capture callback recorder
// ============================================================================

/// One provider progress report for one lane.
#[derive(Clone)]
struct LaneProgressSample {
    at_wall_ms: f64,
    total_audio_proc_ms: u64,
    lag_ms: u64,
    state: String,
}

#[derive(Default)]
struct RecorderState {
    capture_events: u64,
    full_snapshots: u64,
    preview_events: u64,
    /// Callback-side work the FFI dispatcher thread pays per event.
    capture_callback_ms: Samples,
    preview_callback_ms: Samples,
    /// Wall time between the audio for a Final leaving `push` and the Final
    /// arriving. This is the provider round trip and does not shrink or grow
    /// with the replay rate.
    final_wall_lag_ms: Samples,
    /// The same lag expressed on the audio timeline of this replay rate.
    final_audio_lag_ms: Samples,
    final_sequences: HashSet<u64>,
    withdrawn_sequences: u64,
    event_revision_gaps: u64,
    last_event_revision: u64,
    realtime_lag_ms: Samples,
    /// Latest provider lag, and how far into the recording the provider has
    /// actually finalized. Together these say whether the provider is keeping
    /// up with an accelerated feed or just queueing it.
    last_realtime_lag_ms: u64,
    max_final_end_ms: u64,
    /// Includes speculative rows, so a tail that arrives but never finalizes
    /// is distinguishable from a tail that never arrived.
    max_utterance_end_ms: u64,
    last_new_final_at_ms: f64,
    /// When the last capture event arrived. A lane that has gone dark stops
    /// updating this, and the feed must notice: continuing to push into a
    /// dead stream turns a provider failure into a fake "we replayed it all".
    last_event_at_ms: f64,
    remote_health: Vec<(f64, String)>,
    capture_states: Vec<(f64, String)>,
    /// Provider-confirmed progress per lane, sampled on every live frame.
    lane_progress: HashMap<String, Vec<LaneProgressSample>>,
    /// Longest gap between two consecutive live-preview callbacks — the
    /// caption canvas is redrawn from these, so a gap is a visible freeze.
    last_preview_at: Option<f64>,
    preview_gap_ms: Samples,
}

/// What the Swift-equivalent projection queue paid, and what the transcript
/// looked like each time it paid it.
#[derive(Default)]
struct ProjectionRecord {
    elapsed_ms: Samples,
    by_line_count: Vec<(u64, f64)>,
    errors: Vec<String>,
}

struct Recorder {
    started: Instant,
    speed: f64,
    desired_projection: AtomicU64,
    state: Mutex<RecorderState>,
}

impl Recorder {
    fn new(started: Instant, speed: f64) -> Arc<Self> {
        Arc::new(Self {
            started,
            speed,
            desired_projection: AtomicU64::new(0),
            state: Mutex::new(RecorderState::default()),
        })
    }

    fn elapsed_ms(&self) -> f64 {
        self.started.elapsed().as_secs_f64() * 1_000.0
    }
}

/// Thin forwarder so the recorded callback cost stays the callback's own cost.
struct RecordingCallback(Arc<Recorder>);

impl FfiNotebookCaptureCallback for RecordingCallback {
    fn on_capture_event(&self, event: FfiNotebookCaptureEvent) {
        let entered = Instant::now();
        let now_ms = self.0.elapsed_ms();
        self.0
            .desired_projection
            .fetch_max(event.event_revision, Ordering::AcqRel);

        let mut state = self.0.state.lock().unwrap();
        state.capture_events += 1;
        state.last_event_at_ms = now_ms;
        if event.is_full_snapshot {
            state.full_snapshots += 1;
        }
        if state.last_event_revision != 0 && event.event_revision > state.last_event_revision + 1 {
            state.event_revision_gaps += 1;
        }
        state.last_event_revision = state.last_event_revision.max(event.event_revision);
        state.withdrawn_sequences += event.removed_sequences.len() as u64;
        if let Some(lag) = event.realtime_lag_ms {
            state.realtime_lag_ms.push(lag as f64);
            state.last_realtime_lag_ms = lag;
        }

        let health = format!("{:?}", event.remote_health);
        if state
            .remote_health
            .last()
            .is_none_or(|(_, last)| *last != health)
        {
            state.remote_health.push((now_ms, health));
        }
        let capture_state = format!("{:?}", event.capture_state);
        if state
            .capture_states
            .last()
            .is_none_or(|(_, last)| *last != capture_state)
        {
            state.capture_states.push((now_ms, capture_state));
        }

        for utterance in &event.utterances {
            // Speculative rows count as provider progress even though they are
            // not yet text the user can trust. Tracking them separately is how
            // a tail that arrives but never finalizes stays visible instead of
            // looking like audio the provider swallowed.
            if let Some(end_ms) = utterance.source_end_ms {
                state.max_utterance_end_ms = state.max_utterance_end_ms.max(end_ms);
            }
            if utterance.completion != "complete" {
                continue;
            }
            if !state.final_sequences.insert(utterance.sequence) {
                continue;
            }
            let Some(end_ms) = utterance.source_end_ms else {
                continue;
            };
            state.max_final_end_ms = state.max_final_end_ms.max(end_ms);
            state.last_new_final_at_ms = now_ms;
            // The audio ending at `end_ms` was pushed at `end_ms / speed`.
            let pushed_at_ms = end_ms as f64 / self.0.speed;
            let wall_lag = (now_ms - pushed_at_ms).max(0.0);
            state.final_wall_lag_ms.push(wall_lag);
            state.final_audio_lag_ms.push(wall_lag * self.0.speed);
        }

        state
            .capture_callback_ms
            .push(entered.elapsed().as_secs_f64() * 1_000.0);
    }

    fn on_live_preview(&self, preview: FfiNotebookCaptureLivePreview) {
        let entered = Instant::now();
        let now_ms = self.0.elapsed_ms();
        let _ = preview.preview_revision;
        let mut state = self.0.state.lock().unwrap();
        state.preview_events += 1;
        // Provider-confirmed progress, per lane. This is the only honest
        // measure of whether a translation lane is keeping up: a lane's own
        // utterance timestamps advance when it emits a segment, so a lane that
        // has processed the audio but not yet segmented looks identical to one
        // that is minutes behind.
        for lane in &preview.lane_health {
            let key = lane
                .target_language
                .clone()
                .unwrap_or_else(|| "canonical".to_string());
            let sample = LaneProgressSample {
                at_wall_ms: now_ms,
                total_audio_proc_ms: lane.total_audio_proc_ms.unwrap_or(0),
                lag_ms: lane.lag_ms.unwrap_or(0),
                state: lane.state.clone(),
            };
            state.lane_progress.entry(key).or_default().push(sample);
        }
        if let Some(previous) = state.last_preview_at {
            state.preview_gap_ms.push(now_ms - previous);
        }
        state.last_preview_at = Some(now_ms);
        state
            .preview_callback_ms
            .push(entered.elapsed().as_secs_f64() * 1_000.0);
    }
}

// ============================================================================
// Accelerated realtime replay
// ============================================================================

#[test]
#[ignore = "opt-in: replays a real recording through the real Soniox realtime pipeline"]
fn replay_lecture_realtime_accelerated() {
    init_tracing();
    let media = media_path();
    let out_dir = output_dir();
    let speed = replay_speed();
    let languages = replay_languages();
    let language = languages[0].clone();
    // One lane per selected language, plus the canonical lane when there is
    // more than one — the same plan the core derives.
    let lane_count = if languages.len() >= 3 {
        languages.len() as u32 + 1
    } else {
        1
    };
    let invite = InviteLane::from_env(lane_count).map(Arc::new);
    let api_key = if invite.is_none() {
        Some(soniox_api_key())
    } else {
        None
    };

    let audio = canonical_audio(&media, replay_seconds());
    let audio_ms = audio.duration_ms();
    eprintln!(
        "[decode] source {} Hz x{} ch, {} samples -> {:.1}s canonical 16 kHz mono\n\
         [decode] decode {:.1}s, canonicalize {:.1}s",
        audio.source_sample_rate,
        audio.source_channels,
        audio.source_samples,
        audio_ms as f64 / 1_000.0,
        audio.decode.as_secs_f64(),
        audio.canonicalize.as_secs_f64(),
    );

    let tmp = TempDir::new().expect("create replay data directory");
    let core = Arc::new(
        ZuTalkCore::new_for_test(tmp.path().to_string_lossy().into_owned())
            .expect("create core for replay"),
    );
    let notebook = core
        .create_notebook(Some("Accelerated replay".to_string()))
        .expect("create replay notebook");
    let mut profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .expect("read capture profile");
    profile.remote_realtime_enabled = true;
    profile.selected_languages = languages.clone();
    profile.language_a = languages[0].clone();
    profile.language_b = languages
        .get(1)
        .cloned()
        .unwrap_or_else(|| if language == "en" { "zh" } else { "en" }.to_string());
    profile.left_language = profile.language_a.clone();
    profile.right_language = profile.language_b.clone();
    profile.common_caption_language = None;
    profile.send_context_to_soniox = false;
    let profile = core
        .update_notebook_capture_profile(profile)
        .expect("enable remote realtime capture");

    let started = Instant::now();
    let recorder = Recorder::new(started, speed);

    // Resolve the credential last: the reservation it may create must be
    // covered by a settle guard from the moment it exists.
    let mut settle_guard: Option<InviteSettleGuard> = None;
    match (&api_key, &invite) {
        (Some(key), _) => {
            core.set_api_key("soniox".to_string(), key.clone())
                .expect("install Soniox credential");
        }
        (None, Some(lane)) => {
            let before = lane.quota();
            // The reservation doubles as the Soniox WebSocket duration cap, so
            // it has to cover the whole wall clock of the replay, not just its
            // audio duration.
            let requested = (audio_ms as i64 / 1_000) + 900;
            let reserved = lane.reserve(requested);
            settle_guard = Some(InviteSettleGuard {
                lane: lane.clone(),
                recorder: recorder.clone(),
            });
            eprintln!(
                "[invite] quota before: {}s remaining of {}s ({}s used) | requested {requested}s, reserved {reserved}s for {} lane(s)",
                before.remaining_seconds, before.quota_seconds, before.used_seconds, lane.lane_count
            );
            assert!(
                reserved >= audio_ms as i64 / 1_000,
                "reservation {reserved}s is shorter than the {}s recording; \
                 Soniox would cut the WebSocket off mid-replay",
                audio_ms / 1_000
            );
            core.set_lane_credential_requester(Some(Box::new(InviteLaneRequester {
                core: Arc::downgrade(&core),
                lane: lane.clone(),
            })));
        }
        (None, None) => unreachable!("credential resolution already panicked"),
    }

    let event = core
        .start_notebook_capture_session(
            notebook.id.clone(),
            profile.revision,
            None,
            Box::new(RecordingCallback(recorder.clone())),
        )
        .expect("start capture session");
    let session_id = event.session_id.clone();
    eprintln!(
        "[start] session opened, feeding {:.1}s of audio at {speed}x (expect ~{:.1}s wall)",
        audio_ms as f64 / 1_000.0,
        audio_ms as f64 / 1_000.0 / speed
    );

    // The Swift client projects on a background queue, gated only on
    // desired > applied. Reproduce that shape exactly.
    let projection_stop = Arc::new(AtomicBool::new(false));
    let projection_samples = Arc::new(Mutex::new(ProjectionRecord::default()));
    let projection_worker = {
        let core = core.clone();
        let recorder = recorder.clone();
        let session_id = session_id.clone();
        let stop = projection_stop.clone();
        let samples = projection_samples.clone();
        std::thread::spawn(move || {
            let mut applied = 0_u64;
            loop {
                let desired = recorder.desired_projection.load(Ordering::Acquire);
                if desired <= applied {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                }
                let lines = recorder.state.lock().unwrap().final_sequences.len() as u64;
                let projection_started = Instant::now();
                let outcome = core.project_notebook_realtime_incremental(session_id.clone());
                let elapsed = projection_started.elapsed().as_secs_f64() * 1_000.0;
                applied = desired;
                let mut guard = samples.lock().unwrap();
                guard.elapsed_ms.push(elapsed);
                guard.by_line_count.push((lines, elapsed));
                if let Err(error) = outcome {
                    guard.errors.push(format!("{error:?}"));
                }
            }
        })
    };

    // Feed on a fixed schedule so a slow push shows up as schedule slip
    // rather than silently stretching the replay.
    let mut push_ms = Samples::default();
    let mut schedule_slip_ms = Samples::default();
    let mut throttle_wait = Duration::ZERO;
    let mut push_error: Option<String> = None;
    let max_lag_ms = max_provider_lag_ms();
    let total_chunks = audio.s16le.len().div_ceil(PCM_CHUNK_BYTES);
    for (index, chunk) in audio.s16le.chunks(PCM_CHUNK_BYTES).enumerate() {
        let due = Duration::from_secs_f64((index as f64 * CHUNK_MS as f64) / (speed * 1_000.0));
        let now = started.elapsed();
        if due > now {
            std::thread::sleep(due - now);
        } else {
            schedule_slip_ms.push((now - due).as_secs_f64() * 1_000.0);
        }
        // Hold the requested rate only while the provider keeps up. Beyond the
        // bound the feed waits, so the run measures the provider's real ceiling
        // instead of dying of a backlog it built itself.
        if max_lag_ms > 0 {
            let throttle_started = Instant::now();
            while recorder.state.lock().unwrap().last_realtime_lag_ms > max_lag_ms {
                std::thread::sleep(Duration::from_millis(200));
                if throttle_started.elapsed() > Duration::from_secs(300) {
                    break;
                }
            }
            throttle_wait += throttle_started.elapsed();
        }
        // A silent lane still accepts pushes: the journal keeps taking audio
        // and `try_fanout_pcm` succeeds into a channel nobody drains. Without
        // this the feed races to the end of the file and the run reports a
        // replay that never reached the provider.
        {
            let state = recorder.state.lock().unwrap();
            let silence_ms = recorder.started.elapsed().as_secs_f64() * 1_000.0
                - state.last_event_at_ms.max(1.0);
            if state.capture_events > 0 && silence_ms > LANE_SILENCE_ABORT_MS {
                drop(state);
                push_error = Some(format!(
                    "lane went silent for {:.0}s at chunk {index}/{total_chunks} \
                     ({:.0}s of audio fed)",
                    silence_ms / 1_000.0,
                    (index as u64 * CHUNK_MS) as f64 / 1_000.0
                ));
                break;
            }
        }
        let push_started = Instant::now();
        let outcome = core.push_notebook_capture_session(session_id.clone(), chunk.to_vec());
        push_ms.push(push_started.elapsed().as_secs_f64() * 1_000.0);
        if let Err(error) = outcome {
            push_error = Some(format!("chunk {index}/{total_chunks}: {error:?}"));
            break;
        }
        if index % 6_000 == 0 && index > 0 {
            let state = recorder.state.lock().unwrap();
            eprintln!(
                "[feed] audio {:.0}s | wall {:.0}s | finals {} | events {} | previews {}",
                (index as u64 * CHUNK_MS) as f64 / 1_000.0,
                started.elapsed().as_secs_f64(),
                state.final_sequences.len(),
                state.capture_events,
                state.preview_events,
            );
        }
    }
    let feed_wall = started.elapsed();
    if let Some(error) = &push_error {
        eprintln!("[feed] STOPPED EARLY: {error}");
    }

    // Pushing bytes faster than the provider decodes them only builds a queue,
    // so the interesting number is how long the provider needs after the last
    // byte. Wait for it to reach the end of the recording instead of guessing
    // a drain window: stopping early would truncate the transcript and hide
    // exactly the backlog this replay is meant to expose.
    let catch_up_started = Instant::now();
    let mut catch_up_curve: Vec<(f64, u64, u64)> = Vec::new();
    let catch_up_reason = loop {
        let (max_final_end_ms, max_utterance_end_ms, last_lag_ms, idle_ms) = {
            let state = recorder.state.lock().unwrap();
            (
                state.max_final_end_ms,
                state.max_utterance_end_ms,
                state.last_realtime_lag_ms,
                recorder.elapsed_ms() - state.last_new_final_at_ms,
            )
        };
        catch_up_curve.push((
            catch_up_started.elapsed().as_secs_f64(),
            max_final_end_ms,
            last_lag_ms,
        ));
        if max_final_end_ms + 2_000 >= audio_ms {
            break "provider finalized through the end of the recording";
        }
        if max_utterance_end_ms + 2_000 >= audio_ms && idle_ms > 20_000.0 {
            // The tail is on screen but still speculative. `stop` is what
            // finalizes it, so waiting longer buys nothing.
            break "tail reached but still speculative; stopping to finalize it";
        }
        if idle_ms > 120_000.0 {
            break "no new Final for 120s";
        }
        if catch_up_started.elapsed() > Duration::from_secs_f64(audio_ms as f64 / 1_000.0 + 300.0) {
            break "catch-up budget exhausted";
        }
        if catch_up_curve.len().is_multiple_of(30) {
            eprintln!(
                "[drain] provider at {:.0}s of {:.0}s audio | lag {:.0}s | {:.0}s since feed ended",
                max_final_end_ms as f64 / 1_000.0,
                audio_ms as f64 / 1_000.0,
                last_lag_ms as f64 / 1_000.0,
                catch_up_started.elapsed().as_secs_f64()
            );
        }
        std::thread::sleep(Duration::from_secs(1));
    };
    let catch_up_wall = catch_up_started.elapsed();
    eprintln!(
        "[drain] stopped waiting after {:.1}s: {catch_up_reason}",
        catch_up_wall.as_secs_f64()
    );

    let stop_started = Instant::now();
    let stop_event = core
        .stop_notebook_capture_session(session_id.clone())
        .expect("stop capture session");
    let stop_wall = stop_started.elapsed();

    let mut settle = Instant::now();
    let mut last_state = format!("{:?}", stop_event.capture_state);
    loop {
        let event = core
            .get_notebook_capture_session_event(session_id.clone())
            .expect("read capture event");
        let state = format!("{:?}", event.capture_state);
        if state != last_state {
            eprintln!("[stop] capture state -> {state}");
            last_state = state.clone();
            settle = Instant::now();
        }
        let terminal = matches!(state.as_str(), "Completed" | "Failed" | "Interrupted");
        if terminal && settle.elapsed() > Duration::from_secs(3) {
            break;
        }
        if stop_started.elapsed() > Duration::from_secs(180) {
            eprintln!("[stop] gave up waiting for a terminal capture state (last: {state})");
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }

    projection_stop.store(true, Ordering::Release);
    projection_worker.join().expect("join projection worker");

    let utterances = core
        .list_notebook_capture_utterances(session_id.clone())
        .expect("list capture utterances");

    // Close the reservation before reporting so the quota line is the truth
    // after this run rather than a snapshot with seconds still held.
    drop(settle_guard.take());
    let invite_quota_after = invite.as_ref().map(|lane| lane.quota());

    // ---- report ----------------------------------------------------------
    let state = recorder.state.lock().unwrap();
    let projection_record = projection_samples.lock().unwrap();
    let projection = &projection_record.elapsed_ms;
    let projection_by_lines = &projection_record.by_line_count;
    let projection_errors = &projection_record.errors;
    let wall = started.elapsed();
    let realtime_factor = audio_ms as f64 / 1_000.0 / feed_wall.as_secs_f64();

    let mut report = String::new();
    let mut line = |text: String| {
        eprintln!("{text}");
        report.push_str(&text);
        report.push('\n');
    };

    line("======== accelerated realtime replay ========".to_string());
    line(format!(
        "audio {:.1}s | requested speed {speed}x | achieved {realtime_factor:.1}x | feed wall {:.1}s | total wall {:.1}s",
        audio_ms as f64 / 1_000.0,
        feed_wall.as_secs_f64(),
        wall.as_secs_f64()
    ));
    line(format!(
        "decode {:.1}s + canonicalize {:.1}s before a single byte was sent",
        audio.decode.as_secs_f64(),
        audio.canonicalize.as_secs_f64()
    ));
    // What the feed rate bought, versus what the provider actually did with it.
    let finalized_ms = state.max_final_end_ms;
    let provider_wall = feed_wall.as_secs_f64() + catch_up_wall.as_secs_f64();
    line(format!(
        "provider finalized {:.1}s (saw {:.1}s incl. speculative) of the {:.1}s recording in {:.1}s wall = {:.2}x realtime throughput",
        finalized_ms as f64 / 1_000.0,
        state.max_utterance_end_ms as f64 / 1_000.0,
        audio_ms as f64 / 1_000.0,
        provider_wall,
        finalized_ms as f64 / 1_000.0 / provider_wall.max(0.001)
    ));
    line(format!(
        "feed throttled {:.1}s waiting for the provider (bound {}ms of lag)",
        throttle_wait.as_secs_f64(),
        max_lag_ms
    ));
    line(format!(
        "after the last byte was pushed the provider still needed {:.1}s ({catch_up_reason})",
        catch_up_wall.as_secs_f64()
    ));
    line(
        "provider progress after the feed ended (wall s -> finalized audio s, lag s):".to_string(),
    );
    for (at, finalized, lag) in catch_up_curve
        .iter()
        .step_by((catch_up_curve.len() / 12).max(1))
    {
        line(format!(
            "  {at:>6.0}s -> {:>7.1}s  lag {:>6.1}s",
            *finalized as f64 / 1_000.0,
            *lag as f64 / 1_000.0
        ));
    }
    line(format!(
        "push (audio thread):        {}",
        push_ms.summary("ms")
    ));
    line(format!(
        "schedule slip (feed behind):  {} over {} of {} chunks",
        schedule_slip_ms.summary("ms"),
        schedule_slip_ms.len(),
        total_chunks
    ));
    line(format!(
        "capture callback (dispatch):  {}",
        state.capture_callback_ms.summary("ms")
    ));
    line(format!(
        "live preview callback:        {}",
        state.preview_callback_ms.summary("ms")
    ));
    line(format!(
        "preview gap (canvas redraw):  {} at {speed}x -> divide by {speed} for 1x",
        state.preview_gap_ms.summary("ms")
    ));
    line(format!(
        "incremental projection:       {}",
        projection.summary("ms")
    ));
    line(format!(
        "projection duty cycle:        {:.1}% of the {speed}x feed, ~{:.2}% at 1x",
        100.0 * projection.sum() / feed_wall.as_secs_f64() / 1_000.0,
        100.0 * projection.sum() / feed_wall.as_secs_f64() / 1_000.0 / speed
    ));
    line(format!(
        "Final round trip (wall):      {}",
        state.final_wall_lag_ms.summary("ms")
    ));
    line(format!(
        "Final behind live edge:       {} of audio time at {speed}x",
        state.final_audio_lag_ms.summary("ms")
    ));
    line(format!(
        "provider-reported lag:        {}",
        state.realtime_lag_ms.summary("ms")
    ));
    // The measurement this run exists for. A lane's utterance timestamps only
    // advance when it emits a segment, so they cannot tell a lane that is
    // behind from one that has not segmented yet. This is the provider's own
    // statement of how much audio it has processed on each connection.
    line("per-lane provider throughput (from AudioProgress):".to_string());
    let mut lanes = state.lane_progress.iter().collect::<Vec<_>>();
    lanes.sort_by(|left, right| left.0.cmp(right.0));
    for (name, samples) in lanes {
        let Some(first) = samples.first() else {
            continue;
        };
        let Some(last) = samples.last() else { continue };
        let wall_s = (last.at_wall_ms - first.at_wall_ms) / 1_000.0;
        let audio_s = last
            .total_audio_proc_ms
            .saturating_sub(first.total_audio_proc_ms) as f64
            / 1_000.0;
        let mut lag = Samples::default();
        for sample in samples {
            lag.push(sample.lag_ms as f64);
        }
        line(format!(
            "  {name:<10} processed {audio_s:>7.1}s of audio in {wall_s:>7.1}s wall = {:>5.2}x |              final lag {:>6.1}s | lag {} | state {}",
            if wall_s > 0.0 { audio_s / wall_s } else { 0.0 },
            last.lag_ms as f64 / 1_000.0,
            lag.summary("ms"),
            last.state
        ));
    }
    line(format!(
        "events {} ({} full snapshots, {} revision gaps, {} withdrawals) | previews {}",
        state.capture_events,
        state.full_snapshots,
        state.event_revision_gaps,
        state.withdrawn_sequences,
        state.preview_events
    ));
    line(format!(
        "stop() blocked for {:.1}s",
        stop_wall.as_secs_f64()
    ));
    if let Some(quota) = &invite_quota_after {
        line(format!(
            "community invitation after settlement: {}s remaining of {}s ({}s used)",
            quota.remaining_seconds, quota.quota_seconds, quota.used_seconds
        ));
    }
    line(format!(
        "remote health: {}",
        state
            .remote_health
            .iter()
            .map(|(at, value)| format!("{:.0}s {value}", at / 1_000.0))
            .collect::<Vec<_>>()
            .join(" -> ")
    ));
    line(format!(
        "capture state: {}",
        state
            .capture_states
            .iter()
            .map(|(at, value)| format!("{:.0}s {value}", at / 1_000.0))
            .collect::<Vec<_>>()
            .join(" -> ")
    ));
    if let Some(error) = &push_error {
        line(format!("FEED ABORTED: {error}"));
    }
    match persisted_provider_failure(tmp.path(), &session_id) {
        Some((error_type, request_id)) => line(format!(
            "durable provider failure: {error_type}{}",
            if request_id.is_empty() {
                String::new()
            } else {
                format!(" (request {request_id})")
            }
        )),
        None => line("durable provider failure: none recorded".to_string()),
    }
    line(format!(
        "lane reconnects observed: {}",
        state
            .remote_health
            .iter()
            .filter(|(_, health)| health == "Connecting")
            .count()
            .saturating_sub(1)
    ));
    for error in projection_errors.iter().take(5) {
        line(format!("PROJECTION FAILURE: {error}"));
    }

    // Projection cost against transcript length answers "does it get worse the
    // longer you record", which a single p95 cannot.
    line("projection cost by transcript length:".to_string());
    let mut buckets: Vec<(u64, Samples)> = Vec::new();
    for (lines_at_call, elapsed) in projection_by_lines {
        let bucket = (lines_at_call / 100) * 100;
        match buckets.iter_mut().find(|(key, _)| *key == bucket) {
            Some((_, samples)) => samples.push(*elapsed),
            None => {
                let mut samples = Samples::default();
                samples.push(*elapsed);
                buckets.push((bucket, samples));
            }
        }
    }
    buckets.sort_by_key(|(key, _)| *key);
    for (bucket, samples) in &buckets {
        line(format!("  {bucket:>5}+ lines: {}", samples.summary("ms")));
    }

    let transcript = transcript_text(&utterances);
    line(format!(
        "utterances {} | transcript {} chars | languages {:?}",
        utterances.len(),
        transcript.chars().count(),
        utterances
            .iter()
            .map(|utterance| utterance.source_language.clone())
            .collect::<HashSet<_>>()
    ));

    // The summary above cannot answer "does projection get worse the longer
    // you record" when a session produces few lines. Dump every sample so the
    // question is answerable from any run, not just a long-transcript one.
    let mut projection_table = String::from("finalized_lines\telapsed_ms\n");
    for (lines, elapsed) in projection_by_lines {
        projection_table.push_str(&format!("{lines}\t{elapsed:.3}\n"));
    }
    std::fs::write(out_dir.join("realtime-projection.tsv"), projection_table)
        .expect("write projection sample table");

    let transcript_path = out_dir.join("realtime-transcript.txt");
    std::fs::write(&transcript_path, &transcript).expect("write realtime transcript");
    let report_path = out_dir.join("realtime-report.txt");
    std::fs::write(&report_path, &report).expect("write realtime report");
    let timeline_path = out_dir.join("realtime-utterances.tsv");
    std::fs::write(&timeline_path, utterance_table(&utterances)).expect("write utterance table");
    eprintln!("[out] {}", transcript_path.display());
    eprintln!("[out] {}", report_path.display());
    eprintln!("[out] {}", timeline_path.display());

    assert!(push_error.is_none(), "the accelerated feed did not survive");
    assert!(
        !utterances.is_empty(),
        "an accelerated replay produced no transcript at all"
    );
}

// ============================================================================
// Local cost of getting a long recording into the app at all
// ============================================================================

/// Everything the app must do before a single byte can reach a provider:
/// decode, canonicalize, and the durable encrypted import. No credential and
/// no network.
#[test]
#[ignore = "opt-in: decodes and imports a real long recording"]
fn measure_local_import_cost() {
    let media = media_path();
    let out_dir = output_dir();

    let audio = canonical_audio(&media, replay_seconds());
    let audio_seconds = audio.duration_ms() as f64 / 1_000.0;

    let tmp = TempDir::new().expect("create import data directory");
    let core = ZuTalkCore::new_for_test(tmp.path().to_string_lossy().into_owned())
        .expect("create core for import");
    let notebook = core
        .create_notebook(Some("Local import cost".to_string()))
        .expect("create import notebook");

    let import_started = Instant::now();
    let import = core
        .import_audio_into_notebook(media.to_string_lossy().into_owned(), notebook.id.clone())
        .expect("import media into notebook");
    let import_wall = import_started.elapsed();
    let encrypted_bytes = encrypted_audio_bytes(tmp.path());

    let mut report = String::new();
    let mut line = |text: String| {
        eprintln!("{text}");
        report.push_str(&text);
        report.push('\n');
    };
    line("======== local import cost ========".to_string());
    line(format!(
        "source {} Hz x{} ch | {:.1} minutes | container {} bytes",
        audio.source_sample_rate,
        audio.source_channels,
        audio_seconds / 60.0,
        std::fs::metadata(&media).map(|m| m.len()).unwrap_or(0)
    ));
    line(format!(
        "decode {:.1}s | canonicalize to 16 kHz mono {:.1}s | canonical PCM {:.1} MB",
        audio.decode.as_secs_f64(),
        audio.canonicalize.as_secs_f64(),
        audio.s16le.len() as f64 / 1_048_576.0
    ));
    line(format!(
        "import_audio_into_notebook {:.1}s wall -> {:.2} GB encrypted on disk ({:.0}x the container)",
        import_wall.as_secs_f64(),
        encrypted_bytes as f64 / 1_073_741_824.0,
        encrypted_bytes as f64 / std::fs::metadata(&media).map(|m| m.len()).unwrap_or(1) as f64
    ));
    line(format!(
        "reported duration {} ms | {} Hz x{} ch stored at source rate",
        import.duration_ms, import.sample_rate, import.channels
    ));

    std::fs::write(out_dir.join("import-report.txt"), &report).expect("write import report");
}

// ============================================================================
// Async file transcription
// ============================================================================

#[test]
#[ignore = "opt-in: uploads a real recording through the real Soniox async file API"]
fn transcribe_lecture_async_file_api() {
    let media = media_path();
    let out_dir = output_dir();
    let languages = replay_languages();
    let language = languages[0].clone();
    let api_key = soniox_api_key();

    let tmp = TempDir::new().expect("create transcription data directory");
    let core = ZuTalkCore::new_for_test(tmp.path().to_string_lossy().into_owned())
        .expect("create core for transcription");
    core.set_api_key("soniox".to_string(), api_key)
        .expect("install Soniox credential");

    let notebook = core
        .create_notebook(Some("Async file transcription".to_string()))
        .expect("create transcription notebook");
    let mut profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .expect("read capture profile");
    profile.selected_languages = vec![language.clone()];
    profile.language_a = language.clone();
    profile.language_b = if language == "en" { "zh" } else { "en" }.to_string();
    profile.left_language = profile.language_a.clone();
    profile.right_language = profile.language_b.clone();
    profile.common_caption_language = None;
    core.update_notebook_capture_profile(profile)
        .expect("select transcription language");

    let import_started = Instant::now();
    let import = core
        .import_audio_into_notebook(media.to_string_lossy().into_owned(), notebook.id.clone())
        .expect("import media into notebook");
    let import_wall = import_started.elapsed();
    let audio_seconds = import.duration_ms as f64 / 1_000.0;
    let encrypted_bytes = encrypted_audio_bytes(tmp.path());
    eprintln!(
        "[import] {:.1}s audio at {} Hz x{} ch in {:.1}s wall, {:.2} GB of encrypted PCM on disk",
        audio_seconds,
        import.sample_rate,
        import.channels,
        import_wall.as_secs_f64(),
        encrypted_bytes as f64 / 1_073_741_824.0
    );

    let request_started = Instant::now();
    core.request_notebook_async_transcription(import.session_id.clone())
        .expect("request async transcription");
    let tasks = core.list_tasks(None).expect("list tasks");
    assert_eq!(tasks.len(), 1, "import must enqueue exactly one task");
    let task_id = tasks[0].id.clone();

    let mut last_status = String::new();
    let mut status_timeline: Vec<(f64, String)> = Vec::new();
    loop {
        let task = core
            .get_task_status(task_id.clone())
            .expect("read task status");
        if task.status != last_status {
            let at = request_started.elapsed().as_secs_f64();
            eprintln!("[task] {:.1}s -> {}", at, task.status);
            status_timeline.push((at, task.status.clone()));
            last_status = task.status.clone();
        }
        if task.status == "completed" {
            break;
        }
        assert_ne!(
            task.status, "failed",
            "async transcription failed: {:?}",
            task.error_msg
        );
        // The client's own deadline is audio/2 plus an allowance; give the
        // harness the same order of magnitude plus slack.
        assert!(
            request_started.elapsed() < Duration::from_secs_f64(audio_seconds + 900.0),
            "async transcription did not finish in time (last status {})",
            task.status
        );
        std::thread::sleep(Duration::from_millis(500));
    }
    let transcribe_wall = request_started.elapsed();

    let tokens = core
        .session_meta_for_test()
        .get_tokens(&import.session_id)
        .expect("read persisted tokens");
    let full_text: String = tokens.iter().map(|token| token.text.as_str()).collect();

    let mut report = String::new();
    let mut line = |text: String| {
        eprintln!("{text}");
        report.push_str(&text);
        report.push('\n');
    };
    line("======== async file transcription ========".to_string());
    line(format!(
        "audio {:.1}s | import {:.1}s | upload+transcribe+cleanup {:.1}s | {:.0}x realtime end to end",
        audio_seconds,
        import_wall.as_secs_f64(),
        transcribe_wall.as_secs_f64(),
        audio_seconds / (import_wall.as_secs_f64() + transcribe_wall.as_secs_f64())
    ));
    line(format!(
        "encrypted source PCM on disk: {:.2} GB for {:.0} minutes",
        encrypted_bytes as f64 / 1_073_741_824.0,
        audio_seconds / 60.0
    ));
    line(format!(
        "tokens {} | transcript {} chars",
        tokens.len(),
        full_text.chars().count()
    ));
    line(format!(
        "task status timeline: {}",
        status_timeline
            .iter()
            .map(|(at, status)| format!("{at:.0}s {status}"))
            .collect::<Vec<_>>()
            .join(" -> ")
    ));

    let transcript_path = out_dir.join("async-transcript.txt");
    std::fs::write(&transcript_path, &full_text).expect("write async transcript");
    let token_path = out_dir.join("async-tokens.tsv");
    let mut token_table = String::from("start_ms\tend_ms\tlanguage\tspeaker\ttext\n");
    for token in &tokens {
        token_table.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\n",
            token.start_ms,
            token.end_ms,
            token.language,
            token.speaker.as_deref().unwrap_or(""),
            token.text.replace(['\t', '\n'], " ")
        ));
    }
    std::fs::write(&token_path, token_table).expect("write async token table");
    let report_path = out_dir.join("async-report.txt");
    std::fs::write(&report_path, &report).expect("write async report");
    eprintln!("[out] {}", transcript_path.display());
    eprintln!("[out] {}", token_path.display());
    eprintln!("[out] {}", report_path.display());

    assert!(!tokens.is_empty(), "async transcription produced no tokens");
}

// ============================================================================
// Output helpers
// ============================================================================

fn transcript_text(utterances: &[FfiNotebookCaptureUtterance]) -> String {
    let mut ordered: Vec<&FfiNotebookCaptureUtterance> = utterances.iter().collect();
    ordered.sort_by_key(|utterance| utterance.sequence);
    let mut text = String::new();
    for utterance in ordered {
        if utterance.source_text.trim().is_empty() {
            continue;
        }
        text.push_str(&format!(
            "[{}] {}\n",
            format_timestamp(utterance.source_start_ms.unwrap_or(0)),
            utterance.source_text.trim()
        ));
    }
    text
}

fn utterance_table(utterances: &[FfiNotebookCaptureUtterance]) -> String {
    let mut ordered: Vec<&FfiNotebookCaptureUtterance> = utterances.iter().collect();
    ordered.sort_by_key(|utterance| utterance.sequence);
    let mut table =
        String::from("sequence\tstart_ms\tend_ms\tlanguage\tcompletion\tspeaker\ttext\n");
    for utterance in ordered {
        table.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            utterance.sequence,
            utterance.source_start_ms.unwrap_or(0),
            utterance.source_end_ms.unwrap_or(0),
            utterance.source_language,
            utterance.completion,
            utterance.session_speaker_id.as_deref().unwrap_or(""),
            utterance.source_text.replace(['\t', '\n'], " ")
        ));
    }
    table
}

fn format_timestamp(ms: u64) -> String {
    let total_seconds = ms / 1_000;
    format!(
        "{:02}:{:02}:{:02}",
        total_seconds / 3_600,
        (total_seconds % 3_600) / 60,
        total_seconds % 60
    )
}

/// Total bytes the import wrote as encrypted PCM under this data directory.
fn encrypted_audio_bytes(data_dir: &Path) -> u64 {
    fn walk(path: &Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                walk(&entry.path(), total);
            } else if entry.path().extension().is_some_and(|ext| ext == "enc") {
                if let Ok(metadata) = entry.metadata() {
                    *total += metadata.len();
                }
            }
        }
    }
    let mut total = 0;
    walk(data_dir, &mut total);
    total
}
