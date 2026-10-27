import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    /// Flip a Today info-card's dismissed flag back to false so it reappears (driven by the inbox's
    /// "Restore to Today"). Keyed on the card id stored in the update's `restorePayload`.
    func restoreTodayCard(_ cardID: String) {
        switch cardID {
        case "scoresBuilding": scoresBuildingDismissed = false
        case "newHere":        newHereDismissed = false
        default:               break
        }
    }

    /// Dismiss a Today info-card INTO the inbox: set its @AppStorage flag (so it stays gone) and post a
    /// `.dismissedCard` update carrying the card id so it can be restored.
    func dismissTodayCard(id: String, title: String, message: String) {
        StrandHaptic.selection.play()
        switch id {
        case "scoresBuilding": scoresBuildingDismissed = true
        case "newHere":        newHereDismissed = true
        default:               break
        }
        updateStore.post(UpdateItem(
            kind: .dismissedCard,
            title: title,
            message: message,
            restorePayload: id
        ))
    }

    /// A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
    /// `DataPendingNote`). Matches the "New here?" card's × styling.
    func todayCardDismissButton(_ action: @escaping () -> Void) -> some View {
        Button { withAnimation(StrandMotion.interactive) { action() } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss to Updates")
    }

    // MARK: First-run scoring-guide card (one-time, dismissible)

    /// "New here?" — a single, dismissible card that points first-time users at the guide. Tapping the
    /// card opens the guide; the ✕ closes it. Either action sets `scoringGuideCardSeen`, so it shows
    /// once and never again. An in-flow card, never a modal.
    var scoringGuideFirstRunCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New here?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        scoringGuideCardSeen = true
                        showGuideTop = true
                    } label: {
                        Label("How your scores work", systemImage: "arrow.right")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    // Dismiss INTO the Updates inbox (restorable), rather than permanently hiding.
                    withAnimation(StrandMotion.interactive) {
                        dismissTodayCard(
                            id: "newHere",
                            title: "New here?",
                            message: "How Charge, Effort and Rest are calculated — and how they differ from WHOOP."
                        )
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            // The whole card is tappable as the primary action; the ✕ stops the tap from also firing.
            .contentShape(Rectangle())
            .onTapGesture {
                scoringGuideCardSeen = true
                showGuideTop = true
            }
        }
        // Press-down feedback for the tappable card surface.
        .strandPressable()
    }

    /// The "still building" and "new here?" prompts are about getting today's scores going,
    /// so they stay anchored to today rather than reappearing on every navigated past day.
    @ViewBuilder
    var scoresBuildingPrompts: some View {
        if selectedDayOffset == 0 && repo.today?.recovery == nil {
            // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
            if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
            // Only for a genuinely new install: gone once a WHOOP export is imported (or enough
            // history exists) and once dismissed (persisted via `scoresBuildingDismissed`).
            if TodayDisplayRules.showScoresBuildingNote(
                isToday: selectedDayOffset == 0, todayHasRecovery: repo.today?.recovery != nil,
                dismissed: scoresBuildingDismissed, importedDays: repo.freshness.importedDays,
                historyDays: repo.days.count) {
                DataPendingNote(
                    title: "Live now. Your scores are building.",
                    message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                )
                // A small × dismisses the card INTO the Updates inbox (restorable from there).
                .overlay(alignment: .topTrailing) {
                    todayCardDismissButton {
                        dismissTodayCard(
                            id: "scoresBuilding",
                            title: "Live now. Your scores are building.",
                            message: "Charge, Effort and Rest build over your next few nights of wear."
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }
}
