#!/usr/bin/env python3
"""Zulangue caption-web:扫码看实时字幕稿。

设计见 docs/architecture/share-web-captions.md。要点:

- 主持人的 App 建房后推两种载荷:帧(实时 tail,replace-in-full)与
  块快照(稿,按 session 只留最新)。浏览器经 SSE 订阅。
- **明文经过本服务**是产品定案(2026-08-09),App 的 UI 负责把这句话
  说给主持人;本服务的责任是不留超过必要的东西:全部状态在内存,
  房间关闭或空闲超时即清,进程重启即空。
- 房间号即门票(不可猜测),发布口令只有主持人持有。
- 上限挡的是脚本滥用,不是「未授权用户用不了」。
"""

from __future__ import annotations

import argparse
import json
import queue
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 一场会议量级的房间;超过这个数,新建房被拒,等 TTL 释放。
MAX_ROOMS = 200
# 帧与块快照的单次载荷上限。多语言长会议的块快照也远在这之下。
MAX_BODY_BYTES = 1 * 1024 * 1024
# 最后一次推送之后,房间还能活多久。与会议时长同量级。
ROOM_IDLE_TTL_SECONDS = 6 * 60 * 60
# 每个 IP 每分钟最多建几个房。正常使用是一场会议一个。
MAX_CREATES_PER_MINUTE = 6
# 单房间的 SSE 订阅上限 —— 会议室量级,不是直播量级。
MAX_SUBSCRIBERS_PER_ROOM = 200
# 订阅者队列深度。帧是 replace-in-full 的,浏览器掉队就丢旧帧。
SUBSCRIBER_QUEUE_DEPTH = 32


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
        self.subscribers: list[queue.Queue] = []
        self.ended = False


