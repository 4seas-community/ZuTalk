# Zulangue 构建系统

# 变量
project_dir     := justfile_directory()
macos_dir       := project_dir / "macos" / "Zulangue"
bridge_dir      := macos_dir / "Zulangue" / "Bridge" / "Generated"
uniffi_out      := project_dir / "target" / "uniffi-generated"
app_bundle_id   := "xyz.voice.zulangue"
# 所有构建产物统一写入根级 build/。
build_dir       := project_dir / "build"
app_build_dir   := build_dir / "app"
dmg_dir         := build_dir / "dmg"
target_arm64    := "aarch64-apple-darwin"
target_x86_64   := "x86_64-apple-darwin"
macos_deployment_target := "15.5"

# 默认：列出所有命令
default:
    @just --list

# 一键初始化开发环境
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Zulangue 开发环境初始化 ==="
    xcode-select -p &>/dev/null || { echo "错误: 未安装 Xcode CLI Tools"; exit 1; }
    command -v rustc &>/dev/null || { curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; }
    rustup target add {{ target_arm64 }} {{ target_x86_64 }} 2>/dev/null || true
    rustup component add clippy rustfmt
    cargo install cargo-nextest --version 0.9.100 --locked 2>/dev/null || true
    cargo install cargo-insta --locked 2>/dev/null || true
    cargo fetch
    echo "=== 初始化完成。运行 'just dev' 开始构建 ==="

# Debug 构建（仅 ARM64）— 日常开发用
dev: _rust-build-debug _uniffi-generate _copy-artifacts _sync-xcode
    @echo "✓ Debug 构建完成"

# Release 构建（universal binary）— 发布用
release: _rust-build-release-arm64 _rust-build-release-x86_64 _lipo _uniffi-generate _copy-artifacts-release
    @echo "✓ Release 构建完成（universal binary）"

# 清理所有构建产物
clean:
    cargo clean
    rm -rf {{ bridge_dir }}
    rm -rf {{ uniffi_out }}
    # 保留构建目录说明和占位文件。
    find {{ build_dir }} -mindepth 1 -not -name "README.md" -not -name ".gitkeep" -delete 2>/dev/null || true
    @echo "✓ 清理完成"

# 清理 build/test-* 测试残留。
clean-test-residue:
    @find {{ build_dir }} -mindepth 1 -maxdepth 1 -name 'test-*' -type d -exec rm -rf {} + 2>/dev/null || true
    @echo "✓ build/test-* 已清"

# 清理 workspace 之外的 Xcode 与 fuzz 构建缓存。
clean-all: clean
    @rm -rf {{ macos_dir }}/build
    @echo "  ✓ macos/Zulangue/build 已清"
    @rm -rf {{ project_dir }}/fuzz/target
    @echo "  ✓ fuzz/target 已清"
    @rm -rf ~/Library/Developer/Xcode/DerivedData/Zulangue-*
    @echo "  ✓ Xcode DerivedData (所有 Zulangue-* hash) 已清"
    @echo "✓ 彻底清理完成"

# 修剪长期未使用的 Cargo 构建缓存。
# 用法: `just sweep` (默认 30 天) 或 `just sweep 7` (改阈值)
sweep days="30":
    @command -v cargo-sweep >/dev/null 2>&1 || { echo "需要先 cargo install cargo-sweep"; exit 1; }
    cargo sweep --time {{ days }} {{ project_dir }}
    cargo sweep --time {{ days }} {{ project_dir }}/fuzz 2>/dev/null || true
    @echo "✓ 已修剪 {{ days }} 天以上未使用的 fingerprint"

# 版本号同步（Cargo.toml → Info.plist）
sync-version:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c "import sys,json; pkgs=json.load(sys.stdin)['packages']; print([p['version'] for p in pkgs if p['name']=='vt-ffi'][0])")
    echo "Syncing version: $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" {{ macos_dir }}/Zulangue/Info.plist 2>/dev/null || echo "Info.plist not found (skip)"

# 版本号一致性检查
version-check:
    #!/usr/bin/env bash
    set -euo pipefail
    CARGO_VER=$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c "import sys,json; pkgs=json.load(sys.stdin)['packages']; print([p['version'] for p in pkgs if p['name']=='vt-ffi'][0])")
    echo "Cargo version: $CARGO_VER"
    if [ -f "{{ macos_dir }}/Zulangue/Info.plist" ]; then
        PLIST_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" {{ macos_dir }}/Zulangue/Info.plist)
        echo "Plist version: $PLIST_VER"
        if [ "$CARGO_VER" != "$PLIST_VER" ]; then
            echo "FAIL: Version mismatch! Run 'just sync-version'"
            exit 1
        fi
    fi
    echo "✓ Version OK: $CARGO_VER"

