import SwiftUI
import StrandDesign

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// macOS: a dependable wake alarm for the WHOOP strap. The strap's firmware alarm is armed, and because
/// the Mac stays awake and connected overnight, the Mac also runs its own timer for the same instant and
/// plays a haptic wake pattern if the firmware did not fire (`WakeAlarmPolicy`, `AppModel`). The wind-down
/// nudge sits below it.
///
/// iOS: HONEST by design — a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so iOS
/// deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android, which has the
/// exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle evening reminder —
/// and we say plainly why there's no wake alarm, rather than promising one we can't keep.
struct SmartAlarmView: View {
    @State private var windDownOn = WindDownNudge.isEnabled
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        ScreenScaffold(title: "Smart alarm",
                       subtitle: "A gentle evening wind-down nudge to help you reach your wake time rested.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                #if os(macOS)
                WakeAlarmCard()
                #endif
                windowHero
                #if os(iOS)
                honestyCard
                #endif
                windDownCard
            }
        }
    }

    // A small Rest-tinted hero — the wind-down readout as a clean time pairing (wind-down → wake)
    // over a scenic Rest backdrop, so a glance gives the night's shape. It's about winding down to
    // sleep, so it reads in the Rest world (indigo) rather than the brand-green chrome below.
    private var windowHero: some View {
        ZStack {
            ScenicHeroBackground(domain: .rest)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                Text("Tonight").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    heroTime(label: "Wind down",
                             time: windDownOn ? timeLabel(WindDownNudge.nudgeMinuteOfDay()) : "—",
                             tint: StrandPalette.restColor)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    heroTime(label: "Wake",
                             time: timeLabel(wakeMinutes),
                             tint: StrandPalette.restBright)
                    Spacer(minLength: 0)
                }
                Text(windDownOn
                     ? "A calm nudge \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before your wake time."
                     : "Turn on the wind-down reminder below to land at your wake time rested.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroTime(label: LocalizedStringKey, time: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(time)
                .font(StrandFont.number(28))
                .foregroundStyle(tint)
        }
    }

    // The up-front, honest explanation of why iOS gets a nudge and not a wake alarm.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No wake alarm on this device")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A sideloaded app can't sound a reliable wake alarm in the background on iOS — that needs a critical-alert permission this build doesn't have. Use your phone's built-in Clock alarm to wake. NOOP's smart wake (light-sleep detection) is available on the Android app.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var windDownCard: some View {
        // Rest-tinted when armed so the active state reads in the sleep world; neutral when off.
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evening").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(StrandPalette.restColor)
                            .accessibilityHidden(true)
                        Text("Wind-down nudge")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to wind down")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A calm evening reminder, timed from your wake time and usual sleep need. It's a suggestion, not an alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $windDownOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Remind me to wind down")
                        .onChangeCompat(of: windDownOn) { on in WindDownNudge.setEnabled(on) }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Wake time")
                    }
                    Text("You'll be reminded around \(timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Divider().overlay(StrandPalette.hairline)
                    perDaySection
                }
            }
        }
    }

    // PR#554 — per-day wake overrides. A toggle reveals a per-weekday wake-time editor; with it off (or no
    // override set) every evening uses the single wake time above. Each weekday row shows the effective wake
    // (override or the default) and lets the user set or clear that day's time.
    @ViewBuilder private var perDaySection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Different wake time per day")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Set a wake time for specific days — a lie-in at the weekend, say. Days you leave alone use the time above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $perDayOn)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel("Different wake time per day")
                .onChangeCompat(of: perDayOn) { on in
                    // Turning the section OFF clears every override (so the nudge reverts to the single time);
                    // turning it ON just reveals the editor — no override is created until the user sets one.
                    if !on {
                        for weekday in 1...7 { WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil) }
                        overrides = [:]
                    }
                }
        }
        .frame(minHeight: 42)

        if perDayOn {
            VStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    weekdayOverrideRow(weekday)
                }
            }
            .padding(.top, 4)
        }
    }

    /// One weekday's override row: the day name, the effective wake time (override or default), a picker to
    /// set it, and a clear control shown only when an override exists for that day.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return HStack(spacing: 12) {
            Text(Self.weekdayName(weekday))
                .font(StrandFont.subhead)
                .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override, use the default wake time")
            }
            DatePicker("", selection: overrideBinding(weekday, effective: effective),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
        }
    }

    /// A binding for one weekday's wake override — reads the effective minute, writes a NEW override (a pick
    /// always sets that day's override) into both the store and the local mirror, rescheduling via the store.
    private func overrideBinding(_ weekday: Int, effective: Int) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = effective / 60
                c.minute = effective % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                WindDownNudge.setWakeOverride(weekday: weekday, minutes: m)
                overrides[weekday] = m
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (1...7).contains(dow) ? names[dow - 1] : "Day \(dow)"
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

