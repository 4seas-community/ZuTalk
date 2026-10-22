//! Ordered Soniox v5 streaming protocol for Notebook capture.
//!
//! Realtime Notebook capture retains the provider response shape because translation tokens do
//! not carry timestamps. The separate post-stop transcription adapter projects source tokens into
//! [`vt_model::Token`], whose timestamps are mandatory; it is not used by the live bilingual UI.

use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::Arc;
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
/// Exponential backoff stops doubling here: 1s, 2s, 4s, then 8s forever.
/// Retries are bounded by the outage budget (or unbounded in production),
/// not by attempt count, so the ceiling is what keeps a long outage from
/// backing off into minutes-long silences once the network returns.
const RECONNECT_MAX_DELAY_EXPONENT: u32 = 3;
const CONTINUITY_WINDOW: Duration = Duration::from_secs(15);
const FAST_RECONNECT_WINDOW: Duration = Duration::from_secs(5);
const REPLAY_OVERLAP: Duration = Duration::from_secs(2);
/// How many times real time a lane sends what queued during an outage too
/// long to resume at once. Live audio keeps arriving at one times real time,
/// so the backlog shrinks at one times real time: a fifteen-second outage is
/// caught up in fifteen seconds.
const CATCH_UP_SPEED: u32 = 2;
const PCM_BYTES_PER_MILLISECOND: u64 = 32;

// The macOS capture tap forwards approximately one 100 ms, 3,200-byte PCM
// block at a time. This queue rides out the short-outage window whose audio
// is still worth sending to the replacement connection; once an outage
// outlives CONTINUITY_WINDOW the reconnect wait sheds incoming PCM instead
// (the local encrypted journal stays authoritative), so an arbitrarily long
// outage can never fill this channel into FFI audio backpressure.
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
        /// The connection ended at a session-length cap, not in a failure:
        /// the lane is healthy and is moving to a fresh connection at once.
        /// Nothing about it is worth telling the user unless the replacement
        /// fails to come up, which arrives as an unplanned reconnect.
        planned: bool,
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
    /// How long one outage may keep retrying before the lane fails.
    ///
    /// `None` — production — never gives up on a retryable failure: local
    /// capture owns the recording's lifetime, so the remote lane's only jobs
    /// are to come back when the network does and to stop when told. Terminal
    /// refusals (auth, spent invite, protocol) still fail immediately; a
    /// credential source that keeps refusing is an ending, not an outage.
    reconnect_outage_budget: Option<Duration>,
    /// How far the provider may fall behind the audio this lane has sent
    /// before the lane cuts the connection and rejoins at the live edge.
    ///
    /// Once the backlog passes the continuity window a reconnect could not
    /// replay it anyway, so the stream is by definition no longer
    /// continuable; waiting longer only turns a bounded skip into a dead
    /// lane once the bounded audio channel behind it fills. Subtitles that
    /// are a minute late are not live captions — a hole drawn as a hole
    /// beats text that silently trails the room.
    live_edge_max_backlog: Duration,
    /// See [`IMMEDIATE_ROLLOVER_MIN_SESSION`].
    immediate_rollover_min_session: Duration,
    /// How long before a known session cap the lane starts waiting for a
    /// pause to hand over at. Never more than a quarter of the cap.
    handover_lead: Duration,
    /// How long before the cap the lane hands over whether or not a pause
    /// came. Never more than a tenth of the cap.
    handover_deadline_margin: Duration,
    /// An outage up to this long replays and resumes at once; a longer one
    /// catches up at a measured pace. See [`FAST_RECONNECT_WINDOW`].
    fast_reconnect_window: Duration,
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
            reconnect_outage_budget: None,
            live_edge_max_backlog: CONTINUITY_WINDOW,
            immediate_rollover_min_session: IMMEDIATE_ROLLOVER_MIN_SESSION,
            handover_lead: HANDOVER_LEAD,
            handover_deadline_margin: HANDOVER_DEADLINE_MARGIN,
            fast_reconnect_window: FAST_RECONNECT_WINDOW,
        }
    }
}

struct StreamFailure {
    task_error: SttError,
    event_error: SttStreamError,
    /// The retryable ending was chosen by this lane on purpose: it had
    /// outrun its provider past the replay window, so the reconnect must
    /// rejoin at the live edge instead of replaying, whatever the wall
    /// clock says about the outage.
    skips_to_live_edge: bool,
    /// Whether this ending is a session-length cap rather than a failure.
    rollover: Rollover,
}

/// How a retryable ending relates to the provider's session-length cap.
/// Either kind is a healthy lane changing connections, so the next one opens
/// at once rather than after a backoff that would only add audio to replay.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Rollover {
    /// Not a cap: an outage, a refusal, a protocol fault.
    None,
    /// The provider cut the connection at its cap. What it had not finalized
    /// is committed as it stood and the audio after it is replayed onto the
    /// next connection — which re-hears up to the replay overlap twice.
    AtCap,
    /// The lane ended the connection itself at a pause before the cap and
    /// the provider confirmed every token final. The next connection starts
    /// at the live edge with nothing to replay and nothing to re-hear.
    HandedOver,
}

impl StreamFailure {
    fn transport(operation: &str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            task_error: SttError::ConnectionFailed(format!("{operation}: {message}")),
            skips_to_live_edge: false,
            rollover: Rollover::None,
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
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Protocol { message },
        }
    }

    /// Soniox ended the connection because a session-length cap ran out:
    /// the `max_session_duration_seconds` a temporary key carries
    /// (403 `temp_api_key_session_expired`) or the provider's own fixed
    /// maximum (413 `max_duration_reached`).
    ///
    /// The 403 is the one that matters, and it is the reason this exists. A
    /// community invite key is capped at the reservation's wall-clock span,
    /// and the provider reports reaching it with an error frame whose status
    /// is the same 403 it uses for a key without permission. Read by status,
    /// the end of every invite recording's third hour was a refused key: the
    /// lane stopped for good and the app told the user their key had been
    /// rejected. The key was fine and so was the lane; the stream had simply
    /// reached the length that key was minted for. The cure is the one the
    /// provider prescribes — a new connection on a fresh credential — and the
    /// reconnect loop already knows how to continue the capture timeline
    /// across one.
    fn session_duration_cap(error_code: u16, request_id: Option<String>) -> Self {
        let reason = "provider ended the session at its duration cap".to_string();
        Self {
            task_error: SttError::ConnectionFailed(reason.clone()),
            skips_to_live_edge: false,
            rollover: Rollover::AtCap,
            event_error: SttStreamError::Provider(SttStreamProviderError {
                error_code,
                error_type: SESSION_DURATION_CAP_ERROR_TYPE.to_string(),
                error_message: reason,
                request_id,
            }),
        }
    }

    fn timeout(operation: &str, elapsed: Duration) -> Self {
        Self {
            task_error: SttError::Timeout {
                operation: operation.to_string(),
                elapsed,
            },
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Timeout {
                operation: operation.to_string(),
                elapsed_ms: elapsed.as_millis().try_into().unwrap_or(u64::MAX),
            },
        }
    }

    /// The lane ended its own connection at a pause shortly before the key's
    /// session cap, and the provider confirmed everything it had heard as
    /// final. This is the hand-over the provider recommends — "open a new
    /// connection before the cap" — and the clean one: nothing was cut off
    /// mid-word, so the next connection has nothing to replay.
    fn handed_over() -> Self {
        let reason = "lane handed over to a fresh connection before its session cap".to_string();
        Self {
            task_error: SttError::ConnectionFailed(reason.clone()),
            skips_to_live_edge: false,
            rollover: Rollover::HandedOver,
            event_error: SttStreamError::Closed { code: None, reason },
        }
    }

    /// A hand-over whose finish the provider never confirmed in time. The
    /// lane is still healthy; it rolls over the way a cap does, replaying
    /// whatever was not confirmed.
    fn handover_unconfirmed(elapsed: Duration) -> Self {
        let operation = "Soniox stream hand-over".to_string();
        Self {
            task_error: SttError::Timeout {
                operation: operation.clone(),
                elapsed,
            },
            skips_to_live_edge: false,
            rollover: Rollover::AtCap,
            event_error: SttStreamError::Timeout {
                operation,
                elapsed_ms: elapsed.as_millis().try_into().unwrap_or(u64::MAX),
            },
        }
    }

    /// Soniox sent `finished: true` while no local Finish was pending.
    ///
    /// The capture is still live, so whatever made the provider wrap up, this
    /// is a rollover boundary, not an ending: retryable, so the reconnect loop
    /// continues the same capture timeline on a fresh connection and
    /// credential. (A temporary key's `max_session_duration_seconds` was once
    /// assumed to end this way. Measured against the provider, it does not:
    /// it ends with an error frame — see [`Self::session_duration_cap`].)
    fn finished_midstream() -> Self {
        let reason = "provider finished the session while capture was live".to_string();
        Self {
            task_error: SttError::ConnectionFailed(reason.clone()),
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Closed { code: None, reason },
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
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Closed { code, reason },
        }
    }

    fn provider(error: SttStreamProviderError) -> Self {
        let task_error = provider_task_error(&error);
        Self {
            task_error,
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Provider(error),
        }
    }

    /// A connection could not be given a credential. A refused credential
    /// (invitation spent, budget gone, token revoked) is final; anything else
    /// is treated as transport so the normal reconnect backoff can ride out a
    /// brief outage of whatever issues the key.
    ///
    /// A credential source that has run out of time — an invitation with no
    /// quota left to cover the next stream — is reported apart from a refusal.
    /// It used to share the refusal's wording, so a partner whose time ran
    /// out was told their key had been rejected, and one whose key had been
    /// rejected was told their time might have run out.
    fn credential(error: SttError) -> Self {
        let message = format!("Soniox lane credential: {error}");
        if matches!(error, SttError::QuotaExhausted { .. }) {
            return Self {
                task_error: error,
                skips_to_live_edge: false,
                rollover: Rollover::None,
                event_error: SttStreamError::Provider(SttStreamProviderError {
                    error_code: 402,
                    error_type: CREDENTIAL_TIME_EXHAUSTED_ERROR_TYPE.to_string(),
                    error_message: message,
                    request_id: None,
                }),
            };
        }
        if error.is_auth_error() {
            return Self {
                task_error: error,
                skips_to_live_edge: false,
                rollover: Rollover::None,
                event_error: SttStreamError::Provider(SttStreamProviderError {
                    error_code: 401,
                    error_type: "unauthenticated".to_string(),
                    error_message: message,
                    request_id: None,
                }),
            };
        }
        Self {
            task_error: error,
            skips_to_live_edge: false,
            rollover: Rollover::None,
            event_error: SttStreamError::Transport {
                operation: "Soniox lane credential".to_string(),
                message,
            },
        }
    }

    /// This lane sent more audio than the provider has processed, past the
    /// point a reconnect could replay. Retryable — the lane is healthy, the
    /// provider is slow — but the reconnect must skip to the live edge: the
    /// backlog is unplayable by the same rule that bounds every replay.
    fn behind_live_edge(backlog: Duration) -> Self {
        let message = format!(
            "provider fell {}s behind the audio this lane sent",
            backlog.as_secs()
        );
        Self {
            task_error: SttError::ConnectionFailed(message.clone()),
            skips_to_live_edge: true,
            rollover: Rollover::None,
            event_error: SttStreamError::Transport {
                operation: "Soniox live-edge backlog".to_string(),
                message,
            },
        }
    }

    fn is_retryable(&self) -> bool {
        if self.rollover != Rollover::None {
            return true;
        }
        match &self.event_error {
            SttStreamError::Transport { .. } => true,
            SttStreamError::Timeout { operation, .. } => operation != "Soniox stream drain",
            SttStreamError::Closed { code, .. } => {
                !code.is_some_and(|code| matches!(code, 1008 | 4001 | 4003))
            }
            // `error_type` here is already the canonical vocabulary, so the
            // provider's own names for a duration cap never reach this match;
            // those endings are recognised from the raw frame and arrive as a
            // `rollover` instead.
            // 408 is the provider timing out on this connection — a stall,
            // which a fresh connection resumes like any outage.
            SttStreamError::Provider(error) => {
                matches!(error.error_code, 408 | 413 | 429 | 503)
                    || matches!(
                        error.error_type.as_str(),
                        "rate_limited" | "service_unavailable"
                    )
            }
            SttStreamError::Protocol { .. } => false,
        }
    }
}

/// The `error_type` a rollover is reported under in logs. Never persisted:
/// a rollover that succeeds is not a failure, and one whose replacement
/// cannot connect fails with that connection's own error.
const SESSION_DURATION_CAP_ERROR_TYPE: &str = "session_duration_cap";

/// The `error_type` persisted when a lane's credential source has no time
/// left to cover another connection: today, a community invitation whose
/// quota is spent. Distinct from any provider type so the app can say so in
/// those words rather than as a rejected key or a spent provider balance.
pub const CREDENTIAL_TIME_EXHAUSTED_ERROR_TYPE: &str = "invite_time_exhausted";

/// A key's session cap is known for invite keys. In the last minute before
/// it, the lane hands over to a fresh connection at the next pause — an
/// `<end>` endpoint, where every token is final — so the cap never cuts a
/// sentence and the seam re-hears nothing.
const HANDOVER_LEAD: Duration = Duration::from_secs(60);
/// No pause by this long before the cap: hand over anyway. Finishing still
/// makes every token final; the seam merely falls mid-sentence.
const HANDOVER_DEADLINE_MARGIN: Duration = Duration::from_secs(15);

