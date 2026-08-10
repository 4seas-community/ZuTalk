// SurfaceCard.swift
// The card chrome every page had been writing out by hand.
//
// Five surfaces drew the same three modifiers in the same order — a fill, a
// stroked rounded border, and a clip to the same radius — and drifted while
// doing it: 0.28 against 0.30 against 0.40 opacity, two different border
// alphas at the same corner radius.
//
// This is deliberately a modifier and not a container view. Callers apply
// their own `.padding` and `.frame` first, exactly where they already did,
// so the chain a view produces is unchanged; only the trailing chrome is
// shared. A container would have had to swallow padding and frame too, and
// `background` sizing to the padded content rather than the framed one is a
// real visual difference.
//
// The differing numbers stay at the call sites, now visible side by side.
// Whether they should converge is a design decision, not a refactor.

import SwiftUI

extension View {
    /// Fill and clip, no border.
    func surfaceCard(fill: Color, cornerRadius: CGFloat) -> some View {
        background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Fill, stroked border inset to the same radius, then clip.
    func surfaceCard(
        fill: Color,
        cornerRadius: CGFloat,
        border: Color,
        borderWidth: CGFloat
    ) -> some View {
        background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
