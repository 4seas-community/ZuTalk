#!/usr/bin/env bash
# 真实网络冒烟:邀请码 → 兑换 → endpoint 登记 → 自建中继放行。
#
# 双机清单验证不了「门禁在不在」——两台真机通常都已登记。这条冒烟在
# **已部署的** invite 服务上开一张一次性冒烟邀请码,登记一把新身份,
# 断言中继接纳它;再用一把从未登记的身份,断言中继拒绝它。两个断言
# 合起来才是门禁存在的证明:只测前者分不清「放行」与「不设防」。
#
# 需要:能 ssh 到部署机(create-invite 是服务器侧 CLI,码只显示一次、
# 库里只存哈希),以及到 invite/relay 服务的公网可达。手动运行,
# 不进 ci-check —— 它依赖外部服务与网络。
set -euo pipefail

INVITE_SSH="${ZULANGUE_INVITE_SSH:-zulangue-invite.exe.xyz}"
INVITE_URL="${ZULANGUE_INVITE_URL:-https://zulangue-invite.exe.xyz}"
RELAY_URL="${ZULANGUE_RELAY_URL:-https://zulangue-relay.exe.xyz}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() { printf '\n== %s ==\n' "$1"; }

step "构建探针"
cargo build -p vt-share --example relay_smoke --quiet
PROBE=target/debug/examples/relay_smoke

step "生成两把身份:一把将登记,一把保持陌生"
ENROLLED_ID=$("$PROBE" id "$WORK/enrolled.key")
STRANGER_ID=$("$PROBE" id "$WORK/stranger.key")
echo "将登记: $ENROLLED_ID"
echo "陌生人: $STRANGER_ID"

step "在部署机上开一张冒烟邀请码(1 Give,标签可审计)"
CODE=$(ssh "$INVITE_SSH" \
    "cd ~/zulangue-community-invite && python3 server.py --db data/invites.db \
     create-invite --label 'share-relay-smoke-$STAMP' --gives 1" | tr -d '[:space:]')
test -n "$CODE" || { echo "✗ 没拿到邀请码"; exit 1; }

step "兑换邀请码拿访问令牌(与 App 同一条路)"
TOKEN=$(curl -sS -X POST "$INVITE_URL/v1/redeem" \
    -H 'Content-Type: application/json' \
    -d "{\"code\": \"$CODE\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
test -n "$TOKEN" || { echo "✗ 兑换失败"; exit 1; }

step "登记第一把身份的 endpoint id"
ENROLL_BODY=$(curl -sS -X POST "$INVITE_URL/v1/share-endpoint" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"endpoint_id\": \"$ENROLLED_ID\"}")
echo "$ENROLL_BODY" | grep -q enrolled || { echo "✗ 登记失败: $ENROLL_BODY"; exit 1; }

step "已登记的身份应当被中继接纳(relay-auth 放行)"
"$PROBE" online "$WORK/enrolled.key" "$RELAY_URL" 30

step "从未登记的身份应当被拒之门外(10 秒内连不上即通过)"
if "$PROBE" online "$WORK/stranger.key" "$RELAY_URL" 10; then
    echo "✗ 陌生 endpoint 连上了中继 —— 门禁失效"
    exit 1
fi

printf '\n✓ 真实中继链路冒烟通过:登记的进,陌生的不进\n'
