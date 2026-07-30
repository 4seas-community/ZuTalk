#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/check_gatekeeper_status.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/Zulangue.app"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$APP" "$FAKE_BIN"

cat >"$FAKE_BIN/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

app="${@: -1}"
case "${SPCTL_MODE:-}" in
  accepted)
    echo "$app: accepted"
    exit 0
    ;;
  rejected)
    echo "$app: rejected"
    exit 3
    ;;
  *)
    echo "SPCTL_MODE must be accepted or rejected" >&2
    exit 99
    ;;
esac
SH
chmod +x "$FAKE_BIN/spctl"

run_check() {
  local mode="$1"
  local spctl_mode="$2"
  local output_file="$TMP_DIR/output.txt"
  set +e
  if [ -n "$mode" ]; then
    SPCTL_MODE="$spctl_mode" PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" "$mode" "$APP" >"$output_file" 2>&1
  else
    SPCTL_MODE="$spctl_mode" PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" "$APP" >"$output_file" 2>&1
  fi
  CHECK_STATUS=$?
  set -e
  CHECK_OUTPUT="$(cat "$output_file")"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "expected output to contain: $expected" >&2
    echo "--- output ---" >&2
    echo "$output" >&2
    echo "--------------" >&2
    exit 1
  fi
}

assert_status() {
  local expected="$1"
  if [ "$CHECK_STATUS" -ne "$expected" ]; then
    echo "expected exit $expected, got $CHECK_STATUS" >&2
    echo "--- output ---" >&2
    echo "$CHECK_OUTPUT" >&2
    echo "--------------" >&2
    exit 1
  fi
}

assert_nonzero_status() {
  if [ "$CHECK_STATUS" -eq 0 ]; then
    echo "expected non-zero exit, got 0" >&2
    echo "--- output ---" >&2
    echo "$CHECK_OUTPUT" >&2
    echo "--------------" >&2
    exit 1
  fi
}

run_check "" accepted
assert_status 0
assert_contains "$CHECK_OUTPUT" "Gatekeeper: accepted"

run_check "" rejected
assert_status 0
assert_contains "$CHECK_OUTPUT" "Gatekeeper rejects this target"
assert_contains "$CHECK_OUTPUT" "$APP: rejected"

run_check "--warn" rejected
assert_status 0
assert_contains "$CHECK_OUTPUT" "Gatekeeper rejects this target"
assert_contains "$CHECK_OUTPUT" "$APP: rejected"

run_check "--strict" accepted
assert_status 0
assert_contains "$CHECK_OUTPUT" "Gatekeeper: accepted"

run_check "--strict" rejected
assert_nonzero_status
assert_contains "$CHECK_OUTPUT" "Gatekeeper rejects this target"
assert_contains "$CHECK_OUTPUT" "$APP: rejected"

set +e
PATH="/usr/bin:/bin" bash "$SCRIPT" --strict "$APP" >"$TMP_DIR/no-spctl.txt" 2>&1
missing_spctl_status=$?
set -e
if [ "$missing_spctl_status" -eq 0 ]; then
  echo "strict mode must fail when spctl is unavailable" >&2
  cat "$TMP_DIR/no-spctl.txt" >&2
  exit 1
fi
assert_contains "$(cat "$TMP_DIR/no-spctl.txt")" "Gatekeeper check failed: spctl not found"

grep -Eq 'check_gatekeeper_status\.sh"?[[:space:]]+--warn' "$ROOT_DIR/justfile" \
  || { echo "install-local-app must call Gatekeeper check in warn mode" >&2; exit 1; }
grep -Eq '^assert-gatekeeper-accepted([[:space:]].*)?:' "$ROOT_DIR/justfile" \
  || { echo "justfile must define assert-gatekeeper-accepted" >&2; exit 1; }
grep -Eq '^assert-release-dmg-gatekeeper-accepted:' "$ROOT_DIR/justfile" \
  || { echo "justfile must define assert-release-dmg-gatekeeper-accepted" >&2; exit 1; }
grep -Eq '^release-full:.*notarize-release.*assert-release-dmg-gatekeeper-accepted' "$ROOT_DIR/justfile" \
  || { echo "release-full must strictly assess the notarized release DMG" >&2; exit 1; }
grep -Eq 'bash scripts/test_gatekeeper_status\.sh' "$ROOT_DIR/justfile" \
  || { echo "local gate must run the Gatekeeper status gate" >&2; exit 1; }
grep -Fq 'just release-adhoc' "$ROOT_DIR/.github/workflows/macos-build.yaml" \
  || { echo "GitHub macOS workflow must compile the Ad Hoc verification app" >&2; exit 1; }
if grep -Fq 'just release-full' "$ROOT_DIR/.github/workflows/macos-build.yaml"; then
  echo "GitHub macOS workflow must not require Developer ID for the current release path" >&2
  exit 1
fi

echo "gatekeeper status check tests passed"
