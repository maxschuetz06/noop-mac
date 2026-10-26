import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Diagonal-hatch track (WHOOP "typical range" context)

/// A repeating set of 45° diagonal lines for the "typical range" context track behind a stage bar
/// ("solid = you, hatch = the context"). Pure geometry — stroke it in the stage colour and clip it to a
/// capsule. `spacing` is the gap between lines; the lines run further than the bounds so the clip edges
/// stay clean. Presentation-only; no data of its own.
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 5
    var lineWidth: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start well before the left edge so the 45° lines fully cover the rect after the diagonal shear.
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}
