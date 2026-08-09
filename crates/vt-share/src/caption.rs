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

/// 一句话在线上帧里的完整形态。字段与采集层的
/// `FfiNotebookCaptureUtterance` 逐一对应,但**镜像声明,不引用** ——
/// `vt-share` 依赖不到 `vt-ffi`,这是依赖图门禁的一部分。
///
/// 主机本地的投影水位(`source_projection_revision` 等)不过网:它们描述的是
/// 主机自己的落库进度,对接收端没有意义。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionUtterance {
    pub id: String,
    pub session_id: String,
    pub sequence: u64,
    pub revision: u64,
    pub speaker: Option<String>,
    pub source_language: String,
    /// 推测性尾部的 durable 语言还是 und 时的临时车道标签。
    pub provisional_source_language: Option<String>,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    /// "partial" 或 "complete"。
    pub completion: String,
    pub alignment: String,
}

/// 一条多语言翻译 cue 的线上形态。镜像自 `FfiNotebookCaptureTranslationCue`。
/// 已撤回的 cue 不上线 —— 帧是 replace-in-full 的,缺席即撤回。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionCue {
    pub target_language: String,
    pub group_epoch: u64,
    pub provider_sequence: u64,
    pub source_language: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub text: String,
    pub completion: String,
    pub revision: u64,
}

/// 一条语言车道此刻的健康状态。镜像自 `FfiNotebookCaptureLaneHealth` 的
/// 呈现子集 —— 主机的排队延迟等诊断细节不过网。
///
/// 没有它,接收端分不清「这条车道还在连」和「这条车道坏了不会再有字」——
/// 这正是 lane health 存在的理由,压扁的行列表曾把它整个丢掉。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionLaneHealth {
    /// `None` 是 canonical 转写车道。
    pub target_language: Option<String>,
    /// "live" | "connecting" | "failed"
    pub state: String,
    pub group_epoch: u64,
}

/// 一帧字幕:当前 tail 的完整快照。
///
/// `lines` 是压扁的兼容投影(旧接收端只认它);`utterances`/`cues`/`lane_health`
/// 是完整形态,接收端有则优先使用。两份都由广播端从同一帧预览翻出,
/// 不存在分歧源。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CaptionFrame {
    pub scope: ScopeId,
    /// 只在这条预览通道内单调。跳号无害,因为每帧都是完整的。
    pub preview_revision: u64,
    pub lines: Vec<CaptionLine>,
    /// 这一帧属于主播的哪一场录音。旧帧没有这个字段,serde 默认为空。
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub utterances: Vec<CaptionUtterance>,
    #[serde(default)]
    pub cues: Vec<CaptionCue>,
    #[serde(default)]
    pub lane_health: Vec<CaptionLaneHealth>,
}

impl CaptionFrame {
    /// 只带压扁行的帧,完整形态字段为空。旧测试与不需要完整画布的路径用。
    pub fn flat(scope: ScopeId, preview_revision: u64, lines: Vec<CaptionLine>) -> Self {
        Self {
            scope,
            preview_revision,
            lines,
            session_id: String::new(),
            utterances: Vec::new(),
            cues: Vec::new(),
            lane_health: Vec::new(),
        }
    }
}

