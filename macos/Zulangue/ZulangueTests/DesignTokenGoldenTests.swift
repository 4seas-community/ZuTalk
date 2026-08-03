import XCTest
import SwiftUI
import AppKit
@testable import Zulangue

/// Locks every design token's resolved value in both appearances.
///
/// `Tokens.swift` is two layers: a small set of primitives, and names that
/// forward to them. Renaming a call site from one forwarding name to another
/// must not move a single pixel, and this golden is what makes that checkable
/// rather than merely asserted — the refactor is allowed to remove lines from
/// the golden, never to change the value on a line that survives.
///
/// Regenerate deliberately — xcodebuild only forwards variables that carry the
/// TEST_RUNNER_ prefix, so a bare shell export silently does nothing:
///   TEST_RUNNER_ZULANGUE_REGENERATE_TOKEN_GOLDEN=1 xcodebuild test ...
/// Deleting Golden/design-tokens.txt regenerates it too.
final class DesignTokenGoldenTests: XCTestCase {

    private static let tokens: [(String, Color)] = [
        ("surface", .surface),
        ("surfaceRaised", .surfaceRaised),
        ("surfaceSunk", .surfaceSunk),
        ("line100", .line100),
        ("line70", .line70),
        ("line50", .line50),
        ("line30", .line30),
        ("line15", .line15),
        ("line10", .line10),
        ("line05", .line05),
        ("signal", .signal),
        ("signalDim", .signalDim),
        ("signalSoft", .signalSoft),
        ("signalGlow", .signalGlow),
        ("brandAccent", .brandAccent),
        ("brandAccentHover", .brandAccentHover),
        ("brandAccentSoft", .brandAccentSoft),
        ("brandAccentGlow", .brandAccentGlow),
        ("brandAccentForeground", .brandAccentForeground),
        ("accentOrangeInk", .accentOrangeInk),
        ("accentOrangeInkDim", .accentOrangeInkDim),
        ("accentOrangeInkSoft", .accentOrangeInkSoft),
        ("accentOrangeInkGlow", .accentOrangeInkGlow),
        ("destructive", .destructive),
        ("successInk", .successInk),
        ("gold", .gold),
        ("goldDim", .goldDim),
        ("goldSoft", .goldSoft),
        ("bgOverlay", .bgOverlay),
        ("accentOrange", .accentOrange),
        ("accentOrangeHover", .accentOrangeHover),
        ("accentOrangeSoft", .accentOrangeSoft),
        ("accentOrangeGlow", .accentOrangeGlow),
        ("accentGold", .accentGold),
        ("accentGoldDim", .accentGoldDim),
        ("accentGoldSoft", .accentGoldSoft),
        ("bgRoot", .bgRoot),
        ("bgPanel", .bgPanel),
        ("bgSurface", .bgSurface),
        ("bgElevated", .bgElevated),
        ("bgSunken", .bgSunken),
        ("bgGlass", .bgGlass),
        ("borderSubtle", .borderSubtle),
        ("borderPanel", .borderPanel),
        ("borderActive", .borderActive),
        ("borderGhost", .borderGhost),
        ("borderFaint", .borderFaint),
        ("textPrimary", .textPrimary),
        ("textSecondary", .textSecondary),
        ("textTertiary", .textTertiary),
        ("textMuted", .textMuted),
        ("textDim", .textDim),
        ("signalGreen", .signalGreen),
        ("signalGreenText", .signalGreenText),
        ("signalRed", .signalRed),
        ("signalBlue", .signalBlue),
        ("signalAmber", .signalAmber),
        ("signalPurple", .signalPurple),
        ("success", .success),
        ("warning", .warning),
        ("error", .error),
        ("info", .info),
        ("shadowSubtle", .shadowSubtle),
        ("shadowMedium", .shadowMedium),
        ("shadowStrong", .shadowStrong),
        ("shadowFocus", .shadowFocus),
    ]

    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Golden/design-tokens.txt")
    }

    func testEveryTokenResolvesToItsGoldenValue() throws {
        let actual = Self.tokens
            .map { name, color in
                "\(name)  light=\(rgba(color, .aqua))  dark=\(rgba(color, .darkAqua))"
            }
            .joined(separator: "\n") + "\n"

        let fm = FileManager.default
        if ProcessInfo.processInfo.environment["ZULANGUE_REGENERATE_TOKEN_GOLDEN"] == "1"
            || !fm.fileExists(atPath: goldenURL.path) {
            try fm.createDirectory(
                at: goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: goldenURL, atomically: true, encoding: .utf8)
            XCTFail("Token golden written to \(goldenURL.lastPathComponent); re-run to verify.")
            return
        }

        let expected = try String(contentsOf: goldenURL, encoding: .utf8)
        guard expected != actual else { return }

        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = Set(actual.split(separator: "\n", omittingEmptySubsequences: false))
        let expectedByName = Dictionary(
            expectedLines.compactMap { line -> (String, String)? in
                guard let name = line.split(separator: " ").first else { return nil }
                return (String(name), String(line))
            },
            uniquingKeysWith: { first, _ in first }
        )

        var changed: [String] = []
        for line in actual.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let name = line.split(separator: " ").first else { continue }
            if let before = expectedByName[String(name)], before != String(line) {
                changed.append("  \(before)\n→ \(line)")
            }
        }
        let removed = expectedLines
            .filter { !$0.isEmpty && !actualLines.contains($0) }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { name in !actual.contains("\(name)  ") }

        XCTAssertTrue(
            changed.isEmpty,
            """
            A token changed value. Renaming between forwarding names must be a no-op:
            \(changed.joined(separator: "\n"))
            """
        )
        if changed.isEmpty && !removed.isEmpty {
            // Removing a forwarding name is the point of the convergence work.
            // Record it by regenerating, but never alongside a value change.
            XCTFail(
                "Only removals detected (\(removed.count)): \(removed.joined(separator: ", ")). "
                + "Regenerate the golden to accept them."
            )
        }
    }

    private func rgba(_ color: Color, _ appearance: NSAppearance.Name) -> String {
        let ns = NSColor(color)
        var resolved = ns
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = ns.usingColorSpace(.deviceRGB) ?? ns
        }
        return String(
            format: "%.6f,%.6f,%.6f,%.6f",
            resolved.redComponent, resolved.greenComponent,
            resolved.blueComponent, resolved.alphaComponent
        )
    }
}
