import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

/// A small status dot for the recording chip — a steady filled dot, or a breathing pulse halo when the
/// strap is live (recording). Honours Reduce Motion (no pulse). Local to TodayView so it doesn't disturb
/// the design package's pill dots.
struct RecordingDot: View {
    var color: Color
    var pulsing: Bool
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animate ? 2.2 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
            }
            Circle().fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: pulsing ? 3 : 1)
        }
        .frame(width: 8, height: 8)
        .onAppear { if pulsing && !reduceMotion { animate = true } }
        .animation(pulsing && !reduceMotion ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}
