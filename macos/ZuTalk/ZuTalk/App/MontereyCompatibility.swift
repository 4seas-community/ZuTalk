import SwiftUI

/// Compatibility helpers for the macOS 12.5 deployment floor.
///
/// Keep newer SwiftUI behavior on systems that provide it, while ensuring the
/// app binary never links an unavailable symbol merely because the source was
/// compiled with a newer SDK.
extension View {
    func montereyOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        modifier(MontereyOnChangeModifier(value: value, action: action))
    }

    @ViewBuilder
    func montereyScrollIndicators(_ showsIndicators: Bool) -> some View {
        if #available(macOS 13.0, *) {
            scrollIndicators(showsIndicators ? .visible : .hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func montereyScrollContentBackground(hidden: Bool) -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(hidden ? .hidden : .visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func montereyDefaultScrollAnchor(_ anchor: UnitPoint) -> some View {
        if #available(macOS 14.0, *) {
            defaultScrollAnchor(anchor)
        } else {
            self
        }
    }

    /// Reports pointer location on macOS 14+, and falls back to enter/exit on
    /// Monterey where continuous hover coordinates are not public API.
    @ViewBuilder
    func montereyContinuousHover(
        perform action: @escaping (_ isActive: Bool, _ location: CGPoint?) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    action(true, location)
                case .ended:
                    action(false, nil)
                }
            }
        } else {
            onHover { isActive in
                action(isActive, nil)
            }
        }
    }
}

private struct MontereyOnChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (_ oldValue: Value, _ newValue: Value) -> Void

    @State private var previousValue: Value

    init(
        value: Value,
        action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) {
        self.value = value
        self.action = action
        _previousValue = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            let oldValue = previousValue
            previousValue = newValue
            action(oldValue, newValue)
        }
    }
}

/// A two-candidate horizontal fit that preserves `ViewThatFits` behavior on
/// macOS 13+, and deliberately chooses the compact fallback on Monterey.
struct MontereyHorizontalViewThatFits<Primary: View, Fallback: View>: View {
    private let primary: Primary
    private let fallback: Fallback

    init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.primary = primary()
        self.fallback = fallback()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 13.0, *) {
            ViewThatFits(in: .horizontal) {
                primary
                fallback
            }
        } else {
            fallback
        }
    }
}

enum MontereyTaskSleep {
    static func milliseconds(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds &* 1_000_000)
    }

    static func seconds(_ seconds: Double) async throws {
        let clamped = max(0, seconds)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}
