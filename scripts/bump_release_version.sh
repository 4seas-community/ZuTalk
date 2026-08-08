#!/usr/bin/env bash
# 一次改对三处版本号,并把上一版的发布说明归档进 CHANGELOG。
#
# 版本号散在 Cargo.toml、Xcode 的两处 MARKETING_VERSION 和
# CURRENT_PROJECT_VERSION 里。check_release_version.sh 能发现它们不一致,
# 但发现不一致是在你已经改错之后 —— 这里负责一次改对。
#
# 构建号只增不复用:Sparkle 拿它判断新旧,复用一个构建号会让已经装了
# 那一版的人永远收不到更新。
#
# 用法:bash scripts/bump_release_version.sh 0.3.3
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

PROJECT_FILE="macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"
CARGO_FILE="Cargo.toml"
NOTES="packaging/release-notes.md"
CHANGELOG="CHANGELOG.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

NEW_VERSION="${1:-}"
[[ -n "$NEW_VERSION" ]] || fail "usage: bump_release_version.sh <x.y.z>"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "version must look like x.y.z"

OLD_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$CARGO_FILE" | head -1)"
[[ -n "$OLD_VERSION" ]] || fail "cannot read the current version out of $CARGO_FILE"
[[ "$OLD_VERSION" != "$NEW_VERSION" ]] || fail "$NEW_VERSION is already the current version"

# 只往前走。回退版本号会让装了新版的人被 Sparkle 判成"已是最新"。
LOWEST="$(printf '%s\n%s\n' "$OLD_VERSION" "$NEW_VERSION" | sort -V | head -1)"
[[ "$LOWEST" == "$OLD_VERSION" ]] \
  || fail "$NEW_VERSION is older than the current $OLD_VERSION"

OLD_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PROJECT_FILE" | sort -u)"
[[ "$(printf '%s\n' "$OLD_BUILD" | grep -c .)" -eq 1 ]] \
  || fail "Xcode must have exactly one CURRENT_PROJECT_VERSION"
NEW_BUILD=$((OLD_BUILD + 1))

# 上一版的发布说明进 CHANGELOG,再腾出位置给这一版。以前 release-notes.md
# 每次被整个覆盖,历史只活在 git log 和已发布的资产里。
if [[ -f "$NOTES" ]]; then
  if [[ -f "$CHANGELOG" ]] && grep -Fq "# Zulangue $OLD_VERSION" "$CHANGELOG"; then
    echo "· CHANGELOG 里已经有 $OLD_VERSION,不重复归档"
  else
    TMP="$(mktemp)"
    {
      echo "# Zulangue 更新历史"
      echo
      echo "每一版的发布说明按时间倒序排列。当前正在准备的那一版在"
      echo "\`packaging/release-notes.md\`,发布后由 \`just bump\` 归档到这里。"
      echo
      echo "条目按当时发布的原文归档,不做事后修饰 —— 所以偶尔会看到标题落后于"
      echo "它实际发布的标签(每条开头的 \`tag:\` 注释是准的)。"
      echo
      echo "---"
      echo
      echo "<!-- tag: v$OLD_VERSION -->"
      cat "$NOTES"
      if [[ -f "$CHANGELOG" ]]; then
        echo
        echo "---"
        echo
        # 去掉旧文件的抬头,只留历史条目。
        sed '1,/^---$/d' "$CHANGELOG" | sed '/./,$!d'
      fi
    } > "$TMP"
    mv "$TMP" "$CHANGELOG"
    echo "· 归档 $OLD_VERSION 的发布说明到 $CHANGELOG"
  fi
fi

sed -i '' "s/^version = \"$OLD_VERSION\"$/version = \"$NEW_VERSION\"/" "$CARGO_FILE"
sed -i '' \
  -e "s/MARKETING_VERSION = $OLD_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" \
  -e "s/CURRENT_PROJECT_VERSION = $OLD_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" \
  "$PROJECT_FILE"

cat > "$NOTES" <<EOF
# Zulangue $NEW_VERSION

<!-- 一句话说清这一版对用户意味着什么,然后逐条列出他们看得见的变化。
     这份文件会被嵌进 appcast,用户在更新提示里读到的就是它。 -->

Zulangue requires macOS 15.5 or later.
EOF

# Cargo.lock 跟着走,免得发布时才发现版本对不上。
cargo metadata --no-deps --format-version 1 > /dev/null

bash "$ROOT_DIR/scripts/check_release_version.sh"
echo "✓ $OLD_VERSION (build $OLD_BUILD) → $NEW_VERSION (build $NEW_BUILD)"
echo "  下一步:写 $NOTES,然后 just local-gate"
