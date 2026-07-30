import XCTest
@testable import Zulangue

@MainActor
final class LocalSystemSettingsViewModelTests: XCTestCase {
    func testServicesSectionNameIsNotAProviderName() {
        let displayName = SettingsSection.services.displayName

        XCTAssertNotEqual(displayName, ProviderCredentialAccount.soniox.displayName)
    }

    func testServicesSectionLocalizationsDoNotUseProviderAsNavigation() throws {
        XCTAssertEqual(
            try localizedString(locale: "en", key: "settings.section.services_name"),
            "Services & API"
        )
        XCTAssertEqual(
            try localizedString(locale: "zh-Hans", key: "settings.section.services_name"),
            "服务与 API"
        )
        XCTAssertEqual(
            try localizedString(locale: "ja", key: "settings.section.services_name"),
            "サービスと API"
        )
    }

    func testProviderDeletionRequiresExplicitConfirmation() throws {
        let session = FakeProviderCredentialSession()
        let viewModel = ProviderConnectionsViewModel(credentialSession: session)

        viewModel.requestDeletion(.account(.soniox))
        XCTAssertEqual(viewModel.pendingDeletion, .account(.soniox))
        XCTAssertEqual(session.clearCallCount, 0)

        viewModel.cancelDeletion()
        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(session.clearCallCount, 0)

        viewModel.requestDeletion(.account(.soniox))
        viewModel.confirmDeletion()
        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(session.clearCallCount, 1)
    }

    func testCredentialFileResetRequiresExplicitConfirmation() throws {
        let session = FakeProviderCredentialSession()
        let viewModel = ProviderConnectionsViewModel(credentialSession: session)

        viewModel.requestDeletion(.savedCredentialFile)
        XCTAssertEqual(session.resetCallCount, 0)
        viewModel.confirmDeletion()

        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(session.resetCallCount, 1)
    }

    func testCredentialEditorCommitsTrimmedReplacementOnReturnOrBlur() {
        XCTAssertEqual(
            ProviderCredentialEditorCommitDecision.resolve(
                rawValue: "  replacement-key\n",
                isConfigured: true
            ),
            .apply("replacement-key")
        )
        XCTAssertEqual(
            ProviderCredentialEditorCommitDecision.resolve(
                rawValue: "   ",
                isConfigured: true
            ),
            .dismissReplacement
        )
        XCTAssertEqual(
            ProviderCredentialEditorCommitDecision.resolve(
                rawValue: "",
                isConfigured: false
            ),
            .keepEditing
        )
    }

