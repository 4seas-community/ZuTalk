import CoreAudio
import SwiftUI
import XCTest
@testable import ZuTalk

@MainActor
final class SoftwareUpdateVersionTests: XCTestCase {
    /// 一个「检查更新」面板不说自己是哪一版,用户既判断不了刚装上的是不是
    /// 新的,报问题时也报不出版本 —— 而版本与构建号必须成对出现:版本号是
    /// 用户嘴里说的那个,构建号是发布链条与 Sparkle 认的那个。
    func testVersionDisplayCarriesBothMarketingAndBuildNumbers() {
        let display = GeneralSettingsSection.versionDisplay
        let info = Bundle.main.infoDictionary
        let short = try? XCTUnwrap(info?["CFBundleShortVersionString"] as? String)
        let build = try? XCTUnwrap(info?["CFBundleVersion"] as? String)

        XCTAssertTrue(display.contains(short ?? "—"), "要显示版本号: \(display)")
        XCTAssertTrue(display.contains(build ?? "—"), "也要显示构建号: \(display)")
        XCTAssertFalse(display.contains("—"), "两个数都必须取得到")
    }

    /// 版本行必须真的出现在更新卡片里,而不只是存在于一个没人调用的
    /// 辅助函数上。
    func testUpdatesCardShowsTheVersionRow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/Settings/GeneralSettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("settings.updates.current_version"))
        XCTAssertTrue(source.contains("Self.versionDisplay"))
        XCTAssertTrue(source.contains("settings.updates.version"))
    }
}

@MainActor
final class LocalSystemSettingsViewModelTests: XCTestCase {
    /// No section is named for the company that happens to provide a
    /// service today — not even the one that holds the provider keys.
    func testNoSectionNameIsAProviderName() {
        for section in SettingsSection.allCases {
            for account in ProviderCredentialAccount.allCases {
                XCTAssertNotEqual(section.displayName, account.displayName)
            }
        }
    }

    func testSettingsSectionsAreNamedForWhatTheyAreAbout() throws {
        XCTAssertEqual(SettingsSection.allCases, [.account, .general, .advanced])
        let expected = [
            "en": ["Account", "General", "Advanced"],
            "zh-Hans": ["账号", "通用", "高级"],
            "ja": ["アカウント", "一般", "詳細"],
        ]
        for (locale, names) in expected {
            XCTAssertEqual(
                try ["account", "general", "advanced"].map {
                    try localizedString(locale: locale, key: "settings.section.\($0)_name")
                },
                names
            )
        }
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
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
            // The verdict belongs to the account's card, not a second banner.
            XCTAssertEqual(
                store.state(for: .soniox),
                .invalidCredential(Date(timeIntervalSince1970: 100))
            )
            XCTAssertNil(viewModel.operationError)
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
            postStopModelId: "stt-async-v5",
            postStopUsesAsyncFileApi: true
        )

        XCTAssertEqual(engine.realtimeSummary, "Soniox · stt-rt-v5")
        XCTAssertEqual(engine.postStopSummary, "Soniox · stt-async-v5")
        XCTAssertEqual(engine.postStopUsesAsyncFileApi, true)
        XCTAssertEqual(engine.postStopExecutionSummary, String(
            localized: "settings.services.engine.async_file_api"
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let providerSettings = try String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        let credentialSession = try String(
            contentsOf: root.appendingPathComponent("App/ProviderCredentialSession.swift"),
            encoding: .utf8
        )

        // No model catalogue. Choosing a model is a question the product
        // answers, not one it asks; a picker here would make every user
        // research context windows before they could use the feature.
        XCTAssertFalse(providerSettings.contains("Picker("))

        // No model or provider constant written in Swift. Settings may show
        // these values, but only as they come back from the core — two copies
        // drift, and the UI ends up naming a model the core does not use.
        for coreOwnedConstant in [
            "stt-rt-v5", "stt-async-v5", "deepseek-", "soniox.com", "deepseek.com",
        ] {
            XCTAssertFalse(
                providerSettings.contains(coreOwnedConstant),
                "\(coreOwnedConstant) belongs to the core descriptor, not to Swift"
            )
        }
        for unsupportedProvider in ["OpenRouter", "Anthropic", "xAI"] {
            XCTAssertFalse(providerSettings.contains(unsupportedProvider))
        }
        XCTAssertTrue(credentialSession.contains("getNotebookCaptureEngineDescriptor()"))
        XCTAssertTrue(credentialSession.contains("getLanguageModelEngineDescriptor()"))
        XCTAssertTrue(providerSettings.contains("modelStore.engine"))

        // The engine and model names moved to the diagnostics card on the
        // same page. The same rule follows them there: read from the core,
        // never spelled out in Swift.
        let advanced = try String(
            contentsOf: root.appendingPathComponent("Settings/AdvancedSettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(advanced.contains("engineStore.engine"))
        XCTAssertTrue(advanced.contains("modelStore.engine"))
        for coreOwnedConstant in [
            "stt-rt-v5", "stt-async-v5", "deepseek-", "soniox.com", "deepseek.com",
        ] {
            XCTAssertFalse(
                advanced.contains(coreOwnedConstant),
                "\(coreOwnedConstant) belongs to the core descriptor, not to Swift"
            )
        }
    }

    /// The key field is the same height as the pills beside it — one height
    /// for every small control (`PillMetrics.height`), never a field of its
    /// own, smaller size. Before 0.8.3 the field was pinned at 44 pt while
    /// the buttons next to it were whatever the system drew.
    func testProviderCredentialEditorIsAsTallAsThePillsBesideIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let source = try String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        // The key goes into the shared field, hidden as it is typed.
        let fieldStart = try XCTUnwrap(source.range(of: "SettingsField("))
        let fieldEnd = try XCTUnwrap(source[fieldStart.upperBound...].range(of: ".onSubmit(verifyAndCommitDraft)"))
        XCTAssertTrue(source[fieldStart.lowerBound..<fieldEnd.lowerBound].contains("isSecure: true"))
        XCTAssertFalse(source.contains("SecureField("), "the row draws no field of its own")

        let components = try String(
            contentsOf: root.appendingPathComponent("Settings/SettingsComponents.swift"),
            encoding: .utf8
        )
        let sharedStart = try XCTUnwrap(components.range(of: "struct SettingsField: View"))
        let sharedEnd = try XCTUnwrap(components[sharedStart.upperBound...].range(of: "// MARK: - 状态与值"))
        let shared = components[sharedStart.lowerBound..<sharedEnd.lowerBound]
        XCTAssertTrue(shared.contains(".frame(height: PillMetrics.height)"))
        XCTAssertTrue(shared.contains("SecureField(placeholder, text: $text)"))
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

    func testFailedVerificationHintSaysWhatToDoInsteadOfRepeatingTheVerdict() throws {
        let checkedAt = Date(timeIntervalSince1970: 100)
        let failures: [(ProviderConnectionVerificationState, String)] = [
            (.invalidCredential(checkedAt), "invalid_format"),
            (.organizationBalanceExhausted(checkedAt), "organization_balance_exhausted"),
            (.organizationMonthlyBudgetExhausted(checkedAt), "organization_budget_exhausted"),
            (.projectMonthlyBudgetExhausted(checkedAt), "project_budget_exhausted"),
            (.quotaExhausted(checkedAt), "quota_exhausted_format"),
            (.networkUnavailable(checkedAt), "network_unavailable_format"),
            (.rateLimited(checkedAt), "rate_limited_format"),
            (.serviceUnavailable(checkedAt), "service_unavailable_format"),
        ]
        let passing: [ProviderConnectionVerificationState] = [
            .unverified, .checking, .ready(checkedAt),
        ]
        for state in passing {
            XCTAssertNil(state.failureHintFormatKey)
        }

        for (state, verdict) in failures {
            let hintKey = try XCTUnwrap(state.failureHintFormatKey)
            for locale in ["en", "zh-Hans", "ja", "ko", "fr", "es", "de", "th"] {
                let title = try localizedString(
                    locale: locale,
                    key: "settings.credentials.verification.\(verdict)"
                )
                let hint = try localizedString(locale: locale, key: hintKey)
                XCTAssertNotEqual(hint, title, "\(locale) \(hintKey) repeats the status line")
                // The same card shows the DeepSeek key, so the provider is
                // always the account's name, never a hard-coded one.
                XCTAssertEqual(
                    hint.components(separatedBy: "%@").count,
                    2,
                    "\(locale) \(hintKey) must name the provider exactly once"
                )
                XCTAssertFalse(hint.contains("Soniox"), "\(locale) \(hintKey)")
            }
        }
    }

    /// Every verdict the model key can get names the model's provider. The
    /// card used to say "Soniox rejected this key" under the model key too.
    func testModelKeyVerdictsNameTheModelProvider() {
        let checkedAt = Date(timeIntervalSince1970: 100)
        let modelVerdicts: [ProviderConnectionVerificationState] = [
            .invalidCredential(checkedAt),
            .quotaExhausted(checkedAt),
            .networkUnavailable(checkedAt),
            .rateLimited(checkedAt),
            .serviceUnavailable(checkedAt),
        ]
        for state in modelVerdicts {
            let model = ProviderConnectionVerificationFailure(state, account: .deepseek)
                .localizedDescription
            XCTAssertTrue(model.contains("DeepSeek"), model)
            XCTAssertFalse(model.contains("Soniox"), model)

            let capture = ProviderConnectionVerificationFailure(state, account: .soniox)
                .localizedDescription
            XCTAssertTrue(capture.contains("Soniox"), capture)
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
            "capture.settings.remote.credential.saved_inactive",
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
            "en": "Live text — recording in progress",
            "zh-Hans": "正在边录边出字",
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
            .appendingPathComponent("ZuTalk/Resources", isDirectory: true)

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
        // Saving a key and sending audio are two different things; the notice
        // says so, and says exactly when audio does leave.
        let expectedEgressNotices = [
            "en": "Saving a Soniox key sends nothing by itself. Audio goes to Soniox only for recordings with live text on, or when you choose to refine a recording.",
            "zh-Hans": "保存 Soniox 密钥本身不会发送任何数据。只有开了边录边出字的录音，或你手动要求的精修，才会把音频发给 Soniox。",
            "ja": "Soniox キーを保存しただけでは何も送信されません。音声が Soniox に送られるのは、リアルタイム文字起こしをオンにした録音か、自分で清書を実行したときだけです。",
        ]
        let requiredKeys = [
            "settings.section.captions_name",
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
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let settings = try String(
            contentsOf: root.appendingPathComponent("Settings/FullSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settings.contains("@AppStorage(\"recording.autoTranscribe\")"))
        XCTAssertFalse(settings.contains("@AppStorage(\"recording.remoteRealtimeEnabled\")"))
        XCTAssertFalse(settings.contains("case recording"))
        XCTAssertFalse(settings.contains("RecordingSection"))
        XCTAssertFalse(settings.contains("settings.group.modes"))
        // What live text needs (an invite code, or a key) lives under
        // Account and Advanced; neither is a place to configure how
        // recordings behave.
        XCTAssertTrue(settings.contains("case account"))
        XCTAssertTrue(settings.contains("case advanced"))
        XCTAssertFalse(settings.contains("case captions"))
        let advanced = try String(
            contentsOf: root.appendingPathComponent("Settings/AdvancedSettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(advanced.contains("ProviderSettingsView(scope: .captions)"))
        XCTAssertTrue(advanced.contains("ProviderSettingsView(scope: .languageModel)"))
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

    func testUserVisibleBrandUsesTitleCaseZuTalk() throws {
        for locale in ["en", "zh-Hans", "ja"] {
            XCTAssertEqual(
                try localizedString(locale: locale, key: "app.name"),
                "ZuTalk"
            )
            XCTAssertEqual(
                try localizedString(locale: locale, key: "onboarding.brand.name"),
                "ZuTalk"
            )
            XCTAssertEqual(
                try localizedString(locale: locale, key: "trust.version_format"),
                "ZuTalk · v%@"
            )
        }

        let appProject = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistData = try Data(
            contentsOf: appProject.appendingPathComponent("ZuTalk-Info.plist")
        )
        let infoPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(infoPlist["CFBundleDisplayName"] as? String, "ZuTalk")
        XCTAssertEqual(infoPlist["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertFalse(infoPlist.values.contains { ($0 as? String) == "zutalk" })
    }

    private func localizedString(locale: String, key: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = projectRoot
            .appendingPathComponent("ZuTalk")
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
            .appendingPathComponent("ZuTalk")
        let files = [
            "Settings/FullSettingsView.swift",
            "App/OnboardingView.swift",
            "App/ProviderCredentialSession.swift"
        ]
        let combined = try files.map { path in
            try String(
                contentsOf: projectRoot.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        XCTAssertTrue(
            combined.contains(
                "String(localized: \"settings.credentials.error.core_unavailable\")"
            )
        )
        XCTAssertFalse(combined.contains("Peer sharing status"))
        XCTAssertFalse(combined.contains("DaemonStatusSection()"))
        XCTAssertTrue(combined.contains("case account"))
        XCTAssertTrue(combined.contains("case general"))
        XCTAssertTrue(combined.contains("case advanced"))
        XCTAssertFalse(combined.contains("case knowledge"))
        XCTAssertFalse(combined.contains("case diagnostics"))
        XCTAssertFalse(combined.contains("DiagnosticsSection()"))
        XCTAssertFalse(combined.contains("\"Core unavailable\""))
        XCTAssertFalse(combined.contains("ZuTalkCore unavailable"))
        XCTAssertFalse(combined.contains("Rust policy"))
        XCTAssertFalse(combined.contains("Transport not loaded"))
        XCTAssertFalse(combined.contains("transportInfo.transport"))
    }

}

@MainActor
final class AudioInputDeviceTests: XCTestCase {
    func testLiveCoreAudioCatalogProducesStableNonemptyDescriptors() throws {
        let catalog = CoreAudioInputDeviceCatalog()
        let snapshot = try catalog.snapshot()

        for device in snapshot.devices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertNotEqual(device.deviceID, kAudioObjectUnknown)
        }
        if let defaultInputDeviceID = snapshot.defaultInputDeviceID {
            XCTAssertNotEqual(defaultInputDeviceID, kAudioObjectUnknown)
        }
        if let defaultInputDevice = snapshot.defaultInputDevice {
            XCTAssertEqual(
                try catalog.resolveCaptureDevice(
                    uid: nil,
                    cachedDevice: defaultInputDevice
                ),
                defaultInputDevice
            )
            XCTAssertEqual(
                try catalog.resolveCaptureDevice(
                    uid: defaultInputDevice.uid,
                    cachedDevice: defaultInputDevice
                ),
                defaultInputDevice
            )
        }
    }

    func testExplicitSelectionPersistsStableUIDAndResolvesCurrentDeviceID() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [mixer],
                defaultInputDeviceID: mixer.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: mixer.uid)

        let restored = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        XCTAssertEqual(restored.selectedUID, mixer.uid)
        XCTAssertEqual(try restored.resolveDeviceForCapture(), mixer)
        XCTAssertEqual(restored.selectedDeviceLastKnownName, mixer.name)
    }

    func testColdCaptureResolutionUsesOneDeviceLookupWithoutLoadingFullPickerSnapshot() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let builtIn = AudioInputDevice(deviceID: 7, uid: "built-in", name: "Mac Microphone")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [builtIn],
                defaultInputDeviceID: builtIn.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)

        XCTAssertEqual(try store.resolveDeviceForCapture(), builtIn)
        XCTAssertEqual(catalog.snapshotCallCount, 0)
        XCTAssertEqual(catalog.captureResolutionCallCount, 1)
        XCTAssertFalse(store.hasLoadedSnapshot)
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testLoadedPickerSnapshotIsReusedWithoutRescanningEveryCaptureStart() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [mixer],
                defaultInputDeviceID: mixer.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: mixer.uid)

        XCTAssertEqual(try store.resolveDeviceForCapture(), mixer)
        XCTAssertEqual(try store.resolveDeviceForCapture(), mixer)
        XCTAssertEqual(catalog.snapshotCallCount, 1)
        XCTAssertEqual(catalog.captureResolutionCallCount, 2)
        XCTAssertEqual(catalog.cachedDeviceUIDs, [mixer.uid, mixer.uid])
    }

    func testExplicitDeviceReplugResolvesItsNewDeviceIDWithoutDefaultFallback() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let replugged = AudioInputDevice(deviceID: 84, uid: "usb-mixer", name: "USB Mixer")
        let builtIn = AudioInputDevice(deviceID: 7, uid: "built-in", name: "Mac Microphone")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [original, builtIn],
                defaultInputDeviceID: builtIn.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: original.uid)
        catalog.currentSnapshot = AudioInputDeviceSnapshot(
            devices: [replugged, builtIn],
            defaultInputDeviceID: builtIn.deviceID
        )

        XCTAssertEqual(try store.resolveDeviceForCapture(), replugged)
        XCTAssertEqual(store.selectedUID, original.uid)
        XCTAssertNotEqual(try store.resolveDeviceForCapture(), builtIn)
        XCTAssertEqual(catalog.snapshotCallCount, 1)
    }

    func testPreflightingAnotherDeviceDoesNotRewriteSelectedDeviceLastKnownName() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let selected = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let proposed = AudioInputDevice(deviceID: 84, uid: "desk-mic", name: "Desk Mic")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [selected, proposed],
                defaultInputDeviceID: selected.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: selected.uid)

        XCTAssertEqual(try store.resolveDevice(uid: proposed.uid), proposed)
        XCTAssertEqual(store.selectedUID, selected.uid)
        XCTAssertEqual(store.selectedDeviceLastKnownName, selected.name)
    }

    func testExplicitDeviceUnplugAfterSnapshotFailsWithoutUsingSystemDefault() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let builtIn = AudioInputDevice(deviceID: 7, uid: "built-in", name: "Mac Microphone")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [mixer, builtIn],
                defaultInputDeviceID: builtIn.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: mixer.uid)
        catalog.currentSnapshot = AudioInputDeviceSnapshot(
            devices: [builtIn],
            defaultInputDeviceID: builtIn.deviceID
        )

        XCTAssertThrowsError(try store.resolveDeviceForCapture()) { error in
            XCTAssertEqual(
                error as? AudioInputDeviceError,
                .selectedDeviceUnavailable(name: mixer.name)
            )
        }
        XCTAssertEqual(store.selectedUID, mixer.uid)
        XCTAssertEqual(catalog.snapshotCallCount, 1)
        XCTAssertEqual(catalog.captureResolutionCallCount, 1)
        XCTAssertEqual(catalog.cachedDeviceUIDs, [mixer.uid])
    }

    func testLightweightValidationFailureNeverUsesStaleCachedDevice() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [mixer],
                defaultInputDeviceID: mixer.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: mixer.uid)
        catalog.captureResolutionError = .queryFailed(
            operation: "device UID lookup",
            status: kAudioHardwareUnspecifiedError
        )

