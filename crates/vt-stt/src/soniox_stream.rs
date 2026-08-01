//! Ordered Soniox v5 streaming protocol for Notebook capture.
//!
//! Realtime Notebook capture retains the provider response shape because translation tokens do
//! not carry timestamps. The separate post-stop transcription adapter projects source tokens into
//! [`vt_model::Token`], whose timestamps are mandatory; it is not used by the live bilingual UI.

use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{self, Instant, Sleep};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tokio_util::sync::CancellationToken;

use crate::soniox_rt::{
    canonical_soniox_error_type, safe_soniox_provider_detail, safe_soniox_request_id,
    SonioxTranslation,
};
use crate::{
    ContextConfig, SonioxQuotaKind, SttConfig, SttError, TranslationConfig,
    CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const RECEIVE_IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);
const DRAIN_TIMEOUT: Duration = Duration::from_secs(5);
const RECONNECT_BASE_DELAY: Duration = Duration::from_secs(1);
const RECONNECT_MAX_ATTEMPTS: u8 = 3;
const CONTINUITY_WINDOW: Duration = Duration::from_secs(15);
const FAST_RECONNECT_WINDOW: Duration = Duration::from_secs(5);
const REPLAY_OVERLAP: Duration = Duration::from_secs(2);
const PCM_BYTES_PER_MILLISECOND: u64 = 32;

// The macOS capture tap forwards approximately one 100 ms, 3,200-byte PCM
// block at a time. Keep enough bounded queue space for all three production
// reconnect attempts (1s + 2s + 4s backoff plus connect time) without turning
// a transient network loss into FFI audio backpressure.
const AUDIO_CHANNEL_CAPACITY: usize = 512;
const CONTROL_CHANNEL_CAPACITY: usize = 8;
const EVENT_CHANNEL_CAPACITY: usize = 64;

/// Translation role supplied by Soniox for an ordered stream token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SttStreamTranslationStatus {
    None,
    Original,
    Translation,
    Unknown(String),
}

impl SttStreamTranslationStatus {
    fn from_provider(value: Option<String>) -> Self {
        match value.as_deref() {
            None | Some("none") => Self::None,
            Some("original") => Self::Original,
            Some("translation") => Self::Translation,
            Some(other) => Self::Unknown(other.to_string()),
        }
    }
}

/// A Soniox stream token that preserves absent translation timestamps.
#[derive(Debug, Clone, PartialEq)]
pub struct SttStreamToken {
    pub text: String,
    pub start_ms: Option<u64>,
    pub end_ms: Option<u64>,
    pub is_final: bool,
    pub confidence: Option<f32>,
    pub translation_status: SttStreamTranslationStatus,
    pub language: Option<String>,
    pub source_language: Option<String>,
    /// Anonymous label scoped to the current Soniox WebSocket session.
    pub speaker: Option<String>,
}

/// Stable provider error metadata. The numeric HTTP-style code and request ID are never reduced
/// to display text so callers can persist them on the capture run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SttStreamProviderError {
    pub error_code: u16,
    pub error_type: String,
    pub error_message: String,
    pub request_id: Option<String>,
}

/// Typed stream failures delivered before the runtime task exits with [`SttError`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SttStreamError {
    Provider(SttStreamProviderError),
    Transport { operation: String, message: String },
    Protocol { message: String },
    Timeout { operation: String, elapsed_ms: u64 },
    Closed { code: Option<u16>, reason: String },
}

/// Ordered events emitted by the v5 stream.
#[derive(Debug, Clone, PartialEq)]
pub enum SttStreamEvent {
    /// The WebSocket is connected and its configuration message was accepted by the transport.
    /// Provider validation errors can still follow asynchronously.
    Connected,
    /// A retryable transport/provider failure ended the current WebSocket.
    /// Audio accepted by `audio_tx` remains queued for the replacement session.
    Reconnecting {
        attempt: u8,
        delay_ms: u64,
    },
    /// A replacement WebSocket is configured. The duration measures only the
    /// transport outage, before replay/catch-up work begins.
    RecoveryStarted {
        outage_ms: u64,
    },
    /// Provider-confirmed processing progress for the current WebSocket,
    /// projected onto the capture-wide audio timeline.
    AudioProgress {
        final_audio_proc_ms: u64,
        total_audio_proc_ms: u64,
        lag_ms: u64,
    },
    /// A contiguous batch of non-control tokens in exact provider response order.
    Tokens(Vec<SttStreamToken>),
    /// Soniox emitted the `<end>` semantic endpoint marker.
    Endpoint,
    /// Soniox emitted the `<fin>` manual-finalization marker.
    Finalized,
    /// Soniox emitted `finished: true` after the final tail tokens.
    Finished,
    /// The local capture fanout could no longer append PCM contiguously to
    /// this lane. The caller must end or restart the lane before sending more
    /// audio; continuing on the old provider timeline would compress time.
    InputDiscontinuity,
    Error(SttStreamError),
}

/// Control plane for a Notebook Soniox stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SttStreamControl {
    /// Send `{"type":"finalize"}` without changing pause state.
    Finalize,
    /// Finalize the current utterance, then automatically keep the connection alive every 10s.
    Pause,
    /// Resume forwarding PCM frames and stop automatic keepalives.
    Resume,
    /// Send one explicit `{"type":"keepalive"}`.
    Keepalive,
    /// Send an empty text frame and drain tail responses for at most five seconds.
    Finish,
}

/// Senders, event receiver, and task returned by [`SonioxStreamClient::start`].
///
/// Audio and control are separate so a stop or pause command cannot sit behind queued PCM.
pub struct SonioxStreamRuntime {
    pub audio_tx: mpsc::Sender<Vec<u8>>,
    pub control_tx: mpsc::Sender<SttStreamControl>,
    pub event_rx: mpsc::Receiver<SttStreamEvent>,
    pub task: JoinHandle<Result<(), SttError>>,
}

impl SonioxStreamRuntime {
    pub async fn push_pcm(&self, pcm: Vec<u8>) -> Result<(), SttError> {
        self.audio_tx
            .send(pcm)
            .await
            .map_err(|_| SttError::Cancelled)
    }

    pub async fn send_control(&self, control: SttStreamControl) -> Result<(), SttError> {
        self.control_tx
            .send(control)
            .await
            .map_err(|_| SttError::Cancelled)
    }
}

