import Darwin
import Combine
import Foundation

/// Provider accounts supported by Rust's scoped in-memory credential runtime.
enum ProviderCredentialAccount: String, CaseIterable, Codable, Identifiable {
    case soniox

    var id: String { rawValue }

    var scope: String {
        "soniox"
    }

    var displayName: String {
        "Soniox"
    }

    init?(scope: String?) {
        guard let scope,
              let account = Self.allCases.first(where: { $0.scope == scope }) else {
            return nil
        }
        self = account
    }
}

/// Read-only product presentation for the one Notebook capture engine.
///
/// Provider credentials and Notebook egress consent remain separate concerns:
/// this value only describes the engine currently built into the Rust core.
/// The fallback intentionally omits model identifiers so Swift never invents a
/// second source of truth while generated bindings are being refreshed.
struct NotebookCaptureEnginePresentation: Equatable {
    let providerDisplayName: String
    let realtimeModelId: String?
    let postStopModelId: String?
    let postStopUsesRealtimeRestream: Bool?

    static var descriptorUnavailable: Self {
        Self(
            providerDisplayName: String(localized: "settings.services.engine.unavailable"),
            realtimeModelId: nil,
            postStopModelId: nil,
            postStopUsesRealtimeRestream: nil
        )
    }

    var realtimeSummary: String {
        [providerDisplayName, realtimeModelId]
            .compactMap { value in
                guard let value, value.isEmpty == false else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var postStopSummary: String {
        [providerDisplayName, postStopModelId]
            .compactMap { value in
                guard let value, value.isEmpty == false else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var postStopExecutionSummary: String {
        postStopUsesRealtimeRestream == true
            ? String(localized: "settings.services.engine.realtime_replay")
            : String(localized: "settings.services.engine.execution_unavailable")
    }
}

@MainActor
protocol NotebookCaptureEngineDescriptorLoading {
    func load() -> NotebookCaptureEnginePresentation
}

/// Single integration point for the Rust-owned fixed engine descriptor.
///
/// This is the sole Swift mapping from the Rust-owned engine descriptor. Views
/// consume the presentation store and never duplicate provider/model constants.
@MainActor
struct LiveNotebookCaptureEngineDescriptorLoader: NotebookCaptureEngineDescriptorLoading {
    func load() -> NotebookCaptureEnginePresentation {
        guard let descriptor = CoreClient.shared.core?.getNotebookCaptureEngineDescriptor() else {
            return .descriptorUnavailable
        }
        return NotebookCaptureEnginePresentation(
            providerDisplayName: descriptor.providerDisplayName,
            realtimeModelId: descriptor.realtimeModelId,
            postStopModelId: descriptor.postStopModelId,
            postStopUsesRealtimeRestream: descriptor.postStopExecution == .realtimeRestream
        )
    }
}

@MainActor
final class NotebookCaptureEnginePresentationStore: ObservableObject {
    static let shared = NotebookCaptureEnginePresentationStore()

    @Published private(set) var engine: NotebookCaptureEnginePresentation
    private let loader: any NotebookCaptureEngineDescriptorLoading

    init(loader: (any NotebookCaptureEngineDescriptorLoading)? = nil) {
        self.loader = loader ?? LiveNotebookCaptureEngineDescriptorLoader()
        self.engine = .descriptorUnavailable
    }

    func refresh() {
        engine = loader.load()
    }
}

struct ProviderCredentialSnapshot: Equatable {
    let account: ProviderCredentialAccount
    let scope: String
    let isSaved: Bool
    let isActive: Bool
}

/// Product-facing credential state. `loadedUnverified` deliberately describes
/// runtime availability, never provider connectivity, validity, or consent.
enum ProviderCredentialPresentationState: Equatable {
    case missing
    case savedInactive
    case savedLoadedUnverified
    case runtimeOnlyUnverified

    static func resolve(_ snapshot: ProviderCredentialSnapshot) -> Self {
        switch (snapshot.isSaved, snapshot.isActive) {
        case (false, false): .missing
        case (true, false): .savedInactive
        case (true, true): .savedLoadedUnverified
        case (false, true): .runtimeOnlyUnverified
        }
    }

    var localizedStatusTitle: String {
        switch self {
        case .savedLoadedUnverified:
            String(localized: "settings.credentials.applied")
        case .savedInactive:
            String(localized: "settings.credentials.saved_inactive")
        case .runtimeOnlyUnverified:
            String(localized: "settings.credentials.runtime_only")
        case .missing:
            String(localized: "settings.credentials.missing")
        }
    }
}

private struct ProviderCredentialFileDocument: Codable {
    let version: Int
    let credentials: [String: String]
}

enum ProviderCredentialStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case malformedDocument
    case unknownAccounts([String])
    case emptyCredential(String)
    case credentialTooLarge(String)
    case fileTooLarge
    case unsafePath(String)
    case wrongOwner(String)
    case operationFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return String(
                format: String(localized: "settings.credentials.error.unsupported_version_format"),
                version
            )
        case .malformedDocument:
            return String(localized: "settings.credentials.error.malformed_document")
        case .unknownAccounts:
            return String(localized: "settings.credentials.error.unknown_accounts")
        case let .emptyCredential(account):
            return String(
                format: String(localized: "settings.credentials.error.empty_credential_format"),
                account
            )
        case let .credentialTooLarge(account):
            return String(
                format: String(localized: "settings.credentials.error.credential_too_large_format"),
                account
            )
        case .fileTooLarge:
            return String(localized: "settings.credentials.error.file_too_large")
        case let .unsafePath(path):
            return String(
                format: String(localized: "settings.credentials.error.unsafe_path_format"),
                path
            )
        case let .wrongOwner(path):
            return String(
                format: String(localized: "settings.credentials.error.wrong_owner_format"),
                path
            )
        case let .operationFailed(operation, code):
            return String(
                format: String(localized: "settings.credentials.error.operation_failed_format"),
                operation,
                code
            )
        }
    }

    /// Validation failures describe a regular file whose contents cannot be
    /// trusted. An explicit Settings edit may replace that whole document.
    /// Path, ownership, and POSIX failures are never bypassed.
    var allowsExplicitReplacement: Bool {
        switch self {
        case .unsupportedVersion,
             .malformedDocument,
             .unknownAccounts,
             .emptyCredential,
             .credentialTooLarge,
             .fileTooLarge:
            return true
        case .unsafePath, .wrongOwner, .operationFailed:
            return false
        }
    }
}

/// App-private provider credential persistence for the user-approved
/// "trusted local macOS account" threat model.
///
/// This file store deliberately does not claim cryptographic protection. It
/// relies on a 0700 directory and 0600 regular file owned by the current user.
/// Values never enter UserDefaults, SQLite, logs, diagnostics, or source files.
protocol ProviderCredentialPersisting: AnyObject {
    func load() throws -> [ProviderCredentialAccount: String]
    func save(_ credentials: [ProviderCredentialAccount: String]) throws
    func updateCredentials(
        allowingReplacementOfUnreadableDocument: Bool,
        _ mutation: (
            inout [ProviderCredentialAccount: String],
            _ replacingUnreadableDocument: Bool
        ) throws -> Void
    ) throws -> [ProviderCredentialAccount: String]
    func delete() throws
}

final class ProviderCredentialFileStore: ProviderCredentialPersisting {
    static let documentVersion = 1
    static let maximumFileBytes = 64 * 1024
    static let maximumCredentialBytes = 16 * 1024
    static let lockFileName = ".provider-credentials.lock"
    static let temporaryFilePrefix = ".provider-credentials."
    static let temporaryFileSuffix = ".tmp"

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL(
        fileManager: FileManager = .default,
        useTestIsolation: Bool? = nil
    ) -> URL {
        let shouldIsolate = useTestIsolation
            ?? (TestEnvironment.isUnitTestMode || TestEnvironment.isUITestMode)
        let dataDirectory: URL
        if shouldIsolate {
            dataDirectory = URL(
                fileURLWithPath: CoreClient.defaultDataDir(),
                isDirectory: true
            )
        } else {
            dataDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Zulangue", isDirectory: true)
        }
        return dataDirectory
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("provider-credentials.json", isDirectory: false)
    }

