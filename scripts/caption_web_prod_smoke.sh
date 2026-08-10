#!/usr/bin/env bash
# caption-web **生产**冒烟:对已部署实例验证整条链路。
#
# 与 caption_web_smoke.sh(本地契约冒烟)分工:这条走公网,专门验证只有
# 真实部署才暴露的东西 —— 边缘代理会不会缓冲 SSE(缓冲=字幕永远到不了
# 浏览器,本地测不出)、TLS 下的 reqwest 推送、公网可达性、登录墙是否
# 真的放开了。手动运行,不进 ci-check —— 它依赖外部服务与网络。
#
#   CAPTION_URL=https://zulangue-caption.exe.xyz scripts/caption_web_prod_smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${CAPTION_URL:-https://zulangue-caption.exe.xyz}"
step() { printf '\n== %s ==\n' "$1"; }

step "服务可达(且没有登录墙)"
HEALTH=$(curl -sf --max-time 15 "$BASE/healthz")
echo "$HEALTH" | grep -q '"status": "ok"' || { echo "✗ healthz 不对: $HEALTH"; exit 1; }

step "建房"
ROOM_JSON=$(curl -sf --max-time 15 -X POST "$BASE/v1/rooms")
ROOM_ID=$(echo "$ROOM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["room_id"])')
TOKEN=$(echo "$ROOM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["publish_token"])')
VIEWER=$(echo "$ROOM_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["viewer_url"])')
echo "房间: $VIEWER"
echo "$VIEWER" | grep -q "^$BASE/r/" || { echo "✗ viewer_url 基址不对(--public-base 配错?)"; exit 1; }

step "错口令必须被拒"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    -H 'Authorization: Bearer wrong-token' -H 'Content-Type: application/json' \
    -d '{}' "$BASE/v1/rooms/$ROOM_ID/frame")
test "$STATUS" = "401" || { echo "✗ 错口令得到 $STATUS,期望 401"; exit 1; }

step "SSE 必须实时穿透边缘代理(先订阅,再推送,3 秒内要看到)"
SSE_OUT=$(mktemp)
curl -sN --max-time 12 "$BASE/v1/rooms/$ROOM_ID/events" > "$SSE_OUT" &
SSE_PID=$!
disown  # 之后要 kill 它;不摘出作业表,bash 会把 Terminated 播报进输出。
sleep 2  # 让订阅先建立 —— 这才测得出「推送后的增量事件」而不只是 init 全量。
curl -sf --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"preview_revision": 1, "session_id": "prod-smoke", "utterances": [], "lines": [{"speaker": null, "source_language": "ja", "source_text": "生放送テスト", "target_language": "zh-Hans", "target_text": "直播测试", "completion": "partial"}]}' \
    "$BASE/v1/rooms/$ROOM_ID/frame" > /dev/null
curl -sf --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"session_id": "prod-smoke", "blocks": [{"id": "b1", "owner": "capture:prod-smoke", "text": "生产稿", "lanes": {"en": "prod transcript"}}]}' \
    "$BASE/v1/rooms/$ROOM_ID/blocks" > /dev/null
for _ in $(seq 1 6); do
    grep -q "生放送テスト" "$SSE_OUT" && grep -q "生产稿" "$SSE_OUT" && break
    sleep 0.5
done
kill "$SSE_PID" 2>/dev/null || true
grep -q "event: init" "$SSE_OUT" || { echo "✗ SSE 没收到 init"; exit 1; }
grep -q "生放送テスト" "$SSE_OUT" || { echo "✗ 推送后的帧没有实时到达 —— 边缘代理在缓冲 SSE?"; exit 1; }
grep -q "生产稿" "$SSE_OUT" || { echo "✗ 推送后的稿没有实时到达"; exit 1; }
rm -f "$SSE_OUT"
echo "SSE 实时穿透 ✓"

step "晚订阅者拿全量(init 里有稿与最新帧)"
LATE=$(curl -sN --max-time 3 "$BASE/v1/rooms/$ROOM_ID/events" || true)
echo "$LATE" | grep -q "生产稿" || { echo "✗ 晚订阅者没拿到稿"; exit 1; }
echo "$LATE" | grep -q "生放送テスト" || { echo "✗ 晚订阅者没拿到最新帧"; exit 1; }

step "观看页可打开且自足"
PAGE=$(curl -sf --max-time 15 "$VIEWER")
echo "$PAGE" | grep -q "EventSource" || { echo "✗ 观看页不对"; exit 1; }

step "真实 Rust 推送链路(reqwest + TLS)对生产建房推送"
OUTPUT=$(CAPTION_WEB_SMOKE_URL="$BASE" cargo test -p vt-ffi --lib \
    share_web::tests::web_share_smoke_against_local_service \
    -- --ignored --exact --nocapture 2>&1)
echo "$OUTPUT" | grep -q "test result: ok" || {
    echo "$OUTPUT" | tail -20; echo "✗ Rust 链路对生产失败"; exit 1; }
RUST_VIEWER=$(echo "$OUTPUT" | grep -o 'viewer_url=.*' | head -1 | cut -d= -f2)
RUST_ROOM=${RUST_VIEWER##*/}
RUST_EVENTS=$(curl -sN --max-time 3 "$BASE/v1/rooms/$RUST_ROOM/events" || true)
echo "$RUST_EVENTS" | grep -q "こんにちは" || { echo "✗ Rust 推的帧没到生产"; exit 1; }
echo "$RUST_EVENTS" | grep -q "冒烟稿" || { echo "✗ Rust 推的稿没到生产"; exit 1; }

step "封笔:不再收推送,稿仍读得到"
curl -sf --max-time 15 -X DELETE -H "Authorization: Bearer $TOKEN" \
    "$BASE/v1/rooms/$ROOM_ID" > /dev/null
# 散场之后扫码进来的人要读到整份稿,不是 404 —— 会议散场恰恰是最多人
# 去读稿的时候。稿由留存期兜底清除,不由「停止共享」清除。
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/r/$ROOM_ID")
test "$STATUS" = "200" || { echo "✗ 封笔后观看页得到 $STATUS,期望 200"; exit 1; }
ENDED_EVENTS=$(curl -sN --max-time 3 "$BASE/v1/rooms/$ROOM_ID/events" || true)
echo "$ENDED_EVENTS" | grep -q "event: init" \
    || { echo "✗ 封笔后订阅拿不到全量"; exit 1; }
echo "$ENDED_EVENTS" | grep -q "event: ended" \
    || { echo "✗ 封笔后订阅没收到 ended"; exit 1; }
# 封笔之后主播不能再写。
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"preview_revision":99}' "$BASE/v1/rooms/$ROOM_ID/frame")
test "$STATUS" = "401" || { echo "✗ 封笔后仍接受推送($STATUS)"; exit 1; }
# Rust 那间由服务端 TTL 兜底(测试进程退出即弃房),这里替它收尾。
curl -s --max-time 15 -X DELETE "$BASE/v1/rooms/$RUST_ROOM" \
    -H "Authorization: Bearer unknown" > /dev/null || true

printf '\n✓ [caption-web] 生产链路冒烟通过: %s\n' "$BASE"
