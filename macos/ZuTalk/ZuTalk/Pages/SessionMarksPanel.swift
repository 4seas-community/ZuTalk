import SwiftUI

/// The materials rail: every moment the listener flagged, newest work at the
/// bottom, each card holding the passage it captured and room to say why.
///
/// This is the only writing surface that makes sense while a room is still
/// talking. A blank page asks someone following a foreign language to compose;
/// a card that already contains what was just said asks them only to react.
struct SessionMarksPanel: View {
    let sessionId: String?
    /// Whether a keypress can currently drop a mark. Marks are a live gesture;
    /// after the recording ends the rail becomes a reading and editing surface.
    let isLive: Bool
    let onMark: () -> Void

    @ObservedObject private var store = SessionMarkStore.shared
    @FocusState private var focusedNoteId: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.borderGhost.opacity(0.4))

            if store.marks.isEmpty {
                emptyState
            } else {
                markList
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.bgSunken.opacity(0.28))
        .accessibilityIdentifier("session.marks.panel")
        .onChange(of: store.pendingFocusMarkId) { markId in
            guard let markId else { return }
            focusedNoteId = markId
            store.pendingFocusMarkId = nil
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text(String(localized: "session.marks.title"))
                .font(.captionMedium)
                .foregroundColor(.textSecondary)

            if !store.marks.isEmpty {
                Text("\(store.marks.count)")
                    .font(.monoNum11)
                    .foregroundColor(.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.bgElevated.opacity(0.7))
                    )
            }

            Spacer(minLength: Spacing.sm)

            if isLive {
                Button(action: onMark) {
                    Label(
                        String(localized: "session.marks.add"),
                        systemImage: "bookmark.fill"
                    )
                    .font(.captionMedium)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.brandAccent)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Color.brandAccent.opacity(0.14))
                )
                .help(String(localized: "session.marks.add.hint"))
                .accessibilityIdentifier("session.marks.add")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "bookmark")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(.textTertiary.opacity(0.7))
            Text(String(localized: isLive
                ? "session.marks.empty.live"
                : "session.marks.empty.done"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("session.marks.empty")
    }

    private var markList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(store.marks) { mark in
                        SessionMarkCard(
                            mark: mark,
                            focusedNoteId: $focusedNoteId,
                            onNoteCommit: { store.setNote(markId: mark.id, note: $0) },
                            onDelete: { store.delete(markId: mark.id) }
                        )
                        .id(mark.id)
                    }
                }
                .padding(Spacing.sm)
            }
            .onChange(of: store.marks.count) { _ in
                // A fresh mark is the reason the rail exists; bring it into
                // view without stealing the listener's scroll position for
                // anything else.
                guard let last = store.marks.last else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

/// One marked moment: when, what was said, and what the listener made of it.
private struct SessionMarkCard: View {
    let mark: SessionMarkViewModel
    @FocusState.Binding var focusedNoteId: String?
    let onNoteCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String
    @State private var isHovering = false
    @State private var showsRawExcerpt = false
    @State private var isConfirmingDelete = false

    init(
        mark: SessionMarkViewModel,
        focusedNoteId: FocusState<String?>.Binding,
        onNoteCommit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.mark = mark
        self._focusedNoteId = focusedNoteId
        self.onNoteCommit = onNoteCommit
        self.onDelete = onDelete
        self._draft = State(initialValue: mark.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                // The moment is a link back to the passage it marks.
                Button {
                    NotificationCenter.default.post(
                        name: .zutalkRevealTranscriptMoment,
                        object: nil,
                        userInfo: ["sessionId": mark.sessionId, "ms": mark.startMs]
                    )
                } label: {
                    Label(mark.startLabel, systemImage: "arrow.turn.down.left")
                        .font(.monoNum11)
                        .foregroundColor(.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "session.marks.reveal"))
                .accessibilityLabel(Text(String(localized: "session.marks.reveal")))
                Spacer(minLength: Spacing.xs)
                if isHovering {
                    Button(action: requestDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.textTertiary)
                    .help(String(localized: "session.marks.delete"))
                    .accessibilityLabel(Text(String(localized: "session.marks.delete")))
                }
            }

            excerpt

            // The note is always available, never behind a disclosure: a
            // listener who has a thought has it now, and a click to reach the
            // field is a click during which the thought is lost.
            //
            // TextEditor rather than a growing TextField because the growing
            // form needs macOS 13 and this app runs from 12.5. It also takes a
            // Return without ending the note, which suits a thought that comes
            // out in two lines.
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(String(localized: "session.marks.note.placeholder"))
                        .font(.bodySM)
                        .foregroundColor(.textTertiary.opacity(0.8))
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.bodySM)
                    .foregroundColor(.textPrimary)
                    .montereyScrollContentBackground(hidden: true)
                    .frame(minHeight: 34, maxHeight: 96)
                    .focused($focusedNoteId, equals: mark.id)
                    .onChange(of: focusedNoteId) { focused in
                        // Commit on the way out rather than per keystroke: the
                        // write is durable and the listener is usually
                        // mid-sentence.
                        if focused != mark.id { commit() }
                    }
                    .accessibilityIdentifier("session.marks.note.\(mark.id)")
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Color.bgSunken.opacity(0.5))
            )
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.bgElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Color.borderGhost.opacity(0.35), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(role: .destructive, action: requestDelete) {
                Label(String(localized: "session.marks.delete"), systemImage: "trash")
            }
        }
        // A mark with a note holds the listener's own words, which nothing
        // regenerates; losing them to a stray click on a hover button is not
        // something to allow without asking.
        .confirmationDialog(
            String(localized: "session.marks.delete.confirm_title"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "session.marks.delete"), role: .destructive, action: onDelete)
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "session.marks.delete.confirm_message"))
        }
        .onChange(of: mark.note) { updated in
            // The excerpt refreshes as transcript improves, which re-creates
            // this row. Never let that clobber text being typed.
            if focusedNoteId != mark.id { draft = updated }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.marks.card.\(mark.id)")
    }

    private func requestDelete() {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete()
        } else {
            isConfirmingDelete = true
        }
    }

    @ViewBuilder
    private var excerpt: some View {
        if mark.isEmptyExcerpt {
            // Marking a silence is legitimate — "something happened here" —
            // and must not look like a failure.
            Text(String(localized: "session.marks.excerpt.silent"))
                .font(.bodySM)
                .foregroundColor(.textTertiary)
                .italic()
        } else if let digest = mark.digest, digest.failed == false {
            // The readable version replaces the fragments rather than sitting
            // beside them: two copies of the same passage is what the listener
            // came here to stop reading. The raw lines stay one click away.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(digest.text)
                    .font(.bodySM)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: Spacing.xs) {
                    if digest.isCurrent == false {
                        Label(
                            String(localized: "session.marks.digest.stale"),
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                    }
                    Button(showsRawExcerpt
                        ? String(localized: "session.marks.digest.hide_original")
                        : String(localized: "session.marks.digest.show_original")) {
                        showsRawExcerpt.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .accessibilityIdentifier("session.marks.digest.toggle.\(mark.id)")
                }

                if showsRawExcerpt {
                    rawExcerpt
                }
            }
        } else if let digest = mark.digest, digest.failed {
            // A failure that silently showed fragments would read as "the
            // feature is off", and the listener would never know to ask again.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(
                    String(localized: "session.marks.digest.failed"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.signalAmber)
                rawExcerpt
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(mark.lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.primaryText)
                            .font(.bodySM)
                            .foregroundColor(.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let secondary = line.secondaryText {
                            Text(secondary)
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private var rawExcerpt: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(mark.lines) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.primaryText)
                        .font(.bodySM)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let secondary = line.secondaryText {
                        Text(secondary)
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func commit() {
        guard draft != mark.note else { return }
        onNoteCommit(draft)
    }
}
