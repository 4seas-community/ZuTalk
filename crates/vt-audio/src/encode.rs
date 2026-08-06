//! 音频编码器
//! WAV (hound)

use std::path::Path;

use crate::AudioError;

/// 编码 PCM f32 为 WAV 文件（无损）
pub fn encode_wav(
    path: impl AsRef<Path>,
    samples: &[f32],
    sample_rate: u32,
    channels: u16,
) -> Result<(), AudioError> {
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };

    let mut writer = hound::WavWriter::create(path, spec)
        .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;

    for &sample in samples {
        writer
            .write_sample(sample)
            .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;
    }

    writer
        .finalize()
        .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;

    Ok(())
}

/// 编码 PCM f32 为内存中的 WAV 字节流（RIFF 头 + fmt + data），用于
/// zip 导出等不落盘场景。输出以 "RIFF" 开头，可被任何 WAV 播放器打开。
pub fn encode_wav_bytes(
    samples: &[f32],
    sample_rate: u32,
    channels: u16,
) -> Result<Vec<u8>, AudioError> {
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };

    let mut cursor = std::io::Cursor::new(Vec::new());
    {
        let mut writer = hound::WavWriter::new(&mut cursor, spec)
            .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;
        for &sample in samples {
            writer
                .write_sample(sample)
                .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;
        }
        writer
            .finalize()
            .map_err(|e| AudioError::EncodeFailed(e.to_string()))?;
    }
    Ok(cursor.into_inner())
}

/// 生成正弦波 PCM f32 采样（测试用）
pub fn generate_sine_wave(sample_rate: u32, duration_secs: f64, frequency: f64) -> Vec<f32> {
    let num_samples = (sample_rate as f64 * duration_secs) as usize;
    (0..num_samples)
        .map(|i| {
            let t = i as f64 / sample_rate as f64;
            (2.0 * std::f64::consts::PI * frequency * t).sin() as f32
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::decode_file;
    use proptest::prelude::*;
    use tempfile::NamedTempFile;

    #[test]
    fn test_encode_wav_roundtrip() {
        let samples = generate_sine_wave(16000, 1.0, 440.0);
        let tmp = NamedTempFile::new().unwrap();

        encode_wav(tmp.path(), &samples, 16000, 1).unwrap();

        let decoded = decode_file(tmp.path()).unwrap();
        assert_eq!(decoded.sample_rate, 16000);
        assert_eq!(decoded.channels, 1);
        assert_eq!(decoded.samples.len(), samples.len());
    }

    #[test]
    fn test_encode_wav_bytes_has_riff_header() {
        // Output must be a valid WAV (RIFF ... WAVE ... fmt ... data) so
        // downstream consumers (zip export → any audio player) can decode it.
        let samples = generate_sine_wave(16000, 0.5, 440.0);
        let bytes = encode_wav_bytes(&samples, 16000, 1).unwrap();

        assert!(bytes.len() > 44, "WAV must have header + data");
        assert_eq!(&bytes[0..4], b"RIFF", "must start with RIFF");
        assert_eq!(&bytes[8..12], b"WAVE", "must contain WAVE tag");
        assert!(
            bytes.windows(4).any(|w| w == b"fmt "),
            "must contain fmt chunk"
        );
        assert!(
            bytes.windows(4).any(|w| w == b"data"),
            "must contain data chunk"
        );

        // Round-trip: the bytes must decode back to the same samples.
        let tmp = NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), &bytes).unwrap();
        let decoded = decode_file(tmp.path()).unwrap();
        assert_eq!(decoded.sample_rate, 16000);
        assert_eq!(decoded.channels, 1);
        assert_eq!(decoded.samples.len(), samples.len());
    }

    #[test]
    fn test_generate_sine_wave() {
        let samples = generate_sine_wave(16000, 1.0, 440.0);
        assert_eq!(samples.len(), 16000);
        for &s in &samples {
            assert!((-1.0..=1.0).contains(&s));
        }
    }

    proptest! {
        #[test]
        fn test_wav_roundtrip_proptest(
            sample_rate in prop_oneof![Just(16000u32), Just(44100u32), Just(48000u32)],
            duration_ms in 100u32..2000u32,
        ) {
            let duration_secs = duration_ms as f64 / 1000.0;
            let samples = generate_sine_wave(sample_rate, duration_secs, 440.0);
            let tmp = NamedTempFile::new().unwrap();

            encode_wav(tmp.path(), &samples, sample_rate, 1).unwrap();
            let decoded = decode_file(tmp.path()).unwrap();
            prop_assert_eq!(decoded.sample_rate, sample_rate);
            prop_assert_eq!(decoded.samples.len(), samples.len());
        }
    }
}
