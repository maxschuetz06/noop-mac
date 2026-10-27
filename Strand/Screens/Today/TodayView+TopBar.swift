import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    var screenTitle: LocalizedStringKey {
        "Day Details"
    }

    /// The calm macOS redesign drops the day-cycle scene behind the header (flat soft canvas).
    var sceneBackground: AnyView? { nil }
    var scaffoldSubtitle: LocalizedStringKey? { "Every value of the day, in detail." }

    var scaffoldTitle: LocalizedStringKey? {
        screenTitle
    }

    /// The Updates "ringer": a bell button (~30pt) with a small gold unread-count badge. Tapping opens
    /// the Updates inbox sheet. Shown in the window toolbar.
    var updateBell: some View {
        Button { showUpdatesInbox = true } label: {
            Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if updateStore.unreadCount > 0 {
                        Text("\(min(updateStore.unreadCount, 99))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.goldDeepText)
                            // Fixed 14pt square + Circle() = a true CIRCLE on both platforms, kept INSIDE
                            // the 34pt bell frame (offset -1,1) so the macOS toolbar (at the window's top
                            // edge) no longer clips the badge's top (Aaron 2026-06-23).
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: -1, y: 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updateStore.unreadCount > 0
                            ? "Updates, \(updateStore.unreadCount) unread"
                            : "Updates")
    }
}
