//! 隐私自动销毁
//! 权威：D2 §5, PRD §0.1 #21
//!
//! 这里只提供「安全销毁一个文件」这一个原语。什么时候销毁由 vt-ffi 的
//! `enforce_privacy_after_task` 决定：high 在显式异步转录成功后销毁，
//! maximum 在停止录音且已有可重建的转录事实时就销毁。

use std::path::Path;

/// 隐私销毁器
pub struct PrivacyDestroyer;

/// 销毁错误
#[derive(Debug, thiserror::Error)]
pub enum DestroyError {
    #[error("file destroy failed: {0}")]
    FileDestroyFailed(String),

    #[error("key destroy failed: {0}")]
    KeyDestroyFailed(String),
}

impl PrivacyDestroyer {
    /// 安全销毁文件：覆写零后删除。
    pub fn destroy_file(path: &Path) -> Result<(), DestroyError> {
        if !path.exists() {
            return Ok(()); // 幂等：已不存在
        }

        // 覆写零
        let len = std::fs::metadata(path)
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?
            .len() as usize;

        let zeros = vec![0u8; len.min(64 * 1024)]; // 分块覆写
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;

        use std::io::Write;
        let mut writer = std::io::BufWriter::new(file);
        let mut remaining = len;
        while remaining > 0 {
            let to_write = remaining.min(zeros.len());
            writer
                .write_all(&zeros[..to_write])
                .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;
            remaining -= to_write;
        }
        writer
            .flush()
            .map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;
        drop(writer);

        // 删除文件
        std::fs::remove_file(path).map_err(|e| DestroyError::FileDestroyFailed(e.to_string()))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::{NamedTempFile, TempDir};

    #[test]
    fn destroy_file_removes_the_file() {
        let tmp = NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        std::fs::write(&path, vec![0xABu8; 1024]).unwrap();
        assert!(path.exists());

        PrivacyDestroyer::destroy_file(&path).unwrap();

        assert!(!path.exists(), "file should be deleted");
    }

    #[test]
    fn destroy_file_is_idempotent() {
        let tmp = NamedTempFile::new().unwrap();
        let path = tmp.path().to_path_buf();
        std::fs::write(&path, vec![0xABu8; 512]).unwrap();

        PrivacyDestroyer::destroy_file(&path).unwrap();
        // 第二次：文件已不存在，不应报错——重试销毁是正常路径。
        PrivacyDestroyer::destroy_file(&path).unwrap();
    }

    #[test]
    fn destroy_file_reports_failure_instead_of_silently_succeeding() {
        // 目录不是文件；调用方（保留策略）靠这个错误把 chunk 标成删除失败，
        // 而不是把它当成已销毁。
        let dir = TempDir::new().unwrap();
        let target = dir.path().join("not-a-file");
        std::fs::create_dir(&target).unwrap();

        let error = PrivacyDestroyer::destroy_file(&target).unwrap_err();

        assert!(
            error.to_string().contains("file destroy failed"),
            "unexpected error: {error}"
        );
        assert!(target.exists(), "failed destroy must not remove the target");
    }

    #[test]
    fn destroy_file_zeroes_content_before_unlinking() {
        // 覆写发生在 unlink 之前：把同一个 inode 的内容读回来应当全是零。
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("secret.enc");
        std::fs::write(&path, vec![0xABu8; 4096]).unwrap();
        let handle = std::fs::File::open(&path).unwrap();

        PrivacyDestroyer::destroy_file(&path).unwrap();

        use std::io::Read;
        let mut remaining = Vec::new();
        let mut handle = handle;
        handle.read_to_end(&mut remaining).unwrap();
        assert!(
            remaining.iter().all(|byte| *byte == 0),
            "plaintext survived in the unlinked inode"
        );
    }
}
