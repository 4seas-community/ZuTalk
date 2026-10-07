import SwiftUI

// MARK: - Layouts that answer a width question without asking their children

/// The realtime page re-lays out on every capture publish. Ancestor stacks
/// probe each child at several widths (0, ∞, candidates) to rank flexibility,
/// and a `ViewThatFits` or a flexible HStack child answers each probe by
/// shaping its text again. With CJK labels that was 444–786 header shapings
/// and 0.3–0.9 s of main-thread time per update — a full core for the whole
/// recording. These layouts measure their text once per pass, from a cache,
/// and answer every later probe with arithmetic.

/// One row when everything fits at its natural width, otherwise the identity
/// on its own line above the details and actions. The choice is the one
/// `ViewThatFits` made; only the cost differs.
///
/// Subviews, in order: identity, details, actions.
@available(macOS 13.0, *)
struct RunHeaderLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    struct Cache {
        var ideal: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let oneRowWidth = Self.oneRowWidth(cache.ideal, spacing: spacing)
        let width = proposal.width ?? oneRowWidth
        if fitsOneRow(width: width, cache: cache) {
            return CGSize(width: width, height: cache.ideal.map(\.height).max() ?? 0)
        }
        return CGSize(width: width, height: twoRowHeight(cache))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard subviews.count == 3 else {
            for subview in subviews {
                subview.place(at: bounds.origin, proposal: .unspecified)
            }
            return
        }
        let identity = cache.ideal[0]
        let details = cache.ideal[1]
        let actions = cache.ideal[2]
        if fitsOneRow(width: bounds.width, cache: cache) {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(identity)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(actions)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - actions.width - spacing, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(details)
            )
            return
        }
        let firstRowHeight = identity.height
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
        let secondRowMidY = bounds.minY + firstRowHeight + rowSpacing
            + max(details.height, actions.height) / 2
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: secondRowMidY),
            anchor: .leading,
            proposal: ProposedViewSize(details)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: secondRowMidY),
            anchor: .trailing,
            proposal: ProposedViewSize(actions)
        )
    }

    private func fitsOneRow(width: CGFloat, cache: Cache) -> Bool {
        // The Spacer the old row had between identity and details.
        Self.oneRowWidth(cache.ideal, spacing: spacing) + spacing <= width + 0.5
    }

    private func twoRowHeight(_ cache: Cache) -> CGFloat {
        guard cache.ideal.count == 3 else { return cache.ideal.map(\.height).max() ?? 0 }
        return cache.ideal[0].height + rowSpacing + max(cache.ideal[1].height, cache.ideal[2].height)
    }

    private static func oneRowWidth(_ ideal: [CGSize], spacing: CGFloat) -> CGFloat {
        ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideal.count - 1))
    }
}

/// The transcript and, beside it, a fixed-width rail. An HStack would probe
/// the transcript — and the whole scrolling column inside it — at several
/// widths to decide who gets what; here the answer is known in advance: the
/// separator and rail get their widths and the transcript the rest, proposed
/// once. Nothing is measured.
///
/// Subviews, in order: transcript, then optionally the separator and the rail.
@available(macOS 13.0, *)
struct TranscriptRailLayout: Layout {
    var separatorWidth: CGFloat
    var railWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // It fills what it is given, like the HStack of flexible children it
        // replaces; asking the transcript would start the probing again.
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let transcript = subviews.first else { return }
        let fixedWidths = [separatorWidth, railWidth].prefix(subviews.count - 1)
        let transcriptWidth = max(0, bounds.width - fixedWidths.reduce(0, +))
        transcript.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: transcriptWidth, height: bounds.height)
        )
        var x = bounds.minX + transcriptWidth
        for (subview, width) in zip(subviews.dropFirst(), fixedWidths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}
