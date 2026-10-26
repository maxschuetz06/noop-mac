import Foundation
import WhoopProtocol

/// Retro-decode gate for the reject archive (#152). When the decoder learns a historical layout (e.g.
/// WHOOP 4.0 v25), every archived undecodable frame is re-run through it and whatever now decodes is
/// inserted: the only path by which already-acked banked history backfills after an update. The replay
/// runs once per `version`; it is idempotent if it runs again (rows dedupe by ts) and the archive is
/// bounded, so an extra run costs little. The archive carries no deviceId, so replayed rows attribute to
/// the current strap.
struct RejectArchiveReplayGate {
    enum Outcome: Equatable {
        /// The archive was already replayed for this version.
        case notDue
        /// Replayed; `rows` were newly inserted.
        case replayed(rows: Int)
        /// A store insert failed: the gate stays open so the next launch retries, because the archive
        /// holds the only surviving copy of these records.
        case deferred
    }

    let defaults: UserDefaults
    let key: String
    let version: String

    /// The gate the app runs at store bootstrap. It opens when the decoder version changes (S-9: a decoder
    /// fix must replay even within one app version) and on every app release, which also covers a newly
    /// mapped layout whose `DecoderVersion` bump was forgotten: those frames are undecodable by
    /// definition, so no decode fingerprint can notice them. Existing installs have no value under this
    /// key yet and replay once after updating; the replay is idempotent and the archive is bounded.
    static func production(defaults: UserDefaults = .standard,
                           decoderVersion: Int = DecoderVersion.current,
                           appVersion: String = appReleaseVersion) -> RejectArchiveReplayGate {
        RejectArchiveReplayGate(defaults: defaults, key: "rejectArchiveReplayedVersion",
                                version: "decoder-\(decoderVersion) app-\(appVersion)")
    }

    static let appReleaseVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var isDue: Bool { defaults.string(forKey: key) != version }

    func runIfDue(archive: RawHistoryArchive, store: BackfillStoreWriting, deviceId: String) async -> Outcome {
        guard isDue else { return .notDue }
        do {
            let rows = try await archive.replay(into: store, deviceId: deviceId)
            defaults.set(version, forKey: key)
            return .replayed(rows: rows)
        } catch {
            return .deferred
        }
    }
}
