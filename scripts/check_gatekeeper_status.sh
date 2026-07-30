#!/usr/bin/env bash
set -euo pipefail

MODE="warn"
ASSESS_TYPE="execute"
TARGET="/Applications/Zulangue.app"

usage() {
  echo "Usage: $0 [--warn|--report|--strict] [--type execute|open|install] [target]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --warn|--report)
      MODE="warn"
      shift
      ;;
    --strict)
      MODE="strict"
      shift
      ;;
    --type)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      ASSESS_TYPE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [ ! -e "$TARGET" ]; then
  echo "Gatekeeper check failed: $TARGET does not exist" >&2
  exit 2
fi

if ! command -v spctl >/dev/null 2>&1; then
  if [ "$MODE" = "strict" ]; then
    echo "Gatekeeper check failed: spctl not found" >&2
    exit 1
  fi
  echo "Gatekeeper check skipped: spctl not found"
  exit 0
fi

if SPCTL_OUTPUT="$(spctl --assess --type "$ASSESS_TYPE" "$TARGET" 2>&1)"; then
  echo "Gatekeeper: accepted"
else
  printf '%s\n' "$SPCTL_OUTPUT"
  echo ""
  echo "Gatekeeper rejects this target."
  echo "For app bundles, this can prevent TCC from listing Zulangue in Accessibility permissions."
  echo "Try:"
  echo "  sudo xattr -rc $TARGET"
  echo "  sudo spctl --add $TARGET"
  if [ "$MODE" = "strict" ]; then
    echo "Gatekeeper strict check failed."
    exit 1
  fi
fi