#[derive(Clone, Copy)]
struct StreamTimeouts {
    connect: Duration,
    write: Duration,
    receive_idle: Duration,
    keepalive: Duration,
    drain: Duration,
    reconnect_base_delay: Duration,
    reconnect_max_attempts: u8,
}

impl Default for StreamTimeouts {
    fn default() -> Self {
        Self {
            connect: CONNECT_TIMEOUT,
            write: WRITE_TIMEOUT,
            receive_idle: RECEIVE_IDLE_TIMEOUT,
            keepalive: KEEPALIVE_INTERVAL,
            drain: DRAIN_TIMEOUT,
            reconnect_base_delay: RECONNECT_BASE_DELAY,
            reconnect_max_attempts: RECONNECT_MAX_ATTEMPTS,
        }
    }
}

struct StreamFailure {
    task_error: SttError,
    event_error: SttStreamError,
}

impl StreamFailure {
    fn transport(operation: &str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            task_error: SttError::ConnectionFailed(format!("{operation}: {message}")),
            event_error: SttStreamError::Transport {
                operation: operation.to_string(),
                message,
            },
        }
    }

    fn protocol(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            task_error: SttError::ParseError(message.clone()),
            event_error: SttStreamError::Protocol { message },
        }
    }

    fn timeout(operation: &str, elapsed: Duration) -> Self {
        Self {
            task_error: SttError::Timeout {
                operation: operation.to_string(),
                elapsed,
            },
            event_error: SttStreamError::Timeout {
                operation: operation.to_string(),
                elapsed_ms: elapsed.as_millis().try_into().unwrap_or(u64::MAX),
            },
        }
    }

    fn closed(code: Option<u16>) -> Self {
        let reason = if code.is_some() {
            "provider closed the stream before finished".to_string()
        } else {
            "provider stream ended before finished".to_string()
        };
        let task_error = match code {
            Some(code) if matches!(code, 1008 | 4001 | 4003) => SttError::AuthFailed {
                message: format!("authentication_error (close_status={code})"),
            },
            Some(code) => SttError::ServerClosed {
                code,
                reason: reason.clone(),
            },
            None => SttError::ConnectionFailed(reason.clone()),
        };
        Self {
            task_error,
            event_error: SttStreamError::Closed { code, reason },
        }
    }

    fn provider(error: SttStreamProviderError) -> Self {
        let task_error = provider_task_error(&error);
        Self {
            task_error,
            event_error: SttStreamError::Provider(error),
        }
    }

    fn is_retryable(&self) -> bool {
        match &self.event_error {
            SttStreamError::Transport { .. } => true,
            SttStreamError::Timeout { operation, .. } => operation != "Soniox stream drain",
            SttStreamError::Closed { code, .. } => {
                !code.is_some_and(|code| matches!(code, 1008 | 4001 | 4003))
            }
            SttStreamError::Provider(error) => {
                matches!(error.error_code, 413 | 429 | 503)
                    || matches!(
                        error.error_type.as_str(),
                        "max_duration_reached" | "rate_limited" | "service_unavailable"
                    )
            }
            SttStreamError::Protocol { .. } => false,
        }
    }
}

fn provider_task_error(error: &SttStreamProviderError) -> SttError {
    let error_type = canonical_soniox_error_type(error.error_code, Some(&error.error_type));
    let detail =
        safe_soniox_provider_detail(error.error_code, error_type, error.request_id.as_deref());
    match error.error_code {
        401 | 403 => SttError::AuthFailed { message: detail },
        402 => SttError::QuotaExhausted {
            kind: SonioxQuotaKind::from_error_type(Some(&error.error_type)),
            message: detail,
        },
        429 => SttError::RateLimited,
        status => SttError::ApiError {
            status,
            error_type: error_type.to_string(),
            message: detail,
        },
    }
}

// Deliberately not `Debug`: this wire value contains the provider credential
// and the exact user-approved Context Pack payload.
#[derive(Serialize)]
struct SonioxStreamConfig {
    api_key: String,
    model: String,
    audio_format: String,
    sample_rate: u32,
    num_channels: u8,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    language_hints: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    language_hints_strict: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_language_identification: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_speaker_diarization: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enable_endpoint_detection: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    endpoint_latency_adjustment_level: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    endpoint_sensitivity: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_endpoint_delay_ms: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: Option<SonioxStreamContext>,
    #[serde(skip_serializing_if = "Option::is_none")]
    translation: Option<SonioxTranslation>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_reference_id: Option<String>,
}

#[derive(Serialize)]
struct SonioxStreamContext {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    translation_terms: Vec<SonioxStreamTranslationTerm>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    terms: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    general: Vec<SonioxStreamContextEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
}

#[derive(Serialize)]
struct SonioxStreamContextEntry {
    key: String,
    value: String,
}

#[derive(Serialize)]
struct SonioxStreamTranslationTerm {
    source: String,
    target: String,
}

#[derive(Debug, Deserialize)]
struct SonioxStreamResponse {
    #[serde(default)]
    tokens: Vec<SonioxStreamTokenWire>,
    #[serde(default)]
    finished: bool,
    #[serde(default)]
    error_code: Option<u16>,
    #[serde(default)]
    error_type: Option<String>,
    /// Decoded only so the wire shape remains explicit; never surfaced.
    #[serde(default, rename = "error_message", alias = "message")]
    _error_message: Option<String>,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    final_audio_proc_ms: Option<u64>,
    #[serde(default)]
    total_audio_proc_ms: Option<u64>,
}

#[derive(Debug, Clone)]
struct ReplayAudioFrame {
    end_ms: u64,
    pcm: Vec<u8>,
}

#[derive(Debug, Default)]
struct StreamRecoveryState {
    next_audio_ms: u64,
    acknowledged_ms: u64,
    connection_origin_ms: u64,
    sent_frames: VecDeque<ReplayAudioFrame>,
}

impl StreamRecoveryState {
    fn record_sent(&mut self, pcm: Vec<u8>) {
        let duration_ms = (pcm.len() as u64)
            .div_ceil(PCM_BYTES_PER_MILLISECOND)
            .max(1);
        let frame = ReplayAudioFrame {
            end_ms: self.next_audio_ms.saturating_add(duration_ms),
            pcm,
        };
        self.next_audio_ms = frame.end_ms;
        self.sent_frames.push_back(frame);
    }

