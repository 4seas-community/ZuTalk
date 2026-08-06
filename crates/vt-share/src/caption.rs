//! 实时字幕通道。
//!
//! # 为什么是「每帧一条 uni-stream」而不是 datagram
//!
//! QUIC datagram 约 1.2 KB 封顶(`iroh` 的 `Connection::max_datagram_size` 文档:
//! 数据必须装进单个 QUIC 包,随路径 MTU 变化,最低只保证「a little over a
//! kilobyte」)。而观众画布最多渲染八行,一帧含八行 utterance 加多语言 cue 加
//! lane health,中日泰 UTF-8 下轻易过万字节 —— datagram 装不下,分片重组又会让
//! 「丢一片废一帧」。
//!
//! QUIC 开 uni-stream 不需要额外往返:写完即关,帧与帧互不阻塞,没有尺寸上限。
//! 接收端读完整条流,再按 [`CaptionFrame::preview_revision`] 决定用还是丢。
//!
//! # 为什么丢帧是安全的
//!
//! 帧是 replace-in-full 的:每一帧都携带完整的当前 tail。这个性质来自采集层的
//! `FfiNotebookCaptureLivePreview`,不是这里发明的。因此跳号无害,乱序也无害 ——
//! 只要接收端只认单调变新的 revision。
//!
//! 见 `docs/architecture/share-p2p.md` 第 3 节。

use serde::{Deserialize, Serialize};

use crate::room::ScopeId;

/// 一行字幕。**纯文本,没有任何音频字段。**
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionLine {
    /// 说话人在本次会话内的稳定标识,没有则为空。
    pub speaker: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub target_language: Option<String>,
    pub target_text: Option<String>,
    /// "partial" 或 "complete"。与采集层的 `completion` 同义。
    pub completion: String,
}

/// 一帧字幕:当前 tail 的完整快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionFrame {
    pub scope: ScopeId,
    /// 只在这条预览通道内单调。跳号无害,因为每帧都是完整的。
    pub preview_revision: u64,
    pub lines: Vec<CaptionLine>,
}

/// 接收端的字幕投影。
///
/// 只在内存里,不落库 —— 观看到的是**别人的**内容,不是本机 Notebook 的一部分。
#[derive(Debug, Default)]
pub struct CaptionReceiver {
    applied_revision: Option<u64>,
    lines: Vec<CaptionLine>,
}

/// 一帧被接收后的处置。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameOutcome {
    /// 帧更新,已替换当前投影。
    Applied,
    /// 帧比已应用的旧或相同,丢弃。乱序到达时这是正常情况,不是错误。
    Stale,
    /// 帧属于另一个共享范围,丢弃。
    WrongScope,
}

impl CaptionReceiver {
    pub fn new() -> Self {
        Self::default()
    }

    /// 已应用的 revision;还没收到任何帧时为 `None`。
    pub fn applied_revision(&self) -> Option<u64> {
        self.applied_revision
    }

    pub fn lines(&self) -> &[CaptionLine] {
        &self.lines
    }

    /// 收下一帧。
    ///
    /// **replace-in-full**:应用即整体替换,不做增量合并。这正是丢帧无害的原因 ——
    /// 中间少收几帧,下一帧照样描述完整的当前状态。
    pub fn accept(&mut self, frame: CaptionFrame, expected_scope: &ScopeId) -> FrameOutcome {
        if &frame.scope != expected_scope {
            return FrameOutcome::WrongScope;
        }
        if let Some(applied) = self.applied_revision {
            if frame.preview_revision <= applied {
                return FrameOutcome::Stale;
            }
        }
        self.applied_revision = Some(frame.preview_revision);
        self.lines = frame.lines;
        FrameOutcome::Applied
    }

