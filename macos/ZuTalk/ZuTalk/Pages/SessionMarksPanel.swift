import SwiftUI

/// The materials rail: every moment the listener flagged, newest work at the
/// bottom, each card holding the passage it captured and room to say why.
///
/// This is the only writing surface that makes sense while a room is still
/// talking. A blank page asks someone following a foreign language to compose;
/// a card that already contains what was just said asks them only to react.
///
/// The header is one word and a count. A mark is a time, what was said, and
/// the note field; what can be done to it is icons, each named by its
/// tooltip.
struct SessionMarksPanel: View {
    let sessionId: String?
    /// Whether a keypress can currently drop a mark. Marks are a live gesture;
    /// after the recording ends the rail becomes a reading and editing surface.
    let isLive: Bool
    let onMark: () -> Void
    /// Marks to show instead of the store's: for drawing the panel in a
    /// given state without a recording behind it.
    var shownMarks: [SessionMarkViewModel]?

    @ObservedObject private var store = SessionMarkStore.shared
    @FocusState private var focusedNoteId: String?

    private var marks: [SessionMarkViewModel] { shownMarks ?? store.marks }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.borderGhost.opacity(0.4))

            if marks.isEmpty {
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
            GroupHeader(String(localized: "session.marks.title"))

            if !marks.isEmpty {
                Text("\(marks.count)")
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
                ActionPill(
                    String(localized: "session.marks.add"),
                    systemImage: "bookmark.fill",
                    tone: .on,
                    help: String(localized: "session.marks.add.hint"),
                    action: onMark
                )
                .accessibilityIdentifier("session.marks.add")
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: PillMetrics.height + Spacing.sm * 2)
    }

    /// One sentence. While recording it names the key to press; the longer
    /// account of what a mark keeps is its tooltip.
    private var emptyState: some View {
        OneSentenceState(
            systemImage: "bookmark",
            sentence: String(localized: isLive
                ? "recording.marks.empty_live"
                : "session.marks.empty.done"),
            detail: isLive ? String(localized: "session.marks.empty.live") : nil
        )
        .accessibilityIdentifier("session.marks.empty")
    }

    private var markList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(marks) { mark in
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
            .onChange(of: marks.count) { _ in
                // A fresh mark is the reason the rail exists; bring it into
                // view without stealing the listener's scroll position for
                // anything else.
                guard let last = marks.last else { return }
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
                digestMarks
                // Always there, quiet until the card is pointed at: an
                // action that only exists on hover is one nobody finds.
                iconButton(
                    "trash",
                    help: String(localized: "session.marks.delete"),
                    action: requestDelete
                )
                .opacity(isHovering ? 1 : 0.55)
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

    /// A small icon that does one thing, named by its tooltip.
    private func iconButton(
        _ systemImage: String,
        tint: Color = .textTertiary,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(PillMetrics.markFont)
                .foregroundColor(tint)
                .frame(width: PillMetrics.segmentWidth - Spacing.xs, height: PillMetrics.segmentWidth - Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    /// For a mark shown in its tidied form: that the passage changed since
    /// (an icon, the words in its tooltip), and the way to the original
    /// lines. Both used to be printed under the excerpt.
    @ViewBuilder
    private var digestMarks: some View {
        if mark.isEmptyExcerpt == false, let digest = mark.digest, digest.failed == false {
            if digest.isCurrent == false {
                Image(systemName: "clock.arrow.circlepath")
                    .font(PillMetrics.markFont)
                    .foregroundColor(.signalAmber)
                    .help(String(localized: "session.marks.digest.stale"))
                    .accessibilityLabel(Text(String(localized: "session.marks.digest.stale")))
            }
            iconButton(
                showsRawExcerpt ? "text.quote" : "text.alignleft",
                tint: showsRawExcerpt ? .brandAccent : .textTertiary,
                help: String(localized: showsRawExcerpt
                    ? "session.marks.digest.hide_original"
                    : "session.marks.digest.show_original")
            ) {
                showsRawExcerpt.toggle()
            }
            .accessibilityIdentifier("session.marks.digest.toggle.\(mark.id)")
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