    fn acknowledge(&mut self, provider_total_ms: u64) -> (u64, u64) {
        let acknowledged = self
            .connection_origin_ms
            .saturating_add(provider_total_ms)
            .min(self.next_audio_ms);
        self.acknowledged_ms = self.acknowledged_ms.max(acknowledged);
        let retain_from = self
            .acknowledged_ms
            .saturating_sub(REPLAY_OVERLAP.as_millis() as u64);
        while self
            .sent_frames
            .front()
            .is_some_and(|frame| frame.end_ms <= retain_from)
        {
            self.sent_frames.pop_front();
        }
        (
            self.acknowledged_ms,
            self.next_audio_ms.saturating_sub(self.acknowledged_ms),
        )
    }

    fn prepare_replay(&mut self, outage: Duration) -> Vec<ReplayAudioFrame> {
        if outage > CONTINUITY_WINDOW {
            self.sent_frames.clear();
            self.acknowledged_ms = self.next_audio_ms;
            self.connection_origin_ms = self.next_audio_ms;
            return Vec::new();
        }
        let replay_from = self
            .acknowledged_ms
            .saturating_sub(REPLAY_OVERLAP.as_millis() as u64);
        self.connection_origin_ms = replay_from;
        self.sent_frames
            .iter()
            .filter(|frame| frame.end_ms > replay_from)
            .cloned()
            .collect()
    }

    fn replay_duplicate_until_provider_ms(&self) -> u64 {
        self.acknowledged_ms
            .saturating_sub(self.connection_origin_ms)
    }
}

#[derive(Debug, Deserialize)]
struct SonioxStreamTokenWire {
    text: String,
    #[serde(default)]
    start_ms: Option<u64>,
    #[serde(default)]
    end_ms: Option<u64>,
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    confidence: Option<f32>,
    #[serde(default)]
    translation_status: Option<String>,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    source_language: Option<String>,
    #[serde(default)]
    speaker: Option<String>,
}

impl From<SonioxStreamTokenWire> for SttStreamToken {
    fn from(value: SonioxStreamTokenWire) -> Self {
        Self {
            text: value.text,
            start_ms: value.start_ms,
            end_ms: value.end_ms,
            is_final: value.is_final,
            confidence: value.confidence,
            translation_status: SttStreamTranslationStatus::from_provider(value.translation_status),
            language: value.language,
            source_language: value.source_language,
            speaker: value.speaker,
        }
    }
}

#[derive(Debug, Serialize)]
struct ControlMessage {
    #[serde(rename = "type")]
    control_type: &'static str,
}

/// v5 Notebook capture stream. Starting is non-blocking; `Connected` is emitted only after the
/// configuration frame has been sent successfully.
pub struct SonioxStreamClient;

impl SonioxStreamClient {
    pub fn start(
        endpoint: impl Into<String>,
        api_key: impl Into<String>,
        config: SttConfig,
        cancel: CancellationToken,
    ) -> SonioxStreamRuntime {
        Self::start_with_timeouts(endpoint, api_key, config, cancel, StreamTimeouts::default())
    }

