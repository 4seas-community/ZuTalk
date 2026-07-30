//! 流式解密读取器 + 范围解密
//! 设计引用：D2 §3, §3.5

use std::io::{self, Read};
use std::path::Path;

use crate::encrypt::{decrypt_chunk, encrypt_chunk};
use crate::session_key::SessionKey;
use crate::CryptoError;

/// 加密文件中每个 chunk 的明文大小（64KB）
const CHUNK_SIZE: usize = 64 * 1024;

/// 将数据分 chunk 加密写入文件
/// 文件格式: [chunk_len_u32_le | encrypted_chunk] ...
pub fn encrypt_to_file(
    path: impl AsRef<Path>,
    key: &SessionKey,
    data: &[u8],
) -> Result<(), CryptoError> {
    let mut file_data = Vec::new();

    for chunk in data.chunks(CHUNK_SIZE) {
        let encrypted = encrypt_chunk(chunk, key)?;
        let len = encrypted.len() as u32;
        file_data.extend_from_slice(&len.to_le_bytes());
        file_data.extend_from_slice(&encrypted);
    }

    std::fs::write(path, &file_data).map_err(|e| CryptoError::EncryptionFailed {
        message: e.to_string(),
    })?;

    Ok(())
}

/// 流式解密读取器
pub struct DecryptReader {
    /// 加密文件的全部数据
    file_data: Vec<u8>,
    /// 当前在 file_data 中的读取位置
    file_offset: usize,
    /// 解密后的当前 chunk 缓冲
    buffer: Vec<u8>,
    /// 在 buffer 中的读取位置
    buf_offset: usize,
    /// 解密密钥
    key: SessionKey,
}

impl DecryptReader {
    pub fn new(path: impl AsRef<Path>, key: &SessionKey) -> Result<Self, CryptoError> {
        let file_data = std::fs::read(path).map_err(|e| CryptoError::DecryptionFailed {
            message: e.to_string(),
        })?;

        Ok(Self {
            file_data,
            file_offset: 0,
            buffer: Vec::new(),
            buf_offset: 0,
            key: SessionKey::from_bytes(*key.as_bytes()),
        })
    }

    /// 读取下一个加密 chunk 并解密到 buffer
    fn fill_buffer(&mut self) -> Result<bool, CryptoError> {
        if self.file_offset >= self.file_data.len() {
            return Ok(false);
        }

        // Read chunk length (u32 LE)
        if self.file_offset + 4 > self.file_data.len() {
            return Ok(false);
        }
        let len_bytes = &self.file_data[self.file_offset..self.file_offset + 4];
        let chunk_len = u32::from_le_bytes(len_bytes.try_into().unwrap()) as usize;
        self.file_offset += 4;

        if self.file_offset + chunk_len > self.file_data.len() {
            return Err(CryptoError::DecryptionFailed {
                message: "truncated encrypted file".to_string(),
            });
        }

        let encrypted = &self.file_data[self.file_offset..self.file_offset + chunk_len];
        self.file_offset += chunk_len;

        self.buffer = decrypt_chunk(encrypted, &self.key)?;
        self.buf_offset = 0;
        Ok(true)
    }
}

impl Read for DecryptReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.buf_offset >= self.buffer.len() {
            match self.fill_buffer() {
                Ok(true) => {}
                Ok(false) => return Ok(0),
                Err(e) => return Err(io::Error::new(io::ErrorKind::InvalidData, e)),
            }
        }

        let available = self.buffer.len() - self.buf_offset;
        let to_copy = available.min(buf.len());
        buf[..to_copy].copy_from_slice(&self.buffer[self.buf_offset..self.buf_offset + to_copy]);
        self.buf_offset += to_copy;
        Ok(to_copy)
    }
}

/// 时间范围解密参数
pub struct DecryptRange {
    pub start_ms: u64,
    pub end_ms: u64,
    pub sample_rate: u32,
    pub channels: u16,
    pub bytes_per_sample: u16,
}

