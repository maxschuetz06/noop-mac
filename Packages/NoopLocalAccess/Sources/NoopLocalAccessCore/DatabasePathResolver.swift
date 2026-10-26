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
    /// default folder and then the legacy one.
    public static func mirrorPaths(dataFolder: String?,
                                   home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let folders = dataFolder.map { [$0] } ?? [defaultDataFolder, legacyDataFolder]
        return folders.map { "\(home)/\($0)/\(mirrorFileName)" }
    }

    /// Precedence: explicit path (`--db-path` / `NOOP_DB_PATH`, never falls back) → existing mirror in the
    /// external data folder (`NOOP_DATA_FOLDER`, else `~/NOOP-Data`, then `~/NOOP-Daten`) → official app
    /// container candidates.
    public static func resolve(configuration: LocalAccessConfiguration,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        let fm = FileManager.default
        if let explicit = configuration.databasePath {
            let expanded = expandHome(explicit, home: home)
            guard fm.fileExists(atPath: expanded) else {
                throw LocalAccessError.databaseUnavailable("NOOP database not found at NOOP_DB_PATH.")
            }
            return expanded
        }

        for mirror in mirrorPaths(dataFolder: configuration.dataFolder, home: home) where fm.fileExists(atPath: mirror) {
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
