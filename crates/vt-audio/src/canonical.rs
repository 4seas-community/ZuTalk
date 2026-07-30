//! Deterministic conversion from stored interleaved PCM to Soniox wire PCM.
//!
//! Zulangue keeps imported audio in its source sample rate and channel layout
//! so local playback/export remains lossless with respect to the decoded
//! source. Provider upload has a different contract: Soniox receives 16 kHz
//! mono PCM. Keeping this conversion in Rust gives every upload path the same
//! format boundary and prevents Swift/UI state from influencing audio bytes.

use crate::AudioError;

/// Canonical sample rate used by both Soniox realtime and post-stop upload.
pub const SONIOX_CANONICAL_SAMPLE_RATE: u32 = 16_000;

/// Downmix interleaved f32 PCM and resample it to canonical 16 kHz mono.
///
/// Channel samples are averaged per frame, then linear interpolation is
/// evaluated on an integer-rational source clock. The integer clock makes the
/// output frame count and sample positions deterministic for a given input.
pub fn canonicalize_for_soniox(
    interleaved_samples: &[f32],
    sample_rate: u32,
    channels: u16,
) -> Result<Vec<f32>, AudioError> {
    if sample_rate == 0 {
        return Err(AudioError::ResampleFailed(
            "source sample rate must be positive".to_string(),
        ));
    }
    if channels == 0 {
        return Err(AudioError::ResampleFailed(
            "source channel count must be positive".to_string(),
        ));
    }
    let channels = channels as usize;
    if !interleaved_samples.len().is_multiple_of(channels) {
        return Err(AudioError::ResampleFailed(format!(
            "interleaved sample count {} is not aligned to {channels} channels",
            interleaved_samples.len()
        )));
    }
    if interleaved_samples.is_empty() {
        return Ok(Vec::new());
    }

    let mono = interleaved_samples
        .chunks_exact(channels)
        .map(|frame| {
            let sum = frame.iter().fold(0.0_f64, |accumulator, sample| {
                let finite = if sample.is_finite() { *sample } else { 0.0 };
                accumulator + finite.clamp(-1.0, 1.0) as f64
            });
            (sum / channels as f64) as f32
        })
        .collect::<Vec<_>>();

    if sample_rate == SONIOX_CANONICAL_SAMPLE_RATE {
        return Ok(mono);
    }

    let output_frames_u128 = (mono.len() as u128)
        .saturating_mul(SONIOX_CANONICAL_SAMPLE_RATE as u128)
        .saturating_add((sample_rate / 2) as u128)
        / sample_rate as u128;
    let output_frames = usize::try_from(output_frames_u128.max(1)).map_err(|_| {
        AudioError::ResampleFailed("canonical output is too large for this platform".to_string())
    })?;
    let mut output = Vec::with_capacity(output_frames);

    for output_index in 0..output_frames {
        let source_position = (output_index as u128).saturating_mul(sample_rate as u128);
        let left_index = usize::try_from(source_position / SONIOX_CANONICAL_SAMPLE_RATE as u128)
            .unwrap_or(usize::MAX)
            .min(mono.len() - 1);
        let remainder = (source_position % SONIOX_CANONICAL_SAMPLE_RATE as u128) as f32;
        let fraction = remainder / SONIOX_CANONICAL_SAMPLE_RATE as f32;
        let left = mono[left_index];
        let right = mono.get(left_index + 1).copied().unwrap_or(left);
        output.push(left + (right - left) * fraction);
    }

    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_one_second_of_48k_stereo_to_16k_mono() {
        let mut stereo = Vec::with_capacity(48_000 * 2);
        for _ in 0..48_000 {
            stereo.extend_from_slice(&[0.8, 0.2]);
        }

        let canonical = canonicalize_for_soniox(&stereo, 48_000, 2).unwrap();

        assert_eq!(canonical.len(), 16_000);
        assert!(canonical.iter().all(|sample| (*sample - 0.5).abs() < 1e-6));
    }

    #[test]
    fn rejects_partial_multichannel_frames() {
        let error = canonicalize_for_soniox(&[0.1, 0.2, 0.3], 48_000, 2).unwrap_err();
        assert!(error.to_string().contains("not aligned"));
    }
}