impl DecryptRange {
    /// 计算字节范围 [start_byte, end_byte)
    fn byte_range(&self) -> (usize, usize) {
        let bytes_per_ms =
            self.sample_rate as f64 * self.channels as f64 * self.bytes_per_sample as f64 / 1000.0;
        let start = (self.start_ms as f64 * bytes_per_ms) as usize;
        let end = (self.end_ms as f64 * bytes_per_ms) as usize;
        (start, end)
    }
}

/// 按时间范围解密音频片段
pub fn decrypt_range(
    path: impl AsRef<Path>,
    key: &SessionKey,
    range: &DecryptRange,
) -> Result<Vec<u8>, CryptoError> {
    let mut reader = DecryptReader::new(path, key)?;
    let mut all_data = Vec::new();
    reader
        .read_to_end(&mut all_data)
        .map_err(|e| CryptoError::DecryptionFailed {
            message: e.to_string(),
        })?;

    let (start, end) = range.byte_range();
    let start = start.min(all_data.len());
    let end = end.min(all_data.len());

    Ok(all_data[start..end].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decrypt_full_file() {
        let original = vec![0xABu8; 16000 * 2 * 10]; // ~10s 16kHz 16bit
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let key = SessionKey::generate();

        encrypt_to_file(tmp.path(), &key, &original).unwrap();

        let mut reader = DecryptReader::new(tmp.path(), &key).unwrap();
        let mut decrypted = Vec::new();
        reader.read_to_end(&mut decrypted).unwrap();

        assert_eq!(decrypted, original);
    }

    #[test]
    fn test_decrypt_range() {
        let sample_rate = 16000u32;
        let channels = 1u16;
        let bytes_per_sample = 2u16;
        let total_bytes = sample_rate as usize * channels as usize * bytes_per_sample as usize * 30; // 30s
        let original: Vec<u8> = (0..total_bytes).map(|i| (i % 256) as u8).collect();

        let tmp = tempfile::NamedTempFile::new().unwrap();
        let key = SessionKey::generate();
        encrypt_to_file(tmp.path(), &key, &original).unwrap();

        let range = DecryptRange {
            start_ms: 10_000,
            end_ms: 15_000,
            sample_rate,
            channels,
            bytes_per_sample,
        };
        let segment = decrypt_range(tmp.path(), &key, &range).unwrap();

        // 5 seconds at 16kHz mono 16bit = 160000 bytes
        let expected_len = 16000_usize * 2 * 5;
        assert_eq!(
            segment.len(),
            expected_len,
            "segment should be 5s = {expected_len} bytes"
        );
    }

    #[test]
    fn test_decrypt_wrong_key_fails() {
        let original = vec![42u8; 1024];
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let key = SessionKey::generate();
        let wrong_key = SessionKey::generate();

        encrypt_to_file(tmp.path(), &key, &original).unwrap();

        let reader = DecryptReader::new(tmp.path(), &wrong_key);
        assert!(reader.is_ok()); // file opens fine, decrypt fails on read

        let mut reader = reader.unwrap();
        let mut buf = Vec::new();
        let result = reader.read_to_end(&mut buf);
        assert!(result.is_err(), "wrong key should cause decrypt failure");
    }

    #[test]
    fn test_decrypt_large_file_streaming() {
        let size = 16000 * 2 * 300; // ~5 min
        let original = vec![0xCDu8; size];
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let key = SessionKey::generate();
        encrypt_to_file(tmp.path(), &key, &original).unwrap();

        let mut reader = DecryptReader::new(tmp.path(), &key).unwrap();
        let mut total_read = 0usize;
        let mut buf = [0u8; 4096];
        loop {
            let n = reader.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            total_read += n;
        }
        assert_eq!(total_read, size);
    }

    #[test]
    fn test_encrypt_decrypt_empty() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let key = SessionKey::generate();
        encrypt_to_file(tmp.path(), &key, &[]).unwrap();

        let mut reader = DecryptReader::new(tmp.path(), &key).unwrap();
        let mut buf = Vec::new();
        reader.read_to_end(&mut buf).unwrap();
        assert!(buf.is_empty());
    }
}
