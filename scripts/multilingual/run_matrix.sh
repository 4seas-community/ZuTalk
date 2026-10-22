#!/usr/bin/env bash
# Runs the multilingual corpora through real Soniox, one configuration after
# another, and scores each run.
#
#   ZUTALK_INVITE_TOKEN=<community-invite.json> \
#     bash scripts/multilingual/run_matrix.sh <suite-dir> <out-dir>
#
# <suite-dir> is make_suite.py's output. Needs a debug build of the app
# (`just dev`) and an invitation the replay test can sign in with. Each
# configuration records the callbacks, a lane trace and a review; the scores
# go to <out-dir>/summary.txt. Configurations are "name languages corpus
# seconds"; override with ZUTALK_MATRIX="A th,zh,en core 292;B ...".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SUITE="$(cd "$1" && pwd -P)"
OUT="$2"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
: "${ZUTALK_INVITE_TOKEN:?point ZUTALK_INVITE_TOKEN at the community invitation file}"
IFS=';' read -ra CONFIGS <<< "${ZUTALK_MATRIX:-A th,zh,en core 292;B en,th,zh core 292;C zh,en,th core 292;D th,zh pair-thzh 288;E th,en pair-then 266;F zh,en pair-zhen 162}"
CONFIG_FILE="$(getconf DARWIN_USER_TEMP_DIR)zutalk-live-replay.json"
for entry in "${CONFIGS[@]}"; do
  read -r name langs media seconds <<< "$entry"
  python3 - "$CONFIG_FILE" "$SUITE" "$OUT" "$name" "$langs" "$media" "$seconds" "$ZUTALK_INVITE_TOKEN" <<'PY'
import json, sys
path, suite, out, name, langs, media, seconds, invite = sys.argv[1:9]
json.dump({
    "media": f"{suite}/{media}.wav", "invite_token": invite, "languages": langs.split(","),
    "out": f"{out}/{name}.txt", "record": f"{out}/{name}.jsonl", "seconds": int(seconds),
    "columns": True, "subtitles": True,
}, open(path, "w"))
PY
  rm -f "$OUT/$name.trace.jsonl"
  TEST_RUNNER_ZUTALK_LANE_TRACE="$OUT/$name.trace.jsonl" \
  TEST_RUNNER_CFFIXED_USER_HOME="$OUT/home" \
  xcodebuild test \
    -project "$ROOT/macos/ZuTalk/ZuTalk.xcodeproj" -scheme ZuTalkTests \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$ROOT/build/xcode-cache/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/build/xcode-cache/SourcePackages" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -only-testing:ZuTalkTests/LiveCaptureReplayTests > "$OUT/$name.log" 2>&1 || true
  {
    echo "##### $name languages=$langs corpus=$media"
    tail -2 "$OUT/$name.txt" 2>/dev/null || echo "no report: see $OUT/$name.log"
    python3 "$ROOT/scripts/multilingual/suite_eval.py" "$OUT/$name.jsonl" "$SUITE/$media.json" "$OUT/$name.review.txt"
    python3 "$ROOT/scripts/multilingual/trace_offset.py" "$OUT/$name.trace.jsonl" | grep -E "^->|canonical" || true
  } >> "$OUT/summary.txt" 2>&1
  echo "$name done"
done
rm -f "$CONFIG_FILE"
