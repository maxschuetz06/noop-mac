import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Profile photo (optional, on-device)

    /// Set / change / remove an optional profile picture. PhotosUI's `PhotosPicker` works on both
    /// iOS 16+ and macOS 13+ (NOOP's floor), so the same control serves both platforms — no
    /// availability gating needed. The photo is stored only on this device (NOOP is fully offline).
    var profilePhotoCard: some View {
        SettingsSection(
            icon: "person.crop.circle",
            title: "Profile photo",
            blurb: "Optional. Add a photo for the avatar in the top-left. Stored only on \(Platform.deviceNounPhrase) — NOOP is offline, so it's never uploaded."
        ) {
            HStack(spacing: 16) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: 64)
                    .accessibilityLabel(profile.hasAvatar ? "Your profile photo" : "No profile photo set")

                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                        Text(profile.hasAvatar ? "Change photo" : "Choose photo")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

                    if profile.hasAvatar {
                        Button("Remove photo") { profile.clearAvatar() }
                            .buttonStyle(NoopButtonStyle(.tertiary, fullWidth: true))
                            .accessibilityHint("Reverts to the default profile icon")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        // Load the picked photo's bytes, then hand them to the store (which downscales + persists).
        // Clearing the selection afterwards lets the user re-pick the same photo if they want.
        .onChange(of: avatarPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { profile.setAvatar(data) }
                    avatarPickerItem = nil
                }
            }
        }
    }

    // MARK: - Profile

    var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Age") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Stepper("Age", value: $profile.age, in: 13...100)
                            .labelsHidden()
                            .accessibilityLabel("Age, \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    // Imperial mode steps in pounds and stores the kg equivalent; metric steps in kg.
                    if unitSystem == .imperial {
                        poundsField(weightKg: $profile.weightKg)
                    } else {
                        measureField(value: $profile.weightKg, unit: "kg",
                                     range: 30...250, step: 0.5, format: "%.1f",
                                     accessibility: "Weight in kilograms")
                    }
                }
                rowDivider
                FormRow(label: "Height") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        feetInchesField(heightCm: $profile.heightCm)
                    } else {
                        measureField(value: $profile.heightCm, unit: "cm",
                                     range: 120...230, step: 1, format: "%.0f",
                                     accessibility: "Height in centimetres")
                    }
                }
                rowDivider
                // Waist (optional). Unlike the rows above it, an empty waist is valid (0 = unset) —
                // it's the ONE measurement that ADDS the VO₂max estimate alongside Fitness Age. It does
                // NOT sharpen the Fitness Age itself (the body term cancels in the Nes model), so it sits
                // apart with an honest "adds your VO₂max estimate" note rather than implying it tunes the age.
                FormRow(label: "Waist (optional)") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        waistInchesField(waistCm: $profile.waistCm)
                    } else {
                        waistCentimetresField(waistCm: $profile.waistCm)
                    }
                }
                Text("Optional — adds your VO₂max estimate. The Fitness Age itself doesn't need it. Measure around your middle, at the navel.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            hrMaxField
                            Text("bpm")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
                rowDivider
                // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor.
                // 1.0 = raw pass-through until the true 5/MG tick rate is known. The divisor goes
                // up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
                // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
                FormRow(label: "Step calibration") {
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f", profile.stepTicksPerStep))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 44, alignment: .trailing)
                        Stepper("Step calibration") {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true)
                        } onDecrement: {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false)
                        }
                            .labelsHidden()
                            .accessibilityLabel("Step calibration, \(String(format: "%.1f", profile.stepTicksPerStep)) counter ticks per step")
                    }
                }
                Text("Counter ticks per step — leave at 1.0 unless your steps run high. On a WHOOP 5/MG they can run very high (10× or more), so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                // Tap-through to the WHOOP 4.0 steps-ESTIMATE calibration (a SEPARATE thing from the
                // 5/MG @57 counter divisor above): a 4.0 sends no step count, so NOOP estimates steps
                // from motion and calibrates that to the phone. The sheet explains it, shows the fit +
                // a recent estimated-vs-phone comparison, and offers a manual coefficient.
                Button {
                    showStepsCalibration = true
                } label: {
                    FormRow(label: "Steps estimate") {
                        HStack(spacing: 8) {
                            Text(stepsCalibrationSummary)
                                .font(StrandFont.footnote)
                                .foregroundStyle(profile.stepsManualCoefficient > 0
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Steps estimate calibration. \(stepsCalibrationSummary). Opens the calibration screen.")
                Text("For a WHOOP 4.0, which sends no step count: NOOP estimates steps from motion, calibrated to your phone. Tap to see how close it is and adjust it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One-line state for the "Steps estimate" tap-through row: manual, the auto-fit confidence, or a
    /// not-yet-calibrated prompt — so the row reflects the current calibration without opening the sheet.
    var stepsCalibrationSummary: String {
        if profile.stepsManualCoefficient > 0 { return "Manual" }
        if profile.stepsCalibrationCoefficient > 0 {
            return "Auto · \(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) confidence"
        }
        return "Not calibrated"
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
    }

    /// Imperial weight entry: shows pounds, steps in 1-lb increments, and writes the kg equivalent back
    /// to the SI-stored profile. Range mirrors the metric 30…250 kg (≈66…551 lb).
    func poundsField(weightKg: Binding<Double>) -> some View {
        let lb = Binding<Double>(
            get: { UnitFormatter.kgToPounds(weightKg.wrappedValue) },
            set: { weightKg.wrappedValue = $0 / UnitFormatter.poundsPerKilogram }
        )
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", lb.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text("lb")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper("Weight in pounds", value: lb, in: 66...551, step: 1)
                .labelsHidden()
                .accessibilityLabel("Weight, \(Int(lb.wrappedValue.rounded())) pounds")
        }
    }

    /// Imperial height entry: shows feet′ inches″, steps in whole inches, and writes the cm equivalent
    /// back to the SI-stored profile. Range mirrors the metric 120…230 cm (≈47…91 in).
    func feetInchesField(heightCm: Binding<Double>) -> some View {
        let inches = Binding<Double>(
            get: { UnitFormatter.cmToInches(heightCm.wrappedValue).rounded() },
            set: { heightCm.wrappedValue = $0 * UnitFormatter.centimetersPerInch }
        )
        let parts = UnitFormatter.cmToFeetInches(heightCm.wrappedValue)
        return HStack(spacing: 10) {
            Text("\(parts.feet)′ \(parts.inches)″")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 56, alignment: .trailing)
            Stepper("Height in inches", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityLabel("Height, \(parts.feet) feet \(parts.inches) inches")
        }
    }

    /// Metric waist entry: 0 = unset (shows a muted "Not set" rather than a misleading 0 cm). Steps in
    /// 1-cm increments; the first increment from unset lands at a sensible 80 cm so the stepper doesn't
    /// crawl up from the range floor. Mirrors `measureField` but tolerant of the optional empty state.
    func waistCentimetresField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(set ? String(format: "%.0f", waistCm.wrappedValue) : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: 48, alignment: .trailing)
                if set {
                    Text("cm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Stepper("Waist in centimetres") {
                waistCm.wrappedValue = min(160, (set ? waistCm.wrappedValue : 79) + 1)
            } onDecrement: {
                // Stepping below the 60-cm floor clears it back to unset (optional).
                let next = waistCm.wrappedValue - 1
                waistCm.wrappedValue = next < 60 ? 0 : next
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(waistCm.wrappedValue.rounded())) centimetres" : "Waist not set")
        }
    }

    /// Imperial waist entry: 0 = unset (muted "Not set"); otherwise shows whole inches and stores the cm
    /// equivalent — the same metric/imperial treatment as Height. First increment from unset lands near a
    /// sensible 31″. Range mirrors the metric 60…160 cm (≈24…63 in).
    func waistInchesField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        let inches = set ? UnitFormatter.cmToInches(waistCm.wrappedValue).rounded() : 0
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(set ? "\(Int(inches))" : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: 48, alignment: .trailing)
                if set {
                    Text("in")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Stepper("Waist in inches") {
                let nextIn = (set ? inches : 30) + 1
                waistCm.wrappedValue = min(160, nextIn * UnitFormatter.centimetersPerInch)
            } onDecrement: {
                let nextIn = inches - 1
                // Stepping below the ~24″ floor clears it back to unset (optional).
                waistCm.wrappedValue = nextIn < 24 ? 0 : nextIn * UnitFormatter.centimetersPerInch
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(inches)) inches" : "Waist not set")
        }
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    var hrMaxField: some View {
        HStack(spacing: 10) {
            Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(profile.hrMaxOverride > 0
                                 ? StrandPalette.textPrimary
                                 : StrandPalette.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
    }
}
