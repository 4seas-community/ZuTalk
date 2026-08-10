#!/usr/bin/env bash
# 门禁的门禁:确认「新版本还被老版本找得到」这条判断真的挂在发布路径上,
# 并且真的会因为找不到而失败。
#
# 这条判断只在发布时才有输出,平时没人会去跑它——所以它最容易在一次改名
# 里被顺手摘掉,而摘掉之后一切照常绿,代价要等到用户点更新才显形。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"
RECORD="$ROOT_DIR/packaging/update-identity.json"
CHECK="$ROOT_DIR/scripts/check_update_identity.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

recipe_body() {
  local recipe="$1"
  awk -v recipe="$recipe" '
    $0 ~ "^" recipe ":" { in_recipe = 1; next }
    in_recipe && $0 ~ "^_?[A-Za-z0-9_-]+:" { exit }
    in_recipe { print }
  ' "$JUSTFILE"
}

[[ -x "$CHECK" ]] || fail "scripts/check_update_identity.sh must be executable"
[[ -f "$RECORD" ]] || fail "packaging/update-identity.json must exist"

# 记录必须是完整的三个名字:少一个,门禁就只能守住剩下的两条判据,而
# Sparkle 三条中任意一条命中都算数。
python3 - "$RECORD" <<'PY' || fail "packaging/update-identity.json must record bundle_file_name, display_name and bundle_id"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    record = json.load(handle)
for key in ("bundle_file_name", "display_name", "bundle_id"):
    value = record.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(1)
PY

for recipe in release-adhoc release-full; do
  line="$(grep -E "^$recipe:" "$JUSTFILE" || true)"
  [[ -n "$line" ]] || fail "justfile must define $recipe"
  grep -Fq "assert-sparkle-update-identity" <<<"$line" \
    || fail "$recipe must verify that installed copies can still find the app in this update"
done

assert_body="$(recipe_body assert-sparkle-update-identity)"
[[ -n "$assert_body" ]] || fail "justfile must define assert-sparkle-update-identity"
grep -Fq "scripts/check_update_identity.sh" <<<"$assert_body" \
  || fail "assert-sparkle-update-identity must run scripts/check_update_identity.sh"

# 行为测试:拿三个假 app bundle 走一遍 Sparkle 的三条判据。名字全取自记录
# 本身,所以这段不会随产品改名而失效。
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SHIPPED_FILE_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["bundle_file_name"])' "$RECORD")"
SHIPPED_BUNDLE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["bundle_id"])' "$RECORD")"

make_app() {
  local app="$WORK_DIR/$1"
  local bundle_id="$2"
  mkdir -p "$app/Contents"
  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
</dict>
</plist>
EOF
  printf '%s\n' "$app"
}

same_identity="$(make_app "$SHIPPED_FILE_NAME" "$SHIPPED_BUNDLE_ID")"
bash "$CHECK" "$same_identity" >/dev/null \
  || fail "the gate must accept an update that keeps the shipped identity"

# 只改文件名:Sparkle 还能靠 bundle ID 找到它,门禁也该放行。
renamed_file="$(make_app "Renamed.app" "$SHIPPED_BUNDLE_ID")"
bash "$CHECK" "$renamed_file" >/dev/null \
  || fail "the gate must accept a renamed bundle that keeps the shipped bundle id"

# 两个都改:Sparkle 三条判据全不中,已装副本从此更新不动。
orphaned="$(make_app "Renamed.app" "$SHIPPED_BUNDLE_ID.renamed")"
if bash "$CHECK" "$orphaned" >/dev/null 2>&1; then
  fail "the gate must reject an update that no installed copy can find"
fi

echo "update identity gate is wired into the release path and rejects orphaning renames"
