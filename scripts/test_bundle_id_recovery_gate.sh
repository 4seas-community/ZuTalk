#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"
PROJECT="$ROOT_DIR/macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"

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

has_line_with_bundle_ref() {
  local body="$1"
  local prefix="$2"
  grep -Fq "$prefix {{ app_bundle_id }}" <<<"$body" \
    || grep -Fq "$prefix $APP_BUNDLE_ID" <<<"$body"
}

APP_BUNDLE_ID="$(awk '
  /PRODUCT_BUNDLE_IDENTIFIER = xyz\.voice\.zulangue;/ { print "xyz.voice.zulangue"; exit }
' "$PROJECT")"

[[ "$APP_BUNDLE_ID" == "xyz.voice.zulangue" ]] \
  || fail "Zulangue app bundle id must be discoverable from the Xcode project"

JUST_BUNDLE_ID="$(awk -F'"' '/^app_bundle_id[[:space:]]*:=/ { print $2; exit }' "$JUSTFILE")"
[[ "$JUST_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] \
  || fail "justfile app_bundle_id must match the Xcode app bundle id"

for recipe in approve; do
  body="$(recipe_body "$recipe")"
  [[ -n "$body" ]] || fail "justfile must define $recipe"
  has_line_with_bundle_ref "$body" "tccutil reset Accessibility" \
    || fail "$recipe must reset Accessibility for $APP_BUNDLE_ID"
  has_line_with_bundle_ref "$body" "tccutil reset Microphone" \
    || fail "$recipe must reset Microphone for $APP_BUNDLE_ID"
done

approve_body="$(recipe_body approve)"
has_line_with_bundle_ref "$approve_body" "defaults delete" \
  || fail "approve must clear onboarding defaults for $APP_BUNDLE_ID"
grep -Fq "zulangue.onboarding.completed" <<<"$approve_body" \
  || fail "approve must clear the onboarding completion key"

grep -Eq 'bash scripts/test_bundle_id_recovery_gate\.sh' "$JUSTFILE" \
  || fail "just ci-check must run the bundle id recovery gate"

echo "bundle id recovery gate uses the canonical app bundle id"