        XCTAssertThrowsError(try store.resolveDeviceForCapture()) { error in
            XCTAssertEqual(error as? AudioInputDeviceError, catalog.captureResolutionError)
        }
        XCTAssertEqual(catalog.snapshotCallCount, 1)
        XCTAssertEqual(catalog.captureResolutionCallCount, 1)
    }

    func testMissingExplicitSelectionNeverFallsBackToSystemDefault() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let builtIn = AudioInputDevice(deviceID: 7, uid: "built-in", name: "Mac Microphone")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [mixer, builtIn],
                defaultInputDeviceID: builtIn.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.refresh()
        store.select(uid: mixer.uid)

        catalog.currentSnapshot = AudioInputDeviceSnapshot(
            devices: [builtIn],
            defaultInputDeviceID: builtIn.deviceID
        )
        store.refresh()

        XCTAssertTrue(store.isExplicitSelectionUnavailable)
        XCTAssertEqual(store.selectedUID, mixer.uid)
        XCTAssertThrowsError(try store.resolveDeviceForCapture()) { error in
            XCTAssertEqual(
                error as? AudioInputDeviceError,
                .selectedDeviceUnavailable(name: mixer.name)
            )
        }
        XCTAssertEqual(store.selectedUID, mixer.uid)
    }

    func testSystemDefaultSelectionResolvesTheLatestDefaultDevice() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let builtIn = AudioInputDevice(deviceID: 7, uid: "built-in", name: "Mac Microphone")
        let mixer = AudioInputDevice(deviceID: 41, uid: "usb-mixer", name: "USB Mixer")
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(
                devices: [builtIn, mixer],
                defaultInputDeviceID: builtIn.deviceID
            )
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)

        XCTAssertNil(store.selectedUID)
        XCTAssertEqual(try store.resolveDeviceForCapture(), builtIn)

        catalog.currentSnapshot = AudioInputDeviceSnapshot(
            devices: [builtIn, mixer],
            defaultInputDeviceID: mixer.deviceID
        )
        XCTAssertEqual(try store.resolveDeviceForCapture(), mixer)
        XCTAssertEqual(catalog.snapshotCallCount, 0)
        XCTAssertEqual(catalog.captureResolutionCallCount, 2)
    }

    func testInterleavedInputCopiesOnlyTheFirstChannelWithItsStride() throws {
        let ring = MicrophoneCaptureSPSCRing(capacity: 1, maximumFramesPerSlot: 4)
        let interleaved: [Float] = [1, 10, 2, 20, 3, 30]
        let result = interleaved.withUnsafeBufferPointer { samples in
            ring.enqueue(
                samples.baseAddress!,
                frameCount: 3,
                stride: 2,
                sampleTime: 123
            )
        }

        XCTAssertEqual(result, .accepted)
        var captured: [Float] = []
        var sampleTime: Int64 = 0
        XCTAssertTrue(ring.consume { samples, time in
            captured = Array(samples)
            sampleTime = time
        })
        XCTAssertEqual(captured, [1, 2, 3])
        XCTAssertEqual(sampleTime, 123)
    }

    func testSystemAudioChunkerGathersShortIOBuffersIntoWholeBlocks() {
        let chunker = SystemAudioChunker(chunkFrames: 4)
        var blocks: [([Float], Int64)] = []
        let emit: (UnsafePointer<Float>, Int, Int64) -> Void = { block, count, time in
            blocks.append((Array(UnsafeBufferPointer(start: block, count: count)), time))
        }
        let first: [Float] = [1, 2, 3]
        let second: [Float] = [4, 5, 6]
        first.withUnsafeBufferPointer {
            chunker.append($0.baseAddress!, frameCount: 3, stride: 1, sampleTime: 100, emit: emit)
        }
        XCTAssertTrue(blocks.isEmpty)
        second.withUnsafeBufferPointer {
            chunker.append($0.baseAddress!, frameCount: 3, stride: 1, sampleTime: 103, emit: emit)
        }
        XCTAssertEqual(blocks.map(\.0), [[1, 2, 3, 4]])
        XCTAssertEqual(blocks.map(\.1), [100])

        chunker.flush(emit: emit)
        XCTAssertEqual(blocks.map(\.0), [[1, 2, 3, 4], [5, 6]])
        XCTAssertEqual(blocks.map(\.1), [100, 104])
    }

    func testSystemAudioChunkerClosesThePartialBlockAtATimelineJump() {
        let chunker = SystemAudioChunker(chunkFrames: 4)
        var blocks: [([Float], Int64)] = []
        let emit: (UnsafePointer<Float>, Int, Int64) -> Void = { block, count, time in
            blocks.append((Array(UnsafeBufferPointer(start: block, count: count)), time))
        }
        let interleaved: [Float] = [1, 10, 2, 20]
        interleaved.withUnsafeBufferPointer {
            chunker.append($0.baseAddress!, frameCount: 2, stride: 2, sampleTime: 0, emit: emit)
        }
        let later: [Float] = [7]
        later.withUnsafeBufferPointer {
            chunker.append($0.baseAddress!, frameCount: 1, stride: 1, sampleTime: 50, emit: emit)
        }
        chunker.flush(emit: emit)
        XCTAssertEqual(blocks.map(\.0), [[1, 2], [7]])
        XCTAssertEqual(blocks.map(\.1), [0, 50])
    }

    func testSystemAudioResolvesWithoutTheHardwareCatalog() throws {
        let suiteName = "AudioInputDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = FakeAudioInputDeviceCatalog(
            snapshot: AudioInputDeviceSnapshot(devices: [], defaultInputDeviceID: nil)
        )
        let store = AudioInputDeviceStore(catalog: catalog, defaults: defaults)
        store.select(uid: AudioInputDevice.systemAudioUID)

        if SystemAudioCapture.isSupported {
            XCTAssertTrue(try store.resolveDeviceForCapture().isSystemAudio)
            XCTAssertFalse(store.isExplicitSelectionUnavailable)
        } else {
            XCTAssertThrowsError(try store.resolveDeviceForCapture()) { error in
                XCTAssertEqual(error as? AudioInputDeviceError, .systemAudioUnsupported)
            }
        }
        XCTAssertEqual(catalog.captureResolutionCallCount, 0)
        XCTAssertTrue(store.isSystemAudioSelected)
    }

    func testDeviceBindingHappensBeforeReadingFormatAndInstallingTap() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Capture/MicrophoneCapture.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let bind = try XCTUnwrap(source.range(of: "try Self.bind(inputDevice, to: inputNode)"))
        let format = try XCTUnwrap(source.range(of: "inputNode.inputFormat(forBus: 0)"))
        let tap = try XCTUnwrap(source.range(of: "inputNode.installTap("))
        let prepare = try XCTUnwrap(source.range(of: "engine.prepare()", range: tap.upperBound..<source.endIndex))

        XCTAssertLessThan(bind.lowerBound, format.lowerBound)
        XCTAssertLessThan(format.lowerBound, tap.lowerBound)
        XCTAssertLessThan(tap.lowerBound, prepare.lowerBound)
        XCTAssertTrue(source.contains("stride: buffer.stride"))
        XCTAssertTrue(source.contains("channelData[0]"))
        XCTAssertTrue(source.contains("actualDeviceID == requestedDeviceID"))
        XCTAssertTrue(source.contains("uidValue.takeRetainedValue() as String == inputDevice.uid"))
    }

    func testAudioInputCopyIsLocalizedForEverySupportedInterfaceLanguage() throws {
        let keys = [
            "settings.audio_input.title",
            "settings.audio_input.subtitle",
            "settings.audio_input.device",
            "settings.audio_input.channel_one_hint",
            "settings.audio_input.system_default",
            "settings.audio_input.system_default_format",
            "settings.audio_input.unavailable_format",
            "settings.audio_input.refresh",
            "settings.audio_input.active_locked",
            "settings.audio_input.local_scope",
            "settings.audio_input.switching",
            "settings.audio_input.active_switch_hint",
            "settings.audio_input.active_elsewhere",
            "settings.audio_input.error.query_format",
            "settings.audio_input.error.no_device",
            "settings.audio_input.error.unavailable_format",
            "settings.audio_input.error.audio_unit_format",
            "settings.audio_input.error.binding_format",
            "settings.audio_input.error.switch_unavailable",
            "settings.audio_input.system_audio",
            "settings.audio_input.system_audio_hint",
            "settings.audio_input.error.system_audio_unsupported",
            "settings.audio_input.error.system_audio_format",
            "record.page.input",
            "record.page.input_detail_system_audio",
            "record.page.input_detail_microphone_or_meeting",
            "record.page.input_detail_microphone",
            "capture.toast.audio_input_switch_failed",
        ]

        for language in AppLanguage.allCases {
            for key in keys {
                let value = try localizedString(locale: language.rawValue, key: key)
                XCTAssertFalse(value.isEmpty, "Missing \(language.rawValue) localization for \(key)")
                XCTAssertNotEqual(value, key, "Missing \(language.rawValue) localization for \(key)")
            }
        }
    }

    private func localizedString(locale: String, key: String) throws -> String {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources", isDirectory: true)
        let stringsURL = resources
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let values = NSDictionary(contentsOf: stringsURL) as? [String: String]
        return try XCTUnwrap(values?[key])
    }
}

