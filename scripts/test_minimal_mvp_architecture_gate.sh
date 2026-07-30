#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GENERATED_SWIFT="$ROOT_DIR/macos/Zulangue/Zulangue/Bridge/Generated/vt_ffi.swift"
GENERATED_HEADER="$ROOT_DIR/macos/Zulangue/Zulangue/Bridge/Generated/vt_ffiFFI.h"
XCODE_PROJECT="$ROOT_DIR/macos/Zulangue/Zulangue.xcodeproj/project.pbxproj"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for removed_path in \
  crates/zulangued \
  crates/vt-sync \
  crates/vt-template \
  crates/vt-glossary \
  crates/vt-speaker \
  crates/vt-llm \
  crates/vt-ffi/src/recording_api.rs \
  crates/vt-ffi/src/event.rs \
  crates/vt-ffi/src/sync_api.rs \
  crates/vt-ffi/src/knowledge_api.rs \
  crates/vt-ffi/src/notebook_ask_api.rs \
  macos/Zulangue/Zulangue/App/RecordingCommandRouter.swift \
  macos/Zulangue/Zulangue/App/KnowledgeClient.swift \
  macos/Zulangue/Zulangue/Bridge/EventConfig+Compatibility.swift \
  macos/Zulangue/Zulangue/Library/TaskCallbackBridge.swift
do
  [[ ! -e "$ROOT_DIR/$removed_path" ]] \
    || fail "removed MVP subsystem path returned: $removed_path"
done

if grep -Eq '"crates/(zulangued|vt-sync|vt-template|vt-glossary|vt-speaker|vt-llm)"' \
    "$ROOT_DIR/Cargo.toml"; then
  fail "Cargo workspace must contain only the Notebook Capture MVP crates"
fi
if grep -Eq '^name = "(zulangued|vt-sync|vt-template|vt-glossary|vt-speaker|vt-llm)"$' \
    "$ROOT_DIR/Cargo.lock"; then
  fail "Cargo.lock retained a removed MVP package"
fi

for generated in "$GENERATED_SWIFT" "$GENERATED_HEADER"; do
  [[ -f "$generated" ]] || fail "generated UniFFI artifact is missing: $generated"
done
if grep -Eq 'FfiTaskCallback|testSttKey|KeyTestResult|enqueueSnapshotSave|notifyEditorChanged|RecordingCommandRouter|EventConfig|AgentEdit|NotebookAsk|KnowledgeClient' \
    "$GENERATED_SWIFT" "$GENERATED_HEADER"; then
  fail "generated UniFFI ABI retained a removed or Rust-internal surface"
fi

if grep -Eq 'RecordingCommandRouter\.swift|EventConfig\+Compatibility\.swift|TaskCallbackBridge\.swift|Security\.framework' \
    "$XCODE_PROJECT"; then
  fail "Xcode project retained a removed runtime or Keychain framework seam"
fi

echo "minimal MVP architecture boundary is clean"