    func load() throws -> [ProviderCredentialAccount: String] {
        try withExclusiveFileLock {
            try removeSafeStaleTemporaryFilesLocked()
            return try loadCredentialsLocked()
        }
    }

    func save(_ credentials: [ProviderCredentialAccount: String]) throws {
        let data = try encodeDocument(credentials)
        try withExclusiveFileLock {
            try removeSafeStaleTemporaryFilesLocked()
            try writePrivateFileAtomicallyLocked(data)
        }
    }

    func updateCredentials(
        allowingReplacementOfUnreadableDocument: Bool,
        _ mutation: (
            inout [ProviderCredentialAccount: String],
            _ replacingUnreadableDocument: Bool
        ) throws -> Void
    ) throws -> [ProviderCredentialAccount: String] {
        try withExclusiveFileLock {
            try removeSafeStaleTemporaryFilesLocked()

            var replacingUnreadableDocument = false
            var credentials: [ProviderCredentialAccount: String]
            do {
                credentials = try loadCredentialsLocked()
            } catch let error as ProviderCredentialStoreError
                where allowingReplacementOfUnreadableDocument
                    && error.allowsExplicitReplacement {
                credentials = [:]
                replacingUnreadableDocument = true
            }

            try mutation(&credentials, replacingUnreadableDocument)
            let data = try encodeDocument(credentials)
            try writePrivateFileAtomicallyLocked(data)
            return credentials
        }
    }