private final class FakeAudioInputDeviceCatalog: AudioInputDeviceCataloging {
    var currentSnapshot: AudioInputDeviceSnapshot
    var captureResolutionError: AudioInputDeviceError?
    private(set) var snapshotCallCount = 0
    private(set) var captureResolutionCallCount = 0
    private(set) var cachedDeviceUIDs: [String?] = []

    init(snapshot: AudioInputDeviceSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() throws -> AudioInputDeviceSnapshot {
        snapshotCallCount += 1
        return currentSnapshot
    }

    func resolveCaptureDevice(
        uid: String?,
        cachedDevice: AudioInputDevice?
    ) throws -> AudioInputDevice? {
        captureResolutionCallCount += 1
        cachedDeviceUIDs.append(cachedDevice?.uid)
        if let captureResolutionError { throw captureResolutionError }
        guard let uid else { return currentSnapshot.defaultInputDevice }
        return currentSnapshot.devices.first { $0.uid == uid }
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

// MARK: - City archive

/// The picker's arithmetic: which cells a month has, how a day's events are
/// grouped, what a filter leaves. Dates are pinned to one time zone so the
/// expectations do not depend on where the tests run.
@MainActor
final class CityCalendarLayoutTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        Int64(date(month, day, hour, minute).timeIntervalSince1970 * 1_000)
    }

    private func event(
        _ id: String,
        start: Int64,
        end: Int64,
        title: String = "",
        place: String = "",
        mine: Bool = false
    ) -> FfiCityEvent {
        FfiCityEvent(
            id: id,
            title: title.isEmpty ? id : title,
            place: place,
            startMs: start,
            endMs: end,
            residentsOnly: false,
            mine: mine
        )
    }

    func testMonthGridStartsOnTheMondayOfTheFirstWeekAndAlwaysHasSixRows() {
        // 1 November 2026 is a Sunday, so its row starts on Monday 26 October.
        let grid = CityCalendarLayout.monthGrid(for: date(11, 13), calendar: calendar)

        XCTAssertEqual(grid.count, 42)
        XCTAssertEqual(grid.first, date(10, 26))
        XCTAssertEqual(grid[6], date(11, 1))
        XCTAssertEqual(grid.last, date(12, 6))
        XCTAssertEqual(calendar.component(.weekday, from: grid[0]), 2)
    }

    func testWeekdayHeadersRunMondayToSunday() {
        XCTAssertEqual(
            CityCalendarLayout.weekdaySymbols(calendar: calendar, locale: Locale(identifier: "en_GB")),
            ["M", "T", "W", "T", "F", "S", "S"]
        )
    }

    func testMonthPagingLandsOnTheFirstOfTheNeighbouringMonth() {
        XCTAssertEqual(CityCalendarLayout.month(date(11, 13), offsetBy: 1, calendar: calendar), date(12, 1))
        XCTAssertEqual(CityCalendarLayout.month(date(11, 13), offsetBy: -1, calendar: calendar), date(10, 1))
    }

    func testAnEventCountsOnTheDayItStartsInThisTimeZone() {
        // 19:00 to midnight belongs to the 13th, not to both days.
        let late = event("late", start: ms(11, 13, 19), end: ms(11, 14, 0))
        let morning = event("morning", start: ms(11, 13, 9), end: ms(11, 13, 10))
        let next = event("next", start: ms(11, 14, 9), end: ms(11, 14, 10))

        let counts = CityCalendarLayout.countsByDay([late, morning, next], calendar: calendar)

        XCTAssertEqual(counts[date(11, 13)], 2)
        XCTAssertEqual(counts[date(11, 14)], 1)
        XCTAssertNil(counts[date(11, 15)])
        XCTAssertEqual(CityCalendarLayout.count(inMonth: date(11, 1), from: [late, morning, next], calendar: calendar), 3)
        XCTAssertEqual(CityCalendarLayout.count(inMonth: date(12, 1), from: [late, morning, next], calendar: calendar), 0)
    }

    func testTheBarUnderADayGrowsWithItsEventsAndStaysInsideTheCell() {
        XCTAssertEqual(CityCalendarLayout.barWidth(count: 0), 0)
        XCTAssertLessThan(CityCalendarLayout.barWidth(count: 1), CityCalendarLayout.barWidth(count: 4))
        XCTAssertLessThan(CityCalendarLayout.barWidth(count: 4), CityCalendarLayout.barWidth(count: 8))
        XCTAssertLessThanOrEqual(CityCalendarLayout.barWidth(count: 200), 24)
    }

    func testSearchCoversTitleAndPlaceAndMineKeepsOnlyOnesOwn() {
        let reading = event("a", start: ms(11, 12, 9), end: ms(11, 12, 11), title: "Reading Club", place: "Library")
        let tea = event("b", start: ms(11, 13, 13), end: ms(11, 13, 16), title: "Tea & Coworking", place: "Gallery Space", mine: true)
        let all = [reading, tea]

        XCTAssertEqual(CityCalendarLayout.filter(all, query: "", mineOnly: false).map(\.id), ["a", "b"])
        XCTAssertEqual(CityCalendarLayout.filter(all, query: "  reading ", mineOnly: false).map(\.id), ["a"])
        XCTAssertEqual(CityCalendarLayout.filter(all, query: "gallery", mineOnly: false).map(\.id), ["b"])
        XCTAssertEqual(CityCalendarLayout.filter(all, query: "", mineOnly: true).map(\.id), ["b"])
        XCTAssertTrue(CityCalendarLayout.filter(all, query: "reading", mineOnly: true).isEmpty)
    }

    func testTodayIsGroupedByTheClock() {
        let now = date(11, 13, 15, 10)
        // Far enough from "now" that no tolerance for early starts or
        // overruns could move them between groups.
        let lecture = event("lecture", start: ms(11, 13, 15), end: ms(11, 13, 17))
        let tea = event("tea", start: ms(11, 13, 13, 30), end: ms(11, 13, 16, 30))
        let evening = event("evening", start: ms(11, 13, 19), end: ms(11, 13, 21))
        let noon = event("noon", start: ms(11, 13, 11), end: ms(11, 13, 12))
        let early = event("early", start: ms(11, 13, 8), end: ms(11, 13, 9))
        let tomorrow = event("tomorrow", start: ms(11, 14, 9), end: ms(11, 14, 10))

        let groups = CityCalendarLayout.groups(
            on: date(11, 13),
            from: [early, noon, tea, lecture, evening, tomorrow],
            now: now,
            recording: nil,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.running, .laterToday, .endedToday])
        XCTAssertEqual(Set(groups[0].events.map(\.id)), ["lecture", "tea"])
        XCTAssertEqual(groups[1].events.map(\.id), ["evening"])
        // The one that just ended comes first.
        XCTAssertEqual(groups[2].events.map(\.id), ["noon", "early"])
        XCTAssertFalse(groups.contains { $0.showsDates })
    }

    func testAnotherDayIsOneUntitledList() {
        let first = event("first", start: ms(11, 20, 9), end: ms(11, 20, 10))
        let second = event("second", start: ms(11, 20, 11), end: ms(11, 20, 13))

        let groups = CityCalendarLayout.groups(
            on: date(11, 20),
            from: [second, first],
            now: date(11, 13, 15, 10),
            recording: nil,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.plain])
        XCTAssertEqual(groups[0].events.map(\.id), ["first", "second"])
        XCTAssertNil(CityEventListView.title(.plain))
    }

    func testFilingAfterwardsPutsEventsThatOverlapTheRecordingFirst() {
        // Recorded yesterday 09:40 to 11:20.
        let recording = CityRecordingSpan(start: date(11, 12, 9, 40), duration: 100 * 60)
        let club = event("club", start: ms(11, 12, 9, 30), end: ms(11, 12, 11, 30))
        let yoga = event("yoga", start: ms(11, 12, 9), end: ms(11, 12, 10, 30))
        let taichi = event("taichi", start: ms(11, 12, 13, 30), end: ms(11, 12, 16))
        let events = [yoga, club, taichi]

        let groups = CityCalendarLayout.groups(
            on: date(11, 12),
            from: events,
            now: date(11, 13, 15, 10),
            recording: recording,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.overlapping, .restOfDay])
        // The one that covers more of the recording leads.
        XCTAssertEqual(groups[0].events.map(\.id), ["club", "yoga"])
        XCTAssertEqual(groups[1].events.map(\.id), ["taichi"])

        XCTAssertEqual(
            CityCalendarLayout.initialDay(now: date(11, 13, 15, 10), recording: recording, calendar: calendar),
            date(11, 12)
        )
        XCTAssertEqual(
            CityCalendarLayout.initialSelection(current: nil, events: events, recording: recording),
            "club"
        )
        // What the recording is already filed under stays selected.
        XCTAssertEqual(
            CityCalendarLayout.initialSelection(current: "taichi", events: events, recording: recording),
            "taichi"
        )
        // Nothing is chosen for a recording that has no span to compare with.
        XCTAssertNil(CityCalendarLayout.initialSelection(current: nil, events: events, recording: nil))
        XCTAssertNil(CityCalendarLayout.initialSelection(current: "gone", events: events, recording: nil))
    }

    func testOtherDaysAreListedOnlyWhileNarrowingDown() {
        let sixth = event("6", start: ms(11, 6, 11), end: ms(11, 6, 13), mine: true)
        let thirteenth = event("13", start: ms(11, 13, 11), end: ms(11, 13, 13), mine: true)
        let twentieth = event("20", start: ms(11, 20, 11), end: ms(11, 20, 13), mine: true)
        let december = event("dec", start: ms(12, 4, 11), end: ms(12, 4, 13), mine: true)
        let mine = [twentieth, sixth, thirteenth, december]

        XCTAssertNil(CityCalendarLayout.otherDays(
            than: date(11, 13), from: mine, month: date(11, 1),
            searching: false, mineOnly: false, calendar: calendar
        ))

        let thisMonth = CityCalendarLayout.otherDays(
            than: date(11, 13), from: mine, month: date(11, 1),
            searching: false, mineOnly: true, calendar: calendar
        )
        XCTAssertEqual(thisMonth?.kind, .mineOtherDays)
        XCTAssertEqual(thisMonth?.events.map(\.id), ["6", "20"])
        XCTAssertEqual(thisMonth?.showsDates, true)

        // A search is not limited to the month on screen.
        let found = CityCalendarLayout.otherDays(
            than: date(11, 13), from: mine, month: date(11, 1),
            searching: true, mineOnly: false, calendar: calendar
        )
        XCTAssertEqual(found?.kind, .foundOtherDays)
        XCTAssertEqual(found?.events.map(\.id), ["6", "20", "dec"])
    }

    func testDayIdentifiersDoNotFollowTheInterfaceLanguage() {
        XCTAssertEqual(CityMonthCalendarView.key(date(11, 13, 15, 10), calendar: calendar), "2026-11-13")
        XCTAssertEqual(CityMonthCalendarView.key(date(1, 5), calendar: calendar), "2026-01-05")
    }
}

