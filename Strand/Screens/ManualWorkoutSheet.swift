import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Manual workout sheet
//
// Add a workout you tracked elsewhere, or edit one you already logged. Five inputs — sport,
// start, duration, average HR, calories — validated by WorkoutSource.buildManualRow (the same
// honest-row rules the engine uses). On save the caller persists it under the strap source via
// Repository.saveManualWorkout. Captured-but-unexposed fields (maxHr / strain / zones) on an edited
// row are carried over by WorkoutSource.preservingCaptured so editing a live-tracked session's
// sport/duration never silently wipes its real strain.
//
// `editing` is non-nil when editing an existing row (its values pre-fill the form and it is passed
// as `replacing:` so a changed natural key deletes the old row). nil = a fresh add.

struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a new manual workout.
    let editing: WorkoutRow?
    /// Called with the validated row (and the original, when editing) once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sport: String
    @State private var start: Date
    @State private var durationMin: Int
    @State private var avgHrText: String
    @State private var kcalText: String

    /// Focus for the numeric (Avg HR / Calories) fields so the keyboard Done button can resign them —
    /// the decimal pad has no return key. iOS-only effect; the enum keeps both platforms compiling.
    private enum NumberField: Hashable { case avgHr, calories }
    @FocusState private var focusedField: NumberField?

    /// Whether the Sport text field is being edited — drives whether the catalogue suggestions show
    /// beneath it. The list also stays hidden once the typed text exactly matches a catalogue sport
    /// (a settled choice), so the form isn't permanently half-covered.
    @FocusState private var sportFocused: Bool

    init(editing: WorkoutRow? = nil,
         onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // Pre-fill from the edited row (display "detected" as "Activity" so a re-label starts clean).
        let e = editing
        _sport = State(initialValue: e.map { WorkoutSource.displaySport($0.sport) } ?? "")
        _start = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) } ?? Date())
        _durationMin = State(initialValue: e.map { max(1, Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded())) } ?? 45)
        _avgHrText = State(initialValue: e?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: e?.energyKcal.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                field("Sport") {
                    sportPicker
                }
                field("Start") {
                    DatePicker("", selection: $start, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .accessibilityLabel("Start date and time")
                }
                field("Duration") {
                    HStack(spacing: 12) {
                        Stepper(value: $durationMin, in: 1...(24 * 60), step: 5) {
                            Text(durationLabel)
                                .font(StrandFont.number(16))
                                .foregroundStyle(StrandPalette.effortBright)
                        }
                        .accessibilityLabel("Duration in minutes")
                    }
                }
                HStack(spacing: 14) {
                    field("Avg HR") {
                        numberInput("optional", text: $avgHrText, unit: "bpm", field: .avgHr)
                            .accessibilityLabel("Average heart rate in beats per minute, optional")
                    }
                    field("Calories") {
                        numberInput("optional", text: $kcalText, unit: "kcal", field: .calories)
                            .accessibilityLabel("Calories in kilocalories, optional")
                    }
                }
            }
            if let validationNote { noteRow(validationNote) }
            footer
        }
        .padding(NoopMetrics.space6)
        // A fixed 420pt is right for the free-floating macOS sheet, but on iPhone it's wider than
        // the screen, so the Avg HR/Calories row, the Start DatePicker and the footer ran off the
        // right edge (#185, same fix as WhatsNewView/ScoringGuideView). iOS fills the presented
        // sheet's width and sizes to content height instead.
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        // A short 5-field form → open at .medium with .large a drag away; the grabber also gives the
        // top dismiss affordance the sheet otherwise lacks (only a bottom Cancel).
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
        // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add. No-op on macOS.
        .keyboardDoneToolbar($focusedField)
    }

    // MARK: - Sport picker
    //
    // A searchable PICKER over the shared WorkoutCatalog (the same named-sport list the live tracker
    // uses, incl. Padel) with a free-text FALLBACK: the text field IS the value, so an unusual sport
    // NOOP doesn't enumerate still saves exactly as typed (#519). Typing filters the catalogue
    // beneath the field; tapping a match fills it; the list collapses on a settled / off-catalogue
    // entry so the short form isn't permanently covered. Mirrors Android WorkoutsScreen.SportPickerField.

    /// Suggestions for the current text — the whole catalogue while empty, else a case-insensitive
    /// name filter. Empty list ⇒ a free-typed sport with no match (keeps whatever was typed).
    private var sportSuggestions: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(sport) }

    /// Show the list only while the field is focused, there are matches, and the text isn't already an
    /// exact catalogue name (a settled choice collapses it).
    private var showSportSuggestions: Bool {
        sportFocused && !sportSuggestions.isEmpty && WorkoutCatalog.sport(named: sport) == nil
    }

    private var sportPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("e.g. Running", text: $sport)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused($sportFocused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .accessibilityLabel("Sport")
            if showSportSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sportSuggestions) { sp in
                            Button {
                                sport = sp.name
                                sportFocused = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(sp.name)
                                        .font(StrandFont.body)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    if sp.isDistanceSport {
                                        Text("· GPS")
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pick \(sp.name)")
                        }
                    }
                }
                .frame(maxHeight: 168)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // A small Effort-world glyph so the sheet reads as part of the workouts (amber) world.
            Image(systemName: "figure.run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 30, height: 30)
                .background(StrandPalette.effortColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Add Workout" : "Edit Workout")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(editing == nil
                     ? "Log a session you tracked elsewhere."
                     : "Adjust this session's details.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton("Cancel", kind: .tertiary) { dismiss() }
            Spacer()
            NoopButton(editing == nil ? "Add" : "Save", systemImage: "checkmark", kind: .primary) {
                save()
            }
            .disabled(builtRow == nil)
            .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                // Numeric entry → decimal pad on iOS (digits + "."), not the QWERTY default; no-op on macOS.
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        // Fill the field column so the Avg HR / Calories boxes share an identical width — left to
        // their intrinsic size the two boxes rendered unequal (the "bpm"/"kcal" units differ in
        // length), so the side-by-side row read as lopsided (#234).
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var durationLabel: String {
        let h = durationMin / 60, m = durationMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Parsed avg-HR — nil for blank, an out-of-band sentinel handled by buildManualRow otherwise.
    private var avgHr: Int? { Int(avgHrText.trimmingCharacters(in: .whitespaces)) }
    private var kcal: Double? { Double(kcalText.trimmingCharacters(in: .whitespaces)) }

    /// The validated row, or nil when the inputs can't make an honest one (drives the disabled Save +
    /// the inline note). Built through the same WorkoutSource.buildManualRow the engine trusts.
    private var builtRow: WorkoutRow? {
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — guard before building.
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty && avgHr == nil { return nil }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty && kcal == nil { return nil }
        guard let base = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                      sport: sport, avgHr: avgHr, energyKcal: kcal)
        else { return nil }
        // Carry over captured-but-unexposed fields when editing an existing strap session.
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    private var validationNote: String? {
        guard builtRow == nil else { return nil }
        if sport.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a sport." }
        if start > Date() { return "Start can't be in the future." }
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty, avgHr == nil || !(25...250).contains(avgHr ?? -1) {
            return "Average HR must be 25–250 bpm."
        }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return "Calories must be 0–20,000."
        }
        return "Check the values and try again."
    }

    private func save() {
        guard let row = builtRow else { return }
        onSave(row, editing)
        dismiss()
    }
}

// MARK: - Live workout start picker
//
// The Apple-side entry point for LIVE tracking, mirroring Android's StartWorkoutSheet (WorkoutStart.kt):
// pick a named sport from the shared WorkoutCatalog, then begin the session. Brings the iOS/macOS live
// tracker to parity with Android, which has had a named-sport picker on Start since #115 — previously
// the Apple "Start workout" buttons called `startWorkout()` with no sport and every live session saved
// as the generic "Workout". A host presents this and forwards the chosen name to
// `AppModel.startWorkout(sport:)`. Free-text isn't offered here (a live start is a quick tap from a
// fixed list); an unusual sport can still be set afterwards via the manual edit sheet's free-text field.

struct StartWorkoutSheet: View {
    /// Called with the chosen sport name once the user taps Start. The host wires this to
    /// `model.startWorkout(sport:)` (and presents the live workout view, as it does today).
    let onStart: (_ sport: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = WorkoutCatalog.defaultSportName

    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }
    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "figure.run")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 30, height: 30)
                    .background(StrandPalette.effortColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a workout")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Pick a sport — NOOP records HR, peak, average and effort from the live feed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            TextField("Search sport", text: $query)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .accessibilityLabel("Search sport")

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { sp in
                        Button {
                            selected = sp.name
                        } label: {
                            HStack(spacing: 6) {
                                Text(sp.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(sp.name == selected
                                                     ? StrandPalette.accent : StrandPalette.textPrimary)
                                if sp.isDistanceSport {
                                    Text("· GPS")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pick \(sp.name)")
                        .accessibilityAddTraits(sp.name == selected ? [.isSelected] : [])
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))

            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Cancel", kind: .tertiary) { dismiss() }
                Spacer()
                NoopButton("Start \(selected)", systemImage: "figure.run", kind: .primary) {
                    onStart(selected)
                    dismiss()
                }
                .accessibilityLabel("Start \(selected)")
            }
        }
        .padding(NoopMetrics.space6)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
    }
}

#if DEBUG
#Preview("Add") {
    ManualWorkoutSheet { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Edit") {
    ManualWorkoutSheet(editing: WorkoutRow(
        startTs: Int(Date().timeIntervalSince1970) - 3600, endTs: Int(Date().timeIntervalSince1970),
        sport: "Running", source: "manual", durationS: 3600, energyKcal: 540,
        avgHr: 148, maxHr: 172, strain: 12.4, distanceM: nil, zonesJSON: nil, notes: nil)) { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Start") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