    func delete() throws {
        try withExclusiveFileLock {
            try removeSafeStaleTemporaryFilesLocked()

            var info = stat()
            guard lstat(fileURL.path, &info) == 0 else {
                if errno == ENOENT {
                    return
                }
                throw ProviderCredentialStoreError.operationFailed("file inspection", errno)
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw ProviderCredentialStoreError.unsafePath(fileURL.path)
            }
            guard info.st_uid == geteuid() else {
                throw ProviderCredentialStoreError.wrongOwner(fileURL.path)
            }
            guard unlink(fileURL.path) == 0 else {
                throw ProviderCredentialStoreError.operationFailed("file deletion", errno)
            }
            syncDirectoryBestEffort()
        }
    }

    private func loadCredentialsLocked() throws -> [ProviderCredentialAccount: String] {
        guard let data = try readPrivateFileIfPresentLocked() else {
            return [:]
        }
        return try decodeDocument(data)
    }

    private func decodeDocument(
        _ data: Data
    ) throws -> [ProviderCredentialAccount: String] {
        guard data.count <= Self.maximumFileBytes else {
            throw ProviderCredentialStoreError.fileTooLarge
        }

        let document: ProviderCredentialFileDocument
        do {
            document = try JSONDecoder().decode(ProviderCredentialFileDocument.self, from: data)
        } catch {
            throw ProviderCredentialStoreError.malformedDocument
        }
        guard document.version == Self.documentVersion else {
            throw ProviderCredentialStoreError.unsupportedVersion(document.version)
        }

        let knownNames = Set(ProviderCredentialAccount.allCases.map(\.rawValue))
        let unknownNames = document.credentials.keys
            .filter { !knownNames.contains($0) }
            .sorted()
        guard unknownNames.isEmpty else {
            throw ProviderCredentialStoreError.unknownAccounts(unknownNames)
        }

        var result: [ProviderCredentialAccount: String] = [:]
        for (rawAccount, value) in document.credentials {
            guard let account = ProviderCredentialAccount(rawValue: rawAccount) else {
                continue
            }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ProviderCredentialStoreError.emptyCredential(rawAccount)
            }
            guard normalized.utf8.count <= Self.maximumCredentialBytes else {
                throw ProviderCredentialStoreError.credentialTooLarge(rawAccount)
            }
            result[account] = normalized
        }
        return result
    }

    private func encodeDocument(
        _ credentials: [ProviderCredentialAccount: String]
    ) throws -> Data {
        var encodedCredentials: [String: String] = [:]
        for (account, value) in credentials {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ProviderCredentialStoreError.emptyCredential(account.rawValue)
            }
            guard normalized.utf8.count <= Self.maximumCredentialBytes else {
                throw ProviderCredentialStoreError.credentialTooLarge(account.rawValue)
            }
            encodedCredentials[account.rawValue] = normalized
        }

