#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"
JUSTFILE="$ROOT_DIR/justfile"
PROJECT_FILE="$ROOT_DIR/macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"
INFO_PLIST="$ROOT_DIR/macos/Zulangue/Zulangue-Info.plist"

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

[[ -f "$WORKFLOW" ]] || fail "GitHub macOS workflow must exist"

grep -Fq 'just release-adhoc' "$WORKFLOW" \
  || fail "tag CI must compile the Ad Hoc Universal verification artifact"
if grep -Fq 'just release-full' "$WORKFLOW"; then
  fail "tag CI must not require unavailable Developer ID credentials"
fi
if grep -Eq 'secrets\.(SPARKLE_PRIVATE_ED_KEY|DEVELOPER_ID|APPLE_NOTARY)' "$WORKFLOW"; then
  fail "GitHub Actions must not receive release signing private material"
fi
if grep -Fq 'just sparkle-appcast' "$WORKFLOW"; then
  fail "GitHub Actions must not sign appcasts"
fi
if grep -Fq 'gh release create' "$WORKFLOW"; then
  fail "GitHub Actions must not publish a release without the local signed appcast"
fi
if grep -Fq 'build/dmg/appcast.xml' "$WORKFLOW"; then
  fail "GitHub Actions must not upload locally signed appcasts"
fi

grep -Eq '^release-adhoc:.*release.*xcode-build-universal.*assert-universal-app.*assert-adhoc-app.*assert-sparkle-configured-app.*assert-public-app-privacy.*dmg' "$JUSTFILE" \
  || fail "release-adhoc must verify architecture, Ad Hoc signing, Sparkle, and privacy"
grep -Eq '^release-sparkle-adhoc:.*release-adhoc.*sparkle-appcast' "$JUSTFILE" \
  || fail "the local release path must add a signed Sparkle appcast"

appcast_body="$(recipe_body sparkle-appcast)"
grep -Fq -- '--account Zulangue' <<<"$appcast_body" \
  || fail "appcast signing must use the dedicated local Keychain account"
if grep -Fq 'SPARKLE_PRIVATE_ED_KEY' <<<"$appcast_body"; then
  fail "appcast signing must not accept an exported private key environment variable"
fi
grep -Fq 'ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9' <<<"$appcast_body" \
  || fail "the downloaded Sparkle tools archive must have a pinned checksum"
grep -Fq 'releases/download/${GITHUB_REF_NAME}/' <<<"$appcast_body" \
  || fail "appcast downloads must use immutable tagged release URLs"
grep -Fq 'sparkle:edSignature=' <<<"$appcast_body" \
  || fail "appcast generation must verify the update archive signature"
grep -Fq '<!-- sparkle-signatures:' <<<"$appcast_body" \
  || fail "appcast generation must verify the signed feed"

grep -Fq 'version = 2.9.4;' "$PROJECT_FILE" \
  || fail "the reviewed Sparkle version must be pinned exactly"
grep -Eq 'SPARKLE_PUBLIC_ED_KEY = "[A-Za-z0-9+/]{43}=";' "$PROJECT_FILE" \
  || fail "the application must embed a valid public update key"
grep -A1 -F '<key>SURequireSignedFeed</key>' "$INFO_PLIST" | grep -Fq '<true/>' \
  || fail "the app must require a signed update feed"
grep -A1 -F '<key>SUVerifyUpdateBeforeExtraction</key>' "$INFO_PLIST" | grep -Fq '<true/>' \
  || fail "the app must verify updates before extraction"
grep -Fq 'https://github.com/4seas-community/zulangue/releases/latest/download/appcast.xml' "$PROJECT_FILE" \
  || fail "the public HTTPS appcast URL must be configured"

echo "local-keychain Ad Hoc Sparkle release gate is fail-closed"
