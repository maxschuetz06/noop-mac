import AppKit
import UniformTypeIdentifiers

/// Pure description of the `NSOpenPanel` for one Data Sources import target, so the rules are
/// unit-testable without presenting a panel.
///
/// A folder is expressed as `dirs == true`, never as `UTType.folder` inside `types`: `types` only
/// filters *files* (`NSOpenPanel.allowedContentTypes`), while whether directories are selectable is
/// `canChooseDirectories`. Mixing `.folder` into the file-type list is what made the SwiftUI
/// `.fileImporter` panel grey out the `.zip` export together with its unzipped folder.
struct ImportPanelConfig: Equatable {
    let types: [UTType]
    let files: Bool
    let dirs: Bool

    static func make(for target: ImportTarget) -> (types: [UTType], files: Bool, dirs: Bool) {
        let declared = target.allowedContentTypes
        let acceptsFolder = declared.contains { $0.conforms(to: .folder) }
        let fileTypes = declared.filter { !$0.conforms(to: .folder) }
        return (types: fileTypes, files: !fileTypes.isEmpty, dirs: acceptsFolder)
    }
}

/// Presents the macOS import panel for an `ImportTarget` as a sheet on the key window.
enum ImportPanel {
    /// Builds the panel for `target` (at click time, so the types can never be stale).
    @MainActor
    static func makePanel(for target: ImportTarget) -> NSOpenPanel {
        let config = ImportPanelConfig.make(for: target)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = config.types
        panel.canChooseFiles = config.files
        panel.canChooseDirectories = config.dirs
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        return panel
    }

    /// Shows the panel and calls `completion` on the main actor with the chosen URL (not called on
    /// cancel). The URL carries the sandbox's user-selected extension exactly like `.fileImporter`'s
    /// result did, so callers keep using `startAccessingSecurityScopedResource()` unchanged.
    @MainActor
    static func present(for target: ImportTarget, completion: @escaping @MainActor (URL) -> Void) {
        let panel = makePanel(for: target)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in completion(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
