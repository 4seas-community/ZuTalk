#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT_FILE="$ROOT_DIR/macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"
APP_PATH="${1:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CARGO_VERSION="$(
  cargo metadata --no-deps --format-version 1 |
    python3 -c 'import json,sys; packages=json.load(sys.stdin)["packages"]; print(next(p["version"] for p in packages if p["name"] == "vt-ffi"))'
)"

MARKETING_VERSIONS="$(
  sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJECT_FILE" |
    sort -u
)"
MARKETING_COUNT="$(printf '%s\n' "$MARKETING_VERSIONS" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$MARKETING_COUNT" -eq 1 ]] \
  || fail "Xcode must have exactly one MARKETING_VERSION"
[[ "$MARKETING_VERSIONS" == "$CARGO_VERSION" ]] \
  || fail "Cargo $CARGO_VERSION does not match Xcode $MARKETING_VERSIONS"

BUILD_VERSIONS="$(
  sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PROJECT_FILE" |
    sort -u
)"
BUILD_COUNT="$(printf '%s\n' "$BUILD_VERSIONS" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$BUILD_COUNT" -eq 1 ]] \
  || fail "Xcode must have exactly one CURRENT_PROJECT_VERSION"
[[ "$BUILD_VERSIONS" =~ ^[1-9][0-9]*$ ]] \
  || fail "CURRENT_PROJECT_VERSION must be a positive, monotonically increasing integer"

if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  TAG_VERSION="${GITHUB_REF_NAME#v}"
  [[ "$TAG_VERSION" == "$CARGO_VERSION" ]] \
    || fail "tag $GITHUB_REF_NAME does not match product version $CARGO_VERSION"
fi

if [[ -n "$APP_PATH" ]]; then
  PLIST="$APP_PATH/Contents/Info.plist"
  [[ -f "$PLIST" ]] || fail "built app Info.plist is missing"
  BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
  BUILT_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
  [[ "$BUILT_VERSION" == "$CARGO_VERSION" ]] \
    || fail "built app version $BUILT_VERSION does not match $CARGO_VERSION"
  [[ "$BUILT_NUMBER" == "$BUILD_VERSIONS" ]] \
    || fail "built app number $BUILT_NUMBER does not match $BUILD_VERSIONS"
fi

echo "✓ Release version $CARGO_VERSION (build $BUILD_VERSIONS) is consistent"
