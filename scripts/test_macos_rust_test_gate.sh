#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"
WORKFLOW="$ROOT_DIR/.github/workflows/rust-test.yaml"
MACOS_RUST_GATE_CMD="bash scripts/test_macos_rust_test_gate.sh"

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

contains_exact_command() {
  local expected="$1"
  awk -v expected="$expected" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == expected) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

[[ ! -e "$WORKFLOW" ]] \
  || fail "GitHub Rust Test workflow must stay removed while local-gate is authoritative"

local_gate_line="$(grep -E '^local-gate:' "$JUSTFILE" || true)"
grep -Fq "local-gate-rust-macos" <<<"$local_gate_line" \
  || fail "local-gate must depend on local-gate-rust-macos"

macos_body="$(recipe_body local-gate-rust-macos)"
[[ -n "$macos_body" ]] || fail "justfile must define local-gate-rust-macos"
grep -Eq 'cargo[[:space:]]+nextest[[:space:]]+run[[:space:]]+--no-fail-fast' <<<"$macos_body" \
  || fail "local-gate-rust-macos must run cargo nextest without fail-fast"
grep -Eq -- '-p[[:space:]]+vt-pipeline' <<<"$macos_body" \
  || fail "local-gate-rust-macos must cover vt-pipeline"
grep -Eq -- '-p[[:space:]]+vt-ffi' <<<"$macos_body" \
  || fail "local-gate-rust-macos must cover vt-ffi"
if grep -Eq '(^|[[:space:]])(\|\||&&|;|&)([[:space:]]|$)|set[[:space:]]+\+e|set[[:space:]]+\+o[[:space:]]+errexit' <<<"$macos_body"; then
  fail "local-gate-rust-macos must fail closed"
fi

ci_check_body="$(recipe_body ci-check)"
[[ -n "$ci_check_body" ]] || fail "justfile must define ci-check"
if ! contains_exact_command "$MACOS_RUST_GATE_CMD" <<<"$ci_check_body"; then
  fail "just ci-check must run the macOS Rust test gate"
fi

echo "local macOS Rust test gate is enforced"