        let document = ProviderCredentialFileDocument(
            version: Self.documentVersion,
            credentials: encodedCredentials
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw ProviderCredentialStoreError.fileTooLarge
        }
        return data
    }

    private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
        try ensurePrivateDirectory()
        let lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.lockFileName, isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ProviderCredentialStoreError.operationFailed("lock file open", errno)
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("lock file inspection", errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderCredentialStoreError.unsafePath(lockURL.path)
        }
        guard info.st_uid == geteuid() else {
            throw ProviderCredentialStoreError.wrongOwner(lockURL.path)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("lock file permission update", errno)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw ProviderCredentialStoreError.operationFailed("credential file lock", errno)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        // Validate the descriptor again after waiting. The lock file is stable
        // across launches and is never replaced by credential updates.
        guard fstat(descriptor, &info) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("locked file inspection", errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw ProviderCredentialStoreError.unsafePath(lockURL.path)
        }
        return try operation()
    }

    private func ensurePrivateDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProviderCredentialStoreError.operationFailed("directory creation", errno)
        }

        var info = stat()
        guard lstat(directoryURL.path, &info) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("directory inspection", errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ProviderCredentialStoreError.unsafePath(directoryURL.path)
        }
        guard info.st_uid == geteuid() else {
            throw ProviderCredentialStoreError.wrongOwner(directoryURL.path)
        }
        guard chmod(directoryURL.path, mode_t(0o700)) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("directory permission update", errno)
        }
    }

    private func readPrivateFileIfPresentLocked() throws -> Data? {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT {
                return nil
            }
            throw ProviderCredentialStoreError.operationFailed("file open", errno)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("file inspection", errno)
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderCredentialStoreError.unsafePath(fileURL.path)
        }
        guard info.st_uid == geteuid() else {
            throw ProviderCredentialStoreError.wrongOwner(fileURL.path)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("file permission update", errno)
        }
        guard info.st_size >= 0, info.st_size <= off_t(Self.maximumFileBytes) else {
            throw ProviderCredentialStoreError.fileTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ProviderCredentialStoreError.operationFailed("file read", errno)
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= Self.maximumFileBytes else {
                throw ProviderCredentialStoreError.fileTooLarge
            }
        }
        return data
    }

    private func removeSafeStaleTemporaryFilesLocked() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            throw ProviderCredentialStoreError.operationFailed(
                "temporary file enumeration",
                Int32((error as NSError).code)
            )
        }

        var removedAny = false
        for childURL in children {
            let name = childURL.lastPathComponent
            guard name.hasPrefix(Self.temporaryFilePrefix),
                  name.hasSuffix(Self.temporaryFileSuffix),
                  name.count > Self.temporaryFilePrefix.count + Self.temporaryFileSuffix.count else {
                continue
            }

            var info = stat()
            guard lstat(childURL.path, &info) == 0 else {
                if errno == ENOENT {
                    continue
                }
                throw ProviderCredentialStoreError.operationFailed(
                    "temporary file inspection",
                    errno
                )
            }

            // Only remove files that match the exact artifact contract used by
            // this store. Symlinks, directories, foreign owners, and widened
            // modes are left untouched for explicit user inspection.
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid(),
                  (info.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                continue
            }
            guard unlink(childURL.path) == 0 else {
                if errno == ENOENT {
                    continue
                }
                throw ProviderCredentialStoreError.operationFailed(
                    "temporary file cleanup",
                    errno
                )
            }
            removedAny = true
        }

        if removedAny {
            syncDirectoryBestEffort()
        }
    }

    private func writePrivateFileAtomicallyLocked(_ data: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".provider-credentials.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }

        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ProviderCredentialStoreError.operationFailed("temporary file creation", errno)
        }
        // Set the final mode before writing the first secret byte. If the
        // process is killed during the write, the residue still matches the
        // narrowly-scoped stale-file cleanup contract on the next launch.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let permissionError = errno
            _ = close(descriptor)
            throw ProviderCredentialStoreError.operationFailed(
                "temporary file permission update",
                permissionError
            )
        }

        // Open the directory before committing so every operation that can
        // reject the write happens while the old destination is untouched.
        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            let openError = errno
            _ = close(descriptor)
            throw ProviderCredentialStoreError.operationFailed("directory open", openError)
        }
        defer { _ = close(directoryDescriptor) }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw ProviderCredentialStoreError.operationFailed("file write", errno)
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ProviderCredentialStoreError.operationFailed("file sync", errno)
            }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("file close", errno)
        }

        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw ProviderCredentialStoreError.operationFailed("atomic replace", errno)
        }
        shouldRemoveTemporaryFile = false

        // rename(2) is the commit point. The destination now contains the
        // already-fsynced 0600 file, so durability sync is best effort and no
        // error is reported after a successful commit.
        _ = fsync(directoryDescriptor)
    }

    private func syncDirectoryBestEffort() {
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { return }
        _ = fsync(directoryDescriptor)
        _ = close(directoryDescriptor)
    }
}

enum ProviderCredentialSessionError: LocalizedError, Equatable {
    case coreUnavailable
    case emptyValue
    case activationFailed(String)
    case clearFailed(String)
    case persistenceFailed
    case runtimeCleanupFailed

    var errorDescription: String? {
        switch self {
        case .coreUnavailable:
            return String(localized: "settings.credentials.error.core_unavailable")
        case .emptyValue:
            return String(localized: "settings.credentials.error.empty_value")
        case let .activationFailed(scope):
            return String(
                format: String(localized: "settings.credentials.error.activation_failed_format"),
                scope
            )
        case let .clearFailed(scope):
            return String(
                format: String(localized: "settings.credentials.error.clear_failed_format"),
                scope
            )
        case .persistenceFailed:
            return String(localized: "settings.credentials.error.persistence_failed")
        case .runtimeCleanupFailed:
            return String(localized: "settings.credentials.error.runtime_cleanup_failed")
        }
    }
}

@MainActor
protocol ProviderCredentialRuntimeAccess {
    func hasApiKey(scope: String) -> Bool
    func setApiKey(scope: String, value: String) throws
    func clearApiKey(scope: String) throws
    func completeBootstrap()
}

@MainActor
struct LiveProviderCredentialRuntime: ProviderCredentialRuntimeAccess {
    private let coreProvider: @MainActor () -> (any ZulangueCoreProtocol)?

    init(
        coreProvider: @escaping @MainActor () -> (any ZulangueCoreProtocol)? = {
            CoreClient.shared.core
        }
    ) {
        self.coreProvider = coreProvider
    }