/// What the city feature says: errors a person can act on, who signs, what
/// goes into the archive, and that audio does not.
@MainActor
final class CityTextTests: XCTestCase {
    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func account(roles: [String], city: String = "Riverside") -> FfiCityAccount {
        FfiCityAccount(
            server: "city.example",
            cityId: "polis:riverside",
            cityName: city,
            personId: "person-1",
            personName: "Sam",
            roles: roles,
            signedInAtEpoch: 0
        )
    }

    private func filing(
        state: FfiCityFilingState,
        changed: UInt32 = 0,
        errorCode: String? = nil
    ) -> FfiCityFiling {
        FfiCityFiling(
            sessionId: "session-1",
            eventId: "event-1",
            eventTitle: "Language Exchange",
            eventStartMs: Int64(date(11, 6, 11).timeIntervalSince1970 * 1_000),
            channelTitle: nil,
            state: state,
            filedAtEpoch: nil,
            signerName: "Sam",
            languages: [
                FfiCityLanguageCount(language: "en", sentences: 412),
                FfiCityLanguageCount(language: "th", sentences: 96),
            ],
            speakers: 4,
            marks: 7,
            changedSentences: changed,
            errorCode: errorCode,
            webUrl: nil,
            audioWanted: false,
            audioWithheld: false,
            audioDue: false,
            audioPartsPlanned: 0,
            audioPartsFiled: 0,
            audioErrorCode: nil,
            audioRetryAtEpoch: nil
        )
    }

    func testStableCodesAreReadFromWhateverCaseTheCoreThrows() {
        XCTAssertEqual(
            CityText.errorCode(CoreError.ValidationFailed(message: "city.error.offline")),
            "city.error.offline"
        )
        XCTAssertEqual(
            CityText.errorCode(CoreError.NotFound(message: "city.error.unbound")),
            "city.error.unbound"
        )
        XCTAssertEqual(
            CityText.errorCode(CoreError.InternalError(message: "city.error.server")),
            "city.error.server"
        )
        XCTAssertNil(CityText.errorCode(CoreError.InternalError(message: "disk full")))
        XCTAssertNil(CityText.errorCode(CocoaError(.fileNoSuchFile)))
    }

    func testEveryStableCodeHasWordsAndUnknownOnesGetTheGeneralSentence() {
        let general = CityText.message(forCode: nil)
        XCTAssertEqual(general, String(localized: "city.error.generic"))
        XCTAssertEqual(CityText.message(forCode: "city.error.something_new"), general)
        for code in CityText.errorCodes {
            let message = CityText.message(forCode: code)
            XCTAssertNotEqual(message, code, "\(code) has no wording")
            XCTAssertNotEqual(message, general, "\(code) falls through to the general sentence")
        }
    }

    /// "Not allowed" has to say who must do what; with a name, the name the
    /// host is to add is in the sentence.
    func testNotAllowedNamesThePersonTheHostShouldAdd() {
        let named = CityText.message(forCode: "city.error.not_allowed", signer: "Sam")
        XCTAssertTrue(named.contains("Sam"), named)
        XCTAssertFalse(named.contains("%@"), named)
        let unnamed = CityText.message(forCode: "city.error.not_allowed", signer: "")
        XCTAssertFalse(unnamed.contains("%@"), unnamed)
        XCTAssertEqual(
            CityText.describe(CoreError.ValidationFailed(message: "city.error.not_allowed"), signer: "Sam"),
            named
        )
    }

    func testErrorWordingExistsInEveryInterfaceLanguage() throws {
        let keys = CityText.errorCodes.sorted() + ["city.error.generic", "city.error.not_allowed_named_format"]
        for language in Self.languages {
            let strings = try self.strings(language)
            for key in keys {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                // The codes double as keys; none may carry a format specifier
                // that a plain lookup would print as "%@".
                if key != "city.error.not_allowed_named_format" {
                    XCTAssertFalse(value.contains("%"), "\(language) \(key)")
                }
            }
        }
    }

