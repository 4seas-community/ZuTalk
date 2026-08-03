import AppKit
import Foundation
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

enum KnowledgeEntrySource: String, Codable {
    case manual
    case agent
}

struct KnowledgeTerm: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var value: String
    var category: String = "term"
    var isEnabled: Bool = true
    var source: KnowledgeEntrySource = .manual
}

struct KnowledgeTranslationTerm: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceText: String
    var targetText: String
    var isEnabled: Bool = true
    var source: KnowledgeEntrySource = .manual
}

struct KnowledgeGeneralContext: Codable, Equatable {
    var topic = ""
    var setting = ""
    var location = ""
    var people = ""
    var organizations = ""
    var languages = ""
}

struct KnowledgeProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var summary = ""
    var general = KnowledgeGeneralContext()
    var backgroundText = ""
    var terms: [KnowledgeTerm] = []
    var translationTerms: [KnowledgeTranslationTerm] = []
    var additionalGeneral: [SonioxKnowledgeContext.GeneralItem] = []
    var translationLanguageA = "und"
    var translationLanguageB = "mul"
    var revision: UInt64 = 1
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?

    var sonioxContext: SonioxKnowledgeContext {
        let generalValues: [(String, String)] = [
            ("topic", general.topic),
            ("setting", general.setting),
            ("location", general.location),
            ("people", general.people),
            ("organizations", general.organizations),
            ("languages", general.languages),
        ] + additionalGeneral.map { ($0.key, $0.value) }
        return SonioxKnowledgeContext(
            general: generalValues.compactMap { key, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .init(key: key, value: trimmed)
            },
            text: backgroundText.trimmingCharacters(in: .whitespacesAndNewlines),
            terms: terms.filter(\.isEnabled).map(\.value).filter { $0.isEmpty == false },
            translationTerms: translationTerms.filter(\.isEnabled).compactMap {
                guard $0.sourceText.isEmpty == false, $0.targetText.isEmpty == false else { return nil }
                return .init(source: $0.sourceText, target: $0.targetText)
            }
        )
    }
}

struct SonioxKnowledgeContext: Codable, Equatable {
    struct GeneralItem: Codable, Equatable {
        let key: String
        let value: String
    }

    struct TranslationItem: Codable, Equatable {
        let source: String
        let target: String
    }

    let general: [GeneralItem]
    let text: String
    let terms: [String]
    let translationTerms: [TranslationItem]

    enum CodingKeys: String, CodingKey {
        case general, text, terms
        case translationTerms = "translation_terms"
    }
}

private struct KnowledgeContextPackDocument: Codable, Equatable {
    static let schemaV1 = "zulangue.context-pack.v1"

    var schema = schemaV1
    var title: String
    var sources: [KnowledgeContextPackSource]
}

private struct KnowledgeContextPackSource: Codable, Equatable {
    var title: String
    var format: String
    var contentKind: String
    var sha256: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case title, format, sha256, content
        case contentKind = "content_kind"
    }
}

@MainActor
final class KnowledgeProfileStore: ObservableObject {
    @Published private(set) var profiles: [KnowledgeProfile] = []
    @Published private(set) var persistenceError: String?

    private let client: any NotebookCaptureClienting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var packIDs: [UUID: String] = [:]
    private var documents: [UUID: KnowledgeContextPackDocument] = [:]
    private var persistedProfiles: [UUID: KnowledgeProfile] = [:]

    var activeProfiles: [KnowledgeProfile] {
        profiles.filter { $0.deletedAt == nil }
    }

    /// The encrypted Rust Context Pack store is the sole persistence authority.
    /// An injected client keeps the boundary testable without introducing a
    /// second file format or plaintext sidecar.
    init(client: (any NotebookCaptureClienting)? = nil) {
        self.client = client ?? RustNotebookCaptureClient()
        encoder = Self.makeEncoder()
        decoder = Self.makeDecoder()
        load()
    }

