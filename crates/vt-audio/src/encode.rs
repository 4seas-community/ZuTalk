//! 音频编码器
//! WAV (hound) + AAC (fdk-aac)

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

/// 编码 PCM f32 为 AAC 文件 (ADTS format)
pub fn encode_aac(
    path: impl AsRef<Path>,
    samples: &[f32],
    sample_rate: u32,
    channels: u16,
    _bitrate: u32,
) -> Result<(), AudioError> {
    use fdk_aac::enc::{ChannelMode, Encoder, EncoderParams};

    let channel_mode = match channels {
        1 => ChannelMode::Mono,
        2 => ChannelMode::Stereo,
        _ => {
            return Err(AudioError::EncodeFailed(format!(
                "unsupported channel count: {channels}"
            )))
        }
    };

    let params = EncoderParams {
        bit_rate: fdk_aac::enc::BitRate::VbrVeryHigh,
        sample_rate,
        transport: fdk_aac::enc::Transport::Adts,
        channels: channel_mode,
    };

    let encoder = Encoder::new(params).map_err(|e| AudioError::EncodeFailed(format!("{e:?}")))?;

    let info = encoder
        .info()
        .map_err(|e| AudioError::EncodeFailed(format!("{e:?}")))?;
    let frame_size = info.frameLength as usize * channels as usize;

    // Convert f32 [-1.0, 1.0] to i16
    let pcm_i16: Vec<i16> = samples
        .iter()
        .map(|&s| (s * 32767.0).clamp(-32768.0, 32767.0) as i16)
        .collect();

    // Output buffer - max AAC frame is ~768 bytes per channel per frame
    let max_output_size = 768 * channels as usize * 2;
    let mut out_buf = vec![0u8; max_output_size];
    let mut output = Vec::new();
    let mut offset = 0;

    while offset < pcm_i16.len() {
        let end = (offset + frame_size).min(pcm_i16.len());
        let mut frame = pcm_i16[offset..end].to_vec();

        // Pad last frame with silence if needed
        if frame.len() < frame_size {
            frame.resize(frame_size, 0);
        }

        let encode_info = encoder
            .encode(&frame, &mut out_buf)
            .map_err(|e| AudioError::EncodeFailed(format!("{e:?}")))?;
        if encode_info.output_size > 0 {
            output.extend_from_slice(&out_buf[..encode_info.output_size]);
        }

        offset += frame_size;
    }

    // Flush encoder
    let flush_info = encoder
        .encode(&[], &mut out_buf)
        .map_err(|e| AudioError::EncodeFailed(format!("{e:?}")))?;
    if flush_info.output_size > 0 {
        output.extend_from_slice(&out_buf[..flush_info.output_size]);
    }

    std::fs::write(path, &output).map_err(|e| AudioError::IoError(e.to_string()))?;

    Ok(())
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
    fn test_encode_aac_roundtrip() {
        let samples = generate_sine_wave(48000, 2.0, 440.0);
        let tmp = NamedTempFile::with_suffix(".aac").unwrap();

        encode_aac(tmp.path(), &samples, 48000, 1, 64_000).unwrap();

        let decoded = decode_file(tmp.path()).unwrap();
        assert_eq!(decoded.sample_rate, 48000);
        let orig_duration = samples.len() as f64 / 48000.0;
        let decoded_duration = decoded.samples.len() as f64 / 48000.0;
        assert!(
            (orig_duration - decoded_duration).abs() < 0.2,
            "duration diff too large: orig={orig_duration}s decoded={decoded_duration}s"
        );
    }

    #[test]
    fn test_encode_aac_stereo() {
        let samples = generate_sine_wave(44100, 2.0, 440.0);
        let stereo: Vec<f32> = samples.iter().flat_map(|&s| [s, s]).collect();
        let tmp = NamedTempFile::with_suffix(".aac").unwrap();

        encode_aac(tmp.path(), &stereo, 44100, 2, 64_000).unwrap();
        let decoded = decode_file(tmp.path()).unwrap();
        assert_eq!(decoded.channels, 2);
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
