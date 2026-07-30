import Darwin
import XCTest
@testable import Zulangue

private final class ProviderCredentialConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeMutations = 0
    private(set) var maximumConcurrentMutations = 0
    private(set) var errors: [Error] = []

    func mutationStarted() {
        lock.lock()
        activeMutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, activeMutations)
        lock.unlock()
    }

    func mutationEnded() {
        lock.lock()
        activeMutations -= 1
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}

@MainActor
final class ProviderCredentialSessionTests: XCTestCase {
    private enum FakeRuntimeError: Error {
        case rejected
    }

    private final class FakeRuntime: ProviderCredentialRuntimeAccess {
        var values: [String: String] = [:]
        var setCalls: [(scope: String, value: String)] = []
        var clearCalls: [String] = []
        var onEvent: ((String) -> Void)?
        var rejectedSetScope: String?
        var rejectedSetValues: Set<String> = []
        var rejectedClearScope: String?
        var reportSetAsMissing = false
        var reportClearAsPresent = false
        private(set) var bootstrapCompletionCount = 0
        var onCompleteBootstrap: (() -> Void)?

        func hasApiKey(scope: String) -> Bool {
            if reportSetAsMissing, setCalls.last?.scope == scope {
                return false
            }
            if reportClearAsPresent, clearCalls.last == scope {
                return true
            }
            return values[scope] != nil
        }

        func setApiKey(scope: String, value: String) throws {
            onEvent?("runtime.set:\(scope):\(value)")
            if rejectedSetScope == scope || rejectedSetValues.contains(value) {
                throw FakeRuntimeError.rejected
            }
            setCalls.append((scope, value))
            values[scope] = value
        }

        func clearApiKey(scope: String) throws {
            onEvent?("runtime.clear:\(scope)")
            if rejectedClearScope == scope {
                throw FakeRuntimeError.rejected
            }
            clearCalls.append(scope)
            values.removeValue(forKey: scope)
        }

        func completeBootstrap() {
            onEvent?("runtime.complete_bootstrap")
            onCompleteBootstrap?()
            bootstrapCompletionCount += 1
        }
    }

    private final class FakePersistence: ProviderCredentialPersisting {
        var credentials: [ProviderCredentialAccount: String]
        var failingSaveCalls: Set<Int> = []
        var loadError: Error?
        var deleteError: Error?
        var onEvent: ((String) -> Void)?
        private(set) var saveCallCount = 0
        private(set) var deleteCallCount = 0
        private(set) var updateCallCount = 0

        init(credentials: [ProviderCredentialAccount: String]) {
            self.credentials = credentials
        }

        func load() throws -> [ProviderCredentialAccount: String] {
            if let loadError {
                throw loadError
            }
            return credentials
        }

        func save(_ credentials: [ProviderCredentialAccount: String]) throws {
            saveCallCount += 1
            if failingSaveCalls.contains(saveCallCount) {
                onEvent?("persistence.commit_failed")
                throw FakeRuntimeError.rejected
            }
            self.credentials = credentials
            onEvent?("persistence.commit")
        }

        func updateCredentials(
            allowingReplacementOfUnreadableDocument: Bool,
            _ mutation: (
                inout [ProviderCredentialAccount: String],
                _ replacingUnreadableDocument: Bool
            ) throws -> Void
        ) throws -> [ProviderCredentialAccount: String] {
            updateCallCount += 1
            var workingCredentials: [ProviderCredentialAccount: String]
            var replacingUnreadableDocument = false
            if let loadError {
                guard allowingReplacementOfUnreadableDocument,
                      let storeError = loadError as? ProviderCredentialStoreError,
                      storeError.allowsExplicitReplacement else {
                    throw loadError
                }
                workingCredentials = [:]
                replacingUnreadableDocument = true
            } else {
                workingCredentials = credentials
            }

            try mutation(&workingCredentials, replacingUnreadableDocument)
            try save(workingCredentials)
            if replacingUnreadableDocument {
                loadError = nil
            }
            return workingCredentials
        }