    private func requireCore() throws -> any ZulangueCoreProtocol {
        guard let core = coreProvider() else {
            throw ProviderCredentialSessionError.coreUnavailable
        }
        return core
    }

    func hasApiKey(scope: String) -> Bool {
        coreProvider()?.hasApiKey(scope: scope) ?? false
    }

    func setApiKey(scope: String, value: String) throws {
        try requireCore().setApiKey(scope: scope, value: value)
    }

    func clearApiKey(scope: String) throws {
        try requireCore().clearApiKey(scope: scope)
    }

    func completeBootstrap() {
        coreProvider()?.completeProviderCredentialBootstrap()
    }
}

@MainActor
protocol ProviderCredentialValidating {
    func verify(
        _ candidate: String?,
        for account: ProviderCredentialAccount
    ) async -> ProviderConnectionVerificationState
}

@MainActor
struct LiveProviderCredentialValidator: ProviderCredentialValidating {
    private let coreProvider: @MainActor () -> (any ZulangueCoreProtocol)?

    init(
        coreProvider: @escaping @MainActor () -> (any ZulangueCoreProtocol)? = {
            CoreClient.shared.core
        }
    ) {
        self.coreProvider = coreProvider
    }

    func verify(
        _ candidate: String?,
        for account: ProviderCredentialAccount
    ) async -> ProviderConnectionVerificationState {
        guard let core = coreProvider() else {
            return .serviceUnavailable(Date())
        }
        do {
            let check = try await core.verifyApiKey(
                scope: account.scope,
                candidate: candidate
            )
            let checkedAt = Date(
                timeIntervalSince1970: TimeInterval(check.checkedAtMs) / 1_000
            )
            switch check.status {
            case .ready:
                return .ready(checkedAt)
            case .invalidCredential:
                return .invalidCredential(checkedAt)
            case .organizationBalanceExhausted:
                return .organizationBalanceExhausted(checkedAt)
            case .organizationMonthlyBudgetExhausted:
                return .organizationMonthlyBudgetExhausted(checkedAt)
            case .projectMonthlyBudgetExhausted:
                return .projectMonthlyBudgetExhausted(checkedAt)
            case .quotaExhausted:
                return .quotaExhausted(checkedAt)
            case .networkUnavailable:
                return .networkUnavailable(checkedAt)
            case .rateLimited:
                return .rateLimited(checkedAt)
            case .serviceUnavailable:
                return .serviceUnavailable(checkedAt)
            }
        } catch {
            return .serviceUnavailable(Date())
        }
    }
}

enum ProviderConnectionVerificationState: Equatable {
    case unverified
    case checking
    case ready(Date)
    case invalidCredential(Date)
    case organizationBalanceExhausted(Date)
    case organizationMonthlyBudgetExhausted(Date)
    case projectMonthlyBudgetExhausted(Date)
    case quotaExhausted(Date)
    case networkUnavailable(Date)
    case rateLimited(Date)
    case serviceUnavailable(Date)