    fn start_with_timeouts(
        endpoint: impl Into<String>,
        api_key: impl Into<String>,
        config: SttConfig,
        cancel: CancellationToken,
        timeouts: StreamTimeouts,
    ) -> SonioxStreamRuntime {
        let (audio_tx, audio_rx) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
        let (control_tx, control_rx) = mpsc::channel(CONTROL_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(EVENT_CHANNEL_CAPACITY);
        let endpoint = endpoint.into();
        let api_key = api_key.into();
        let task = tokio::spawn(async move {
            match run_stream(
                &endpoint, &api_key, &config, audio_rx, control_rx, &event_tx, cancel, timeouts,
            )
            .await
            {
                Ok(()) => Ok(()),
                Err(failure) => {
                    let _ = event_tx
                        .send(SttStreamEvent::Error(failure.event_error))
                        .await;
                    Err(failure.task_error)
                }
            }
        });
        SonioxStreamRuntime {
            audio_tx,
            control_tx,
            event_rx,
            task,
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_stream(
    endpoint: &str,
    api_key: &str,
    config: &SttConfig,
    mut audio_rx: mpsc::Receiver<Vec<u8>>,
    mut control_rx: mpsc::Receiver<SttStreamControl>,
    event_tx: &mpsc::Sender<SttStreamEvent>,
    cancel: CancellationToken,
    timeouts: StreamTimeouts,
) -> Result<(), StreamFailure> {
    let mut paused = false;
    let mut reconnect_attempt = 0_u8;
    let mut disconnected_at = None::<Instant>;
    let mut recovery = StreamRecoveryState::default();
    loop {
        let mut session_connected = false;
        let reconnect_outage = disconnected_at.map(|started| started.elapsed());
        match run_stream_session(
            endpoint,
            api_key,
            config,
            &mut audio_rx,
            &mut control_rx,
            event_tx,
            cancel.clone(),
            timeouts,
            &mut paused,
            &mut session_connected,
            &mut recovery,
            reconnect_outage,
        )
        .await
        {
            Ok(()) => return Ok(()),
            Err(failure) if failure.is_retryable() => {
                if session_connected {
                    disconnected_at = Some(Instant::now());
                    reconnect_attempt = 0;
                } else {
                    disconnected_at.get_or_insert_with(Instant::now);
                }
                if reconnect_attempt >= timeouts.reconnect_max_attempts {
                    return Err(failure);
                }
                reconnect_attempt += 1;
                let delay = reconnect_delay(timeouts.reconnect_base_delay, reconnect_attempt);
                send_event(
                    event_tx,
                    SttStreamEvent::Reconnecting {
                        attempt: reconnect_attempt,
                        delay_ms: delay.as_millis().try_into().unwrap_or(u64::MAX),
                    },
                )
                .await?;
                match wait_for_reconnect(delay, &mut control_rx, cancel.clone(), &mut paused).await
                {
                    ReconnectWait::Retry => {}
                    ReconnectWait::Cancelled => return Ok(()),
                    ReconnectWait::Finish => return Err(failure),
                }
            }
            Err(failure) => return Err(failure),
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_stream_session(
    endpoint: &str,
    api_key: &str,
    config: &SttConfig,
    audio_rx: &mut mpsc::Receiver<Vec<u8>>,
    control_rx: &mut mpsc::Receiver<SttStreamControl>,
    event_tx: &mpsc::Sender<SttStreamEvent>,
    cancel: CancellationToken,
    timeouts: StreamTimeouts,
    paused: &mut bool,
    session_connected: &mut bool,
    recovery: &mut StreamRecoveryState,
    reconnect_outage: Option<Duration>,
) -> Result<(), StreamFailure> {
    let connect = time::timeout(timeouts.connect, connect_async(endpoint))
        .await
        .map_err(|_| StreamFailure::timeout("Soniox stream connect", timeouts.connect))?
        .map_err(|error| StreamFailure::transport("Soniox stream connect", error.to_string()))?;
    let (ws_stream, _) = connect;
    let (mut write, mut read) = ws_stream.split();

    let wire_config = build_stream_config(api_key, config);
    let config_json = serde_json::to_string(&wire_config)
        .map_err(|error| StreamFailure::protocol(error.to_string()))?;
    send_message(
        &mut write,
        Message::Text(config_json.into()),
        "Soniox stream configuration send",
        timeouts.write,
    )
    .await?;
    *session_connected = true;

    let mut suppress_replay_until_provider_ms = 0_u64;
    if let Some(outage) = reconnect_outage {
        send_event(
            event_tx,
            SttStreamEvent::RecoveryStarted {
                outage_ms: outage.as_millis().try_into().unwrap_or(u64::MAX),
            },
        )
        .await?;
        send_event(
            event_tx,
            SttStreamEvent::AudioProgress {
                final_audio_proc_ms: recovery.acknowledged_ms,
                total_audio_proc_ms: recovery.acknowledged_ms,
                lag_ms: outage.as_millis().try_into().unwrap_or(u64::MAX),
            },
        )
        .await?;
        let replay = recovery.prepare_replay(outage);
        suppress_replay_until_provider_ms = recovery.replay_duplicate_until_provider_ms();
        let replay_interval = if outage > FAST_RECONNECT_WINDOW {
            Some(Duration::from_millis(80))
        } else {
            None
        };
        for frame in replay {
            send_message(
                &mut write,
                Message::Binary(frame.pcm.into()),
                "Soniox stream recovery audio send",
                timeouts.write,
            )
            .await?;
            if let Some(interval) = replay_interval {
                time::sleep(interval).await;
            }
        }
        if outage > FAST_RECONNECT_WINDOW && outage <= CONTINUITY_WINDOW {
            while let Ok(pcm) = audio_rx.try_recv() {
                let retained_pcm = pcm.clone();
                send_message(
                    &mut write,
                    Message::Binary(pcm.into()),
                    "Soniox stream catch-up audio send",
                    timeouts.write,
                )
                .await?;
                recovery.record_sent(retained_pcm);
                time::sleep(Duration::from_millis(80)).await;
            }
        } else if outage > CONTINUITY_WINDOW {
            // The local encrypted journal remains authoritative for this
            // interval. Do not burst stale remote audio into the new,
            // explicitly non-contiguous realtime epoch.
            while audio_rx.try_recv().is_ok() {}
        }
    } else {
        recovery.connection_origin_ms = recovery.next_audio_ms;
    }
    send_event(event_tx, SttStreamEvent::Connected).await?;

    let mut draining = false;
    let mut audio_open = true;
    let mut control_open = true;
    let far_future = Duration::from_secs(365 * 24 * 60 * 60);
    let mut keepalive_sleep = Box::pin(time::sleep(far_future));
    let mut drain_sleep = Box::pin(time::sleep(far_future));
    let mut receive_idle_sleep = Box::pin(time::sleep(timeouts.receive_idle));
    if *paused {
        reset_sleep(&mut keepalive_sleep, timeouts.keepalive);
    }

    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            control = control_rx.recv(), if control_open && !draining => {
                match control {
                    Some(SttStreamControl::Finalize) => {
                        drain_queued_audio(&mut write, audio_rx, timeouts.write).await?;
                        send_control(&mut write, "finalize", timeouts.write).await?;
                    }
                    Some(SttStreamControl::Pause) => {
                        // The FFI state lock prevents new pushes before Pause is
                        // enqueued. Flush every audio frame already accepted by
                        // `audio_tx` before the utterance boundary, otherwise the
                        // biased control branch would finalize ahead of speech.
                        drain_queued_audio(&mut write, audio_rx, timeouts.write).await?;
                        send_control(&mut write, "finalize", timeouts.write).await?;
                        *paused = true;
                        reset_sleep(&mut keepalive_sleep, timeouts.keepalive);
                    }
                    Some(SttStreamControl::Resume) => {
                        *paused = false;
                        // A successful keepalive write is sufficient liveness
                        // while paused; restart response-idle accounting only
                        // when audio processing resumes.
                        reset_sleep(&mut receive_idle_sleep, timeouts.receive_idle);
                    }
                    Some(SttStreamControl::Keepalive) => {
                        send_control(&mut write, "keepalive", timeouts.write).await?;
                    }
                    Some(SttStreamControl::Finish) | None => {
                        if control.is_none() {
                            control_open = false;
                        }
                        // Stop closes the capture input before sending Finish.
                        // Drain accepted PCM first, then send the empty frame so
                        // Soniox tail tokens cover the complete local recording.
                        drain_queued_audio(&mut write, audio_rx, timeouts.write).await?;
                        begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts).await?;
                    }
                }
            }
            audio = audio_rx.recv(), if audio_open && !draining => {
                match audio {
                    Some(pcm) if !*paused => {
                        let retained_pcm = pcm.clone();
                        send_message(
                            &mut write,
                            Message::Binary(pcm.into()),
                            "Soniox stream audio send",
                            timeouts.write,
                        ).await?;
                        recovery.record_sent(retained_pcm);
                    }
                    Some(_) => {
                        // Paused audio is deliberately not buffered or sent remotely.
                    }
                    None => {
                        audio_open = false;
                    }
                }
            }
            _ = &mut keepalive_sleep, if *paused && !draining => {
                send_control(&mut write, "keepalive", timeouts.write).await?;
                reset_sleep(&mut keepalive_sleep, timeouts.keepalive);
            }
            _ = &mut drain_sleep, if draining => {
                return Err(StreamFailure::timeout("Soniox stream drain", timeouts.drain));
            }
            _ = &mut receive_idle_sleep, if !draining && !*paused => {
                return Err(StreamFailure::timeout(
                    "Soniox stream response receive",
                    timeouts.receive_idle,
                ));
            }
            message = read.next() => {
                reset_sleep(&mut receive_idle_sleep, timeouts.receive_idle);
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let mut response: SonioxStreamResponse = serde_json::from_str(&text)
                            .map_err(|error| StreamFailure::protocol(error.to_string()))?;
                        if let Some(error_code) = response.error_code {
                            let error_type = canonical_soniox_error_type(
                                error_code,
                                response.error_type.as_deref(),
                            )
                            .to_string();
                            return Err(StreamFailure::provider(SttStreamProviderError {
                                error_code,
                                error_type,
                                error_message: "provider request failed".to_string(),
                                request_id: safe_soniox_request_id(response.request_id.as_deref()),
                            }));
                        }
                        if let Some(total_audio_proc_ms) = response.total_audio_proc_ms {
                            let final_audio_proc_ms = response.final_audio_proc_ms.unwrap_or(0);
                            let (acknowledged_ms, sent_lag_ms) =
                                recovery.acknowledge(total_audio_proc_ms);
                            let queued_lag_ms = (audio_rx.len() as u64).saturating_mul(100);
                            let lag_ms = sent_lag_ms.saturating_add(queued_lag_ms);
                            let final_audio_proc_ms = recovery
                                .connection_origin_ms
                                .saturating_add(final_audio_proc_ms)
                                .min(acknowledged_ms);
                            send_event(
                                event_tx,
                                SttStreamEvent::AudioProgress {
                                    final_audio_proc_ms,
                                    total_audio_proc_ms: acknowledged_ms,
                                    lag_ms,
                                },
                            )
                            .await?;
                        }
                        if suppress_replay_until_provider_ms > 0 {
                            let response_is_entirely_replayed = response
                                .total_audio_proc_ms
                                .is_some_and(|processed| {
                                    processed <= suppress_replay_until_provider_ms
                                });
                            if response_is_entirely_replayed {
                                response.tokens.clear();
                            } else {
                                let has_new_timed_source = response.tokens.iter().any(|token| {
                                    token.translation_status.as_deref() != Some("translation")
                                        && token.end_ms.is_some_and(|end_ms| {
                                            end_ms > suppress_replay_until_provider_ms
                                        })
                                });
                                response.tokens.retain(|token| {
                                    if token.translation_status.as_deref() == Some("translation") {
                                        has_new_timed_source
                                    } else {
                                        token.end_ms.is_none_or(|end_ms| {
                                            end_ms > suppress_replay_until_provider_ms
                                        })
                                    }
                                });
                            }
                            if response
                                .total_audio_proc_ms
                                .is_some_and(|processed| {
                                    processed >= suppress_replay_until_provider_ms
                                })
                            {
                                suppress_replay_until_provider_ms = 0;
                            }
                        }
                        emit_response_events(
                            event_tx,
                            response.tokens,
                            recovery.connection_origin_ms,
                        )
                        .await?;
                        if response.finished {
                            send_event(event_tx, SttStreamEvent::Finished).await?;
                            return Ok(());
                        }
                    }
                    Some(Ok(Message::Close(frame))) => {
                        let code = frame.map(|frame| frame.code.into());
                        return Err(StreamFailure::closed(code));
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        return Err(StreamFailure::transport(
                            "Soniox stream response receive",
                            error.to_string(),
                        ));
                    }
                    None => {
                        return Err(StreamFailure::closed(None));
                    }
                }
            }
        }
    }
}

enum ReconnectWait {
    Retry,
    Cancelled,
    Finish,
}

async fn wait_for_reconnect(
    delay: Duration,
    control_rx: &mut mpsc::Receiver<SttStreamControl>,
    cancel: CancellationToken,
    paused: &mut bool,
) -> ReconnectWait {
    let sleep = time::sleep(delay);
    tokio::pin!(sleep);
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return ReconnectWait::Cancelled,
            control = control_rx.recv() => {
                match control {
                    Some(SttStreamControl::Pause) => *paused = true,
                    Some(SttStreamControl::Resume) => *paused = false,
                    Some(SttStreamControl::Finish) | None => return ReconnectWait::Finish,
                    Some(SttStreamControl::Finalize | SttStreamControl::Keepalive) => {}
                }
            }
            _ = &mut sleep => return ReconnectWait::Retry,
        }
    }
}

