#!/usr/bin/env bash
# caption-web **生产**冒烟:对已部署实例验证整条链路。
#
# 与 caption_web_smoke.sh(本地契约冒烟)分工:这条走公网,专门验证只有
# 真实部署才暴露的东西 —— 边缘代理会不会缓冲 SSE(缓冲=字幕永远到不了
# 浏览器,本地测不出)、TLS 下的 reqwest 推送、公网可达性、登录墙是否
# 真的放开了、观看页的安全头有没有被代理剥掉。手动运行,不进 ci-check ——
# 它依赖外部服务与网络。跑完不在服务器上留任何房间。
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
cleanup() {
    curl -s -o /dev/null --max-time 15 -X DELETE -H "Authorization: Bearer $TOKEN" \
        "$BASE/v1/rooms/$ROOM_ID?purge=1" || true
}
trap cleanup EXIT
echo "房间: ${VIEWER%/*}/…"
echo "$VIEWER" | grep -q "^$BASE/r/" || { echo "✗ viewer_url 基址不对(--public-base 配错?)"; exit 1; }

step "错口令必须被拒"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    -H 'Authorization: Bearer wrong-token' -H 'Content-Type: application/json' \
    -d '{}' "$BASE/v1/rooms/$ROOM_ID/frame")
test "$STATUS" = "401" || { echo "✗ 错口令得到 $STATUS,期望 401"; exit 1; }

step "SSE 必须实时穿透边缘代理(先订阅,再推送,3 秒内要看到)"
# 载荷是信封形状的假密文:服务器不解、不看,原样转发。
SSE_OUT=$(mktemp)
curl -sN --max-time 12 "$BASE/v1/rooms/$ROOM_ID/events" > "$SSE_OUT" &
SSE_PID=$!
disown  # 之后要 kill 它;不摘出作业表,bash 会把 Terminated 播报进输出。
sleep 2  # 让订阅先建立 —— 这才测得出「推送后的增量事件」而不只是 init 全量。
curl -sf --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"v": 2, "ct": "cHJvZC1zbW9rZS1mcmFtZQ"}' \
    "$BASE/v1/rooms/$ROOM_ID/frame" > /dev/null
curl -sf --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"v": 2, "session_id": "prod-smoke:0", "ct": "cHJvZC1zbW9rZS1wYXJ0"}' \
    "$BASE/v1/rooms/$ROOM_ID/blocks" > /dev/null
for _ in $(seq 1 6); do
    grep -q "cHJvZC1zbW9rZS1mcmFtZQ" "$SSE_OUT" && grep -q "cHJvZC1zbW9rZS1wYXJ0" "$SSE_OUT" && break
    sleep 0.5
done
kill "$SSE_PID" 2>/dev/null || true
grep -q "event: init" "$SSE_OUT" || { echo "✗ SSE 没收到 init"; exit 1; }
grep -q "cHJvZC1zbW9rZS1mcmFtZQ" "$SSE_OUT" || { echo "✗ 推送后的帧没有实时到达 —— 边缘代理在缓冲 SSE?"; exit 1; }
grep -q "cHJvZC1zbW9rZS1wYXJ0" "$SSE_OUT" || { echo "✗ 推送后的稿没有实时到达"; exit 1; }
rm -f "$SSE_OUT"
echo "SSE 实时穿透 ✓"

step "观看页可打开、自足、安全头没被代理剥掉"
HEADERS=$(curl -sf --max-time 15 -D - -o /dev/null "$VIEWER")
echo "$HEADERS" | grep -qi "^content-security-policy: default-src 'none'" || { echo "✗ 观看页缺 CSP"; exit 1; }
echo "$HEADERS" | grep -qi "^referrer-policy: no-referrer" || { echo "✗ 观看页缺 Referrer-Policy"; exit 1; }
PAGE=$(curl -sf --max-time 15 "$VIEWER")
echo "$PAGE" | grep -q "crypto.subtle.decrypt" || { echo "✗ 观看页不对"; exit 1; }

step "真实 Rust 链接共享(reqwest + TLS)对生产:录音链接、直播、锁定、换链接、撤销"
OUTPUT=$(LINK_SHARE_SERVICE="$BASE" cargo test -p vt-ffi --lib \
    link_share::tests::a_link_round_trip_against_the_caption_service \
    -- --exact --nocapture 2>&1)
echo "$OUTPUT" | grep -q "test result: ok. 1 passed" || {
    echo "$OUTPUT" | tail -20; echo "✗ Rust 链路对生产失败"; exit 1; }

step "撤销:当场删掉,链接从此打不开"
cleanup
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/v1/rooms/$ROOM_ID")
test "$STATUS" = "404" || { echo "✗ 撤销后房间仍在($STATUS)"; exit 1; }
trap - EXIT

printf '\n✓ [caption-web] 生产链路冒烟通过: %s\n' "$BASE"