    func testCredentialEditorVerifiesBeforeSaving() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".onSubmit(verifyAndCommitDraft)"))
        XCTAssertTrue(source.contains("await verificationStore.verifyCandidate("))
        XCTAssertTrue(source.contains("guard verification.isReady else"))
        XCTAssertTrue(source.contains("try credentialSession.apply(normalized, for: account)"))
        XCTAssertFalse(source.contains(".onChange(of: isFocused)"))
    }

    func testInvalidCandidateIsNotSaved() async {
        let session = FakeProviderCredentialSession()
        let validator = FakeProviderCredentialValidator(
            result: .invalidCredential(Date(timeIntervalSince1970: 100))
        )
        let store = ProviderConnectionVerificationStore(validator: validator)
        let viewModel = ProviderConnectionsViewModel(
            credentialSession: session,
            verificationStore: store
        )

        do {
            try await viewModel.verifyAndApply("bad-key", for: .soniox)
            XCTFail("Invalid credentials must not be saved")
        } catch {
            XCTAssertEqual(session.applyCallCount, 0)
            XCTAssertEqual(validator.callCount, 1)
            XCTAssertNil(validator.lastCandidateAfterCall)
        }
    }

    func testReadyCandidateIsSavedAfterVerification() async throws {
        let session = FakeProviderCredentialSession()
        let validator = FakeProviderCredentialValidator(
            result: .ready(Date(timeIntervalSince1970: 100))
        )
        let store = ProviderConnectionVerificationStore(validator: validator)
        let viewModel = ProviderConnectionsViewModel(
            credentialSession: session,
            verificationStore: store
        )

        try await viewModel.verifyAndApply("  valid-key  ", for: .soniox)

        XCTAssertEqual(validator.callCount, 1)
        XCTAssertEqual(session.applyCallCount, 1)
        XCTAssertEqual(session.lastAppliedValue, "valid-key")
        XCTAssertTrue(store.state(for: .soniox).isReady)
    }

    func testFreshSavedCredentialCheckUsesCache() async {
        let checkedAt = Date(timeIntervalSince1970: 100)
        let validator = FakeProviderCredentialValidator(result: .ready(checkedAt))
        let store = ProviderConnectionVerificationStore(
            validator: validator,
            now: { Date(timeIntervalSince1970: 101) }
        )

        store.verifyIfNeeded(account: .soniox, isConfigured: true)
        await Task.yield()
        await Task.yield()
        store.verifyIfNeeded(account: .soniox, isConfigured: true)
        await Task.yield()

        XCTAssertEqual(validator.callCount, 1)
        XCTAssertEqual(store.state(for: .soniox), .ready(checkedAt))
    }

    func testEnginePresentationSeparatesRealtimeAndPostStopRoles() {
        let engine = NotebookCaptureEnginePresentation(
            providerDisplayName: "Soniox",
            realtimeModelId: "stt-rt-v5",
            postStopModelId: "stt-rt-v5",
            postStopUsesRealtimeRestream: true
        )

        XCTAssertEqual(engine.realtimeSummary, "Soniox · stt-rt-v5")
        XCTAssertEqual(engine.postStopSummary, "Soniox · stt-rt-v5")
        XCTAssertEqual(engine.postStopUsesRealtimeRestream, true)
        XCTAssertEqual(engine.postStopExecutionSummary, String(
            localized: "settings.services.engine.realtime_replay"
        ))

        XCTAssertEqual(
            NotebookCaptureEnginePresentation.descriptorUnavailable.postStopExecutionSummary,
            String(localized: "settings.services.engine.execution_unavailable")
        )
    }

    func testCredentialPresentationDistinguishesEveryPersistenceRuntimeState() {
        func snapshot(saved: Bool, active: Bool) -> ProviderCredentialSnapshot {
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: ProviderCredentialAccount.soniox.scope,
                isSaved: saved,
                isActive: active
            )
        }

        XCTAssertEqual(
            ProviderCredentialPresentationState.resolve(snapshot(saved: false, active: false)),
            .missing
        )
        XCTAssertEqual(
            ProviderCredentialPresentationState.resolve(snapshot(saved: true, active: false)),
            .savedInactive
        )
        XCTAssertEqual(
            ProviderCredentialPresentationState.resolve(snapshot(saved: true, active: true)),
            .savedLoadedUnverified
        )
        XCTAssertEqual(
            ProviderCredentialPresentationState.resolve(snapshot(saved: false, active: true)),
            .runtimeOnlyUnverified
        )
        XCTAssertEqual(
            ProviderCredentialPresentationState.savedInactive.localizedStatusTitle,
            String(localized: "settings.credentials.saved_inactive")
        )
        XCTAssertNotEqual(
            ProviderCredentialPresentationState.savedInactive.localizedStatusTitle,
            String(localized: "settings.credentials.missing")
        )
    }

    func testProviderSettingsHasNoModelPickerOrArbitraryModelEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let providerSettings = try String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        let credentialSession = try String(
            contentsOf: root.appendingPathComponent("App/ProviderCredentialSession.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(providerSettings.contains("Picker("))
        XCTAssertFalse(providerSettings.contains("modelId"))
        XCTAssertFalse(providerSettings.contains("stt-rt-v5"))
        for unsupportedProvider in ["OpenRouter", "Anthropic", "DeepSeek", "xAI"] {
            XCTAssertFalse(providerSettings.contains(unsupportedProvider))
        }
        XCTAssertTrue(credentialSession.contains("getNotebookCaptureEngineDescriptor()"))
        XCTAssertTrue(providerSettings.contains("engineStore.engine"))
    }

    func testProviderCredentialEditorMeetsMinimumInteractionTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        let fieldStart = try XCTUnwrap(source.range(of: "SecureField("))
        let fieldEnd = try XCTUnwrap(
            source[fieldStart.upperBound...].range(of: "Text(statusHint)")
        )
        let field = source[fieldStart.lowerBound..<fieldEnd.lowerBound]

        XCTAssertTrue(field.contains(".frame(minHeight: 44)"))
        XCTAssertFalse(field.contains(".frame(minHeight: 32)"))
    }

    func testProviderCredentialCopyExplainsLocalLoginTrustBoundary() throws {
        let expectedHints = [
            "en": "Saved unencrypted in an app-private file readable by this macOS login and loaded automatically at launch.",
            "zh-Hans": "以未加密文件保存在当前 macOS 登录账户的应用私有目录中，并在启动时自动加载。",
            "ja": "現在の macOS ログインだけが読めるアプリ専用ファイルに暗号化せず保存し、起動時に自動で読み込みます。",
        ]
        for (locale, expected) in expectedHints {
            let hint = try localizedString(
                locale: locale,
                key: "settings.credentials.local_storage_hint"
            )
            XCTAssertEqual(hint, expected)
            XCTAssertFalse(hint.localizedCaseInsensitiveContains("Keychain"))
        }
    }

    func testProviderCredentialStatusesDescribeRuntimeStateNotConnectivity() throws {
        let keys = [
            "settings.credentials.applied",
            "settings.credentials.missing",
            "settings.credentials.accessibility_applied_format",
            "settings.credentials.accessibility_missing_format",
            "settings.credentials.provider_not_tested_hint",
            "settings.credentials.recovery_title",
            "settings.credentials.recovery_hint",
            "settings.credentials.reset_file",
            "settings.credentials.reset_file_accessibility_hint",
        ]
        let forbiddenClaims = ["connected", "ready", "已连接", "接続済み"]

        for locale in ["en", "zh-Hans", "ja"] {
            for key in keys {
                let value = try localizedString(locale: locale, key: key)
                XCTAssertNotEqual(value, key, "Missing \(locale) localization for \(key)")
                for claim in forbiddenClaims {
                    XCTAssertFalse(
                        value.localizedCaseInsensitiveContains(claim),
                        "\(key) must not imply a successful provider test"
                    )
                }
            }
        }
    }

    func testNotebookCredentialReadinessCopyNeverClaimsConnectionSuccess() throws {
        let keys = [
            "capture.settings.realtime.start_disclosure",
            "capture.settings.remote.credential.loaded_unverified",
            "capture.settings.remote.credential.saved_inactive",
            "capture.settings.remote.credential.runtime_only_unverified",
            "capture.settings.remote.credential.missing",
            "capture.settings.remote.credential.hint",
        ]
        let forbiddenClaims = ["connected", "connection succeeded", "已连接", "连接成功", "接続済み"]

        for locale in ["en", "zh-Hans", "ja"] {
            for key in keys {
                let value = try localizedString(locale: locale, key: key)
                XCTAssertNotEqual(value, key)
                for claim in forbiddenClaims {
                    XCTAssertFalse(value.localizedCaseInsensitiveContains(claim))
                }
            }
        }
    }

    func testLiveTranscriptTabHintDoesNotClaimRemoteStreaming() throws {
        let expected = [
            "en": "Live transcript — recording in progress",
            "zh-Hans": "实时转录进行中",
            "ja": "リアルタイム文字起こし — 録音中",
        ]

        for (locale, value) in expected {
            let hint = try localizedString(
                locale: locale,
                key: "editor.tab.transcript.live.hint"
            )
            XCTAssertEqual(hint, value)
            XCTAssertFalse(hint.localizedCaseInsensitiveContains("Soniox"))
            XCTAssertFalse(hint.localizedCaseInsensitiveContains("stream"))
            XCTAssertFalse(hint.contains("流"))
        }
    }

    func testRemovedVoiceAPISettingsKeysStayAbsent() throws {
        let removedKeys = [
            "settings.section.voice_api",
            "settings.section.voice_api_name",
            "settings.voice_api.subtitle",
            "settings.voice_api.title",
            "settings.voice_api.rt_label",
            "settings.voice_api.async_label",
            "settings.api.provider_label",
            "settings.api.key_label",
            "toast.floating.need_key.detail",
        ]
        let testFile = URL(fileURLWithPath: #filePath)
        let resources = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue/Resources", isDirectory: true)

        for locale in ["en", "zh-Hans", "ja"] {
            let source = try String(
                contentsOf: resources
                    .appendingPathComponent("\(locale).lproj", isDirectory: true)
                    .appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            for key in removedKeys {
                XCTAssertFalse(source.contains("\"\(key)\""), "\(key) remains in \(locale)")
            }
        }
    }

    func testServiceSettingsSeparateCredentialStorageFromNotebookEgress() throws {
        let expectedEgressNotices = [
            "en": "Saving a key does not grant new data sharing. Each Notebook must authorize remote processing separately. Work that a Notebook already authorized and left waiting for a credential may resume only after the key is durably saved and loaded.",
            "zh-Hans": "保存密钥不会授予新的数据外发权限。每个 Notebook 仍须单独授权远端处理；若某项后台任务此前已获该 Notebook 授权，只是在等待凭据，它可能在密钥持久保存并成功加载后继续。",
            "ja": "キーを保存するだけで新たなデータ送信が許可されることはありません。各 Notebook でリモート処理を個別に許可する必要があります。Notebook がすでに許可し、認証情報待ちになっていたバックグラウンド処理は、キーが永続的に保存され読み込まれた後に再開する場合があります。",
        ]
        let requiredKeys = [
            "settings.services.title",
            "settings.services.connection.title",
            "settings.services.no_egress_notice",
            "settings.services.engine.realtime",
            "settings.services.engine.post_stop",
            "settings.services.engine.post_stop_detail",
            "settings.credentials.replace",
            "settings.credentials.delete_confirmation_title",
            "settings.credentials.reset_confirmation_title",
        ]

        for locale in ["en", "zh-Hans", "ja"] {
            for key in requiredKeys {
                let value = try localizedString(locale: locale, key: key)
                XCTAssertNotEqual(value, key, "Missing \(locale) localization for \(key)")
            }

            let egress = try localizedString(
                locale: locale,
                key: "settings.services.no_egress_notice"
            )
            XCTAssertEqual(egress, expectedEgressNotices[locale])

            let postStop = try localizedString(
                locale: locale,
                key: "settings.services.engine.post_stop_detail"
            )
            XCTAssertTrue(postStop.localizedCaseInsensitiveContains("Soniox"))
            XCTAssertTrue(postStop.localizedCaseInsensitiveContains("API"))
        }
    }

    func testDiagnosticsCallsTheseServiceCredentialsNotModelKeys() throws {
        for locale in ["en", "zh-Hans", "ja"] {
            let value = try localizedString(
                locale: locale,
                key: "diagnostics.operational.provider_keys"
            )
            XCTAssertFalse(value.localizedCaseInsensitiveContains("model"))
            XCTAssertFalse(value.contains("模型"))
        }
    }

    func testGlobalSettingsHasNoRecordingConfigurationRouteInMinimalMVP() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let settings = try String(
            contentsOf: root.appendingPathComponent("Settings/FullSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settings.contains("@AppStorage(\"recording.autoTranscribe\")"))
        XCTAssertFalse(settings.contains("@AppStorage(\"recording.remoteRealtimeEnabled\")"))
        XCTAssertFalse(settings.contains("case recording"))
        XCTAssertFalse(settings.contains("RecordingSection"))
        XCTAssertFalse(settings.contains("settings.group.modes"))
        XCTAssertTrue(settings.contains("case services"))
        XCTAssertTrue(settings.contains("ServiceConnectionsSection"))
        XCTAssertFalse(settings.contains("settings.shortcuts.toggle_floating"))
        XCTAssertFalse(settings.contains("settings.shortcuts.cycle_display"))
        XCTAssertFalse(settings.contains("⌃⌥V"))
        XCTAssertFalse(settings.contains("⌃⌥M"))
        XCTAssertFalse(settings.contains("recording.autoSummarize"))
        XCTAssertFalse(settings.contains("recording.defaultTemplate"))
        XCTAssertFalse(settings.contains("settings.recording.auto_summarize"))
        XCTAssertFalse(settings.contains("settings.recording.default_template"))
    }

    func testAudioPrivacyOptionsStateWhatRemainsUsable() {
        let maximum = AudioPrivacyOptionSummary(level: .maximum)

        XCTAssertEqual(maximum.level, .maximum)
        XCTAssertFalse(maximum.title.isEmpty)
        XCTAssertFalse(maximum.storageText.isEmpty)
    }

    func testUserVisibleBrandUsesTitleCaseZulangue() throws {
        for locale in ["en", "zh-Hans", "ja"] {
            XCTAssertEqual(
                try localizedString(locale: locale, key: "app.name"),
                "Zulangue"
            )
            XCTAssertEqual(
                try localizedString(locale: locale, key: "onboarding.brand.name"),
                "Zulangue"
            )
            XCTAssertEqual(
                try localizedString(locale: locale, key: "trust.version_format"),
                "Zulangue · v%@"
            )
        }

        let appProject = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistData = try Data(
            contentsOf: appProject.appendingPathComponent("Zulangue-Info.plist")
        )
        let infoPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(infoPlist["CFBundleDisplayName"] as? String, "Zulangue")
        XCTAssertEqual(infoPlist["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertFalse(infoPlist.values.contains { ($0 as? String) == "zulangue" })
    }

    private func localizedString(locale: String, key: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = projectRoot
            .appendingPathComponent("Zulangue")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")

        let values = NSDictionary(contentsOf: stringsURL) as? [String: String]
        return try XCTUnwrap(values?[key])
    }

    func testSettingsAndOnboardingUnavailableCopyAvoidsImplementationTerms() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue")
        let files = [
            "Settings/FullSettingsView.swift",
            "Settings/DiagnosticsSection.swift",
            "App/OnboardingView.swift"
        ]
        let combined = try files.map { path in
            try String(
                contentsOf: projectRoot.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        XCTAssertTrue(combined.contains("Local app service is not ready yet."))
        XCTAssertFalse(combined.contains("Peer sharing status"))
        XCTAssertFalse(combined.contains("DaemonStatusSection()"))
        XCTAssertTrue(combined.contains("sections: [.general, .shortcuts]"))
        XCTAssertFalse(combined.contains("sections: [.general, .knowledge, .shortcuts]"))
        XCTAssertFalse(combined.contains("\"Core unavailable\""))
        XCTAssertFalse(combined.contains("ZulangueCore unavailable"))
        XCTAssertFalse(combined.contains("Rust policy"))
        XCTAssertFalse(combined.contains("Transport not loaded"))
        XCTAssertFalse(combined.contains("transportInfo.transport"))
    }

    func testSettingsDiagnosticsUseProductCopy() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue")
        let combined = try String(
            contentsOf: projectRoot.appendingPathComponent("Settings/DiagnosticsSection.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(combined.contains("Peer sharing status"))
        XCTAssertFalse(combined.contains("Backend descriptors"))
    }

    func testProviderDiagnosticsTreatsZeroOptionalKeysAsInformational() {
        let state = SettingsProviderDiagnosticsState.resolve([])

        XCTAssertEqual(state.configuredCount, 0)
        XCTAssertEqual(state.mirrorMismatchCount, 0)
        XCTAssertEqual(state.severity, "info")
        XCTAssertNil(
            state.trustKeyState,
            "local-only mode must not project an actionable missing-provider warning"
        )
    }

    func testProviderDiagnosticsStillFlagsConfiguredKeyMirrorMismatch() {
        let state = SettingsProviderDiagnosticsState.resolve([
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: "soniox",
                isSaved: true,
                isActive: false
            ),
        ])

        XCTAssertEqual(state.configuredCount, 1)
        XCTAssertEqual(state.mirrorMismatchCount, 1)
        XCTAssertEqual(state.severity, "warning")
        XCTAssertEqual(state.trustKeyState, "provider_api_key_untested")
    }

    func testProviderDiagnosticsDoesNotCallSavedActiveCredentialHealthy() {
        let state = SettingsProviderDiagnosticsState.resolve([
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: "soniox",
                isSaved: true,
                isActive: true
            ),
        ])

        XCTAssertEqual(state.configuredCount, 1)
        XCTAssertEqual(state.mirrorMismatchCount, 0)
        XCTAssertEqual(state.severity, "info")
        XCTAssertNil(
            state.trustKeyState,
            "loading a saved key does not prove provider connectivity or validity"
        )
    }

}

@MainActor
private final class FakeProviderCredentialSession: ProviderCredentialSessioning {
    var recoveryErrorDescription: String?
    private var saved = true
    private var active = true
    private(set) var clearCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var applyCallCount = 0
    private(set) var lastAppliedValue: String?

    func has(_ account: ProviderCredentialAccount) -> Bool {
        active
    }

    func apply(_ value: String, for account: ProviderCredentialAccount) throws {
        applyCallCount += 1
        lastAppliedValue = value
        saved = true
        active = true
    }

    func clear(_ account: ProviderCredentialAccount) throws {
        clearCallCount += 1
        saved = false
        active = false
    }

    func resetSavedCredentials() throws {
        resetCallCount += 1
        saved = false
        active = false
    }

    func snapshot() -> [ProviderCredentialSnapshot] {
        [
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: ProviderCredentialAccount.soniox.scope,
                isSaved: saved,
                isActive: active
            )
        ]
    }
}

@MainActor
private final class FakeProviderCredentialValidator: ProviderCredentialValidating {
    let result: ProviderConnectionVerificationState
    private(set) var callCount = 0
    private(set) var lastCandidateAfterCall: String?

    init(result: ProviderConnectionVerificationState) {
        self.result = result
    }

    func verify(
        _ candidate: String?,
        for account: ProviderCredentialAccount
    ) async -> ProviderConnectionVerificationState {
        callCount += 1
        // Deliberately do not retain the candidate; this mirrors the production
        // store's secret-lifetime boundary.
        lastCandidateAfterCall = nil
        return result
    }
}
