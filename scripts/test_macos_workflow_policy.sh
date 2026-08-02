#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/macos-build.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_literal() {
  local expected="$1"
  grep -Fq -- "$expected" "$WORKFLOW" \
    || fail "macOS workflow is missing policy: $expected"
}

[[ -f "$WORKFLOW" ]] || fail "GitHub macOS workflow must exist"

require_literal "  actions: read"
require_literal "  contents: read"
require_literal "if: github.event_name != 'push' || !startsWith(github.ref, 'refs/tags/v')"
require_literal "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"
require_literal "SCCACHE_GHA_RW_MODE: \${{ github.ref == 'refs/heads/main' && 'READ_WRITE' || 'READ_ONLY' }}"
require_literal "SCCACHE_GHA_RW_MODE: READ_ONLY"
require_literal 'repos/${GITHUB_REPOSITORY}/actions/workflows/macos-build.yaml/runs'
require_literal "-f branch=main"
require_literal "-f event=push"
require_literal '-f head_sha="$GITHUB_SHA"'
require_literal 'for attempt in $(seq 1 60); do'
require_literal 'sleep 15'
require_literal "run: just version-check"
require_literal "just release-adhoc"
require_literal "bash scripts/check_release_version.sh build/app/Zulangue.app"
require_literal "just local-gate-rust-core"
require_literal "just local-gate-rust-macos"
require_literal "just swift-test"
require_literal "persist-credentials: false"

[[ "$(grep -Fc 'mozilla-actions/sccache-action@fc920bf0ec8de6ee65d409111f7ec508035751ba' "$WORKFLOW")" -eq 2 ]] \
  || fail "both macOS jobs must use the pinned sccache action"
if grep -Fq 'actions/cache@' "$WORKFLOW"; then
  fail "macOS workflow must not cache the full Cargo target or DerivedData"
fi
if grep -Eq '^[[:space:]]*pull_request_target:' "$WORKFLOW"; then
  fail "macOS workflow must not grant target-context privileges to pull requests"
fi

echo "macOS workflow verification and release policies are enforced"
