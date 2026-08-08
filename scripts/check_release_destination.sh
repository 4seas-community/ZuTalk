#!/usr/bin/env bash
# 发布目的地一致性:GITHUB_REPOSITORY 必须就是本仓库的 github remote。
#
# 这两个值一旦分岔,后果是隐形的:下载地址会被**签进** appcast,签名
# 依然有效,地址却指向另一个仓库 —— 从产物上看不出来,只有用户点了
# 更新才会发现。GITHUB_REF_NAME 由 check_release_version.sh 与 Cargo
# 版本对齐,这里补上另一半。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

REMOTE_URL="$(git remote get-url github 2>/dev/null || true)"
[[ -n "$REMOTE_URL" ]] \
  || fail "this repository has no 'github' remote to publish against"

# HTTPS 与 SSH 两种写法都归一成 owner/repo。
REMOTE_SLUG="$(
  printf '%s\n' "$REMOTE_URL" |
    sed -E 's#^git@github\.com:#https://github.com/#' |
    sed -E 's#^https://github\.com/##; s#\.git$##; s#/$##'
)"

[[ "$REMOTE_SLUG" == "$GITHUB_REPOSITORY" ]] \
  || fail "GITHUB_REPOSITORY is $GITHUB_REPOSITORY but the github remote is $REMOTE_SLUG"

echo "✓ Release destination $GITHUB_REPOSITORY matches the github remote"