        func delete() throws {
            deleteCallCount += 1
            if let deleteError {
                throw deleteError
            }
            credentials = [:]
            loadError = nil
        }
    }

    private var temporaryRoot: URL!
    private var credentialFileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderCredentialSessionTests-\(UUID().uuidString)")
        credentialFileURL = temporaryRoot
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("provider-credentials.json", isDirectory: false)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        credentialFileURL = nil
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testProductionPathMatchesDocumentedAppPrivateLocation() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Zulangue", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("provider-credentials.json", isDirectory: false)
        let actual = ProviderCredentialFileStore.defaultFileURL(useTestIsolation: false)

        XCTAssertEqual(actual.standardizedFileURL, expected.standardizedFileURL)
    }

    func testDefaultUnitTestPathIsIsolatedFromRealApplicationSupport() {
        let actual = ProviderCredentialFileStore.defaultFileURL().standardizedFileURL
        let expectedRoot = URL(
            fileURLWithPath: CoreClient.defaultDataDir(),
            isDirectory: true
        ).standardizedFileURL

        XCTAssertTrue(actual.path.hasPrefix(expectedRoot.path))
        XCTAssertFalse(
            actual.path.contains("Library/Application Support/Zulangue"),
            "tests must never read or write the signed-in user's provider credentials"
        )
    }

    func testAccountScopeMappingAllowsOnlySoniox() {
        let accounts = ProviderCredentialAccount.allCases
        let scopes = accounts.map(\.scope)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(Set(scopes).count, accounts.count)
        XCTAssertEqual(ProviderCredentialAccount.soniox.scope, "soniox")
        XCTAssertNil(ProviderCredentialAccount(scope: "unknown"))
    }

    func testSavedCredentialLoadPolicyExcludesUnitAndUiTests() {
        XCTAssertTrue(
            TestEnvironment.shouldLoadSavedProviderCredentials(
                isUnitTestMode: false,
                isUITestMode: false
            )
        )
        XCTAssertFalse(
            TestEnvironment.shouldLoadSavedProviderCredentials(
                isUnitTestMode: true,
                isUITestMode: false
            )
        )
        XCTAssertFalse(
            TestEnvironment.shouldLoadSavedProviderCredentials(
                isUnitTestMode: false,
                isUITestMode: true
            )
        )
        XCTAssertFalse(
            TestEnvironment.shouldLoadSavedProviderCredentials(
                isUnitTestMode: true,
                isUITestMode: true
            )
        )
    }

    func testFileStoreRoundTripsAllKnownAccountsAndNormalizesWhitespace() throws {
        let store = makeStore()
        let fixtures = Dictionary(
            uniqueKeysWithValues: ProviderCredentialAccount.allCases.enumerated().map {
                ($0.element, "  fixture-token-\($0.offset)\n")
            }
        )

        try store.save(fixtures)
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, ProviderCredentialAccount.allCases.count)
        for (index, account) in ProviderCredentialAccount.allCases.enumerated() {
            XCTAssertEqual(loaded[account], "fixture-token-\(index)")
        }
    }

    func testFileDocumentIsVersionedAndContainsOnlyAccountMap() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token"])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: credentialFileURL))
                as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["version", "credentials"])
        XCTAssertEqual(object["version"] as? Int, 1)
        let credentials = try XCTUnwrap(object["credentials"] as? [String: String])
        XCTAssertEqual(credentials, ["soniox": "fixture-token"])
    }

    func testSaveCreatesAndRepairsPrivatePermissions() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token"])

        assertPermissions(0o700, at: credentialFileURL.deletingLastPathComponent())
        assertPermissions(0o600, at: credentialFileURL)

        XCTAssertEqual(chmod(credentialFileURL.deletingLastPathComponent().path, 0o777), 0)
        XCTAssertEqual(chmod(credentialFileURL.path, 0o666), 0)

        _ = try store.load()

        assertPermissions(0o700, at: credentialFileURL.deletingLastPathComponent())
        assertPermissions(0o600, at: credentialFileURL)
    }

    func testAtomicSaveLeavesNoTemporaryCredentialFiles() throws {
        let store = makeStore()
        try store.save([.soniox: "first-fixture-token"])
        try store.save([.soniox: "second-fixture-token"])

        let children = try FileManager.default.contentsOfDirectory(
            at: credentialFileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(
            children.map(\.lastPathComponent).sorted(),
            [ProviderCredentialFileStore.lockFileName, "provider-credentials.json"].sorted()
        )
        XCTAssertEqual(try store.load()[.soniox], "second-fixture-token")
    }

    func testStableLockFileIsPrivateRegularAndReused() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token"])
        let lockURL = credentialFileURL.deletingLastPathComponent()
            .appendingPathComponent(ProviderCredentialFileStore.lockFileName)

        var before = stat()
        XCTAssertEqual(lstat(lockURL.path, &before), 0)
        XCTAssertEqual(before.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(before.st_uid, geteuid())
        XCTAssertEqual(before.st_mode & mode_t(0o777), mode_t(0o600))

        _ = try store.load()

        var after = stat()
        XCTAssertEqual(lstat(lockURL.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
    }

    func testLockFileSymlinkIsRejectedWithoutTouchingTarget() throws {
        let directory = credentialFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetURL = temporaryRoot.appendingPathComponent("lock-target")
        try Data("sentinel".utf8).write(to: targetURL)
        let lockURL = directory.appendingPathComponent(ProviderCredentialFileStore.lockFileName)
        XCTAssertEqual(symlink(targetURL.path, lockURL.path), 0)

        XCTAssertThrowsError(try makeStore().load())
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("sentinel".utf8))
    }

    func testLoadRemovesSafeCrashResidueTemporaryFile() throws {
        let directory = credentialFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staleURL = directory.appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)crash-residue\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        try Data("stale-secret-fixture".utf8).write(to: staleURL)
        XCTAssertEqual(chmod(staleURL.path, 0o600), 0)

        _ = try makeStore().load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    func testDeleteAlsoRemovesSafeCrashResidueTemporaryFile() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token"])
        let staleURL = credentialFileURL.deletingLastPathComponent().appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)delete-residue\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        try Data("stale-secret-fixture".utf8).write(to: staleURL)
        XCTAssertEqual(chmod(staleURL.path, 0o600), 0)

        try store.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    func testCleanupLeavesUnsafeTemporaryArtifactsUntouched() throws {
        let directory = credentialFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetURL = temporaryRoot.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: targetURL)
        let symlinkURL = directory.appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)symlink\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        XCTAssertEqual(symlink(targetURL.path, symlinkURL.path), 0)
        let widenedURL = directory.appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)widened\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        try Data("not-owned-by-cleanup-contract".utf8).write(to: widenedURL)
        XCTAssertEqual(chmod(widenedURL.path, 0o644), 0)
        let directoryURL = directory.appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)directory\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        _ = try makeStore().load()

        var symlinkInfo = stat()
        XCTAssertEqual(lstat(symlinkURL.path, &symlinkInfo), 0)
        XCTAssertEqual(symlinkInfo.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertTrue(FileManager.default.fileExists(atPath: widenedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("sentinel".utf8))
    }

    func testRejectedRealFileSaveLeavesPreviousDocumentUnchangedAcrossRelaunch() throws {
        let store = makeStore()
        try store.save([.soniox: "previous-fixture-token"])
        let oversized = String(
            repeating: "x",
            count: ProviderCredentialFileStore.maximumCredentialBytes + 1
        )

        XCTAssertThrowsError(try store.save([.soniox: oversized]))

        let relaunchedStore = ProviderCredentialFileStore(fileURL: credentialFileURL)
        XCTAssertEqual(try relaunchedStore.load()[.soniox], "previous-fixture-token")
    }

    func testRealFileDeleteIsDurableAcrossRelaunch() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token"])

        try store.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialFileURL.path))
        XCTAssertTrue(try ProviderCredentialFileStore(fileURL: credentialFileURL).load().isEmpty)
    }

    func testLoadRejectsMalformedJson() throws {
        try writeFixture(Data("not-json".utf8))

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .malformedDocument)
        }
    }

    func testLoadRejectsUnsupportedVersion() throws {
        try writeJSONFixture(["version": 2, "credentials": [:] as [String: String]])

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .unsupportedVersion(2))
        }
    }

    func testLoadRejectsUnknownAccountWithoutLoadingKnownValues() throws {
        try writeJSONFixture([
            "version": 1,
            "credentials": [
                "soniox": "fixture-token",
                "unknown-provider": "untrusted-fixture-token",
            ],
        ])

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? ProviderCredentialStoreError,
                .unknownAccounts(["unknown-provider"])
            )
        }
    }

    func testLoadRejectsEmptyCredential() throws {
        try writeJSONFixture([
            "version": 1,
            "credentials": ["soniox": " \n "],
        ])

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(
                error as? ProviderCredentialStoreError,
                .emptyCredential("soniox")
            )
        }
    }

    func testLoadRejectsOversizedFileBeforeDecoding() throws {
        let data = Data(
            repeating: 0x20,
            count: ProviderCredentialFileStore.maximumFileBytes + 1
        )
        try writeFixture(data)

        XCTAssertThrowsError(try makeStore().load()) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .fileTooLarge)
        }
    }

    func testLoadRejectsCredentialFileSymlink() throws {
        let directory = credentialFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(symlink("/dev/null", credentialFileURL.path), 0)

        XCTAssertThrowsError(try makeStore().load())
    }

    func testLoadRejectsSecretsDirectorySymlink() throws {
        let realDirectory = temporaryRoot.appendingPathComponent("real-secrets")
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(
            symlink(realDirectory.path, credentialFileURL.deletingLastPathComponent().path),
            0
        )

        XCTAssertThrowsError(try makeStore().load()) { error in
            guard let storeError = error as? ProviderCredentialStoreError,
                  case .unsafePath = storeError else {
                return XCTFail("Expected unsafePath, got \(error)")
            }
        }
    }

    func testApplyPersistsTrimmedValueAndActivatesRustRuntime() throws {
        let runtime = FakeRuntime()
        let store = makeStore()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: store)

        XCTAssertFalse(session.has(.soniox))
        try session.apply("  fixture-token\n", for: .soniox)

        XCTAssertTrue(session.has(.soniox))
        XCTAssertEqual(runtime.values["soniox"], "fixture-token")
        XCTAssertEqual(try store.load()[.soniox], "fixture-token")
        XCTAssertEqual(
            session.snapshot().first(where: { $0.account == .soniox }),
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: "soniox",
                isSaved: true,
                isActive: true
            )
        )
        XCTAssertEqual(runtime.bootstrapCompletionCount, 1)
    }

    func testApplyCommitsDurableKeyBeforeOpeningWorkerBootstrapGate() throws {
        let persistence = FakePersistence(credentials: [:])
        let runtime = FakeRuntime()
        runtime.onCompleteBootstrap = {
            XCTAssertEqual(persistence.credentials[.soniox], "fixture-token")
            XCTAssertEqual(runtime.values["soniox"], "fixture-token")
        }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        try session.apply("fixture-token", for: .soniox)

        XCTAssertEqual(runtime.bootstrapCompletionCount, 1)
        XCTAssertEqual(persistence.updateCallCount, 1)
    }

    func testInitialApplyStrictlyClearsThenCommitsThenActivates() throws {
        var events: [String] = []
        let persistence = FakePersistence(credentials: [:])
        persistence.onEvent = { events.append($0) }
        let runtime = FakeRuntime()
        runtime.onEvent = { events.append($0) }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        try session.apply("fixture-token", for: .soniox)

        XCTAssertEqual(events, [
            "runtime.clear:soniox",
            "persistence.commit",
            "runtime.set:soniox:fixture-token",
            "runtime.complete_bootstrap",
        ])
    }

    func testReplacementStrictlyRevokesOldRuntimeBeforeDurableCommit() throws {
        var events: [String] = []
        let persistence = FakePersistence(credentials: [.soniox: "old-fixture-token"])
        persistence.onEvent = { events.append($0) }
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "old-fixture-token"
        runtime.onEvent = { events.append($0) }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        try session.apply("new-fixture-token", for: .soniox)

        XCTAssertEqual(events, [
            "runtime.clear:soniox",
            "persistence.commit",
            "runtime.set:soniox:new-fixture-token",
            "runtime.complete_bootstrap",
        ])
        XCTAssertEqual(persistence.credentials[.soniox], "new-fixture-token")
        XCTAssertEqual(runtime.values["soniox"], "new-fixture-token")
    }

    func testMalformedReplacementClearsRuntimeBeforeReplacingDocument() throws {
        var events: [String] = []
        let persistence = FakePersistence(credentials: [:])
        persistence.loadError = ProviderCredentialStoreError.malformedDocument
        persistence.onEvent = { events.append($0) }
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-runtime-token"
        runtime.onEvent = { events.append($0) }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        try session.apply("replacement-fixture-token", for: .soniox)

        XCTAssertEqual(events, [
            "runtime.clear:soniox",
            "persistence.commit",
            "runtime.set:soniox:replacement-fixture-token",
            "runtime.complete_bootstrap",
        ])
        XCTAssertNil(persistence.loadError)
        XCTAssertEqual(persistence.credentials[.soniox], "replacement-fixture-token")
    }

    func testPersistenceFailureNeverExposesReplacementRuntimeValue() throws {
        var events: [String] = []
        let persistence = FakePersistence(credentials: [.soniox: "old-fixture-token"])
        persistence.failingSaveCalls = [1]
        persistence.onEvent = { events.append($0) }
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "old-fixture-token"
        runtime.onEvent = { events.append($0) }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        XCTAssertThrowsError(
            try session.apply("new-fixture-token", for: .soniox)
        ) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .persistenceFailed)
        }

        XCTAssertEqual(events, [
            "runtime.clear:soniox",
            "persistence.commit_failed",
            "runtime.set:soniox:old-fixture-token",
        ])
        XCTAssertFalse(events.contains("runtime.set:soniox:new-fixture-token"))
        XCTAssertEqual(persistence.credentials[.soniox], "old-fixture-token")
        XCTAssertEqual(runtime.values["soniox"], "old-fixture-token")
    }

    func testActivationFailureKeepsCommittedKeySavedButInactive() throws {
        var events: [String] = []
        let persistence = FakePersistence(credentials: [:])
        persistence.onEvent = { events.append($0) }
        let runtime = FakeRuntime()
        runtime.rejectedSetValues = ["fixture-token"]
        runtime.onEvent = { events.append($0) }
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        XCTAssertThrowsError(try session.apply("fixture-token", for: .soniox)) { error in
            XCTAssertTrue(error is FakeRuntimeError)
        }

        XCTAssertEqual(events, [
            "runtime.clear:soniox",
            "persistence.commit",
            "runtime.set:soniox:fixture-token",
            "runtime.clear:soniox",
            "runtime.complete_bootstrap",
        ])
        XCTAssertEqual(persistence.credentials[.soniox], "fixture-token")
        XCTAssertNil(runtime.values["soniox"])
        XCTAssertEqual(
            session.snapshot().first(where: { $0.account == .soniox }),
            ProviderCredentialSnapshot(
                account: .soniox,
                scope: "soniox",
                isSaved: true,
                isActive: false
            )
        )
    }

    func testSessionApplyAndClearUsePersistenceTransactionBoundary() throws {
        let persistence = FakePersistence(credentials: [:])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)

        try session.apply("fixture-token", for: .soniox)
        try session.clear(.soniox)

        XCTAssertEqual(persistence.updateCallCount, 2)
        XCTAssertEqual(persistence.saveCallCount, 2)
        XCTAssertTrue(persistence.credentials.isEmpty)
    }

    func testApplyRejectsWhitespaceWithoutTouchingDiskOrRuntime() {
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: makeStore())

        XCTAssertThrowsError(try session.apply(" \n\t ", for: .soniox)) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .emptyValue)
        }
        XCTAssertTrue(runtime.setCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialFileURL.path))
    }

    func testNewSessionAutomaticallyActivatesSavedCredential() throws {
        let firstRuntime = FakeRuntime()
        let store = makeStore()
        let firstSession = ProviderCredentialSession(runtime: firstRuntime, fileStore: store)
        try firstSession.apply("fixture-token", for: .soniox)

        let relaunchedRuntime = FakeRuntime()
        let relaunchedSession = ProviderCredentialSession(
            runtime: relaunchedRuntime,
            fileStore: store
        )
        try relaunchedSession.bootstrapSavedCredentials()

        XCTAssertTrue(relaunchedSession.has(.soniox))
        XCTAssertEqual(relaunchedRuntime.values["soniox"], "fixture-token")
        XCTAssertEqual(relaunchedRuntime.bootstrapCompletionCount, 1)
    }

    func testExplicitSaveReplacesMalformedDocumentAndRelaunchActivatesNewKey() throws {
        try writeFixture(Data("not-json".utf8))
        let firstRuntime = FakeRuntime()
        let firstSession = ProviderCredentialSession(runtime: firstRuntime, fileStore: makeStore())

        XCTAssertThrowsError(try firstSession.bootstrapSavedCredentials())
        XCTAssertNotNil(firstSession.recoveryErrorDescription)
        XCTAssertEqual(firstRuntime.bootstrapCompletionCount, 1)

        try firstSession.apply(" replacement-fixture-token ", for: .soniox)

        XCTAssertNil(firstSession.recoveryErrorDescription)
        XCTAssertTrue(firstSession.has(.soniox))
        XCTAssertEqual(firstRuntime.bootstrapCompletionCount, 2)
        let relaunchedRuntime = FakeRuntime()
        let relaunchedSession = ProviderCredentialSession(
            runtime: relaunchedRuntime,
            fileStore: makeStore()
        )
        try relaunchedSession.bootstrapSavedCredentials()
        XCTAssertEqual(relaunchedRuntime.values["soniox"], "replacement-fixture-token")
    }

    func testExplicitSaveReplacesUnsupportedDocumentVersion() throws {
        try writeJSONFixture([
            "version": 99,
            "credentials": ["soniox": "old-fixture-token"],
        ])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: makeStore())

        XCTAssertThrowsError(try session.bootstrapSavedCredentials())
        try session.apply("new-fixture-token", for: .soniox)

        XCTAssertNil(session.recoveryErrorDescription)
        XCTAssertEqual(try makeStore().load()[.soniox], "new-fixture-token")
        XCTAssertEqual(runtime.values["soniox"], "new-fixture-token")
    }

    func testExplicitResetDeletesMalformedDocumentAndClearsRecoveryError() throws {
        try writeFixture(Data("not-json".utf8))
        let staleURL = credentialFileURL.deletingLastPathComponent().appendingPathComponent(
            "\(ProviderCredentialFileStore.temporaryFilePrefix)reset-residue\(ProviderCredentialFileStore.temporaryFileSuffix)"
        )
        try Data("stale-secret-fixture".utf8).write(to: staleURL)
        XCTAssertEqual(chmod(staleURL.path, 0o600), 0)
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: makeStore())
        XCTAssertThrowsError(try session.bootstrapSavedCredentials())

        try session.resetSavedCredentials()

        XCTAssertNil(session.recoveryErrorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(session.snapshot().allSatisfy { !$0.isSaved && !$0.isActive })
        XCTAssertEqual(runtime.bootstrapCompletionCount, 2)
    }

    func testClearRemovesSavedAndRuntimeCopiesAcrossRelaunch() throws {
        let store = makeStore()
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: store)
        try session.apply("fixture-token", for: .soniox)

        try session.clear(.soniox)

        XCTAssertFalse(session.has(.soniox))
        XCTAssertNil(runtime.values["soniox"])
        XCTAssertNil(try store.load()[.soniox])

        let relaunchedSession = ProviderCredentialSession(
            runtime: FakeRuntime(),
            fileStore: store
        )
        try relaunchedSession.bootstrapSavedCredentials()
        XCTAssertFalse(relaunchedSession.has(.soniox))
    }

    func testApplySaveFailureRestoresPreviousDurableAndRuntimeValue() throws {
        let persistence = FakePersistence(credentials: [.soniox: "previous-fixture-token"])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)
        try session.activateSavedCredentials()
        persistence.failingSaveCalls = [1]

        XCTAssertThrowsError(
            try session.apply("replacement-fixture-token", for: .soniox)
        ) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .persistenceFailed)
        }

        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertEqual(persistence.credentials[.soniox], "previous-fixture-token")
        XCTAssertEqual(runtime.values["soniox"], "previous-fixture-token")
        XCTAssertTrue(session.has(.soniox))
    }

    func testApplyRuntimeRestoreFailureKeepsDurableSavedStateButMarksItInactive() throws {
        let persistence = FakePersistence(credentials: [.soniox: "previous-fixture-token"])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)
        try session.activateSavedCredentials()
        persistence.failingSaveCalls = [1]
        runtime.rejectedSetValues = ["previous-fixture-token"]

        XCTAssertThrowsError(
            try session.apply("replacement-fixture-token", for: .soniox)
        ) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .persistenceFailed)
        }

        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNil(runtime.values["soniox"])
        XCTAssertFalse(session.has(.soniox))
        XCTAssertEqual(persistence.credentials[.soniox], "previous-fixture-token")
        let snapshot = try XCTUnwrap(session.snapshot().first { $0.account == .soniox })
        XCTAssertTrue(snapshot.isSaved)
        XCTAssertFalse(snapshot.isActive)
    }

    func testClearSaveFailureRestoresPreviousDurableAndRuntimeValue() throws {
        let persistence = FakePersistence(credentials: [.soniox: "previous-fixture-token"])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)
        try session.activateSavedCredentials()
        persistence.failingSaveCalls = [1]

        XCTAssertThrowsError(try session.clear(.soniox)) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .persistenceFailed)
        }

        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertEqual(persistence.credentials[.soniox], "previous-fixture-token")
        XCTAssertEqual(runtime.values["soniox"], "previous-fixture-token")
        XCTAssertTrue(session.has(.soniox))
    }

    func testClearRuntimeRestoreFailureKeepsDurableSavedStateButMarksItInactive() throws {
        let persistence = FakePersistence(credentials: [.soniox: "previous-fixture-token"])
        let runtime = FakeRuntime()
        let session = ProviderCredentialSession(runtime: runtime, fileStore: persistence)
        try session.activateSavedCredentials()
        persistence.failingSaveCalls = [1]
        runtime.rejectedSetValues = ["previous-fixture-token"]

        XCTAssertThrowsError(try session.clear(.soniox)) { error in
            XCTAssertEqual(error as? ProviderCredentialSessionError, .persistenceFailed)
        }

        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNil(runtime.values["soniox"])
        XCTAssertFalse(session.has(.soniox))
        XCTAssertEqual(persistence.credentials[.soniox], "previous-fixture-token")
        let snapshot = try XCTUnwrap(session.snapshot().first { $0.account == .soniox })
        XCTAssertTrue(snapshot.isSaved)
        XCTAssertFalse(snapshot.isActive)
    }

    func testProcessOnlyBootstrapFailureClearsRuntimeAndStillOpensGate() {
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-fixture-token"
        runtime.rejectedSetScope = "soniox"
        let session = ProviderCredentialSession(
            runtime: runtime,
            fileStore: FakePersistence(credentials: [:])
        )

        XCTAssertThrowsError(
            try session.bootstrapProcessOnlyCredential("fixture-token", for: .soniox)
        )

        XCTAssertTrue(runtime.values.isEmpty)
        XCTAssertNotNil(session.recoveryErrorDescription)
        XCTAssertEqual(runtime.bootstrapCompletionCount, 1)
    }

    func testBootstrapActivationFailureClearsRuntimeAndOpensGate() throws {
        let store = makeStore()
        try store.save([.soniox: "fixture-token-a"])
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-runtime-token"
        runtime.rejectedSetScope = "soniox"
        let session = ProviderCredentialSession(runtime: runtime, fileStore: store)

        XCTAssertThrowsError(try session.bootstrapSavedCredentials())

        XCTAssertTrue(runtime.values.isEmpty)
        let snapshot = session.snapshot()
        XCTAssertTrue(snapshot.allSatisfy { !$0.isActive })
        XCTAssertEqual(
            Set(snapshot.filter(\.isSaved).map(\.account)),
            Set([.soniox])
        )
        XCTAssertEqual(runtime.bootstrapCompletionCount, 1)
    }

    func testMalformedBootstrapFailsClosedAndStillOpensGate() throws {
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-runtime-token"
        let session = ProviderCredentialSession(runtime: runtime, fileStore: makeStore())
        try writeFixture(Data("not-json".utf8))

        XCTAssertThrowsError(try session.bootstrapSavedCredentials())

        XCTAssertTrue(runtime.values.isEmpty)
        XCTAssertTrue(session.snapshot().allSatisfy { !$0.isSaved && !$0.isActive })
        XCTAssertEqual(runtime.bootstrapCompletionCount, 1)
    }

    func testMalformedBootstrapKeepsGateClosedWhenRuntimeCannotBeCleared() throws {
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-runtime-token"
        runtime.rejectedClearScope = "soniox"
        let session = ProviderCredentialSession(runtime: runtime, fileStore: makeStore())
        try writeFixture(Data("not-json".utf8))

        XCTAssertThrowsError(
            try session.bootstrapSavedCredentials()
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialSessionError,
                .runtimeCleanupFailed
            )
        }

        XCTAssertEqual(runtime.values["soniox"], "stale-runtime-token")
        XCTAssertEqual(runtime.bootstrapCompletionCount, 0)
        XCTAssertTrue(
            session.recoveryErrorDescription?.contains(
                ProviderCredentialSessionError.runtimeCleanupFailed.localizedDescription
            ) == true
        )
    }

    func testProcessOnlyBootstrapKeepsGateClosedWhenRuntimeCannotBeCleared() {
        let runtime = FakeRuntime()
        runtime.values["soniox"] = "stale-runtime-token"
        runtime.rejectedClearScope = "soniox"
        let session = ProviderCredentialSession(
            runtime: runtime,
            fileStore: FakePersistence(credentials: [:])
        )

        XCTAssertThrowsError(
            try session.bootstrapProcessOnlyCredential("fixture-token", for: .soniox)
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialSessionError,
                .runtimeCleanupFailed
            )
        }

        XCTAssertEqual(runtime.values["soniox"], "stale-runtime-token")
        XCTAssertEqual(runtime.bootstrapCompletionCount, 0)
        XCTAssertNotNil(session.recoveryErrorDescription)
    }

    func testLiveRuntimeFailsClosedWhenCoreIsUnavailable() {
        let runtime = LiveProviderCredentialRuntime(coreProvider: { nil })

        XCTAssertFalse(runtime.hasApiKey(scope: "soniox"))
        XCTAssertThrowsError(try runtime.setApiKey(scope: "soniox", value: "fixture-token")) {
            XCTAssertEqual($0 as? ProviderCredentialSessionError, .coreUnavailable)
        }
        XCTAssertThrowsError(try runtime.clearApiKey(scope: "soniox")) {
            XCTAssertEqual($0 as? ProviderCredentialSessionError, .coreUnavailable)
        }
    }

    private func makeStore() -> ProviderCredentialFileStore {
        ProviderCredentialFileStore(fileURL: credentialFileURL)
    }

    private func writeJSONFixture(_ object: [String: Any]) throws {
        try writeFixture(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func writeFixture(_ data: Data) throws {
        let directory = credentialFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: credentialFileURL)
        XCTAssertEqual(chmod(credentialFileURL.path, 0o600), 0)
    }

    private func assertPermissions(_ expected: Int, at url: URL) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, expected, "Unexpected mode for \(url.path)")
        } catch {
            XCTFail("Unable to inspect permissions for \(url.path): \(error)")
        }
    }
}
