import SwiftUI

// MARK: - Dashboard hues (macOS Home + Sleep overview)
//
// The calm dashboard pairs the neutral surfaces/text above with a small set of airy hues and their
// soft card "washes" (`CardWash`). Kept apart from the domain colour worlds on purpose: these never
// follow `chartStyle`, so the dashboard reads the same in Titanium and Classic.

public extension StrandPalette {
    /// Sidebar surface — a hair lighter than `surfaceBase` on light, a hair raised on dark.
    static let surfaceSidebar = Color(light: "#FAFAF8", dark: "#16191C")

    static let hueGreen  = Color(light: "#3FAE5A", dark: "#58C774")
    static let huePeach  = Color(light: "#F29A4A", dark: "#F2A35E")
    static let hueRose   = Color(light: "#E8708A", dark: "#EF8AA0")
    static let hueBlue   = Color(light: "#5B6CF0", dark: "#8592FF")
    static let hueViolet = Color(light: "#9A84F0", dark: "#B2A0FF")
    static let hueAmber  = Color(light: "#F2B33D", dark: "#F5C45E")
    /// Scheme-invariant marker yellow (the aura hero's vital anchors).
    static let hueYellow = Color(light: "#F6D84A", dark: "#F6D84A")

    static let washGreen = Color(light: "#CDEFC9", dark: "#1F4A2A")
    static let washPeach = Color(light: "#FFD9B8", dark: "#4A3020")
    static let washRose  = Color(light: "#FBD9E2", dark: "#4A2430")
    static let washBlue  = Color(light: "#DCE2FF", dark: "#252C55")
}
