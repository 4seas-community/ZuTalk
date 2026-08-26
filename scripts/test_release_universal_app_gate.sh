#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"
CARGO_CONFIG="$ROOT_DIR/.cargo/config.toml"
ARCHIVE_TARGET_GATE="$ROOT_DIR/scripts/check_macos_archive_deployment_target.sh"

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
[[ -x "$ARCHIVE_TARGET_GATE" ]] \
  || fail "macOS archive deployment-target gate must exist and be executable"

grep -Fq 'runs-on: macos-15' "$WORKFLOW" \
  || fail "GitHub macOS workflow must use the pinned macOS 15 runner"
grep -Fq 'just release-adhoc' "$WORKFLOW" \
  || fail "GitHub macOS workflow must build the Ad Hoc Universal verification artifact"
grep -Fq 'build/dmg/ZuTalk-*.dmg' "$WORKFLOW" \
  || fail "GitHub macOS workflow must upload the single ZuTalk DMG"

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

grep -Eq '^macos_deployment_target[[:space:]]*:=[[:space:]]*"12\.5"' "$JUSTFILE" \
  || fail "Rust and Xcode release builds must share the macOS 12.5 deployment target"
grep -Eq '^MACOSX_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*"12\.5"' "$CARGO_CONFIG" \
  || fail "direct Cargo builds must default to the macOS 12.5 deployment target"
grep -Fq 'macos_rust_target_dir := project_dir / "target" / ("macos-" + macos_deployment_target)' "$JUSTFILE" \
  || fail "macOS Rust artifacts must be isolated by deployment target"
for artifact_var in host_debug_ffi release_arm64_ffi release_x86_64_ffi release_universal_ffi; do
  grep -Eq "^${artifact_var}[[:space:]]*:=[[:space:]]*macos_rust_target_dir[[:space:]]*/" "$JUSTFILE" \
    || fail "$artifact_var must live under the deployment-target-specific Cargo directory"
done
for recipe in _rust-build-debug _rust-build-release-arm64 _rust-build-release-x86_64; do
  recipe_text="$(recipe_body "$recipe")"
  grep -Fq 'CARGO_TARGET_DIR="{{ macos_rust_target_dir }}"' <<<"$recipe_text" \
    || fail "$recipe must use the deployment-target-specific Cargo directory"
  grep -Fq 'MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }}' <<<"$recipe_text" \
    || fail "$recipe must pin the Rust deployment target"
done

lipo_body="$(recipe_body _lipo)"
for artifact_var in release_arm64_ffi release_x86_64_ffi release_universal_ffi; do
  grep -Fq "{{ ${artifact_var} }}" <<<"$lipo_body" \
    || fail "_lipo must use $artifact_var"
done
grep -Fq 'scripts/check_macos_archive_deployment_target.sh' <<<"$lipo_body" \
  || fail "_lipo must verify release archive deployment targets"
for artifact_var in release_arm64_ffi release_x86_64_ffi; do
  grep -Fq "{{ ${artifact_var} }}\" \"{{ macos_deployment_target }}" <<<"$lipo_body" \
    || fail "_lipo must reject $artifact_var members built for a newer macOS"
done
for recipe in _rust-build-release-arm64 _rust-build-release-x86_64; do
  recipe_text="$(recipe_body "$recipe")"
  grep -Fq -- '--remap-path-prefix={{ project_dir }}=.' <<<"$recipe_text" \
    || fail "$recipe must remove the local project path from release binaries"
  grep -Fq -- '--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo' <<<"$recipe_text" \
    || fail "$recipe must remove the local Cargo path from release binaries"
done

grep -Eq '^assert-universal-app:' "$JUSTFILE" \
  || fail "justfile must define assert-universal-app"

assert_body="$(recipe_body assert-universal-app)"
grep -Eq 'lipo[[:space:]]+-archs.*Contents/MacOS/ZuTalk|lipo[[:space:]]+-archs[[:space:]]+"\$BIN"' <<<"$assert_body" \
  || fail "assert-universal-app must inspect the app executable with lipo -archs"
grep -Eq 'lipo[[:space:]]+"\$BIN"[[:space:]]+-verify_arch' <<<"$assert_body" \
  || fail "assert-universal-app must verify architectures with lipo <binary> -verify_arch"
grep -Eq 'arm64' <<<"$assert_body" \
  || fail "assert-universal-app must require arm64"
grep -Fq 'LSMinimumSystemVersion' <<<"$assert_body" \
  || fail "assert-universal-app must verify the bundle deployment target"
grep -Fq 'vtool -arch' <<<"$assert_body" \
  || fail "assert-universal-app must verify each Mach-O architecture deployment target"
grep -Fq 'libswiftSynchronization.dylib' <<<"$assert_body" \
  || fail "assert-universal-app must reject the macOS 15-only Synchronization runtime"
grep -Eq 'x86_64' <<<"$assert_body" \
  || fail "assert-universal-app must require x86_64"
grep -Eq 'exit[[:space:]]+1' <<<"$assert_body" \
  || fail "assert-universal-app must fail when an architecture is missing"

copy_debug_body="$(recipe_body _copy-artifacts)"
grep -Fq '{{ host_debug_ffi }}' <<<"$copy_debug_body" \
  || fail "debug artifact copy must stage the deployment-target-specific libvt_ffi.a"
grep -Fq 'scripts/check_macos_archive_deployment_target.sh' <<<"$copy_debug_body" \
  || fail "debug artifact copy must verify archive deployment targets"
copy_release_body="$(recipe_body _copy-artifacts-release)"
grep -Fq '{{ release_universal_ffi }}' <<<"$copy_release_body" \
  || fail "release artifact copy must stage the universal libvt_ffi.a"

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
grep -Fq 'set position of item "ZuTalk.app"' "$friendly_dmg_script" \
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
