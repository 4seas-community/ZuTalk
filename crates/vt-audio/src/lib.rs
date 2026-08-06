//! Zulangue 音频层
//!
//! symphonia 解码 + 编码 + rubato 重采样。

mod canonical;
pub mod decode;
pub mod encode;
pub mod error;

pub use canonical::{canonicalize_for_soniox, SONIOX_CANONICAL_SAMPLE_RATE};
pub use decode::{decode_file, DecodedAudio};
pub use encode::{encode_wav, generate_sine_wave};
pub use error::AudioError;
