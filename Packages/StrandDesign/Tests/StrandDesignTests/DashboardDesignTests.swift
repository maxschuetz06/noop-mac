// Resolves dynamic colours through NSAppearance, so the suite only builds where AppKit exists.
#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import StrandDesign

/// The dashboard tokens and primitives that replaced the app's former `SoftTheme`.
final class DashboardDesignTests: XCTestCase {

    /// sRGB 0…255 components of a dynamic colour resolved under `appearance`.
    private func rgb(_ color: Color, _ appearance: NSAppearance.Name) -> [Int] {
        var out: [Int] = []
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return out
    }

    private func assertHex(_ color: Color, light: Int, dark: Int, file: StaticString = #filePath, line: UInt = #line) {
        let split = { (v: Int) in [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF] }
        XCTAssertEqual(rgb(color, .aqua), split(light), "light", file: file, line: line)
        XCTAssertEqual(rgb(color, .darkAqua), split(dark), "dark", file: file, line: line)
    }

    func testDashboardTokensResolvePerAppearance() {
        assertHex(StrandPalette.surfaceSidebar, light: 0xFAFAF8, dark: 0x16191C)
        assertHex(StrandPalette.hueGreen, light: 0x3FAE5A, dark: 0x58C774)
        assertHex(StrandPalette.huePeach, light: 0xF29A4A, dark: 0xF2A35E)
        assertHex(StrandPalette.hueRose, light: 0xE8708A, dark: 0xEF8AA0)
        assertHex(StrandPalette.hueBlue, light: 0x5B6CF0, dark: 0x8592FF)
        assertHex(StrandPalette.hueViolet, light: 0x9A84F0, dark: 0xB2A0FF)
        assertHex(StrandPalette.hueAmber, light: 0xF2B33D, dark: 0xF5C45E)
        assertHex(StrandPalette.hueYellow, light: 0xF6D84A, dark: 0xF6D84A)
        assertHex(StrandPalette.washGreen, light: 0xCDEFC9, dark: 0x1F4A2A)
        assertHex(StrandPalette.washPeach, light: 0xFFD9B8, dark: 0x4A3020)
        assertHex(StrandPalette.washRose, light: 0xFBD9E2, dark: 0x4A2430)
        assertHex(StrandPalette.washBlue, light: 0xDCE2FF, dark: 0x252C55)
    }

    func testSmoothSparklinePointsUseInsetRange() {
        let pts = Sparkline.smoothPoints([10, 20, 15], in: CGSize(width: 100, height: 52))
        XCTAssertEqual(pts.map(\.x), [0, 50, 100])
        XCTAssertEqual(pts[0].y, 46, accuracy: 0.001)   // minimum sits on the bottom inset
        XCTAssertEqual(pts[1].y, 6, accuracy: 0.001)    // maximum on the top inset
        XCTAssertEqual(pts[2].y, 26, accuracy: 0.001)
    }

    func testSmoothSparklineDegenerateSeries() {
        let size = CGSize(width: 80, height: 40)
        XCTAssertTrue(Sparkline.smoothPoints([], in: size).isEmpty)
        XCTAssertEqual(Sparkline.smoothPoints([7], in: size), [CGPoint(x: 80, y: 20)])
        // A flat series must not divide by zero: every point lands on the bottom inset.
        XCTAssertEqual(Sparkline.smoothPoints([5, 5, 5], in: size).map(\.y), [34, 34, 34])
    }

    func testMiniBarsHeightFraction() {
        XCTAssertEqual(MiniBars.heightFraction(0, max: 10), 0.12, accuracy: 0.0001)
        XCTAssertEqual(MiniBars.heightFraction(10, max: 10), 1, accuracy: 0.0001)
        XCTAssertEqual(MiniBars.heightFraction(5, max: 10), 0.56, accuracy: 0.0001)
        // An all-zero series keeps the baseline instead of producing NaN.
        XCTAssertEqual(MiniBars.heightFraction(0, max: 0), 0.12, accuracy: 0.0001)
    }
}
#endif
