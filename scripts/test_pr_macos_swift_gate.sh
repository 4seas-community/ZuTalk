#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"
JUSTFILE="$ROOT_DIR/justfile"
PROJECT_FILE="$ROOT_DIR/macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"
HOSTED_PR_MAX_MACOS_DEPLOYMENT_TARGET="${HOSTED_PR_MAX_MACOS_DEPLOYMENT_TARGET:-15.5}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

recipe_body() {
  local recipe="$1"
  awk -v recipe="$recipe:" '
    index($0, recipe) == 1 { in_recipe = 1; print; next }
    in_recipe && $0 ~ "^[A-Za-z0-9_-]+:" { exit }
    in_recipe { print }
  ' "$JUSTFILE"
}

[[ -f "$WORKFLOW" ]] \
  || fail "GitHub macOS workflow must exist"

grep -Fq 'just swift-test' "$WORKFLOW" \
  || fail "GitHub macOS workflow must run Swift tests"
if grep -Eq '^[[:space:]]*pull_request_target:' "$WORKFLOW"; then
  fail "GitHub macOS workflow must not run untrusted pull requests with target privileges"
fi

local_gate_line="$(grep -E '^local-gate:' "$JUSTFILE" || true)"
grep -Fq "swift-test" <<<"$local_gate_line" \
  || fail "local-gate must run Swift tests"

swift_body="$(recipe_body swift-test)"
[[ -n "$swift_body" ]] || fail "justfile must define swift-test"
grep -Eq 'xcodebuild[[:space:]]+test' <<<"$swift_body" \
  || fail "swift-test must run xcodebuild test"
grep -Eq -- '-scheme[[:space:]]+ZulangueTests' <<<"$swift_body" \
  || fail "swift-test must run the ZulangueTests scheme"

awk -v max="$HOSTED_PR_MAX_MACOS_DEPLOYMENT_TARGET" '
  /MACOSX_DEPLOYMENT_TARGET =/ {
    target = $0
    sub(/.*MACOSX_DEPLOYMENT_TARGET = /, "", target)
    sub(/;.*/, "", target)
    split(target, parts, ".")
    split(max, max_parts, ".")
    major = parts[1] + 0
    minor = (parts[2] == "" ? 0 : parts[2] + 0)
    max_major = max_parts[1] + 0
    max_minor = (max_parts[2] == "" ? 0 : max_parts[2] + 0)
    if (major > max_major || (major == max_major && minor > max_minor)) {
      printf("deployment target %s exceeds local Swift gate max %s at %s:%d\n", target, max, FILENAME, FNR) > "/dev/stderr"
      bad = 1
    }
  }
  END { exit bad }
' "$PROJECT_FILE" \
  || fail "macOS deployment target must stay runnable by the local Swift gate"

echo "local macOS Swift gate is present and deployment-compatible"