# 完整质量门禁
ci-check:
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    bash scripts/test_local_gate_wiring.sh
    bash scripts/test_gatekeeper_status.sh
    bash scripts/test_swift_test_gate.sh
    bash scripts/test_pr_macos_swift_gate.sh
    bash scripts/test_macos_rust_test_gate.sh
    bash scripts/test_release_distribution_gate.sh
    bash scripts/test_release_universal_app_gate.sh
    bash scripts/test_bundle_id_recovery_gate.sh
    bash scripts/test_secret_material_storage_gate.sh
    bash scripts/test_minimal_mvp_architecture_gate.sh
    bash scripts/anti-demo.sh
    @echo "✓ CI check 通过"

# 本地合并门禁，覆盖静态检查、Rust、Swift 和本地部署。
local-gate: local-gate-static local-gate-rust-core local-gate-rust-macos swift-test deploy-local
    @echo "✓ Local gate 通过"

local-gate-static:
    cargo fmt --all -- --check
    bash scripts/test_local_gate_wiring.sh
    bash scripts/test_gatekeeper_status.sh
    bash scripts/test_swift_test_gate.sh
    bash scripts/test_pr_macos_swift_gate.sh
    bash scripts/test_macos_rust_test_gate.sh
    bash scripts/test_release_distribution_gate.sh
    bash scripts/test_release_universal_app_gate.sh
    bash scripts/test_bundle_id_recovery_gate.sh
    bash scripts/test_secret_material_storage_gate.sh
    bash scripts/test_minimal_mvp_architecture_gate.sh
    bash scripts/anti-demo.sh

local-gate-rust-core:
    cargo nextest run --no-fail-fast \
        -p vt-model \
        -p vt-crypto \
        -p vt-stt \
        -p vt-audio \
        -p vt-export \
        -p vt-store \
        -p vt-i18n

local-gate-rust-macos:
    cargo nextest run --no-fail-fast \
        -p vt-pipeline \
        -p vt-ffi

# 静态守门：检查示例数据、硬编码密钥、未完成代码和通知监听。
lint:
    bash scripts/anti-demo.sh

# 安全门禁（cargo audit + cargo deny）
ci-security:
    #!/usr/bin/env bash
    set -e
    if ! command -v cargo-audit >/dev/null; then
        echo "Installing cargo-audit..."
        cargo install cargo-audit --locked
    fi
    if ! command -v cargo-deny >/dev/null; then
        echo "Installing cargo-deny..."
        cargo install cargo-deny --locked
    fi
    cargo audit
    cargo deny check
    echo "✓ Security check 通过"

# 运行 Rust 测试
test:
    cargo nextest run --workspace

# 可选的 Soniox 真实线路冒烟。构建完成后才从交互终端读取凭据；
# 凭据只存在于当前 recipe/测试子进程内，不进入命令行、仓库或测试输出。
soniox-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    set +x
    unset SONIOX_API_KEY

    if ! command -v jq >/dev/null 2>&1; then
        echo "FAIL: jq is required to locate the prebuilt smoke-test binary"
        exit 1
    fi

    echo "Building the Soniox smoke test without a credential in the process environment..."
    smoke_binary="$(
        cargo test -p vt-stt \
            --test soniox_two_way_real_smoke \
            --no-run \
            --message-format=json \
        | jq -r 'select(.reason == "compiler-artifact" and .target.name == "soniox_two_way_real_smoke" and .profile.test == true) | .executable // empty' \
        | tail -n 1
    )"
    if [[ -z "$smoke_binary" || ! -x "$smoke_binary" ]]; then
        echo "FAIL: Soniox smoke-test binary was not produced"
        exit 1
    fi

    if [[ ! -t 0 ]]; then
        echo "FAIL: an interactive terminal is required to enter the one-run Soniox key"
        exit 1
    fi

    IFS= read -r -s -p "Enter Soniox API key for this smoke run (not stored): " soniox_key
    echo

    if [[ -z "${soniox_key//[[:space:]]/}" ]]; then
        echo "FAIL: Soniox credential is empty"
        exit 1
    fi

    trap 'unset soniox_key smoke_binary' EXIT

    SONIOX_API_KEY="$soniox_key" "$smoke_binary" \
        soniox_v5_two_way_real_smoke_redacts_content \
        --ignored --exact --nocapture