    var checkedAt: Date? {
        switch self {
        case .unverified, .checking:
            nil
        case .ready(let date),
             .invalidCredential(let date),
             .organizationBalanceExhausted(let date),
             .organizationMonthlyBudgetExhausted(let date),
             .projectMonthlyBudgetExhausted(let date),
             .quotaExhausted(let date),
             .networkUnavailable(let date),
             .rateLimited(let date),
             .serviceUnavailable(let date):
            date
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

/// Event-driven, single-flight verification shared by Settings and onboarding.
/// It installs no timer and never retains credential material.
@MainActor
final class ProviderConnectionVerificationStore: ObservableObject {
    static let shared = ProviderConnectionVerificationStore()
    static let freshnessInterval: TimeInterval = 6 * 60 * 60
    static let failureFreshnessInterval: TimeInterval = 60

    @Published private(set) var states: [
        ProviderCredentialAccount: ProviderConnectionVerificationState
    ] = [:]

    private let validator: any ProviderCredentialValidating
    private let now: () -> Date
    private var tasks: [ProviderCredentialAccount: Task<Void, Never>] = [:]

    init(
        validator: (any ProviderCredentialValidating)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.validator = validator ?? LiveProviderCredentialValidator()
        self.now = now
    }

    func state(
        for account: ProviderCredentialAccount
    ) -> ProviderConnectionVerificationState {
        states[account] ?? .unverified
    }

    func verifyIfNeeded(
        account: ProviderCredentialAccount,
        isConfigured: Bool,
        force: Bool = false
    ) {
        guard isConfigured else {
            reset(account)
            return
        }
        guard tasks[account] == nil else { return }
        if !force,
           let checkedAt = state(for: account).checkedAt,
           now().timeIntervalSince(checkedAt) < freshnessInterval(for: state(for: account)) {
            return
        }

        states[account] = .checking
        let validator = self.validator
        tasks[account] = Task { @MainActor [weak self] in
            let result = await validator.verify(nil, for: account)
            guard let self, !Task.isCancelled else { return }
            states[account] = result
            tasks[account] = nil
        }
    }

    func verifyCandidate(
        _ candidate: String,
        for account: ProviderCredentialAccount
    ) async -> ProviderConnectionVerificationState {
        tasks[account]?.cancel()
        tasks[account] = nil
        states[account] = .checking
        let result = await validator.verify(candidate, for: account)
        guard !Task.isCancelled else { return .unverified }
        states[account] = result
        return result
    }

    func reset(_ account: ProviderCredentialAccount) {
        tasks[account]?.cancel()
        tasks[account] = nil
        states[account] = .unverified
    }

    private func freshnessInterval(
        for state: ProviderConnectionVerificationState
    ) -> TimeInterval {
        switch state {
        case .ready, .invalidCredential:
            Self.freshnessInterval
        case .organizationBalanceExhausted,
             .organizationMonthlyBudgetExhausted,
             .projectMonthlyBudgetExhausted,
             .quotaExhausted,
             .networkUnavailable,
             .rateLimited,
             .serviceUnavailable:
            Self.failureFreshnessInterval
        case .unverified, .checking:
            0
        }
    }
}

@MainActor
protocol ProviderCredentialSessioning {
    var recoveryErrorDescription: String? { get }

    func has(_ account: ProviderCredentialAccount) -> Bool
    func apply(_ value: String, for account: ProviderCredentialAccount) throws
    func clear(_ account: ProviderCredentialAccount) throws
    func resetSavedCredentials() throws
    func snapshot() -> [ProviderCredentialSnapshot]
}

private struct ProviderCredentialRuntimeMutationError: Error {
    let underlying: Error
}

/// The only product boundary for the Soniox provider credential.
///
/// It owns the transaction between the user-approved private file and Rust's
/// process memory. There is deliberately no credential getter for UI callers.
@MainActor
final class ProviderCredentialSession: ObservableObject, ProviderCredentialSessioning {
    static let shared = ProviderCredentialSession()

    /// Allows read-only UI surfaces to refresh boolean readiness snapshots.
    /// Secrets remain inaccessible and never enter observable state.
    @Published private(set) var statusRevision: UInt64 = 0

    private let runtime: any ProviderCredentialRuntimeAccess
    private let fileStore: any ProviderCredentialPersisting
    private var savedAccounts: Set<ProviderCredentialAccount> = []
    private(set) var recoveryErrorDescription: String?

    init(
        runtime: (any ProviderCredentialRuntimeAccess)? = nil,
        fileStore: (any ProviderCredentialPersisting)? = nil
    ) {
        self.runtime = runtime ?? LiveProviderCredentialRuntime()
        self.fileStore = fileStore ?? ProviderCredentialFileStore()
    }

    /// Restores the current private credential document into Rust process
    /// memory. The durable worker gate opens only after activation succeeds or
    /// the runtime is proven empty; an uncleared runtime keeps remote work
    /// gated.
    func bootstrapSavedCredentials() throws {
        defer { publishStatusChange() }
        do {
            try activateSavedCredentials()
        } catch {
            let failureDescription = error.localizedDescription
            guard clearAllRuntimeCredentialsBestEffort() else {
                let cleanupError = ProviderCredentialSessionError.runtimeCleanupFailed
                recoveryErrorDescription = [
                    failureDescription,
                    cleanupError.localizedDescription,
                ].joined(separator: "\n")
                throw cleanupError
            }
            recoveryErrorDescription = failureDescription
            runtime.completeBootstrap()
            throw error
        }

        runtime.completeBootstrap()
    }

    /// UI tests use an isolated data directory and a process-only fixture key.
    /// This path never loads, deletes, or writes the signed-in user's provider
    /// credential document.
    func bootstrapProcessOnlyCredential(
        _ value: String,
        for account: ProviderCredentialAccount
    ) throws {
        defer { publishStatusChange() }
        savedAccounts = []
        recoveryErrorDescription = nil
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            guard !normalized.isEmpty else {
                throw ProviderCredentialSessionError.emptyValue
            }
            try clearRuntimeCredentials()
            try runtime.setApiKey(scope: account.scope, value: normalized)
            guard runtime.hasApiKey(scope: account.scope) else {
                throw ProviderCredentialSessionError.activationFailed(account.scope)
            }
            runtime.completeBootstrap()
        } catch {
            let failureDescription = error.localizedDescription
            guard clearAllRuntimeCredentialsBestEffort() else {
                let cleanupError = ProviderCredentialSessionError.runtimeCleanupFailed
                recoveryErrorDescription = [
                    failureDescription,
                    cleanupError.localizedDescription,
                ].joined(separator: "\n")
                throw cleanupError
            }
            recoveryErrorDescription = failureDescription
            runtime.completeBootstrap()
            throw error
        }
    }

    /// Installs a short-lived credential for the current process without
    /// writing it to the durable provider credential document.
    func activateProcessOnlyCredential(
        _ value: String,
        for account: ProviderCredentialAccount
    ) throws {
        defer { publishStatusChange() }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ProviderCredentialSessionError.emptyValue
        }
        try runtime.setApiKey(scope: account.scope, value: normalized)
        guard runtime.hasApiKey(scope: account.scope) else {
            throw ProviderCredentialSessionError.activationFailed(account.scope)
        }
    }

    func activateSavedCredentials() throws {
        savedAccounts = []
        recoveryErrorDescription = nil

        do {
            try clearRuntimeCredentials()
            let credentials = try fileStore.load()
            // Persisted state is known as soon as the document validates. If
            // runtime activation later fails, diagnostics must show saved but
            // inactive instead of pretending the durable keys disappeared.
            savedAccounts = Set(credentials.keys)
            for account in ProviderCredentialAccount.allCases {
                guard let value = credentials[account] else {
                    continue
                }
                try runtime.setApiKey(scope: account.scope, value: value)
                guard runtime.hasApiKey(scope: account.scope) else {
                    throw ProviderCredentialSessionError.activationFailed(account.scope)
                }
            }
        } catch {
            clearAllRuntimeCredentialsBestEffort()
            recoveryErrorDescription = error.localizedDescription
            throw error
        }
    }

    func has(_ account: ProviderCredentialAccount) -> Bool {
        savedAccounts.contains(account) && runtime.hasApiKey(scope: account.scope)
    }

    func apply(_ value: String, for account: ProviderCredentialAccount) throws {
        defer { publishStatusChange() }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ProviderCredentialSessionError.emptyValue
        }

        var mutationStarted = false
        var replacingUnreadableDocument = false
        var previousValue: String?
        var wasActive = false
        var previousSavedAccounts = savedAccounts
        let committedCredentials: [ProviderCredentialAccount: String]
        do {
            committedCredentials = try fileStore.updateCredentials(
                allowingReplacementOfUnreadableDocument: true
            ) { credentials, replacingUnreadable in
                mutationStarted = true
                replacingUnreadableDocument = replacingUnreadable
                previousValue = credentials[account]
                wasActive = runtime.hasApiKey(scope: account.scope)
                previousSavedAccounts = Set(credentials.keys)

                // The credential document has been read but not mutated. Revoke
                // runtime visibility before changing the in-memory document or
                // reaching the atomic file commit.
                do {
                    if replacingUnreadable {
                        try clearRuntimeCredentials()
                    } else {
                        try clearRuntimeCredential(account)
                    }
                } catch {
                    throw ProviderCredentialRuntimeMutationError(underlying: error)
                }
                credentials[account] = normalized
            }
        } catch let error as ProviderCredentialRuntimeMutationError {
            if replacingUnreadableDocument
                || !restoreRuntime(previousValue, wasActive: wasActive, account: account) {
                clearAllRuntimeCredentialsBestEffort()
            }
            savedAccounts = replacingUnreadableDocument ? [] : previousSavedAccounts
            recoveryErrorDescription = error.underlying.localizedDescription
            throw error.underlying
        } catch {
            guard mutationStarted else {
                recoveryErrorDescription = error.localizedDescription
                throw error
            }

            if replacingUnreadableDocument {
                clearAllRuntimeCredentialsBestEffort()
                savedAccounts = []
            } else {
                if !restoreRuntime(previousValue, wasActive: wasActive, account: account) {
                    clearAllRuntimeCredentialsBestEffort()
                }
                // save is commit-or-unchanged, so the old account map is still
                // durable even if runtime restoration failed.
                savedAccounts = previousSavedAccounts
            }
            recoveryErrorDescription = ProviderCredentialSessionError.persistenceFailed.localizedDescription
            throw ProviderCredentialSessionError.persistenceFailed
        }

        // The rename has committed. From here on the new durable key is the
        // truth even if Rust activation fails, so diagnostics must report it
        // as saved/inactive rather than rolling the file back.
        savedAccounts = Set(committedCredentials.keys)
        do {
            try runtime.setApiKey(scope: account.scope, value: normalized)
            guard runtime.hasApiKey(scope: account.scope) else {
                throw ProviderCredentialSessionError.activationFailed(account.scope)
            }
            recoveryErrorDescription = nil
            runtime.completeBootstrap()
        } catch {
            let activationDescription = error.localizedDescription
            guard clearRuntimeCredentialBestEffort(account) else {
                let cleanupError = ProviderCredentialSessionError.runtimeCleanupFailed
                recoveryErrorDescription = [
                    activationDescription,
                    cleanupError.localizedDescription,
                ].joined(separator: "\n")
                throw cleanupError
            }
            recoveryErrorDescription = activationDescription
            runtime.completeBootstrap()
            throw error
        }
    }

