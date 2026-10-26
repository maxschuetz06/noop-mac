import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TodayView {
    /// The iOS tab is already labelled "Today", and "Control Center" collides with the OS feature of
    /// that name (on both platforms). Match the tab on iOS; keep the established name on macOS.
    var screenTitle: LocalizedStringKey {
        #if os(iOS)
        "Today"
        #else
        "Day Details"
        #endif
    }

    #if os(iOS)
    var sceneBackground: AnyView? { AnyView(SceneScreenBackground()) }
    var scaffoldSubtitle: LocalizedStringKey? { nil }
    #else
    /// The calm macOS redesign drops the day-cycle scene behind the header (flat soft canvas).
    var sceneBackground: AnyView? { nil }
    var scaffoldSubtitle: LocalizedStringKey? { "Every value of the day, in detail." }
    #endif

    /// The big scaffold title — suppressed on iOS, where `todayTopBar` replaces it; macOS keeps its
    /// "Control Center" header.
    var scaffoldTitle: LocalizedStringKey? {
        #if os(iOS)
        nil
        #else
        screenTitle
        #endif
    }

    #if os(iOS)
    /// The day-nav label: relative for today/yesterday, else a short date.
    var dayNavLabel: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let d = Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date()
            return Self.navDayFmt.string(from: d)
        }
    }

    static let navDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Picker binding that converts a chosen date back to a whole-day offset (capped at today).
    var dayPickerBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date() },
            set: { newValue in
                let cal = Calendar.current
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: newValue),
                                              to: cal.startOfDay(for: Date())).day ?? 0
                selectedDayOffset = max(0, days)
                showDayPicker = false
            }
        )
    }

    /// Compact WHOOP-style top bar: a profile/settings button (left), the centred ‹ Today › day-nav
    /// (bold, tappable to jump to a date), and the strap-battery badge (right).
    /// Apple-style large-title header: a tappable "Today ⌄" + full date on the left (taps to change day),
    /// then updates / quick-add / and an OBVIOUS menu avatar (opens Settings) on the right.
    @ViewBuilder var todayTopBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { showDayPicker = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(dayNavLabel)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text(selectedLogicalDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(dayNavLabel). Change day")
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Date(), displayedComponents: [.date])
                    .datePickerStyle(.graphical).labelsHidden().padding(12)
            }

            Spacer(minLength: 8)

            // Uniform 36pt circular icon set: recording-status light, updates bell, quick-add (+), menu.
            HStack(spacing: 8) {
                // Recording status — a colour-coded light (green recording / amber synced / red not
                // recording), replacing the old full-width banner. Taps to Devices to connect.
                if let state = recordingState {
                    Button { StrandHaptic.selection.play(); router.openDevices() } label: {
                        Circle().fill(StrandPalette.surfaceInset)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().fill(recordingHue(state)).frame(width: 10, height: 10))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.accessibilityText)
                }
                // Updates bell.
                Button { showUpdatesInbox = true } label: {
                    Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 15, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                        .overlay(alignment: .topTrailing) {
                            if updateStore.unreadCount > 0 {
                                Text("\(min(updateStore.unreadCount, 99))")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.goldDeepText)
                                    .padding(.horizontal, 3.5).padding(.vertical, 1)
                                    .frame(minWidth: 14)
                                    .background(Capsule().fill(StrandPalette.statusCritical))
                                    .offset(x: 2, y: -1)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Updates")
                // Quick-action + (the accented primary — gold, same 36 size as the rest).
                Button { router.requestQuickActions() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(StrandPalette.goldDeepText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick actions")
                .accessibilityHint("Start a workout, log your journal, or breathe")
                // Menu (Settings) — the avatar, same 36 size.
                Button { showSettings = true } label: {
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu and settings")
            }
        }
        .frame(height: 46)
    }

    /// Colour for the compact recording-status light: green recording, amber last-synced, red not
    /// recording, accent for experimental history. Mirrors the old chip's semantics in one dot.
    func recordingHue(_ state: RecordingState) -> Color {
        switch state {
        case .recording:           return StrandPalette.statusPositive
        case .lastSynced:          return StrandPalette.statusWarning
        case .notRecording:        return Color(red: 0.98, green: 0.27, blue: 0.23)
        case .historyExperimental: return StrandPalette.accent
        }
    }

    func topNavChevron(_ name: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Settings presented as a sheet from the top-bar profile button (sheets inherit the app
    /// environment on iOS, so SettingsView gets the same objects it has under the More tab).
    var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
    #endif

    /// The Updates "ringer": a bell button (~30pt) with a small gold unread-count badge. Tapping opens
    /// the Updates inbox sheet. Shared by the iOS top bar and the macOS toolbar.
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
