#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"

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

[[ -f "$WORKFLOW" ]] \
  || fail "GitHub macOS workflow must exist"

grep -Fq 'runs-on: macos-15' "$WORKFLOW" \
  || fail "GitHub macOS workflow must use the pinned macOS 15 runner"
grep -Fq 'just release-adhoc' "$WORKFLOW" \
  || fail "GitHub macOS workflow must build the Ad Hoc Universal verification artifact"
grep -Fq 'build/dmg/Zulangue-*.dmg' "$WORKFLOW" \
  || fail "GitHub macOS workflow must upload the single Zulangue DMG"

grep -Eq '^xcode-build-universal:' "$JUSTFILE" \
  || fail "justfile must define a release-only universal Xcode build recipe"

universal_body="$(recipe_body xcode-build-universal)"
grep -Eq 'ONLY_ACTIVE_ARCH=NO' <<<"$universal_body" \
  || fail "xcode-build-universal must disable ONLY_ACTIVE_ARCH"
grep -Eq 'ARCHS="arm64 x86_64"|ARCHS=arm64[[:space:]]+x86_64' <<<"$universal_body" \
  || fail "xcode-build-universal must build both arm64 and x86_64"
grep -Eq 'generic/platform=macOS' <<<"$universal_body" \
  || fail "xcode-build-universal must use a generic macOS destination"
grep -Eq 'CODE_SIGN_STYLE=Manual' <<<"$universal_body" \
  || fail "xcode-build-universal must use manual signing"
grep -Eq 'CODE_SIGN_IDENTITY="-"' <<<"$universal_body" \
  || fail "xcode-build-universal must use Ad Hoc signing"
grep -Eq 'DEVELOPMENT_TEAM=""' <<<"$universal_body" \
  || fail "xcode-build-universal must not require a private Apple team"

grep -Eq '^macos_deployment_target[[:space:]]*:=[[:space:]]*"15\.5"' "$JUSTFILE" \
  || fail "Rust and Xcode release builds must share the macOS 15.5 deployment target"
for recipe in _rust-build-release-arm64 _rust-build-release-x86_64; do
  recipe_text="$(recipe_body "$recipe")"
  grep -Fq 'MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }}' <<<"$recipe_text" \
    || fail "$recipe must pin the Rust deployment target"
  grep -Fq -- '--remap-path-prefix={{ project_dir }}=.' <<<"$recipe_text" \
    || fail "$recipe must remove the local project path from release binaries"
  grep -Fq -- '--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo' <<<"$recipe_text" \
    || fail "$recipe must remove the local Cargo path from release binaries"
done

grep -Eq '^assert-universal-app:' "$JUSTFILE" \
  || fail "justfile must define assert-universal-app"

assert_body="$(recipe_body assert-universal-app)"
grep -Eq 'lipo[[:space:]]+-archs.*Contents/MacOS/Zulangue|lipo[[:space:]]+-archs[[:space:]]+"\$BIN"' <<<"$assert_body" \
  || fail "assert-universal-app must inspect the app executable with lipo -archs"
grep -Eq 'lipo[[:space:]]+"\$BIN"[[:space:]]+-verify_arch' <<<"$assert_body" \
  || fail "assert-universal-app must verify architectures with lipo <binary> -verify_arch"
grep -Eq 'arm64' <<<"$assert_body" \
  || fail "assert-universal-app must require arm64"
grep -Eq 'x86_64' <<<"$assert_body" \
  || fail "assert-universal-app must require x86_64"
grep -Eq 'exit[[:space:]]+1' <<<"$assert_body" \
  || fail "assert-universal-app must fail when an architecture is missing"

copy_release_body="$(recipe_body _copy-artifacts-release)"
grep -Fq 'target/{{ target_arm64 }}/release/build/fdk-aac-sys-' <<<"$copy_release_body" \
  || fail "release artifact copy must collect arm64 libfdk-aac.a"