    func clear(_ account: ProviderCredentialAccount) throws {
        defer { publishStatusChange() }
        var mutationStarted = false
        var previousValue: String?
        var wasActive = false
        var previousSavedAccounts = savedAccounts
        do {
            let committedCredentials = try fileStore.updateCredentials(
                allowingReplacementOfUnreadableDocument: false
            ) { credentials, _ in
                mutationStarted = true
                previousValue = credentials[account]
                wasActive = runtime.hasApiKey(scope: account.scope)
                previousSavedAccounts = Set(credentials.keys)

                do {
                    try runtime.clearApiKey(scope: account.scope)
                    guard !runtime.hasApiKey(scope: account.scope) else {
                        throw ProviderCredentialSessionError.clearFailed(account.scope)
                    }
                } catch {
                    throw ProviderCredentialRuntimeMutationError(underlying: error)
                }
                credentials.removeValue(forKey: account)
            }

            savedAccounts = Set(committedCredentials.keys)
            recoveryErrorDescription = nil
            runtime.completeBootstrap()
        } catch let error as ProviderCredentialRuntimeMutationError {
            if !restoreRuntime(previousValue, wasActive: wasActive, account: account) {
                clearAllRuntimeCredentialsBestEffort()
            }
            savedAccounts = previousSavedAccounts
            recoveryErrorDescription = error.underlying.localizedDescription
            throw error.underlying
        } catch {
            guard mutationStarted else {
                recoveryErrorDescription = error.localizedDescription
                throw error
            }

            if !restoreRuntime(previousValue, wasActive: wasActive, account: account) {
                clearAllRuntimeCredentialsBestEffort()
            }
            // save is commit-or-unchanged; retain the durable truth even when
            // the old runtime value cannot be restored.
            savedAccounts = previousSavedAccounts
            recoveryErrorDescription = ProviderCredentialSessionError.persistenceFailed.localizedDescription
            throw ProviderCredentialSessionError.persistenceFailed
        }
    }

