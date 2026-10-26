import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SettingsView {
    // MARK: - Diagnostics (every model)

    /// Raw-sensor CSV export — a read-only diagnostic over the decoded streams NOOP already stores
    /// (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events). Split out of the 5/MG card so it
    /// stays visible on EVERY model (#22): a WHOOP 4.0 owner still needs this to share decoded data.
    var rawSensorDiagnosticsCard: some View {
        SettingsSection(
            icon: "doc.text.magnifyingglass",
            title: "Diagnostics",
            blurb: "A read-only export of the decoded sensor streams NOOP already stores. Works on any strap — nothing is written to your device, and nothing is uploaded."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                // MARK: Export raw sensor data (CSV) — a read-only diagnostic over the decoded streams
                // NOOP already stores (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events).
                Button {
                    exportRawSensorCSV()
                } label: {
                    if rawCsvBusy {
                        HStack(spacing: NoopMetrics.space1 + 2) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export raw sensor data (CSV)", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(rawCsvBusy)

                if let url = lastRawCsvURL {
                    NoopButton("Reveal in Finder", systemImage: "folder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }

                Text("Dumps the last 24 hours of decoded per-sample sensor streams (heart rate, R-R, motion, steps, SpO₂, skin temperature, respiration, events) to a single CSV — all on \(Platform.deviceNounPhrase), nothing uploaded. Share it to help prototype and test sleep, activity and strength algorithms.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                scheduledExportControls
            }
        }
        // Re-arm / catch-up the daily export whenever Settings appears (self-heals after a relaunch).
        .onAppear { ScheduledDebugExport.activateIfEnabled() }
    }

    /// Daily auto-export of the strap log (#510 — parity with Android's DebugExportScheduler). Opt-in,
    /// default OFF: a toggle + a time-of-day picker + a "Run now". Honest about iOS background timing —
    /// the macOS drop is reliable (the app is usually running), the iOS one fires when iOS next wakes
    /// NOOP near the chosen time, never guaranteed to the minute.
    @ViewBuilder var scheduledExportControls: some View {
        Toggle(isOn: $debugExportOn) {
            Text("Daily auto-export of the strap log")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
        .onChangeCompat(of: debugExportOn) { on in ScheduledDebugExport.setEnabled(on) }

        if debugExportOn {
            HStack {
                Text("Time of day")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                DatePicker("", selection: debugExportTimeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel("Daily auto-export time")
            }

            NoopButton("Run now", systemImage: "square.and.arrow.down.on.square", kind: .secondary) {
                runScheduledExportNow()
            }
        }

        Text(debugExportCaption)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Honest caption — the drop location plus the platform-specific timing reality.
    var debugExportCaption: String {
        return "Writes a timestamped copy of your strap log to your Documents folder, once a day — handy for a bug report without remembering to grab it. On Mac it runs while NOOP is open (and catches up on launch if the time passed while it was closed). Everything stays on \(Platform.deviceNounPhrase); nothing is uploaded."
    }

    /// Bridges the minutes-since-midnight store to the DatePicker, persisting + rescheduling on change.
    var debugExportTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = debugExportMinutes / 60
                c.minute = debugExportMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                debugExportMinutes = m
                ScheduledDebugExport.setTimeMinutes(m)
            }
        )
    }

    /// "Run now": write an immediate timestamped strap-log drop (with the raw capture beside it, if a
    /// session has recorded one) and tell the user where it landed.
    func runScheduledExportNow() {
        model.ble.flushPuffinCaptures()
        let url = ScheduledDebugExport.runNow(captureURL: live.puffinCaptureURL)
        if let url {
            backupAlertTitle = "Strap log exported"
            backupAlertMessage = "Saved \(url.lastPathComponent) to your Documents folder."
        } else {
            backupAlertTitle = "Export failed"
            backupAlertMessage = "Couldn't write the strap log right now."
        }
        showBackupAlert = true
    }

    /// Export the last 24h of decoded sensor streams for the connected strap to a CSV, then save (macOS
    /// NSSavePanel) or share (iOS share sheet) — the same pattern as exportPuffinCaptures(). The store
    /// handle and the strap deviceId both come from the app's single "my-whoop" id.
    func exportRawSensorCSV() {
        rawCsvBusy = true
        Task {
            let since = Date().timeIntervalSince1970 - 24 * 60 * 60
            do {
                let url = try await model.repo.exportRawSensorCSV(deviceId: model.deviceId, since: since)
                await MainActor.run {
                    rawCsvBusy = false
                    lastRawCsvURL = url
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = url.lastPathComponent
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    let fm = FileManager.default
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: url, to: dest)
                    } catch {
                        backupAlertTitle = "Export failed"
                        backupAlertMessage = error.localizedDescription
                        showBackupAlert = true
                    }
                }
            } catch RepositoryError.storeUnavailable {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = "Export failed"
                    backupAlertMessage = "Couldn't open the local store."
                    showBackupAlert = true
                }
            } catch {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = "Export failed"
                    backupAlertMessage = error.localizedDescription
                    showBackupAlert = true
                }
            }
        }
    }

    /// Flush the in-flight capture, then copy it to a user-chosen location (save panel on macOS) or
    /// hand it to the system share sheet (iOS).
    func exportPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let src = live.puffinCaptureURL else { return }
        // Suggest a friendly, timestamped name so a reporter saving several captures gets sortable,
        // non-colliding files (#510) — e.g. noop-raw-capture-260617-1042.json.
        let suggested = FileExport.timestampedName("noop-raw-capture", ext: "json")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch {
            backupAlertTitle = "Export failed"
            backupAlertMessage = error.localizedDescription
            showBackupAlert = true
        }
    }

    /// One-tap matched-pair export (#510): export the raw puffin capture AND the strap log together,
    /// both stamped with the same `yyMMdd-HHmm` minute so they're obviously a pair. Reuses the existing
    /// export utilities — `FileExport.exportPair` shares both files in one iOS share sheet, and saves
    /// each via its own NSSavePanel on macOS (no new file plumbing).
    func exportRawAndLog() {
        model.ble.flushPuffinCaptures()
        guard let capture = live.puffinCaptureURL else {
            backupAlertTitle = "Nothing to export"
            backupAlertMessage = "No raw capture has been recorded yet this session."
            showBackupAlert = true
            return
        }
        let stamp = FileExport.timestamp()
        FileExport.exportPair(
            file: capture, fileSuggestedName: "noop-raw-capture-\(stamp).json",
            text: live.exportableLogText(), textSuggestedName: "noop-strap-log-\(stamp).txt")
    }

    /// Flush, then reveal the capture file in Finder so the user can grab it directly.
    func revealPuffinCaptures() {
        model.ble.flushPuffinCaptures()
        guard let url = live.puffinCaptureURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
