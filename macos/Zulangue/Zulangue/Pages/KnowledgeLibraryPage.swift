import Foundation
import Combine
import SwiftUI

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
        ]
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

@MainActor
final class KnowledgeProfileStore: ObservableObject {
    @Published private(set) var profiles: [KnowledgeProfile] = []
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var activeProfiles: [KnowledgeProfile] {
        profiles.filter { $0.deletedAt == nil }
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    @discardableResult
    func create(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = KnowledgeProfile(
            name: trimmed.isEmpty ? String(localized: "knowledge.untitled") : trimmed
        )
        profiles.insert(profile, at: 0)
        persist()
        return profile.id
    }

    func update(_ profile: KnowledgeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var next = profile
        next.revision = profiles[index].revision &+ 1
        next.updatedAt = Date()
        profiles[index] = next
        profiles.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func delete(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].deletedAt = Date()
        profiles[index].updatedAt = Date()
        profiles[index].revision &+= 1
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            profiles = try decoder.decode([KnowledgeProfile].self, from: Data(contentsOf: fileURL))
                .sorted { $0.updatedAt > $1.updatedAt }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Zulangue", isDirectory: true)
            .appendingPathComponent("knowledge-profiles.json")
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
                    onBack: { self.selectedID = nil },
                    onSave: store.update
                )
            } else {
                overview
            }
        }
        .background(Color.bpBlue)
        .sheet(isPresented: $isCreating) { createSheet }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "knowledge.title"))
                            .font(.titleLG)
                            .foregroundColor(.bpLine)
                        Text(String(localized: "knowledge.subtitle"))
                            .font(.bodySM)
                            .foregroundColor(.textOnBpDim)
                    }
                    Spacer()
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
                            .foregroundColor(.bpLine)
                        Text(String(localized: "knowledge.empty.description"))
                            .font(.bodySM)
                            .foregroundColor(.textOnBpDim)
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
                                        .foregroundColor(.bpLine)
                                    Text(profile.summary.isEmpty
                                         ? String(localized: "knowledge.card.no_summary")
                                         : profile.summary)
                                        .font(.bodySM)
                                        .foregroundColor(.textOnBpDim)
                                        .lineLimit(3)
                                    Text(String(
                                        format: String(localized: "knowledge.card.counts"),
                                        profile.terms.filter(\.isEnabled).count,
                                        profile.translationTerms.filter(\.isEnabled).count
                                    ))
                                    .font(.caption)
                                    .foregroundColor(.textOnBpFaint)
                                }
                                .padding(Spacing.lg)
                                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                                .background(Color.bpBlueLight.opacity(0.36))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                                    .stroke(Color.bpLineGhost, lineWidth: Stroke.thin))
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
}

private struct KnowledgeProfilePage: View {
    @State private var draft: KnowledgeProfile
    @State private var lastSavedDraft: KnowledgeProfile
    @State private var savedRevision: UInt64
    @State private var saveTask: Task<Void, Never>?
    @State private var newTerm = ""

    let onBack: () -> Void
    let onSave: (KnowledgeProfile) -> Void

    init(
        profile: KnowledgeProfile,
        onBack: @escaping () -> Void,
        onSave: @escaping (KnowledgeProfile) -> Void
    ) {
        _draft = State(initialValue: profile)
        _lastSavedDraft = State(initialValue: profile)
        _savedRevision = State(initialValue: profile.revision)
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
        .onDisappear { saveNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Button(action: onBack) {
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
                .foregroundColor(.bpLine)
            TextField(String(localized: "knowledge.summary.placeholder"), text: $draft.summary)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.textOnBpDim)
            Text(String(
                format: String(localized: "knowledge.saved_revision"),
                Int64(savedRevision)
            ))
            .font(.caption)
            .foregroundColor(.textOnBpFaint)
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
                    .foregroundColor(estimate > 8_000 ? .destructive : .textOnBpDim)
            }
            ProgressView(value: min(Double(estimate) / 8_000, 1))
                .tint(estimate > 8_000 ? .destructive : .brandAccent)
        }
        .padding(Spacing.md)
        .background(Color.bpBlueLight.opacity(0.34))
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
                .background(Color.bpBlueLight.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private var termsSection: some View {
        section(String(localized: "knowledge.terms.title"), subtitle: String(localized: "knowledge.terms.subtitle")) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach($draft.terms) { $term in
                    HStack {
                        Toggle("", isOn: $term.isEnabled).labelsHidden()
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
                        Toggle("", isOn: $term.isEnabled).labelsHidden()
                        TextField(String(localized: "knowledge.translation.source"), text: $term.sourceText)
                        Image(systemName: "arrow.right").foregroundColor(.textOnBpFaint)
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
                Text(title).font(.titleMD).foregroundColor(.bpLine)
                Text(subtitle).font(.bodySM).foregroundColor(.textOnBpDim)
            }
            content()
        }
        .padding(Spacing.lg)
        .background(Color.bpBlueLight.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .stroke(Color.bpLineGhost, lineWidth: Stroke.thin))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(label)
                .font(.bodySM)
                .foregroundColor(.textOnBpDim)
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
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard draft != lastSavedDraft else { return }
        onSave(draft)
        lastSavedDraft = draft
        savedRevision &+= 1
    }
}