    /// Every `city.` key the views ask for exists, so nothing shows its key.
    func testEveryCityKeyUsedInSourceIsLocalized() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let english = try strings("en")
        let pattern = try NSRegularExpression(pattern: "\"(city\\.[a-z0-9_.]+)\"")
        var checked = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.lastPathComponent.hasPrefix("City")
            && file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                XCTAssertNotNil(
                    english[key],
                    "\(file.lastPathComponent) uses \(key), which has no English string"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    func testOnlyTheWeightiestRoleIsNamedAndTheCityComesFromTheServer() {
        let resident = CityText.role(account(roles: ["resident"]))
        let coordinator = CityText.role(account(roles: ["resident", "inviter", "coordinator"]))
        let founder = CityText.role(account(roles: ["coordinator", "founder", "resident"]))

        for text in [resident, coordinator, founder] {
            XCTAssertTrue(text.contains("Riverside"), text)
        }
        XCTAssertEqual(Set([resident, coordinator, founder]).count, 3)
        // No role at all: just the city, never a made-up title.
        XCTAssertEqual(CityText.role(account(roles: [])), "Riverside")
        XCTAssertEqual(CityText.role(account(roles: [], city: "")), "city.example")
    }

    func testSentencesJoinWithoutASpaceAfterAnIdeographicFullStop() {
        XCTAssertEqual(CityText.joinSentences(["One.", "", "Two."]), "One. Two.")
        XCTAssertEqual(CityText.joinSentences(["甲。", "乙。"]), "甲。乙。")
        XCTAssertEqual(CityText.joinSentences([]), "")
    }

    /// What is filed in whose name. That the audio goes too — and that it is
    /// never said to stay — is pinned in `CityAudioTruthTests`.
    func testTheSummaryNamesTheSignerTheLanguagesAndTheChannel() {
        let options = FfiCityFilingOptions(speakerNames: true, audio: false, automatic: true)

        let plain = CityText.summary(signer: "Sam", languages: ["en", "th"], options: options, channel: nil)
        let withChannel = CityText.summary(signer: "Sam", languages: ["en", "th"], options: options, channel: "Exchange")

        XCTAssertTrue(plain.contains("Sam"))
        XCTAssertTrue(plain.contains("English"))
        XCTAssertTrue(plain.contains(String(localized: "city.summary.names")))
        XCTAssertFalse(plain.contains("Exchange"))
        XCTAssertTrue(withChannel.contains("Exchange"))
        // A recording whose languages are not known yet still says who signs.
        XCTAssertTrue(CityText.summary(signer: "Sam", languages: [], options: options, channel: nil).contains("Sam"))
        XCTAssertEqual(CityText.languageNames(["en", "EN", "und", "th"]).count, 2)
    }

    func testFiledContentListsEachLanguageThenSpeakersAndMarks() {
        let content = CityText.content(filing(state: .filed))

        XCTAssertTrue(content.contains("412"))
        XCTAssertTrue(content.contains("96"))
        XCTAssertEqual(content.components(separatedBy: " · ").count, 4)
    }

    func testFilingRowsSayWhatHappenedNotOnlyByColour() {
        let status = { (filing: FfiCityFiling) in
            CityFilingStatus.resolve(filing, busy: false, offline: false, signer: "Sam")
        }
        let filed = status(filing(state: .filed))
        let changed = status(filing(state: .filed, changed: 6))
        let waiting = status(filing(state: .queued, errorCode: "city.error.offline"))
        let refused = status(filing(state: .failed, errorCode: "city.error.not_allowed"))

        XCTAssertEqual(Set([filed, changed, waiting, refused].map(\.label)).count, 4)
        XCTAssertEqual(Set([filed, changed, waiting, refused].map(\.symbol)).count, 4)
        XCTAssertTrue(changed.label.contains("6"))
        XCTAssertEqual(refused.reason?.contains("Sam"), true)
        // A row is the event, its day, and the status as an icon and a word;
        // what was filed and why is the row's tooltip.
        XCTAssertFalse(CityFilingsCard.detail(filing(state: .filed)).isEmpty)
        XCTAssertTrue(CityFilingsCard.tooltip(filing(state: .filed), status: filed).contains("412"))
        XCTAssertTrue(
            CityFilingsCard.tooltip(filing(state: .failed, errorCode: "city.error.not_allowed"), status: refused)
                .contains("Sam")
        )
    }

    func testEventTimesAreShownInTheGivenTimeZone() {
        let locale = Locale(identifier: "en_GB")
        let start = Int64(date(11, 13, 11).timeIntervalSince1970 * 1_000)
        let end = Int64(date(11, 13, 13).timeIntervalSince1970 * 1_000)
        let event = FfiCityEvent(
            id: "e", title: "Exchange", place: "Event Space",
            startMs: start, endMs: end, residentsOnly: false, mine: true
        )

        XCTAssertEqual(
            CityText.timeRange(startMs: start, endMs: end, calendar: calendar, locale: locale),
            "11:00–13:00"
        )
        let today = CityText.when(event, now: date(11, 13, 15, 10), calendar: calendar, locale: locale)
        XCTAssertEqual(today, String(format: String(localized: "city.event.today_format"), "11:00–13:00"))
        let later = CityText.when(event, now: date(11, 14, 9), calendar: calendar, locale: locale)
        XCTAssertTrue(later.hasSuffix("11:00–13:00"))
        XCTAssertTrue(later.contains("13"))
        XCTAssertNotEqual(later, today)
        XCTAssertTrue(
            CityText.whenAndWhere(event, now: date(11, 13, 15, 10), calendar: calendar, locale: locale)
                .hasSuffix("Event Space")
        )
    }

    func testOnlyWebAddressesAreOpened() {
        XCTAssertEqual(CityText.siteURL(server: " city.example ")?.absoluteString, "https://city.example")
        XCTAssertEqual(CityText.siteURL(server: "http://localhost:8787")?.absoluteString, "http://localhost:8787")
        XCTAssertNil(CityText.siteURL(server: "   "))
        XCTAssertNotNil(CityText.webURL("https://city.example/archive/item"))
        XCTAssertNil(CityText.webURL(nil))
        XCTAssertNil(CityText.webURL("file:///private/etc/hosts"))
        XCTAssertNil(CityText.webURL("javascript:alert(1)"))
        XCTAssertNil(CityText.webURL("https://"))
    }

    /// Copy that must be said truthfully, in every language the app ships.
    func testWithdrawAndSignInCopyStateTheirLimitsEverywhere() throws {
        let keys = [
            "city.withdraw.confirm_short",
            "city.withdraw.confirm_one",
            "city.signin.disclosure",
            "city.signout.confirm_one",
            "city.share.public_note",
            "city.signin.step_scan",
            "city.signin.step_check",
            "settings.section.city_name",
        ]
        for language in Self.languages {
            let strings = try self.strings(language)
            for key in keys {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
            }
            // The public note sets the archive against the 24-hour link.
            XCTAssertTrue(try XCTUnwrap(strings["city.share.public_note"]).contains("24"), language)
        }
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources", isDirectory: true)
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

// MARK: - 交到档案馆:一套状态

/// Where one recording's filing stands. The recording's page, the lists, the
/// Share panel, Settings and the sidebar all read this one answer, so what it
/// says for each state — and what it offers to do next — is pinned here.
@MainActor
final class CityFilingStatusTests: XCTestCase {
    private static let languages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]
    private static let offlineCode = "city.error.offline"
    private static let goneCode = "city.error.event_gone"

    private func filing(
        _ state: FfiCityFilingState,
        session: String = "session-1",
        changed: UInt32 = 0,
        errorCode: String? = nil,
        webUrl: String? = nil,
        filedAt: Int64? = nil
    ) -> FfiCityFiling {
        FfiCityFiling(
            sessionId: session,
            eventId: "event-1",
            eventTitle: "Language Exchange",
            eventStartMs: 1_794_547_200_000,
            channelTitle: nil,
            state: state,
            filedAtEpoch: filedAt,
            signerName: "Sam",
            languages: [FfiCityLanguageCount(language: "en", sentences: 412)],
            speakers: 4,
            marks: 7,
            changedSentences: changed,
            errorCode: errorCode,
            webUrl: webUrl,
            audioWanted: false,
            audioWithheld: false,
            audioDue: false,
            audioPartsPlanned: 0,
            audioPartsFiled: 0,
            audioErrorCode: nil,
            audioRetryAtEpoch: nil
        )
    }

    private func status(
        _ filing: FfiCityFiling?,
        busy: Bool = false,
        offline: Bool = false
    ) -> CityFilingStatus {
        CityFilingStatus.resolve(filing, busy: busy, offline: offline, signer: "Sam")
    }

    func testEachStateOfTheLedgerHasItsOwnStatus() {
        XCTAssertEqual(status(nil).kind, .notFiled)
        XCTAssertEqual(status(filing(.bound)).kind, .chosen)
        XCTAssertEqual(status(filing(.queued, errorCode: Self.offlineCode)).kind, .waiting)
        XCTAssertEqual(status(filing(.filed)).kind, .filed)
        XCTAssertEqual(status(filing(.filed, changed: 6)).kind, .changed)
        XCTAssertEqual(status(filing(.filed, errorCode: Self.goneCode)).kind, .eventGone)
        XCTAssertEqual(status(filing(.failed, errorCode: "city.error.refused")).kind, .failed)
        XCTAssertEqual(status(filing(.withdrawn)).kind, .withdrawn)
        // The archive does not show an item whose event is gone, so that
        // outranks "you changed some sentences": updating it would not help.
        XCTAssertEqual(status(filing(.filed, changed: 6, errorCode: Self.goneCode)).kind, .eventGone)
    }

    func testEveryStatusHasItsOwnWordsAndItsOwnSymbol() {
        let all = [
            status(nil),
            status(filing(.bound)),
            status(filing(.bound), busy: true),
            status(filing(.queued)),
            status(filing(.queued), offline: true),
            status(filing(.filed)),
            status(filing(.filed, changed: 6)),
            status(filing(.filed, errorCode: Self.goneCode)),
            status(filing(.failed, errorCode: "city.error.refused")),
            status(filing(.withdrawn)),
        ]
        // Colour is never the only signal: the words and the icon differ too.
        XCTAssertEqual(Set(all.map(\.label)).count, all.count)
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
        for one in all {
            XCTAssertFalse(one.label.isEmpty)
            XCTAssertFalse(one.label.hasPrefix("city."), "\(one.kind) shows its key")
            XCTAssertFalse(one.label.contains("%"), "\(one.kind) shows a format specifier")
        }
        XCTAssertTrue(status(filing(.filed, changed: 6)).label.contains("6"))
    }

    /// "Filing…" is said only while something is on its way up. An update or
    /// a withdrawal in flight leaves the item in the archive, so it keeps
    /// saying what the archive has.
    func testSendingIsSaidOnlyWhileARecordingIsBeingFiled() {
        for state in [FfiCityFilingState.bound, .queued, .failed, .withdrawn] {
            XCTAssertEqual(status(filing(state), busy: true).kind, .sending, "\(state)")
        }
        XCTAssertEqual(status(nil, busy: true).kind, .sending)
        XCTAssertEqual(status(filing(.filed), busy: true).kind, .filed)
        XCTAssertEqual(status(filing(.filed, changed: 2), busy: true).kind, .changed)
        XCTAssertEqual(status(filing(.filed, errorCode: Self.goneCode), busy: true).kind, .eventGone)

        // Nothing can be started on a recording that has a request in flight.
        let inFlight: [FfiCityFiling?] = [
            nil, filing(.bound), filing(.queued), filing(.failed), filing(.withdrawn),
            filing(.filed, webUrl: "https://city.example/archive/item"), filing(.filed, changed: 2),
        ]
        for row in inFlight {
            XCTAssertNil(status(row, busy: true).primaryAction)
        }
    }

    /// The owner was told "this Mac is offline" while it was online: the route
    /// to the city's server had timed out. Only the system's own verdict may
    /// produce those words; the core's code never does.
    func testOnlyTheSystemMaySayThisMacIsOffline() {
        let unreachable = filing(.queued, errorCode: Self.offlineCode)

        let online = status(unreachable, offline: false)
        XCTAssertEqual(online.label, String(localized: "city.word.waiting"))
        XCTAssertEqual(online.hint, String(localized: "city.status.waiting"))
        XCTAssertEqual(online.primaryAction, .retry)
        XCTAssertNil(online.reason)

        let offline = status(unreachable, offline: true)
        XCTAssertEqual(offline.label, String(localized: "city.word.waiting_offline"))
        XCTAssertEqual(offline.hint, String(localized: "city.status.waiting_offline"))
        XCTAssertEqual(offline.symbol, "wifi.slash")
        // Retrying with no network at all cannot work; it goes by itself later.
        XCTAssertNil(offline.primaryAction)

        // Reachability changes the wording of a queued filing and nothing else.
        for other in [filing(.bound), filing(.filed), filing(.failed, errorCode: Self.offlineCode), filing(.withdrawn)] {
            XCTAssertEqual(status(other, offline: true).label, status(other, offline: false).label)
        }
    }

    func testGreenIsSuccessGoldAsksForALookAndRedIsOnlyFailure() {
        XCTAssertEqual(status(filing(.filed)).tone, .success)
        XCTAssertEqual(status(filing(.filed, changed: 1)).tone, .warning)
        XCTAssertEqual(status(filing(.filed, errorCode: Self.goneCode)).tone, .warning)
        XCTAssertEqual(status(filing(.failed)).tone, .failure)
        let quiet: [CityFilingStatus] = [
            status(nil), status(filing(.bound)), status(filing(.bound), busy: true),
            status(filing(.queued)), status(filing(.queued), offline: true), status(filing(.withdrawn)),
        ]
        for one in quiet {
            XCTAssertEqual(one.tone, .quiet, "\(one.kind)")
        }
        // Orange stays with recording activity; no filing status uses it.
        for tone in [CityFilingStatus.Tone.quiet, .success, .warning, .failure] {
            XCTAssertNotEqual(tone.color, Color.accentOrange)
        }
        XCTAssertEqual(CityFilingStatus.Tone.success.color, Color.success)
        XCTAssertEqual(CityFilingStatus.Tone.warning.color, Color.warning)
        XCTAssertEqual(CityFilingStatus.Tone.failure.color, Color.error)
    }

    func testEachStatusOffersTheOneThingThatMakesSense() throws {
        let url = try XCTUnwrap(URL(string: "https://city.example/archive/c/event-1/b/block-1"))

        XCTAssertEqual(status(nil).primaryAction, .chooseEvent)
        XCTAssertEqual(status(filing(.bound)).primaryAction, .file)
        XCTAssertEqual(status(filing(.withdrawn)).primaryAction, .file)
        XCTAssertEqual(status(filing(.queued)).primaryAction, .retry)
        XCTAssertEqual(status(filing(.filed, webUrl: url.absoluteString)).primaryAction, .open(url))
        XCTAssertEqual(status(filing(.filed, changed: 3, webUrl: url.absoluteString)).primaryAction, .update)
        XCTAssertEqual(status(filing(.failed, errorCode: "city.error.not_allowed")).primaryAction, .retry)
        XCTAssertEqual(status(filing(.failed, errorCode: "city.error.no_transcript")).primaryAction, .retry)

        // Nothing to open when the city gave no page, or gave something that
        // is not a web address.
        XCTAssertNil(status(filing(.filed)).primaryAction)
        XCTAssertNil(status(filing(.filed, webUrl: "file:///private/etc/hosts")).primaryAction)

        // The event is gone from the city: retrying cannot help, and opening
        // would show an empty page. Another event is the way forward.
        XCTAssertEqual(
            status(filing(.filed, errorCode: Self.goneCode, webUrl: url.absoluteString)).primaryAction,
            .chooseEvent
        )
        XCTAssertEqual(status(filing(.failed, errorCode: Self.goneCode)).primaryAction, .chooseEvent)
    }

    func testAReasonIsGivenWhereThePersonNeedsOne() {
        // Why it failed, with the name the host is to add.
        let refused = status(filing(.failed, errorCode: "city.error.not_allowed"))
        XCTAssertEqual(refused.reason, CityText.message(forCode: "city.error.not_allowed", signer: "Sam"))
        XCTAssertEqual(refused.reason?.contains("Sam"), true)

        // Filed, but the event was deleted: say what that means and what
        // changing the event will do.
        let gone = status(filing(.filed, errorCode: Self.goneCode))
        XCTAssertEqual(gone.reason, String(localized: "city.status.event_gone_detail"))
        XCTAssertEqual(
            status(filing(.failed, errorCode: Self.goneCode)).reason,
            String(localized: "city.error.event_gone")
        )

        // An update or withdrawal that did not go through leaves the item
        // filed, with the cause on the record. It must not vanish.
        let stale = status(filing(.filed, changed: 2, errorCode: Self.offlineCode))
        XCTAssertEqual(stale.kind, .changed)
        XCTAssertEqual(stale.reason?.contains(String(localized: "city.error.offline")), true)

        for plain in [status(nil), status(filing(.bound)), status(filing(.queued, errorCode: Self.offlineCode)),
                      status(filing(.filed)), status(filing(.withdrawn))] {
            XCTAssertNil(plain.reason, "\(plain.kind)")
        }
    }

    /// An icon in a list needs the whole sentence for its tooltip and for
    /// VoiceOver: which thing this is about, the status, and the event.
    func testTheSpokenFormNamesTheArchiveTheStatusAndTheEvent() {
        let filed = status(filing(.filed))
        let spoken = filed.described(event: "Language Exchange")

        XCTAssertTrue(spoken.contains(filed.label))
        XCTAssertTrue(spoken.contains("Language Exchange"))
        XCTAssertNotEqual(spoken, filed.label)
        XCTAssertFalse(spoken.contains("%"))
        // Without an event's name it is the status, then the word about its audio.
        XCTAssertTrue(filed.described(event: nil).hasPrefix(filed.label))
        XCTAssertEqual(filed.described(event: ""), filed.described(event: nil))
    }

    func testTheTallyCountsWhatIsInTheArchiveWhatIsWaitingAndWhatNeedsSomeone() {
        let list = [
            filing(.filed, session: "a"),
            filing(.filed, session: "b", changed: 4),
            filing(.queued, session: "c", errorCode: Self.offlineCode),
            filing(.bound, session: "d"),
            filing(.failed, session: "e", errorCode: "city.error.refused"),
            filing(.filed, session: "f", errorCode: Self.goneCode),
            filing(.bound, session: "g"),
            filing(.withdrawn, session: "h"),
        ]
        // "d" is being filed right now: on its way, neither merely chosen nor
        // stuck in the queue.
        let tally = CityFilingTally.count(list, busy: ["d"])

        XCTAssertEqual(
            tally,
            CityFilingTally(filed: 2, sending: 1, waiting: 1, failed: 1, eventGone: 1, chosen: 1)
        )
        let summary = tally.summary ?? ""
        XCTAssertEqual(summary.components(separatedBy: " · ").count, 6)
        XCTAssertFalse(summary.contains("%"))

        // Only what there is gets said; nothing at all when nothing is listed.
        XCTAssertEqual(CityFilingTally(filed: 3).summary?.components(separatedBy: " · ").count, 1)
        XCTAssertNil(CityFilingTally().summary)
        XCTAssertNil(CityFilingTally.count([filing(.withdrawn)], busy: []).summary)
    }

    /// The sidebar says one thing: the most pressing. Nothing when all is well.
    func testTheSidebarLineAppearsOnlyWhenSomethingIsPendingOrWrong() {
        XCTAssertNil(CityFilingTally().attention)
        XCTAssertNil(CityFilingTally(filed: 5, chosen: 2).attention)

        // The few seconds of an ordinary upload are not a queue.
        let sending = CityFilingTally(filed: 5, sending: 1).attention
        XCTAssertEqual(sending?.tone, .quiet)
        XCTAssertEqual(sending?.text.contains("1"), true)

        let waiting = CityFilingTally(filed: 5, sending: 1, waiting: 2).attention
        XCTAssertEqual(waiting?.tone, .quiet)
        XCTAssertEqual(waiting?.text.contains("2"), true)

        let gone = CityFilingTally(waiting: 2, eventGone: 1).attention
        XCTAssertEqual(gone?.tone, .warning)
        XCTAssertEqual(gone?.text.contains("1"), true)

        let failed = CityFilingTally(waiting: 2, failed: 3, eventGone: 1).attention
        XCTAssertEqual(failed?.tone, .failure)
        XCTAssertEqual(failed?.text.contains("3"), true)

        XCTAssertEqual(Set([sending?.text, waiting?.text, gone?.text, failed?.text]).count, 4)
    }

    /// Settings is where every filing can be dealt with: one pill for the
    /// thing most worth doing, and each row's ⋯ holds the rest.
    func testEachSettingsRowOffersWhatCanBeDoneWithIt() throws {
        let url = try XCTUnwrap(URL(string: "https://city.example/archive/item"))
        let menu = { (filing: FfiCityFiling) in
            CityFilingsCard.menu(for: self.status(filing), filing: filing)
        }
        let pill = { (filing: FfiCityFiling) in
            CityFilingsCard.pill(for: self.status(filing))
        }

        // A choice not acted on yet: file it (or retry), change it, or drop it.
        XCTAssertEqual(pill(filing(.bound)), .file)
        XCTAssertEqual(pill(filing(.withdrawn)), .file)
        XCTAssertEqual(pill(filing(.queued)), .retry)
        for state in [FfiCityFilingState.bound, .queued, .withdrawn] {
            XCTAssertEqual(menu(filing(state)), [.changeEvent, .drop, .showRecording], "\(state)")
        }
        XCTAssertEqual(pill(filing(.failed, errorCode: "city.error.not_allowed")), .retry)
        XCTAssertEqual(
            menu(filing(.failed, errorCode: "city.error.not_allowed")),
            [.changeEvent, .drop, .showRecording]
        )
        // What is in the archive: opening it and withdrawing it are in the
        // menu. No pill when nothing is needed.
        XCTAssertNil(pill(filing(.filed, webUrl: url.absoluteString)))
        XCTAssertEqual(
            menu(filing(.filed, webUrl: url.absoluteString)),
            [.open(url), .withdraw, .showRecording]
        )
        XCTAssertEqual(pill(filing(.filed, changed: 2, webUrl: url.absoluteString)), .update)
        XCTAssertEqual(
            menu(filing(.filed, changed: 2, webUrl: url.absoluteString)),
            [.open(url), .withdraw, .showRecording]
        )
        // Event gone: the pill changes the event. The menu does not offer a
        // page that would be empty.
        XCTAssertEqual(pill(filing(.filed, errorCode: Self.goneCode, webUrl: url.absoluteString)), .changeEvent)
        XCTAssertEqual(
            menu(filing(.filed, errorCode: Self.goneCode, webUrl: url.absoluteString)),
            [.withdraw, .showRecording]
        )
        XCTAssertEqual(pill(filing(.failed, errorCode: Self.goneCode)), .changeEvent)
        XCTAssertEqual(menu(filing(.failed, errorCode: Self.goneCode)), [.retry, .drop, .showRecording])

        // Text filed, audio never filed: the pill adds the audio. This is the
        // only way audio reaches something filed before 0.8.3.
        var textOnly = filing(.filed, webUrl: url.absoluteString)
        textOnly.audioWanted = true
        XCTAssertEqual(pill(textOnly), .fileAudio)
        XCTAssertEqual(menu(textOnly), [.open(url), .withdraw, .showRecording])
        // Changed sentences come first; adding the audio is then in the menu.
        textOnly.changedSentences = 2
        XCTAssertEqual(pill(textOnly), .update)
        XCTAssertEqual(menu(textOnly), [.open(url), .fileAudio, .withdraw, .showRecording])
        // The city refused the audio: retrying it is offered, the text is untouched.
        var refused = filing(.filed, webUrl: url.absoluteString)
        refused.audioWanted = true
        refused.audioDue = true
        refused.audioErrorCode = "city.error.audio_refused"
        XCTAssertEqual(pill(refused), .retryAudio)

        // The pill is never repeated in the menu, and every action has a word.
        let rows = [
            filing(.bound), filing(.queued), filing(.failed), filing(.filed, changed: 1),
            filing(.failed, errorCode: Self.goneCode), textOnly, refused,
        ]
        for row in rows {
            let resolved = status(row)
            let listed = CityFilingsCard.menu(for: resolved, filing: row)
            if let taken = CityFilingsCard.pill(for: resolved) {
                XCTAssertFalse(listed.contains(taken), "\(resolved.kind)")
            }
            for action in listed + [CityFilingsCard.pill(for: resolved)].compactMap({ $0 }) {
                XCTAssertFalse(CityFilingsCard.title(action).hasPrefix("city."), "\(action)")
                XCTAssertFalse(CityFilingsCard.symbol(action).isEmpty)
                XCTAssertFalse(CityFilingsCard.identifier(action).isEmpty)
            }
        }
    }

    /// The list of all filings never counts changed sentences (that means
    /// reading a whole transcript); a count read for one recording must
    /// survive the next reload of the list.
    func testACountOfChangedSentencesSurvivesAReloadOfTheList() {
        let known = [
            "edited": filing(.filed, session: "edited", changed: 6, filedAt: 100),
            "refiled": filing(.filed, session: "refiled", changed: 3, filedAt: 100),
            "withdrawn": filing(.filed, session: "withdrawn", changed: 2, filedAt: 100),
        ]
        let reloaded = [
            filing(.filed, session: "edited", filedAt: 100),
            // Filed again since: the old count describes another filing.
            filing(.filed, session: "refiled", filedAt: 200),
            filing(.withdrawn, session: "withdrawn", filedAt: 100),
            filing(.filed, session: "new", filedAt: 100),
        ]

        let merged = CityStore.carryingChangedCounts(from: known, into: reloaded)

        XCTAssertEqual(merged.map(\.sessionId), ["edited", "refiled", "withdrawn", "new"])
        XCTAssertEqual(merged.map(\.changedSentences), [6, 0, 0, 0])
        XCTAssertEqual(merged[2].state, .withdrawn)
    }

    func testComingBackToTheAppRetriesQueuedFilingsButNotInABurst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let gap = CityStore.activationRetryGap

        XCTAssertFalse(CityStore.retriesOnActivation(queued: false, lastRetryAt: nil, now: now))
        XCTAssertTrue(CityStore.retriesOnActivation(queued: true, lastRetryAt: nil, now: now))
        XCTAssertFalse(
            CityStore.retriesOnActivation(queued: true, lastRetryAt: now.addingTimeInterval(-gap / 2), now: now)
        )
        XCTAssertTrue(
            CityStore.retriesOnActivation(queued: true, lastRetryAt: now.addingTimeInterval(-gap), now: now)
        )
        // While anything is queued it is retried every two minutes.
        XCTAssertEqual(CityStore.retryInterval, 120)
    }

    func testStatusWordingExistsInEveryInterfaceLanguage() throws {
        let plain = [
            "city.status.not_filed", "city.status.chosen", "city.status.sending",
            "city.status.waiting", "city.status.waiting_offline", "city.status.filed",
            "city.status.event_gone", "city.status.event_gone_detail", "city.status.failed",
            "city.status.withdrawn", "city.status.open_share_hint", "city.sidebar.hint",
            "city.action.drop", "city.action.show_recording", "city.error.event_gone",
            "city.toast.update_failed", "city.toast.withdraw_failed", "city.toast.move_failed",
        ]
        let counted = [
            "city.status.changed_format", "city.tally.filed_format", "city.tally.sending_format",
            "city.tally.waiting_format", "city.tally.failed_format", "city.tally.event_gone_format",
            "city.tally.chosen_format", "city.sidebar.sending_format", "city.sidebar.waiting_format",
            "city.sidebar.failed_format", "city.sidebar.event_gone_format",
        ]
        for language in Self.languages {
            let strings = try self.strings(language)
            for key in plain {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                XCTAssertFalse(value.contains("%"), "\(language) \(key)")
            }
            for key in counted {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertTrue(value.contains("%lld"), "\(language) \(key)")
            }
            let named = try XCTUnwrap(strings["city.status.for_event_format"], language)
            XCTAssertTrue(named.contains("%1$@") && named.contains("%2$@"), language)
            // The two waiting labels must not read alike: one of them claims
            // the Mac has no network.
            XCTAssertNotEqual(strings["city.status.waiting"], strings["city.status.waiting_offline"], language)
        }
    }

    /// `city.error.offline` means the city's server could not be reached. It
    /// says nothing about this Mac, so its wording must not either: the
    /// remedy is to wait or retry.
    func testNotReachingTheCityIsNeverWordedAsThisMacBeingOffline() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        // Said from the core's code alone, with no word from the system.
        let fromTheCoreAlone = [
            "city.error.offline", "city.status.waiting", "city.word.waiting", "city.toast.queued",
            "city.picker.empty_never", "city.when.automatic_detail",
        ]
        for key in fromTheCoreAlone {
            let en = try XCTUnwrap(english[key], key)
            let zh = try XCTUnwrap(chinese[key], key)
            XCTAssertFalse(en.contains("this Mac") || en.contains("This Mac"), "\(key): \(en)")
            XCTAssertFalse(en.localizedCaseInsensitiveContains("online"), "\(key): \(en)")
            XCTAssertFalse(en.localizedCaseInsensitiveContains("connect to the internet"), "\(key): \(en)")
            XCTAssertFalse(zh.contains("这台 Mac"), "\(key): \(zh)")
            XCTAssertFalse(zh.contains("联网"), "\(key): \(zh)")
            XCTAssertFalse(zh.contains("断网"), "\(key): \(zh)")
        }
        XCTAssertEqual(
            chinese["city.error.offline"],
            "连不上城的服务器。过一会儿再试；一直不行就看看网络。"
        )
        XCTAssertEqual(
            chinese["city.error.event_gone"],
            "这场活动在城里已经删除或取消了。换一场活动，再交一次。"
        )
        // Chinese says 「文字稿」 for a transcript throughout; 「转录稿」 is the
        // old name (docs/product/interface-layers.md, 用词).
        for (key, value) in chinese where key.hasPrefix("city.") {
            XCTAssertFalse(value.contains("转录稿"), "\(key): \(value)")
        }
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Resources", isDirectory: true)
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

// MARK: - 哪场活动算「现在正在进行」

/// The Record page preselects an event only when exactly one is running, so
/// what counts as "running" decides whether hosts get a ready-made choice or
/// a wrong one.
@MainActor
final class CityEventMatchingTests: XCTestCase {
    private let minute: Int64 = 60_000
    private let hour: Int64 = 3_600_000
    private let noon: Int64 = 1_794_547_200_000

    private func at(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }

    private func event(_ id: String, start: Int64, end: Int64, mine: Bool = false) -> FfiCityEvent {
        FfiCityEvent(
            id: id,
            title: id,
            place: "",
            startMs: start,
            endMs: end,
            residentsOnly: false,
            mine: mine
        )
    }

    func testAnEventCountsFromShortlyBeforeItStartsUntilShortlyAfterItEnds() {
        let talk = event("talk", start: noon, end: noon + 2 * hour)
        let ids = { (ms: Int64) in
            CityEventMatching.runningNow([talk], now: self.at(ms)).map(\.id)
        }
        XCTAssertEqual(ids(noon - 16 * minute), [], "too early to be this event")
        XCTAssertEqual(ids(noon - 15 * minute), ["talk"], "people press Record a little early")
        XCTAssertEqual(ids(noon + hour), ["talk"])
        XCTAssertEqual(ids(noon + 2 * hour + 20 * minute), ["talk"], "events run over")
        XCTAssertEqual(ids(noon + 2 * hour + 21 * minute), [])
    }

    func testASeasonLongEventIsNeverChosenForYou() {
        let season = event("season", start: noon - 20 * 24 * hour, end: noon + 29 * 24 * hour)
        let talk = event("talk", start: noon, end: noon + 2 * hour)
        XCTAssertEqual(
            CityEventMatching.runningNow([season], now: at(noon + hour)).map(\.id),
            [],
            "an umbrella event is running every day; choosing it would be a guess"
        )
        XCTAssertEqual(
            CityEventMatching.automaticChoice([season, talk], now: at(noon + hour))?.id,
            "talk",
            "and it must not stop the one real session from being chosen"
        )
    }

    func testNothingIsChosenWhenSeveralEventsRunAtOnce() {
        let hall = event("hall", start: noon, end: noon + 2 * hour)
        let gallery = event("gallery", start: noon - hour, end: noon + hour)
        XCTAssertNil(CityEventMatching.automaticChoice([hall, gallery], now: at(noon + 10 * minute)))
        XCTAssertNil(CityEventMatching.automaticChoice([], now: at(noon)))
    }

    func testYourOwnEventComesFirstThenTheOneThatJustStarted() {
        let earlier = event("earlier", start: noon - hour, end: noon + hour)
        let justStarted = event("just-started", start: noon, end: noon + 2 * hour)
        let mine = event("mine", start: noon - 2 * hour, end: noon + hour, mine: true)
        XCTAssertEqual(
            CityEventMatching.runningNow([earlier, justStarted, mine], now: at(noon + 5 * minute)).map(\.id),
            ["mine", "just-started", "earlier"]
        )
    }

    func testAnEventWithoutAnEndIsTreatedAsTwoHours() {
        let open = event("open", start: noon, end: noon)
        XCTAssertEqual(CityEventMatching.runningNow([open], now: at(noon + hour)).map(\.id), ["open"])
        XCTAssertEqual(CityEventMatching.runningNow([open], now: at(noon + 3 * hour)).map(\.id), [])
    }

    func testFilingLaterPutsTheEventThatOverlapsTheRecordingMostFirst() {
        let morning = event("morning", start: noon - 3 * hour, end: noon - hour)
        let midday = event("midday", start: noon - hour, end: noon + hour)
        let evening = event("evening", start: noon + 6 * hour, end: noon + 8 * hour)
        let found = CityEventMatching.overlapping(
            [morning, midday, evening],
            recordingStart: at(noon - 90 * minute),
            duration: 2 * 3_600
        )
        XCTAssertEqual(found.map(\.id), ["midday", "morning"])
    }
}

// MARK: - 0.8.2: three sections, the account, first launch

/// The strings of one interface language, read from the source tree so a test
/// can check all eight whatever language the test host runs in.
private func settingsStrings(_ language: String) throws -> [String: String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZuTalk/Resources/\(language).lproj/Localizable.strings")
    return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
}

private let settingsLanguages = ["en", "th", "ja", "ko", "fr", "es", "de", "zh-Hans"]

@MainActor
final class SettingsThreeSectionsTests: XCTestCase {
    /// Account, General, Advanced, in that order, and nothing else: the
    /// sidebar lists `allCases`.
    func testThereAreExactlyThreeSectionsInOrder() {
        XCTAssertEqual(SettingsSection.allCases, [.account, .general, .advanced])
        XCTAssertEqual(Set(SettingsSection.allCases.map(\.id)).count, 3)
    }

    func testSettingsOpensOnAccountWhenNothingWasAskedFor() {
        XCTAssertEqual(SettingsRouter.defaultSection, .account)
        XCTAssertEqual(SettingsRouter().section, .account)
    }

    func testOpeningSettingsAtASectionLandsOnIt() {
        let router = SettingsRouter.shared
        let before = router.section
        defer { router.section = before }
        let store = MainNavigationStore()

        store.openSettings(section: .advanced)
        XCTAssertEqual(router.section, .advanced)
        store.openSettings(section: .account)
        XCTAssertEqual(router.section, .account)
        XCTAssertEqual(store.activeTab, .config)
    }

    func testEverySectionHasItsOwnNameInEveryLanguage() throws {
        for language in settingsLanguages {
            let strings = try settingsStrings(language)
            let names = try ["account", "general", "advanced"].map {
                try XCTUnwrap(strings["settings.section.\($0)_name"], "\(language) \($0)")
            }
            XCTAssertEqual(Set(names).count, 3, "\(language): \(names)")
        }
    }

    /// Which page holds what. Account has the identity, the invite code, the
    /// devices and the archive; the language-model key left General; Advanced
    /// opens with the two keys and ends with diagnostics.
    func testEachSectionHoldsWhatPeopleLookForThere() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk/Settings", isDirectory: true)
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func positions(of parts: [String], in text: String) throws -> [String.Index] {
            try parts.map { try XCTUnwrap(text.range(of: $0), "\($0) is missing").lowerBound }
        }

        let account = try source("AccountSettingsSection.swift")
        let accountOrder = try positions(
            of: [
                "CityIdentitySection()", "CommunityInviteSettingsCard()",
                "DevicesSettingsSection()", "CityArchiveSection()",
            ],
            in: account
        )
        XCTAssertEqual(accountOrder, accountOrder.sorted())

        let shell = try source("FullSettingsView.swift")
        XCTAssertFalse(shell.contains("ProviderSettingsView("))

        let advanced = try source("AdvancedSettingsSection.swift")
        let advancedOrder = try positions(
            of: [
                "ProviderSettingsView(scope: .captions)", "ProviderSettingsView(scope: .languageModel)",
                "SharingSettingsSection()", "BackupSettingsCard()", "SettingsDiagnosticsCard()",
            ],
            in: advanced
        )
        XCTAssertEqual(advancedOrder, advancedOrder.sorted())

        // Backup moved out of the devices block; its codes are still pasted
        // there, so its hints must send people to the right page.
        XCTAssertFalse(try source("DevicesSettingsSection.swift").contains("BackupSettingsCard()"))
        let backup = try source("BackupSettingsCard.swift")
        XCTAssertTrue(backup.contains("backup.code_hint_account"))
        XCTAssertTrue(backup.contains("backup.restore_explain_account"))
    }

    /// The account page never names a provider: someone on an invite code
    /// does not need to know who is behind it.
    func testAccountCopyNamesNoProvider() throws {
        let accountKeys = [
            "settings.account.signin_title", "settings.account.signin_detail",
            "settings.account.identity_title", "city.archive.title", "city.archive.subtitle",
            "onboarding.step.live_text", "settings.live_text.source.invite",
            "settings.live_text.source.invite_time_format", "settings.live_text.source.invite_spent",
            "settings.live_text.source.own_key", "settings.live_text.source.nothing",
            "settings.live_text.shared_detail", "settings.live_text.invite_field_label",
            "settings.live_text.invite_hint", "community_invite.remaining_recordable_format",
            "settings.live_text.status.spent", "settings.live_text.status.own_key", "captions_choice.off",
            "settings.live_text.use_invite", "settings.live_text.use_own_key",
            "settings.group.devices", "settings.account.devices_subtitle",
            "settings.devices.this_mac_label", "settings.devices.pairing_code",
            "settings.account.devices_add_subtitle", "sidebar.account.sign_in", "sidebar.account.hint",
        ]
        for language in settingsLanguages {
            let strings = try settingsStrings(language)
            for key in accountKeys {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                for account in ProviderCredentialAccount.allCases {
                    XCTAssertFalse(
                        value.localizedCaseInsensitiveContains(account.displayName),
                        "\(language) \(key) names \(account.displayName)"
                    )
                }
            }
        }
    }
}

@MainActor
final class LiveTextSourceTests: XCTestCase {
    private func source(
        inviteActive: Bool = false,
        inviteEnabled: Bool = false,
        remaining: Int? = nil,
        lanes: Int = 1,
        ownKey: Bool = false
    ) -> LiveTextSource {
        .resolve(
            inviteActive: inviteActive,
            inviteEnabled: inviteEnabled,
            remainingSeconds: remaining,
            laneCount: lanes,
            hasOwnKey: ownKey
        )
    }