    @discardableResult
    func create(name: String) -> UUID {
        let title = normalizedTitle(name)
        do {
            let pack = try client.createLibraryContextPack(title: title)
            let id = try profileID(for: pack.id)
            let profile = KnowledgeProfile(id: id, name: pack.title, revision: pack.revision)
            packIDs[id] = pack.id
            documents[id] = KnowledgeContextPackDocument(title: pack.title, sources: [])
            persistedProfiles[id] = profile
            profiles.insert(profile, at: 0)
            persistenceError = nil
            return id
        } catch {
            persistenceError = error.localizedDescription
            return UUID()
        }
    }

    /// Replaces the encrypted Pack in one revision-checked Rust transaction.
    /// The returned value lets the editor show the authoritative revision only
    /// after the durable write has succeeded.
    @discardableResult
    func update(_ profile: KnowledgeProfile) -> KnowledgeProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return nil }
        do {
            var next = profile
            guard let packID = packIDs[profile.id] else {
                throw KnowledgeProfileStoreError.missingPack(profile.id)
            }
            let document = try contextPackDocument(
                from: profile,
                baseline: persistedProfiles[profile.id],
                original: documents[profile.id]
            )
            let documentJSON = String(
                decoding: try encoder.encode(document),
                as: UTF8.self
            )
            let saved = try client.replaceLibraryContextPack(
                packId: packID,
                expectedRevision: profiles[index].revision,
                documentJson: documentJSON
            )
            next.name = saved.title
            next.revision = saved.revision
            next.updatedAt = Date()
            profiles[index] = next
            profiles.sort { $0.updatedAt > $1.updatedAt }
            documents[profile.id] = document
            persistedProfiles[profile.id] = next
            persistenceError = nil
            return next
        } catch {
            persistenceError = error.localizedDescription
            return nil
        }
    }

    func delete(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        do {
            guard let packID = packIDs[id] else {
                throw KnowledgeProfileStoreError.missingPack(id)
            }
            _ = try client.deleteLibraryContextPack(
                packId: packID,
                expectedRevision: profiles[index].revision
            )
            profiles.remove(at: index)
            packIDs.removeValue(forKey: id)
            documents.removeValue(forKey: id)
            persistedProfiles.removeValue(forKey: id)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    /// Imports the established `.zulangue-pack.json` contract through Rust so
    /// schema, byte limits, source hashes and source formats are checked before
    /// a fresh encrypted Library Pack is created.
    @discardableResult
    func importJSON(from url: URL) throws -> UUID {
        let pack = try client.importContextPack(sourcePath: url.path, titleOverride: nil)
        let rawDocument = try client.readLibraryContextPack(packId: pack.id)
        let document = try decodeDocument(rawDocument)
        let profile = try decodeProfile(pack: pack, document: document)
        packIDs[profile.id] = pack.id
        documents[profile.id] = document
        persistedProfiles[profile.id] = profile
        profiles.removeAll { $0.id == profile.id }
        profiles.insert(profile, at: 0)
        persistenceError = nil
        return profile.id
    }

    func reload() {
        load()
    }

    private func load() {
        do {
            let packs = try client.listLibraryContextPacks()
            var loaded: [KnowledgeProfile] = []
            var loadedIDs: [UUID: String] = [:]
            var loadedDocuments: [UUID: KnowledgeContextPackDocument] = [:]
            var loadedProfiles: [UUID: KnowledgeProfile] = [:]
            for pack in packs.reversed() {
                let json = try client.readLibraryContextPack(packId: pack.id)
                let document = try decodeDocument(json)
                let profile = try decodeProfile(pack: pack, document: document)
                loaded.append(profile)
                loadedIDs[profile.id] = pack.id
                loadedDocuments[profile.id] = document
                loadedProfiles[profile.id] = profile
            }
            profiles = loaded
            packIDs = loadedIDs
            documents = loadedDocuments
            persistedProfiles = loadedProfiles
            persistenceError = nil
        } catch {
            profiles = []
            packIDs = [:]
            documents = [:]
            persistedProfiles = [:]
            persistenceError = error.localizedDescription
        }
    }

    private func decodeDocument(_ documentJSON: String) throws -> KnowledgeContextPackDocument {
        let document = try decoder.decode(
            KnowledgeContextPackDocument.self,
            from: Data(documentJSON.utf8)
        )
        guard document.schema == KnowledgeContextPackDocument.schemaV1 else {
            throw KnowledgeProfileStoreError.unsupportedSchema(document.schema)
        }
        return document
    }

    private func decodeProfile(
        pack: NotebookContextPackDTO,
        document: KnowledgeContextPackDocument
    ) throws -> KnowledgeProfile {
        var profile = KnowledgeProfile(
            id: try profileID(for: pack.id),
            name: document.title.isEmpty ? pack.title : document.title,
            revision: pack.revision
        )
        var background: [String] = []
        var seenTerms = Set<String>()
        var hasTranslationHeaders = false

        for source in document.sources {
            switch source.contentKind {
            case "general":
                for item in try parseGeneral(source.content) {
                    switch item.key {
                    case "summary": profile.summary = item.value
                    case "topic": profile.general.topic = item.value
                    case "setting": profile.general.setting = item.value
                    case "location": profile.general.location = item.value
                    case "people": profile.general.people = item.value
                    case "organizations": profile.general.organizations = item.value
                    case "languages": profile.general.languages = item.value
                    default: profile.additionalGeneral.append(item)
                    }
                }
            case "terms":
                for value in source.content
                    .components(separatedBy: .newlines)
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .filter({ $0.isEmpty == false })
                where seenTerms.insert(value).inserted {
                    profile.terms.append(.init(value: value))
                }
            case "translation_terms":
                let csv = try parseTranslationCSV(source.content)
                if hasTranslationHeaders == false {
                    profile.translationLanguageA = csv.languageA
                    profile.translationLanguageB = csv.languageB
                    hasTranslationHeaders = true
                }
                profile.translationTerms.append(contentsOf: csv.rows.map {
                    KnowledgeTranslationTerm(sourceText: $0.0, targetText: $0.1)
                })
            case "text":
                let text = source.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty == false { background.append(text) }
            default:
                throw KnowledgeProfileStoreError.unsupportedContentKind(source.contentKind)
            }
        }
        profile.backgroundText = background.joined(separator: "\n\n")
        return profile
    }

    private func contextPackDocument(
        from profile: KnowledgeProfile,
        baseline: KnowledgeProfile?,
        original: KnowledgeContextPackDocument?
    ) throws -> KnowledgeContextPackDocument {
        let canonical = try canonicalSources(from: profile)
        guard let baseline, let original else {
            return KnowledgeContextPackDocument(
                title: normalizedTitle(profile.name),
                sources: canonical
            )
        }

        var sources = original.sources
        if profile.summary != baseline.summary
            || profile.general != baseline.general
            || profile.additionalGeneral != baseline.additionalGeneral {
            sources = try replacingSources(
                kind: "general",
                in: sources,
                with: canonical.filter { $0.contentKind == "general" }
            )
        }
        if profile.backgroundText != baseline.backgroundText {
            sources = try replacingSources(
                kind: "text",
                in: sources,
                with: canonical.filter { $0.contentKind == "text" }
            )
        }
        if profile.terms != baseline.terms {
            sources = try replacingSources(
                kind: "terms",
                in: sources,
                with: canonical.filter { $0.contentKind == "terms" }
            )
        }
        if profile.translationTerms != baseline.translationTerms
            || profile.translationLanguageA != baseline.translationLanguageA
            || profile.translationLanguageB != baseline.translationLanguageB {
            sources = try replacingSources(
                kind: "translation_terms",
                in: sources,
                with: canonical.filter { $0.contentKind == "translation_terms" }
            )
        }

        return KnowledgeContextPackDocument(
            title: normalizedTitle(profile.name),
            sources: sources
        )
    }

    private func canonicalSources(
        from profile: KnowledgeProfile
    ) throws -> [KnowledgeContextPackSource] {
        let context = profile.sonioxContext
        var sources: [KnowledgeContextPackSource] = []
        var general: [String: String] = [:]
        for item in context.general { general[item.key] = item.value }
        let summary = profile.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty == false { general["summary"] = summary }

        if general.isEmpty == false {
            let data = try JSONSerialization.data(withJSONObject: general, options: [.sortedKeys])
            let content = String(decoding: data, as: UTF8.self)
            sources.append(contextSource(
                title: String(localized: "knowledge.general.title"),
                format: "text",
                contentKind: "general",
                content: content
            ))
        }
        if context.text.isEmpty == false {
            sources.append(contextSource(
                title: String(localized: "knowledge.background.title"),
                format: "text",
                contentKind: "text",
                content: context.text
            ))
        }
        if context.terms.isEmpty == false {
            sources.append(contextSource(
                title: String(localized: "knowledge.terms.title"),
                format: "text",
                contentKind: "terms",
                content: context.terms.joined(separator: "\n")
            ))
        }
        if context.translationTerms.isEmpty == false {
            let languageA = validLanguageHeader(profile.translationLanguageA, fallback: "und")
            var languageB = validLanguageHeader(profile.translationLanguageB, fallback: "mul")
            if languageA.caseInsensitiveCompare(languageB) == .orderedSame {
                languageB = languageA == "mul" ? "und" : "mul"
            }
            let header = "\(languageA),\(languageB)"
            let rows = context.translationTerms.map {
                "\(csvField($0.source)),\(csvField($0.target))"
            }
            sources.append(contextSource(
                title: String(localized: "knowledge.translations.title"),
                format: "translation_csv",
                contentKind: "translation_terms",
                content: ([header] + rows).joined(separator: "\n")
            ))
        }

        return sources
    }

    private func replacingSources(
        kind: String,
        in sources: [KnowledgeContextPackSource],
        with replacements: [KnowledgeContextPackSource]
    ) throws -> [KnowledgeContextPackSource] {
        let matchingIndices = sources.indices.filter { sources[$0].contentKind == kind }
        guard matchingIndices.count <= 1 else {
            throw KnowledgeProfileStoreError.ambiguousSourceEdit(kind)
        }
        guard let sourceIndex = matchingIndices.first else {
            return sources + replacements
        }

        var result = sources
        guard var replacement = replacements.first else {
            result.remove(at: sourceIndex)
            return result
        }

        // The profile editor owns the source's content, not its provenance.
        // Retain the imported title and Text/Markdown representation whenever a
        // single source can be edited without an ambiguous many-to-one merge.
        replacement.title = sources[sourceIndex].title
        replacement.format = sources[sourceIndex].format
        result[sourceIndex] = replacement
        return result
    }

    private func contextSource(
        title: String,
        format: String,
        contentKind: String,
        content: String
    ) -> KnowledgeContextPackSource {
        let digest = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return KnowledgeContextPackSource(
            title: title,
            format: format,
            contentKind: contentKind,
            sha256: digest,
            content: content
        )
    }

    private func parseGeneral(_ content: String) throws -> [SonioxKnowledgeContext.GeneralItem] {
        if let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: String] {
            return object.keys.sorted().compactMap { key in
                object[key].map { .init(key: key, value: $0) }
            }
        }
        return try content.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { return nil }
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                throw KnowledgeProfileStoreError.invalidGeneralLine(line)
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false, value.isEmpty == false else {
                throw KnowledgeProfileStoreError.invalidGeneralLine(line)
            }
            return .init(key: key, value: value)
        }
    }

    private func parseTranslationCSV(
        _ content: String
    ) throws -> (languageA: String, languageB: String, rows: [(String, String)]) {
        let records = try csvRecords(content)
        guard let header = records.first, header.count == 2 else {
            throw KnowledgeProfileStoreError.invalidTranslationCSV
        }
        let rows = try records.dropFirst().compactMap { record -> (String, String)? in
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            guard record.count == 2 else { throw KnowledgeProfileStoreError.invalidTranslationCSV }
            return (
                record[0].trimmingCharacters(in: .whitespacesAndNewlines),
                record[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (
            header[0].trimmingCharacters(in: .whitespacesAndNewlines),
            header[1].trimmingCharacters(in: .whitespacesAndNewlines),
            rows
        )
    }

    private func csvRecords(_ content: String) throws -> [[String]] {
        let scalars = Array(content)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var quoted = false
        var index = 0
        while index < scalars.count {
            let character = scalars[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
                index += 1
                continue
            }
            switch character {
            case "\"" where field.isEmpty && quoted == false:
                inQuotes = true
                quoted = true
            case "\"":
                throw KnowledgeProfileStoreError.invalidTranslationCSV
            case ",":
                record.append(field)
                field = ""
                quoted = false
            case "\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
                quoted = false
            case "\r":
                if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                record.append(field)
                records.append(record)
                record = []
                field = ""
                quoted = false
            default:
                field.append(character)
            }
            index += 1
        }
        guard inQuotes == false else { throw KnowledgeProfileStoreError.invalidTranslationCSV }
        if field.isEmpty == false || record.isEmpty == false || content.isEmpty == false {
            record.append(field)
            records.append(record)
        }
        return records
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func validLanguageHeader(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first,
              (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({
                  (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber }
              })
        else { return fallback }
        return value
    }

    private func normalizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "knowledge.untitled") : trimmed
    }

    private func profileID(for packID: String) throws -> UUID {
        guard let id = UUID(uuidString: packID) else {
            throw KnowledgeProfileStoreError.invalidPackID(packID)
        }
        return id
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum KnowledgeProfileStoreError: LocalizedError {
    case ambiguousSourceEdit(String)
    case invalidPackID(String)
    case missingPack(UUID)
    case unsupportedSchema(String)
    case unsupportedContentKind(String)
    case invalidGeneralLine(String)
    case invalidTranslationCSV

    var errorDescription: String? {
        switch self {
        case .ambiguousSourceEdit(let kind):
            return "This section comes from multiple JSON sources (\(kind)). Edit the source JSON before importing to avoid losing source data."
        case .invalidPackID(let value):
            return "Knowledge base has an invalid identifier: \(value)"
        case .missingPack(let id):
            return "Knowledge base \(id.uuidString) is no longer available."
        case .unsupportedSchema(let value):
            return "Unsupported knowledge-base schema: \(value)"
        case .unsupportedContentKind(let value):
            return "Unsupported knowledge-base content kind: \(value)"
        case .invalidGeneralLine(let value):
            return "Invalid overview entry: \(value)"
        case .invalidTranslationCSV:
            return "The preferred-translation CSV is invalid."
        }
    }
}

struct KnowledgeLibraryPage: View {
    @StateObject private var store = KnowledgeProfileStore()
    @State private var selectedID: UUID?
    @State private var isCreating = false
    @State private var newName = ""

    var body: some View {
        Group {
            if let selectedID,
               let profile = store.activeProfiles.first(where: { $0.id == selectedID }) {
                KnowledgeProfilePage(
                    profile: profile,
                    persistenceError: store.persistenceError,
                    onBack: { self.selectedID = nil },
                    onSave: store.update
                )
            } else {
                overview
            }
        }
        .background(Color.bgRoot)
        .sheet(isPresented: $isCreating) { createSheet }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "knowledge.title"))
                            .font(.titleLG)
                            .foregroundColor(.textPrimary)
                        Text(String(localized: "knowledge.subtitle"))
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer()
                    Button(action: chooseJSONToImport) {
                        Label(
                            String(localized: "knowledge.import_json"),
                            systemImage: "square.and.arrow.down"
                        )
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("knowledge.import_json")

                    Button {
                        newName = ""
                        isCreating = true
                    } label: {
                        Label(String(localized: "knowledge.new"), systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandAccent)
                    .accessibilityIdentifier("knowledge.new")
                }

                if let error = store.persistenceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bodySM)
                        .foregroundColor(.destructive)
                }

                if store.activeProfiles.isEmpty {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 36))
                            .foregroundColor(.brandAccent)
                        Text(String(localized: "knowledge.empty.title"))
                            .font(.titleMD)
                            .foregroundColor(.textPrimary)
                        Text(String(localized: "knowledge.empty.description"))
                            .font(.bodySM)
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: Spacing.md)],
                        spacing: Spacing.md
                    ) {
                        ForEach(store.activeProfiles) { profile in
                            Button { selectedID = profile.id } label: {
                                VStack(alignment: .leading, spacing: Spacing.md) {
                                    Image(systemName: "book.closed.fill")
                                        .foregroundColor(.brandAccent)
                                    Text(profile.name)
                                        .font(.titleMD)
                                        .foregroundColor(.textPrimary)
                                    Text(profile.summary.isEmpty
                                         ? String(localized: "knowledge.card.no_summary")
                                         : profile.summary)
                                        .font(.bodySM)
                                        .foregroundColor(.textSecondary)
                                        .lineLimit(3)
                                    Text(String(
                                        format: String(localized: "knowledge.card.counts"),
                                        profile.terms.filter(\.isEnabled).count,
                                        profile.translationTerms.filter(\.isEnabled).count
                                    ))
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                                }
                                .padding(Spacing.lg)
                                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                                .background(Color.bgElevated.opacity(0.36))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                                    .stroke(Color.borderGhost, lineWidth: Stroke.thin))
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(String(localized: "knowledge.new"))
                .font(.titleLG)
            TextField(String(localized: "knowledge.name"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createProfile)
            HStack {
                Spacer()
                Button(String(localized: "common.cancel")) { isCreating = false }
                Button(String(localized: "knowledge.create"), action: createProfile)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
    }

    private func createProfile() {
        selectedID = store.create(name: newName)
        isCreating = false
    }

    private func chooseJSONToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "knowledge.import_json.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selectedID = try store.importJSON(from: url)
            ToastCenter.shared.success(String(localized: "knowledge.import_json.done"))
        } catch {
            ToastCenter.shared.error(
                String(localized: "knowledge.import_json.failed"),
                detail: error.localizedDescription
            )
        }
    }
}