/// 接收端的字幕投影。
///
/// 只在内存里,不落库 —— 观看到的是**别人的**内容,不是本机 Notebook 的一部分。
#[derive(Debug, Default)]
pub struct CaptionReceiver {
    applied_revision: Option<u64>,
    /// 最新一帧的完整内容。replace-in-full,所以留一帧就够。
    frame: Option<CaptionFrame>,
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
        self.frame
            .as_ref()
            .map(|f| f.lines.as_slice())
            .unwrap_or(&[])
    }

    /// 最新一帧的完整形态;还没收到任何帧时为 `None`。
    pub fn latest_frame(&self) -> Option<&CaptionFrame> {
        self.frame.as_ref()
    }

    /// 收下一帧。
    ///
    /// **replace-in-full**:应用即整体替换,不做增量合并。这正是丢帧无害的原因 ——
    /// 中间少收几帧,下一帧照样描述完整的当前状态。
    ///
    /// **换场即新通道。** `preview_revision` 只在单次录音的预览通道内单调
    /// (`next_preview_revision` 每场从 1 起);Notebook 范围的房间跨越多场
    /// 录音,拿上一场的水位去卡新一场,第二场的每一帧都会被误判为 Stale ——
    /// 观看端画面从此定格。session 变了就重置水位;旧版主播的帧没有
    /// session_id(恒为空串),两帧相等,自然回落到纯单调。
    pub fn accept(&mut self, frame: CaptionFrame, expected_scope: &ScopeId) -> FrameOutcome {
        if &frame.scope != expected_scope {
            return FrameOutcome::WrongScope;
        }
        let same_session = self
            .frame
            .as_ref()
            .map(|current| current.session_id == frame.session_id)
            .unwrap_or(false);
        if same_session {
            if let Some(applied) = self.applied_revision {
                if frame.preview_revision <= applied {
                    return FrameOutcome::Stale;
                }
            }
        }
        self.applied_revision = Some(frame.preview_revision);
        self.frame = Some(frame);
        FrameOutcome::Applied
    }

    /// 广播结束或断线时清空。投影不留残影。
    pub fn clear(&mut self) {
        self.applied_revision = None;
        self.frame = None;
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
            session_id: "s-1".into(),
            utterances: vec![CaptionUtterance {
                id: "u1".into(),
                session_id: "s-1".into(),
                sequence: 1,
                revision,
                speaker: None,
                source_language: "ja".into(),
                provisional_source_language: None,
                source_text: text.into(),
                source_start_ms: Some(0),
                source_end_ms: Some(500),
                translated_language: Some("zh-Hans".into()),
                translated_text: Some(format!("译:{text}")),
                completion: "partial".into(),
                alignment: "aligned".into(),
            }],
            cues: vec![CaptionCue {
                target_language: "ko".into(),
                group_epoch: 1,
                provider_sequence: 1,
                source_language: "ja".into(),
                source_start_ms: Some(0),
                source_end_ms: Some(500),
                text: "안녕".into(),
                completion: "partial".into(),
                revision,
            }],
            lane_health: vec![CaptionLaneHealth {
                target_language: Some("ko".into()),
                state: "live".into(),
                group_epoch: 1,
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

    /// 旧版广播端的帧没有完整形态字段,新接收端必须照收 —— 压扁的
    /// `lines` 仍在,只是完整画布退化为分享页的行列表。
    #[test]
    fn legacy_frame_without_rich_fields_still_decodes() {
        let legacy = serde_json::json!({
            "scope": { "session": { "session_id": "s-1" } },
            "preview_revision": 4,
            "lines": [{
                "speaker": null,
                "source_language": "ja",
                "source_text": "旧帧",
                "target_language": null,
                "target_text": null,
                "completion": "partial"
            }]
        });
        let back: CaptionFrame = serde_json::from_value(legacy).unwrap();
        assert_eq!(back.preview_revision, 4);
        assert_eq!(back.lines.len(), 1);
        assert!(back.session_id.is_empty());
        assert!(back.utterances.is_empty());
        assert!(back.cues.is_empty());
        assert!(back.lane_health.is_empty());
    }

    /// 换场即新通道:第二场录音的 revision 从头计数,不能被上一场的水位
    /// 卡死 —— 否则 Notebook 范围的房间从第二场起画面永远定格。
    #[test]
    fn a_new_session_resets_the_revision_watermark() {
        let mut rx = CaptionReceiver::new();
        let mut first = frame(87, "第一场结尾");
        first.session_id = "session-a".into();
        assert_eq!(rx.accept(first, &scope()), FrameOutcome::Applied);

        // 新一场,revision 回到 1:必须照常应用。
        let mut second = frame(1, "第二场开头");
        second.session_id = "session-b".into();
        assert_eq!(rx.accept(second, &scope()), FrameOutcome::Applied);
        assert_eq!(rx.applied_revision(), Some(1));
        assert_eq!(rx.lines()[0].source_text, "第二场开头");

        // 同一场内旧帧照旧丢弃 —— 重置只发生在换场那一下。
        let mut stale = frame(1, "迟到帧");
        stale.session_id = "session-b".into();
        assert_eq!(rx.accept(stale, &scope()), FrameOutcome::Stale);
    }

    /// 完整形态随帧替换:接收端手里永远只有最新一帧的 utterance/cue。
    #[test]
    fn latest_frame_exposes_rich_payload_and_replaces_in_full() {
        let mut rx = CaptionReceiver::new();
        rx.accept(frame(1, "一"), &scope());
        rx.accept(frame(2, "二"), &scope());
        let latest = rx.latest_frame().expect("已收到帧");
        assert_eq!(latest.utterances.len(), 1);
        assert_eq!(latest.utterances[0].source_text, "二");
        assert_eq!(latest.session_id, "s-1");
        assert_eq!(latest.cues.len(), 1);
        assert_eq!(latest.lane_health[0].state, "live");
    }
}
