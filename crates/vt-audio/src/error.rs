//! 音频层错误类型

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("I/O error: {0}")]
    IoError(String),

    #[error("unsupported format: {0}")]
    UnsupportedFormat(String),

    #[error("decode failed: {0}")]
    DecodeFailed(String),

    #[error("encode failed: {0}")]
    EncodeFailed(String),

    #[error("resample failed: {0}")]
    ResampleFailed(String),
}