    func testNothingRedeemedAndNoKeyMeansAudioOnly() {
        XCTAssertEqual(source(), .nothing)
        XCTAssertFalse(source().powersLiveText)
    }

    func testAnInviteThatIsOnComesBeforeYourOwnKey() {
        XCTAssertEqual(
            source(inviteActive: true, inviteEnabled: true, ownKey: true),
            .invite(recordableSeconds: nil)
        )
        XCTAssertTrue(source(inviteActive: true, inviteEnabled: true).powersLiveText)
    }

    /// Invite time is spent once per connection, so the sentence gives what
    /// can actually be recorded: the same figure the sidebar has always shown.
    func testRemainingTimeIsDividedByTheConnectionsTheNextRecordingOpens() {
        XCTAssertEqual(
            source(inviteActive: true, inviteEnabled: true, remaining: 3 * 3_600, lanes: 3),
            .invite(recordableSeconds: 3_600)
        )
        XCTAssertEqual(
            source(inviteActive: true, inviteEnabled: true, remaining: 5_400, lanes: 1),
            .invite(recordableSeconds: CommunityInviteSession.wallClockRecordableSeconds(
                remainingSeconds: 5_400,
                laneCount: 1
            ))
        )
    }

    func testAnInviteSwitchedOffOrNeverRedeemedFallsToYourOwnKey() {
        XCTAssertEqual(source(inviteActive: true, inviteEnabled: false, remaining: 3_600, ownKey: true), .ownKey)
        XCTAssertEqual(source(inviteActive: false, inviteEnabled: true, ownKey: true), .ownKey)
        XCTAssertEqual(source(inviteActive: true, inviteEnabled: false, remaining: 3_600), .nothing)
    }

