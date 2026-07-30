#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
JUSTFILE="$ROOT_DIR/justfile"

recipe_body() {
  local recipe="$1"
  awk -v recipe="$recipe" '
    $0 ~ "^" recipe ":" { in_recipe = 1; next }
    in_recipe && $0 ~ "^[A-Za-z0-9_-]+:" { exit }
    in_recipe { print }
  ' "$JUSTFILE"
}

assert_pipeline_is_strict() {
  local recipe="$1"
  local body
  local compact
  local first_command
  body="$(recipe_body "$recipe")"
  compact="$(tr '\n' ' ' <<<"$body")"
  first_command="$(awk 'NF { sub(/^[[:space:]]+/, ""); print; exit }' <<<"$body")"

  if [[ "$first_command" != "#!/usr/bin/env bash" ]]; then
    echo "FAIL: $recipe must be a bash shebang recipe so pipefail applies to the xcodebuild pipeline" >&2
    exit 1
  fi

  if grep -Eq 'xcbeautify[[:space:]\\]*\|\|' <<<"$compact"; then
    echo "FAIL: $recipe masks xcodebuild failures after xcbeautify" >&2
    exit 1
  fi

  if ! grep -Eq 'set[[:space:]]+-euo[[:space:]]+pipefail' <<<"$body"; then
    echo "FAIL: $recipe must enable errexit and pipefail so xcodebuild failures are propagated through xcbeautify" >&2
    exit 1
  fi
}

assert_pipeline_is_strict swift-test
assert_pipeline_is_strict swift-coverage

echo "swift xcodebuild test gates propagate failures"