/// Finds a quiet moment in the audio a lane sends, so a hand-over cuts
/// between words rather than through one.
///
/// The provider's own `<end>` endpoint is the best pause, but it can be a
/// long time coming: steady speech, or speech the provider keeps open, gave
/// none in the minute before a cap in testing, and a hand-over forced in the
/// middle of a word lost a syllable on each side of the cut. A single 100 ms
/// block well below the recent level is enough: speech drops by far more than
/// that between words and phrases. Steady noise with nobody speaking never
/// qualifies, and needs no pause — a cut through it costs nothing.
#[derive(Debug, Default)]
struct QuietBlockDetector {
    /// Slow-moving RMS of recent blocks (time constant about two seconds).
    level: f64,
}

/// A block at or below this fraction of the recent level (−20 dB) is quiet.
const QUIET_BLOCK_FRACTION: f64 = 0.1;
/// Or at or below this absolute RMS (about −50 dBFS): near-digital silence.
const QUIET_BLOCK_FLOOR: f64 = 100.0;

impl QuietBlockDetector {
    fn observe(&mut self, pcm: &[u8]) -> bool {
        let samples = pcm.len() / 2;
        if samples == 0 {
            return false;
        }
        let energy: f64 = pcm
            .chunks_exact(2)
            .map(|pair| {
                let sample = f64::from(i16::from_le_bytes([pair[0], pair[1]]));
                sample * sample
            })
            .sum();
        let rms = (energy / samples as f64).sqrt();
        let quiet = rms <= QUIET_BLOCK_FLOOR || rms <= self.level * QUIET_BLOCK_FRACTION;
        self.level = if self.level == 0.0 {
            rms
        } else {
            self.level * 0.95 + rms * 0.05
        };
        quiet
    }
}

/// When a connection whose key carries a session cap should hand over.
#[derive(Clone, Copy, Debug)]
struct HandoverSchedule {
    /// From here on, the next pause is where the lane hands over.
    watch_from: Instant,
    /// The lane hands over here even without a pause.
    hand_over_by: Instant,
}

impl HandoverSchedule {
    /// `dialed_at` is taken before the socket opens, so the provider's own
    /// clock — which starts at the session — can only be later.
    fn for_cap(dialed_at: Instant, cap: Duration, timeouts: StreamTimeouts) -> Self {
        let lead = timeouts.handover_lead.min(cap / 4);
        let margin = timeouts.handover_deadline_margin.min(cap / 10);
        let cap_at = dialed_at + cap;
        Self {
            watch_from: cap_at - lead,
            hand_over_by: cap_at - margin,
        }
    }
}

/// A connection that lived at least this long before the provider ended it
/// at a cap is rolled over at once. A cap reached sooner than this is not a
/// long recording reaching the end of a key — it is a key minted with almost
/// no time on it — and goes through the normal backoff, so a credential
/// source that keeps handing those out cannot spin the lane.
const IMMEDIATE_ROLLOVER_MIN_SESSION: Duration = Duration::from_secs(30);

/// Whether an error frame is the provider ending the session on a length
/// cap rather than refusing it. Decided on the provider's own `error_type`,
/// before it is folded into the canonical vocabulary: the key-cap ending
/// shares its 403 with a key that lacks permission, and only the type tells
/// them apart.
fn ends_at_session_duration_cap(error_code: u16, error_type: Option<&str>) -> bool {
    match error_type.map(str::trim) {
        Some("temp_api_key_session_expired") | Some("max_duration_reached") => true,
        Some(_) => false,
        None => error_code == 413,
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

/// A minted credential that never reached the provider.
///
/// A single-use key is spent when a connection presents it — which happens in
/// the configuration message, after the socket is up. A dial that fails never
/// gets that far, so its key is still redeemable and the next attempt must
/// reuse it rather than mint another.
///
/// This matters because the community invite service bounds a session by the
/// number of keys it issues. An outage is retried until it ends — dials at
/// up to one per backoff step, each minting before it dials — so minting per
/// dial would spend the whole key budget on one long blip while opening zero
/// streams: charging a budget meant to bound streams for attempts that were
/// never streams.
struct UnpresentedCredential {
    credential: LaneCredential,
    minted_at: Instant,
}

/// Shorter than the service's own 300-second expiry on a single-use key, so a
/// reused one is never a key the provider has already forgotten.
const UNPRESENTED_CREDENTIAL_REUSE_WINDOW: Duration = Duration::from_secs(240);

impl UnpresentedCredential {
    fn new(credential: LaneCredential) -> Self {
        Self {
            credential,
            minted_at: Instant::now(),
        }
    }

    fn into_still_redeemable(self) -> Option<LaneCredential> {
        (self.minted_at.elapsed() < UNPRESENTED_CREDENTIAL_REUSE_WINDOW).then_some(self.credential)
    }
}

#[derive(Debug, Default)]
struct StreamRecoveryState {
    next_audio_ms: u64,
    acknowledged_ms: u64,
    connection_origin_ms: u64,
    sent_frames: VecDeque<ReplayAudioFrame>,
    /// Where this connection's audio stood, in the provider's frame, at each
    /// finalize sent and not yet answered.
    finalize_marks: VecDeque<u64>,
    /// How far the provider's clock runs ahead of the audio sent, from which
    /// of its positions on. Soniox adds a little time of its own each time
    /// it finalizes — about a tenth of a second — and every position it
    /// reports afterwards carries all of it.
    provider_lead: Vec<(u64, u64)>,
}

impl StreamRecoveryState {
    /// A stream that begins partway through a recording. Every position this
    /// type reports is on the capture timeline, so all three clocks start
    /// where the stream does rather than at zero.
    fn starting_at(capture_origin_ms: u64) -> Self {
        Self {
            next_audio_ms: capture_origin_ms,
            acknowledged_ms: capture_origin_ms,
            connection_origin_ms: capture_origin_ms,
            sent_frames: VecDeque::new(),
            finalize_marks: VecDeque::new(),
            provider_lead: Vec::new(),
        }
    }

    /// A new connection: its clock starts again at zero, with nothing added.
    fn begin_provider_clock(&mut self) {
        self.finalize_marks.clear();
        self.provider_lead.clear();
    }

    /// A finalize went out after everything recorded as sent.
    fn note_finalize_sent(&mut self) {
        self.finalize_marks
            .push_back(self.next_audio_ms.saturating_sub(self.connection_origin_ms));
    }

    /// The provider answered the oldest finalize at `provider_total_ms`. All
    /// it heard was the audio sent before that finalize; the rest is time it
    /// added.
    fn note_finalize_answered(&mut self, provider_total_ms: u64) {
        let Some(sent_ms) = self.finalize_marks.pop_front() else {
            return;
        };
        let lead_ms = provider_total_ms.saturating_sub(sent_ms);
        if lead_ms > self.lead_at(provider_total_ms) {
            self.provider_lead.push((provider_total_ms, lead_ms));
        }
    }

    fn lead_at(&self, provider_ms: u64) -> u64 {
        self.provider_lead
            .iter()
            .rev()
            .find(|(from_ms, _)| *from_ms <= provider_ms)
            .map_or(0, |(_, lead_ms)| *lead_ms)
    }

    /// A provider position on the capture timeline.
    fn capture_ms(&self, provider_ms: u64) -> u64 {
        self.connection_origin_ms
            .saturating_add(provider_ms.saturating_sub(self.lead_at(provider_ms)))
    }

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
        self.drop_unreplayable_frames();
    }

    /// Audio too old to ever be replayed is audio we are only storing.
    ///
    /// Trimming otherwise happens solely on acknowledgement, which assumes the
    /// provider keeps reporting progress. A connection that stays open while
    /// `total_audio_proc_ms` stalls therefore retains every frame of the
    /// session — 32 KB per second of speech, so about 115 MB an hour, of PCM
    /// that no reconnect can use.
    ///
    /// The ceiling is not a new policy, it is the one already written down:
    /// [`prepare_replay`](Self::prepare_replay) abandons replay outright once
    /// an outage exceeds [`CONTINUITY_WINDOW`], and never replays from earlier
    /// than [`REPLAY_OVERLAP`] before the acknowledged point. Anything older
    /// than both is unreachable by construction.
    fn drop_unreplayable_frames(&mut self) {
        let horizon = (CONTINUITY_WINDOW + REPLAY_OVERLAP).as_millis() as u64;
        let Some(retain_from) = self.next_audio_ms.checked_sub(horizon) else {
            return;
        };
        while self
            .sent_frames
            .front()
            .is_some_and(|frame| frame.end_ms <= retain_from)
        {
            self.sent_frames.pop_front();
        }
    }

    fn acknowledge(&mut self, provider_total_ms: u64) -> (u64, u64) {
        let acknowledged = self.capture_ms(provider_total_ms).min(self.next_audio_ms);
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
            self.begin_provider_clock();
            return Vec::new();
        }
        let replay_from = self
            .acknowledged_ms
            .saturating_sub(REPLAY_OVERLAP.as_millis() as u64);
        self.connection_origin_ms = replay_from;
        self.begin_provider_clock();
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

    /// Audio dropped without ever reaching a provider still happened: its
    /// duration must advance the timeline, or every token after the drop is
    /// projected early by exactly the dropped span — the transcript would
    /// silently compress time and the recorded gap would read as covered.
    fn note_discarded(&mut self, pcm_len: usize) {
        let duration_ms = (pcm_len as u64).div_ceil(PCM_BYTES_PER_MILLISECOND).max(1);
        self.next_audio_ms = self.next_audio_ms.saturating_add(duration_ms);
    }

    /// Forgets everything unsent and unacknowledged and restarts the
    /// projection at the current live edge. Call after the queue has been
    /// drained and counted, so the edge includes what was just discarded.
    fn re_anchor_to_live_edge(&mut self) {
        self.sent_frames.clear();
        self.acknowledged_ms = self.next_audio_ms;
        self.connection_origin_ms = self.next_audio_ms;
        self.begin_provider_clock();
    }

    fn sent_backlog(&self) -> Duration {
        Duration::from_millis(self.next_audio_ms.saturating_sub(self.acknowledged_ms))
    }
}

/// Which tokens of a replacement connection repeat what the connection
/// before it already delivered.
///
/// A replacement hears the stretch before the acknowledged point again, for
/// context. Every word in that stretch is already written: the old
/// connection's finals were delivered, and its partials were confirmed when
/// it closed. So no word ending inside the replay may come back — not when
/// the provider first re-hears it, and not when it finalizes it, which can
/// be well after `total_audio_proc_ms` has passed the replay. Only
/// `final_audio_proc_ms` past the replay says the last of them is out.
///
/// Translation tokens carry no timestamps. Each follows the source words it
/// translates, so it repeats old work exactly when the source word before it
/// did — even when it arrives in a later response than that word.
#[derive(Debug, Default)]
struct ReplaySuppression {
    /// Connection-relative end of the replayed audio; zero when nothing was
    /// replayed and nothing is filtered.
    until_provider_ms: u64,
    /// Whether the last final source word was a replayed one.
    last_final_source_replayed: bool,
}

impl ReplaySuppression {
    fn after_replay(until_provider_ms: u64) -> Self {
        Self {
            until_provider_ms,
            // Before any source word arrives, all the connection has heard
            // is the replay.
            last_final_source_replayed: true,
        }
    }

    fn filter(
        &mut self,
        tokens: &mut Vec<SonioxStreamTokenWire>,
        final_audio_proc_ms: Option<u64>,
    ) {
        if self.until_provider_ms == 0 {
            return;
        }
        let until = self.until_provider_ms;
        // Finals come first in a response and the partial tail continues
        // after them, so one running state serves both; only the finals'
        // carries over to the next response.
        let mut last_final_replayed = self.last_final_source_replayed;
        let mut last_replayed = last_final_replayed;
        tokens.retain(|token| {
            if token.translation_status.as_deref() == Some("translation") {
                return !last_replayed;
            }
            let replayed = token.end_ms.is_some_and(|end_ms| end_ms <= until);
            last_replayed = replayed;
            if token.is_final {
                last_final_replayed = replayed;
            }
            !replayed
        });
        self.last_final_source_replayed = last_final_replayed;
        if final_audio_proc_ms.is_some_and(|processed| processed >= until)
            && !self.last_final_source_replayed
        {
            *self = Self::default();
        }
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

/// Supplies the credential for one WebSocket connection.
///
/// The stream asks once per connection attempt, including every reconnect.
/// A saved personal key answers from memory and never fails; a community
/// invitation answers with a single-use key fetched for that one connection,
/// so the reconnect loop stays a single code path either way.
pub trait LaneCredentialSource: Send + Sync {
    fn credential_for_connection(&self) -> BoxedCredentialFuture<'_>;
}

pub type BoxedCredentialFuture<'a> = std::pin::Pin<
    Box<dyn std::future::Future<Output = Result<LaneCredential, SttError>> + Send + 'a>,
>;

/// What one connection presents, and how long the provider will let it run.
#[derive(Clone, PartialEq, Eq)]
pub struct LaneCredential {
    pub api_key: String,
    /// The per-session cap minted into the key — a community invite key's
    /// `max_session_duration_seconds`. Known, it lets the lane hand over to a
    /// fresh connection at a pause shortly before the cap instead of being
    /// cut off by it. `None` for a saved personal key.
    pub session_cap: Option<Duration>,
}

impl LaneCredential {
    pub fn uncapped(api_key: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            session_cap: None,
        }
    }
}

// Deliberately redacted: the key is a live provider credential.
impl std::fmt::Debug for LaneCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LaneCredential")
            .field("api_key", &"<redacted>")
            .field("session_cap", &self.session_cap)
            .finish()
    }
}