fn reconnect_delay(base: Duration, attempt: u8) -> Duration {
    base.saturating_mul(1_u32 << u32::from(attempt.saturating_sub(1)))
}

fn build_stream_config(api_key: &str, config: &SttConfig) -> SonioxStreamConfig {
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    let language_hints_strict = config.language_hints_strict.then_some(true);
    let enable_language_identification =
        (config.enable_language_identification || config.language_hints.is_empty()).then_some(true);
    SonioxStreamConfig {
        api_key: api_key.to_string(),
        model: engine.realtime_model_id.to_string(),
        audio_format: engine.audio_format.to_string(),
        sample_rate: engine.sample_rate,
        num_channels: engine.channels,
        language_hints: config.language_hints.clone(),
        language_hints_strict,
        enable_language_identification,
        enable_speaker_diarization: config.enable_speaker_diarization.then_some(true),
        enable_endpoint_detection: Some(true),
        endpoint_latency_adjustment_level: Some(config.endpoint_latency_adjustment_level),
        endpoint_sensitivity: Some(config.endpoint_sensitivity),
        max_endpoint_delay_ms: Some(config.resolved_max_endpoint_delay_ms()),
        context: build_stream_context(config.context.as_ref()),
        translation: config
            .translation
            .as_ref()
            .map(|translation| match translation {
                TranslationConfig::OneWay { target_language } => SonioxTranslation::OneWay {
                    target_language: target_language.clone(),
                },
                TranslationConfig::TwoWay {
                    language_a,
                    language_b,
                } => SonioxTranslation::TwoWay {
                    language_a: language_a.clone(),
                    language_b: language_b.clone(),
                },
            }),
        client_reference_id: config.client_reference_id.clone(),
    }
}