    /// A spent invite refuses the next start; a recording then runs on the
    /// saved key when there is one, and has no live text when there is not.
    func testASpentInviteFallsToYourOwnKeyOrSaysItIsSpent() {
        XCTAssertEqual(source(inviteActive: true, inviteEnabled: true, remaining: 0, ownKey: true), .ownKey)
        XCTAssertEqual(source(inviteActive: true, inviteEnabled: true, remaining: 0), .inviteSpent)
        XCTAssertFalse(LiveTextSource.inviteSpent.powersLiveText)
    }

    func testTheSentenceCarriesHoursAndMinutes() {
        let sentence = LiveTextSource.invite(recordableSeconds: 29 * 3_600 + 30 * 60 + 59).sentence
        XCTAssertEqual(sentence, String(
            format: String(localized: "settings.live_text.source.invite_time_format"),
            Int64(29),
            Int64(30)
        ))
        XCTAssertTrue(sentence.contains("29"), sentence)
        XCTAssertTrue(sentence.contains("30"), sentence)
        XCTAssertFalse(sentence.contains("%"), sentence)
    }

    func testEveryStateHasItsOwnSentence() {
        let sentences = [
            LiveTextSource.invite(recordableSeconds: nil),
            .invite(recordableSeconds: 60),
            .inviteSpent,
            .ownKey,
            .nothing,
        ].map(\.sentence)
        XCTAssertEqual(Set(sentences).count, sentences.count)
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.hasPrefix("settings."), "\(sentence) is a missing key")
        }
    }

    /// "Your own key" means a key the core has loaded, the same thing a
    /// recording checks when it starts.
    func testTheCurrentAnswerReadsWhetherAKeyIsLoaded() throws {
        let session = FakeProviderCredentialSession()
        let invite = CommunityInviteSession.shared
        try XCTSkipIf(invite.isActive && invite.isEnabled, "an invite is active in this environment")

        XCTAssertEqual(LiveTextSource.current(invite: invite, credentials: session), .ownKey)
        try session.clear(.soniox)
        XCTAssertEqual(LiveTextSource.current(invite: invite, credentials: session), .nothing)
    }
}

@MainActor
final class OnboardingLiveTextStepTests: XCTestCase {
    /// Welcome, what live text needs, the microphone, done — and the second
    /// step can be skipped without anything having been entered.
    ///
    /// "Done" is remembered in a suite of this test's own: under test the
    /// standard domain is the installed app's real preferences.
    func testSkippingTheSecondStepStillReachesTheEnd() throws {
        let suiteName = "OnboardingLiveTextStepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OnboardingController(defaults: defaults, openSystemSettings: { _ in })
        XCTAssertEqual(controller.phase, .welcome)

        controller.goToLiveText()
        XCTAssertEqual(controller.phase, .liveText)

        controller.skipLiveText()
        XCTAssertEqual(controller.phase, .permissions)
        // Skipping remembers nothing: no choice, no key, not "done" yet.
        XCTAssertNil(defaults.persistentDomain(forName: suiteName))

        controller.finish()
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertTrue(defaults.bool(forKey: OnboardingController.completedKey))
        XCTAssertFalse(OnboardingController.shouldShowOnboarding(defaults: defaults))
    }

    func testTheSecondStepLeadsWithTheInviteCode() {
        XCTAssertEqual(OnboardingLiveTextMode.initial(inviteActive: false, hasOwnKey: false), .inviteCode)
        XCTAssertEqual(OnboardingLiveTextMode.initial(inviteActive: true, hasOwnKey: false), .inviteCode)
        XCTAssertEqual(OnboardingLiveTextMode.initial(inviteActive: true, hasOwnKey: true), .inviteCode)
        // Walking through it again with only a key of one's own: that side
        // is shown straight away.
        XCTAssertEqual(OnboardingLiveTextMode.initial(inviteActive: false, hasOwnKey: true), .ownKey)
    }

    /// Once access has been refused macOS never asks again, so asking again
    /// did nothing. The button now opens the Microphone privacy pane.
    func testADeniedMicrophoneOpensItsSystemSettingsPane() throws {
        var opened: [AppPermission] = []
        // Nothing here remembers anything, but the controller is still kept
        // off the real preferences.
        let suiteName = "OnboardingLiveTextStepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OnboardingController(
            defaults: defaults,
            openSystemSettings: { opened.append($0) }
        )

        controller.permissionStatuses[.microphone] = .denied
        controller.resolvePermission(.microphone)
        XCTAssertEqual(opened, [.microphone])

        controller.permissionStatuses[.microphone] = .granted
        controller.resolvePermission(.microphone)
        XCTAssertEqual(opened, [.microphone])

