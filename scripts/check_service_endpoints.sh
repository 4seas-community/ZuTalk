#!/usr/bin/env bash
# 发布前确认:客户端编译进去的三个服务地址,在外面真的存在。
#
# 这三个常量是编译进用户机器上二进制的,发出去就改不动了。它们指向不
# 存在的主机名时,构建、测试、门禁**全部照常通过** —— 失败只发生在用户
# 那边,而且是分享、网页字幕、邀请码兑换同时失效。改名期间这个窗口是
# 真实存在的:代码先指向新名,DNS 后补。
#
# 所以这里查的不是"字符串对不对",是"这个名字现在解析得到、TLS 握得上"。
# 用外部解析器:本机若有 VPN/代理的合成 DNS,任何名字都会解析成
# 198.18.x.x,看起来全都成功。
#
# 用法:bash scripts/check_service_endpoints.sh
# 跳过(离线构建等):SKIP_SERVICE_ENDPOINT_CHECK=1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ -n "${SKIP_SERVICE_ENDPOINT_CHECK:-}" ]]; then
  echo "· 跳过服务地址检查(SKIP_SERVICE_ENDPOINT_CHECK 已设)"
  exit 0
fi

RESOLVER="${SERVICE_ENDPOINT_RESOLVER:-1.1.1.1}"

# 从源码里取,不在这里重复写一遍主机名 —— 抄一份就会有一天对不上,
# 而对不上的那天正是这个门禁本该拦住的那天。
extract() {
  local file="$1" pattern="$2" url
  [[ -f "$file" ]] || fail "找不到 $file"
  url="$(sed -nE "s#.*${pattern}.*\"(https://[^\"]+)\".*#\1#p" "$file" | head -1)"
  [[ -n "$url" ]] || fail "在 $file 里没找到 ${pattern} 的地址"
  printf '%s\n' "$url" | sed -E 's#^https://##; s#/.*$##'
}

RELAY_HOST="$(extract crates/vt-ffi/src/share_api.rs 'DEFAULT_RELAY_URL')"
CAPTION_HOST="$(extract crates/vt-ffi/src/share_web.rs 'DEFAULT_WEB_CAPTION_SERVICE')"
INVITE_HOST="$(extract \
  macos/ZuTalk/ZuTalk/App/CommunityInviteSession.swift 'baseURL')"

STATUS=0
for HOST in "$RELAY_HOST" "$CAPTION_HOST" "$INVITE_HOST"; do
  ADDRESS="$(dig +short A "$HOST" "@${RESOLVER}" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  if [[ -z "$ADDRESS" ]]; then
    echo "  ✗ $HOST —— 解析不到(DNS 记录还没加?见 docs/service-rename.md §3.1)" >&2
    STATUS=1
    continue
  fi
  # 解析得到还不够:证书里没有这个名字的话,客户端一样连不上。
  if curl -sS -o /dev/null --max-time 10 "https://${HOST}/healthz" 2>/dev/null \
    || curl -sS -o /dev/null --max-time 10 "https://${HOST}/" 2>/dev/null; then
    echo "  ✓ $HOST ($ADDRESS)"
  else
    echo "  ✗ $HOST ($ADDRESS) —— 解析到了,但 HTTPS 连不上(证书还没覆盖这个名字?)" >&2
    STATUS=1
  fi
done

[[ $STATUS -eq 0 ]] \
  || fail "客户端指向的服务地址还不可用;现在发版,新装用户的分享/字幕/邀请码会全部失效"

echo "✓ 三个服务地址均可解析且可连接"
