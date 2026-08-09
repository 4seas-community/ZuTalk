#!/usr/bin/env bash
# caption-web 跨层冒烟:真实 Rust 推送链路 → 本地 Python 服务 → SSE 验证。
#
# 防的是两边契约漂移:Rust 侧 serde 字段名与服务端/网页读的字段名分家时,
# 单元测试两边各自全绿,链路却是断的。本脚本本地起服务、跑 vt-ffi 的
# ignored 冒烟测试、再用 curl 从 SSE 里验证帧与稿真的到了。
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8199
BASE="http://127.0.0.1:${PORT}"

python3 services/caption-web/server.py --host 127.0.0.1 --port "$PORT" \
    --public-base "$BASE" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
    curl -sf "$BASE/healthz" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -sf "$BASE/healthz" >/dev/null || { echo "FAIL: 服务没起来"; exit 1; }

# Rust 链路:建房、推帧、推稿。测试把 viewer_url 打到 stdout。
OUTPUT=$(CAPTION_WEB_SMOKE_URL="$BASE" cargo test -p vt-ffi --lib \
    share_web::tests::web_share_smoke_against_local_service \
    -- --ignored --exact --nocapture 2>&1)
echo "$OUTPUT" | grep -q "test result: ok" || {
    echo "$OUTPUT" | tail -30
    echo "FAIL: Rust 冒烟测试未通过"
    exit 1
}
VIEWER_URL=$(echo "$OUTPUT" | grep -o 'viewer_url=.*' | head -1 | cut -d= -f2)
ROOM_ID=${VIEWER_URL##*/}
test -n "$ROOM_ID" || { echo "FAIL: 拿不到房间号"; exit 1; }

# SSE 的 init 事件里应当同时有稿(冒烟稿)与最新帧(こんにちは)。
EVENTS=$(curl -s --max-time 3 "$BASE/v1/rooms/$ROOM_ID/events" || true)
echo "$EVENTS" | grep -q "冒烟稿" || { echo "FAIL: 稿没到服务端"; exit 1; }
echo "$EVENTS" | grep -q "こんにちは" || { echo "FAIL: 帧没到服务端"; exit 1; }

# 观看页可打开且自足。
PAGE=$(curl -sf "$BASE/r/$ROOM_ID")
echo "$PAGE" | grep -q "EventSource" || { echo "FAIL: 观看页不对"; exit 1; }

echo "✓ [caption-web] Rust→服务→SSE 链路冒烟通过"