# 运行 Swift 集成测试（自动重建 Rust + UniFFI 绑定）
swift-test: dev clean-test-residue
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild test \
        -project {{ macos_dir }}/Zulangue.xcodeproj \
        -scheme ZulangueTests \
        -destination "platform=macOS,arch=arm64" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        -quiet \
        2>&1 | xcbeautify

# 运行 Swift 测试 + 覆盖率报告
swift-coverage: dev clean-test-residue
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    xcodebuild test \
        -project {{ macos_dir }}/Zulangue.xcodeproj \
        -scheme ZulangueTests \
        -destination "platform=macOS,arch=arm64" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        -enableCodeCoverage YES \
        -resultBundlePath build/swift-test-result.xcresult \
        -quiet 2>&1 | xcbeautify

    echo ""
    echo "=== Coverage Summary ==="
    xcrun xccov view --report --only-targets build/swift-test-result.xcresult

    echo ""
    echo "=== Per-file Coverage (Zulangue.app) ==="
    xcrun xccov view --report --files-for-target Zulangue.app \
        build/swift-test-result.xcresult | head -50

# 运行所有测试（Rust + Swift）
test-all: test swift-test
    @echo "=== Rust + Swift 所有测试通过 ==="

# 验证构建产物
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== 验证构建产物 ==="
    test -f "{{ bridge_dir }}/libvt_ffi.a" || { echo "FAIL: libvt_ffi.a 不存在"; exit 1; }
    test -f "{{ bridge_dir }}/vt_ffi.swift" || { echo "FAIL: Swift 绑定不存在"; exit 1; }
    test -f "{{ bridge_dir }}/vt_ffiFFI.h" || { echo "FAIL: C 头文件不存在"; exit 1; }
    test -f "{{ bridge_dir }}/vt_ffiFFI.modulemap" || { echo "FAIL: modulemap 不存在"; exit 1; }
    file "{{ bridge_dir }}/libvt_ffi.a" | grep -q "archive" || { echo "FAIL: 不是有效归档"; exit 1; }
    grep -q "ZulangueCore" "{{ bridge_dir }}/vt_ffi.swift" || { echo "FAIL: Swift 绑定不含 ZulangueCore"; exit 1; }
    echo "=== 全部通过 ==="

# Xcode build → .app 输出到 build/app/（用于打包 / 本地直接运行）
#
# 默认只 build 当前 host arch（ARM Mac → arm64-only），匹配 just dev 的产物。
# Ad Hoc universal build 用 'just release-adhoc'；Developer ID 发布用 'just release-full'。
xcode-build:
    #!/usr/bin/env bash
    set -euo pipefail
    OUT="{{ app_build_dir }}"
    mkdir -p "$OUT"
    HOST_ARCH=$(uname -m)
    LOG="$OUT/xcodebuild.log"
    echo "Building for host arch: $HOST_ARCH"
    if ! xcodebuild build \
        -project "{{ macos_dir }}/Zulangue.xcodeproj" \
        -scheme Zulangue \
        -configuration Release \
        -derivedDataPath "$OUT/.derived" \
        -destination "platform=macOS,arch=$HOST_ARCH" \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS="$HOST_ARCH" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-" \
        DEVELOPMENT_TEAM="" \
        SYMROOT="$OUT/.symroot" \
        OBJROOT="$OUT/.intermediates" \
        CONFIGURATION_BUILD_DIR="$OUT" \
        >"$LOG" 2>&1; then
        grep -E "error:|warning:|BUILD|✓|libvt_ffi" "$LOG" | tail -80 || tail -80 "$LOG"
        exit 1
    fi
    grep -E "error:|warning:|BUILD|✓|libvt_ffi" "$LOG" | tail -30 || true
    test -d "$OUT/Zulangue.app" || { echo "FAIL: Zulangue.app 未生成"; exit 1; }
    echo "✓ Xcode build → $OUT/Zulangue.app"
    # 保留 Xcode 自动签名结果；未配置签名身份时，本地构建使用 ad-hoc 签名。
    AUTH=$(codesign -dv "$OUT/Zulangue.app" 2>&1 | grep "Authority" | head -1 | sed 's/.*=//' || echo "")
    if [ -z "$AUTH" ]; then
        echo "⚠ adhoc 签名 (team=None) · 需 'just approve' 让 Gatekeeper 接受"
    else
        echo "✓ Signed by: $AUTH"
    fi

