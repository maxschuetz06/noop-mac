import Foundation

public struct LocalAccessConfiguration: Equatable, Sendable {
    public var databasePath: String?
    /// Home-relative external data folder the app mirrors into (`NOOP_EXTERNAL_DATA_FOLDER` of the build).
    public var dataFolder: String?
    public var bundleID: String?
    public var deviceID: String

    public init(databasePath: String? = nil, dataFolder: String? = nil, bundleID: String? = nil,
                deviceID: String = "my-whoop") {
        self.databasePath = databasePath
        self.dataFolder = dataFolder
        self.bundleID = bundleID
        self.deviceID = deviceID
    }

    public static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LocalAccessConfiguration {
        LocalAccessConfiguration(
            databasePath: nonEmpty(env["NOOP_DB_PATH"]),
            dataFolder: nonEmpty(env["NOOP_DATA_FOLDER"]),
            bundleID: nonEmpty(env["NOOP_BUNDLE_ID"]),
            deviceID: nonEmpty(env["NOOP_DEVICE_ID"]) ?? "my-whoop"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum DatabasePathResolver {
    public static let productionBundleID = "com.noopapp.noop"
    /// Read-only mirror a NOOP build with an external data folder publishes for local agents.
    public static let mirrorFileName = "whoop-latest.sqlite"
    /// Folder name suggested by the docs for new setups.
    public static let defaultDataFolder = "NOOP-Data"
    /// Folder name of earlier builds; still found so existing setups keep working.
    public static let legacyDataFolder = "NOOP-Daten"

    /// Mirror locations to try, in order: only the configured folder when one is set, otherwise the
    /// default folder and, only while that folder does not exist, the legacy one. Once `~/NOOP-Data`
    /// exists the app writes there, so a leftover legacy mirror would be stale.
    public static func mirrorPaths(dataFolder: String?,
                                   home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let folders: [String]
        if let dataFolder {
            folders = [dataFolder]
        } else if FileManager.default.fileExists(atPath: "\(home)/\(defaultDataFolder)") {
            folders = [defaultDataFolder]
        } else {
            folders = [defaultDataFolder, legacyDataFolder]
        }
        return folders.map { "\(home)/\($0)/\(mirrorFileName)" }
    }

    /// One stderr line (the MCP server log for stdio clients) whenever the legacy mirror is read.
    public static func legacyMirrorWarning(modified: Date?) -> String {
        let date = modified.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        return "[noop-local-access] warning: reading the legacy mirror ~/\(legacyDataFolder)/\(mirrorFileName) "
            + "(last modified \(date)); it may be stale. Set NOOP_DATA_FOLDER or NOOP_DB_PATH to choose the mirror."
    }

    public static func writeToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Precedence: explicit path (`--db-path` / `NOOP_DB_PATH`, never falls back) → existing mirror in the
    /// external data folder (`NOOP_DATA_FOLDER`, else `~/NOOP-Data`, then `~/NOOP-Daten` while
    /// `~/NOOP-Data` does not exist; `warn` reports that case) → official app container candidates.
    public static func resolve(configuration: LocalAccessConfiguration,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                               warn: (String) -> Void = writeToStandardError) throws -> String {
        let fm = FileManager.default
        if let explicit = configuration.databasePath {
            let expanded = expandHome(explicit, home: home)
            guard fm.fileExists(atPath: expanded) else {
                throw LocalAccessError.databaseUnavailable("NOOP database not found at NOOP_DB_PATH.")
            }
            return expanded
        }

        let legacyMirror = "\(home)/\(legacyDataFolder)/\(mirrorFileName)"
        for mirror in mirrorPaths(dataFolder: configuration.dataFolder, home: home) where fm.fileExists(atPath: mirror) {
            if configuration.dataFolder == nil, mirror == legacyMirror {
                let modified = (try? fm.attributesOfItem(atPath: mirror))?[.modificationDate] as? Date
                warn(legacyMirrorWarning(modified: modified))
            }
            return mirror
        }

        for candidate in candidates(bundleID: configuration.bundleID, home: home) where fm.fileExists(atPath: candidate) {
            return candidate
        }

        throw LocalAccessError.databaseUnavailable(
            "No NOOP database was found. Use a NOOP build with an external data folder so it publishes <folder>/whoop-latest.sqlite (set NOOP_DATA_FOLDER if the folder is not ~/NOOP-Data), or set NOOP_DB_PATH explicitly."
        )
    }

    public static func candidates(bundleID: String? = nil, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var ids = [productionBundleID]
        if let bundleID, bundleID != productionBundleID {
            ids.insert(bundleID, at: 0)
        }

        var paths: [String] = ids.map {
            "\(home)/Library/Containers/\($0)/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
        }
        paths.append("\(home)/Library/Application Support/OpenWhoop/whoop.sqlite")
        return orderedUnique(paths)
    }

    public static func expandHome(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + String(path.dropFirst())
    }
}
