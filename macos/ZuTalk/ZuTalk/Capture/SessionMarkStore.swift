import Combine
import Foundation

/// One marked moment, as the UI needs it.
///
/// A view model rather than the FFI record so the excerpt can be pre-joined
/// into display lines once, instead of on every SwiftUI body evaluation during
/// a live capture.
struct SessionMarkViewModel: Identifiable, Equatable {
    let id: String
    let sessionId: String
    /// When the key went down, in capture milliseconds.
    let atMs: UInt64
    let startMs: UInt64
    let endMs: UInt64
    /// Whether the trailing edge still tracks the enclosing utterance.
    let endIsAuto: Bool
    /// The listener's own words. Nothing regenerates this.
    let note: String
    let lines: [SessionMarkLineViewModel]

    var isEmptyExcerpt: Bool { lines.isEmpty }

    /// `mm:ss` from the start of the recording, which is how a listener refers
    /// to a moment out loud.
    var startLabel: String { SessionMarkViewModel.clockLabel(startMs) }

    static func clockLabel(_ ms: UInt64) -> String {
        let totalSeconds = ms / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    init(_ mark: FfiSessionMark) {
        id = mark.id
        sessionId = mark.sessionId
        atMs = mark.atMs
        startMs = mark.startMs
        endMs = mark.endMs
        endIsAuto = mark.endIsAuto
        note = mark.note
        lines = mark.excerpt.map(SessionMarkLineViewModel.init)
    }
}

struct SessionMarkLineViewModel: Identifiable, Equatable {
    let id: String
    let sourceLanguage: String
    let sourceText: String
    let translatedLanguage: String?
    let translatedText: String?

    init(_ line: FfiSessionMarkLine) {
        id = line.utteranceId
        sourceLanguage = line.sourceLanguage
        sourceText = line.sourceText
        translatedLanguage = line.translatedLanguage
        translatedText = line.translatedText
    }

    /// What the listener was actually reading in the room. In a language they
    /// follow there is no translation lane, and the source is that text.
    var primaryText: String {
        guard let translatedText, !translatedText.isEmpty else { return sourceText }
        return translatedText
    }

    /// The original, when it differs from what was read.
    var secondaryText: String? {
        guard let translatedText, !translatedText.isEmpty else { return nil }
        return sourceText.isEmpty ? nil : sourceText
    }
}

/// Marks for one session.
///
/// Dropping a mark is the only thing here that happens while the listener is
/// still listening, so it is the only thing tuned for it: fire the write, take
/// the result, done. No reload, no round trip through a refresh — the returned
/// mark is already the mark, and a listener who pressed the key must see it
/// land immediately or they will press again.
@MainActor
final class SessionMarkStore: ObservableObject {
    static let shared = SessionMarkStore()

    @Published private(set) var marks: [SessionMarkViewModel] = []
    @Published private(set) var sessionId: String?
    @Published private(set) var lastError: String?
    /// The mark just created, so the panel can scroll to it and focus its note
    /// field. Cleared once consumed.
    @Published var pendingFocusMarkId: String?

    /// When the most recent mark was dropped, used to decide whether any
    /// excerpt could still be improving. Nil once nothing is settling.
    private var lastMarkAt: Date?

    private let coreProvider: @MainActor () -> (any ZuTalkCoreProtocol)?

    init(
        coreProvider: @escaping @MainActor () -> (any ZuTalkCoreProtocol)? = {
            CoreClient.shared.core
        }
    ) {
        self.coreProvider = coreProvider
    }

    /// Points the store at a session, reloading only when it actually changed.
    ///
    /// Re-pointing at the same session must not clear the list: the realtime
    /// page re-renders constantly during capture, and a list that blinks empty
    /// on every render is worse than no list.
    func load(sessionId: String?, force: Bool = false) {
        guard force || sessionId != self.sessionId else { return }
        self.sessionId = sessionId
        guard let sessionId, let core = coreProvider() else {
            marks = []
            return
        }
        do {
            marks = try core.sessionMarkList(sessionId: sessionId).map(SessionMarkViewModel.init)
            lastError = nil
        } catch {
            // Keep whatever is already on screen. A read failure is not
            // evidence that the listener's marks are gone.
            lastError = error.localizedDescription
        }
    }

