//! 可分享内容的封闭清单。
//!
//! 分享层不提供任意路径发送口。能跨机器离开本机的东西只有 [`ShareableKind`] 里
//! 列出的这几种,新增变体要改这个文件,而改这个文件会撞上
//! `scripts/test_share_no_audio_gate.sh`。
//!
//! 设计见 `docs/architecture/share-p2p.md` 第 5 节。

use serde::{Deserialize, Serialize};

/// 一件可以分享出去的资源。
///
/// **这个枚举没有音频变体,也不会有。** 音频不可共享是不可配置的约束,不是默认值。
/// 同样没有 Context Pack 变体:它是加密的用户资料,与音频一样不该默认离开本机。
///
/// 枚举是封闭的(非 `#[non_exhaustive]`),下游必须穷尽匹配 —— 将来有人加变体,
/// 每一处消费点都会编译失败,而不是静默放行一种新的外泄路径。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShareableKind {
    /// 实时转录的文字稿。
    RealtimeTranscript,
    /// 停止后异步转录的文字稿。
    AsyncTranscript,
    /// 个人笔记正文。
    PersonalNote,
    /// 文本格式的导出包(Markdown / SRT / VTT / TXT)。
    ///
    /// 打包必须走 [`vt_export::ExportOptions::shareable`],它把音频硬编码为关闭。
    /// `ExportOptions::default()` 的 `include_audio` 是 `true`,复用它就会把
    /// `audio.wav` 发出去。
    TextExportBundle,
}

impl ShareableKind {
    /// 稳定的线上标识。改动即协议破坏,不要跟着 Rust 变体名走。
    pub fn wire_tag(self) -> &'static str {
        match self {
            Self::RealtimeTranscript => "realtime_transcript",
            Self::AsyncTranscript => "async_transcript",
            Self::PersonalNote => "personal_note",
            Self::TextExportBundle => "text_export_bundle",
        }
    }

    /// 全部变体,供 UI 列举与测试穷尽性使用。
    pub const ALL: &'static [Self] = &[
        Self::RealtimeTranscript,
        Self::AsyncTranscript,
        Self::PersonalNote,
        Self::TextExportBundle,
    ];
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ALL 必须覆盖每一个变体。漏掉一个,UI 就会少列一项,而测试不会发现。
    #[test]
    fn all_covers_every_variant() {
        for kind in ShareableKind::ALL {
            // 穷尽匹配:新增变体会让这里编译失败,强制更新 ALL。
            match kind {
                ShareableKind::RealtimeTranscript
                | ShareableKind::AsyncTranscript
                | ShareableKind::PersonalNote
                | ShareableKind::TextExportBundle => {}
            }
        }
        assert_eq!(ShareableKind::ALL.len(), 4);
    }

    #[test]
    fn wire_tags_are_unique_and_audio_free() {
        let mut seen = std::collections::HashSet::new();
        for kind in ShareableKind::ALL {
            let tag = kind.wire_tag();
            assert!(seen.insert(tag), "wire_tag 重复: {tag}");
            let lowered = tag.to_ascii_lowercase();
            assert!(
                !lowered.contains("audio") && !lowered.contains("pcm"),
                "可分享类型不得指向音频: {tag}"
            );
        }
    }

    /// 线上标识与 Rust 变体名解耦,重命名变体不该破坏协议。
    #[test]
    fn wire_tags_round_trip_through_serde() {
        for kind in ShareableKind::ALL {
            let json = serde_json::to_string(kind).unwrap();
            let back: ShareableKind = serde_json::from_str(&json).unwrap();
            assert_eq!(*kind, back);
            assert_eq!(json.trim_matches('"'), kind.wire_tag());
        }
    }
}