# Release 专用 Xcode build。和本地 xcode-build 分开，避免 deploy-local 被双架构构建拖慢。
xcode-build-universal:
    #!/usr/bin/env bash
    set -euo pipefail
    OUT="{{ app_build_dir }}"
    mkdir -p "$OUT"
    LOG="$OUT/xcodebuild-universal.log"
    echo "Building universal release app: arm64 x86_64"
    if ! xcodebuild build \
        -project "{{ macos_dir }}/Zulangue.xcodeproj" \
        -scheme Zulangue \
        -configuration Release \
        -derivedDataPath "$OUT/.derived-universal" \
        -destination "generic/platform=macOS" \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="arm64 x86_64" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-" \
        DEVELOPMENT_TEAM="" \
        SYMROOT="$OUT/.symroot-universal" \
        OBJROOT="$OUT/.intermediates-universal" \
        CONFIGURATION_BUILD_DIR="$OUT" \
        >"$LOG" 2>&1; then
        grep -E "error:|warning:|BUILD|ARCHS|ONLY_ACTIVE_ARCH|libvt_ffi" "$LOG" | tail -120 || tail -120 "$LOG"
        exit 1
    fi
    grep -E "error:|warning:|BUILD|ARCHS|ONLY_ACTIVE_ARCH|libvt_ffi" "$LOG" | tail -40 || true
    test -d "$OUT/Zulangue.app" || { echo "FAIL: Zulangue.app 未生成"; exit 1; }
    just assert-universal-app
    echo "✓ Universal Xcode build → $OUT/Zulangue.app"

assert-universal-app:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    BIN="$APP/Contents/MacOS/Zulangue"
    if [ ! -x "$BIN" ]; then
        echo "FAIL: $BIN 不存在或不可执行 — 先运行 'just xcode-build-universal'"
        exit 1
    fi
    ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
    for arch in arm64 x86_64; do
        if ! lipo "$BIN" -verify_arch "$arch" >/dev/null 2>&1; then
            echo "FAIL: $BIN 缺少 $arch 架构 (found: ${ARCHS:-unknown})"
            exit 1
        fi
    done
    echo "✓ Universal app executable: $ARCHS"

assert-adhoc-app:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    test -d "$APP" || { echo "FAIL: $APP 不存在"; exit 1; }
    codesign --verify --deep --strict "$APP"
    DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
    grep -Fq "Signature=adhoc" <<<"$DETAILS" \
        || { echo "FAIL: Zulangue.app 不是 Ad Hoc 签名"; exit 1; }
    echo "✓ Ad Hoc signature verified"

assert-public-app-privacy:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    test -d "$APP" || { echo "FAIL: $APP 不存在"; exit 1; }
    SCAN="$(mktemp)"
    trap 'rm -f "$SCAN"' EXIT
    find "$APP" -type f -maxdepth 6 -exec strings {} \; >"$SCAN"
    if grep -Eq '/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/' "$SCAN"; then
        echo "FAIL: release app contains a machine-local user path" >&2
        exit 1
    fi
    prior_identity_pattern='4[[:space:]_-]*S''EAS|Four''Seas|Voice''Tool|Gi''tea'
    if grep -Eiq "$prior_identity_pattern" "$SCAN"; then
        echo "FAIL: release app contains a prior product or service identity" >&2
        exit 1
    fi
    echo "✓ Release app contains no machine-local paths or prior identities"

# 先生成最新 Rust 库与 UniFFI 绑定，再构建 Xcode 应用。

# 本地 app bundle 构建，只写 workspace 内 build/app。
build-local-app: dev xcode-build
    @echo "✓ Local app bundle ready at {{ app_build_dir }}/Zulangue.app"

# 安装已构建 app 到 /Applications。
install-local-app:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    if [ ! -d "$APP" ]; then
        echo "✗ $APP 不存在,先运行 'just build-local-app'"
        exit 1
    fi
    killall Zulangue 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Zulangue.app
    ditto "$APP" /Applications/Zulangue.app
    echo "✓ Deployed to /Applications/Zulangue.app"
    # 清理构建产物可能继承的 quarantine/provenance xattr。
    xattr -rc /Applications/Zulangue.app 2>/dev/null || true
    # 检查 Gatekeeper 状态。
    bash "{{ project_dir }}/scripts/check_gatekeeper_status.sh" --warn --type execute /Applications/Zulangue.app
    codesign -dv /Applications/Zulangue.app 2>&1 | grep -E "Signature|Authority" | head -2 || true

