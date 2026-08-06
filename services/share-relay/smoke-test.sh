#!/usr/bin/env bash
# 中继门禁冒烟测试。
#
# 验四件事,每一件都对应一种真实的部署事故:
#   1. 邀请码服务活着          —— 服务没起来,中继会把所有人都拒掉
#   2. 未登记的 endpoint 被拒  —— 门禁根本没生效
#   3. token 不符返回 401      —— 两边 service.env 不一致(最常见的事故)
#   4. 登记后被放行            —— 门禁把自己人也挡了
#
# 用法:
#   ZULANGUE_RELAY_AUTH_TOKEN=... INVITE_URL=https://invite.exe.dev ./smoke-test.sh
#   # 想连第 4 步一起验,再给一个已兑换的邀请 access token:
#   ZULANGUE_RELAY_AUTH_TOKEN=... INVITE_ACCESS_TOKEN=... ./smoke-test.sh
set -euo pipefail

INVITE_URL="${INVITE_URL:-https://invite.exe.dev}"
TOKEN="${ZULANGUE_RELAY_AUTH_TOKEN:-}"
ACCESS="${INVITE_ACCESS_TOKEN:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -n "$TOKEN" ]] || fail "需要 ZULANGUE_RELAY_AUTH_TOKEN(与中继的 IROH_RELAY_HTTP_BEARER_TOKEN 同值)"

# 一个不可能被登记的 endpoint id:合法长度的全 f。
NEVER_ENROLLED="$(printf 'f%.0s' {1..64})"

auth_call() {
  curl -sS -o "$2" -w "%{http_code}" -X POST "$INVITE_URL/v1/relay-auth" \
    -H "Authorization: Bearer $1" \
    -H "X-Iroh-Endpoint-Id: $3"
}

echo "── 1. 邀请码服务可达 ──"
curl -fsS "$INVITE_URL/healthz" >/dev/null || fail "$INVITE_URL 不可达"
echo "  ✓ $INVITE_URL 活着"

echo "── 2. 未登记的 endpoint 被拒 ──"
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(auth_call "$TOKEN" "$body" "$NEVER_ENROLLED")"
[[ "$code" == "200" ]] || fail "期望 200,实际 $code"
[[ "$(cat "$body")" == "false" ]] \
  || fail "未登记的 endpoint 竟被放行 —— 门禁没有生效"
echo "  ✓ 拒了"

echo "── 3. token 不符时 401 ──"
code="$(auth_call "definitely-not-the-token" "$body" "$NEVER_ENROLLED")"
[[ "$code" == "401" ]] \
  || fail "期望 401,实际 $code —— 两边的 token 可能都是空的"
echo "  ✓ 401"

if [[ -z "$ACCESS" ]]; then
  echo "── 4. 跳过(未提供 INVITE_ACCESS_TOKEN)──"
  echo ""
  echo "✓ 门禁在拦。要连「登记后放行」一起验,补一个已兑换的邀请 access token 再跑一次。"
  exit 0
fi

echo "── 4. 登记后被放行 ──"
probe="$(printf 'e%.0s' {1..64})"
curl -fsS -X POST "$INVITE_URL/v1/share-endpoint" \
  -H "Authorization: Bearer $ACCESS" \
  -H "Content-Type: application/json" \
  -d "{\"endpoint_id\":\"$probe\"}" >/dev/null \
  || fail "登记失败 —— access token 可能已失效"
code="$(auth_call "$TOKEN" "$body" "$probe")"
[[ "$code" == "200" && "$(cat "$body")" == "true" ]] \
  || fail "登记过的 endpoint 仍被拒(HTTP $code, body $(cat "$body"))"
echo "  ✓ 放行了"

echo ""
echo "✓ 中继门禁四项全通"
