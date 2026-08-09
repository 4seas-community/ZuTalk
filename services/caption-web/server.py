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
<title>Zulangue Live Captions</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; font-family: -apple-system, "PingFang SC", "Hiragino Sans",
    "Noto Sans", sans-serif; background: #111; color: #eee;
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
  main { flex: 1; overflow-y: auto; padding: 16px 14px 40px; }
  .session { margin-bottom: 20px; }
  .block { margin: 0 0 12px; line-height: 1.55; font-size: 17px; }
  .block .annotation { color: #9ac; font-size: 15px; }
  .live { opacity: 0.65; border-left: 3px solid #6c6; padding-left: 10px; }
  .live .partial { font-style: normal; }
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
  <span class="status" id="status">connecting…</span>
</header>
<main id="main">
  <div id="transcript"></div>
  <div id="livetail" class="live"></div>
</main>
<button id="follow">↓ Live</button>
<script>
"use strict";
const state = { sessions: [], frame: null, lang: null, langs: [], following: true, ended: false };
const el = (id) => document.getElementById(id);

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
      const src = u.provisional_source_language || u.source_language;
      if (src && src !== "und") langs.add(src);
      if (u.translated_language) langs.add(u.translated_language);
    }
    for (const c of (frame.cues || [])) langs.add(c.target_language);
    for (const line of (frame.lines || [])) {
      if (line.source_language && line.source_language !== "und") langs.add(line.source_language);
      if (line.target_language) langs.add(line.target_language);
    }
  }
  return Array.from(langs).sort();
}

function renderLangButtons() {
  const langs = collectLanguages();
  if (JSON.stringify(langs) === JSON.stringify(state.langs)) return;
  state.langs = langs;
  const holder = el("langs");
  holder.textContent = "";
  for (const lang of langs) {
    const button = document.createElement("button");
    button.className = "lang" + (state.lang === lang ? " active" : "");
    button.textContent = lang;
    button.onclick = () => { state.lang = (state.lang === lang ? null : lang); render(); };
    holder.appendChild(button);
  }
}

function blockText(block) {
  // 选中语言有车道就用车道;没有回落原文 —— 空白比原文更糟。
  if (state.lang && block.lanes && block.lanes[state.lang]) return block.lanes[state.lang];
  return block.text || "";
}

function renderTranscript() {
  const holder = el("transcript");
  holder.textContent = "";
  for (const session of state.sessions) {
    const sessionDiv = document.createElement("div");
    sessionDiv.className = "session";
    for (const block of (session.blocks || [])) {
      const p = document.createElement("p");
      p.className = "block";
      const text = blockText(block);
      if (!text) continue;
      if (block.owner === "user") {
        const span = document.createElement("span");
        span.className = "annotation";
        span.textContent = text;
        p.appendChild(span);
      } else {
        p.textContent = text;
      }
      sessionDiv.appendChild(p);
    }
    holder.appendChild(sessionDiv);
  }
}

function renderLive() {
  const holder = el("livetail");
  holder.textContent = "";
  const frame = state.frame;
  if (!frame || state.ended) return;
  const utterances = frame.utterances || [];
  const cues = frame.cues || [];
  if (utterances.length) {
    for (const u of utterances) {
      const src = u.provisional_source_language || u.source_language;
      let text = null;
      if (!state.lang || state.lang === src) text = u.source_text;
      else if (state.lang === u.translated_language) text = u.translated_text;
      if (text) {
        const p = document.createElement("p");
        p.className = "block partial";
        p.textContent = text;
        holder.appendChild(p);
      }
    }
    // 句子车道没覆盖的语言,用该语言最新的 cue 补上。
    if (state.lang) {
      const latest = cues.filter((c) => c.target_language === state.lang).pop();
      const covered = utterances.some((u) => u.translated_language === state.lang);
      if (latest && !covered && latest.text) {
        const p = document.createElement("p");
        p.className = "block partial";
        p.textContent = latest.text;
        holder.appendChild(p);
      }
    }
  } else {
    // 旧版主播:只有压扁行。
    for (const line of (frame.lines || [])) {
      const text = state.lang && state.lang === line.target_language
        ? line.target_text : line.source_text;
      if (!text) continue;
      const p = document.createElement("p");
      p.className = "block partial";
      p.textContent = text;
      holder.appendChild(p);
    }
  }
}

function render() {
  renderLangButtons();
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
el("follow").onclick = () => { state.following = true; render(); };

const roomId = location.pathname.split("/").pop();
const source = new EventSource(`/v1/rooms/${roomId}/events`);
source.addEventListener("init", (e) => {
  const data = JSON.parse(e.data);
  state.sessions = data.sessions || [];
  state.frame = data.frame;
  el("status").textContent = "live";
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
  const status = el("status");
  status.textContent = "This share has ended. The transcript stays until you close the page.";
  status.className = "status ended";
  render();
});
source.onerror = () => { if (!state.ended) el("status").textContent = "reconnecting…"; };
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
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return None
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
                body = self.read_body()
                if body is None:
                    self.send_json(413, {"error": "payload_too_large"})
                    return
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    self.send_json(400, {"error": "invalid_json"})
                    return
                if not isinstance(data, dict):
                    self.send_json(400, {"error": "invalid_payload"})
                    return
                self.store.publish(room, event, data)
                self.send_json(200, {"status": "accepted"})
                return

        self.send_json(404, {"error": "not_found"})

    # ------------------------------------------------------------------
    def do_DELETE(self) -> None:
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