#if os(macOS)
/// The macOS wake-alarm card: enable, time, weekdays, next alarm, "Test now" / "Stop", last result.
/// Bound to the same `BehaviorStore` properties the Automations screen edits; every change re-arms the
/// firmware alarm and the Mac fallback timer through `AppModel.applySmartAlarm()`.
private struct WakeAlarmCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    @EnvironmentObject var live: LiveState

    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), like AutomationsView.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        StrandCard(padding: 20, tint: behavior.smartAlarmEnabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 16) {
                header
                enableRow
                if behavior.smartAlarmEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    timeRow
                    weekdayChips
                }
                nextAlarmText
                Divider().overlay(StrandPalette.hairline)
                testRow
                if let line = lastResultLine {
                    Text(line)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The strap's own alarm hasn't been confirmed to fire on WHOOP 5.0 yet. If it stays silent, this Mac buzzes the strap instead — but only while the Mac is awake and the strap is in Bluetooth range.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: behavior.smartAlarmWeekdays) { _ in model.applySmartAlarm() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Morning").strandOverline()
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                Text("Wake alarm")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private var enableRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable wake alarm")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Buzzes your strap at the wake time. The strap's own alarm is armed, and this Mac backs it up while NOOP is running.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $behavior.smartAlarmEnabled)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel("Enable wake alarm")
                .onChangeCompat(of: behavior.smartAlarmEnabled) { on in
                    // Ask once, up front, so the "strap not connected" / ringing notification can show.
                    if on { WindDownNudge.requestAuthorization() }
                }
        }
        .frame(minHeight: 42)
    }

    private var timeRow: some View {
        HStack {
            Text("Wake at")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.compact)
                .accessibilityLabel("Wake at")
        }
        .frame(minHeight: 42)
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach(Self.weekdayOrder, id: \.self) { dow in
                let selected = AutomationsView.weekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                Button {
                    behavior.smartAlarmWeekdays = AutomationsView.toggledWeekday(dow, in: behavior.smartAlarmWeekdays)
                } label: {
                    Text(Self.weekdayInitial(dow))
                        .font(StrandFont.caption)
                        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.weekdayName(dow))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var nextAlarmText: some View {
        Group {
            if behavior.smartAlarmEnabled, let next = model.wakeAlarmNextFire {
                Text("Next alarm: \(Self.dayLabel(next)) \(Self.timeLabel(next))")
            } else if behavior.smartAlarmEnabled {
                Text("No upcoming alarm — pick at least one day.")
            } else {
                Text("Wake alarm is off.")
            }
        }
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textPrimary)
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.startWakePattern(isTest: true)
                } label: { Label("Test one burst", systemImage: "play.fill") }
                .buttonStyle(.bordered).tint(StrandPalette.accent)
                .disabled(!live.bonded || model.wakeAlarmRinging)

                if model.wakeAlarmRinging {
                    Button {
                        model.stopWakeAlarm(by: .app)
                    } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                }
                Spacer()
            }
            if model.wakeAlarmRinging {
                Text("Buzzing the strap… round \(model.wakeAlarmRound)/\(model.wakeAlarmTotalRounds). Double-tap the strap or press Stop.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if !live.bonded {
                Text("Connect the strap to test the alarm.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("One round = \(WakeAlarmPolicy.burstBuzzCount) quick buzzes. The real alarm repeats up to \(WakeAlarmPolicy.maxRounds) rounds, \(Int(WakeAlarmPolicy.roundInterval)) s apart. The test plays one round only.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Last result

    private var lastResultLine: String? {
        guard let r = model.wakeAlarmLastResult else { return nil }
        let when = Self.timeLabel(r.date)
        let message: String
        switch r.outcome {
        case .completed(let n): message = String(localized: "Mac buzzed the strap \(n)×")
        case .stoppedByDoubleTap(let n): message = String(localized: "Stopped by double-tap after \(n)×")
        case .stoppedInApp(let n): message = String(localized: "Stopped in the app after \(n)×")
        case .firmwareHandled: message = String(localized: "Strap alarm fired")
        case .strapNotConnected: message = String(localized: "Strap not connected")
        case .missedWhileAsleep: message = String(localized: "Mac was asleep at alarm time")
        }
        return r.isTest
            ? String(localized: "Last test: \(when) – \(message)")
            : String(localized: "Last alarm: \(when) – \(message)")
    }

    // MARK: Helpers

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let m = behavior.smartAlarmMinutes
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                behavior.smartAlarmMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    /// Locale of the language the app is actually showing (the in-app language override only changes the
    /// bundle's preferred localization, not `Locale.current`).
    private static var displayLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = displayLocale
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = displayLocale
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Calendar weekday number (1 = Sun … 7 = Sat) → locale symbol index.
    private static func weekdayName(_ dow: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = displayLocale
        let names = cal.weekdaySymbols
        return (1...7).contains(dow) ? names[dow - 1] : "?"
    }

    private static func weekdayInitial(_ dow: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = displayLocale
        let names = cal.veryShortWeekdaySymbols
        return (1...7).contains(dow) ? names[dow - 1] : "?"
    }
}
#endif
