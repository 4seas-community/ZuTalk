//! 文件导入管道
//! 权威：D3 §2.5, D2 §4

use std::path::{Path, PathBuf};

use vt_audio::{decode_file, AudioError};
use vt_crypto::decrypt::encrypt_to_file;
use vt_crypto::SessionKey;

use crate::recording::f32_samples_to_bytes;

/// 导入结果
pub struct ImportResult {
    pub session_id: String,
    pub encrypted_path: PathBuf,
    pub encryption_key: SessionKey,
    pub source_format: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub duration_ms: u64,
}

/// 导入错误
#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("decode failed: {0}")]
    DecodeFailed(String),

    #[error("encrypt failed: {0}")]
    EncryptFailed(String),

    #[error("I/O error: {0}")]
    IoError(String),
}

impl From<AudioError> for ImportError {
    fn from(e: AudioError) -> Self {
        ImportError::DecodeFailed(e.to_string())
    }
}

/// 导入音频文件：解码 → 加密副本存储
pub async fn import_audio_file(
    source: &Path,
    data_dir: &Path,
) -> Result<ImportResult, ImportError> {
    let source_format = source
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("unknown")
        .to_string();

    // 解码音频文件
    let decoded = decode_file(source)?;

    // 转为字节
    let pcm_bytes = f32_samples_to_bytes(&decoded.samples);

    // 生成 session ID 和密钥
    let session_id = uuid::Uuid::new_v4().to_string();
    let key = SessionKey::generate();

    // 确保数据目录存在
    if !data_dir.exists() {
        std::fs::create_dir_all(data_dir).map_err(|e| ImportError::IoError(e.to_string()))?;
    }

    // 加密写入
    let enc_path = data_dir.join(format!("{session_id}.enc"));
    encrypt_to_file(&enc_path, &key, &pcm_bytes)
        .map_err(|e| ImportError::EncryptFailed(e.to_string()))?;

    // 计算时长
    let total_samples = decoded.samples.len() / decoded.channels as usize;
    let duration_ms = if decoded.sample_rate > 0 {
        (total_samples as u64 * 1000) / decoded.sample_rate as u64
    } else {
        0
    };

    Ok(ImportResult {
        session_id,
        encrypted_path: enc_path,
        encryption_key: key,
        source_format,
        sample_rate: decoded.sample_rate,
        channels: decoded.channels,
        duration_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use tempfile::TempDir;
    use vt_crypto::decrypt::DecryptReader;

    fn test_fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../vt-audio/tests/fixtures")
            .join(name)
    }

    #[tokio::test]
    async fn test_import_mp3() {
        let tmp = TempDir::new().unwrap();
        let source = test_fixture("test_44k_stereo.mp3");

        let result = import_audio_file(&source, tmp.path()).await.unwrap();

        assert!(result.encrypted_path.exists());
        assert!(source.exists(), "original file should not be deleted");
        assert!(!result.session_id.is_empty());
        assert_eq!(result.source_format, "mp3");
        assert_eq!(result.sample_rate, 44100);
        assert_eq!(result.channels, 2);
    }

    #[tokio::test]
    async fn test_import_wav() {
        let tmp = TempDir::new().unwrap();
        let source = test_fixture("test_16k_mono.wav");

        let result = import_audio_file(&source, tmp.path()).await.unwrap();

        assert!(result.encrypted_path.exists());
        assert_eq!(result.source_format, "wav");
        assert_eq!(result.sample_rate, 16000);
        assert_eq!(result.channels, 1);
        assert!(result.duration_ms > 2500); // ~3s fixture
    }

    #[tokio::test]
    async fn test_import_decrypt_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let source = test_fixture("test_16k_mono.wav");

        let result = import_audio_file(&source, tmp.path()).await.unwrap();

        // Decrypt and verify PCM data can be read
        let mut reader =
            DecryptReader::new(&result.encrypted_path, &result.encryption_key).unwrap();
        let mut decrypted = Vec::new();
        reader.read_to_end(&mut decrypted).unwrap();

        // Should have some audio data
        assert!(!decrypted.is_empty());

        // Should be f32 samples (4 bytes each)
        assert_eq!(decrypted.len() % 4, 0);
    }

    // 审计结论（docs/audit/tests/01-vt-pipeline.md #25, #26）：
    // 删除 test_import_nonexistent_file 和 test_import_unsupported_format。两条都是
    // 在验证 symphonia::decode_file 的兜底错误路径，不在 import 模块自己的逻辑里。
    // 真正的 import 正路径覆盖由 test_import_mp3 / test_import_wav /
    // test_import_decrypt_roundtrip 三条承担。
}
