//! 流上的分帧。
//!
//! 一条长寿的双向流上连续走消息:4 字节小端长度前缀 + postcard。上一代用 JSON,
//! 字节数组被编成数字数组,体积涨三四倍;postcard 原样装字节。
//!
//! 上限是硬的:一个对端不能靠声明一个巨大的长度让本机分配任意内存。文档差量
//! 另行按 [`crate::protocol::UPDATE_CHUNK_BYTES`] 切块,所以单帧不会逼近上限。

use serde::{de::DeserializeOwned, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// 单帧字节上限。差量按 1 MiB 切块,文档摘要几千条也只有几百 KB。
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum WireError {
    #[error("流读写失败: {0}")]
    Io(#[from] std::io::Error),
    #[error("消息 {actual} 字节,超过上限 {MAX_FRAME_BYTES}")]
    TooLarge { actual: usize },
    #[error("消息编解码失败: {0}")]
    Codec(#[from] postcard::Error),
}

pub async fn write_frame<W, T>(writer: &mut W, value: &T) -> Result<(), WireError>
where
    W: AsyncWriteExt + Unpin,
    T: Serialize,
{
    let body = postcard::to_stdvec(value)?;
    if body.len() > MAX_FRAME_BYTES {
        return Err(WireError::TooLarge { actual: body.len() });
    }
    writer.write_all(&(body.len() as u32).to_le_bytes()).await?;
    writer.write_all(&body).await?;
    Ok(())
}

/// 读一帧。长度先于分配被校验。
pub async fn read_frame<R, T>(reader: &mut R) -> Result<T, WireError>
where
    R: AsyncReadExt + Unpin,
    T: DeserializeOwned,
{
    let mut len_bytes = [0u8; 4];
    reader.read_exact(&mut len_bytes).await?;
    let len = u32::from_le_bytes(len_bytes) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(WireError::TooLarge { actual: len });
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).await?;
    Ok(postcard::from_bytes(&body)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_frame_round_trips_and_a_huge_length_is_refused_before_allocating() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        write_frame(&mut a, &(7u32, vec![1u8, 2, 3])).await.unwrap();
        let back: (u32, Vec<u8>) = read_frame(&mut b).await.unwrap();
        assert_eq!(back, (7, vec![1, 2, 3]));

        a.write_all(&u32::MAX.to_le_bytes()).await.unwrap();
        let refused = read_frame::<_, (u32, Vec<u8>)>(&mut b).await;
        assert!(matches!(refused, Err(WireError::TooLarge { .. })));
    }
}