/// The user's own saved key: one value, reused by every lane and reconnect.
pub struct StaticLaneCredential {
    api_key: String,
}

impl StaticLaneCredential {
    pub fn new(api_key: impl Into<String>) -> Arc<Self> {
        Arc::new(Self {
            api_key: api_key.into(),
        })
    }
}

impl LaneCredentialSource for StaticLaneCredential {
    fn credential_for_connection(&self) -> BoxedCredentialFuture<'_> {
        let api_key = self.api_key.clone();
        Box::pin(async move { Ok(LaneCredential::uncapped(api_key)) })
    }
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
        Self::start_with_credential(endpoint, StaticLaneCredential::new(api_key), config, cancel)
    }

    pub fn start_with_credential(
        endpoint: impl Into<String>,
        credential: Arc<dyn LaneCredentialSource>,
        config: SttConfig,
        cancel: CancellationToken,
    ) -> SonioxStreamRuntime {
        Self::start_with_timeouts(
            endpoint,
            credential,
            config,
            cancel,
            0,
            StreamTimeouts::default(),
        )
    }

    /// Starts a stream whose provider timeline is already `capture_origin_ms`
    /// into the recording.
    ///
    /// A stream's own reconnects keep the capture timeline because the client
    /// remembers where the current connection began. A *replacement* stream is
    /// a different object with no such memory, and one started at zero would
    /// report every token as if the recording had just begun — a translation
    /// lane replaced forty minutes in would file its cues against the opening
    /// minute. Telling it where it starts is what makes replacing a lane
    /// possible at all.
    pub fn start_at_capture_position(
        endpoint: impl Into<String>,
        credential: Arc<dyn LaneCredentialSource>,
        config: SttConfig,
        cancel: CancellationToken,
        capture_origin_ms: u64,
    ) -> SonioxStreamRuntime {
        Self::start_with_timeouts(
            endpoint,
            credential,
            config,
            cancel,
            capture_origin_ms,
            StreamTimeouts::default(),
        )
    }

    fn start_with_timeouts(
        endpoint: impl Into<String>,
        credential: Arc<dyn LaneCredentialSource>,
        config: SttConfig,
        cancel: CancellationToken,
        capture_origin_ms: u64,
        timeouts: StreamTimeouts,
    ) -> SonioxStreamRuntime {
        let (audio_tx, audio_rx) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
        let (control_tx, control_rx) = mpsc::channel(CONTROL_CHANNEL_CAPACITY);
        let (public_event_tx, event_rx) = mpsc::channel(EVENT_CHANNEL_CAPACITY);
        // The connection never waits on whoever consumes its events. It used
        // to: with the bounded channel full, the task sat in `send` instead of
        // reading the socket, the provider's progress went unread, and the
        // lane measured its own unread acknowledgements as the provider
        // falling behind — then cut itself to "rejoin the live edge", every
        // half minute, for as long as the consumer stayed slow. A relay now
        // owns the bounded hand-off; the connection only ever enqueues.
        let (event_tx, mut relay_rx) = mpsc::unbounded_channel::<SttStreamEvent>();
        tokio::spawn(async move {
            while let Some(event) = relay_rx.recv().await {
                if public_event_tx.send(event).await.is_err() {
                    break;
                }
            }
        });
        let endpoint = endpoint.into();
        let task = tokio::spawn(async move {
            match run_stream(
                &endpoint,
                credential.as_ref(),
                &config,
                audio_rx,
                control_rx,
                &event_tx,
                cancel,
                capture_origin_ms,
                timeouts,
            )
            .await
            {
                Ok(()) => Ok(()),
                Err(failure) => {
                    let _ = event_tx.send(SttStreamEvent::Error(failure.event_error));
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
    credential: &dyn LaneCredentialSource,
    config: &SttConfig,
    mut audio_rx: mpsc::Receiver<Vec<u8>>,
    mut control_rx: mpsc::Receiver<SttStreamControl>,
    event_tx: &mpsc::UnboundedSender<SttStreamEvent>,
    cancel: CancellationToken,
    capture_origin_ms: u64,
    timeouts: StreamTimeouts,
) -> Result<(), StreamFailure> {
    let mut paused = false;
    let mut reconnect_attempt = 0_u8;
    let mut disconnected_at = None::<Instant>;
    let mut recovery = StreamRecoveryState::starting_at(capture_origin_ms);
    let mut unpresented_credential: Option<UnpresentedCredential> = None;
    let mut skip_to_live_edge = false;
    let mut handed_over = false;
    // A stop heard while waiting to reconnect: the next connection sends
    // what is left and finishes at once.
    let mut finish_requested = false;
    loop {
        let mut session_connected = false;
        let reconnect_outage = disconnected_at.map(|started| started.elapsed());
        let reconnect_skips = std::mem::take(&mut skip_to_live_edge);
        let after_handover = std::mem::take(&mut handed_over);
        let session_started = Instant::now();
        match run_stream_session(
            endpoint,
            credential,
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
            reconnect_skips,
            after_handover,
            finish_requested,
            &mut unpresented_credential,
        )
        .await
        {
            Ok(()) => return Ok(()),
            Err(failure) if failure.is_retryable() => {
                skip_to_live_edge = failure.skips_to_live_edge;
                handed_over = failure.rollover == Rollover::HandedOver;
                if session_connected {
                    disconnected_at = Some(Instant::now());
                    reconnect_attempt = 0;
                } else {
                    disconnected_at.get_or_insert_with(Instant::now);
                }
                let outage_so_far = disconnected_at
                    .map(|started| started.elapsed())
                    .unwrap_or_default();
                if timeouts
                    .reconnect_outage_budget
                    .is_some_and(|budget| outage_so_far >= budget)
                {
                    tracing::error!(
                        outage_s = outage_so_far.as_secs(),
                        "Soniox lane gave up: outage outlived the reconnect budget"
                    );
                    return Err(failure);
                }
                reconnect_attempt = reconnect_attempt.saturating_add(1);
                let rolls_over_now = failure.rollover != Rollover::None
                    && session_connected
                    && session_started.elapsed() >= timeouts.immediate_rollover_min_session;
                let delay = if rolls_over_now {
                    Duration::ZERO
                } else {
                    reconnect_delay(timeouts.reconnect_base_delay, reconnect_attempt)
                };
                if rolls_over_now && failure.rollover == Rollover::HandedOver {
                    tracing::info!(
                        session_s = session_started.elapsed().as_secs(),
                        "Soniox session handed over before its cap; \
                         continuing on a fresh connection"
                    );
                } else if rolls_over_now {
                    tracing::info!(
                        session_s = session_started.elapsed().as_secs(),
                        error = ?failure.event_error,
                        "Soniox ended the session at its duration cap; \
                         continuing on a fresh connection"
                    );
                } else {
                    tracing::warn!(
                        attempt = reconnect_attempt,
                        outage_s = outage_so_far.as_secs(),
                        delay_ms = delay.as_millis() as u64,
                        error = ?failure.event_error,
                        "Soniox lane disconnected; retrying"
                    );
                }
                send_event(
                    event_tx,
                    SttStreamEvent::Reconnecting {
                        attempt: reconnect_attempt,
                        delay_ms: delay.as_millis().try_into().unwrap_or(u64::MAX),
                        planned: rolls_over_now,
                    },
                )
                .await?;
                // Once the outage has outlived the replay window the queued
                // PCM can never be sent (a burst past CONTINUITY_WINDOW is
                // abandoned on reconnect anyway), so shed it while waiting:
                // otherwise a long outage fills the bounded audio channel and
                // turns into FFI backpressure, which tombstones the lane the
                // moment this loop was finally about to save it.
                let shed_audio = outage_so_far > CONTINUITY_WINDOW || skip_to_live_edge;
                match wait_for_reconnect(
                    delay,
                    &mut audio_rx,
                    shed_audio,
                    &mut recovery,
                    &mut control_rx,
                    cancel.clone(),
                    &mut paused,
                    finish_requested,
                )
                .await
                {
                    ReconnectWait::Retry => {}
                    ReconnectWait::Cancelled => return Ok(()),
                    // The tail is still owed: the audio queued meanwhile and
                    // the words this outage left unconfirmed. Reconnect now
                    // rather than end the lane on the outage's error.
                    ReconnectWait::Finish => finish_requested = true,
                }
            }
            Err(failure) => return Err(failure),
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_stream_session(
    endpoint: &str,
    credential: &dyn LaneCredentialSource,
    config: &SttConfig,
    audio_rx: &mut mpsc::Receiver<Vec<u8>>,
    control_rx: &mut mpsc::Receiver<SttStreamControl>,
    event_tx: &mpsc::UnboundedSender<SttStreamEvent>,
    cancel: CancellationToken,
    timeouts: StreamTimeouts,
    paused: &mut bool,
    session_connected: &mut bool,
    recovery: &mut StreamRecoveryState,
    reconnect_outage: Option<Duration>,
    reconnect_skips_to_live_edge: bool,
    reconnect_after_handover: bool,
    finish_requested: bool,
    unpresented_credential: &mut Option<UnpresentedCredential>,
) -> Result<(), StreamFailure> {
    // Resolved before dialing: a single-use credential is spent the moment a
    // connection presents it, so a socket opened without one in hand would
    // burn a key on a connection that may never be configured.
    //
    // The converse is the reason for the carry-over: a dial that never
    // connects never presents its key, so that key is still redeemable and
    // the retry reuses it instead of minting a second one.
    let lane_credential = match unpresented_credential
        .take()
        .and_then(UnpresentedCredential::into_still_redeemable)
    {
        Some(lane_credential) => lane_credential,
        None => credential
            .credential_for_connection()
            .await
            .map_err(StreamFailure::credential)?,
    };

    let dialed_at = Instant::now();
    let connect = match time::timeout(timeouts.connect, connect_async(endpoint)).await {
        Err(_) => {
            *unpresented_credential = Some(UnpresentedCredential::new(lane_credential));
            return Err(StreamFailure::timeout(
                "Soniox stream connect",
                timeouts.connect,
            ));
        }
        Ok(Err(error)) => {
            *unpresented_credential = Some(UnpresentedCredential::new(lane_credential));
            return Err(StreamFailure::transport(
                "Soniox stream connect",
                error.to_string(),
            ));
        }
        Ok(Ok(connect)) => connect,
    };
    // Past this point the key either reaches the provider in the
    // configuration message or is lost with a socket that already opened.
    // Both count as spent; only an unopened socket returns a key to the pool.
    let (ws_stream, _) = connect;
    let (mut write, mut read) = ws_stream.split();

    let wire_config = build_stream_config(&lane_credential.api_key, config);
    let handover = lane_credential
        .session_cap
        .map(|cap| HandoverSchedule::for_cap(dialed_at, cap, timeouts));
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

    let mut replay_suppression = ReplaySuppression::default();
    let mut catch_up = CatchUp::default();
    // Whether this connection has carried any audio at all.
    let mut sent_audio = false;
    let clean_handover = reconnect_after_handover
        && reconnect_outage.is_some_and(|outage| outage <= CONTINUITY_WINDOW);
    if let (true, Some(outage)) = (clean_handover, reconnect_outage) {
        // The connection before this one confirmed every token final before
        // it closed, so there is nothing to replay and nothing to re-hear:
        // this connection simply starts where the last one stopped. The audio
        // that queued while it opened is ordinary live audio from here.
        recovery.re_anchor_to_live_edge();
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
    } else if let Some(outage) = reconnect_outage {
        // A lane that cut itself for outrunning the provider skips whatever
        // the wall clock says: the backlog it is skipping is the outage, and
        // it is over the continuity window by the rule that triggered the
        // cut. The reported span classifies the recovery as non-continuous
        // downstream, which is what makes the durable gap record appear.
        let outage = if reconnect_skips_to_live_edge {
            outage
                .max(recovery.sent_backlog())
                .max(CONTINUITY_WINDOW + Duration::from_millis(1))
        } else {
            outage
        };
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
        replay_suppression =
            ReplaySuppression::after_replay(recovery.replay_duplicate_until_provider_ms());
        if outage > timeouts.fast_reconnect_window && outage <= CONTINUITY_WINDOW {
            // Too much to send at once. The replay and then the queue go out
            // at a measured pace from the session loop below, which keeps
            // reading words and controls between blocks.
            catch_up.replay = replay.into_iter().map(|frame| frame.pcm).collect();
            catch_up.active = true;
        } else {
            for frame in replay {
                send_message(
                    &mut write,
                    Message::Binary(frame.pcm.into()),
                    "Soniox stream recovery audio send",
                    timeouts.write,
                )
                .await?;
                sent_audio = true;
            }
        }
        if outage > CONTINUITY_WINDOW {
            // The local encrypted journal remains authoritative for this
            // interval. Do not burst stale remote audio into the new,
            // explicitly non-contiguous realtime epoch — but every dropped
            // frame still advances the timeline, and the projection is
            // re-anchored only after the drain so the new origin is the true
            // live edge rather than a point the discarded audio's duration
            // short of it.
            while let Ok(pcm) = audio_rx.try_recv() {
                recovery.note_discarded(pcm.len());
            }
            recovery.re_anchor_to_live_edge();
        }
    } else {
        recovery.connection_origin_ms = recovery.next_audio_ms;
        recovery.begin_provider_clock();
    }
    if *paused {
        // A pause heard while there was no connection follows speech the
        // lane had already accepted. Send it and close the utterance, as
        // the pause would have on a live connection; the capture accepts no
        // audio while paused, so nothing queued is from the pause itself.
        sent_audio |= drain_queued_audio(
            &mut write,
            &mut catch_up,
            audio_rx,
            recovery,
            timeouts.write,
        )
        .await?;
        if sent_audio {
            send_control(&mut write, "finalize", timeouts.write).await?;
            recovery.note_finalize_sent();
        }
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
    // A key with a known cap is handed over before the provider ends it:
    // first at the next pause, then — no pause by the deadline — regardless.
    let mut handover_sleep = Box::pin(time::sleep_until(handover.map_or_else(
        || Instant::now() + far_future,
        |schedule| schedule.watch_from,
    )));
    let mut waiting_for_pause = false;
    let mut handing_over = false;
    let mut quiet_blocks = QuietBlockDetector::default();
    let mut catch_up_sleep = Box::pin(time::sleep(Duration::ZERO));
    if finish_requested {
        // Stop came while this lane was reconnecting; see `run_stream`.
        sent_audio |= drain_queued_audio(
            &mut write,
            &mut catch_up,
            audio_rx,
            recovery,
            timeouts.write,
        )
        .await?;
        if !sent_audio {
            send_event(event_tx, SttStreamEvent::Finished).await?;
            return Ok(());
        }
        begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts).await?;
    }

    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(()),
            control = control_rx.recv(), if control_open && !draining => {
                match control {
                    Some(SttStreamControl::Finalize) => {
                        sent_audio |=
                            drain_queued_audio(&mut write, &mut catch_up, audio_rx, recovery, timeouts.write).await?;
                        send_control(&mut write, "finalize", timeouts.write).await?;
                        recovery.note_finalize_sent();
                    }
                    Some(SttStreamControl::Pause) => {
                        // The FFI state lock prevents new pushes before Pause is
                        // enqueued. Flush every audio frame already accepted by
                        // `audio_tx` before the utterance boundary, otherwise the
                        // biased control branch would finalize ahead of speech.
                        sent_audio |=
                            drain_queued_audio(&mut write, &mut catch_up, audio_rx, recovery, timeouts.write).await?;
                        send_control(&mut write, "finalize", timeouts.write).await?;
                        recovery.note_finalize_sent();
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
                        sent_audio |=
                            drain_queued_audio(&mut write, &mut catch_up, audio_rx, recovery, timeouts.write).await?;
                        if !sent_audio {
                            // A connection that never carried audio has no
                            // tail to wait for, and the provider refuses to
                            // finish one (400 `invalid_request`). It happens
                            // when a hand-over falls in a pause and the
                            // recording stops before speech resumes.
                            send_event(event_tx, SttStreamEvent::Finished).await?;
                            return Ok(());
                        }
                        begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts).await?;
                    }
                }
            }
            // Responses before audio. Acknowledgements are what the live-edge
            // rule measures the provider by; a burst of queued audio used to be
            // sent in full before a single response was read, which counted
            // the lane's own unread socket as provider backlog.
            message = read.next() => {
                reset_sleep(&mut receive_idle_sleep, timeouts.receive_idle);
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let mut response: SonioxStreamResponse = serde_json::from_str(&text)
                            .map_err(|error| StreamFailure::protocol(error.to_string()))?;
                        if let Some(error_code) = response.error_code {
                            if ends_at_session_duration_cap(
                                error_code,
                                response.error_type.as_deref(),
                            ) {
                                return Err(StreamFailure::session_duration_cap(
                                    error_code,
                                    safe_soniox_request_id(response.request_id.as_deref()),
                                ));
                            }
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
                        #[cfg(debug_assertions)]
                        trace_provider_clock(config, recovery, &response);
                        if let Some(total_audio_proc_ms) = response.total_audio_proc_ms {
                            if response.tokens.iter().any(|token| token.text == "<fin>") {
                                recovery.note_finalize_answered(total_audio_proc_ms);
                            }
                            let final_audio_proc_ms = response.final_audio_proc_ms.unwrap_or(0);
                            let (acknowledged_ms, sent_lag_ms) =
                                recovery.acknowledge(total_audio_proc_ms);
                            let queued_lag_ms = (audio_rx.len() as u64).saturating_mul(100);
                            let lag_ms = sent_lag_ms.saturating_add(queued_lag_ms);
                            let final_audio_proc_ms = recovery
                                .capture_ms(final_audio_proc_ms)
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
                        replay_suppression
                            .filter(&mut response.tokens, response.final_audio_proc_ms);
                        let reached_pause = waiting_for_pause
                            && response.tokens.iter().any(|token| token.text == "<end>");
                        emit_response_events(event_tx, response.tokens, recovery)
                        .await?;
                        if response.finished {
                            if handing_over {
                                // Every token is final and the provider has
                                // heard all this lane sent. Not `Finished`:
                                // the capture is not ending, the connection is.
                                return Err(StreamFailure::handed_over());
                            }
                            if draining {
                                send_event(event_tx, SttStreamEvent::Finished).await?;
                                return Ok(());
                            }
                            // Tail tokens in this same response were already
                            // emitted above, so nothing said is lost across
                            // the rollover.
                            tracing::warn!(
                                "Soniox finished the session while capture was live; \
                                 rolling over to a replacement connection"
                            );
                            return Err(StreamFailure::finished_midstream());
                        }
                        if reached_pause && !draining {
                            // The pause the hand-over waited for. Finishing
                            // here makes the provider confirm the rest as
                            // final; audio from now on queues for the next
                            // connection.
                            tracing::info!(
                                "Soniox session cap is near; handing over at a pause"
                            );
                            if catch_up.active {
                                // What this connection was still catching
                                // up on is older than the cut; it is this
                                // connection's to finish.
                                sent_audio |= drain_queued_audio(
                                    &mut write,
                                    &mut catch_up,
                                    audio_rx,
                                    recovery,
                                    timeouts.write,
                                )
                                .await?;
                            }
                            begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts)
                                .await?;
                            handing_over = true;
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
            _ = &mut catch_up_sleep, if catch_up.active && !draining => {
                let (pcm, counted) = match catch_up.replay.pop_front() {
                    Some(pcm) => (Some(pcm), true),
                    None => (audio_rx.try_recv().ok(), false),
                };
                let Some(pcm) = pcm else {
                    // Caught up: from here audio is live again.
                    catch_up.active = false;
                    continue;
                };
                let block = Duration::from_millis(
                    (pcm.len() as u64).div_ceil(PCM_BYTES_PER_MILLISECOND).max(1),
                );
                let retained_pcm = (!counted).then(|| pcm.clone());
                send_message(
                    &mut write,
                    Message::Binary(pcm.into()),
                    "Soniox stream catch-up audio send",
                    timeouts.write,
                )
                .await?;
                if let Some(retained_pcm) = retained_pcm {
                    recovery.record_sent(retained_pcm);
                }
                sent_audio = true;
                catch_up_sleep
                    .as_mut()
                    .reset(Instant::now() + block / CATCH_UP_SPEED);
            }
            audio = audio_rx.recv(), if audio_open && !draining && !catch_up.active => {
                match audio {
                    Some(pcm) if !*paused => {
                        let quiet_block = quiet_blocks.observe(&pcm);
                        let retained_pcm = pcm.clone();
                        send_message(
                            &mut write,
                            Message::Binary(pcm.into()),
                            "Soniox stream audio send",
                            timeouts.write,
                        ).await?;
                        recovery.record_sent(retained_pcm);
                        sent_audio = true;
                        if waiting_for_pause && quiet_block {
                            // The block just sent was quiet: a cut here falls
                            // between words. Everything before it goes to
                            // this connection, everything after to the next.
                            tracing::info!(
                                "Soniox session cap is near; handing over at a quiet moment"
                            );
                            begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts)
                                .await?;
                            handing_over = true;
                            continue;
                        }
                        // The provider accepting bytes is not the provider
                        // keeping up. Once it is further behind than any
                        // reconnect could replay, this stream can no longer
                        // be continued — cut it now and rejoin at the live
                        // edge while the lane is still healthy, rather than
                        // waiting for the bounded channel behind it to fill
                        // and take the lane down for good.
                        let backlog = recovery.sent_backlog();
                        if backlog > timeouts.live_edge_max_backlog {
                            tracing::warn!(
                                backlog_s = backlog.as_secs(),
                                "Soniox lane outran its provider past the replay window; \
                                 skipping to the live edge"
                            );
                            return Err(StreamFailure::behind_live_edge(backlog));
                        }
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
                if handing_over {
                    return Err(StreamFailure::handover_unconfirmed(timeouts.drain));
                }
                return Err(StreamFailure::timeout("Soniox stream drain", timeouts.drain));
            }
            _ = &mut handover_sleep, if handover.is_some() && !draining => {
                if waiting_for_pause {
                    tracing::info!(
                        "Soniox session cap is near and no pause came; handing over now"
                    );
                    if catch_up.active {
                        sent_audio |= drain_queued_audio(
                            &mut write,
                            &mut catch_up,
                            audio_rx,
                            recovery,
                            timeouts.write,
                        )
                        .await?;
                    }
                    begin_drain(&mut write, &mut draining, &mut drain_sleep, timeouts).await?;
                    handing_over = true;
                } else if let Some(schedule) = handover {
                    waiting_for_pause = true;
                    handover_sleep.as_mut().reset(schedule.hand_over_by);
                }
            }
            _ = &mut receive_idle_sleep, if !draining && !*paused => {
                return Err(StreamFailure::timeout(
                    "Soniox stream response receive",
                    timeouts.receive_idle,
                ));
            }
        }
    }
}

enum ReconnectWait {
    Retry,
    Cancelled,
    Finish,
}

#[allow(clippy::too_many_arguments)]
async fn wait_for_reconnect(
    delay: Duration,
    audio_rx: &mut mpsc::Receiver<Vec<u8>>,
    shed_audio: bool,
    recovery: &mut StreamRecoveryState,
    control_rx: &mut mpsc::Receiver<SttStreamControl>,
    cancel: CancellationToken,
    paused: &mut bool,
    finishing: bool,
) -> ReconnectWait {
    let sleep = time::sleep(delay);
    tokio::pin!(sleep);
    let mut shed_ms = 0_u64;
    let mut audio_open = true;
    let result = loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break ReconnectWait::Cancelled,
            control = control_rx.recv(), if !finishing => {
                match control {
                    Some(SttStreamControl::Pause) => *paused = true,
                    Some(SttStreamControl::Resume) => *paused = false,
                    Some(SttStreamControl::Finish) | None => break ReconnectWait::Finish,
                    Some(SttStreamControl::Finalize | SttStreamControl::Keepalive) => {}
                }
            }
            audio = audio_rx.recv(), if shed_audio && audio_open => {
                match audio {
                    // Discarded, not sent later and not counted onto the
                    // provider timeline — the same treatment reconnect gives
                    // audio queued across an outage longer than
                    // CONTINUITY_WINDOW. The local journal keeps the interval;
                    // the durable transcript gap is recorded by the capture
                    // layer from its own frame counter.
                    Some(pcm) => {
                        shed_ms += (pcm.len() as u64)
                            .div_ceil(PCM_BYTES_PER_MILLISECOND)
                            .max(1);
                        // Shed audio still happened; see `note_discarded`.
                        recovery.note_discarded(pcm.len());
                    }
                    None => audio_open = false,
                }
            }
            _ = &mut sleep => break ReconnectWait::Retry,
        }
    };
    if shed_ms > 0 {
        tracing::warn!(
            shed_ms,
            "Soniox lane shed queued audio while reconnecting past the replay window"
        );
    }
    result
}

fn reconnect_delay(base: Duration, attempt: u8) -> Duration {
    let exponent = u32::from(attempt.saturating_sub(1)).min(RECONNECT_MAX_DELAY_EXPONENT);
    base.saturating_mul(1_u32 << exponent)
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

/// Positions go onto the capture-wide timeline through
/// [`StreamRecoveryState::capture_ms`]: `connection_origin_ms` is where the
/// current WebSocket's own audio clock sits on it, less the time the provider
/// added of its own at each finalize. A replacement session numbers its audio from
/// zero, so without this projection a lane's token timestamps jump backwards the
/// moment it reconnects — and one lane's timestamps drifting out of step with
/// its siblings' is the stated reason multilingual capture fails the whole
/// stream group closed rather than reconnecting a single lane.
///
/// The replay filter above this call compares against connection-relative
/// positions, so the projection has to happen after it, not before.
async fn emit_response_events(
    event_tx: &mpsc::UnboundedSender<SttStreamEvent>,
    tokens: Vec<SonioxStreamTokenWire>,
    recovery: &StreamRecoveryState,
) -> Result<(), StreamFailure> {
    let mut batch = Vec::new();
    let mut control_events = Vec::new();
    for mut token in tokens {
        // Translation tokens carry no timestamps at all; `None` stays `None`.
        token.start_ms = token.start_ms.map(|start_ms| recovery.capture_ms(start_ms));
        token.end_ms = token.end_ms.map(|end_ms| recovery.capture_ms(end_ms));
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
    event_tx: &mpsc::UnboundedSender<SttStreamEvent>,
    event: SttStreamEvent,
) -> Result<(), StreamFailure> {
    event_tx.send(event).map_err(|_| StreamFailure {
        task_error: SttError::Cancelled,
        skips_to_live_edge: false,
        rollover: Rollover::None,
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

/// What a lane still has to send after an outage too long to resume at once.
#[derive(Default)]
struct CatchUp {
    active: bool,
    /// Replayed blocks not yet sent; already counted on the timeline.
    replay: VecDeque<Vec<u8>>,
}

/// Debug builds only: the provider's own clock next to the audio this lane
/// sent, one JSON line per response, to the file `ZUTALK_LANE_TRACE` names.
#[cfg(debug_assertions)]
fn trace_provider_clock(
    config: &SttConfig,
    recovery: &StreamRecoveryState,
    response: &SonioxStreamResponse,
) {
    use std::io::Write;
    static TRACE: std::sync::OnceLock<Option<std::sync::Mutex<std::fs::File>>> =
        std::sync::OnceLock::new();
    let Some(file) = TRACE.get_or_init(|| {
        let path = std::env::var_os("ZUTALK_LANE_TRACE")?;
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .ok()
            .map(std::sync::Mutex::new)
    }) else {
        return;
    };
    let target = match config.translation.as_ref() {
        Some(TranslationConfig::OneWay { target_language }) => Some(target_language.clone()),
        _ => None,
    };
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default();
    let line = serde_json::json!({
        "at": at_ms,
        "kind": "provider_clock",
        "stream_target": target,
        "origin": recovery.connection_origin_ms,
        "sent": recovery.next_audio_ms,
        "provider_total": response.total_audio_proc_ms,
        "provider_final": response.final_audio_proc_ms,
        "fin": response.tokens.iter().any(|token| token.text == "<fin>"),
        "end": response.tokens.iter().any(|token| token.text == "<end>"),
    });
    if let Ok(mut file) = file.lock() {
        let _ = writeln!(file, "{line}");
    }
}

/// Sends every queued block. Returns whether there was any.
///
/// Every block goes onto the lane's own timeline and into the replay
/// buffer, exactly as one sent from the audio branch does: the provider
/// heard it, and its clock counts it.
async fn drain_queued_audio<S>(
    write: &mut S,
    catch_up: &mut CatchUp,
    audio_rx: &mut mpsc::Receiver<Vec<u8>>,
    recovery: &mut StreamRecoveryState,
    timeout: Duration,
) -> Result<bool, StreamFailure>
where
    S: futures::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let mut sent = false;
    // A replay still being caught up goes first: it is older than the queue,
    // and it is already on the timeline.
    catch_up.active = false;
    while let Some(pcm) = catch_up.replay.pop_front() {
        send_message(
            write,
            Message::Binary(pcm.into()),
            "Soniox stream recovery audio send",
            timeout,
        )
        .await?;
        sent = true;
    }
    while let Ok(pcm) = audio_rx.try_recv() {
        let retained_pcm = pcm.clone();
        send_message(
            write,
            Message::Binary(pcm.into()),
            "Soniox stream queued audio fence",
            timeout,
        )
        .await?;
        recovery.record_sent(retained_pcm);
        sent = true;
    }
    Ok(sent)
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

    /// Counts how many times a lane asked for a credential.
    struct CountingCredential {
        issued: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl LaneCredentialSource for CountingCredential {
        fn credential_for_connection(&self) -> BoxedCredentialFuture<'_> {
            let issued = self.issued.clone();
            Box::pin(async move {
                issued.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                Ok(LaneCredential::uncapped("minted-key"))
            })
        }
    }

    /// A dial that never connects never presents its key, so the retry must
    /// reuse it.
    ///
    /// The community invite service bounds a session by keys issued, and a key
    /// is claimed the moment it is minted. Minting once per dial spent three
    /// of a sixteen-key budget on a single blip while opening zero streams —
    /// four such blips ended translation for the rest of a recording.
    #[tokio::test]
    async fn an_unconnected_dial_reuses_its_key_instead_of_minting_another() {
        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let credential = Arc::new(CountingCredential {
            issued: issued.clone(),
        });
        let cancel = CancellationToken::new();
        // Port 1 refuses immediately: every attempt fails before the socket
        // is up, which is exactly the case whose key is still redeemable.
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            "ws://127.0.0.1:1",
            credential,
            SttConfig::default(),
            cancel.clone(),
            0,
            short_timeouts(),
        );
        let _ = time::timeout(Duration::from_secs(5), &mut runtime.task).await;

        assert_eq!(
            issued.load(std::sync::atomic::Ordering::Acquire),
            1,
            "one blip must cost one key, not one per reconnect attempt"
        );
    }

    fn short_timeouts() -> StreamTimeouts {
        StreamTimeouts {
            connect: Duration::from_millis(200),
            write: Duration::from_millis(200),
            receive_idle: Duration::from_secs(1),
            keepalive: Duration::from_millis(25),
            drain: Duration::from_millis(40),
            reconnect_base_delay: Duration::from_millis(10),
            // Tests bound outages by time where production never gives up:
            // a permanently dead endpoint must end the task, not the runner.
            reconnect_outage_budget: Some(Duration::from_millis(500)),
            // Far above anything a test sends, so the live-edge cut only
            // fires in the tests that ask for it with a tighter bound.
            live_edge_max_backlog: Duration::from_secs(3_600),
            // Test sessions last milliseconds; production's floor would send
            // every rollover in a test through the backoff path instead.
            immediate_rollover_min_session: Duration::ZERO,
            handover_lead: HANDOVER_LEAD,
            handover_deadline_margin: HANDOVER_DEADLINE_MARGIN,
            fast_reconnect_window: FAST_RECONNECT_WINDOW,
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        // Audio gives the provider a tail to finish; it never does.
        runtime.push_pcm(vec![0_u8; 3_200]).await.unwrap();
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

    /// A hand-over that falls in a pause opens a connection that may never
    /// carry audio before the recording stops. The provider refuses to finish
    /// such a connection (400 `invalid_request`), which recorded a provider
    /// failure on a recording whose transcript was complete. There is no tail
    /// to wait for, so the lane finishes it itself.
    #[tokio::test]
    async fn a_connection_that_never_carried_audio_finishes_without_the_provider() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (finish_tx, finish_rx) = tokio::sync::oneshot::channel::<bool>();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let mut asked_to_finish = false;
            while let Some(Ok(message)) = ws.next().await {
                if matches!(message, Message::Text(ref text) if text.is_empty()) {
                    asked_to_finish = true;
                    let _ = ws
                        .send(Message::Text(
                            json!({"error_code": 400, "error_type": "invalid_request"})
                                .to_string()
                                .into(),
                        ))
                        .await;
                    break;
                }
            }
            let _ = finish_tx.send(asked_to_finish);
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Finished)
        );
        assert!(runtime.task.await.unwrap().is_ok());
        assert!(
            !finish_rx.await.unwrap(),
            "the provider was never asked to finish"
        );
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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
                planned: false,
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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

    /// A provider whose first connection takes five seconds of audio and then
    /// drops, and whose replacement reports what it received after its
    /// configuration up to the first control message, then answers a finish.
    async fn provider_dropping_once() -> (String, tokio::sync::oneshot::Receiver<(usize, String)>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
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
                        "tokens": [{"text": "前", "is_final": true, "language": "zh",
                                    "start_ms": 4_000, "end_ms": 4_500}],
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
            let mut seen_tx = Some(seen_tx);
            let mut binaries = 0;
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(_) => binaries += 1,
                    Message::Text(text) => {
                        if let Some(seen_tx) = seen_tx.take() {
                            let control = if text.is_empty() {
                                "finish".to_string()
                            } else {
                                serde_json::from_str::<Value>(&text).unwrap()["type"]
                                    .as_str()
                                    .unwrap_or_default()
                                    .to_string()
                            };
                            let _ = seen_tx.send((binaries, control));
                        }
                        if text.is_empty() {
                            second_ws
                                .send(Message::Text(
                                    json!({
                                        "tokens": [{"text": "后", "is_final": true,
                                                    "language": "zh",
                                                    "start_ms": 2_500, "end_ms": 2_600}],
                                        "final_audio_proc_ms": 3_000,
                                        "total_audio_proc_ms": 3_000,
                                        "finished": true
                                    })
                                    .to_string()
                                    .into(),
                                ))
                                .await
                                .unwrap();
                            break;
                        }
                    }
                    _ => {}
                }
            }
        });
        (endpoint, seen_rx)
    }

    fn slow_reconnect_timeouts() -> StreamTimeouts {
        StreamTimeouts {
            reconnect_base_delay: Duration::from_millis(300),
            ..short_timeouts()
        }
    }

    async fn wait_for_reconnecting(runtime: &mut SonioxStreamRuntime) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            if matches!(event, SttStreamEvent::Reconnecting { .. }) {
                return;
            }
        }
        panic!("the lane never started reconnecting");
    }

    /// Stop can come while a lane waits to reconnect. The audio it queued
    /// meanwhile and the words not yet confirmed are still the recording's
    /// tail: the lane reconnects at once, sends them, and finishes, instead
    /// of ending with an error and leaving the tail untranscribed.
    #[tokio::test]
    async fn a_stop_during_a_reconnect_still_delivers_the_tail() {
        let (endpoint, seen) = provider_dropping_once().await;
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            slow_reconnect_timeouts(),
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        wait_for_reconnecting(&mut runtime).await;
        for _ in 0..10 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();

        let mut words = Vec::new();
        let mut finished = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            match event {
                SttStreamEvent::Tokens(tokens) => {
                    words.extend(tokens.into_iter().map(|token| token.text));
                }
                SttStreamEvent::Finished => {
                    finished = true;
                    break;
                }
                _ => {}
            }
        }
        assert!(finished, "the lane finished; words so far {words:?}");
        assert!(
            words.contains(&"后".to_string()),
            "the tail arrived: {words:?}"
        );
        let (binaries, control) = seen.await.unwrap();
        assert_eq!(control, "finish");
        assert_eq!(binaries, 30, "two replayed seconds and the queued second");
        assert!(runtime.task.await.unwrap().is_ok());
    }

    /// A pause that comes while a lane waits to reconnect follows speech the
    /// lane already accepted. That speech is still sent, and still closed
    /// with a finalize, exactly as a pause on a live connection does.
    #[tokio::test]
    async fn a_pause_during_a_reconnect_keeps_the_speech_before_it() {
        let (endpoint, seen) = provider_dropping_once().await;
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            slow_reconnect_timeouts(),
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        wait_for_reconnecting(&mut runtime).await;
        for _ in 0..10 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        runtime.send_control(SttStreamControl::Pause).await.unwrap();

        let (binaries, control) = time::timeout(Duration::from_secs(3), seen)
            .await
            .expect("the replacement heard a control message")
            .unwrap();
        assert_eq!(control, "finalize", "the pause still closes the utterance");
        assert_eq!(
            binaries, 30,
            "two replayed seconds and the second before the pause"
        );

        runtime
            .send_control(SttStreamControl::Resume)
            .await
            .unwrap();
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut finished = false;
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            if event == SttStreamEvent::Finished {
                finished = true;
                break;
            }
        }
        assert!(finished);
    }

    /// After an outage too long to resume at once, the lane catches up on
    /// what queued. It used to do that block by block in a loop that read
    /// nothing back: no caption appeared and Stop went unheard until the
    /// whole backlog was sent, at a pace barely ahead of the live audio still
    /// arriving — up to a minute for a fifteen-second outage. Words and
    /// controls are now served while it catches up.
    #[tokio::test]
    async fn catching_up_after_an_outage_still_serves_words_and_stop() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (seen_tx, seen_rx) = tokio::sync::oneshot::channel::<usize>();
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
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
                    json!({"tokens": [], "final_audio_proc_ms": 5_000, "total_audio_proc_ms": 5_000})
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
            let mut binaries = 0;
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(_) => {
                        binaries += 1;
                        if binaries == 1 {
                            second_ws
                                .send(Message::Text(
                                    json!({
                                        "tokens": [{"text": "新", "is_final": true,
                                                    "language": "zh",
                                                    "start_ms": 2_100, "end_ms": 2_200}],
                                        "final_audio_proc_ms": 2_200,
                                        "total_audio_proc_ms": 2_200
                                    })
                                    .to_string()
                                    .into(),
                                ))
                                .await
                                .unwrap();
                        }
                    }
                    Message::Text(text) if text.is_empty() => {
                        let _ = seen_tx.send(binaries);
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            StreamTimeouts {
                // Any outage counts as a long one here.
                fast_reconnect_window: Duration::from_millis(50),
                ..slow_reconnect_timeouts()
            },
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        wait_for_reconnecting(&mut runtime).await;
        // Three seconds queue during the outage.
        for _ in 0..30 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }

        let word_deadline = tokio::time::Instant::now() + Duration::from_millis(1_500);
        let mut word = None;
        while let Ok(Some(event)) =
            tokio::time::timeout_at(word_deadline, runtime.event_rx.recv()).await
        {
            if let SttStreamEvent::Tokens(tokens) = event {
                word = tokens.into_iter().next().map(|token| token.text);
                break;
            }
        }
        assert_eq!(
            word.as_deref(),
            Some("新"),
            "the replacement's first word arrived while the lane caught up"
        );

        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let stop_deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let mut finished = false;
        while let Ok(Some(event)) =
            tokio::time::timeout_at(stop_deadline, runtime.event_rx.recv()).await
        {
            if event == SttStreamEvent::Finished {
                finished = true;
                break;
            }
        }
        assert!(finished, "Stop was heard while catching up");
        assert_eq!(
            seen_rx.await.unwrap(),
            50,
            "the two replayed seconds and the three queued ones all reached the provider"
        );
    }

    /// A replacement connection hears the last two seconds again. Every word
    /// in them was already written when the old connection closed — its
    /// partials were confirmed then — so none may come back. The provider
    /// finalizes a word some time after it has processed the audio, so the
    /// replayed words keep arriving after `total_audio_proc_ms` has passed
    /// the replay; only `final_audio_proc_ms` says they are all out. And a
    /// translation belongs to the source words just before it, even when it
    /// arrives in a later response than they did.
    #[tokio::test]
    async fn replayed_words_never_come_back_after_a_reconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
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
                        "tokens": [
                            {"text": "前", "is_final": true, "language": "zh",
                             "start_ms": 4_000, "end_ms": 4_500},
                            {"text": "before", "is_final": true, "language": "en",
                             "translation_status": "translation"}
                        ],
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
            // The replay starts at 3_000, so the replayed word is at 1_000
            // here and the replay ends at 2_000.
            let responses = [
                // Past the replay, but its word still only a partial.
                json!({
                    "tokens": [{"text": "前", "is_final": false, "language": "zh",
                                "start_ms": 1_000, "end_ms": 1_500}],
                    "final_audio_proc_ms": 0,
                    "total_audio_proc_ms": 2_100
                }),
                // The replayed word turns final, with its translation.
                json!({
                    "tokens": [
                        {"text": "前", "is_final": true, "language": "zh",
                         "start_ms": 1_000, "end_ms": 1_500},
                        {"text": "before", "is_final": true, "language": "en",
                         "translation_status": "translation"}
                    ],
                    "final_audio_proc_ms": 1_600,
                    "total_audio_proc_ms": 2_600
                }),
                // A new word, its translation one response later.
                json!({
                    "tokens": [{"text": "后", "is_final": true, "language": "zh",
                                "start_ms": 2_500, "end_ms": 2_600}],
                    "final_audio_proc_ms": 2_600,
                    "total_audio_proc_ms": 2_600
                }),
                json!({
                    "tokens": [{"text": "after", "is_final": true, "language": "en",
                                "translation_status": "translation"}],
                    "final_audio_proc_ms": 2_600,
                    "total_audio_proc_ms": 2_600
                }),
            ];
            let mut answered = false;
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(_) if !answered => {
                        answered = true;
                        for response in &responses {
                            second_ws
                                .send(Message::Text(response.to_string().into()))
                                .await
                                .unwrap();
                        }
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }

        let mut final_words = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            if let SttStreamEvent::Tokens(tokens) = event {
                final_words.extend(
                    tokens
                        .iter()
                        .filter(|token| token.is_final)
                        .map(|token| token.text.clone()),
                );
            }
            if final_words.last().is_some_and(|word| word == "after") {
                break;
            }
        }

        assert_eq!(
            final_words,
            vec!["前", "before", "后", "after"],
            "a replayed word or its translation came back"
        );
    }

    /// Soniox moves its own clock forward by about a tenth of a second each
    /// time it finalizes, so every word after a finalize came back late by
    /// all the time added so far. An auxiliary lane is finalized at every
    /// canonical endpoint: after nine minutes of conversation its words were
    /// four seconds late, and their translations sat on the next speaker's
    /// row. The provider says how far ahead it is when it answers the
    /// finalize; positions after that are taken back by that much.
    #[tokio::test]
    async fn time_the_provider_adds_when_it_finalizes_is_taken_back_out() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (more_audio_tx, more_audio_rx) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = ws.next().await else {
                panic!("configuration missing");
            };
            let mut blocks = 0;
            while let Some(Ok(message)) = ws.next().await {
                match message {
                    Message::Binary(_) => blocks += 1,
                    Message::Text(text) if text.contains("finalize") => break,
                    _ => {}
                }
            }
            assert_eq!(blocks, 10, "one second of audio before the finalize");
            // Everything heard, plus 120 ms the provider added for itself.
            ws.send(Message::Text(
                json!({
                    "tokens": [
                        {"text": "前", "is_final": true, "language": "zh", "start_ms": 100, "end_ms": 400},
                        {"text": "<fin>", "is_final": true}
                    ],
                    "final_audio_proc_ms": 1_120,
                    "total_audio_proc_ms": 1_120
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();
            let _ = more_audio_tx.send(());
            let mut more = 0;
            while let Some(Ok(message)) = ws.next().await {
                if let Message::Binary(_) = message {
                    more += 1;
                    if more == 10 {
                        // Spoken 400 ms into the second second: capture
                        // 1_400, which the provider calls 1_520.
                        ws.send(Message::Text(
                            json!({
                                "tokens": [{"text": "后", "is_final": true, "language": "zh", "start_ms": 1_520, "end_ms": 1_800}],
                                "final_audio_proc_ms": 2_120,
                                "total_audio_proc_ms": 2_120
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .unwrap();
                    }
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        for _ in 0..10 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        runtime
            .send_control(SttStreamControl::Finalize)
            .await
            .unwrap();
        more_audio_rx.await.unwrap();
        for _ in 0..10 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }

        let mut starts = Vec::new();
        let mut totals = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, runtime.event_rx.recv()).await
        {
            match event {
                SttStreamEvent::Tokens(tokens) => {
                    starts.extend(tokens.iter().filter_map(|token| token.start_ms))
                }
                SttStreamEvent::AudioProgress {
                    total_audio_proc_ms,
                    ..
                } => totals.push(total_audio_proc_ms),
                _ => {}
            }
            if starts.len() >= 2 {
                break;
            }
        }
        assert_eq!(starts, vec![100, 1_400]);
        assert_eq!(
            totals.first(),
            Some(&1_000),
            "the finalize covers the second sent"
        );
    }

    /// Audio flushed ahead of a finalize is audio the provider heard. It
    /// used to go out uncounted: an auxiliary lane takes a finalize at
    /// every canonical endpoint, so its own clock fell behind by every such
    /// flush, and the first reconnect, hand-over or re-anchor projected all
    /// later tokens early by the whole accumulated amount.
    #[tokio::test]
    async fn audio_flushed_ahead_of_a_finalize_still_advances_the_timeline() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (queued_tx, queued_rx) = tokio::sync::oneshot::channel::<()>();
        let (first_answered_tx, first_answered_rx) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            // Hold the handshake until the client has queued its audio and
            // the finalize, so the lane meets both at once and the finalize
            // branch is the one that sends the audio.
            queued_rx.await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            let mut binary_before_finalize = 0;
            while let Some(Ok(message)) = first_ws.next().await {
                match message {
                    Message::Binary(_) => binary_before_finalize += 1,
                    Message::Text(text) if text.contains("finalize") => break,
                    _ => {}
                }
            }
            assert_eq!(binary_before_finalize, 50, "the finalize flushed the queue");
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
            let _ = first_answered_tx.send(());

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        for _ in 0..50 {
            runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();
        }
        runtime
            .send_control(SttStreamControl::Finalize)
            .await
            .unwrap();
        queued_tx.send(()).unwrap();
        first_answered_rx.await.unwrap();
        // Live audio after the outage, so the replacement has something to
        // answer even if nothing were replayed.
        runtime.push_pcm(vec![1_u8; 3_200]).await.unwrap();

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
            "the replacement resumes 2 s before the acknowledged 5 s, so its \
             2_500 ms token is at 5_500 on the capture timeline"
        );
    }

    /// Soniox ends a session on its own when a temporary key's wall-clock cap
    /// runs out (`max_session_duration_seconds` on a community invite key):
    /// tail tokens, then `finished: true` — with no local Finish pending.
    /// That is a rollover boundary. Treating it as a clean ending is how a
    /// recording died silently at minute 27 with nothing in the logs.
    #[tokio::test]
    async fn unsolicited_finished_rolls_over_to_a_replacement_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            // The provider finishes on its own: final tail token plus
            // `finished: true`, no empty text frame was ever received.
            first_ws
                .send(Message::Text(
                    json!({
                        "tokens": [{
                            "text": "上半场",
                            "is_final": true,
                            "language": "zh"
                        }],
                        "finished": true
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            while let Some(Ok(message)) = second_ws.next().await {
                if matches!(&message, Message::Text(text) if text.is_empty()) {
                    second_ws
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
            }
        });

        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        let Some(SttStreamEvent::Tokens(tokens)) = runtime.event_rx.recv().await else {
            panic!("tail tokens sent with the provider's finish must be delivered");
        };
        assert_eq!(tokens[0].text, "上半场");
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Reconnecting {
                attempt: 1,
                delay_ms: 10,
                planned: false,
            }),
            "an unsolicited finish must reconnect, not end the stream"
        );
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::RecoveryStarted { .. })
        ));
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::AudioProgress { .. })
        ));
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );

        // A finish the capture actually asked for still ends the stream.
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

    /// A community invite key is single-use: presenting it spends it. The
    /// rollover therefore has to mint a replacement, and the assertion has to
    /// be about the credential source rather than about text arriving —
    /// a lane that re-presented the spent key would be refused with an auth
    /// error, and auth is terminal, so the recording would lose realtime
    /// transcription for good at the provider's first wall-clock limit.
    #[tokio::test]
    async fn a_rollover_mints_a_replacement_key_rather_than_reusing_the_spent_one() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            // The provider's own wall-clock limit, mid-capture.
            first_ws
                .send(Message::Text(
                    json!({"tokens": [], "finished": true}).to_string().into(),
                ))
                .await
                .unwrap();

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            while let Some(Ok(message)) = second_ws.next().await {
                if matches!(&message, Message::Text(text) if text.is_empty()) {
                    second_ws
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
            }
        });

        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            Arc::new(CountingCredential {
                issued: issued.clone(),
            }),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        let Some(SttStreamEvent::Reconnecting { .. }) = runtime.event_rx.recv().await else {
            panic!("an unsolicited finish must roll over, not end the lane");
        };
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::RecoveryStarted { .. })
        ));
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::AudioProgress { .. })
        ));
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        assert_eq!(
            issued.load(std::sync::atomic::Ordering::Acquire),
            2,
            "the replacement connection must carry a freshly minted key"
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

    /// Serves two sessions: the first sends `first_frames` and closes, the
    /// second waits for the capture's Finish. Stands in for a provider that
    /// ends one connection on its own and accepts the next.
    async fn provider_ending_the_first_session_with(frames: Vec<Value>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            for frame in frames {
                first_ws
                    .send(Message::Text(frame.to_string().into()))
                    .await
                    .unwrap();
            }
            // The provider closes after any error frame.
            let _ = first_ws.close(None).await;

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            while let Some(Ok(message)) = second_ws.next().await {
                if matches!(&message, Message::Text(text) if text.is_empty()) {
                    second_ws
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
            }
        });
        endpoint
    }

    /// The frame Soniox actually sends when a temporary key's
    /// `max_session_duration_seconds` runs out, captured from the provider
    /// with a ten-second key. Its 403 is the status a key without permission
    /// gets; read by status alone this ended every invite recording at the
    /// end of its reservation window, with "the service rejected the key".
    fn temporary_key_session_expired_frame() -> Value {
        json!({
            "tokens": [],
            "final_audio_proc_ms": 4080,
            "total_audio_proc_ms": 9120,
            "error_code": 403,
            "error_type": "temp_api_key_session_expired",
            "error_message": "Temporary API key session duration limit exceeded. \
                Create a new temporary API key to start a new session.",
            "more_info": "https://soniox.com/docs/api-reference/errors#temp-api-key-session-expired",
            "request_id": "7fdf405e-d0b9-4267-a7b2-1f0c920f21fb"
        })
    }

    #[tokio::test]
    async fn a_key_reaching_its_session_cap_rolls_over_at_once_on_a_fresh_key() {
        let endpoint = provider_ending_the_first_session_with(vec![
            json!({
                "tokens": [{"text": "第三个小时的最后一句", "is_final": true, "language": "zh"}],
                "final_audio_proc_ms": 4000,
                "total_audio_proc_ms": 4000
            }),
            temporary_key_session_expired_frame(),
        ])
        .await;
        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            Arc::new(CountingCredential {
                issued: issued.clone(),
            }),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );

        let mut events = Vec::new();
        loop {
            let event = time::timeout(Duration::from_secs(5), runtime.event_rx.recv())
                .await
                .expect("the lane must keep reporting")
                .expect("the lane must not end");
            let connected_again = matches!(event, SttStreamEvent::Connected)
                && events
                    .iter()
                    .any(|seen| matches!(seen, SttStreamEvent::Reconnecting { .. }));
            events.push(event);
            if connected_again {
                break;
            }
        }

        assert!(
            !events
                .iter()
                .any(|event| matches!(event, SttStreamEvent::Error(_))),
            "a session cap is not a failure: {events:?}"
        );
        assert!(events.iter().any(|event| matches!(
            event,
            SttStreamEvent::Tokens(tokens) if tokens[0].text == "第三个小时的最后一句"
        )));
        assert!(
            events.contains(&SttStreamEvent::Reconnecting {
                attempt: 1,
                delay_ms: 0,
                planned: true,
            }),
            "a rollover reconnects without backing off: {events:?}"
        );
        assert_eq!(
            issued.load(std::sync::atomic::Ordering::Acquire),
            2,
            "the next session needs a fresh key; the capped one cannot open it"
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

    /// Soniox's fixed maximum session length (413) — the one a saved
    /// personal key meets — is the same kind of ending and rolls over the
    /// same way.
    #[tokio::test]
    async fn the_providers_own_maximum_session_length_rolls_over_too() {
        let endpoint = provider_ending_the_first_session_with(vec![json!({
            "tokens": [],
            "error_code": 413,
            "error_type": "max_duration_reached",
            "error_message": "Maximum session duration reached."
        })])
        .await;
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("saved-personal-key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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
                delay_ms: 0,
                planned: true,
            })
        );
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::RecoveryStarted { .. })
        ));
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::AudioProgress { .. })
        ));
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
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

    /// A cap reached moments after connecting is a key minted with almost no
    /// time on it, not a long recording reaching its end. It still rolls
    /// over, but through the backoff, so it cannot spin.
    #[tokio::test]
    async fn a_cap_reached_right_after_connecting_backs_off_instead_of_spinning() {
        let endpoint =
            provider_ending_the_first_session_with(vec![temporary_key_session_expired_frame()])
                .await;
        let timeouts = StreamTimeouts {
            immediate_rollover_min_session: Duration::from_secs(60),
            ..short_timeouts()
        };
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            timeouts,
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
                planned: false,
            })
        );
        runtime
            .control_tx
            .send(SttStreamControl::Finish)
            .await
            .unwrap();
        drop(runtime.audio_tx);
        let _ = time::timeout(Duration::from_secs(5), runtime.task).await;
    }

    /// The same status with a different type is a real refusal and must still
    /// end the lane: only the provider's name for the cap makes a 403 a
    /// rollover.
    #[tokio::test]
    async fn a_permission_refusal_sharing_the_status_still_ends_the_lane() {
        let endpoint = provider_ending_the_first_session_with(vec![json!({
            "tokens": [],
            "error_code": 403,
            "error_type": "permission_denied",
            "error_message": "The key lacks the permission the call needs.",
            "request_id": "3a0d53bf-5a0b-46a7-b447-fcaca63856e3"
        })])
        .await;
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        let Some(SttStreamEvent::Error(SttStreamError::Provider(error))) =
            runtime.event_rx.recv().await
        else {
            panic!("a permission refusal must end the lane");
        };
        assert_eq!(error.error_code, 403);
        assert_eq!(error.error_type, "authentication_error");
        assert!(runtime.task.await.unwrap().unwrap_err().is_auth_error());
    }

    /// An invite key whose session cap the service told the lane about.
    struct CappedCredential {
        cap: Duration,
        issued: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl LaneCredentialSource for CappedCredential {
        fn credential_for_connection(&self) -> BoxedCredentialFuture<'_> {
            let issued = self.issued.clone();
            let cap = self.cap;
            Box::pin(async move {
                let n = issued.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                Ok(LaneCredential {
                    api_key: format!("single-use-{n}"),
                    session_cap: Some(cap),
                })
            })
        }
    }

    /// What the second connection of a hand-over saw.
    #[derive(Debug)]
    struct HandoverObservation {
        /// When the lane finished the first connection, from its opening.
        finished_after: Duration,
        /// Audio frames the second connection received before the capture's
        /// own Finish — anything here was replayed.
        replayed_frames: usize,
    }

    /// The first connection hears three blocks, optionally marks a pause
    /// after `pause_after`, and confirms the lane's finish; the second
    /// reports what it was sent before the capture finished.
    async fn provider_observing_a_handover(
        pause_after: Option<Duration>,
    ) -> (String, tokio::sync::oneshot::Receiver<HandoverObservation>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (observed_tx, observed_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let opened = Instant::now();
            let (mut write, mut read) = accept_async(first_stream).await.unwrap().split();
            let Some(Ok(Message::Text(_config))) = read.next().await else {
                panic!("first session configuration missing");
            };
            let pause = async {
                match pause_after {
                    Some(after) => time::sleep(after).await,
                    None => std::future::pending::<()>().await,
                }
            };
            tokio::pin!(pause);
            let mut paused_once = false;
            loop {
                tokio::select! {
                    _ = &mut pause, if !paused_once => {
                        paused_once = true;
                        write
                            .send(Message::Text(
                                json!({
                                    "tokens": [
                                        {"text": "到点之前的最后一句", "is_final": true,
                                         "start_ms": 0, "end_ms": 300, "language": "zh"},
                                        {"text": "<end>", "is_final": true}
                                    ],
                                    "final_audio_proc_ms": 300,
                                    "total_audio_proc_ms": 300
                                })
                                .to_string()
                                .into(),
                            ))
                            .await
                            .unwrap();
                    }
                    message = read.next() => match message {
                        Some(Ok(Message::Text(text))) if text.is_empty() => break,
                        Some(Ok(_)) => {}
                        _ => panic!("the lane closed the connection without finishing it"),
                    },
                }
            }
            let finished_after = opened.elapsed();
            write
                .send(Message::Text(
                    json!({
                        "tokens": [],
                        "finished": true,
                        "final_audio_proc_ms": 300,
                        "total_audio_proc_ms": 300
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            let mut replayed_frames = 0;
            while let Some(Ok(message)) = second_ws.next().await {
                match message {
                    Message::Binary(_) => replayed_frames += 1,
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
            let _ = observed_tx.send(HandoverObservation {
                finished_after,
                replayed_frames,
            });
        });
        (endpoint, observed_rx)
    }

    /// Collects events until the replacement connection is up.
    async fn events_through_the_second_connection(
        runtime: &mut SonioxStreamRuntime,
    ) -> Vec<SttStreamEvent> {
        let mut events = Vec::new();
        loop {
            let event = time::timeout(Duration::from_secs(5), runtime.event_rx.recv())
                .await
                .expect("the lane must keep reporting")
                .expect("the lane must not end");
            let connected_again = matches!(event, SttStreamEvent::Connected)
                && events
                    .iter()
                    .any(|seen| matches!(seen, SttStreamEvent::Reconnecting { .. }));
            events.push(event);
            if connected_again {
                return events;
            }
        }
    }

    fn handover_timeouts() -> StreamTimeouts {
        StreamTimeouts {
            // The fake provider says nothing between its replies.
            receive_idle: Duration::from_secs(10),
            drain: Duration::from_secs(2),
            ..short_timeouts()
        }
    }

    /// The provider recommends opening a new connection before a key's cap
    /// rather than waiting to be cut off. Handing over at a pause, after the
    /// provider confirmed everything final, leaves the seam clean: the
    /// replacement starts at the live edge with nothing replayed — where a
    /// cut-off connection re-hears its last two seconds and writes them
    /// twice.
    #[tokio::test]
    async fn a_capped_key_hands_over_at_a_pause_with_nothing_to_replay() {
        // A two-second cap starts watching for a pause half a second before
        // it; the pause comes 1.6 s in.
        let (endpoint, observed) =
            provider_observing_a_handover(Some(Duration::from_millis(1_600))).await;
        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            Arc::new(CappedCredential {
                cap: Duration::from_secs(2),
                issued: issued.clone(),
            }),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            handover_timeouts(),
        );
        for _ in 0..3 {
            runtime.push_pcm(vec![0_u8; 3_200]).await.unwrap();
        }

        let events = events_through_the_second_connection(&mut runtime).await;
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, SttStreamEvent::Error(_) | SttStreamEvent::Finished)),
            "a hand-over neither fails nor ends the lane: {events:?}"
        );
        assert!(events.iter().any(|event| matches!(
            event,
            SttStreamEvent::Tokens(tokens) if tokens[0].text == "到点之前的最后一句"
        )));
        assert!(events.contains(&SttStreamEvent::Endpoint));
        assert!(events.contains(&SttStreamEvent::Reconnecting {
            attempt: 1,
            delay_ms: 0,
            planned: true,
        }));
        assert_eq!(issued.load(std::sync::atomic::Ordering::Acquire), 2);

        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let observed = observed.await.unwrap();
        assert_eq!(
            observed.replayed_frames, 0,
            "a confirmed hand-over has nothing to replay"
        );
        // At the pause (1.6 s), not at the deadline (1.8 s).
        assert!(
            observed.finished_after >= Duration::from_millis(1_500)
                && observed.finished_after < Duration::from_millis(1_750),
            "handed over somewhere other than the pause: {observed:?}"
        );
    }

    /// No pause before the deadline: the lane still hands over before the
    /// cap rather than be cut off by it.
    #[tokio::test]
    async fn a_capped_key_without_a_pause_hands_over_at_its_deadline() {
        let (endpoint, observed) = provider_observing_a_handover(None).await;
        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            Arc::new(CappedCredential {
                cap: Duration::from_secs(2),
                issued: issued.clone(),
            }),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            handover_timeouts(),
        );
        for _ in 0..3 {
            runtime.push_pcm(vec![0_u8; 3_200]).await.unwrap();
        }

        let events = events_through_the_second_connection(&mut runtime).await;
        assert!(events.contains(&SttStreamEvent::Reconnecting {
            attempt: 1,
            delay_ms: 0,
            planned: true,
        }));
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let observed = observed.await.unwrap();
        // A tenth of the two-second cap before it.
        assert!(
            observed.finished_after >= Duration::from_millis(1_750),
            "handed over too early: {observed:?}"
        );
        assert!(
            observed.finished_after < Duration::from_secs(2),
            "handed over after the cap: {observed:?}"
        );
        assert_eq!(observed.replayed_frames, 0);
    }

    fn tone_block(amplitude: i16) -> Vec<u8> {
        (0..1_600)
            .flat_map(|index| {
                let sample = if index % 2 == 0 {
                    amplitude
                } else {
                    -amplitude
                };
                sample.to_le_bytes()
            })
            .collect()
    }

    #[test]
    fn a_quiet_block_is_one_well_below_the_recent_level() {
        let mut detector = QuietBlockDetector::default();
        for _ in 0..30 {
            assert!(
                !detector.observe(&tone_block(8_000)),
                "speech is not a pause"
            );
        }
        assert!(
            !detector.observe(&tone_block(4_000)),
            "a softer syllable is not a pause"
        );
        assert!(detector.observe(&tone_block(400)), "a gap between words is");
        assert!(detector.observe(&vec![0_u8; 3_200]), "silence is");

        let mut steady_noise = QuietBlockDetector::default();
        for _ in 0..60 {
            assert!(
                !steady_noise.observe(&tone_block(1_500)),
                "steady noise never reads as a pause"
            );
        }
    }

    /// Speech that never yields an `<end>` still has gaps between words. The
    /// lane hands over in the first quiet block once the cap is near, so the
    /// cut falls between words instead of through one.
    #[tokio::test]
    async fn a_capped_key_hands_over_in_a_quiet_moment_of_the_audio() {
        let (endpoint, observed) = provider_observing_a_handover(None).await;
        let issued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            Arc::new(CappedCredential {
                cap: Duration::from_secs(2),
                issued: issued.clone(),
            }),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            handover_timeouts(),
        );
        // Speech for 1.6 s — past the point the lane starts looking for a
        // pause (1.5 s) — then a gap, then speech again.
        let audio_tx = runtime.audio_tx.clone();
        tokio::spawn(async move {
            let started = Instant::now();
            let mut gap_sent = false;
            while started.elapsed() < Duration::from_millis(2_400) {
                let block = if !gap_sent && started.elapsed() >= Duration::from_millis(1_600) {
                    gap_sent = true;
                    vec![0_u8; 3_200]
                } else {
                    tone_block(8_000)
                };
                if audio_tx.send(block).await.is_err() {
                    return;
                }
                time::sleep(Duration::from_millis(100)).await;
            }
        });

        let events = events_through_the_second_connection(&mut runtime).await;
        assert!(events.contains(&SttStreamEvent::Reconnecting {
            attempt: 1,
            delay_ms: 0,
            planned: true,
        }));
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        let observed = observed.await.unwrap();
        assert!(
            observed.finished_after >= Duration::from_millis(1_550)
                && observed.finished_after < Duration::from_millis(1_750),
            "handed over somewhere other than the quiet block: {observed:?}"
        );
    }

    struct SpentInvitation;

    impl LaneCredentialSource for SpentInvitation {
        fn credential_for_connection(&self) -> BoxedCredentialFuture<'_> {
            Box::pin(async {
                Err(SttError::QuotaExhausted {
                    kind: SonioxQuotaKind::Other,
                    message: "invite service returned 429 quota_exhausted".to_string(),
                })
            })
        }
    }

    /// An invitation with no time left to cover the next stream ends the
    /// lane at once, under its own name: not a rejected key, not a spent
    /// provider balance, and not an outage to keep retrying.
    #[tokio::test]
    async fn spent_invite_time_ends_the_lane_as_spent_time() {
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            "ws://127.0.0.1:1",
            Arc::new(SpentInvitation),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            short_timeouts(),
        );
        let Some(SttStreamEvent::Error(SttStreamError::Provider(error))) =
            runtime.event_rx.recv().await
        else {
            panic!("spent invite time must end the lane");
        };
        assert_eq!(error.error_type, CREDENTIAL_TIME_EXHAUSTED_ERROR_TYPE);
        assert!(matches!(
            runtime.task.await.unwrap(),
            Err(SttError::QuotaExhausted { .. })
        ));
    }

    #[test]
    fn only_the_providers_cap_names_make_an_error_frame_a_rollover() {
        assert!(ends_at_session_duration_cap(
            403,
            Some("temp_api_key_session_expired")
        ));
        assert!(ends_at_session_duration_cap(
            413,
            Some("max_duration_reached")
        ));
        assert!(ends_at_session_duration_cap(413, None));
        assert!(!ends_at_session_duration_cap(
            403,
            Some("permission_denied")
        ));
        assert!(!ends_at_session_duration_cap(401, Some("unauthenticated")));
        assert!(!ends_at_session_duration_cap(403, None));
        assert!(!ends_at_session_duration_cap(
            402,
            Some("organization_balance_exhausted")
        ));
    }

    /// The provider accepting bytes is not the provider keeping up. A lane
    /// whose sent-but-unprocessed backlog outgrows the replay window must cut
    /// itself and rejoin at the live edge — the alternative observed in
    /// production was the bounded channel behind it filling and the lane
    /// being killed for the rest of the recording. The skip must classify as
    /// non-continuous (outage past the continuity window) so the durable gap
    /// record appears downstream.
    #[tokio::test]
    async fn a_lane_that_outruns_its_provider_skips_to_the_live_edge() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (first_stream, _) = listener.accept().await.unwrap();
            let mut first_ws = accept_async(first_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = first_ws.next().await else {
                panic!("first session configuration missing");
            };
            // Accept audio but never acknowledge any progress: the lane's
            // sent backlog grows with every frame while acknowledged stays
            // at the origin.
            let mut sink_open = true;
            while sink_open {
                match first_ws.next().await {
                    Some(Ok(_)) => {}
                    _ => sink_open = false,
                }
            }

            let (second_stream, _) = listener.accept().await.unwrap();
            let mut second_ws = accept_async(second_stream).await.unwrap();
            let Some(Ok(Message::Text(_config))) = second_ws.next().await else {
                panic!("replacement session configuration missing");
            };
            while let Some(Ok(message)) = second_ws.next().await {
                if matches!(&message, Message::Text(text) if text.is_empty()) {
                    second_ws
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
            }
        });

        let mut timeouts = short_timeouts();
        timeouts.live_edge_max_backlog = Duration::from_millis(250);
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            timeouts,
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        // 100 ms of canonical PCM per frame; four frames exceed the 250 ms
        // backlog bound while the server acknowledges nothing.
        for _ in 0..4 {
            runtime.audio_tx.send(vec![0u8; 3_200]).await.unwrap();
        }

        let Some(SttStreamEvent::Reconnecting { .. }) = runtime.event_rx.recv().await else {
            panic!("an outrun lane must cut itself, not wait for its channel to fill");
        };
        let Some(SttStreamEvent::RecoveryStarted { outage_ms }) = runtime.event_rx.recv().await
        else {
            panic!("the replacement connection must announce its recovery");
        };
        assert!(
            outage_ms > CONTINUITY_WINDOW.as_millis() as u64,
            "a live-edge skip must classify as non-continuous so the gap is recorded, got {outage_ms}ms"
        );
        assert!(matches!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::AudioProgress { .. })
        ));
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
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

    /// A consumer that stops reading for a while — the app's event collector
    /// busy, the machine stalled — is not the provider falling behind. The
    /// connection keeps reading the provider's acknowledgements meanwhile, so
    /// the live-edge rule never fires and nothing is cut; every event is
    /// still delivered, in order, once the consumer reads again.
    ///
    /// Before the relay, the connection blocked on the full event channel,
    /// left acknowledgements unread in the socket, and then flushed its queued
    /// audio ahead of them: its own backlog, measured as the provider's. In a
    /// three-language meeting that cut every lane about twice a minute.
    #[tokio::test]
    async fn a_slow_consumer_never_makes_a_healthy_lane_cut_itself() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let accepted = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let server_accepted = accepted.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                server_accepted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let mut ws = accept_async(stream).await.unwrap();
                let Some(Ok(Message::Text(_config))) = ws.next().await else {
                    return;
                };
                // A healthy provider: every 100 ms frame is acknowledged at once.
                let mut processed_ms = 0_u64;
                while let Some(Ok(message)) = ws.next().await {
                    match message {
                        Message::Binary(_) => {
                            processed_ms += 100;
                            let _ = ws
                                .send(Message::Text(
                                    json!({
                                        "tokens": [],
                                        "final_audio_proc_ms": processed_ms,
                                        "total_audio_proc_ms": processed_ms
                                    })
                                    .to_string()
                                    .into(),
                                ))
                                .await;
                        }
                        Message::Text(text) if text.is_empty() => {
                            let _ = ws
                                .send(Message::Text(
                                    json!({"tokens": [], "finished": true}).to_string().into(),
                                ))
                                .await;
                            return;
                        }
                        _ => {}
                    }
                }
            }
        });

        let mut timeouts = short_timeouts();
        timeouts.live_edge_max_backlog = Duration::from_millis(500);
        let mut runtime = SonioxStreamClient::start_with_timeouts(
            endpoint,
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
            timeouts,
        );
        assert_eq!(
            runtime.event_rx.recv().await,
            Some(SttStreamEvent::Connected)
        );
        let mut progress = 0;
        let mut last_processed = 0;
        let mut observe = |event: SttStreamEvent| match event {
            SttStreamEvent::AudioProgress {
                total_audio_proc_ms,
                ..
            } => {
                assert!(
                    total_audio_proc_ms >= last_processed,
                    "events stay in order"
                );
                last_processed = total_audio_proc_ms;
                progress += 1;
                false
            }
            SttStreamEvent::Finished => true,
            SttStreamEvent::Reconnecting { .. } => {
                panic!("a slow consumer made a healthy lane cut itself")
            }
            other => panic!("unexpected event {other:?}"),
        };
        // Three times the event channel's capacity in acknowledgements, and
        // many times the backlog bound in audio, while nobody reads an event.
        let stalled_frames = EVENT_CHANNEL_CAPACITY * 3;
        for _ in 0..stalled_frames {
            runtime.audio_tx.send(vec![0u8; 3_200]).await.unwrap();
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        // The consumer reads again while audio keeps arriving. This is where
        // the old connection, released, flushed its queued audio ahead of the
        // unread acknowledgements and cut itself.
        let mut live_frames = 0;
        let resumed = tokio::time::Instant::now();
        while resumed.elapsed() < Duration::from_millis(800) {
            runtime.audio_tx.send(vec![0u8; 3_200]).await.unwrap();
            live_frames += 1;
            while let Ok(Some(event)) =
                tokio::time::timeout(Duration::from_millis(5), runtime.event_rx.recv()).await
            {
                observe(event);
            }
        }
        runtime
            .send_control(SttStreamControl::Finish)
            .await
            .unwrap();
        loop {
            let event = runtime
                .event_rx
                .recv()
                .await
                .expect("the stream ended before finishing");
            if observe(event) {
                break;
            }
        }
        assert_eq!(
            progress,
            stalled_frames + live_frames,
            "every acknowledgement is delivered"
        );
        assert!(runtime.task.await.unwrap().is_ok());
        assert_eq!(
            accepted.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "one connection for the whole run"
        );
    }

    /// Audio discarded on a skip never reached any provider, but it happened:
    /// the projection origin after the skip must sit past the discarded
    /// span, or every later token lands early by exactly that span — time
    /// silently compresses and the recorded gap reads as covered.
    #[test]
    fn discarded_audio_still_advances_the_projection_origin() {
        let mut recovery = StreamRecoveryState::starting_at(10_000);
        // 2s sent and acknowledged, then the provider stalls for 20s of sends.
        for _ in 0..20 {
            recovery.record_sent(vec![0u8; 3_200]);
        }
        recovery.acknowledge(2_000);
        assert_eq!(recovery.sent_backlog(), Duration::from_millis(0));
        for _ in 0..200 {
            recovery.record_sent(vec![0u8; 3_200]);
        }
        assert_eq!(recovery.sent_backlog(), Duration::from_secs(20));

        // The cut: replay abandoned, then 5s of queued audio discarded.
        let replay = recovery.prepare_replay(CONTINUITY_WINDOW + Duration::from_secs(5));
        assert!(replay.is_empty(), "a skip must not replay the backlog");
        for _ in 0..50 {
            recovery.note_discarded(3_200);
        }
        recovery.re_anchor_to_live_edge();

        // Origin = 10s start + 22s sent + 5s discarded.
        assert_eq!(recovery.connection_origin_ms, 10_000 + 22_000 + 5_000);
        assert_eq!(recovery.acknowledged_ms, recovery.connection_origin_ms);
        assert_eq!(recovery.sent_backlog(), Duration::ZERO);
    }

    #[test]
    fn reconnect_delay_stops_doubling_at_eight_times_base() {
        let base = Duration::from_secs(1);
        assert_eq!(reconnect_delay(base, 1), Duration::from_secs(1));
        assert_eq!(reconnect_delay(base, 2), Duration::from_secs(2));
        assert_eq!(reconnect_delay(base, 3), Duration::from_secs(4));
        assert_eq!(reconnect_delay(base, 4), Duration::from_secs(8));
        assert_eq!(reconnect_delay(base, 40), Duration::from_secs(8));
        assert_eq!(reconnect_delay(base, u8::MAX), Duration::from_secs(8));
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
            StaticLaneCredential::new("key"),
            SttConfig::default(),
            CancellationToken::new(),
            0,
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

    /// The provider ends a session it timed out waiting on (408) — a stall
    /// of this connection, not a refusal of the lane. It used to end the
    /// lane for the rest of the recording; a fresh connection resumes it.
    /// A request the provider rejects as invalid (400) would be rejected
    /// again, so that one still ends the lane.
    #[tokio::test]
    async fn a_provider_timeout_reconnects_and_an_invalid_request_does_not() {
        async fn first_frame_after_error(error_code: u16, error_type: &str) -> SttStreamEvent {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("ws://{}", listener.local_addr().unwrap());
            let frame = json!({"error_code": error_code, "error_type": error_type}).to_string();
            tokio::spawn(async move {
                loop {
                    let Ok((stream, _)) = listener.accept().await else {
                        return;
                    };
                    let Ok(mut ws) = accept_async(stream).await else {
                        continue;
                    };
                    let Some(Ok(Message::Text(_config))) = ws.next().await else {
                        continue;
                    };
                    let _ = ws.send(Message::Text(frame.clone().into())).await;
                }
            });
            let mut runtime = SonioxStreamClient::start_with_timeouts(
                endpoint,
                StaticLaneCredential::new("key"),
                SttConfig::default(),
                CancellationToken::new(),
                0,
                short_timeouts(),
            );
            assert_eq!(
                runtime.event_rx.recv().await,
                Some(SttStreamEvent::Connected)
            );
            runtime.event_rx.recv().await.unwrap()
        }

        assert!(
            matches!(
                first_frame_after_error(408, "request_timeout").await,
                SttStreamEvent::Reconnecting { .. }
            ),
            "a provider timeout is an outage"
        );
        assert!(
            matches!(
                first_frame_after_error(400, "invalid_request").await,
                SttStreamEvent::Error(SttStreamError::Provider(SttStreamProviderError {
                    error_code: 400,
                    ..
                }))
            ),
            "an invalid request is final"
        );
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
            translation_terms: vec![("ZuTalk".into(), "语音工具".into())],
            terms: vec!["  exact spacing  ".into()],
            general: vec![("project".into(), "  Sample Project  ".into())],
            text: Some(" leading and trailing ".into()),
        };
        let wire = build_stream_context(Some(&context)).unwrap();
        assert_eq!(
            serde_json::to_string(&wire).unwrap(),
            r#"{"translation_terms":[{"source":"ZuTalk","target":"语音工具"}],"terms":["  exact spacing  "],"general":[{"key":"project","value":"  Sample Project  "}],"text":" leading and trailing "}"#
        );
        assert_eq!(
            soniox_stream_context_json(&context).unwrap(),
            Some(serde_json::to_string(&wire).unwrap())
        );
    }

    /// A provider that keeps the socket open while it stops reporting progress
    /// is not a hypothetical: acknowledgement is the only thing that trimmed
    /// the replay buffer, so a stalled `total_audio_proc_ms` used to retain
    /// every frame of the session. At 32 KB of PCM per second that is roughly
    /// 115 MB an hour of audio no reconnect could ever use — held by an app
    /// whose whole posture is that audio does not stay around.
    #[test]
    fn a_provider_that_stops_acknowledging_cannot_grow_the_replay_buffer() {
        let mut recovery = StreamRecoveryState::default();
        // Ten minutes of speech in 100 ms frames, never acknowledged.
        for _ in 0..6_000 {
            recovery.record_sent(vec![0; 3_200]);
        }
        assert_eq!(recovery.acknowledged_ms, 0, "provider never acknowledged");

        let retained_ms: u64 = recovery
            .sent_frames
            .iter()
            .map(|frame| frame.pcm.len() as u64 / PCM_BYTES_PER_MILLISECOND)
            .sum();
        let ceiling = (CONTINUITY_WINDOW + REPLAY_OVERLAP).as_millis() as u64;
        assert!(
            retained_ms <= ceiling + 100,
            "retained {retained_ms} ms of audio, ceiling is {ceiling} ms"
        );

        // The ceiling is exactly what replay can reach: a reconnect inside the
        // continuity window still gets its overlap back, so trimming has not
        // cost the recovery anything it was using.
        let replay = recovery.prepare_replay(Duration::from_secs(1));
        assert!(!replay.is_empty(), "短暂断线仍要能回放");
    }

    /// A replacement lane is a new stream object opened partway through a
    /// recording. Every position it reports is on the capture timeline, so its
    /// clocks start where it does — a lane replaced forty minutes in must not
    /// file its first token against the opening minute.
    #[test]
    fn a_stream_started_partway_reports_positions_on_the_capture_timeline() {
        let origin_ms = 40 * 60 * 1_000;
        let mut recovery = StreamRecoveryState::starting_at(origin_ms);

        assert_eq!(recovery.connection_origin_ms, origin_ms);
        assert_eq!(recovery.acknowledged_ms, origin_ms);
        assert_eq!(recovery.next_audio_ms, origin_ms);

        // One second of audio advances the capture clock by one second, not to
        // one second.
        for _ in 0..10 {
            recovery.record_sent(vec![0; 3_200]);
        }
        assert_eq!(recovery.next_audio_ms, origin_ms + 1_000);

        // The provider counts from zero within its own connection; the origin
        // is what turns that back into a capture position.
        let (acknowledged_ms, _lag_ms) = recovery.acknowledge(600);
        assert_eq!(acknowledged_ms, origin_ms + 600);
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