grep -Fq 'target/{{ target_x86_64 }}/release/build/fdk-aac-sys-' <<<"$copy_release_body" \
  || fail "release artifact copy must collect x86_64 libfdk-aac.a"
grep -Eq 'lipo[[:space:]]+-create.*FDK_ARM64.*FDK_X86_64|lipo[[:space:]]+-create.*FDK_X86_64.*FDK_ARM64' <<<"$copy_release_body" \
  || fail "release artifact copy must lipo libfdk-aac.a into a universal archive"
grep -Eq 'libfdk-aac\.a[[:space:]]+-verify_arch[[:space:]]+arm64[[:space:]]+x86_64' <<<"$copy_release_body" \
  || fail "release artifact copy must verify universal libfdk-aac.a"

grep -Eq '^release-adhoc:.*release.*xcode-build-universal.*assert-universal-app.*assert-adhoc-app.*assert-sparkle-configured-app.*assert-public-app-privacy.*dmg' "$JUSTFILE" \
  || fail "release-adhoc must verify the Universal app, Ad Hoc signature, Sparkle, and privacy before packaging"
grep -Eq '^xcode-build-universal-signed:' "$JUSTFILE" \
  || fail "justfile must define a Developer ID universal archive recipe"
signed_universal_body="$(recipe_body xcode-build-universal-signed)"
grep -Eq 'ONLY_ACTIVE_ARCH=NO' <<<"$signed_universal_body" \
  || fail "signed release build must disable ONLY_ACTIVE_ARCH"
grep -Eq 'ARCHS="arm64 x86_64"' <<<"$signed_universal_body" \
  || fail "signed release build must include arm64 and x86_64"
grep -Eq 'generic/platform=macOS' <<<"$signed_universal_body" \
  || fail "signed release build must use a generic macOS destination"
grep -Fq 'CODE_SIGN_IDENTITY="$DEVELOPER_ID"' <<<"$signed_universal_body" \
  || fail "signed release build must use the injected Developer ID identity"

grep -Eq '^release-full:.*release.*xcode-build-universal-signed.*assert-universal-app.*assert-release-app-signature.*assert-sparkle-configured-app.*assert-public-app-privacy.*dmg.*sign-release-dmg.*notarize-release' "$JUSTFILE" \
  || fail "release-full must build, verify, sign, and notarize the universal app"

friendly_dmg_script="$ROOT_DIR/scripts/create_friendly_dmg.sh"
[[ -f "$friendly_dmg_script" ]] \
  || fail "friendly DMG packaging script must exist"
dmg_body="$(recipe_body dmg)"
grep -Fq 'scripts/create_friendly_dmg.sh' <<<"$dmg_body" \
  || fail "dmg recipe must use the friendly DMG packaging script"
grep -Fq 'ln -s /Applications' "$friendly_dmg_script" \
  || fail "friendly DMG must include an Applications shortcut"
grep -Fq 'packaging/dmg-background.png' "$friendly_dmg_script" \
  || fail "friendly DMG must include the branded background"
grep -Fq 'set position of item "Zulangue.app"' "$friendly_dmg_script" \
  || fail "friendly DMG must position the app icon"
grep -Fq 'set position of item "Applications"' "$friendly_dmg_script" \
  || fail "friendly DMG must position the Applications shortcut"
grep -Fq '[[ -f "$VERIFY_MOUNT_DIR/.DS_Store" ]]' "$friendly_dmg_script" \
  || fail "friendly DMG must verify Finder layout metadata"

if grep -Eq '^release-(adhoc|full):.*(^|[[:space:]])xcode-build([[:space:]]|$)' "$JUSTFILE"; then
  fail "release recipes must not use host-only xcode-build"
fi

grep -Eq 'bash scripts/test_release_universal_app_gate\.sh' "$JUSTFILE" \
  || fail "just ci-check must run the release universal app gate"

echo "local release universal app gate is enforced"
