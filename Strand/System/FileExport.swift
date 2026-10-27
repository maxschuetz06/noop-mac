import AppKit
import Foundation
import UniformTypeIdentifiers

/// "Save a file" helper over `NSSavePanel` (sandbox-safe via the user-selected-file entitlement).
enum FileExport {

    /// A short `yyMMdd-HHmm` wall-clock stamp for export filenames (#510 — maddognik's protocol RE),
    /// so a reporter who saves several strap logs / raw captures in a row gets sortable, non-colliding
    /// files (e.g. `noop-strap-log-260617-1042.txt`) instead of repeatedly overwriting one name.
    /// Locale-independent (POSIX) so the stamp is stable on every machine.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        return f.string(from: date)
    }

    /// Compose a timestamped suggested filename — `<prefix>-<yyMMdd-HHmm>.<ext>`
    /// (e.g. `timestampedName("noop-strap-log", ext: "txt")` → `noop-strap-log-260617-1042.txt`).
    static func timestampedName(_ prefix: String, ext: String) -> String {
        "\(prefix)-\(timestamp()).\(ext)"
    }

    /// Write `text` to a file and let the user choose where it goes.
    @MainActor
    static func exportText(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Let the user save a copy of the existing file at `src` to a chosen destination. `src` is owned by
    /// the caller (e.g. a Puffin capture inside the app's container) and is never deleted.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
    }

    /// Export an existing file AND a block of text together as a matched pair (#510 — raw capture + the
    /// strap log that produced it). macOS has no multi-file save panel, so each is saved through its own
    /// panel in sequence (capture first, then the log). Reuses `exportFile` /
    /// `exportText` semantics — no new file plumbing.
    @MainActor
    static func exportPair(file src: URL, fileSuggestedName: String,
                           text: String, textSuggestedName: String) {
        // Capture first, then the log — two panels back-to-back. Cancelling either just skips that file.
        exportFile(at: src, suggestedName: fileSuggestedName)
        exportText(text, suggestedName: textSuggestedName)
    }

}