private struct KnowledgeProfilePage: View {
    @State private var draft: KnowledgeProfile
    @State private var lastSavedDraft: KnowledgeProfile
    @State private var savedRevision: UInt64
    @State private var saveTask: Task<Void, Never>?
    @State private var newTerm = ""

    let persistenceError: String?
    let onBack: () -> Void
    let onSave: (KnowledgeProfile) -> KnowledgeProfile?

    init(
        profile: KnowledgeProfile,
        persistenceError: String?,
        onBack: @escaping () -> Void,
        onSave: @escaping (KnowledgeProfile) -> KnowledgeProfile?
    ) {
        _draft = State(initialValue: profile)
        _lastSavedDraft = State(initialValue: profile)
        _savedRevision = State(initialValue: profile.revision)
        self.persistenceError = persistenceError
        self.onBack = onBack
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                contextMeter
                profileSection
                backgroundSection
                termsSection
                translationsSection
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear { _ = saveNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Button(action: leavePage) {
                    Label(String(localized: "knowledge.back"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    ToastCenter.shared.info(String(localized: "knowledge.ai.coming_soon"))
                } label: {
                    Label(String(localized: "knowledge.ai.improve"), systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }

            TextField(String(localized: "knowledge.name"), text: $draft.name)
                .textFieldStyle(.plain)
                .font(.titleLG)
                .foregroundColor(.textPrimary)
            TextField(String(localized: "knowledge.summary.placeholder"), text: $draft.summary)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.textSecondary)
            if let persistenceError {
                Label(
                    String(localized: "capture.settings.autosave.save_failed"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.captionMedium)
                .foregroundColor(.signalAmber)
                Text(persistenceError)
                    .font(.caption)
                    .foregroundColor(.signalAmber)
                    .textSelection(.enabled)
            } else {
                Text(String(
                    format: String(localized: "knowledge.saved_revision"),
                    Int64(savedRevision)
                ))
                .font(.caption)
                .foregroundColor(.textTertiary)
            }
        }
    }

    private var contextMeter: some View {
        let estimate = estimatedTokens
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label(String(localized: "knowledge.context.title"), systemImage: "waveform.badge.magnifyingglass")
                    .font(.bodyMedium)
                Spacer()
                Text("\(estimate.formatted()) / 8,000 tokens")
                    .font(.bodySM)
                    .foregroundColor(estimate > 8_000 ? .destructive : .textSecondary)
            }
            ProgressView(value: min(Double(estimate) / 8_000, 1))
                .tint(estimate > 8_000 ? .destructive : .brandAccent)
        }
        .padding(Spacing.md)
        .background(Color.bgElevated.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private var profileSection: some View {
        section(String(localized: "knowledge.general.title"), subtitle: String(localized: "knowledge.general.subtitle")) {
            VStack(spacing: Spacing.md) {
                field(String(localized: "knowledge.general.topic"), text: $draft.general.topic)
                field(String(localized: "knowledge.general.setting"), text: $draft.general.setting)
                field(String(localized: "knowledge.general.location"), text: $draft.general.location)
                field(String(localized: "knowledge.general.people"), text: $draft.general.people)
                field(String(localized: "knowledge.general.organizations"), text: $draft.general.organizations)
                field(String(localized: "knowledge.general.languages"), text: $draft.general.languages)
            }
        }
    }

    private var backgroundSection: some View {
        section(String(localized: "knowledge.background.title"), subtitle: String(localized: "knowledge.background.subtitle")) {
            TextEditor(text: $draft.backgroundText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .frame(minHeight: 180)
                .background(Color.bgElevated.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private var termsSection: some View {
        section(String(localized: "knowledge.terms.title"), subtitle: String(localized: "knowledge.terms.subtitle")) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach($draft.terms) { $term in
                    HStack {
                        TextField(String(localized: "knowledge.term.placeholder"), text: $term.value)
                        Button(role: .destructive) {
                            draft.terms.removeAll { $0.id == term.id }
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField(String(localized: "knowledge.term.add"), text: $newTerm)
                        .onSubmit(addTerm)
                    Button(action: addTerm) { Image(systemName: "plus") }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var translationsSection: some View {
        section(String(localized: "knowledge.translations.title"), subtitle: String(localized: "knowledge.translations.subtitle")) {
            VStack(spacing: Spacing.sm) {
                ForEach($draft.translationTerms) { $term in
                    HStack {
                        TextField(String(localized: "knowledge.translation.source"), text: $term.sourceText)
                        Image(systemName: "arrow.right").foregroundColor(.textTertiary)
                        TextField(String(localized: "knowledge.translation.target"), text: $term.targetText)
                        Button(role: .destructive) {
                            draft.translationTerms.removeAll { $0.id == term.id }
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    draft.translationTerms.append(.init(sourceText: "", targetText: ""))
                } label: {
                    Label(String(localized: "knowledge.translation.add"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.titleMD).foregroundColor(.textPrimary)
                Text(subtitle).font(.bodySM).foregroundColor(.textSecondary)
            }
            content()
        }
        .padding(Spacing.lg)
        .background(Color.bgElevated.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .stroke(Color.borderGhost, lineWidth: Stroke.thin))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(label)
                .font(.bodySM)
                .foregroundColor(.textSecondary)
                .frame(width: 110, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var estimatedTokens: Int {
        let context = draft.sonioxContext
        let general = context.general.map { "\($0.key) \($0.value)" }.joined(separator: " ")
        let terms = context.terms.joined(separator: " ")
        let translations = context.translationTerms
            .map { "\($0.source) \($0.target)" }.joined(separator: " ")
        return Int(ceil(Double((general + context.text + terms + translations).count) / 2.5))
    }

    private func addTerm() {
        let value = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }
        guard draft.terms.contains(where: { $0.value.localizedCaseInsensitiveCompare(value) == .orderedSame }) == false else {
            newTerm = ""
            return
        }
        draft.terms.append(.init(value: value))
        newTerm = ""
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard Task.isCancelled == false else { return }
            _ = saveNow()
        }
    }

    @discardableResult
    private func saveNow() -> Bool {
        saveTask?.cancel()
        guard draft != lastSavedDraft else { return true }
        guard let saved = onSave(draft) else { return false }
        draft.revision = saved.revision
        draft.updatedAt = saved.updatedAt
        lastSavedDraft = draft
        savedRevision = saved.revision
        return true
    }

    private func leavePage() {
        guard saveNow() else { return }
        onBack()
    }
}
