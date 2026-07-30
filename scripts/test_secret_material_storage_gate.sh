#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CORE="$ROOT_DIR/crates/vt-ffi/src/lib.rs"
CRYPTO_LIB="$ROOT_DIR/crates/vt-crypto/src/lib.rs"
CRYPTO_MANIFEST="$ROOT_DIR/crates/vt-crypto/Cargo.toml"
FILE_KEY_STORE="$ROOT_DIR/crates/vt-crypto/src/file_key_store.rs"
PRIVATE_FILE_STORE="$ROOT_DIR/crates/vt-crypto/src/private_file_store.rs"
SWIFT_ROOT="$ROOT_DIR/macos/Zulangue/Zulangue"
PROVIDER_SESSION="$SWIFT_ROOT/App/ProviderCredentialSession.swift"
APP_ENTRY="$SWIFT_ROOT/ZulangueApp.swift"
CORE_CLIENT="$SWIFT_ROOT/App/CoreClient.swift"
TEST_ENVIRONMENT="$SWIFT_ROOT/App/TestEnvironment.swift"
SONIOX_RT="$ROOT_DIR/crates/vt-stt/src/soniox_rt.rs"
SONIOX_STREAM="$ROOT_DIR/crates/vt-stt/src/soniox_stream.rs"
TRANSCRIBE_API="$ROOT_DIR/crates/vt-ffi/src/transcribe_api.rs"
README="$ROOT_DIR/README.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -Eq '^[[:space:]]*keyring[[:space:]]*=' "$CRYPTO_MANIFEST"; then
  fail "vt-crypto must not depend on keyring or Keychain"
fi
if grep -R -Eq 'keyring::|KeyManager::new|new_keychain' \
    "$ROOT_DIR/crates/vt-crypto/src" "$CORE"; then
  fail "production secret material must not retain a Keychain runtime path"
fi
if grep -Fq 'KeyManager' "$CRYPTO_LIB"; then
  fail "vt-crypto must not export the removed Keychain manager"
fi

grep -Fq 'let secrets_dir = path.join("Secrets")' "$CORE" \
  || fail "ZulangueCore must isolate durable secret material in Secrets"
grep -Fq 'FileKeyStore::new(secrets_dir.join("content-keys.json"))' "$CORE" \
  || fail "ZulangueCore must persist content/audio keys in the private local store"

# Static tripwires catch accidental path removal; the Rust tests named below
# remain the behavioral authority for races, crash residue, and migration.
for marker in '0o700' '0o600' 'O_NOFOLLOW' 'create_new(true)' 'flock(' \
    'sync_all()' 'std::fs::rename' 'geteuid()' 'metadata.uid()'; do
  grep -Fq "$marker" "$PRIVATE_FILE_STORE" \
    || fail "private Rust secret stores must retain the $marker guard"
done
grep -Fq 'remove_safe_stale_temporary_files' "$PRIVATE_FILE_STORE" \
  || fail "private Rust secret stores must sweep safe store-owned crash temporaries"
grep -Fq 'is_temporary_name_for_store' "$PRIVATE_FILE_STORE" \
  || fail "crash-temporary cleanup must match the owning store filename contract"
grep -Fq 'is_safe_stale_temporary_metadata' "$PRIVATE_FILE_STORE" \
  || fail "crash-temporary cleanup must make a metadata-only safety decision"
grep -Fq 'commit_private_temp_file_with_sync' "$PRIVATE_FILE_STORE" \
  || fail "private Rust secret stores must define the rename commit boundary"
grep -Fq 'let _ = sync_parent(destination)' "$PRIVATE_FILE_STORE" \
  || fail "parent-directory sync must stay explicitly best effort after rename"
grep -Fq 'file_key_store_open_sweeps_only_safe_exact_stale_temps' "$FILE_KEY_STORE" \
  || fail "vt-crypto must retain the crash-temporary cleanup regression test"
grep -Fq 'rename_remains_committed_when_parent_sync_fails' "$PRIVATE_FILE_STORE" \
  || fail "vt-crypto must retain the rename commit-point regression test"
grep -Fq 'file.exclusive()' "$FILE_KEY_STORE" \
  || fail "content-key mutations must reload under an exclusive cross-process transaction"
grep -Fq 'CONTENT_KEY_STORE_VERSION' "$FILE_KEY_STORE" \
  || fail "content-key documents must carry an explicit schema version"
grep -Fq '#[serde(deny_unknown_fields)]' "$FILE_KEY_STORE" \
  || fail "content-key documents must reject unknown fields"

grep -Fq 'Arc::new(MemoryApiKeyStore::new())' "$CORE" \
  || fail "ZulangueCore production init must keep live provider keys in the Rust memory store"
if grep -Eq 'Arc::new\(KeychainApiKeyStore|api_key_store[^;]*KeychainApiKeyStore' "$CORE"; then
  fail "ZulangueCore production init must not wire provider API keys to Keychain"
fi

[[ -f "$PROVIDER_SESSION" ]] \
  || fail "Swift must expose the persisted ProviderCredentialSession boundary"

grep -Fq 'trimmingCharacters(in: .whitespacesAndNewlines)' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must normalize an explicitly applied key"
grep -Fq 'runtime.setApiKey' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must apply provider keys directly to Rust"
grep -Fq 'runtime.hasApiKey' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession state must come from the Rust runtime"
grep -Fq 'runtime.clearApiKey' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must clear the Rust runtime scope"