    /// Explicit recovery for an unreadable provider credential document.
    /// The action is intentionally all-or-nothing because account membership
    /// cannot be trusted when the document itself failed validation.
    func resetSavedCredentials() throws {
        defer { publishStatusChange() }
        let previousSavedAccounts = savedAccounts
        do {
            try clearRuntimeCredentials()
            try fileStore.delete()
            savedAccounts = []
            recoveryErrorDescription = nil
            runtime.completeBootstrap()
        } catch {
            clearAllRuntimeCredentialsBestEffort()
            // delete either commits or leaves the old file untouched.
            savedAccounts = previousSavedAccounts
            recoveryErrorDescription = error.localizedDescription
            throw error
        }
    }

    func snapshot() -> [ProviderCredentialSnapshot] {
        ProviderCredentialAccount.allCases.map { account in
            ProviderCredentialSnapshot(
                account: account,
                scope: account.scope,
                isSaved: savedAccounts.contains(account),
                isActive: runtime.hasApiKey(scope: account.scope)
            )
        }
    }

    private func publishStatusChange() {
        statusRevision &+= 1
    }

    private func clearRuntimeCredentials() throws {
        for account in ProviderCredentialAccount.allCases {
            try clearRuntimeCredential(account)
        }
    }

    private func clearRuntimeCredential(_ account: ProviderCredentialAccount) throws {
        try runtime.clearApiKey(scope: account.scope)
        guard !runtime.hasApiKey(scope: account.scope) else {
            throw ProviderCredentialSessionError.clearFailed(account.scope)
        }
    }

    private func clearRuntimeCredentialBestEffort(
        _ account: ProviderCredentialAccount
    ) -> Bool {
        do {
            try clearRuntimeCredential(account)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func clearAllRuntimeCredentialsBestEffort() -> Bool {
        var clearedAll = true
        for account in ProviderCredentialAccount.allCases {
            do {
                try runtime.clearApiKey(scope: account.scope)
                if runtime.hasApiKey(scope: account.scope) {
                    clearedAll = false
                }
            } catch {
                clearedAll = false
            }
        }
        return clearedAll
    }

    private func restoreRuntime(
        _ previousValue: String?,
        wasActive: Bool,
        account: ProviderCredentialAccount
    ) -> Bool {
        if wasActive, let previousValue {
            do {
                try runtime.setApiKey(scope: account.scope, value: previousValue)
                return runtime.hasApiKey(scope: account.scope)
            } catch {
                return false
            }
        } else {
            do {
                try runtime.clearApiKey(scope: account.scope)
                return !runtime.hasApiKey(scope: account.scope)
            } catch {
                return false
            }
        }
    }
}