        XCTAssertEqual(
            AppPermission.microphone.settingsUrl.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    func testFirstLaunchHasNoDecorativeCodesAndNoSignIn() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/App/OnboardingView.swift"),
            encoding: .utf8
        )
        for code in ["ZL-LIVE-01", "ZL-KEY-02", "ZL-MIC-03", "ZL-DONE", "STT-RT-V5"] {
            XCTAssertFalse(source.contains(code), "\(code) is still drawn")
        }
        // Signing in gives nobody anything they need before a first
        // recording; it is one tap away in Settings.
        XCTAssertFalse(source.contains("CitySignInCard"))
        XCTAssertFalse(source.contains("CityStore"))
        // The invite code is redeemed by the same session Settings uses.
        XCTAssertTrue(source.contains("invite.redeem(code)"))
        XCTAssertTrue(source.contains("onboarding.live_text.skip"))
    }

    /// Only the choice to use a key of one's own names the provider, and it
    /// takes the name as an argument rather than spelling it out.
    func testFirstLaunchCopyNamesAProviderOnlyWhereAKeyIsChosen() throws {
        let plainKeys = [
            "onboarding.step.live_text", "onboarding.step.microphone",
            "onboarding.live_text.subtitle", "onboarding.live_text.use_invite",
            "onboarding.live_text.skip", "onboarding.welcome.privacy_plain",
            "onboarding.permissions.action.open_system_settings",
            "onboarding.permissions.denied_hint",
            "onboarding.start", "onboarding.back", "onboarding.skip", "onboarding.finish",
            "onboarding.permissions.allow", "onboarding.permissions.allowed",
        ]
        for language in settingsLanguages {
            let strings = try settingsStrings(language)
            for key in plainKeys {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.contains("Soniox"), "\(language) \(key)")
            }
            let ownKey = try XCTUnwrap(strings["onboarding.live_text.use_own_key_format"])
            XCTAssertEqual(ownKey.components(separatedBy: "%@").count, 2, "\(language)")
            XCTAssertFalse(ownKey.contains("Soniox"), "\(language)")
        }
    }
}

@MainActor
final class SidebarAccountRowTests: XCTestCase {
    private func account(name: String) -> FfiCityAccount {
        FfiCityAccount(
            server: "city.example",
            cityId: "riverside",
            cityName: "Riverside",
            personId: "person-1",
            personName: name,
            roles: ["resident"],
            signedInAtEpoch: 0
        )
    }

    func testSignedOutIsAQuietSignInRow() {
        XCTAssertEqual(SidebarAccountRow.Presentation.resolve(nil), .signedOut)
    }

    func testSignedInShowsTheInitialAndTheName() {
        XCTAssertEqual(
            SidebarAccountRow.Presentation.resolve(account(name: "  sam  ")),
            .signedIn(initial: "S", name: "sam")
        )
    }

    func testAResidentWithoutANameStillGetsARow() {
        XCTAssertEqual(
            SidebarAccountRow.Presentation.resolve(account(name: "")),
            .signedIn(initial: "?", name: String(localized: "city.settings.unnamed"))
        )
    }

    /// The row follows one thing in the city store. Observing the whole
    /// store would redraw it on every calendar refresh and filing step.
    func testTheRowFollowsOnlyTheAccount() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/UIScenes/Main/SidebarAccountRow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CityStore.shared.$account"))
        XCTAssertFalse(source.contains("@ObservedObject"))
        XCTAssertTrue(source.contains("openSettings(section: .account)"))
    }
}

@MainActor
final class LiveConnectionFactsTests: XCTestCase {
    private func lane(_ target: String?, lagMs: UInt64?) -> NotebookCaptureLaneHealthDTO {
        NotebookCaptureLaneHealthDTO(targetLanguage: target, state: .live, lagMs: lagMs)
    }

    func testNothingIsReportedWhenNoRecordingIsRunning() {
        let facts = LiveConnectionFacts(isRecording: false, lanes: [lane("en", lagMs: 9_000)])
        XCTAssertEqual(facts.connections, 0)
        XCTAssertNil(facts.lagSeconds)
        XCTAssertEqual(facts.text, String(localized: "settings.diagnostics.recording_none"))
    }

    func testTheSlowestConnectionSetsTheDelay() {
        let facts = LiveConnectionFacts(
            isRecording: true,
            lanes: [lane(nil, lagMs: 300), lane("en", lagMs: 4_200), lane("th", lagMs: nil)]
        )
        XCTAssertEqual(facts.connections, 3)
        XCTAssertEqual(facts.lagSeconds, ActiveBilingualTranscriptStore.displayedLagSeconds(4_200))
        XCTAssertTrue(facts.text.contains("3"), facts.text)
    }

    func testUnderASecondCountsAsKeepingUp() {
        let facts = LiveConnectionFacts(isRecording: true, lanes: [lane(nil, lagMs: 400)])
        XCTAssertNil(facts.lagSeconds)
        XCTAssertTrue(
            facts.text.hasSuffix(String(localized: "settings.diagnostics.recording_keeping_up")),
            facts.text
        )
    }
}

// MARK: - 0.8.3: no sentences on the surface

@MainActor
final class SettingsSurfaceTests: XCTestCase {
    private static let newLabels = [
        "settings.switch.on", "settings.switch.off",
        "settings.action.copy", "settings.action.copied", "settings.action.replace",
        "settings.action.stop", "settings.action.create",
        "settings.group.devices", "settings.group.updates", "settings.group.shortcuts",
        "settings.general.appearance", "settings.updates.check",
        "settings.devices.this_mac_label", "settings.devices.pairing_code", "settings.devices.online",
        "settings.backup.code",
        "settings.live_text.status.spent", "settings.live_text.status.own_key",
        "settings.credentials.status.saved", "settings.credentials.status.verified",
        "settings.credentials.status.invalid", "settings.credentials.key_placeholder",
        "onboarding.start", "onboarding.back", "onboarding.skip", "onboarding.finish",
        "onboarding.permissions.allow", "onboarding.permissions.allowed",
    ]

    /// What 0.8.3 added to Settings and first launch are labels: a word or
    /// two in every language, never a sentence.
    func testNewLabelsAreAWordOrTwoInEveryLanguage() throws {
        for language in settingsLanguages {
            let strings = try settingsStrings(language)
            for key in Self.newLabels {
                let value = try XCTUnwrap(strings[key], "\(language) lacks \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                XCTAssertLessThanOrEqual(value.count, 26, "\(language) \(key): \(value)")
                for stop in [".", "。", "!", "！", "…", ":", "："] {
                    XCTAssertFalse(value.contains(stop), "\(language) \(key) reads as a sentence: \(value)")
                }
            }
        }
    }

    /// The city agent's files call these four with the arguments below; the
    /// sentences they pass are no longer printed, but the calls must compile.
    func testTheSharedComponentsKeepTheirCallSignatures() {
        _ = SettingsGroup(title: "a", subtitle: "b") {
            SettingsCard(title: "c", subtitle: "d") {
                SettingsRow("e", description: "f") { EmptyView() }
                SettingsRowDivider()
                SettingsFullRow { EmptyView() }
            }
            SettingsCard { SettingsRow("g") { EmptyView() } }
        }
        _ = SettingsGroup(title: "a") { EmptyView() }
    }

    /// A row's description and a card's or group's subtitle are tooltips
    /// now. Nothing in the three components prints them.
    func testDescriptionsAndSubtitlesAreNotPrinted() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ZuTalk/Settings/SettingsComponents.swift"),
            encoding: .utf8
        )
        let pageHeader = try XCTUnwrap(source.range(of: "struct SettingsPageHeader: View"))
        let components = source[source.startIndex..<pageHeader.lowerBound]
        XCTAssertFalse(components.contains("Text(description)"))
        XCTAssertFalse(components.contains("Text(subtitle)"))
        XCTAssertTrue(components.contains(".settingsExplained(subtitle)"))
        XCTAssertTrue(components.contains(".help(description ?? \"\")"))
    }

    /// What powers live text is said in a few words; the sentence is the
    /// tooltip. Neither names a provider.
    func testLiveTextStatusIsAFewWords() {
        let states: [LiveTextSource] = [
            .invite(recordableSeconds: nil),
            .invite(recordableSeconds: 29 * 3_600 + 30 * 60),
            .inviteSpent,
            .ownKey,
            .nothing,
        ]
        let words = states.map(\.status)
        XCTAssertEqual(Set(words).count, words.count)
        for (state, word) in zip(states, words) {
            XCTAssertFalse(word.isEmpty)
            XCTAssertNotEqual(word, state.sentence)
            for account in ProviderCredentialAccount.allCases {
                XCTAssertFalse(word.localizedCaseInsensitiveContains(account.displayName), word)
            }
        }
        XCTAssertTrue(words[1].contains("29"), words[1])
        XCTAssertTrue(words[1].contains("30"), words[1])
        XCTAssertEqual(LiveTextSource.nothing.status, String(localized: "captions_choice.off"))
    }

    private func device(_ name: String, connected: Bool) -> FfiSyncDevice {
        FfiSyncDevice(
            deviceId: name,
            name: name,
            isThisDevice: false,
            connected: connected,
            viaRelay: false,
            lastSyncedUnixMs: nil
        )
    }

    /// Leaving is offered only while this Mac is paired and still in.
    func testLeavingIsOfferedOnlyWhilePaired() {
        var model = DevicesCardModel(enabled: true, others: [device("Studio Mac", connected: true)])
        XCTAssertTrue(model.canLeave)
        model.removedFromGroup = true
        XCTAssertFalse(model.canLeave)
        XCTAssertFalse(DevicesCardModel(enabled: true).canLeave)
        XCTAssertFalse(DevicesCardModel(enabled: false, others: [device("Studio Mac", connected: true)]).canLeave)
    }

    /// The disclosures that used to be printed under the devices and the
    /// sharing headers are still all there, behind the ⓘ.
    func testDisclosuresMovedBehindTheInfoButtonsNotAway() {
        for key in [
            "settings.devices.how_direct", "settings.devices.how_audio",
            "settings.devices.how_recording", "settings.devices.how_code",
        ] {
            XCTAssertTrue(
                DevicesSettingsSection.howItWorks.contains(String(localized: String.LocalizationValue(key))),
                key
            )
        }
        for key in ["share.encrypted", "share.audio_never"] {
            XCTAssertTrue(
                SharingSettingsSection.howSharingWorks.contains(String(localized: String.LocalizationValue(key))),
                key
            )
        }
        XCTAssertTrue(BackupSettingsCard.howBackupWorks.contains(String(localized: "backup.subtitle")))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZuTalk", isDirectory: true)
        let keys = try? String(
            contentsOf: root.appendingPathComponent("Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        for key in [
            "settings.credentials.trust_boundary_notice", "settings.services.no_egress_notice",
            "settings.services.model.egress_notice", "settings.services.model.audio_notice",
            "settings.credentials.local_storage_hint",
        ] {
            XCTAssertEqual(keys?.contains("\"\(key)\""), true, "\(key) is no longer shown anywhere")
        }
        let onboarding = try? String(
            contentsOf: root.appendingPathComponent("App/OnboardingView.swift"),
            encoding: .utf8
        )
        for key in [
            "onboarding.welcome.privacy_plain", "onboarding.keys.soniox.help",
            "settings.credentials.trust_boundary_notice",
        ] {
            XCTAssertEqual(onboarding?.contains("\"\(key)\""), true, "\(key) is no longer shown anywhere")
        }
    }

    func testDiagnosticsAreCopiedOneRowPerLine() {
        XCTAssertEqual(
            DiagnosticLine.text([
                DiagnosticLine(label: "Version", value: "0.8.3 (63)"),
                DiagnosticLine(label: "Network", value: "Online"),
            ]),
            "Version: 0.8.3 (63)\nNetwork: Online"
        )
    }

    func testALinkSaysHowLongItHasLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func link(expiresIn seconds: Int64) -> FfiRecordingLink {
            FfiRecordingLink(
                roomId: "room",
                sessionId: "session",
                url: "https://example.invalid/r",
                createdAtEpoch: 1_000_000,
                expiresAtEpoch: 1_000_000 + seconds
            )
        }
        XCTAssertEqual(
            SharingSettingsSection.timeLeft(link(expiresIn: 23 * 3_600 + 59), now: now),
            String(format: String(localized: "share.recording.expires_hours_format"), Int64(23))
        )
        XCTAssertEqual(
            SharingSettingsSection.timeLeft(link(expiresIn: 40 * 60), now: now),
            String(format: String(localized: "share.recording.expires_minutes_format"), Int64(40))
        )
        XCTAssertEqual(
            SharingSettingsSection.timeLeft(link(expiresIn: -5), now: now),
            String(format: String(localized: "share.recording.expires_minutes_format"), Int64(1))
        )
    }

    /// First launch asks the system about the microphone through the
    /// controller, so a state can be looked at without changing the Mac's.
    func testTheMicrophoneStepShowsWhatTheSystemAnswers() throws {
        let suiteName = "SettingsSurfaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var answer = PermissionStatus.denied
        let controller = OnboardingController(
            defaults: defaults,
            openSystemSettings: { _ in },
            permissionStatus: { _ in answer }
        )
        XCTAssertEqual(controller.permissionStatuses[.microphone], .denied)
        XCTAssertFalse(controller.allPermissionsGranted)
        XCTAssertFalse(controller.hasCompletedBefore)

        answer = .granted
        controller.refreshPermissions()
        XCTAssertTrue(controller.allPermissionsGranted)
    }
}