assert-gatekeeper-accepted target="/Applications/Zulangue.app" assess_type="execute":
    bash "{{ project_dir }}/scripts/check_gatekeeper_status.sh" --strict --type "{{ assess_type }}" "{{ target }}"

assert-release-dmg-gatekeeper-accepted:
    #!/usr/bin/env bash
    set -euo pipefail
    DMG=$(ls -t {{ dmg_dir }}/Zulangue-*.dmg 2>/dev/null | head -1)
    if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
        echo "FAIL: {{ dmg_dir }}/Zulangue-*.dmg 不存在 — 先运行 'just dmg'"
        exit 1
    fi
    just assert-gatekeeper-accepted "$DMG" open

# 一键部署到 /Applications (构建 + 覆盖 + Gatekeeper/codesign 检查)
deploy-local: build-local-app install-local-app
    @echo "✓ Local deploy complete"

# 从 build/ 直接启动开发构建。
launch-dev: xcode-build
    #!/usr/bin/env bash
    killall Zulangue 2>/dev/null || true
    sleep 1
    open {{ app_build_dir }}/Zulangue.app
    echo "✓ Launched build/ app directly (bypass Gatekeeper)"

# 清理 xattr，并重置 /Applications 中应用的 TCC 与 onboarding 状态。
approve:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="/Applications/Zulangue.app"
    if [ ! -d "$APP" ]; then
        echo "✗ $APP 不存在,先 'just deploy-local'"
        exit 1
    fi
    # 清理 xattr。
    xattr -rc "$APP" 2>/dev/null || true
    # 重置当前 bundle identifier 的 TCC 记录。
    tccutil reset Accessibility {{ app_bundle_id }} 2>/dev/null | tail -1 || true
    tccutil reset Microphone {{ app_bundle_id }} 2>/dev/null | tail -1 || true
    defaults delete {{ app_bundle_id }} zulangue.onboarding.completed 2>/dev/null || true
    killall Zulangue 2>/dev/null || true
    sleep 1
    echo "✓ TCC 清空 + onboarding 重置"
    echo ""
    echo "现在运行 'open /Applications/Zulangue.app' 并重新完成授权。"

# 代码签名（缺 DEVELOPER_ID 时回退到 ad-hoc，仅用于本地开发）
sign:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    if [ ! -d "$APP" ]; then
        echo "FAIL: $APP 不存在 — 先运行 'just xcode-build'"
        exit 1
    fi
    if [ -z "${DEVELOPER_ID:-}" ]; then
        echo "⚠ DEVELOPER_ID 未设置，使用 ad-hoc 签名（不可分发，仅本地运行）"
        codesign --force --deep --sign - \
            --options runtime \
            --entitlements {{ project_dir }}/macos/Zulangue.entitlements \
            "$APP"
    else
        echo "签名: $APP (id=$DEVELOPER_ID)"
        codesign --force --deep --options runtime \
            --sign "$DEVELOPER_ID" \
            --entitlements {{ project_dir }}/macos/Zulangue.entitlements \
            --timestamp \
            "$APP"
    fi
    codesign --verify --strict "$APP"
    echo "✓ 签名完成"

# 官方发布签名。缺 DEVELOPER_ID 必须失败，不能回退 ad-hoc。
sign-release:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${DEVELOPER_ID:?DEVELOPER_ID is required for release signing}"
    APP="{{ app_build_dir }}/Zulangue.app"
    if [ ! -d "$APP" ]; then
        echo "FAIL: $APP 不存在 — 先运行 'just xcode-build-universal'"
        exit 1
    fi
    echo "发布签名: $APP (id=$DEVELOPER_ID)"
    codesign --force --deep --options runtime \
        --sign "$DEVELOPER_ID" \
        --entitlements {{ project_dir }}/macos/Zulangue.entitlements \
        --timestamp \
        "$APP"
    codesign --verify --strict "$APP"
    echo "✓ 发布签名完成"

