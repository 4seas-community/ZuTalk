//! 网页分享:把当前主持的字幕帧与块快照推给 caption-web 服务。
//!
//! 设计见 `docs/architecture/share-web-captions.md`。三条不动摇的边界:
//!
//! 1. **帧必须经 `ShareCaptionTap` 的同一放行判定**再进这里 —— 范围过滤与
//!    per-session 静音只有一套,P2P 不发的帧网页也不发。
//! 2. **推送不阻塞采集**。帧与块都进 `watch` 通道(新值覆盖旧值,与
//!    replace-in-full 天然搭配),独立任务慢慢发,发不动就只发最新。
//! 3. **纯文本**。这条通道承载的类型与 P2P 字幕通道相同,音频门禁
//!    (share-p2p.md §5)原样生效。
//!
//! 明文取舍:网页分享开启后字幕明文经过服务器 —— 这是用户明示的决定
//! (2026-08-09),UI 负责把这句话说出来,这里负责除此之外别无泄漏
//! (发布口令只在内存,不落盘)。

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use vt_share::CaptionFrame;

use crate::{CoreError, ZulangueCore};

/// 默认部署位。与 invite / relay 同一域名家族,可在开启时覆盖。
pub const DEFAULT_WEB_CAPTION_SERVICE: &str = "https://zulangue-caption.exe.xyz";

/// 给 UI 的网页分享快照。
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiWebShareInfo {
    /// 观看页地址 —— 二维码与复制按钮的内容。
    pub viewer_url: String,
}

/// 块快照的线上形态。FFI 记录不带 serde,这里镜像声明。
#[derive(Debug, Clone, Serialize)]
struct WebBlock {
    id: String,
    owner: String,
    text: String,
    lanes: HashMap<String, String>,
}

/// 一个 session 的稿。replace-in-full:服务端按 session 只留最新。
#[derive(Debug, Clone, Serialize)]
struct WebBlocksPayload {
    session_id: String,
    blocks: Vec<WebBlock>,
}

