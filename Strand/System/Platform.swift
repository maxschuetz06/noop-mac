import AppKit
import SwiftUI

/// The native bitmap image type.
public typealias PlatformImage = NSImage

// MARK: - Image bridging

extension Image {
    /// Build a SwiftUI `Image` from the native bitmap type.
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

// MARK: - Pasteboard

/// Clipboard write through `NSPasteboard`.
enum PlatformPasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Device noun (#225)

/// The device noun for user-facing copy that talks about *this* device generically, e.g.
/// "Everything stays on your \(Platform.deviceNoun)."
enum Platform {
    static var deviceNoun: String { "Mac" }

    /// "this Mac" — the common demonstrative form.
    static var deviceNounPhrase: String { "this \(deviceNoun)" }
}

// MARK: - Opening URLs

/// "Open this URL with the system" helper. Used for `mailto:` and `shortcuts://`.
enum PlatformOpen {
    @MainActor static func url(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
