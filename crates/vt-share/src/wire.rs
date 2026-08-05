//! 流上的分帧与长度上限。
//!
//! 每条 uni-stream 承载一条消息:4 字节小端长度前缀 + JSON。上限是硬的 ——
//! 一个远端 peer 不能靠声明一个巨大的长度让本机分配任意内存。

use serde::{de::DeserializeOwned, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// 单条消息的字节上限。
///
/// 字幕帧实测在十几 KB 量级(八行 × 多语言),Loro 更新在粘贴整段时更大。
/// 4 MiB 给足余量,同时把「远端声明 4 GiB 长度」这类内存耗尽挡在外面。
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum WireError {
    #[error("流读写失败: {0}")]
    Io(#[from] std::io::Error),
    #[error("消息 {actual} 字节,超过上限 {MAX_MESSAGE_BYTES}")]
    TooLarge { actual: usize },
    #[error("消息解码失败: {0}")]
    Decode(#[from] serde_json::Error),
}

/// 写一条带长度前缀的消息。
pub async fn write_message<W, T>(writer: &mut W, value: &T) -> Result<(), WireError>
where
    W: AsyncWriteExt + Unpin,
    T: Serialize,
{
    let body = serde_json::to_vec(value)?;
    if body.len() > MAX_MESSAGE_BYTES {
        return Err(WireError::TooLarge { actual: body.len() });
    }
    writer.write_all(&(body.len() as u32).to_le_bytes()).await?;
    writer.write_all(&body).await?;
    Ok(())
}

/// 读一条带长度前缀的消息。
///
/// 长度先于分配被校验 —— 先信任长度再 `with_capacity` 就是一个远端可触发的
/// 内存耗尽。
pub async fn read_message<R, T>(reader: &mut R) -> Result<T, WireError>
where
    R: AsyncReadExt + Unpin,
    T: DeserializeOwned,
{
    let mut len_bytes = [0u8; 4];
    reader.read_exact(&mut len_bytes).await?;
    let len = u32::from_le_bytes(len_bytes) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(WireError::TooLarge { actual: len });
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).await?;
    Ok(serde_json::from_slice(&body)?)
}

/// 文本资源的完整性校验值。
///
/// 不用 iroh-blobs 的内容寻址,所以自己带一个 —— 几十 KB 的文本用 SHA-256 足够,
/// 不需要 BLAKE3 的分块可验证流。
pub fn content_digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
    struct Sample {
        text: String,
        n: u64,
    }

    fn sample() -> Sample {
        Sample {
            text: "こんにちは / สวัสดี / hello".into(),
            n: 42,
        }
    }

    #[tokio::test]
    async fn message_round_trips() {
        let mut buf = Vec::new();
        write_message(&mut buf, &sample()).await.unwrap();
        let mut cursor = std::io::Cursor::new(buf);
        let back: Sample = read_message(&mut cursor).await.unwrap();
        assert_eq!(back, sample());
    }

    #[tokio::test]
    async fn several_messages_stream_back_in_order() {
        let mut buf = Vec::new();
        for n in 0..5u64 {
            write_message(
                &mut buf,
                &Sample {
                    text: "x".into(),
                    n,
                },
            )
            .await
            .unwrap();
        }
        let mut cursor = std::io::Cursor::new(buf);
        for expected in 0..5u64 {
            let got: Sample = read_message(&mut cursor).await.unwrap();
            assert_eq!(got.n, expected);
        }
    }

    /// 远端声明一个巨大长度时,必须在分配之前就被拒。
    #[tokio::test]
    async fn oversized_declared_length_is_refused_before_allocating() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&u32::MAX.to_le_bytes());
        let mut cursor = std::io::Cursor::new(buf);
        let err = read_message::<_, Sample>(&mut cursor).await.unwrap_err();
        assert!(matches!(err, WireError::TooLarge { .. }));
    }

    #[tokio::test]
    async fn truncated_body_is_an_error_not_a_partial_value() {
        let mut buf = Vec::new();
        write_message(&mut buf, &sample()).await.unwrap();
        buf.truncate(buf.len() - 3);
        let mut cursor = std::io::Cursor::new(buf);
        assert!(read_message::<_, Sample>(&mut cursor).await.is_err());
    }

    #[test]
    fn digest_is_stable_and_distinguishes_content() {
        assert_eq!(content_digest(b"abc"), content_digest(b"abc"));
        assert_ne!(content_digest(b"abc"), content_digest(b"abd"));
        assert_eq!(content_digest(b"").len(), 64);
    }
}