class RoomStore:
    """全部内存态。锁保护房间表;每个订阅者一条队列,fanout 不做背压 ——
    队列满了丢旧消息,和帧的 replace-in-full 性质一致。"""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.rooms: dict[str, Room] = {}
        # IP → 最近建房时间戳列表(限速用)。
        self.creates_by_ip: dict[str, list[float]] = {}

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
            return room

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
        """清掉空闲超时的房间。返回清掉的数量。"""
        cutoff = now() - ROOM_IDLE_TTL_SECONDS
        removed = 0
        with self.lock:
            for room_id in list(self.rooms):
                room = self.rooms[room_id]
                if room.last_activity < cutoff:
                    self._end_room_locked(room)
                    del self.rooms[room_id]
                    removed += 1
        return removed

    def end_room(self, room: Room) -> None:
        with self.lock:
            self._end_room_locked(room)
            self.rooms.pop(room.room_id, None)

    def _end_room_locked(self, room: Room) -> None:
        room.ended = True
        for subscriber in room.subscribers:
            offer(subscriber, {"event": "ended", "data": {}})
        room.subscribers.clear()

    def publish(self, room: Room, event: str, data: dict) -> None:
        with self.lock:
            room.last_activity = now()
            if event == "frame":
                room.frame = data
            elif event == "blocks":
                session_id = data.get("session_id")
                if isinstance(session_id, str) and session_id:
                    if session_id not in room.blocks:
                        room.session_order.append(session_id)
                    room.blocks[session_id] = data
            for subscriber in list(room.subscribers):
                offer(subscriber, {"event": event, "data": data})

    def subscribe(self, room: Room) -> queue.Queue | None:
        """挂一个订阅者,并立刻塞进全量初始状态。"""
        with self.lock:
            if room.ended:
                return None
            if len(room.subscribers) >= MAX_SUBSCRIBERS_PER_ROOM:
                return None
            subscriber: queue.Queue = queue.Queue(maxsize=SUBSCRIBER_QUEUE_DEPTH)
            init = {
                "sessions": [room.blocks[sid] for sid in room.session_order],
                "frame": room.frame,
            }
            offer(subscriber, {"event": "init", "data": init})
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
  .cell .annotation { color: #9ac; font-size: 15px; }
  .colhead { position: sticky; top: 0; background: #111; display: grid;
    gap: 14px; padding: 4px 0 6px; border-bottom: 1px solid #2a2a2a;
    margin-bottom: 10px; }
  .colhead span { font-size: 12px; color: #888; }
  .live { opacity: 0.65; border-left: 3px solid #6c6; padding-left: 10px; }
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
  <div id="livetail" class="live"></div>
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
    ended: "这场分享已结束。字幕稿会保留到你关闭页面。",
    follow: "↓ 回到实时",
    source: "原文",
  },
  "en": {
    title: "Zulangue Live Captions",
    connecting: "connecting…",
    live: "live",
    reconnecting: "reconnecting…",
    ended: "This share has ended. The transcript stays until you close the page.",
    follow: "↓ Live",
    source: "Source",
  },
  "th": {
    title: "Zulangue ซับไตเติลสด",
    connecting: "กำลังเชื่อมต่อ…",
    live: "สด",
    reconnecting: "กำลังเชื่อมต่อใหม่…",
    ended: "การแชร์นี้จบแล้ว ทรานสคริปต์จะยังอยู่จนกว่าคุณจะปิดหน้านี้",
    follow: "↓ กลับสู่สด",
    source: "ต้นฉบับ",
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

const state = { sessions: [], frame: null, selected: loadSelection(), langs: [],
                following: true, ended: false, statusKey: "connecting",
                uiLang: detectUiLang() };
const el = (id) => document.getElementById(id);
const t = (key) => UI[state.uiLang][key];
const columnLabel = (key) => key === "source" ? t("source") : key;

function renderChrome() {
  document.documentElement.lang = state.uiLang;
  document.title = t("title");
  const status = el("status");
  status.textContent = t(state.statusKey);
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

// 稿里某一栏的取值:「原文」取块文本,语言取车道;批注块只有原文。
function cellText(block, key) {
  if (key === "source") return block.text || "";
  return (block.lanes && block.lanes[key]) || "";
}

function gridStyle(element) {
  element.style.gridTemplateColumns = `repeat(${state.selected.length}, 1fr)`;
}

function renderColumnHead() {
  const head = el("colhead");
  head.textContent = "";
  if (state.selected.length < 2) return;
  gridStyle(head);
  head.className = "colhead";
  for (const key of state.selected) {
    const span = document.createElement("span");
    span.textContent = columnLabel(key);
    head.appendChild(span);
  }
}

function appendRow(holder, values, annotation) {
  if (values.every((v) => !v)) return;
  const row = document.createElement("div");
  row.className = "row";
  gridStyle(row);
  for (const value of values) {
    const cell = document.createElement("div");
    cell.className = "cell" + (value ? "" : " empty");
    if (annotation && value) {
      const span = document.createElement("span");
      span.className = "annotation";
      span.textContent = value;
      cell.appendChild(span);
    } else {
      cell.textContent = value || "";
    }
    row.appendChild(cell);
  }
  holder.appendChild(row);
}

function renderTranscript() {
  const holder = el("transcript");
  holder.textContent = "";
  for (const session of state.sessions) {
    const sessionDiv = document.createElement("div");
    sessionDiv.className = "session";
    for (const block of (session.blocks || [])) {
      appendRow(
        sessionDiv,
        state.selected.map((key) => cellText(block, key)),
        block.owner === "user"
      );
    }
    holder.appendChild(sessionDiv);
  }
}

// 已进稿的句子。实时尾部(bounded tail)会包含刚落定的句子,而它们同时
// 已经出现在稿区 —— 不去重的话,整屏内容都是双份。主播本机画布靠
// durable/预览按 sequence 合并解决同一个问题;这里的合并键是
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

// 稿里某语言已有的文本。cue 没有句块 id,按文本去重。
function transcribedTexts(lang) {
  const texts = new Set();
  for (const session of state.sessions) {
    for (const block of (session.blocks || [])) {
      if (block.lanes && block.lanes[lang]) texts.add(block.lanes[lang]);
    }
  }
  return texts;
}

function liveCellText(u, key) {
  if (key === "source") return u.source_text || "";
  if (u.translated_language === key) return u.translated_text || "";
  return "";
}

function renderLive() {
  const holder = el("livetail");
  holder.textContent = "";
  const frame = state.frame;
  if (!frame || state.ended) return;
  const seen = transcribedIds();
  const allUtterances = frame.utterances || [];
  const utterances = allUtterances.filter(
    (u) => !seen.has((u.session_id || "") + ":" + u.id)
  );
  const cues = frame.cues || [];
  if (allUtterances.length) {
    for (const u of utterances) {
      appendRow(holder, state.selected.map((key) => liveCellText(u, key)), false);
    }
    // 句子车道没覆盖的语言,各用该语言最新的 cue 补一行(稿里已有的不重复)。
    const fallback = state.selected.map((key) => {
      if (key === "source") return "";
      const covered = allUtterances.some((u) => u.translated_language === key);
      if (covered) return "";
      const latest = cues.filter((c) => c.target_language === key).pop();
      if (!latest || !latest.text) return "";
      return transcribedTexts(key).has(latest.text) ? "" : latest.text;
    });
    appendRow(holder, fallback, false);
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
  renderLangButtons();
  renderColumnHead();
  renderTranscript();
  renderLive();
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
  setStatus("live");
  render();
});
source.addEventListener("frame", (e) => { state.frame = JSON.parse(e.data); render(); });
source.addEventListener("blocks", (e) => {
  const data = JSON.parse(e.data);
  const index = state.sessions.findIndex((s) => s.session_id === data.session_id);
  if (index >= 0) state.sessions[index] = data; else state.sessions.push(data);
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
                self.send_json(429 if not room.ended else 410, {"error": "unavailable"})
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

        for suffix, event in (("/frame", "frame"), ("/blocks", "blocks")):
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
            self.send_json(200, {"status": "ended"})
            return
        self.send_json(404, {"error": "not_found"})


class QuietServer(ThreadingHTTPServer):
    """浏览器关页、代理掐线都是常态 —— 断连不打 traceback。"""

    def handle_error(self, request, client_address) -> None:  # noqa: N802
        import sys

        error = sys.exception()
        if isinstance(error, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def sweep_loop(store: RoomStore, interval_seconds: float) -> None:
    while True:
        time.sleep(interval_seconds)
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
    args = parser.parse_args()

    store = RoomStore()
    threading.Thread(target=sweep_loop, args=(store, 300), daemon=True).start()
    server = QuietServer((args.host, args.port), Handler)
    server.store = store  # type: ignore[attr-defined]
    server.public_base = args.public_base.rstrip("/")  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
