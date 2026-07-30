#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

recipe_body() {
  local recipe="$1"
  awk -v recipe="$recipe:" '
    $0 == recipe { in_recipe = 1; print; next }
    in_recipe && $0 ~ "^[A-Za-z0-9_-]+:" { exit }
    in_recipe { print }
  ' "$JUSTFILE"
}

contains_command() {
  local body="$1"
  local command="$2"
  awk -v expected="$command" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == expected) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' <<<"$body"
}

local_gate_line="$(grep -E '^local-gate:' "$JUSTFILE" || true)"
[[ -n "$local_gate_line" ]] || fail "justfile must define local-gate"
grep -Fq "local-gate-static" <<<"$local_gate_line" \
  || fail "local-gate must depend on local-gate-static"
grep -Fq "local-gate-rust-core" <<<"$local_gate_line" \
  || fail "local-gate must depend on local-gate-rust-core"
grep -Fq "local-gate-rust-macos" <<<"$local_gate_line" \
  || fail "local-gate must depend on local-gate-rust-macos"
grep -Fq "swift-test" <<<"$local_gate_line" \
  || fail "local-gate must run Swift tests"
grep -Fq "deploy-local" <<<"$local_gate_line" \
  || fail "local-gate must deploy locally"

static_body="$(recipe_body local-gate-static)"
[[ -n "$static_body" ]] || fail "justfile must define local-gate-static"
if contains_command "$static_body" "_fmt-workspace"; then
  fmt_body="$(recipe_body _fmt-workspace)"
  grep -Fq 'cargo fmt "${fmt_args[@]}" -- --check' <<<"$fmt_body" \
    || fail "_fmt-workspace must run cargo fmt for resolved workspace packages"
else
  contains_command "$static_body" "cargo fmt --all -- --check" \
    || fail "local-gate-static must run cargo fmt"
fi
for script in \
  scripts/test_local_gate_wiring.sh \
  scripts/test_gatekeeper_status.sh \
  scripts/test_swift_test_gate.sh \
  scripts/test_pr_macos_swift_gate.sh \
  scripts/test_macos_rust_test_gate.sh \
  scripts/test_release_distribution_gate.sh \
  scripts/test_release_universal_app_gate.sh \
  scripts/test_bundle_id_recovery_gate.sh \
  scripts/test_secret_material_storage_gate.sh \
  scripts/test_minimal_mvp_architecture_gate.sh \
  scripts/anti-demo.sh
do
  contains_command "$static_body" "bash $script" \
    || fail "local-gate-static must run $script"
done

rust_core_body="$(recipe_body local-gate-rust-core)"
[[ -n "$rust_core_body" ]] || fail "justfile must define local-gate-rust-core"
grep -Eq 'cargo[[:space:]]+nextest[[:space:]]+run[[:space:]]+--no-fail-fast' <<<"$rust_core_body" \
  || fail "local-gate-rust-core must run cargo nextest without fail-fast"
for crate in vt-model vt-crypto vt-stt vt-audio vt-export vt-store vt-i18n; do
  grep -Eq -- "-p[[:space:]]+$crate" <<<"$rust_core_body" \
    || fail "local-gate-rust-core must cover $crate"
done

rust_macos_body="$(recipe_body local-gate-rust-macos)"
[[ -n "$rust_macos_body" ]] || fail "justfile must define local-gate-rust-macos"
grep -Eq 'cargo[[:space:]]+nextest[[:space:]]+run[[:space:]]+--no-fail-fast' <<<"$rust_macos_body" \
  || fail "local-gate-rust-macos must run cargo nextest without fail-fast"
grep -Eq -- '-p[[:space:]]+vt-pipeline' <<<"$rust_macos_body" \
  || fail "local-gate-rust-macos must cover vt-pipeline"
grep -Eq -- '-p[[:space:]]+vt-ffi' <<<"$rust_macos_body" \
  || fail "local-gate-rust-macos must cover vt-ffi"

echo "local gate wiring is documented and enforced"
