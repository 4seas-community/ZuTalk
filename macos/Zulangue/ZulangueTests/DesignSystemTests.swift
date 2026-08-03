import XCTest
import SwiftUI
import AppKit
@testable import Zulangue

final class DesignSystemTests: XCTestCase {

    // MARK: - Color hex initializer

    func testColorHexInit() {
        let color = Color(hex: 0xff0000)
        // SwiftUI Color 没法直接断言 RGB，但 init 不应崩溃
        XCTAssertNotNil(color)
    }

    func testColorHexWithOpacity() {
        let color = Color(hex: 0x00ff00, opacity: 0.5)
        XCTAssertNotNil(color)
    }

    // MARK: - Radius tokens

    func testRadiusValues() {
        XCTAssertEqual(Radius.xs, 4)
        XCTAssertEqual(Radius.sm, 8)
        XCTAssertEqual(Radius.md, 12)
        XCTAssertEqual(Radius.lg, 16)
        XCTAssertEqual(Radius.pill, 999)
    }

    // MARK: - Spacing tokens

    func testSpacingValues() {
        XCTAssertEqual(Spacing.xs, 4)
        XCTAssertEqual(Spacing.sm, 8)
        XCTAssertEqual(Spacing.xsm, 12)
        XCTAssertEqual(Spacing.md, 16)
        XCTAssertEqual(Spacing.lg, 24)
        XCTAssertEqual(Spacing.xl, 32)
        XCTAssertEqual(Spacing.xxl, 48)
        XCTAssertEqual(Spacing.grid, 24)
    }

    // MARK: - Font tokens (smoke — just verify they construct)

    func testMonoFontsExist() {
        XCTAssertNotNil(Font.mono8)
        XCTAssertNotNil(Font.mono9)
        XCTAssertNotNil(Font.mono10)
        XCTAssertNotNil(Font.mono11)
        XCTAssertNotNil(Font.mono12)
        XCTAssertNotNil(Font.mono10Medium)
        XCTAssertNotNil(Font.mono11Medium)
    }

    func testSansFontsExist() {
        XCTAssertNotNil(Font.sans11)
        XCTAssertNotNil(Font.sans12)
        XCTAssertNotNil(Font.sans13)
        XCTAssertNotNil(Font.sans14)
        XCTAssertNotNil(Font.sans11Medium)
        XCTAssertNotNil(Font.sans13Medium)
        XCTAssertNotNil(Font.sans14Medium)
    }

    /// Recording and processing retain their own activity signal instead of
    /// inheriting the green product theme.
    func testAccentOrangeResolvesToConstitutionalSignal() {
        let target = NSColor(srgbRed: 1.0, green: 107.0 / 255.0, blue: 0.0, alpha: 1.0)
        let allowedDelta: CGFloat = 0.01

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let resolved = resolvedColor(NSColor(Color.accentOrange), appearance: appearance)
                .usingColorSpace(.sRGB) ?? NSColor(Color.accentOrange)

            XCTAssertEqual(
                resolved.redComponent, target.redComponent, accuracy: allowedDelta,
                "accentOrange red component drift in \(appearance.rawValue)"
            )
            XCTAssertEqual(
                resolved.greenComponent, target.greenComponent, accuracy: allowedDelta,
                "accentOrange green component drift in \(appearance.rawValue)"
            )
            XCTAssertEqual(
                resolved.blueComponent, target.blueComponent, accuracy: allowedDelta,
                "accentOrange blue component drift in \(appearance.rawValue)"
            )
        }
    }

    func testBrandAccentResolvesToZulangueGreenInBothAppearances() {
        let targets: [(NSAppearance.Name, NSColor)] = [
            (
                .darkAqua,
                NSColor(
                    srgbRed: 142.0 / 255.0,
                    green: 242.0 / 255.0,
                    blue: 196.0 / 255.0,
                    alpha: 1
                )
            ),
            (
                .aqua,
                NSColor(
                    srgbRed: 0,
                    green: 106.0 / 255.0,
                    blue: 71.0 / 255.0,
                    alpha: 1
                )
            ),
        ]
        let allowedDelta: CGFloat = 0.01

        for (appearance, target) in targets {
            let resolved = resolvedColor(NSColor(Color.brandAccent), appearance: appearance)
                .usingColorSpace(.sRGB) ?? NSColor(Color.brandAccent)
            XCTAssertEqual(resolved.redComponent, target.redComponent, accuracy: allowedDelta)
            XCTAssertEqual(resolved.greenComponent, target.greenComponent, accuracy: allowedDelta)
            XCTAssertEqual(resolved.blueComponent, target.blueComponent, accuracy: allowedDelta)
        }
    }

    func testSignalRedNeverAliasesToTheGreenTheme() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let resolved = resolvedColor(NSColor(Color.signalRed), appearance: appearance)
                .usingColorSpace(.sRGB) ?? NSColor(Color.signalRed)
            XCTAssertGreaterThan(resolved.redComponent, resolved.greenComponent)
            XCTAssertGreaterThan(resolved.redComponent, resolved.blueComponent)
        }
    }

    func testSidebarUsesTheGreenSymbolInsteadOfACompressedWordmark() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        let shell = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("UIScenes/Main/MainShellView.swift"),
            encoding: .utf8
        )
        let brandStart = try XCTUnwrap(shell.range(of: "private var sidebarBrand: some View"))
        let brandEnd = try XCTUnwrap(
            shell[brandStart.upperBound...].range(of: "@ViewBuilder")
        )
        let brand = String(shell[brandStart.lowerBound..<brandEnd.lowerBound])

        XCTAssertTrue(brand.contains("Image(\"ZulangueMark\")"))
        XCTAssertTrue(brand.contains(".foregroundColor(.brandAccent)"))
        XCTAssertTrue(brand.contains("Text(\"Zulangue\")"))
        XCTAssertFalse(brand.contains(".foregroundColor(.accentOrange)"))
    }

    func testOrdinaryInteractionSurfacesDoNotUseTheActivityOrangeToken() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        for relativePath in [
            "UIScenes/Main/MainShellView.swift",
            "App/OnboardingView.swift",
            "Pages/DocumentEditorPage.swift",
            "Pages/NotebookCaptureViews.swift",
            "Pages/TrashPage.swift",
            "MenuBar/MenuBarIdleView.swift",
            "DesignSystem/FocusRing.swift",
        ] {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("accentOrange"),
                "\(relativePath) must use brandAccent for ordinary interactions"
            )
        }
    }

    func testRecordingSurfacesKeepTheActivityOrangeToken() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Zulangue", isDirectory: true)
        for relativePath in [
            "DesignSystem/Primitives/LiveIndicator.swift",
            "MenuBar/RecordingHudView.swift",
            "MenuBar/MenuBarRecordingView.swift",
        ] {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("accentOrange"),
                "\(relativePath) must retain the distinct recording signal"
            )
        }
    }

    private func resolvedColor(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: appearance)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    private func brightness(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
    }
}