fn build_stream_context(context: Option<&ContextConfig>) -> Option<SonioxStreamContext> {
    let context = context?;
    let general = context
        .general
        .iter()
        .map(|(key, value)| SonioxStreamContextEntry {
            key: key.clone(),
            value: value.clone(),
        })
        .collect::<Vec<_>>();
    let text = context.text.clone().filter(|value| !value.is_empty());
    let terms = context.terms.clone();
    let translation_terms = context
        .translation_terms
        .iter()
        .map(|(source, target)| SonioxStreamTranslationTerm {
            source: source.clone(),
            target: target.clone(),
        })
        .collect::<Vec<_>>();
    if general.is_empty() && text.is_none() && terms.is_empty() && translation_terms.is_empty() {
        None
    } else {
        Some(SonioxStreamContext {
            translation_terms,
            terms,
            general,
            text,
        })
    }
}

/// Canonical JSON placed under the WebSocket configuration's `context` key.
/// The FFI layer uses this to prove that a confirmed Context Pack preview is
/// byte-for-byte identical to the provider-bound value before any egress.
pub fn soniox_stream_context_json(context: &ContextConfig) -> Result<Option<String>, SttError> {
    build_stream_context(Some(context))
        .map(|wire| {
            serde_json::to_string(&wire).map_err(|error| SttError::ParseError(error.to_string()))
        })
        .transpose()
}

/// `connection_origin_ms` is where the current WebSocket's own audio clock sits
/// on the capture-wide timeline. A replacement session numbers its audio from
/// zero, so without this projection a lane's token timestamps jump backwards the
/// moment it reconnects — and one lane's timestamps drifting out of step with
/// its siblings' is the stated reason multilingual capture fails the whole
/// stream group closed rather than reconnecting a single lane.
///
/// The replay filter above this call compares against connection-relative
/// positions, so the projection has to happen after it, not before.
async fn emit_response_events(
    event_tx: &mpsc::Sender<SttStreamEvent>,
    tokens: Vec<SonioxStreamTokenWire>,
    connection_origin_ms: u64,
) -> Result<(), StreamFailure> {
    let mut batch = Vec::new();
    let mut control_events = Vec::new();
    for mut token in tokens {
        // Translation tokens carry no timestamps at all; `None` stays `None`.
        token.start_ms = token
            .start_ms
            .map(|start_ms| start_ms.saturating_add(connection_origin_ms));
        token.end_ms = token
            .end_ms
            .map(|end_ms| end_ms.saturating_add(connection_origin_ms));
        let control_event = match token.text.as_str() {
            "<end>" => Some(SttStreamEvent::Endpoint),
            "<fin>" => Some(SttStreamEvent::Finalized),
            _ => None,
        };
        if let Some(control_event) = control_event {
            // A Soniox response is one atomic revision. Translation tokens may
            // follow `<end>` in the same JSON response and still belong to the
            // source tokens before it. Deliver every content token first so
            // consumers cannot finalize and discard the source segment before
            // its translation arrives.
            control_events.push(control_event);
        } else {
            batch.push(token.into());
        }
    }
    if !batch.is_empty() {
        send_event(event_tx, SttStreamEvent::Tokens(batch)).await?;
    }
    for control_event in control_events {
        send_event(event_tx, control_event).await?;
    }
    Ok(())
}

async fn send_event(
    event_tx: &mpsc::Sender<SttStreamEvent>,
    event: SttStreamEvent,
) -> Result<(), StreamFailure> {
    event_tx.send(event).await.map_err(|_| StreamFailure {
        task_error: SttError::Cancelled,
        event_error: SttStreamError::Transport {
            operation: "Soniox stream event delivery".to_string(),
            message: "event receiver closed".to_string(),
        },
    })
}

async fn send_control<S>(
    write: &mut S,
    control_type: &'static str,
    timeout: Duration,
) -> Result<(), StreamFailure>
where
    S: futures::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let payload = serde_json::to_string(&ControlMessage { control_type })
        .map_err(|error| StreamFailure::protocol(error.to_string()))?;
    send_message(
        write,
        Message::Text(payload.into()),
        "Soniox stream control send",
        timeout,
    )
    .await
}

async fn drain_queued_audio<S>(
    write: &mut S,
    audio_rx: &mut mpsc::Receiver<Vec<u8>>,
    timeout: Duration,
) -> Result<(), StreamFailure>
where
    S: futures::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    while let Ok(pcm) = audio_rx.try_recv() {
        send_message(
            write,
            Message::Binary(pcm.into()),
            "Soniox stream queued audio fence",
            timeout,
        )
        .await?;
    }
    Ok(())
}

async fn send_message<S>(
    write: &mut S,
    message: Message,
    operation: &str,
    timeout: Duration,
) -> Result<(), StreamFailure>
where
    S: futures::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    time::timeout(timeout, write.send(message))
        .await
        .map_err(|_| StreamFailure::timeout(operation, timeout))?
        .map_err(|error| StreamFailure::transport(operation, error.to_string()))
}

async fn begin_drain<S>(
    write: &mut S,
    draining: &mut bool,
    drain_sleep: &mut std::pin::Pin<Box<Sleep>>,
    timeouts: StreamTimeouts,
) -> Result<(), StreamFailure>
where
    S: futures::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    if !*draining {
        send_message(
            write,
            Message::Text(String::new().into()),
            "Soniox stream finish send",
            timeouts.write,
        )
        .await?;
        *draining = true;
        reset_sleep(drain_sleep, timeouts.drain);
    }
    Ok(())
}

