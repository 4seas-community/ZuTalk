//! Zulangue 音频层
//!
//! symphonia 解码 + 编码 + rubato 重采样。
//! 设计文档：docs/design/D7-macos-audio.md (编解码部分)

mod canonical;
pub mod decode;
pub mod encode;
pub mod error;

pub use canonical::{canonicalize_for_soniox, SONIOX_CANONICAL_SAMPLE_RATE};
pub use decode::{decode_file, DecodedAudio};
pub use encode::{encode_wav, generate_sine_wave};
pub use error::AudioError;
