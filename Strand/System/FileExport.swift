import Foundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Cross-platform "save / share a file" helper.
///
/// - macOS uses `NSSavePanel` (sandbox-safe via the user-selected-file entitlement).
/// - iOS presents the system share sheet (`UIActivityViewController`) so the user can save the file
///   to Files, AirDrop it, or send it on — the idiomatic iOS way to get a file out of the sandbox.
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
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #else
        // Write to a temp file FIRST and only present the share sheet if the file actually exists.
        // The previous `try?` swallowed write failures, then handed an empty/missing path to the
        // share sheet — the user saw a broken export with no error. Clean up the temp file after the
        // share sheet closes so the temporaryDirectory doesn't accumulate dead exports across runs.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(activityItems: [url], cleanup: [url])
        #endif
    }

    /// Let the user save / share an existing file at `src`. On macOS this copies to a chosen
    /// destination; on iOS it offers the file through the share sheet. `src` is owned by the caller
    /// (e.g. a Puffin capture inside the app's container) and is NOT deleted by the share-sheet
    /// completion handler — only files we staged ourselves get cleaned up.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
        #else
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        present(activityItems: [src], cleanup: [])
        #endif
    }

    /// Export an existing file AND a block of text together as a matched pair (#510 — raw capture + the
    /// strap log that produced it). On iOS both are offered in ONE share sheet so the reporter saves /
    /// AirDrops them in a single gesture; on macOS the system has no multi-file save panel, so each is
    /// saved through its own panel in sequence (capture first, then the log). Reuses `exportFile` /
    /// `exportText` semantics — no new file plumbing.
    @MainActor
    static func exportPair(file src: URL, fileSuggestedName: String,
                           text: String, textSuggestedName: String) {
        #if os(macOS)
        // Capture first, then the log — two panels back-to-back. Cancelling either just skips that file.
        exportFile(at: src, suggestedName: fileSuggestedName)
        exportText(text, suggestedName: textSuggestedName)
        #else
        guard FileManager.default.fileExists(atPath: src.path) else {
            // No capture file — fall back to sharing just the log so the tap isn't a dead end.
            exportText(text, suggestedName: textSuggestedName)
            return
        }
        // Stage the log to a temp file so the share sheet carries both as real documents; clean up the
        // staged log (only) once the sheet closes — the capture file is owned by the app container.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(textSuggestedName)
        do {
            try text.write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            // Couldn't stage the log — still share the capture so the action isn't lost.
            present(activityItems: [src], cleanup: [])
            return
        }
        present(activityItems: [src, logURL], cleanup: [logURL])
        #endif
    }

    #if os(iOS)
    /// Present `UIActivityViewController` and, once it closes, best-effort remove the URLs in
    /// `cleanup` so staged exports don't accumulate in `temporaryDirectory` across runs.
    @MainActor
    private static func present(activityItems: [Any], cleanup: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared
                .connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        // Present from the TOP-MOST controller, not the root (#455). When the caller is itself inside a
        // SwiftUI sheet — e.g. the Trends report is shown via `.sheet` — root already has that sheet
        // presented, so `root.present(...)` is a no-op ("already presenting…") and the share sheet never
        // appears. Climb the presentedViewController chain so the share sheet stacks on top of whatever's
        // up. (The Share-strap-log path worked only because Settings isn't a sheet — root had nothing on it.)
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if !cleanup.isEmpty {
            vc.completionWithItemsHandler = { _, _, _, _ in
                let fm = FileManager.default
                for url in cleanup where fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
            }
        }
        // iPad: anchor the popover to the screen centre to avoid a crash.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
    #endif
}