fn reset_sleep(sleep: &mut std::pin::Pin<Box<Sleep>>, duration: Duration) {
    sleep.as_mut().reset(Instant::now() + duration);
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::{SinkExt, StreamExt};
    use serde_json::{json, Value};
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;

    fn short_timeouts() -> StreamTimeouts {
        StreamTimeouts {
            connect: Duration::from_millis(200),
            write: Duration::from_millis(200),
            receive_idle: Duration::from_secs(1),
            keepalive: Duration::from_millis(25),
            drain: Duration::from_millis(40),
            reconnect_base_delay: Duration::from_millis(10),
            reconnect_max_attempts: 3,
        }
    }

    #[tokio::test]
    async fn pause_finalizes_then_sends_periodic_keepalive() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (message_tx, mut message_rx) = mpsc::channel::<Value>(8);
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            while let Some(Ok(message)) = read.next().await {
                match message {
                    Message::Text(text) if text.is_empty() => {
                        write
                            .send(Message::Text(
                                json!({"tokens": [], "finished": true}).to_string().into(),
                            ))
                            .await
                            .unwrap();
                        break;
                    }
                    Message::Text(text) => {
                        let value = serde_json::from_str(&text).unwrap();
                        message_tx.send(value).await.unwrap();
                    }
                    _ => {}
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        let _config = message_rx.recv().await.unwrap();

        runtime.send_control(SttStreamControl::Pause).await.unwrap();
        assert_eq!(
            message_rx.recv().await.unwrap(),
            json!({"type": "finalize"})
        );
        assert_eq!(
            message_rx.recv().await.unwrap(),
            json!({"type": "keepalive"})
        );
        assert_eq!(
            message_rx.recv().await.unwrap(),
            json!({"type": "keepalive"})
        );

        runtime
            .send_control(SttStreamControl::Resume)
            .await
            .unwrap();
        assert!(time::timeout(Duration::from_millis(40), message_rx.recv())
            .await
            .is_err());
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Finished)
        );
        assert!(runtime.task.await.unwrap().is_ok());
    }

    #[tokio::test]
    async fn silent_server_does_not_trip_response_idle_while_keepalive_writes_succeed() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            while let Some(Ok(message)) = read.next().await {
                if matches!(message, Message::Text(ref text) if text.is_empty()) {
                    write
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
            }
        });

        let timeouts = StreamTimeouts {
            receive_idle: Duration::from_millis(35),
            keepalive: Duration::from_millis(10),
            ..short_timeouts()
        };
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            timeouts,
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        runtime.send_control(SttStreamControl::Pause).await.unwrap();
        time::sleep(Duration::from_millis(90)).await;
        assert!(
            !runtime.task.is_finished(),
            "successful keepalive writes keep a paused stream healthy without provider tokens"
        );
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Finished)
        );
        assert!(runtime.task.await.unwrap().is_ok());
    }

    #[tokio::test]
    async fn finish_times_out_when_server_never_sends_finished() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let ws = accept_async(stream).await.unwrap();
            let (_write, mut read) = ws.split();
            while let Some(Ok(message)) = read.next().await {
                if matches!(message, Message::Text(ref text) if text.is_empty()) {
                    time::sleep(Duration::from_secs(1)).await;
                    break;
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let Some(SttStreamEvent::Error(SttStreamError::Timeout {
            operation,
            elapsed_ms,
        })) = runtime.event_rx.recv().await
        else {
            panic!("expected drain timeout event");
        };
        assert_eq!(operation, "Soniox stream drain");
        assert_eq!(elapsed_ms, 40);
        assert!(matches!(
            runtime.task.await.unwrap(),
            Err(SttError::Timeout { operation, .. }) if operation == "Soniox stream drain"
        ));
    }

    #[tokio::test]
    async fn retryable_disconnect_reconnects_and_flushes_queued_audio() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (second_session_audio_tx, mut second_session_audio_rx) = mpsc::channel::<Vec<u8>>(1);
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            first_ws.close(None).await.unwrap();

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(pcm) => {
                        second_session_audio_tx.send(pcm.to_vec()).await.unwrap();
                        second_ws
                            .send(Message::Text(
                                json!({
                                    "tokens": [{
                                        "text": "恢复",
                                        "is_final": true,
                                        "language": "zh"
                                    }]
                                })
                                .to_string()
                                .into(),
                            ))
                            .await
                            .unwrap();
                    }
                    Message::Text(text) if text.is_empty() => {
                        second_ws
                            .send(Message::Text(
                                json!({"tokens": [], "finished": true}).to_string().into(),
                            ))
                            .await
                            .unwrap();
                        break;
                    }
                    _ => {}
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Reconnecting {
                attempt: 1,
                delay_ms: 10,
            })
        );

        let buffered_audio = vec![7_u8; 3_200];
        runtime.push_pcm(buffered_audio.clone()).await.unwrap();
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::RecoveryStarted { outage_ms }) if outage_ms <= 15_000
        ));
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::AudioProgress { lag_ms, .. }) if lag_ms <= 15_000
        ));
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        assert_eq!(second_session_audio_rx.recv().await, Some(buffered_audio));
        let Some(SttStreamEvent::Tokens(tokens)) = runtime.event_rx.recv().await else {
            panic!("replacement session tokens missing");
        };
        assert_eq!(tokens[0].text, "恢复");

        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Finished)
        );
        assert!(runtime.task.await.unwrap().is_ok());
    }

    /// A replacement WebSocket numbers its own audio from zero, so the token
    /// timestamps it reports are connection-relative. Both `AudioProgress` and
    /// tokens are projected back onto the capture-wide timeline through
    /// `connection_origin_ms`, so a lane's timestamps stay comparable with its
    /// siblings' across a reconnect.
    ///
    /// Sibling connections fed byte-identical audio agree on a word's position
    /// to within one PCM block (measured: p95 = 0 ms, max 180 ms over eight
    /// minutes), and this is what keeps that true after a reconnect.
    #[tokio::test]
    async fn reconnected_tokens_are_projected_onto_the_capture_wide_timeline() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            // Five seconds of audio accepted and acknowledged, then the
            // connection drops.
            let mut accepted_chunks = 0;
            while let Some(Ok(message)) = first_ws.next().await {
                if matches!(message, Message::Binary(_)) {
                    accepted_chunks += 1;
                    if accepted_chunks == 50 {
                        break;
                    }
                }
            }
            first_ws
                .send(Message::Text(
                    json!({
                        "tokens": [{
                            "text": "前",
                            "is_final": true,
                            "language": "zh",
                            "start_ms": 4_000,
                            "end_ms": 4_500
                        }],
                        "final_audio_proc_ms": 5_000,
                        "total_audio_proc_ms": 5_000
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
            first_ws.close(None).await.unwrap();

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            // The replacement session restarts its own clock at the replay
            // point, so 2_500 here is 3_000 + 2_500 on the capture timeline.
            let mut answered = false;
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(_) if !answered => {
                        answered = true;
                        second_ws
                            .send(Message::Text(
                                json!({
                                    "tokens": [{
                                        "text": "后",
                                        "is_final": true,
                                        "language": "zh",
                                        "start_ms": 2_500,
                                        "end_ms": 2_600
                                    }],
                                    "final_audio_proc_ms": 2_600,
                                    "total_audio_proc_ms": 2_600
                                })
                                .to_string()
                                .into(),
                            ))
                            .await
                            .unwrap();
                    }
                    Message::Text(text) if text.is_empty() => {
                        second_ws
                            .send(Message::Text(
                                json!({"tokens": [], "finished": true}).to_string().into(),
                            ))
                            .await
                            .unwrap();
                        break;
                    }
                    _ => {}
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            short_timeouts(),
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }

        let mut source_start_ms = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            if let SttStreamEvent::Tokens(tokens) = event {
                source_start_ms.extend(tokens.iter().filter_map(|token| token.start_ms));
            }
            if source_start_ms.len() >= 2 {
                break;
            }
        }

        assert_eq!(
            source_start_ms,
            vec![4_000, 5_500],
            "the replacement session's 2_500 ms token must be reported at \
             connection_origin_ms (3_000) + 2_500 on the capture timeline"
        );
    }

    #[tokio::test]
    async fn quota_failure_is_not_retried() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = ws.next().await else {
                panic!("configuration missing");
            };
            ws.send(Message::Text(
                json!({
                    "error_code": 402,
                    "error_type": "quota_exhausted",
                    "request_id": "safe-request"
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            "key",
            SttConfig::default(),
            CancellationToken::new(),
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Error(SttStreamError::Provider(
                SttStreamProviderError {
                    error_code: 402,
                    ..
                }
            )))
        ));
        assert!(matches!(
            runtime.task.await.unwrap(),
            Err(SttError::QuotaExhausted { .. })
        ));
    }

    #[test]
    fn production_drain_limit_is_five_seconds() {
        assert_eq!(StreamTimeouts::default().drain, Duration::from_secs(5));
    }

    #[test]
    fn endpoint_overrides_are_serialized_without_changing_the_balanced_defaults() {
        let config = SttConfig {
            endpoint_latency_adjustment_level: 2,
            endpoint_sensitivity: -0.25,
            endpoint_delay_ms: Some(1_250),
            ..Default::default()
        };
        let wire = serde_json::to_value(build_stream_config("key", &config)).unwrap();
        assert_eq!(wire["enable_endpoint_detection"], true);
        assert_eq!(wire["endpoint_latency_adjustment_level"], 2);
        assert_eq!(wire["endpoint_sensitivity"], -0.25);
        assert_eq!(wire["max_endpoint_delay_ms"], 1_250);

        let balanced =
            serde_json::to_value(build_stream_config("key", &SttConfig::default())).unwrap();
        assert_eq!(balanced["endpoint_latency_adjustment_level"], 0);
        assert_eq!(balanced["endpoint_sensitivity"], 0.0);
        assert_eq!(balanced["max_endpoint_delay_ms"], 2_000);
    }

    #[test]
    fn one_way_translation_serializes_exact_target_without_two_way_fields() {
        let config = SttConfig {
            language_hints: vec!["en".into(), "zh".into(), "th".into()],
            enable_language_identification: true,
            enable_speaker_diarization: true,
            translation: Some(TranslationConfig::OneWay {
                target_language: "en".into(),
            }),
            ..Default::default()
        };
        let wire = serde_json::to_value(build_stream_config("key", &config)).unwrap();
        assert_eq!(wire["language_hints"], json!(["en", "zh", "th"]));
        assert_eq!(wire["enable_language_identification"], true);
        assert_eq!(wire["enable_speaker_diarization"], true);
        assert_eq!(
            wire["translation"],
            json!({"type": "one_way", "target_language": "en"})
        );
        assert!(wire["translation"].get("language_a").is_none());
        assert!(wire["translation"].get("language_b").is_none());
    }

    #[test]
    fn context_wire_payload_preserves_confirmed_values_and_canonical_order() {
        let context = ContextConfig {
            translation_terms: vec![("Zulangue".into(), "语音工具".into())],
            terms: vec!["  exact spacing  ".into()],
            general: vec![("project".into(), "  Sample Project  ".into())],
            text: Some(" leading and trailing ".into()),
        };
        let wire = build_stream_context(Some(&context)).unwrap();
        assert_eq!(
            serde_json::to_string(&wire).unwrap(),
            r#"{"translation_terms":[{"source":"Zulangue","target":"语音工具"}],"terms":["  exact spacing  "],"general":[{"key":"project","value":"  Sample Project  "}],"text":" leading and trailing "}"#
        );
        assert_eq!(
            soniox_stream_context_json(&context).unwrap(),
            Some(serde_json::to_string(&wire).unwrap())
        );
    }

    #[test]
    fn provider_progress_keeps_two_seconds_for_short_reconnect_replay() {
        let mut recovery = StreamRecoveryState::default();
        for _ in 0..50 {
            recovery.record_sent(vec![0; 3_200]);
        }
        let (acknowledged_ms, lag_ms) = recovery.acknowledge(5_000);
        assert_eq!(acknowledged_ms, 5_000);
        assert_eq!(lag_ms, 0);

        let replay = recovery.prepare_replay(Duration::from_secs(1));
        assert_eq!(recovery.connection_origin_ms, 3_000);
        assert_eq!(recovery.replay_duplicate_until_provider_ms(), 2_000);
        assert_eq!(replay.len(), 20);
    }

    #[test]
    fn outage_over_fifteen_seconds_starts_without_replay() {
        let mut recovery = StreamRecoveryState::default();
        for _ in 0..50 {
            recovery.record_sent(vec![0; 3_200]);
        }
        recovery.acknowledge(4_000);

        assert!(!recovery
            .prepare_replay(Duration::from_millis(15_001))
            .iter()
            .any(|_| true));
        assert_eq!(recovery.connection_origin_ms, 5_000);
        assert_eq!(recovery.acknowledged_ms, 5_000);
    }
}