# 公证（需要 keychain profile "zulangue-notary"，由 'xcrun notarytool store-credentials' 创建）
notarize:
    #!/usr/bin/env bash
    set -euo pipefail
    # 公证最新 dmg(不依赖版本号)
    DMG=$(ls -t {{ dmg_dir }}/Zulangue-*.dmg 2>/dev/null | head -1)
    if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
        echo "FAIL: {{ dmg_dir }}/Zulangue-*.dmg 不存在 — 先运行 'just dmg'"
        exit 1
    fi
    xcrun notarytool submit "$DMG" \
        --keychain-profile "zulangue-notary" \
        --wait
    xcrun stapler staple "$DMG"
    echo "✓ 公证完成: $DMG"

# 官方发布公证。缺 notary profile 必须失败，不能跳过。
notarize-release:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v security >/dev/null 2>&1 || { echo "FAIL: security 不可用，无法验证公证 profile"; exit 1; }
    if ! security find-generic-password -a "zulangue-notary" -s "com.apple.gk.ticket-delivery" >/dev/null 2>&1; then
        echo "FAIL: zulangue-notary keychain profile 未配置，不能生成官方发布产物"
        exit 1
    fi
    just notarize

# DMG 打包；应用本身必须先完成所选签名流程。
# 输出到 build/dmg/Zulangue-{version}.dmg
dmg:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app_build_dir }}/Zulangue.app"
    if [ ! -d "$APP" ]; then
        echo "FAIL: $APP 不存在 — 先运行 'just xcode-build'"
        exit 1
    fi
    VERSION=$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c "import sys,json; pkgs=json.load(sys.stdin)['packages']; print([p['version'] for p in pkgs if p['name']=='vt-ffi'][0])")
    DMG="{{ dmg_dir }}/Zulangue-${VERSION}.dmg"
    bash "{{ project_dir }}/scripts/create_friendly_dmg.sh" "$APP" "$VERSION" "$DMG"

# 单一社区发布包：Universal app + Ad Hoc 签名 + DMG。
release-adhoc: release xcode-build-universal assert-universal-app assert-adhoc-app assert-public-app-privacy dmg
    @echo "✓ Ad Hoc Universal release 完成: build/dmg/Zulangue-*.dmg"

# 完整签名发布（需要 DEVELOPER_ID 和 notarize keychain profile）
release-full: release xcode-build-universal assert-universal-app assert-public-app-privacy sign-release dmg notarize-release assert-release-dmg-gatekeeper-accepted
    @echo "✓ 完整签名 + 公证 release 完成: build/dmg/Zulangue-*.dmg"

# --- 内部 recipes ---

_rust-build-debug:
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix={{ project_dir }}=. --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo" \
        MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }} \
        cargo build -p vt-ffi --target {{ target_arm64 }}

_rust-build-release-arm64:
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix={{ project_dir }}=. --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo" \
        MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }} \
        cargo build -p vt-ffi --release --target {{ target_arm64 }}

_rust-build-release-x86_64:
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix={{ project_dir }}=. --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo" \
        MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }} \
        cargo build -p vt-ffi --release --target {{ target_x86_64 }}

_lipo:
    mkdir -p target/universal/release
    lipo -create \
        target/{{ target_arm64 }}/release/libvt_ffi.a \
        target/{{ target_x86_64 }}/release/libvt_ffi.a \
        -output target/universal/release/libvt_ffi.a

_uniffi-generate:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ uniffi_out }}
    # 先确保 debug 版本已编译（uniffi 从 debug 提取接口）
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix={{ project_dir }}=. --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=.cargo" \
        MACOSX_DEPLOYMENT_TARGET={{ macos_deployment_target }} \
        cargo build -p vt-ffi --target {{ target_arm64 }}
    cargo run -p vt-ffi --bin uniffi-bindgen generate \
        --library target/{{ target_arm64 }}/debug/libvt_ffi.dylib \
        --language swift \
        --out-dir {{ uniffi_out }}

