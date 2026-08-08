#!/usr/bin/env bash
# 把本机签好的发布产物发到 GitHub Release,并逐条复核发出去的东西。
#
# 这一步之前是手打的 `gh release create`,附件名还带构建号
# (`Zulangue19-18.delta`)。漏传一个 delta 不会有任何提示:appcast 是
# 签过名的,用户侧签名验证照样通过,下载 404。所以这里的规矩是
# **以 appcast 为准** —— 它点名了哪些文件,就传哪些文件,传完再挨个
# 回头确认拿得到。
#
# 用法:
#   GITHUB_REPOSITORY=owner/repo GITHUB_REF_NAME=v0.3.3 \
#       bash scripts/release_publish.sh
#
# 前置:`just release-sparkle-adhoc` 已经跑过,build/update/ 里有签好名
# 的 appcast 与产物;签名标签已经推到主库。
#
# 目标 shell 是 macOS 自带的 bash 3.2 —— 不用 mapfile/readarray。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

UPDATE_DIR="$ROOT_DIR/build/update"
DMG_DIR="$ROOT_DIR/build/dmg"
APPCAST="$UPDATE_DIR/appcast.xml"
MIRROR_ATTEMPTS="${MIRROR_ATTEMPTS:-40}"
MIRROR_INTERVAL="${MIRROR_INTERVAL:-15}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() {
  echo
  echo "── $*"
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
[[ "$GITHUB_REF_NAME" == v* ]] || fail "GITHUB_REF_NAME must be a v-prefixed tag"
VERSION="${GITHUB_REF_NAME#v}"

command -v gh >/dev/null || fail "gh is required to publish a release"

# ── 1. 发布目的地与版本号 ────────────────────────────────────────────
step "目的地与版本号"
bash "$ROOT_DIR/scripts/check_release_destination.sh"
bash "$ROOT_DIR/scripts/check_release_version.sh"

# ── 2. 本机状态:干净的工作树、指向 HEAD 的签名标签 ──────────────────
step "本机标签"
[[ -z "$(git status --porcelain)" ]] \
  || fail "the working tree must be clean so the tag describes what was built"
git rev-parse -q --verify "refs/tags/$GITHUB_REF_NAME" >/dev/null \
  || fail "local tag $GITHUB_REF_NAME does not exist"
git tag -v "$GITHUB_REF_NAME" >/dev/null 2>&1 \
  || fail "tag $GITHUB_REF_NAME is not a verifiable signed tag"
LOCAL_COMMIT="$(git rev-list -n 1 "$GITHUB_REF_NAME")"
[[ "$LOCAL_COMMIT" == "$(git rev-parse HEAD)" ]] \
  || fail "tag $GITHUB_REF_NAME does not point at HEAD"
echo "✓ signed tag $GITHUB_REF_NAME → ${LOCAL_COMMIT:0:12}"

# ── 3. appcast 说要哪些文件,就凑齐哪些文件 ──────────────────────────
step "按 appcast 点名清点产物"
[[ -f "$APPCAST" ]] || fail "$APPCAST is missing; run 'just release-sparkle-adhoc' first"
grep -Fq "<!-- sparkle-signatures:" "$APPCAST" \
  || fail "appcast.xml is not signed"

EXPECTED_PREFIX="https://github.com/$GITHUB_REPOSITORY/releases/download/$GITHUB_REF_NAME/"
APPCAST_URL_LIST="$(
  sed -n 's/.*url="\([^"]*\)".*/\1/p' "$APPCAST" |
    grep -F "/releases/download/" | sort -u
)"
[[ -n "$APPCAST_URL_LIST" ]] || fail "appcast.xml names no downloadable file"

ASSETS=()
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  case "$url" in
    "$EXPECTED_PREFIX"*) ;;
    *) fail "appcast points outside this release: $url" ;;
  esac
  name="${url#"$EXPECTED_PREFIX"}"
  [[ -f "$UPDATE_DIR/$name" ]] \
    || fail "appcast names $name but build/update/$name does not exist"
  ASSETS+=("$UPDATE_DIR/$name")
  echo "· $name"
done <<<"$APPCAST_URL_LIST"

DMG="$DMG_DIR/Zulangue-$VERSION.dmg"
SHA_FILE="$DMG_DIR/Zulangue-macOS.sha256"
[[ -f "$DMG" ]] || fail "release DMG for $VERSION is missing"
[[ -f "$SHA_FILE" ]] || fail "Zulangue-macOS.sha256 is missing"
# 校验和文件名不带版本号,最容易发出上一版的那份。当场重算一次。
grep -Fq "Zulangue-$VERSION.dmg" "$SHA_FILE" \
  || fail "Zulangue-macOS.sha256 is not about Zulangue-$VERSION.dmg"
( cd "$DMG_DIR" && shasum -a 256 --check --status Zulangue-macOS.sha256 ) \
  || fail "Zulangue-macOS.sha256 does not describe the DMG being published"
ASSETS+=("$SHA_FILE" "$APPCAST")
echo "· Zulangue-macOS.sha256"
echo "· appcast.xml"

