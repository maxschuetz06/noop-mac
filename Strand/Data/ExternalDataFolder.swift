import Foundation

/// Optional folder in the user's real home, outside the sandbox container, that holds the database mirror
/// for local agents, the WHOOP import inbox and the raw-PPG capture. It is a build-time opt-in: the
/// `NOOP_EXTERNAL_DATA_FOLDER` build setting fills the Info.plist key `NOOPExternalDataFolder` with a
/// folder name, and the matching sandbox exception comes from a separate entitlements file. Without a
/// valid name the feature is disabled and the app writes nothing outside its container.
struct ExternalDataFolder: Equatable, Sendable {
    static let infoPlistKey = "NOOPExternalDataFolder"
    static let importDirectoryName = "Import"
    static let rawPPGDirectoryName = "raw-ppg"
    static let maxNameLength = 255
    /// Folders macOS or the user already use for other things. As the data folder they would be set to
    /// 0700 (breaking, for example, `~/Public` sharing), so these names disable the feature. Compared
    /// case-insensitively because the home volume usually is.
    static let wellKnownHomeFolders: Set<String> = [
        "applications", "desktop", "documents", "downloads", "library", "movies", "music", "pictures",
        "public", "sites",
    ]

    let name: String
    let root: URL

    var importInboxDirectory: URL { root.appendingPathComponent(Self.importDirectoryName, isDirectory: true) }
    var rawPPGDirectory: URL { root.appendingPathComponent(Self.rawPPGDirectoryName, isDirectory: true) }
    /// Home-relative path for UI copy, e.g. `~/NOOP-Data`.
    var displayPath: String { "~/\(name)" }
    var rawPPGDisplayPath: String { "\(displayPath)/\(Self.rawPPGDirectoryName)/" }

    /// The folder this build was configured with, or nil when the feature is disabled.
    static let current: ExternalDataFolder? = resolve(
        configuredName: Bundle.main.object(forInfoDictionaryKey: infoPlistKey),
        realHome: realHomeDirectory()
    )

    /// Accepts a single folder name relative to the home directory. Missing, empty, well-known folders and
    /// anything that could point elsewhere (slashes, `.`/`..`, `~`, unexpanded build settings) disable
    /// the feature.
    static func resolve(configuredName: Any?, realHome: URL) -> ExternalDataFolder? {
        guard let raw = configuredName as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard isValidName(name) else { return nil }
        return ExternalDataFolder(name: name, root: realHome.appendingPathComponent(name, isDirectory: true))
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxNameLength, name != ".", name != "..",
              !isWellKnownHomeFolder(name) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isWellKnownHomeFolder(_ name: String) -> Bool {
        wellKnownHomeFolders.contains(name.lowercased())
    }

    /// Real home directory. In the sandbox `NSHomeDirectory()` is the container, so ask the passwd database.
    static func realHomeDirectory() -> URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Creates directories and files that only the owner can read (0700 / 0600). The home directory is
/// group-readable on macOS and the external folder has no TCC protection, so health data written there
/// must not depend on the umask or on who created a folder first.
///
/// Permission rule: directories NOOP creates get 0700. An existing directory keeps its permissions,
/// except the configured data folder itself (`tighteningExisting`), which is never a well-known folder.
enum PrivateFiles {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    /// Creates `url` and any missing parents with 0700. An existing `url` is only set to 0700 when
    /// `tighteningExisting` is true and its name is not a well-known home folder; existing parents
    /// (e.g. the home directory) always keep their permissions.
    static func ensureDirectory(_ url: URL, tighteningExisting: Bool = false) throws {
        var missing: [URL] = []
        var cursor = url.standardizedFileURL
        var isDir: ObjCBool = false
        while !FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDir) {
            missing.append(cursor)
            cursor = cursor.deletingLastPathComponent()
        }
        guard isDir.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: cursor.path]) }
        for dir in missing.reversed() {
            guard mkdir(dir.path, directoryMode) == 0 || errno == EEXIST else { throw posixError(dir) }
        }
        let created = !missing.isEmpty
        let tightens = tighteningExisting && !ExternalDataFolder.isWellKnownHomeFolder(url.lastPathComponent)
        guard created || tightens else { return }
        guard chmod(url.path, directoryMode) == 0 else { throw posixError(url) }
    }

    /// Creates an empty 0600 file. Returns false (and leaves it untouched) when it already exists.
    @discardableResult
    static func createEmptyFile(at url: URL, mode: mode_t = fileMode) throws -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw posixError(url)
        }
        close(fd)
        return true
    }

    /// Writes `text` to a 0600 file unless `url` exists. The content is published atomically
    /// (temporary file + exclusive rename), so a crash never leaves a half-written file behind.
    static func writeIfMissing(_ text: String, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try createEmptyFile(at: temp)
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) != 0 {
            let failure = errno
            try? FileManager.default.removeItem(at: temp)
            if failure != EEXIST { throw posixError(url, code: failure) }
        }
    }

    private static func posixError(_ url: URL, code: Int32 = errno) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