_copy-artifacts:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ bridge_dir }}
    cp target/{{ target_arm64 }}/debug/libvt_ffi.a {{ bridge_dir }}/
    cp {{ uniffi_out }}/*.swift {{ bridge_dir }}/ 2>/dev/null || true
    cp {{ uniffi_out }}/*.h {{ bridge_dir }}/ 2>/dev/null || true
    cp {{ uniffi_out }}/*.modulemap {{ bridge_dir }}/ 2>/dev/null || true
    ruby {{ project_dir }}/scripts/patch_uniffi_swift_init_guard.rb {{ bridge_dir }}/vt_ffi.swift
    ruby {{ project_dir }}/scripts/patch_uniffi_header_guard.rb {{ bridge_dir }}/vt_ffiFFI.h
    perl -pi -e 's/[ \t]+$//' {{ bridge_dir }}/*.swift {{ bridge_dir }}/*.h 2>/dev/null || true
    perl -0pi -e 's/\n+\z/\n/' {{ bridge_dir }}/*.swift {{ bridge_dir }}/*.h 2>/dev/null || true
    # Native C libs 必须跟 libvt_ffi.a 一起给 Xcode link(否则 Undefined symbols)。
    # fdk-aac-sys 的 build.rs 在 target/.../build/fdk-aac-sys-*/out 下出 libfdk-aac.a。
    FDK=$(ls -t target/{{ target_arm64 }}/debug/build/fdk-aac-sys-*/out/libfdk-aac.a 2>/dev/null | head -1)
    if [ -n "$FDK" ]; then cp "$FDK" {{ bridge_dir }}/; fi

_copy-artifacts-release:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ bridge_dir }}
    cp target/universal/release/libvt_ffi.a {{ bridge_dir }}/
    FDK_ARM64=$(ls -t target/{{ target_arm64 }}/release/build/fdk-aac-sys-*/out/libfdk-aac.a 2>/dev/null | head -1)
    FDK_X86_64=$(ls -t target/{{ target_x86_64 }}/release/build/fdk-aac-sys-*/out/libfdk-aac.a 2>/dev/null | head -1)
    if [ -z "$FDK_ARM64" ] || [ -z "$FDK_X86_64" ]; then
        echo "FAIL: release libfdk-aac.a missing for arm64 or x86_64"
        exit 1
    fi
    rm -f {{ bridge_dir }}/libfdk-aac.a
    lipo -create "$FDK_ARM64" "$FDK_X86_64" -output {{ bridge_dir }}/libfdk-aac.a
    lipo {{ bridge_dir }}/libfdk-aac.a -verify_arch arm64 x86_64
    cp {{ uniffi_out }}/*.swift {{ bridge_dir }}/ 2>/dev/null || true
    cp {{ uniffi_out }}/*.h {{ bridge_dir }}/ 2>/dev/null || true
    cp {{ uniffi_out }}/*.modulemap {{ bridge_dir }}/ 2>/dev/null || true
    ruby {{ project_dir }}/scripts/patch_uniffi_swift_init_guard.rb {{ bridge_dir }}/vt_ffi.swift
    ruby {{ project_dir }}/scripts/patch_uniffi_header_guard.rb {{ bridge_dir }}/vt_ffiFFI.h
    perl -pi -e 's/[ \t]+$//' {{ bridge_dir }}/*.swift {{ bridge_dir }}/*.h 2>/dev/null || true
    perl -0pi -e 's/\n+\z/\n/' {{ bridge_dir }}/*.swift {{ bridge_dir }}/*.h 2>/dev/null || true

# 同步 Swift 文件到 Xcode project（防止新文件遗漏）
_sync-xcode:
    #!/usr/bin/env bash
    set -euo pipefail
    GEM_DIR=$(ruby -e 'puts Gem.user_dir' 2>/dev/null || echo "")
    if [ -z "$GEM_DIR" ] || [ ! -d "$GEM_DIR/gems/xcodeproj-1.27.0" ]; then
        echo "  ⚠ xcodeproj gem not found, skipping Xcode sync"
        exit 0
    fi
    ruby \
        -I"$GEM_DIR/gems/xcodeproj-1.27.0/lib" \
        -I"$GEM_DIR/gems/nanaimo-0.4.0/lib" \
        -I"$GEM_DIR/gems/colored2-4.0.0/lib" \
        -I"$GEM_DIR/gems/claide-1.1.0/lib" \
        -I"$GEM_DIR/gems/atomos-0.1.3/lib" \
        {{ project_dir }}/scripts/sync_xcode_project.rb 2>/dev/null
    ruby \
        -I"$GEM_DIR/gems/xcodeproj-1.27.0/lib" \
        -I"$GEM_DIR/gems/nanaimo-0.4.0/lib" \
        -I"$GEM_DIR/gems/colored2-4.0.0/lib" \
        -I"$GEM_DIR/gems/claide-1.1.0/lib" \
        -I"$GEM_DIR/gems/atomos-0.1.3/lib" \
        {{ project_dir }}/scripts/dedup_build_phase.rb 2>/dev/null || true