# ── 4. delta 的基线必须真的是已发布过的版本 ─────────────────────────
#
# 基线挑错了不会炸,只会让用户下完 delta 校验失败、再白下一遍全量。
# 悄悄浪费带宽正是最不容易被发现的那类问题。
step "核对 delta 基线"
# 同样按退出码判断:失败时 gh 会把错误正文打到 stdout,当成版本列表用
# 会让「基线发布过吗」这一问变成一句空话。
PUBLISHED=""
if ! PUBLISHED="$(
  gh release list --repo "$GITHUB_REPOSITORY" --limit 30 --json tagName \
    --jq '.[].tagName' 2>/dev/null
)"; then
  PUBLISHED=""
fi
BASE_COUNT=0
for base_dmg in "$UPDATE_DIR"/Zulangue-*.dmg; do
  [[ -f "$base_dmg" ]] || continue
  base_version="$(basename "$base_dmg" .dmg)"
  base_version="${base_version#Zulangue-}"
  [[ "$base_version" != "$VERSION" ]] || continue
  BASE_COUNT=$((BASE_COUNT + 1))
  if [[ -n "$PUBLISHED" ]]; then
    printf '%s\n' "$PUBLISHED" | grep -Fxq "v$base_version" \
      || fail "delta base $base_version was never published; the delta would be dead weight"
  fi
  echo "· 基线 $base_version 确实发布过"
done
if [[ "$BASE_COUNT" -eq 0 ]]; then
  echo "· 这一版没有基线,所有人走全量下载"
fi

# ── 5. 等镜像:GitHub 上必须已经有同一个提交的同名标签 ────────────────
#
# 主库在 Gitea,GitHub 是镜像。抢在同步之前发布的话,GitHub 会拿默认
# 分支 HEAD **自己造一个同名标签** —— 既不是那个签名标签,还可能指向
# 别的提交。所以宁可等。
step "等待镜像同步"
REMOTE_COMMIT=""
attempt=1
while [[ "$attempt" -le "$MIRROR_ATTEMPTS" ]]; do
  # 一次请求拿到 sha 与类型,并且**按退出码**判断有没有拿到 ——
  # `gh api --jq` 在 404 时会把错误 JSON 打到 stdout,拿"输出非空"
  # 当成功会让一个不存在的标签看起来存在。
  if REF="$(
    gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$GITHUB_REF_NAME" \
      --jq '.object.sha + " " + .object.type' 2>/dev/null
  )"; then
    REMOTE_SHA="${REF%% *}"
    REMOTE_TYPE="${REF##* }"
    if [[ "$REMOTE_TYPE" == "tag" ]]; then
      # 附注标签:再解一层才是提交。
      REMOTE_COMMIT="$(
        gh api "repos/$GITHUB_REPOSITORY/git/tags/$REMOTE_SHA" --jq '.object.sha'
      )" || fail "cannot dereference the mirrored tag object $REMOTE_SHA"
    else
      REMOTE_COMMIT="$REMOTE_SHA"
    fi
    break
  fi
  [[ "$attempt" -lt "$MIRROR_ATTEMPTS" ]] \
    || fail "tag $GITHUB_REF_NAME never reached $GITHUB_REPOSITORY; push it before publishing"
  echo "· 还没同步过来 ($attempt/$MIRROR_ATTEMPTS),等 ${MIRROR_INTERVAL}s"
  sleep "$MIRROR_INTERVAL"
  attempt=$((attempt + 1))
done
[[ "$REMOTE_COMMIT" == "$LOCAL_COMMIT" ]] \
  || fail "mirrored tag points at ${REMOTE_COMMIT:0:12}, not the signed ${LOCAL_COMMIT:0:12}"
echo "✓ mirrored tag matches the signed tag"

if gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  fail "release $GITHUB_REF_NAME already exists; delete it or cut a new version"
fi

# ── 6. 发布 ─────────────────────────────────────────────────────────
step "发布 $GITHUB_REF_NAME"
gh release create "$GITHUB_REF_NAME" \
  --repo "$GITHUB_REPOSITORY" \
  --title "Zulangue $VERSION" \
  --notes-file "$ROOT_DIR/packaging/release-notes.md" \
  --verify-tag \
  "${ASSETS[@]}"

# ── 7. 回头确认发出去的东西真的拿得到 ────────────────────────────────
step "复核"
UPLOADED="$(
  gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" \
    --json assets --jq '.assets[].name' | sort
)"
for asset in "${ASSETS[@]}"; do
  name="$(basename "$asset")"
  printf '%s\n' "$UPLOADED" | grep -Fxq "$name" \
    || fail "$name did not make it onto the release"
done
echo "✓ $(printf '%s\n' "$UPLOADED" | grep -c .) 个附件都在"

while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$url")"
  [[ "$code" == "200" ]] \
    || fail "appcast points at $url but it answers $code"
done <<<"$APPCAST_URL_LIST"
echo "✓ appcast 里点名的每个地址都拿得到"

LATEST="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
code="$(curl -sIL -o /dev/null -w '%{http_code}' "$LATEST")"
[[ "$code" == "200" ]] || fail "the stable appcast URL answers $code"
REMOTE_VERSION="$(
  curl -sL "$LATEST" | sed -n 's/.*<sparkle:shortVersionString>\([^<]*\).*/\1/p' | head -1
)"
[[ "$REMOTE_VERSION" == "$VERSION" ]] \
  || fail "the stable appcast still advertises $REMOTE_VERSION"
echo "✓ 稳定 appcast 地址已经指向 $VERSION"

echo
echo "✓ 发布完成: https://github.com/$GITHUB_REPOSITORY/releases/tag/$GITHUB_REF_NAME"