if grep -R -Eq --include='*.swift' 'KeychainStore\.|ApiKeyBridge\.' "$SWIFT_ROOT"; then
  fail "active Swift product code must not mirror provider API keys through Keychain"
fi

grep -Fq 'provider-credentials.json' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must use the single app-private credential filename"
grep -Fq '"Secrets"' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must isolate credentials in the Secrets directory"
grep -Fq 'homeDirectoryForCurrentUser' "$PROVIDER_SESSION" \
  || fail "Provider credentials must resolve from the current login home directory"
if grep -Fq 'temporaryDirectory' "$PROVIDER_SESSION"; then
  fail "Provider credentials must fail closed instead of falling back to a temporary directory"
fi
grep -Eq '0o?700|448' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must enforce mode 0700 on the Secrets directory"
grep -Eq '0o?600|384' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must enforce mode 0600 on the credential file"
grep -Fq 'static let documentVersion = 1' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must write the version-1 credential document"
grep -Fq 'O_EXCL | O_NOFOLLOW' "$PROVIDER_SESSION" \
  || fail "Provider credential temporary files must be exclusive and must not follow symlinks"
grep -Fq 'fsync(descriptor)' "$PROVIDER_SESSION" \
  || fail "Provider credential contents must be fsynced before replacement"
grep -Fq 'rename(temporaryURL.path, fileURL.path)' "$PROVIDER_SESSION" \
  || fail "Provider credential updates must finish with an atomic same-directory rename"
grep -Fq 'lstat(directoryURL.path' "$PROVIDER_SESSION" \
  || fail "Provider credential storage must reject a symlinked Secrets directory"
grep -Fq 'fstat(descriptor' "$PROVIDER_SESSION" \
  || fail "Provider credential storage must inspect the opened file descriptor"
grep -Fq 'info.st_uid == geteuid()' "$PROVIDER_SESSION" \
  || fail "Provider credential paths must belong to the current macOS login"
grep -Fq 'static let lockFileName = ".provider-credentials.lock"' "$PROVIDER_SESSION" \
  || fail "Provider credential transactions must use one stable lock file"
grep -Fq 'flock(descriptor, LOCK_EX)' "$PROVIDER_SESSION" \
  || fail "Provider credential transactions must hold an exclusive process lock"
grep -Fq 'func updateCredentials(' "$PROVIDER_SESSION" \
  || fail "Provider credential apply/clear must use one read-modify-write transaction"
grep -Fq 'removeSafeStaleTemporaryFilesLocked' "$PROVIDER_SESSION" \
  || fail "Provider credential storage must sweep safe crash-temporary files under lock"
grep -Fq 'ProviderCredentialSession.shared.bootstrapSavedCredentials()' "$APP_ENTRY" \
  || fail "Zulangue startup must make one synchronous saved-provider bootstrap decision"
grep -Fq 'TestEnvironment.shouldLoadSavedProviderCredentials' "$APP_ENTRY" \
  || fail "Zulangue startup must isolate real provider credentials from test processes"
grep -Fq 'ZulangueCore.newDeferred' "$CORE_CLIENT" \
  || fail "Production Swift startup must defer durable task claims until credentials are loaded"
grep -Fq 'ProviderCredentialBootstrapGate' "$CORE" \
  || fail "Rust task claims must wait behind the provider credential bootstrap gate"
grep -Fq 'provider_credential_bootstrap.wait_or_cancelled' "$ROOT_DIR/crates/vt-ffi/src/task_worker.rs" \
  || fail "Rust worker must wait for credential bootstrap before its first task claim"
grep -Fq 'completeProviderCredentialBootstrap()' "$PROVIDER_SESSION" \
  || fail "ProviderCredentialSession must open the worker gate after successful activation"
grep -Fq 'environment["VT_TEST_MODE"] == "1"' "$TEST_ENVIRONMENT" \
  || fail "UI-test detection must cover the launch flag used by ZulangueUITests"

if grep -Eq 'UserDefaults\.standard\.(set|register)|SecItem(Add|Update|CopyMatching|Delete)' \
    "$PROVIDER_SESSION"; then
  fail "ProviderCredentialSession must not persist provider API keys in defaults or Keychain"
fi

if grep -Eq 'DebugLog\.|os_log|Logger\.|print\(' "$PROVIDER_SESSION"; then
  fail "ProviderCredentialSession must not log provider credential operations or values"
fi

grep -Fq 'Secrets/provider-credentials.json' "$README" \
  || fail "README must describe the current app-private provider credential file"
if grep -Eq 'Swift 侧 Key 存 macOS Keychain|macOS Keychain，再把|keyring-rs' "$README"; then
  fail "README must not describe the removed Keychain/keyring credential runtime"
fi

grep -Fq 'safe_soniox_request_id' "$SONIOX_RT" \
  || fail "Soniox request IDs must be allowlisted before they cross durable/log boundaries"
grep -Fq 'safe_soniox_task_error' "$TRANSCRIBE_API" \
  || fail "Async Soniox failures must use a redacted durable task message"
if grep -Eq 'response\.error_message|close[_ ]reason.*tracing|format!\([^)]*reason' \
    "$SONIOX_RT" "$SONIOX_STREAM" "$TRANSCRIBE_API"; then
  fail "Raw Soniox provider messages or close reasons must not cross into durable errors or logs"
fi

echo "secret-material static tripwires passed; Rust regression tests remain the behavioral authority"
