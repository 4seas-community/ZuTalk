#!/usr/bin/env python3
"""Zulangue caption-web:扫码看实时字幕稿。

设计见 docs/architecture/share-web-captions.md。要点:

- 主持人的 App 建房后推两种载荷:帧(实时 tail,replace-in-full)与
  块快照(稿,按 session 只留最新)。浏览器经 SSE 订阅。
- **明文经过本服务**是产品定案(2026-08-09),App 的 UI 负责把这句话
  说给主持人;本服务的责任是不留超过必要的东西:留存期一到就清,
  在那之前稿一直读得到 —— 停止共享只封笔不删,重启不作废链接。
  「重启即空」曾被当作一条隐私保证,其实不是:明文本来就要在这台机器上
  待满整个留存期,重启清空只是让恰好那一刻拿着链接的人白拿。
- 房间号即门票(不可猜测),发布口令只有主持人持有。
- 上限挡的是脚本滥用,不是「未授权用户用不了」。
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 一场会议量级的房间;超过这个数,新建房被拒,等 TTL 释放。
MAX_ROOMS = 200
# 帧与块快照的单次载荷上限。多语言长会议的块快照也远在这之下。
MAX_BODY_BYTES = 1 * 1024 * 1024
# 最后一次推送之后,房间还能活多久 —— 停止共享之后也按它计时。
#
# 会议散场恰恰是最多人去读稿的时候:主持人一按停止就让链接变成 404,
# 等于把「扫码看字幕」缩成「必须现场看完」。所以停止共享不再删房,
# 只是封笔;房间读到留存期满为止。窗口越长,明文在服务器上待得越久 ——
# 这个数就是那条取舍,`--retention-hours` 可覆盖。
ROOM_RETENTION_SECONDS = 24 * 60 * 60
# 每个 IP 每分钟最多建几个房。正常使用是一场会议一个。
MAX_CREATES_PER_MINUTE = 6
# 单房间的 SSE 订阅上限 —— 会议室量级,不是直播量级。
MAX_SUBSCRIBERS_PER_ROOM = 200
# 订阅者队列深度。帧是 replace-in-full 的,浏览器掉队就丢旧帧。
SUBSCRIBER_QUEUE_DEPTH = 32
# 一场会议里录音开始/暂停的次数上限。超过就丢最旧的 —— 分割线是
# 追加式的,不设上限的话一次误触发的循环能把内存撑爆。
MAX_SEGMENTS_PER_ROOM = 500


def now() -> float:
    return time.monotonic()


class Room:
    def __init__(self, room_id: str, publish_token: str) -> None:
        self.room_id = room_id
        self.publish_token = publish_token
        self.created_at = now()
        self.last_activity = now()
        self.frame: dict | None = None
        # session_id → 块快照载荷。Notebook 范围的房间会有多场录音。
        self.blocks: dict[str, dict] = {}
        # session_id 首次出现的顺序,网页按它排稿。
        self.session_order: list[str] = []
        # 录音开始/暂停的分割线。追加式:顺序即语义,不能被覆盖。
        self.segments: list[dict] = []
        self.subscribers: list[queue.Queue] = []
        self.ended = False


class RoomStore:
    """锁保护房间表;每个订阅者一条队列,fanout 不做背压 —— 队列满了丢
    旧消息,和帧的 replace-in-full 性质一致。

    配了 `state_path` 就把房间落一份盘,好让重启不作废别人手里的链接
    (见 `snapshot` 的注释)。没配就是纯内存,与从前一致。
    """

    def __init__(
        self,
        state_path: str | None = None,
        retention_seconds: float = ROOM_RETENTION_SECONDS,
    ) -> None:
        self.lock = threading.Lock()
        self.rooms: dict[str, Room] = {}
        # IP → 最近建房时间戳列表(限速用)。
        self.creates_by_ip: dict[str, list[float]] = {}
        self.state_path = state_path
        self.retention_seconds = retention_seconds
        # 有没有需要落盘的改动。落盘是去抖的:推送是说话的频率,每一次
        # 都 fsync 一遍毫无意义 —— 帧不落盘,稿是 replace-in-full 的,
        # 崩溃最多丢掉最后几秒的一次覆盖,主播还活着就会再推一份。
        self.dirty = False

    def create_room(self, client_ip: str) -> Room | None:
        with self.lock:
            window_start = now() - 60
            stamps = [t for t in self.creates_by_ip.get(client_ip, []) if t > window_start]
            if len(stamps) >= MAX_CREATES_PER_MINUTE:
                return None
            stamps.append(now())
            self.creates_by_ip[client_ip] = stamps

            if len(self.rooms) >= MAX_ROOMS:
                return None
            room = Room(
                room_id=secrets.token_urlsafe(16),
                publish_token=secrets.token_urlsafe(32),
            )
            self.rooms[room.room_id] = room
            self.dirty = True
            return room

    # ------------------------------------------------------------------
    # 落盘
    #
    # 从前这里写的是「进程重启即空」。它读起来像一条隐私保证,其实不是:
    # 明文本来就在这台机器的内存里待满整个留存期,重启清空并不让谁更
    # 安全,只是让**恰好那一刻**手里拿着链接的人白拿 —— 一次部署、一次
    # OOM、一次 systemd 重启,会场里所有二维码同时作废,而会还在开。
    # 所以落盘,并把真话写进 UI 与文档:字幕在服务器上以明文保存,
    # 保存多久由留存期决定。
    #
    # 落的是稿(块快照)、分割线、房间身份;**不落帧** —— 帧是推测性的
    # 半句话,重启后要么主播再推一份,要么它本来就该消失。

    def snapshot(self) -> dict:
        with self.lock:
            elapsed_to_epoch = time.time() - now()
            return {
                "version": 1,
                "rooms": [
                    {
                        "room_id": room.room_id,
                        "publish_token": room.publish_token,
                        # 存墙钟:monotonic 跨进程没有意义。存的是「最后
                        # 一次推送发生在哪个绝对时刻」,载入时再换算回来。
                        "created_at_epoch": room.created_at + elapsed_to_epoch,
                        "last_activity_epoch": room.last_activity + elapsed_to_epoch,
                        "blocks": room.blocks,
                        "session_order": room.session_order,
                        "segments": room.segments,
                        "ended": room.ended,
                    }
                    for room in self.rooms.values()
                ],
            }

    def flush(self) -> bool:
        """脏了才写,写则原子替换。返回这次是否真的写了。"""
        if self.state_path is None:
            return False
        with self.lock:
            if not self.dirty:
                return False
            self.dirty = False
        payload = json.dumps(self.snapshot(), ensure_ascii=False).encode()
        temporary = f"{self.state_path}.tmp"
        # 0600:这份文件里有字幕明文和发布口令。
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except BaseException:
            os.unlink(temporary)
            raise
        os.replace(temporary, self.state_path)
        return True

    def load(self) -> int:
        """载入快照,丢掉留存期已满的房间。返回载入的房间数。

        文件坏了不拦启动:一份读不懂的快照的正确处置是当作没有房间,
        而不是让整个服务起不来 —— 服务活着,主播重开一次分享就有新房。
        """
        if self.state_path is None or not os.path.exists(self.state_path):
            return 0
        try:
            with open(self.state_path, encoding="utf-8") as handle:
                payload = json.load(handle)
            rooms = payload["rooms"]
        except (OSError, ValueError, KeyError, TypeError):
            return 0
        cutoff = time.time() - self.retention_seconds
        elapsed_to_epoch = time.time() - now()
        loaded = 0
        with self.lock:
            for stored in rooms:
                try:
                    last_activity_epoch = float(stored["last_activity_epoch"])
                    if last_activity_epoch < cutoff:
                        continue
                    room = Room(
                        room_id=str(stored["room_id"]),
                        publish_token=str(stored["publish_token"]),
                    )
                    room.created_at = float(stored["created_at_epoch"]) - elapsed_to_epoch
                    room.last_activity = last_activity_epoch - elapsed_to_epoch
                    room.blocks = dict(stored["blocks"])
                    room.session_order = list(stored["session_order"])
                    room.segments = list(stored["segments"])
                    room.ended = bool(stored["ended"])
                except (KeyError, TypeError, ValueError):
                    continue
                self.rooms[room.room_id] = room
                loaded += 1
        return loaded

    def room_for_publish(self, room_id: str, token: str) -> Room | None:
        with self.lock:
            room = self.rooms.get(room_id)
            if room is None or room.ended:
                return None
            if not secrets.compare_digest(room.publish_token, token):
                return None
            return room

    def room_for_view(self, room_id: str) -> Room | None:
        with self.lock:
            return self.rooms.get(room_id)

    def sweep_idle(self) -> int:
        """清掉留存期满的房间。返回清掉的数量。**这里是唯一真正删稿的
        地方** —— 停止共享只封笔,不删。"""
        cutoff = now() - self.retention_seconds
        removed = 0
        with self.lock:
            for room_id in list(self.rooms):
                room = self.rooms[room_id]
                if room.last_activity < cutoff:
                    self._end_room_locked(room)
                    del self.rooms[room_id]
                    removed += 1
            if removed:
                self.dirty = True
        return removed

    def end_room(self, room: Room) -> None:
        """封笔:不再收推送,已连着的人收到 `ended`,**稿留下**。

        散场恰恰是最多人去读稿的时候。删房等于把「扫码看字幕」缩成
        「必须现场看完」,而稿本来就已经在服务器上了 —— 提前删它并不
        改变明文经过服务器这件事,只是让来晚的人白扫一次码。
        """
        with self.lock:
            self._end_room_locked(room)
            self.dirty = True

    def _end_room_locked(self, room: Room) -> None:
        room.ended = True
        # 最后一帧是推测性的半句话。分享已经结束,它不会再被修正了,
        # 留着只会让人以为还有人在说 —— 与暂停时的处置同一条理。
        room.frame = None
        for subscriber in room.subscribers:
            offer(subscriber, {"event": "ended", "data": {}})
        room.subscribers.clear()

    def publish(self, room: Room, event: str, data: dict) -> None:
        with self.lock:
            room.last_activity = now()
            # 帧不落盘,所以一帧不算脏 —— 否则说话的频率就是写盘的频率。
            self.dirty = self.dirty or event != "frame"
            if event == "frame":
                room.frame = data
            elif event == "blocks":
                session_id = data.get("session_id")
                if isinstance(session_id, str) and session_id:
                    if session_id not in room.blocks:
                        room.session_order.append(session_id)
                    room.blocks[session_id] = data
            elif event == "segment":
                room.segments.append(data)
                del room.segments[:-MAX_SEGMENTS_PER_ROOM]
                # 暂停即字幕停住:清掉最后一帧,否则晚扫码的人会看到
                # 一句停在半空的推测文本,以为还在说。
                if data.get("kind") == "paused":
                    room.frame = None
            for subscriber in list(room.subscribers):
                offer(subscriber, {"event": event, "data": data})

    def subscribe(self, room: Room) -> queue.Queue | None:
        """挂一个订阅者,并立刻塞进全量初始状态。

        已封笔的房间照样订阅得上:发全量,再发一条 `ended`,然后收线 ——
        散场之后扫码进来的人读到的是完整的稿和一句「已结束」,而不是
        404。这条路不占订阅名额,连接发完就断。
        """
        with self.lock:
            subscriber: queue.Queue = queue.Queue(maxsize=SUBSCRIBER_QUEUE_DEPTH)
            init = {
                "sessions": [room.blocks[sid] for sid in room.session_order],
                "frame": room.frame,
                "segments": list(room.segments),
                # 网页据此说清「这个链接还能开多久」。
                "retention_hours": round(self.retention_seconds / 3600),
            }
            offer(subscriber, {"event": "init", "data": init})
            if room.ended:
                offer(subscriber, {"event": "ended", "data": {}})
                return subscriber
            if len(room.subscribers) >= MAX_SUBSCRIBERS_PER_ROOM:
                return None
            room.subscribers.append(subscriber)
            return subscriber

    def unsubscribe(self, room: Room, subscriber: queue.Queue) -> None:
        with self.lock:
            if subscriber in room.subscribers:
                room.subscribers.remove(subscriber)


def offer(subscriber: queue.Queue, message: dict) -> None:
    """满了先腾掉最旧的一条。掉队的浏览器丢中间态无害 —— 帧是完整快照,
    块也是 replace-in-full。"""
    while True:
        try:
            subscriber.put_nowait(message)
            return
        except queue.Full:
            try:
                subscriber.get_nowait()
            except queue.Empty:
                pass


VIEWER_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Zulangue</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; font-family: -apple-system, "PingFang SC", "Hiragino Sans",
    "Noto Sans", "Noto Sans Thai", sans-serif; background: #111; color: #eee;
    display: flex; flex-direction: column; height: 100dvh;
  }
  header {
    padding: 10px 14px; display: flex; gap: 8px; align-items: center;
    flex-wrap: wrap; border-bottom: 1px solid #333;
  }
  header .title { font-weight: 600; margin-right: auto; }
  header .status { font-size: 12px; color: #9a9; }
  header .status.ended { color: #c96; }
  .lang { border: 1px solid #555; background: none; color: #ccc;
    border-radius: 999px; padding: 4px 12px; cursor: pointer; font-size: 13px; }
  .lang.active { border-color: #6c6; color: #6c6; }
  #uilang { border: 1px solid #444; background: #111; color: #999;
    border-radius: 6px; padding: 3px 6px; font-size: 12px; }
  main { flex: 1; overflow-y: auto; padding: 16px 14px 40px; }
  .session { margin-bottom: 20px; }
  .row { display: grid; gap: 14px; margin: 0 0 12px; }
  .cell { line-height: 1.55; font-size: 17px; min-width: 0;
    overflow-wrap: break-word; }
  .cell.empty { color: #555; }
  /* 回落原文的格子:内容是真的,只是这门语言还没译到/不需要译。
     弱一档颜色说明「这不是译文」,又不至于像空格子那样读不下去。 */
  .cell.fallback { color: #b8b8b8; }
  /* 批注不属于任何一门语言:一条横跨全部栏的行,而不是复制三份。 */
  .annotation-row { margin: 0 0 12px; color: #9ac; font-size: 15px;
    line-height: 1.55; overflow-wrap: break-word; }
  /* 说话人:一行字幕之上的一条小标,横跨全部栏 —— 同一句话在三栏里
     是同一个人说的,标三次是三份噪音。 */
  .speaker { font-size: 12px; color: #8ab; letter-spacing: 0.04em;
    margin: 10px 0 4px; }
  #livetail .speaker { color: #778; }
  .colhead { position: sticky; top: 0; background: #111; display: grid;
    gap: 14px; padding: 4px 0 6px; border-bottom: 1px solid #2a2a2a;
    margin-bottom: 10px; }
  .colhead span { font-size: 12px; color: #888; }
  /* 正在说的文字:直接续在稿后原地刷新,不做引用块。弱色区分推测性。 */
  #livetail .cell { color: #9a9a9a; }
  #livetail p { margin: 0 0 12px; }
  /* 录音的开始/暂停:一条横跨全部栏的线,不属于任何一栏。 */
  .divider { display: flex; align-items: center; gap: 10px;
    margin: 18px 0 14px; color: #7a7a7a; font-size: 12px; }
  .divider::before, .divider::after {
    content: ""; height: 1px; background: #333; flex: 1; }
  .divider.paused { color: #666; }
  #follow {
    position: fixed; right: 16px; bottom: 16px; display: none;
    background: #2a2; color: #fff; border: none; border-radius: 999px;
    padding: 8px 14px; cursor: pointer;
  }
</style>
</head>
<body>
<header>
  <span class="title">Zulangue</span>
  <span id="langs"></span>
  <span class="status" id="status"></span>
  <select id="uilang" aria-label="Interface language">
    <option value="zh-Hans">中文</option>
    <option value="en">English</option>
    <option value="th">ไทย</option>
  </select>
</header>
<main id="main">
  <div id="colhead"></div>
  <div id="transcript"></div>
  <div id="livetail"></div>
</main>
<button id="follow"></button>
<script>
"use strict";
// 界面文案(非内容)的三语:观看的人是简中/泰/英三种语言背景,
// 「This share has ended」对英语不好的人就是一句谜语。内容语言按钮
// (稿显示哪些车道)与界面语言互相独立。
const UI = {
  "zh-Hans": {
    title: "Zulangue 实时字幕",
    connecting: "连接中…",
    live: "实时",
    reconnecting: "重连中…",
    ended: "这场分享已结束。字幕稿留在这个链接上,约 {n} 小时后清除。",
    endedUnknown: "这场分享已结束。字幕稿暂时留在这个链接上。",
    follow: "↓ 回到实时",
    started: "录音开始",
    paused: "录音已暂停",
    source: "原文",
    speaker: "说话人 {n}",
  },
  "en": {
    title: "Zulangue Live Captions",
    connecting: "connecting…",
    live: "live",
    reconnecting: "reconnecting…",
    ended: "This share has ended. The transcript stays at this link for about {n} more hours.",
    endedUnknown: "This share has ended. The transcript stays at this link for now.",
    follow: "↓ Live",
    started: "recording started",
    paused: "recording paused",
    source: "Source",
    speaker: "Speaker {n}",
  },
  "th": {
    title: "Zulangue ซับไตเติลสด",
    connecting: "กำลังเชื่อมต่อ…",
    live: "สด",
    reconnecting: "กำลังเชื่อมต่อใหม่…",
    ended: "การแชร์นี้จบแล้ว ทรานสคริปต์จะยังอยู่ที่ลิงก์นี้อีกประมาณ {n} ชั่วโมง",
    endedUnknown: "การแชร์นี้จบแล้ว ทรานสคริปต์จะยังอยู่ที่ลิงก์นี้ชั่วคราว",
    follow: "↓ กลับสู่สด",
    started: "เริ่มบันทึก",
    paused: "หยุดบันทึกชั่วคราว",
    source: "ต้นฉบับ",
    speaker: "ผู้พูด {n}",
  },
};

function detectUiLang() {
  try {
    const saved = localStorage.getItem("zulangue-ui-lang");
    if (saved && UI[saved]) return saved;
  } catch (e) { /* 隐私模式下 localStorage 可能不可用 */ }
  const nav = (navigator.language || "en").toLowerCase();
  if (nav.startsWith("zh")) return "zh-Hans";
  if (nav.startsWith("th")) return "th";
  return "en";
}

// 内容语言选择:最多三个,分栏并排。"source" 是「原文」伪语言 ——
// 稿的原文不在车道里(车道只有译文),没有它就没法把原文当一栏选。
const MAX_COLUMNS = 3;

function loadSelection() {
  try {
    const saved = JSON.parse(localStorage.getItem("zulangue-content-langs") || "null");
    if (Array.isArray(saved) && saved.length) return saved.slice(0, MAX_COLUMNS);
  } catch (e) { /* 同上 */ }
  return ["source"];
}

const state = { sessions: [], frame: null, segments: [], selected: loadSelection(),
                langs: [], following: true, ended: false, statusKey: "connecting",
                uiLang: detectUiLang(), speakers: {}, retentionHours: null };
const el = (id) => document.getElementById(id);
const t = (key) => UI[state.uiLang][key];

// 「已结束」要说清这个链接还能开多久 —— 停止共享之后稿留在服务器上,
// 不说清楚,读的人不知道该现在读完还是可以晚点回来。留存期由服务端
// 随全量一起下发;没拿到就退回不承诺具体时长的说法。
function statusText() {
  if (state.statusKey !== "ended") return t(state.statusKey);
  if (!state.retentionHours) return t("endedUnknown");
  return t("ended").replace("{n}", state.retentionHours);
}
const columnLabel = (key) => key === "source" ? t("source") : key;

// 说话人名录:标识 → {name, label}。主播给过名字就用名字(那是专名,
// 不翻译);只有 provider 编号时,「说话人 3」这句话按观看者的界面语言
// 拼 —— 与页面其余文案同一条规矩。
// 稿与实时帧用同一套标识,所以名录只有一份,两个时态共用。
function speakerLabel(id) {
  if (!id) return null;
  const speaker = state.speakers[id];
  if (!speaker) return null;
  if (speaker.name) return speaker.name;
  if (!speaker.label) return null;
  return t("speaker").replace("{n}", speaker.label);
}

// 名录来自块快照,按 session 累加 —— 一场会议里几场录音各有各的说话人,
// 后到的那场不该把前一场的名字抹掉。
function mergeSpeakers(session) {
  const speakers = session && session.speakers;
  if (!speakers) return;
  for (const id of Object.keys(speakers)) state.speakers[id] = speakers[id];
}

function renderChrome() {
  document.documentElement.lang = state.uiLang;
  document.title = t("title");
  const status = el("status");
  status.textContent = statusText();
  status.className = "status" + (state.statusKey === "ended" ? " ended" : "");
  el("follow").textContent = t("follow");
  el("uilang").value = state.uiLang;
  state.langs = [];  // 语言按钮里的「原文」标签要跟着界面语言换,强制重建。
  render();
}

function setStatus(key) { state.statusKey = key; renderChrome(); }

el("uilang").addEventListener("change", (e) => {
  state.uiLang = UI[e.target.value] ? e.target.value : "en";
  try { localStorage.setItem("zulangue-ui-lang", state.uiLang); } catch (err) { /* 同上 */ }
  renderChrome();
});

function collectLanguages() {
  const langs = new Set();
  for (const session of state.sessions) {
    for (const block of (session.blocks || [])) {
      for (const lane of Object.keys(block.lanes || {})) langs.add(lane);
    }
  }
  const frame = state.frame;
  if (frame) {
    for (const u of (frame.utterances || [])) {
      if (u.translated_language) langs.add(u.translated_language);
    }
    for (const c of (frame.cues || [])) langs.add(c.target_language);
    for (const line of (frame.lines || [])) {
      if (line.target_language) langs.add(line.target_language);
    }
  }
  return ["source", ...Array.from(langs).sort()];
}

function toggleLanguage(key) {
  const index = state.selected.indexOf(key);
  if (index >= 0) {
    state.selected.splice(index, 1);
    if (state.selected.length === 0) state.selected = ["source"];
  } else {
    state.selected.push(key);
    while (state.selected.length > MAX_COLUMNS) state.selected.shift();
  }
  try { localStorage.setItem("zulangue-content-langs", JSON.stringify(state.selected)); }
  catch (e) { /* 同上 */ }
  state.langs = [];  // 强制重建按钮的选中态。
  render();
}

function renderLangButtons() {
  const langs = collectLanguages();
  const signature = JSON.stringify([langs, state.selected, state.uiLang]);
  if (signature === state.langsSignature) return;
  state.langsSignature = signature;
  const holder = el("langs");
  holder.textContent = "";
  for (const key of langs) {
    const button = document.createElement("button");
    button.className = "lang" + (state.selected.includes(key) ? " active" : "");
    button.textContent = columnLabel(key);
    button.onclick = () => toggleLanguage(key);
    holder.appendChild(button);
  }
}

// 选中的语言里,只有当前房间数据里真实存在的才占一栏。
// localStorage 里的选择可能带着上一场的语言(比如 fr)——那门语言在这
// 一场不存在时,按钮不会渲染出来,用户既看到多余的空栏又无从取消。
// 以「可用 ∩ 已选」渲染,语言真出现时按钮亮起,随时可关。
function activeColumns() {
  const available = new Set(collectLanguages());
  const filtered = state.selected.filter((key) => available.has(key));
  return filtered.length ? filtered : ["source"];
}

// 稿里某一栏的取值:「原文」取块文本,语言取车道,**车道缺席回落原文**。
//
// 回落不是补白,是这一栏唯一正确的内容:原文本来就是中文时,系统不会
// 再造一条「中文→中文」的车道,于是选中文的那一栏在稿里一格车道都没有。
// 不回落,一场中文会议的中文栏就整屏空着——译文栏满满当当,原文栏反倒
// 什么都没有。同理,一句英文原话在英文栏、一句泰语原话在泰语栏,都靠
// 这条回落。译文只是暂时没到时,回落也比空格子强:先读到话,译文到了
// 自然顶上。
function cellText(block, key) {
  if (key === "source") return block.text || "";
  return (block.lanes && block.lanes[key]) || block.text || "";
}

// 这一格是回落来的原文,不是这门语言的译文。
function isFallbackCell(block, key) {
  if (key === "source") return false;
  return !(block.lanes && block.lanes[key]) && !!block.text;
}

function gridStyle(element, count) {
  element.style.gridTemplateColumns = `repeat(${count}, 1fr)`;
}

function renderColumnHead(columns) {
  const head = el("colhead");
  head.textContent = "";
  if (columns.length < 2) { head.className = ""; return; }
  gridStyle(head, columns.length);
  head.className = "colhead";
  for (const key of columns) {
    const span = document.createElement("span");
    span.textContent = columnLabel(key);
    head.appendChild(span);
  }
}

function appendRow(holder, columns, block) {
  const values = columns.map((key) => cellText(block, key));
  if (values.every((v) => !v)) return;
  const row = document.createElement("div");
  row.className = "row";
  gridStyle(row, columns.length);
  columns.forEach((key, index) => {
    const value = values[index];
    const cell = document.createElement("div");
    cell.className = "cell"
      + (value ? "" : " empty")
      + (value && isFallbackCell(block, key) ? " fallback" : "");
    cell.textContent = value || "";
    row.appendChild(cell);
  });
  holder.appendChild(row);
}

// 批注不属于任何一门语言:横跨全部栏一行,而不是在三栏里各印一遍。
// 只放进原文栏也不行 —— 观看者可能一栏原文都没选,那条批注就凭空没了。
function appendAnnotation(holder, block) {
  if (!block.text) return;
  const row = document.createElement("div");
  row.className = "annotation-row";
  row.textContent = block.text;
  holder.appendChild(row);
}

// 说话人小标:横跨全部栏,只在换人时出现。同一个人连着说几句,标一次
// 就够 —— 每句都标,读起来全是名字。
function appendSpeaker(holder, label) {
  const div = document.createElement("div");
  div.className = "speaker";
  div.textContent = label;
  holder.appendChild(div);
}

function formatTime(epochSeconds) {
  if (!epochSeconds) return "";
  try {
    return new Date(epochSeconds * 1000).toLocaleTimeString(undefined,
      { hour: "2-digit", minute: "2-digit" });
  } catch (e) { return ""; }
}

// 一条分割线。开始的线带时间,暂停的线只说「停了」。
function appendDivider(holder, segment) {
  const div = document.createElement("div");
  const started = segment.kind === "started";
  div.className = "divider" + (started ? "" : " paused");
  const label = document.createElement("span");
  const time = formatTime(segment.at);
  label.textContent = started
    ? (time ? `${time} · ${t("started")}` : t("started"))
    : t("paused");
  div.appendChild(label);
  holder.appendChild(div);
}

// 暂停紧接着恢复(中间没有内容)时,两条线并排毫无意义 —— 只画后
// 那条带时间的。暂停后一直没恢复,那条「已暂停」就是当前状态,要留着。
function mergedSegments() {
  const merged = [];
  for (const segment of state.segments) {
    const previous = merged[merged.length - 1];
    if (previous
        && previous.kind === "paused"
        && segment.kind === "started"
        && previous.session_id === segment.session_id
        && (previous.after_block_id || null) === (segment.after_block_id || null)) {
      merged[merged.length - 1] = segment;
    } else {
      merged.push(segment);
    }
  }
  return merged;
}

function renderTranscript(columns) {
  const holder = el("transcript");
  holder.textContent = "";
  const segments = mergedSegments();
  const placed = new Set();
  for (const session of state.sessions) {
    const sessionDiv = document.createElement("div");
    sessionDiv.className = "session";
    const mine = segments.filter((s) => s.session_id === session.session_id);
    // 这一场开头的线(还没有内容时录的)。
    for (const segment of mine.filter((s) => !s.after_block_id)) {
      appendDivider(sessionDiv, segment);
      placed.add(segment);
    }
    // 换人才标一次。批注与分割线打断连续性:它们之后的第一句要重新
    // 报一次名字,否则读者得往上翻很远才知道现在是谁在说。
    let lastSpeaker = null;
    for (const block of (session.blocks || [])) {
      if (block.owner === "user") {
        appendAnnotation(sessionDiv, block);
        lastSpeaker = null;
      } else {
        const label = speakerLabel(block.speaker);
        if (label && block.speaker !== lastSpeaker) appendSpeaker(sessionDiv, label);
        lastSpeaker = block.speaker || null;
        appendRow(sessionDiv, columns, block);
      }
      for (const segment of mine.filter((s) => s.after_block_id === block.id)) {
        appendDivider(sessionDiv, segment);
        placed.add(segment);
        lastSpeaker = null;
      }
    }
    holder.appendChild(sessionDiv);
  }
  // 还没有稿的线(房间刚开、第一场录音尚未落定内容)照样要显示 ——
  // 「已经开始录了」本身就是观看者需要的信息。
  for (const segment of segments) {
    if (!placed.has(segment)) appendDivider(holder, segment);
  }
}

// 已进稿的句子。实时尾部(bounded tail)会包含刚落定的句子,而它们同时
// 已经出现在稿区 —— 不去重的话,整屏内容都是双份。合并键是
// session_id + 句块 id(T2 块 id 就是 utterance id)。
function transcribedIds() {
  const ids = new Set();
  for (const session of state.sessions) {
    for (const block of (session.blocks || [])) {
      ids.add(session.session_id + ":" + block.id);
    }
  }
  return ids;
}

// 某一栏在稿里已有的全部文本,连成大串做包含判断 —— 真实录音的推测
// 片段(「Testing.」这类)往往是已落稿句子的子串,等价判断拦不住它们。
function columnHaystack(key) {
  const parts = [];
  for (const session of state.sessions) {
    for (const block of (session.blocks || [])) {
      const text = cellText(block, key);
      if (text) parts.push(text);
    }
  }
  return parts.join(" ");
}

// 一栏的实时内容:只收属于这门语言的句子,与稿去重,只留最近几行。
//
// 真实录音的帧里,utterance 的语言会飘(语言识别、辅助车道的片段都在
// 同一个尾部里)——不按语言分栏的话,英语碎句、法语片段全部糊进第一栏,
// 越积越长,这正是「栏目下面出现很长一段文字」的来源。主播本机画布靠
// 每语言一条车道的投影解决同一个问题。
const LIVE_LINES_PER_COLUMN = 3;

// 本帧的主导源语言。真实录音里语言识别会飘,辅助车道的碎片也混在同一个
// 尾部 —— 原文栏只收主导语言,漂移片段要么归自己语言的栏,要么不显示。
// 信号分两级:带说话人标识的句子(canonical 车道产物)优先参与判定,
// 碎片通常没有;同级按句数加权,长度只作平票裁决 —— 一句冗长的外语
// 碎片不该赢过两句正主。
function dominantSourceLanguage(frame) {
  const utterances = frame.utterances || [];
  const speakered = utterances.filter((u) => u.speaker);
  const pool = speakered.length ? speakered : utterances;
  const count = {};
  const length = {};
  for (const u of pool) {
    const src = u.provisional_source_language || u.source_language || "und";
    count[src] = (count[src] || 0) + 1;
    length[src] = (length[src] || 0) + (u.source_text || "").length;
  }
  let best = null;
  for (const lang of Object.keys(count)) {
    if (best === null
        || count[lang] > count[best]
        || (count[lang] === count[best] && length[lang] > length[best])) {
      best = lang;
    }
  }
  return best;
}

function liveColumnLines(key, dominantSource) {
  const frame = state.frame;
  if (!frame) return [];
  const seen = transcribedIds();
  const lines = [];
  for (const u of (frame.utterances || [])) {
    if (seen.has((u.session_id || "") + ":" + u.id)) continue;
    const src = u.provisional_source_language || u.source_language;
    if (key === "source") {
      const effective = src || "und";
      if ((effective === dominantSource || effective === "und") && u.source_text) {
        lines.push(u.source_text);
      }
    } else if (u.translated_language === key && u.translated_text) {
      lines.push(u.translated_text);
    } else if (src === key && u.source_text) {
      lines.push(u.source_text);
    }
  }
  // 句子车道没覆盖的语言,用该语言最新的 cue 补上。
  if (key !== "source" && lines.length === 0) {
    const latest = (frame.cues || []).filter((c) => c.target_language === key).pop();
    if (latest && latest.text) lines.push(latest.text);
  }
  const haystack = columnHaystack(key);
  return lines.filter((t) => t && !haystack.includes(t)).slice(-LIVE_LINES_PER_COLUMN);
}

// 正在说的文字直接续在稿后原地刷新 —— 与 App 录音画布同一观感,
// 不做引用块。每栏一个独立的小栈,新句把旧句往上顶。
function renderLive(columns) {
  const holder = el("livetail");
  holder.textContent = "";
  const frame = state.frame;
  if (!frame || state.ended) return;
  if ((frame.utterances || []).length || (frame.cues || []).length) {
    const dominantSource = dominantSourceLanguage(frame);
    const stacks = columns.map((key) => liveColumnLines(key, dominantSource));
    if (stacks.every((stack) => stack.length === 0)) return;
    // 正在说话的是谁:取本帧最后一句带说话人的话。实时区一次只有几行,
    // 逐行标名字反而挤,一条小标说清「现在这段是谁在说」就够。
    const live = (frame.utterances || []).filter((u) => u.speaker).pop();
    const label = live ? speakerLabel(live.speaker) : null;
    if (label) appendSpeaker(holder, label);
    const row = document.createElement("div");
    row.className = "row";
    gridStyle(row, columns.length);
    for (const stack of stacks) {
      const cell = document.createElement("div");
      cell.className = "cell";
      for (const text of stack) {
        const p = document.createElement("p");
        p.textContent = text;
        cell.appendChild(p);
      }
      row.appendChild(cell);
    }
    holder.appendChild(row);
  } else {
    // 旧版主播:只有压扁行,不分栏。
    for (const line of (frame.lines || [])) {
      const text = line.source_text || line.target_text;
      if (!text) continue;
      const p = document.createElement("p");
      p.className = "cell";
      p.textContent = text;
      holder.appendChild(p);
    }
  }
}

function render() {
  const columns = activeColumns();
  renderLangButtons();
  renderColumnHead(columns);
  renderTranscript(columns);
  renderLive(columns);
  if (state.following) el("main").scrollTop = el("main").scrollHeight;
}

const main = el("main");
main.addEventListener("scroll", () => {
  const nearBottom = main.scrollHeight - main.scrollTop - main.clientHeight < 48;
  state.following = nearBottom;
  el("follow").style.display = nearBottom ? "none" : "block";
});
el("follow").onclick = () => {
  state.following = true;
  el("follow").style.display = "none";
  render();
};

renderChrome();

const roomId = location.pathname.split("/").pop();
const source = new EventSource(`/v1/rooms/${roomId}/events`);
source.addEventListener("init", (e) => {
  const data = JSON.parse(e.data);
  state.sessions = data.sessions || [];
  state.frame = data.frame;
  state.segments = data.segments || [];
  state.speakers = {};
  for (const session of state.sessions) mergeSpeakers(session);
  state.retentionHours = data.retention_hours || null;
  setStatus("live");
  render();
});
source.addEventListener("frame", (e) => { state.frame = JSON.parse(e.data); render(); });
source.addEventListener("blocks", (e) => {
  const data = JSON.parse(e.data);
  mergeSpeakers(data);
  const index = state.sessions.findIndex((s) => s.session_id === data.session_id);
  if (index >= 0) state.sessions[index] = data; else state.sessions.push(data);
  render();
});
source.addEventListener("segment", (e) => {
  const data = JSON.parse(e.data);
  state.segments.push(data);
  // 暂停即字幕停住 —— 半句推测文本不能一直挂在屏幕上。
  if (data.kind === "paused") state.frame = null;
  render();
});
source.addEventListener("ended", () => {
  state.ended = true;
  source.close();
  setStatus("ended");
  render();
});
source.onerror = () => { if (!state.ended) setStatus("reconnecting"); };
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "zulangue-caption-web"
    protocol_version = "HTTP/1.1"

    @property
    def store(self) -> RoomStore:
        return self.server.store  # type: ignore[attr-defined]

    @property
    def public_base(self) -> str:
        return self.server.public_base  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args) -> None:  # 静默访问日志;错误仍走 stderr
        pass

    def send_json(self, status: int, payload: dict) -> None:
        # ensure_ascii=False:中日韩文本按 UTF-8 原样输出,比 \uXXXX 转义
        # 省一半以上字节 —— 这个服务的载荷几乎全是这三种文字。
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def bearer_token(self) -> str:
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        return header[len(prefix):] if header.startswith(prefix) else ""

    def read_body(self) -> bytes | None:
        """读掉并返回请求体;超限时排干后返回 None。

        **每个带体的请求都必须先走它、再谈拒绝。** 响应而不读体,未读字节
        会留在 keep-alive 连接里,毒害下一个经边缘代理复用同一后端连接的
        请求 —— 表现为 501 `Unsupported method ('{}GET')`,而且殃及的是
        **别人**的请求。本地测试抓不到:测试客户端不共享后端连接,只有
        代理的连接池会。生产冒烟(caption_web_prod_smoke.sh)抓到过一次,
        不许再犯。
        """
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        if length > MAX_BODY_BYTES:
            # 先把声明的长度有界地排干再拒绝 —— 不读就回复,客户端还在写,
            # 只会看到 connection reset 而不是 413。排不完的直接断连。
            drain_cap = 8 * MAX_BODY_BYTES
            if length <= drain_cap:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 65536))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            else:
                self.close_connection = True
            return None
        return self.rfile.read(length)

    # ------------------------------------------------------------------
    def do_GET(self) -> None:
        # 病理客户端会给 GET 带体;不排干同样毒害连接复用。
        self.read_body()
        if self.path == "/healthz":
            self.send_json(200, {"status": "ok", "rooms": len(self.store.rooms)})
            return

        if self.path.startswith("/r/"):
            room_id = self.path[len("/r/"):]
            if self.store.room_for_view(room_id) is None:
                self.send_json(404, {"error": "room_not_found"})
                return
            body = VIEWER_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/v1/rooms/") and self.path.endswith("/events"):
            room_id = self.path[len("/v1/rooms/"):-len("/events")]
            room = self.store.room_for_view(room_id)
            if room is None:
                self.send_json(404, {"error": "room_not_found"})
                return
            subscriber = self.store.subscribe(room)
            if subscriber is None:
                self.send_json(429, {"error": "too_many_subscribers"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            # SSE 是无限响应,不能声明长度,也不复用连接。
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    try:
                        message = subscriber.get(timeout=25)
                    except queue.Empty:
                        # 心跳注释:穿透中间件的空闲超时,顺带探测断连。
                        self.wfile.write(b": keep-alive\n\n")
                        self.wfile.flush()
                        continue
                    event = message["event"]
                    data = json.dumps(message["data"], ensure_ascii=False)
                    self.wfile.write(f"event: {event}\ndata: {data}\n\n".encode())
                    self.wfile.flush()
                    if event == "ended":
                        break
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.store.unsubscribe(room, subscriber)
            return

        self.send_json(404, {"error": "not_found"})

    # ------------------------------------------------------------------
    def do_POST(self) -> None:
        # 体必须最先读 —— 在任何拒绝之前。见 read_body 的注释。
        body = self.read_body()

        if self.path == "/v1/rooms":
            room = self.store.create_room(self.client_address[0])
            if room is None:
                self.send_json(429, {"error": "room_limit"})
                return
            self.send_json(
                200,
                {
                    "room_id": room.room_id,
                    "publish_token": room.publish_token,
                    "viewer_url": f"{self.public_base}/r/{room.room_id}",
                },
            )
            return

        for suffix, event in (
            ("/frame", "frame"),
            ("/blocks", "blocks"),
            ("/segment", "segment"),
        ):
            if self.path.startswith("/v1/rooms/") and self.path.endswith(suffix):
                room_id = self.path[len("/v1/rooms/"):-len(suffix)]
                room = self.store.room_for_publish(room_id, self.bearer_token())
                if room is None:
                    self.send_json(401, {"error": "unauthorized"})
                    return
                if body is None:
                    self.send_json(413, {"error": "payload_too_large"})
                    return
                try:
                    data = json.loads(body) if body else None
                except json.JSONDecodeError:
                    data = None
                if not isinstance(data, dict):
                    self.send_json(400, {"error": "invalid_json"})
                    return
                self.store.publish(room, event, data)
                self.send_json(200, {"status": "accepted"})
                return

        self.send_json(404, {"error": "not_found"})

    # ------------------------------------------------------------------
    def do_DELETE(self) -> None:
        self.read_body()
        if self.path.startswith("/v1/rooms/"):
            room_id = self.path[len("/v1/rooms/"):]
            room = self.store.room_for_publish(room_id, self.bearer_token())
            if room is None:
                self.send_json(401, {"error": "unauthorized"})
                return
            self.store.end_room(room)
            # 封笔立刻落盘:重启后这间房必须还是「已结束」,不能因为丢了
            # 这一次改动而重新变成可写。
            self.store.flush()
            self.send_json(200, {"status": "ended"})
            return
        self.send_json(404, {"error": "not_found"})


class QuietServer(ThreadingHTTPServer):
    """浏览器关页、代理掐线都是常态 —— 断连不打 traceback。"""

    def handle_error(self, request, client_address) -> None:  # noqa: N802
        error = sys.exception()
        if isinstance(error, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def maintenance_loop(
    store: RoomStore,
    flush_seconds: float = 5,
    sweep_seconds: float = 300,
) -> None:
    """一条线程管两件事:去抖落盘(秒级)与清扫过期(分钟级)。"""
    since_sweep = 0.0
    while True:
        time.sleep(flush_seconds)
        since_sweep += flush_seconds
        try:
            store.flush()
        except OSError as error:
            # 写不下去不该拖垮服务:房间还在内存里,字幕照常发。下一拍
            # 再试;真的一直写不了,重启会丢房 —— 与从前的行为等同。
            print(f"caption-web: 状态落盘失败: {error}", file=sys.stderr)
        if since_sweep >= sweep_seconds:
            since_sweep = 0.0
            store.sweep_idle()


def main() -> None:
    parser = argparse.ArgumentParser(description="Zulangue caption-web service")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8100)
    parser.add_argument(
        "--public-base",
        default="https://zulangue-caption.exe.xyz",
        help="观看页链接的公开基址(反代后面的服务自己拼不出来)",
    )
    parser.add_argument(
        "--state-file",
        default=None,
        help="房间落盘位置。不给就是纯内存:重启即空,会场里的二维码"
        "同时作废。给了就是明文字幕以 0600 存在这个文件里,直到留存期满。",
    )
    parser.add_argument(
        "--retention-hours",
        type=float,
        default=ROOM_RETENTION_SECONDS / 3600,
        help="最后一次推送之后,稿还留多久(停止共享之后也按它计时)",
    )
    args = parser.parse_args()

    store = RoomStore(
        state_path=args.state_file,
        retention_seconds=args.retention_hours * 3600,
    )
    loaded = store.load()
    if loaded:
        print(f"caption-web: 从快照载入 {loaded} 个房间", file=sys.stderr)
    threading.Thread(target=maintenance_loop, args=(store,), daemon=True).start()
    server = QuietServer((args.host, args.port), Handler)
    server.store = store  # type: ignore[attr-defined]
    server.public_base = args.public_base.rstrip("/")  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
