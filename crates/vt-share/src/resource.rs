//! 文本资源的请求与应答。
//!
//! 能跨机器传的东西只有 [`ShareableKind`] 里列出的几种,**全部是文本**,几十 KB
//! 量级。所以这里没有分块、没有断点续传、也没有 `iroh-blobs`:一次请求、一次应答、
//! 一个 SHA-256 校验就够了。
//!
//! 请求里带的是 `(session_id, ShareableKind)`,**不是路径**。调用方无法表达
//! 「把这个文件发出去」,只能表达「把这个 session 的转录稿发出去」—— 音频没有对应
//! 的 kind,所以它连被请求的资格都没有。

use serde::{Deserialize, Serialize};

use crate::shareable::ShareableKind;
use crate::wire::content_digest;

/// 单份资源的字节上限。
///
/// 文本转录稿远小于此。这个上限存在的意义是:一个被篡改的对端不能通过声明一份
/// 巨大的资源来耗尽本机内存。
pub const MAX_RESOURCE_BYTES: usize = 8 * 1024 * 1024;

/// 索要一份资源。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceRequest {
    pub session_id: String,
    pub kind: ShareableKind,
}

/// 一份资源的应答。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ResourceResponse {
    /// 内容与它的 SHA-256。
    Delivered {
        kind: ShareableKind,
        /// UTF-8 文本。这个类型本身就排除了二进制音频。
        text: String,
        sha256: String,
    },
    /// 本机没有这份资源,或它尚未生成。
    Unavailable { reason: String },
}

/// 校验失败的原因。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ResourceError {
    #[error("对端拒绝提供: {0}")]
    Unavailable(String),
    #[error("应答的资源类型与请求不符")]
    KindMismatch,
    #[error("内容与校验值不符")]
    DigestMismatch,
    #[error("资源 {actual} 字节,超过上限 {MAX_RESOURCE_BYTES}")]
    TooLarge { actual: usize },
}

impl ResourceResponse {
    /// 按请求打包一份内容。
    pub fn deliver(kind: ShareableKind, text: String) -> Self {
        let sha256 = content_digest(text.as_bytes());
        Self::Delivered { kind, text, sha256 }
    }

    /// 校验并取出内容。
    ///
    /// 三件事一起查:对端是不是拒绝了、给的类型对不对、内容有没有被改过。
    /// 类型必须校验 —— 否则一个恶意对端可以在你请求转录稿时塞回别的东西。
    pub fn into_verified_text(self, requested: ShareableKind) -> Result<String, ResourceError> {
        match self {
            Self::Unavailable { reason } => Err(ResourceError::Unavailable(reason)),
            Self::Delivered { kind, text, sha256 } => {
                if kind != requested {
                    return Err(ResourceError::KindMismatch);
                }
                if text.len() > MAX_RESOURCE_BYTES {
                    return Err(ResourceError::TooLarge { actual: text.len() });
                }
                if content_digest(text.as_bytes()) != sha256 {
                    return Err(ResourceError::DigestMismatch);
                }
                Ok(text)
            }
        }
    }
}

/// 本机能提供哪些资源。
///
/// 由持有数据的一侧(vt-ffi)实现。返回 `None` 表示这份资源不存在或尚未生成。
///
/// 注意签名:它收的是 `(session_id, ShareableKind)`,交出的是 `String`。
/// **没有任何一处能表达路径或字节流**,所以音频不可能从这里漏出去。
pub trait ResourceProvider: Send + Sync {
    fn provide(&self, session_id: &str, kind: ShareableKind) -> Option<String>;
}

/// 按请求应答。
pub fn answer(provider: &dyn ResourceProvider, request: &ResourceRequest) -> ResourceResponse {
    match provider.provide(&request.session_id, request.kind) {
        Some(text) if text.len() > MAX_RESOURCE_BYTES => ResourceResponse::Unavailable {
            reason: "资源超过分享上限".into(),
        },
        Some(text) => ResourceResponse::deliver(request.kind, text),
        None => ResourceResponse::Unavailable {
            reason: "资源不存在或尚未生成".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(&'static str);
    impl ResourceProvider for Fixed {
        fn provide(&self, _session_id: &str, _kind: ShareableKind) -> Option<String> {
            Some(self.0.to_string())
        }
    }

    struct Missing;
    impl ResourceProvider for Missing {
        fn provide(&self, _session_id: &str, _kind: ShareableKind) -> Option<String> {
            None
        }
    }

    fn request(kind: ShareableKind) -> ResourceRequest {
        ResourceRequest {
            session_id: "s-1".into(),
            kind,
        }
    }

    #[test]
    fn delivered_text_round_trips() {
        let response = answer(
            &Fixed("転写テキスト"),
            &request(ShareableKind::RealtimeTranscript),
        );
        let text = response
            .into_verified_text(ShareableKind::RealtimeTranscript)
            .unwrap();
        assert_eq!(text, "転写テキスト");
    }

    #[test]
    fn missing_resource_reports_unavailable() {
        let response = answer(&Missing, &request(ShareableKind::AsyncTranscript));
        let error = response
            .into_verified_text(ShareableKind::AsyncTranscript)
            .unwrap_err();
        assert!(matches!(error, ResourceError::Unavailable(_)));
    }

    /// 内容被改过就必须被发现 —— 这是不用 blobs 内容寻址后自己补上的完整性校验。
    #[test]
    fn tampered_content_is_detected() {
        let mut response = ResourceResponse::deliver(ShareableKind::PersonalNote, "原文".into());
        if let ResourceResponse::Delivered { text, .. } = &mut response {
            *text = "被替换的内容".into();
        }
        assert_eq!(
            response.into_verified_text(ShareableKind::PersonalNote),
            Err(ResourceError::DigestMismatch)
        );
    }

    /// 请求转录稿却收到笔记,必须拒收。
    #[test]
    fn substituted_kind_is_refused() {
        let response = ResourceResponse::deliver(ShareableKind::PersonalNote, "笔记".into());
        assert_eq!(
            response.into_verified_text(ShareableKind::RealtimeTranscript),
            Err(ResourceError::KindMismatch)
        );
    }

    #[test]
    fn oversized_resource_is_refused_on_both_sides() {
        let big = "x".repeat(MAX_RESOURCE_BYTES + 1);
        // 提供方不发。
        let response = answer(
            &Fixed(Box::leak(big.clone().into_boxed_str())),
            &request(ShareableKind::TextExportBundle),
        );
        assert!(matches!(response, ResourceResponse::Unavailable { .. }));

        // 接收方即便收到也不认。
        let forced = ResourceResponse::deliver(ShareableKind::TextExportBundle, big);
        assert!(matches!(
            forced.into_verified_text(ShareableKind::TextExportBundle),
            Err(ResourceError::TooLarge { .. })
        ));
    }

    /// 每一种可分享类型都能走通这条路 —— 而音频不在这个清单里,所以它没有入口。
    #[test]
    fn every_shareable_kind_can_be_requested() {
        for kind in ShareableKind::ALL {
            let response = answer(&Fixed("内容"), &request(*kind));
            assert_eq!(response.into_verified_text(*kind).unwrap(), "内容");
        }
    }

    #[test]
    fn request_round_trips_through_serde() {
        let r = request(ShareableKind::TextExportBundle);
        let bytes = serde_json::to_vec(&r).unwrap();
        assert_eq!(
            serde_json::from_slice::<ResourceRequest>(&bytes).unwrap(),
            r
        );
    }
}
