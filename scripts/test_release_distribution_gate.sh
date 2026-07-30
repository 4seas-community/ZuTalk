#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"
JUSTFILE="$ROOT_DIR/justfile"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

recipe_body() {
  local recipe="$1"
  awk -v recipe="$recipe" '
    $0 ~ "^" recipe ":" { in_recipe = 1; next }
    in_recipe && $0 ~ "^[A-Za-z0-9_-]+:" { exit }
    in_recipe { print }
  ' "$JUSTFILE"
}

[[ -f "$WORKFLOW" ]] \
  || fail "GitHub macOS workflow must exist"

grep -Fq 'just release-adhoc' "$WORKFLOW" \
  || fail "GitHub macOS workflow must build the Ad Hoc release"

if grep -Eq 'secrets\.|DEVELOPER_ID|zulangue-notary' "$WORKFLOW"; then
  fail "Ad Hoc GitHub release must not require private signing or notarization secrets"
fi

grep -Eq '^release-full:.*assert-public-app-privacy.*sign-release.*notarize-release' "$JUSTFILE" \
  || fail "release-full must use fail-closed release signing and notarization recipes"

sign_release_body="$(recipe_body sign-release)"
[[ -n "$sign_release_body" ]] || fail "justfile must define sign-release"

grep -Eq 'DEVELOPER_ID:\?' <<<"$sign_release_body" \
  || fail "sign-release must fail when DEVELOPER_ID is missing"

if grep -Eq -- '--sign[[:space:]]+-|ad-hoc|adhoc' <<<"$sign_release_body"; then
  fail "sign-release must not fall back to ad-hoc signing"
fi

grep -Eq -- '--timestamp' <<<"$sign_release_body" \
  || fail "sign-release must timestamp the Developer ID signature"

notarize_release_body="$(recipe_body notarize-release)"
[[ -n "$notarize_release_body" ]] || fail "justfile must define notarize-release"

grep -Eq 'security[[:space:]]+find-generic-password.*zulangue-notary' <<<"$notarize_release_body" \
  || fail "notarize-release must require the zulangue-notary keychain profile"

grep -Eq 'exit[[:space:]]+1' <<<"$notarize_release_body" \
  || fail "notarize-release must fail when the notary profile is missing"

echo "local release distribution gate is fail-closed"