/// 录音的开始/暂停在网页上的分割线。
///
/// 帧与稿都是 replace-in-full 的**状态**,分割线是**事件** —— 房间不散、
/// 录音停了又开,这件事在状态里没有痕迹(帧只是不再来了)。所以它单独
/// 走一条追加式通道:顺序有意义,不能被新值覆盖。
#[derive(Debug, Clone, Serialize)]
struct WebSegmentPayload {
    /// "started"(开录/恢复)或 "paused"(暂停)。
    kind: String,
    session_id: String,
    /// 主播机器上的墙钟秒。网页按观看者本地时区格式化 —— 会议现场
    /// 通常同一时区,显示的就是「几点开始录的」。
    at: i64,
    /// 这一刻这场录音稿里的最后一块;网页据此把线画在正确的位置。
    /// 还没有内容时为 `None`(线画在这一场的开头)。
    after_block_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateRoomResponse {
    room_id: String,
    publish_token: String,
    /// 服务端按它配置的公开基址拼好的观看页地址。服务端可能架在反代
    /// 后面,自己拼不一定对,所以以服务端回答为准。
    viewer_url: String,
}

/// 一场网页分享的进程内运行时。挂在 [`crate::share_api::ShareRuntime`] 里,
/// 随停止共享一起收口。
pub(crate) struct WebShareRuntime {
    viewer_url: String,
    /// `<service>/v1/rooms/<room_id>`,推送与关房都在它下面。
    room_url: String,
    publish_token: String,
    frame_tx: tokio::sync::watch::Sender<Option<CaptionFrame>>,
    blocks_tx: tokio::sync::watch::Sender<Option<WebBlocksPayload>>,
    /// 分割线是事件不是状态,所以是队列不是 watch —— 覆盖会丢掉
    /// 「暂停过一次」这件事本身。
    segment_tx: tokio::sync::mpsc::UnboundedSender<WebSegmentPayload>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for WebShareRuntime {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl WebShareRuntime {
    /// 房间已经建好之后,装配推送侧。独立出来是为了可测:单元测试不需要
    /// 真的建房,也能断言「tap 放行的帧确实进了通道」。
    fn assemble(
        runtime: &tokio::runtime::Runtime,
        room_url: String,
        publish_token: String,
        viewer_url: String,
    ) -> Self {
        let (frame_tx, mut frame_rx) = tokio::sync::watch::channel::<Option<CaptionFrame>>(None);
        let (blocks_tx, mut blocks_rx) =
            tokio::sync::watch::channel::<Option<WebBlocksPayload>>(None);
        let (segment_tx, mut segment_rx) =
            tokio::sync::mpsc::unbounded_channel::<WebSegmentPayload>();

        let task = {
            let room_url = room_url.clone();
            let token = publish_token.clone();
            runtime.spawn(async move {
                let client = match reqwest::Client::builder()
                    .timeout(Duration::from_secs(10))
                    .build()
                {
                    Ok(client) => client,
                    Err(error) => {
                        tracing::warn!(%error, "网页分享推送客户端创建失败");
                        return;
                    }
                };
                loop {
                    tokio::select! {
                        changed = frame_rx.changed() => {
                            if changed.is_err() { break; }
                            let frame = frame_rx.borrow_and_update().clone();
                            let Some(frame) = frame else { continue };
                            let result = client
                                .post(format!("{room_url}/frame"))
                                .bearer_auth(&token)
                                .json(&frame)
                                .send()
                                .await;
                            if let Err(error) = result {
                                // 掉线是常态而不是事故:下一帧还是完整的,
                                // 不重试、不积压。
                                tracing::debug!(%error, "网页分享:帧未送达");
                            }
                        }
                        changed = blocks_rx.changed() => {
                            if changed.is_err() { break; }
                            let payload = blocks_rx.borrow_and_update().clone();
                            let Some(payload) = payload else { continue };
                            let result = client
                                .post(format!("{room_url}/blocks"))
                                .bearer_auth(&token)
                                .json(&payload)
                                .send()
                                .await;
                            if let Err(error) = result {
                                tracing::debug!(%error, "网页分享:块快照未送达");
                            }
                        }
                        segment = segment_rx.recv() => {
                            let Some(segment) = segment else { break };
                            // 分割线要重试一次:它不像帧那样「下一帧还会
                            // 带上全部真相」,漏一条就永久少一条线。
                            for attempt in 0..2 {
                                let result = client
                                    .post(format!("{room_url}/segment"))
                                    .bearer_auth(&token)
                                    .json(&segment)
                                    .send()
                                    .await;
                                match result {
                                    Ok(response) if response.status().is_success() => break,
                                    other => {
                                        tracing::debug!(?other, attempt, "网页分享:分割线未送达");
                                        tokio::time::sleep(Duration::from_millis(400)).await;
                                    }
                                }
                            }
                        }
                    }
                }
            })
        };

        Self {
            viewer_url,
            room_url,
            publish_token,
            frame_tx,
            blocks_tx,
            segment_tx,
            task,
        }
    }

    pub(crate) fn viewer_url(&self) -> &str {
        &self.viewer_url
    }

    /// 一帧放行后的字幕。调用方是 `ShareCaptionTap::broadcast` ——
    /// 到这里的帧已经过完范围与静音判定。
    pub(crate) fn publish_frame(&self, frame: &CaptionFrame) {
        let _ = self.frame_tx.send(Some(frame.clone()));
    }

    fn publish_blocks(&self, payload: WebBlocksPayload) {
        let _ = self.blocks_tx.send(Some(payload));
    }

    fn publish_segment(&self, payload: WebSegmentPayload) {
        let _ = self.segment_tx.send(payload);
    }

    /// 关房。尽力而为:服务端反正有 TTL,DELETE 失败不挡停止共享。
    pub(crate) fn close(&self, runtime: &tokio::runtime::Runtime) {
        let room_url = self.room_url.clone();
        let token = self.publish_token.clone();
        runtime.spawn(async move {
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build();
            if let Ok(client) = client {
                let _ = client.delete(room_url).bearer_auth(token).send().await;
            }
        });
    }

    #[cfg(test)]
    fn latest_frame_for_test(&self) -> Option<CaptionFrame> {
        self.frame_tx.borrow().clone()
    }

    /// 测试用装配:不起推送任务,把分割线的接收端交给测试直接查看。
    /// 生产的 `assemble` 会把它交给发送任务,那时测试就观察不到了。
    #[cfg(test)]
    fn assemble_without_sender(
        runtime: &tokio::runtime::Runtime,
    ) -> (
        Self,
        tokio::sync::mpsc::UnboundedReceiver<WebSegmentPayload>,
    ) {
        let (frame_tx, _frame_rx) = tokio::sync::watch::channel::<Option<CaptionFrame>>(None);
        let (blocks_tx, _blocks_rx) = tokio::sync::watch::channel::<Option<WebBlocksPayload>>(None);
        let (segment_tx, segment_rx) = tokio::sync::mpsc::unbounded_channel::<WebSegmentPayload>();
        let runtime_handle = runtime.spawn(async {});
        (
            Self {
                viewer_url: "http://127.0.0.1:1/r/test".into(),
                room_url: "http://127.0.0.1:1/v1/rooms/test".into(),
                publish_token: "t".into(),
                frame_tx,
                blocks_tx,
                segment_tx,
                task: runtime_handle,
            },
            segment_rx,
        )
    }

    #[cfg(test)]
    fn latest_blocks_for_test(&self) -> Option<(String, usize)> {
        self.blocks_tx
            .borrow()
            .as_ref()
            .map(|p| (p.session_id.clone(), p.blocks.len()))
    }
}

impl ZulangueCore {
    /// 宿主发布共享 session 时,同一份块快照顺带推给网页。
    /// 不在主持、或没开网页分享时是 no-op。
    pub(crate) fn push_web_share_blocks(&self, session_id: &str) {
        let web = {
            let guard = self.share_runtime.lock().unwrap();
            match guard.as_ref().and_then(|r| r.web_share.clone()) {
                Some(web) => web,
                None => return,
            }
        };
        let Ok(blocks) = self.shared_session_blocks(session_id.to_string()) else {
            return;
        };
        web.publish_blocks(WebBlocksPayload {
            session_id: session_id.to_string(),
            blocks: blocks
                .into_iter()
                .map(|b| WebBlock {
                    id: b.id,
                    owner: b.owner,
                    text: b.text,
                    lanes: b.lanes,
                })
                .collect(),
        });
    }
}

impl ZulangueCore {
    /// 录音开始/恢复或暂停时,在网页上留一条分割线。
    ///
    /// 放行判定与字幕同源(`session_broadcast_status`):这一段的字幕不
    /// 播给房间,它的分割线也不该出现 —— 否则网页上会凭空多出一条
    /// 「开始录音」而下面什么都不来。
    pub(crate) fn push_web_share_segment(&self, notebook_id: &str, session_id: &str, kind: &str) {
        let web = {
            let guard = self.share_runtime.lock().unwrap();
            match guard.as_ref().and_then(|r| r.web_share.clone()) {
                Some(web) => web,
                None => return,
            }
        };
        if !matches!(
            self.session_broadcast_status(notebook_id.to_string(), session_id.to_string()),
            crate::share_api::FfiSessionBroadcastStatus::Broadcasting
        ) {
            return;
        }
        // 线画在这一场当前最后一块之后。拿不到稿(还没落定过内容)时
        // 为 None —— 网页把它画在这一场的开头。
        let after_block_id = self
            .shared_session_blocks(session_id.to_string())
            .ok()
            .and_then(|blocks| blocks.last().map(|block| block.id.clone()));
        let at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        web.publish_segment(WebSegmentPayload {
            kind: kind.to_string(),
            session_id: session_id.to_string(),
            at,
            after_block_id,
        });
    }
}

#[uniffi::export]
impl ZulangueCore {
    /// 开启网页分享。仅主持中可开;返回观看页地址。
    ///
    /// `service_url` 为空用默认部署位。重复调用返回当前房间,不重复建房。
    pub fn start_web_share(
        &self,
        service_url: Option<String>,
    ) -> Result<FfiWebShareInfo, CoreError> {
        let base = service_url
            .filter(|url| !url.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_WEB_CAPTION_SERVICE.to_string());
        let base = base.trim_end_matches('/').to_string();

        // 主持判定与已开判定一次拿完,不在锁外做两段决定。
        {
            let guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_ref() else {
                return Err(CoreError::ValidationFailed {
                    message: "先开始共享,再开启网页分享".into(),
                });
            };
            if !runtime.is_hosting() {
                return Err(CoreError::ValidationFailed {
                    message: "只有主持人能开启网页分享".into(),
                });
            }
            if let Some(web) = runtime.web_share.as_ref() {
                return Ok(FfiWebShareInfo {
                    viewer_url: web.viewer_url().to_string(),
                });
            }
        }

        // 建房走网络,放在锁外。
        let created: CreateRoomResponse = self
            .runtime
            .block_on(async {
                let client = reqwest::Client::builder()
                    .timeout(Duration::from_secs(10))
                    .build()
                    .map_err(|e| format!("HTTP 客户端创建失败: {e}"))?;
                let response = client
                    .post(format!("{base}/v1/rooms"))
                    .json(&serde_json::json!({}))
                    .send()
                    .await
                    .map_err(|e| format!("连不上字幕网页服务: {e}"))?;
                if !response.status().is_success() {
                    return Err(format!("字幕网页服务拒绝建房: {}", response.status()));
                }
                response
                    .json::<CreateRoomResponse>()
                    .await
                    .map_err(|e| format!("建房响应无法解析: {e}"))
            })
            .map_err(|message| CoreError::InternalError { message })?;

        let web = Arc::new(WebShareRuntime::assemble(
            &self.runtime,
            format!("{base}/v1/rooms/{}", created.room_id),
            created.publish_token,
            created.viewer_url.clone(),
        ));

        {
            let mut guard = self.share_runtime.lock().unwrap();
            let Some(runtime) = guard.as_mut() else {
                return Err(CoreError::ValidationFailed {
                    message: "共享已在建房期间结束".into(),
                });
            };
            if !runtime.is_hosting() {
                web.close(&self.runtime);
                return Err(CoreError::ValidationFailed {
                    message: "共享已在建房期间结束".into(),
                });
            }
            runtime.web_share = Some(web);
        }

        // 按单条录音共享时,把已有的稿先推一份 —— 晚扫码的人不该等到
        // 下一次发布才看到内容。Notebook 范围随下一次发布补上。
        let scope_session = {
            let guard = self.share_runtime.lock().unwrap();
            guard.as_ref().and_then(|r| match r.roster_scope() {
                Some(vt_share::ScopeId::Session { session_id }) => Some(session_id),
                _ => None,
            })
        };
        if let Some(session_id) = scope_session {
            self.push_web_share_blocks(&session_id);
        }

        Ok(FfiWebShareInfo {
            viewer_url: created.viewer_url,
        })
    }

    /// 关闭网页分享(共享本身继续)。
    pub fn stop_web_share(&self) {
        let web = {
            let mut guard = self.share_runtime.lock().unwrap();
            guard.as_mut().and_then(|r| r.web_share.take())
        };
        if let Some(web) = web {
            web.close(&self.runtime);
        }
    }

    /// 当前网页分享的快照;没开时为 `None`。
    pub fn web_share_state(&self) -> Option<FfiWebShareInfo> {
        let guard = self.share_runtime.lock().unwrap();
        guard
            .as_ref()
            .and_then(|r| r.web_share.as_ref())
            .map(|web| FfiWebShareInfo {
                viewer_url: web.viewer_url().to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::share_api::ShareCaptionTap;

    fn attach_web_runtime(core: &ZulangueCore) -> Arc<WebShareRuntime> {
        let web = Arc::new(WebShareRuntime::assemble(
            &core.runtime,
            // 死端口:推送任务的失败路径本来就是静默丢帧,测试里无害。
            "http://127.0.0.1:1/v1/rooms/test-room".into(),
            "test-token".into(),
            "http://127.0.0.1:1/r/test-room".into(),
        ));
        core.share_runtime
            .lock()
            .unwrap()
            .as_mut()
            .expect("共享已开始")
            .web_share = Some(web.clone());
        web
    }

    /// 没在共享、或不是主持人,网页分享开不了。
    #[test]
    fn web_share_requires_an_active_hosted_share() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        assert!(core.start_web_share(None).is_err());
        assert!(core.web_share_state().is_none());
        // stop 在未开启时是 no-op,不 panic。
        core.stop_web_share();
    }

    /// tap 放行的帧同一份进网页通道;被静音的帧两条通道都不发。
    #[test]
    fn the_tap_feeds_the_web_channel_with_the_same_gating() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_sharing(Some("nb-web".into()), None, false)
            .unwrap();
        let web = attach_web_runtime(&core);

        let tap = ShareCaptionTap::new(core.share_runtime.clone(), "nb-web".into());

        // 静音:P2P 与网页都不发。
        core.set_session_broadcast_muted("sess-web".into(), true);
        tap.broadcast(&crate::share_api::test_support::preview("sess-web", 1));
        assert!(
            web.latest_frame_for_test().is_none(),
            "静音帧不得进网页通道"
        );

        core.set_session_broadcast_muted("sess-web".into(), false);
        tap.broadcast(&crate::share_api::test_support::preview("sess-web", 2));
        let frame = web.latest_frame_for_test().expect("放行帧应进网页通道");
        assert_eq!(frame.preview_revision, 2);
        assert_eq!(frame.session_id, "sess-web");
        assert!(!frame.utterances.is_empty(), "网页通道拿到的是完整形态");

        core.stop_sharing().unwrap();
        // 停止共享一并收口网页分享。
        assert!(core.web_share_state().is_none());
    }

    /// 宿主发布共享 session 时,块快照进网页通道。
    #[test]
    fn publishing_a_shared_session_pushes_blocks_to_the_web() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_sharing(None, Some("sess-doc".into()), false)
            .unwrap();
        core.enable_document_sync().unwrap();
        let web = attach_web_runtime(&core);

        core.shared_session_insert_annotation("sess-doc".into(), 0, "n1".into(), "网页稿".into())
            .unwrap();

        let (session_id, block_count) = web.latest_blocks_for_test().expect("发布应推块快照");
        assert_eq!(session_id, "sess-doc");
        assert_eq!(block_count, 1);

        core.stop_sharing().unwrap();
    }

    /// 跨层冒烟:对着本地跑着的 caption-web 服务走完整链路。
    /// 由 `scripts/caption_web_smoke.sh` 驱动(它负责起服务、之后用 curl
    /// 验证房间里真的有帧与稿),平时 `--ignored` 跳过。
    #[test]
    #[ignore]
    fn web_share_smoke_against_local_service() {
        let base = std::env::var("CAPTION_WEB_SMOKE_URL")
            .expect("由 caption_web_smoke.sh 设置,例如 http://127.0.0.1:8100");
        let dir = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_sharing(None, Some("sess-smoke".into()), false)
            .unwrap();
        core.enable_document_sync().unwrap();

        let info = core.start_web_share(Some(base)).unwrap();
        println!("viewer_url={}", info.viewer_url);

        // 一帧字幕 + 一份稿。推送是异步 watch,发几拍等它送达。
        let tap = ShareCaptionTap::new(core.share_runtime.clone(), "unused".into());
        core.shared_session_insert_annotation("sess-smoke".into(), 0, "n1".into(), "冒烟稿".into())
            .unwrap();
        for revision in 1..=5 {
            tap.broadcast(&crate::share_api::test_support::preview(
                "sess-smoke",
                revision,
            ));
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
        // 房间保持开着,由脚本验证内容后再收尾(进程退出即弃房,服务端 TTL 兜底)。
    }

    /// 分割线与字幕同一套放行判定。
    ///
    /// 一条凭空出现的「录音开始」比没有线更坏 —— 观看者会盯着一个
    /// 永远不来内容的段落等。所以静音、范围不符的录音不得留线。
    #[test]
    fn segments_follow_the_same_gating_as_captions() {
        let dir = tempfile::tempdir().unwrap();
        let core = ZulangueCore::new_for_test(dir.path().to_string_lossy().to_string()).unwrap();
        core.start_sharing(Some("nb-seg".into()), None, false)
            .unwrap();
        let (web, mut segments) = WebShareRuntime::assemble_without_sender(&core.runtime);
        core.share_runtime
            .lock()
            .unwrap()
            .as_mut()
            .unwrap()
            .web_share = Some(Arc::new(web));

        // 别的 Notebook 的录音:不留线。
        core.push_web_share_segment("nb-other", "sess-x", "started");
        assert!(segments.try_recv().is_err(), "范围外的录音不得留线");

        // 静音的录音:字幕不播,线也不留。
        core.set_session_broadcast_muted("sess-seg".into(), true);
        core.push_web_share_segment("nb-seg", "sess-seg", "started");
        assert!(segments.try_recv().is_err(), "静音的录音不得留线");

        // 范围内且未静音:留线,带时间。
        core.set_session_broadcast_muted("sess-seg".into(), false);
        core.push_web_share_segment("nb-seg", "sess-seg", "started");
        let segment = segments.try_recv().expect("放行的录音应当留线");
        assert_eq!(segment.kind, "started");
        assert_eq!(segment.session_id, "sess-seg");
        assert!(segment.at > 0, "线上要带得出「几点开始的」");

        core.push_web_share_segment("nb-seg", "sess-seg", "paused");
        assert_eq!(segments.try_recv().unwrap().kind, "paused");

        core.stop_sharing().unwrap();
        // 停止共享后网页分享一并收口,再暂停也不该有线。
        core.push_web_share_segment("nb-seg", "sess-seg", "paused");
        assert!(segments.try_recv().is_err());
    }

    /// 线上块快照是纯文本 —— 与帧同一条音频红线。
    #[test]
    fn web_payloads_are_text_only() {
        let payload = WebBlocksPayload {
            session_id: "s".into(),
            blocks: vec![WebBlock {
                id: "b1".into(),
                owner: "capture:s".into(),
                text: "文字".into(),
                lanes: HashMap::from([("zh-hans".into(), "文字".into())]),
            }],
        };
        let json = serde_json::to_string(&payload).unwrap();
        for banned in ["pcm", "audio", "wav", "sample_rate", "channels"] {
            assert!(
                !json.to_ascii_lowercase().contains(banned),
                "网页块快照不得出现 {banned}"
            );
        }
    }
}