    /// Drops a mark at the current capture position.
    ///
    /// The instant is deliberately not supplied: the app's timer is a wall
    /// clock and the transcript is stamped on the capture clock, so the core
    /// reads it from captured frames instead.
    @discardableResult
    func mark() -> Bool {
        guard let sessionId, let core = coreProvider() else { return false }
        do {
            let created = try core.sessionMarkCreate(sessionId: sessionId, atMs: nil)
            let model = SessionMarkViewModel(created)
            insert(model)
            lastMarkAt = Date()
            pendingFocusMarkId = model.id
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setNote(markId: String, note: String) {
        guard let core = coreProvider() else { return }
        do {
            replace(SessionMarkViewModel(try core.sessionMarkSetNote(markId: markId, note: note)))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setBounds(markId: String, startMs: UInt64, endMs: UInt64) {
        guard let core = coreProvider() else { return }
        do {
            replace(
                SessionMarkViewModel(
                    try core.sessionMarkSetBounds(
                        markId: markId,
                        startMs: startMs,
                        endMs: endMs
                    )
                )
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(markId: String) {
        guard let core = coreProvider() else { return }
        do {
            try core.sessionMarkDelete(markId: markId)
            marks.removeAll { $0.id == markId }
            if pendingFocusMarkId == markId { pendingFocusMarkId = nil }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-reads the marks for the current session.
    ///
    /// Excerpts are derived from transcript, and transcript keeps improving
    /// after a mark is dropped — a partial finalizes, the precision pass lands.
    /// This is how those improvements reach an already-visible card.
    func refreshExcerpts() {
        lastMarkAt = nil
        load(sessionId: sessionId, force: true)
    }

    /// The live-capture version, which does nothing almost all of the time.
    ///
    /// Rebuilding an excerpt costs a full transcript read, and during a long
    /// recording that is thousands of rows. Only a mark dropped moments ago
    /// can still be waiting on a partial to finalize, so only that window is
    /// worth paying for; everything else settles when the recording stops.
    func refreshSettlingExcerpts(now: Date = Date()) {
        guard Self.isSettling(lastMarkAt: lastMarkAt, now: now) else {
            lastMarkAt = nil
            return
        }
        load(sessionId: sessionId, force: true)
    }

    /// Whether any excerpt could still be waiting on a partial to finalize.
    ///
    /// Pure so the cost policy can be checked directly: getting this wrong in
    /// the permissive direction means a full transcript read every two seconds
    /// for the length of a lecture.
    static func isSettling(lastMarkAt: Date?, now: Date) -> Bool {
        guard let lastMarkAt else { return false }
        return now.timeIntervalSince(lastMarkAt) < settlingWindow
    }

    /// How long after a keypress an excerpt is still expected to change. A
    /// realtime partial finalizes well inside this.
    static let settlingWindow: TimeInterval = 20

    private func insert(_ mark: SessionMarkViewModel) {
        marks = Self.ordered(marks, upserting: mark)
    }

    private func replace(_ mark: SessionMarkViewModel) {
        insert(mark)
    }

    /// Places a new or edited mark along the recording.
    ///
    /// Capture order, matching the core's listing: a mark whose bounds were
    /// dragged is still the same moment, and sending it to the bottom of the
    /// rail would make the listener hunt for what they just edited.
    static func ordered(
        _ marks: [SessionMarkViewModel],
        upserting mark: SessionMarkViewModel
    ) -> [SessionMarkViewModel] {
        var result = marks.filter { $0.id != mark.id }
        let index = result.firstIndex { $0.atMs > mark.atMs } ?? result.endIndex
        result.insert(mark, at: index)
        return result
    }
}