    /// 广播结束或断线时清空。投影不留残影。
    pub fn clear(&mut self) {
        self.applied_revision = None;
        self.lines.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> ScopeId {
        ScopeId::Session {
            session_id: "s-1".into(),
        }
    }

    fn other_scope() -> ScopeId {
        ScopeId::Session {
            session_id: "s-2".into(),
        }
    }

    fn frame(revision: u64, text: &str) -> CaptionFrame {
        CaptionFrame {
            scope: scope(),
            preview_revision: revision,
            lines: vec![CaptionLine {
                speaker: None,
                source_language: "ja".into(),
                source_text: text.into(),
                target_language: Some("zh-Hans".into()),
                target_text: Some(format!("译:{text}")),
                completion: "partial".into(),
            }],
        }
    }

    #[test]
    fn first_frame_applies() {
        let mut rx = CaptionReceiver::new();
        assert_eq!(
            rx.accept(frame(1, "こんにちは"), &scope()),
            FrameOutcome::Applied
        );
        assert_eq!(rx.applied_revision(), Some(1));
        assert_eq!(rx.lines().len(), 1);
    }

    /// 跳号必须照常应用 —— 中间丢掉的帧不需要补。
    #[test]
    fn skipped_revisions_are_harmless() {
        let mut rx = CaptionReceiver::new();
        rx.accept(frame(1, "a"), &scope());
        assert_eq!(rx.accept(frame(99, "b"), &scope()), FrameOutcome::Applied);
        assert_eq!(rx.applied_revision(), Some(99));
        assert_eq!(rx.lines()[0].source_text, "b");
    }

    /// 乱序到达的旧帧必须被丢弃,不能把画面倒回去。
    #[test]
    fn out_of_order_old_frame_is_dropped() {
        let mut rx = CaptionReceiver::new();
        rx.accept(frame(10, "new"), &scope());
        assert_eq!(rx.accept(frame(9, "old"), &scope()), FrameOutcome::Stale);
        assert_eq!(rx.lines()[0].source_text, "new");
        assert_eq!(rx.applied_revision(), Some(10));
    }

    /// 同号重复(uni-stream 重发)也要丢,否则会白刷一次画面。
    #[test]
    fn duplicate_revision_is_dropped() {
        let mut rx = CaptionReceiver::new();
        rx.accept(frame(5, "x"), &scope());
        assert_eq!(rx.accept(frame(5, "y"), &scope()), FrameOutcome::Stale);
        assert_eq!(rx.lines()[0].source_text, "x");
    }

    #[test]
    fn frame_from_another_scope_is_dropped() {
        let mut rx = CaptionReceiver::new();
        let mut foreign = frame(1, "x");
        foreign.scope = other_scope();
        assert_eq!(rx.accept(foreign, &scope()), FrameOutcome::WrongScope);
        assert_eq!(rx.applied_revision(), None);
    }

    /// 替换是整体的:上一帧的多余行不能残留。
    #[test]
    fn apply_replaces_in_full() {
        let mut rx = CaptionReceiver::new();
        let mut wide = frame(1, "a");
        wide.lines.push(wide.lines[0].clone());
        wide.lines.push(wide.lines[0].clone());
        rx.accept(wide, &scope());
        assert_eq!(rx.lines().len(), 3);

        rx.accept(frame(2, "b"), &scope());
        assert_eq!(rx.lines().len(), 1);
    }

    #[test]
    fn clear_resets_projection() {
        let mut rx = CaptionReceiver::new();
        rx.accept(frame(7, "x"), &scope());
        rx.clear();
        assert_eq!(rx.applied_revision(), None);
        assert!(rx.lines().is_empty());
        // 清空后旧 revision 可以重新进来 —— 新一轮广播从头计数。
        assert_eq!(rx.accept(frame(1, "y"), &scope()), FrameOutcome::Applied);
    }

    #[test]
    fn frame_round_trips_through_serde() {
        let f = frame(3, "テスト");
        let bytes = serde_json::to_vec(&f).unwrap();
        let back: CaptionFrame = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(back, f);
    }
}
