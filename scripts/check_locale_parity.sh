#!/usr/bin/env bash
# 本地化平价门禁：所有语言必须携带同一套 key。
#
# 为什么需要：Xcode 的 developmentRegion = en，某个语言缺 key 时不会报错，
# 只会静默回退成英文。知识库功能就这样在 de/es/fr/ja/ko/th 六种语言下
# 整块显示英文（含侧栏条目），直到有人逐文件比对才发现。
#
# 检查项：
#   1. 每个 .lproj 的 key 集合与 en.lproj 完全一致
#   2. 同一 key 的格式说明符（%@ / %lld / …）在各语言间数量一致
#   3. 单个 .strings 文件内没有重复 key（后者会静默覆盖前者）
#   4. 每个 vt-i18n locale yml 的 key 集合与 en.yml 完全一致
#   5. 每个 .lproj 都有对应的 vt-i18n yml（韩语曾经只有前者）
#
# 用法:
#   bash scripts/check_locale_parity.sh
#   just local-gate-static

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

RES="macos/Zulangue/Zulangue/Resources"
I18N="crates/vt-i18n/locales"
BASE="en"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0

pass() { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() {
  printf "${RED}✗${NC} %s\n" "$1" >&2
  FAILED=$((FAILED + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- .strings ----------

strings_file() { echo "$RES/$1.lproj/Localizable.strings"; }

# 只认行首的 "key" = "value"; 形式，与 String(localized:) 的查表口径一致。
strings_keys() { grep -oE '^"[^"]+"' "$1" | tr -d '"'; }

# key<TAB>排序后的格式说明符序列
strings_specs() {
  awk '
    /^"[^"]+"[[:space:]]*=/ {
      match($0, /^"[^"]+"/)
      key = substr($0, 2, RLENGTH - 2)
      rest = substr($0, RLENGTH + 1)
      n = 0
      while (match(rest, /%([0-9]+\$)?(lld|ld|lu|@|d|f|s|u)/)) {
        specs[++n] = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
      for (i = 1; i < n; i++)
        for (j = i + 1; j <= n; j++)
          if (specs[i] > specs[j]) { t = specs[i]; specs[i] = specs[j]; specs[j] = t }
      line = ""
      for (i = 1; i <= n; i++) line = line specs[i] " "
      print key "\t" line
      delete specs
    }
  ' "$1"
}

langs=()
for dir in "$RES"/*.lproj; do
  langs+=("$(basename "$dir" .lproj)")
done

base_strings="$(strings_file "$BASE")"
[ -f "$base_strings" ] || {
  fail "缺少基准文件 $base_strings"
  exit 1
}

# 集合比较一律去重：重复 key 由下面的独立检查负责报告，
# 否则 comm 会把重复项误报成「en 没有的 key」。
strings_keys "$base_strings" | sort -u >"$WORK/base.keys"
strings_specs "$base_strings" | sort >"$WORK/base.specs"

for lang in "${langs[@]}"; do
  file="$(strings_file "$lang")"

  # 3. 文件内重复 key
  dupes="$(strings_keys "$file" | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    fail "$lang.lproj 有重复 key（后者会静默覆盖前者）：$(echo "$dupes" | tr '\n' ' ')"
  fi

  [ "$lang" = "$BASE" ] && continue

  # 1. key 集合
  strings_keys "$file" | sort -u >"$WORK/$lang.keys"
  missing="$(comm -23 "$WORK/base.keys" "$WORK/$lang.keys")"
  extra="$(comm -13 "$WORK/base.keys" "$WORK/$lang.keys")"
  if [ -n "$missing" ]; then
    count="$(echo "$missing" | wc -l | tr -d ' ')"
    fail "$lang.lproj 缺 $count 个 key，会静默回退成英文：$(echo "$missing" | head -5 | tr '\n' ' ')$([ "$count" -gt 5 ] && echo '…')"
  fi
  if [ -n "$extra" ]; then
    count="$(echo "$extra" | wc -l | tr -d ' ')"
    fail "$lang.lproj 多 $count 个 en 没有的 key：$(echo "$extra" | head -5 | tr '\n' ' ')$([ "$count" -gt 5 ] && echo '…')"
  fi

  # 2. 格式说明符
  strings_specs "$file" | sort >"$WORK/$lang.specs"
  mismatch="$(join -t "$(printf '\t')" "$WORK/base.specs" "$WORK/$lang.specs" \
    | awk -F'\t' '$2 != $3 { print $1 }')"
  if [ -n "$mismatch" ]; then
    fail "$lang.lproj 格式说明符与 en 不符（String(format:) 会读到错误参数）：$(echo "$mismatch" | head -5 | tr '\n' ' ')"
  fi
done

if [ "$FAILED" -eq 0 ]; then
  pass "[strings] ${#langs[@]} 个 .lproj key 集合、格式说明符一致，无重复 key（$(wc -l <"$WORK/base.keys" | tr -d ' ') 个 key）"
fi

# ---------- vt-i18n ----------

yml_keys() {
  awk '
    /^[a-z_]+:[[:space:]]*$/            { l1 = $0; sub(/:.*/, "", l1); next }
    /^  [a-z_]+:[[:space:]]*$/          { l2 = $0; sub(/^  /, "", l2); sub(/:.*/, "", l2); next }
    /^    [a-z_]+:/                     { k = $0; sub(/^    /, "", k); sub(/:.*/, "", k);
                                          print l1 "." l2 "." k }
  ' "$1"
}

i18n_failed_before=$FAILED
yml_keys "$I18N/$BASE.yml" | sort >"$WORK/base.yml.keys"

for file in "$I18N"/*.yml; do
  lang="$(basename "$file" .yml)"
  [ "$lang" = "$BASE" ] && continue
  yml_keys "$file" | sort >"$WORK/$lang.yml.keys"
  if ! diff -q "$WORK/base.yml.keys" "$WORK/$lang.yml.keys" >/dev/null; then
    fail "vt-i18n $lang.yml 与 en.yml 的 key 集合不一致：$(diff "$WORK/base.yml.keys" "$WORK/$lang.yml.keys" | grep -E '^[<>]' | head -5 | tr '\n' ' ')"
  fi
done

# 5. .lproj 与 vt-i18n 覆盖同一批语言
for lang in "${langs[@]}"; do
  if [ ! -f "$I18N/$lang.yml" ]; then
    fail "$lang.lproj 存在但 vt-i18n 缺 $lang.yml —— 该语言的 Rust 错误消息会是英文"
  fi
done

if [ "$FAILED" -eq "$i18n_failed_before" ]; then
  pass "[vt-i18n] $(ls "$I18N"/*.yml | wc -l | tr -d ' ') 个 locale key 集合一致，且覆盖全部 .lproj 语言"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  printf "${RED}✗ 本地化平价检查失败：%s 项${NC}\n" "$FAILED" >&2
  exit 1
fi
printf "${GREEN}✓ 本地化平价检查通过${NC}\n"
