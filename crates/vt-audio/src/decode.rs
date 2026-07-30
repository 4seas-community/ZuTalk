//! 通用音频解码器
//! 支持 MP3/AAC(M4A)/FLAC/WAV/OGG 五种格式
//! 输出统一 PCM f32 interleaved 采样

use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::AudioError;

/// 解码后的音频数据
pub struct DecodedAudio {
    /// PCM f32 interleaved samples
    pub samples: Vec<f32>,
    /// 采样率 (Hz)
    pub sample_rate: u32,
    /// 声道数
    pub channels: u16,
}

impl DecodedAudio {
    /// 音频时长（秒）
    pub fn duration_secs(&self) -> f64 {
        if self.sample_rate == 0 || self.channels == 0 {
            return 0.0;
        }
        self.samples.len() as f64 / (self.sample_rate as f64 * self.channels as f64)
    }
}

/// 解码音频文件为 PCM f32
pub fn decode_file(path: impl AsRef<Path>) -> Result<DecodedAudio, AudioError> {
    let path = path.as_ref();
    let file = std::fs::File::open(path).map_err(|e| AudioError::IoError(e.to_string()))?;

    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| AudioError::UnsupportedFormat(e.to_string()))?;

    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| AudioError::UnsupportedFormat("no audio track".into()))?;

    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| AudioError::UnsupportedFormat("unknown sample rate".into()))?;
    let channels = track
        .codec_params
        .channels
        .map(|c| c.count() as u16)
        .unwrap_or(1);
    let track_id = track.id;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| AudioError::DecodeFailed(e.to_string()))?;

    let mut all_samples = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(symphonia::core::errors::Error::ResetRequired) => break,
            Err(e) => return Err(AudioError::DecodeFailed(e.to_string())),
        };

        if packet.track_id() != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                let mut sample_buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                sample_buf.copy_interleaved_ref(decoded);
                all_samples.extend_from_slice(sample_buf.samples());
            }
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(e) => return Err(AudioError::DecodeFailed(e.to_string())),
        }
    }

    if all_samples.is_empty() {
        return Err(AudioError::DecodeFailed("no audio samples decoded".into()));
    }

    Ok(DecodedAudio {
        samples: all_samples,
        sample_rate,
        channels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    #[test]
    fn test_decode_wav() {
        let result = decode_file(fixture("test_16k_mono.wav")).unwrap();
        assert_eq!(result.sample_rate, 16000);
        assert_eq!(result.channels, 1);
        let duration = result.duration_secs();
        assert!(
            (duration - 3.0).abs() < 0.1,
            "expected ~3s, got {duration}s"
        );
    }

    #[test]
    fn test_decode_mp3() {
        let result = decode_file(fixture("test_44k_stereo.mp3")).unwrap();
        assert_eq!(result.sample_rate, 44100);
        assert_eq!(result.channels, 2);
        assert!(result.duration_secs() > 2.5);
    }

    #[test]
    fn test_decode_m4a_aac() {
        let result = decode_file(fixture("test_48k_mono.m4a")).unwrap();
        assert_eq!(result.sample_rate, 48000);
        assert_eq!(result.channels, 1);
    }

    #[test]
    fn test_decode_flac() {
        let result = decode_file(fixture("test_44k_stereo.flac")).unwrap();
        assert_eq!(result.sample_rate, 44100);
        assert_eq!(result.channels, 2);
    }

    #[test]
    fn test_decode_ogg() {
        let result = decode_file(fixture("test_16k_stereo.ogg")).unwrap();
        assert_eq!(result.sample_rate, 16000);
        assert_eq!(result.channels, 2);
    }

    #[test]
    fn test_decode_unsupported_format() {
        let result = decode_file(fixture("not_audio.txt"));
        assert!(result.is_err());
    }

    #[test]
    fn test_decode_returns_f32_in_range() {
        let result = decode_file(fixture("test_16k_mono.wav")).unwrap();
        for &s in &result.samples {
            assert!((-1.0..=1.0).contains(&s), "sample out of range: {s}");
        }
    }
}
