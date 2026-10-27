import XCTest
@testable import Strand

/// The widget extension decodes the JSON the app writes into the App Group, so the encoded key set is a
/// cross-process contract: renaming or nesting a field would blank the widget until both sides update.
final class WidgetSnapshotCodingTests: XCTestCase {
    private static let fullJSON = #"""
    {"recovery":72,"bpm":61,"batteryPct":84,"bonded":true,"updated":10,"effort":59,"rest":84,
     "hrv":64,"restingHr":52,"lastSync":5,"localeIdentifier":"de_DE"}
    """#

    private static var full: WidgetSnapshot {
        var snap = WidgetSnapshot(recovery: 72, bpm: 61, batteryPct: 84, bonded: true,
                                  updated: Date(timeIntervalSinceReferenceDate: 10))
        snap.effort = 59
        snap.rest = 84
        snap.hrv = 64
        snap.restingHr = 52
        snap.lastSync = Date(timeIntervalSinceReferenceDate: 5)
        snap.localeIdentifier = "de_DE"
        return snap
    }

    func testAWrittenSnapshotDecodesFieldForField() throws {
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(Self.fullJSON.utf8))
        XCTAssertEqual(decoded, Self.full)
    }

    func testEncodingKeepsTheFlatKeySetAndRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.full)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["recovery", "bpm", "batteryPct", "bonded", "updated", "effort", "rest",
                                          "hrv", "restingHr", "lastSync", "localeIdentifier"])
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), Self.full)
    }
}
