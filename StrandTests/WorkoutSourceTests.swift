import XCTest
import WhoopStore
@testable import Strand

/// Pins the pure workout-editing logic: source classification (the macOS read model has no
/// deviceId, so origin is recovered from `source`), the durable dismissed-span filter that keeps a
/// re-detected bout hidden (#107), manual-row validation, and field preservation on edit.
/// Mirrors the Android WorkoutEditingTest case-for-case.
final class WorkoutSourceTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    // MARK: - classify

    func testClassifyOrdersNoopBeforeWhoop() {
        // "my-whoop-noop" contains "whoop" — the -noop suffix MUST win, else a detected bout
        // would be classified as an imported WHOOP row and become un-dismissable.
        XCTAssertEqual(WorkoutSource.classify("my-whoop-noop"), .detected)
        XCTAssertEqual(WorkoutSource.classify("whoop"), .whoop)
        XCTAssertEqual(WorkoutSource.classify("manual"), .manual)
        XCTAssertEqual(WorkoutSource.classify("lifting"), .lifting)
        XCTAssertEqual(WorkoutSource.classify("activity-file"), .activityFile)
        XCTAssertEqual(WorkoutSource.classify("apple_health"), .apple)
        XCTAssertEqual(WorkoutSource.classify("apple-health"), .apple)
    }

    func testAppleHealthSourceAcceptsCanonicalAndLegacySpellings() {
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple-health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple_health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("APPLE_HEALTH"))
        XCTAssertFalse(WorkoutSource.isAppleHealth("whoop"))
    }

    func testDisplaySportRenamesDetectedToken() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
    }

    // MARK: - dismissed spans (durable #107 filter)

    func testParseDismissedSpansDropsMalformed() {
        let spans = WorkoutSource.parseDismissedSpans(["100:200", "bad", "5:5", "9:3", "300:400"])
        // "5:5" (zero width) and "9:3" (end<start) and "bad" are dropped.
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 100); XCTAssertEqual(spans[0].end, 200)
        XCTAssertEqual(spans[1].start, 300); XCTAssertEqual(spans[1].end, 400)
    }

    func testIsDismissedOnlyHidesOverlappingDetectedRows() {
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let detectedOverlap = row(start: 1500, end: 2500, sport: "detected", source: "my-whoop-noop")
        let detectedClear = row(start: 3000, end: 4000, sport: "detected", source: "my-whoop-noop")
        let manualOverlap = row(start: 1500, end: 2500, sport: "Running", source: "manual")
        XCTAssertTrue(WorkoutSource.isDismissed(detectedOverlap, spans: spans))
        XCTAssertFalse(WorkoutSource.isDismissed(detectedClear, spans: spans))
        // A manual (or imported) row is NEVER auto-hidden by a dismissed span — only detected bouts.
        XCTAssertFalse(WorkoutSource.isDismissed(manualOverlap, spans: spans))
    }

    func testIsDismissedSurvivesStartTsDrift() {
        // A re-detected bout whose boundary drifted a little still overlaps the dismissed span.
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let drifted = row(start: 1040, end: 2030, sport: "detected", source: "my-whoop-noop")
        XCTAssertTrue(WorkoutSource.isDismissed(drifted, spans: spans))
    }

    func testDismissedTokenRoundTrips() {
        let r = row(start: 1700000000, end: 1700003600, sport: "detected", source: "my-whoop-noop")
        let token = WorkoutSource.dismissedToken(for: r)
        XCTAssertEqual(token, "1700000000:1700003600")
        let spans = WorkoutSource.parseDismissedSpans([token])
        XCTAssertTrue(WorkoutSource.isDismissed(r, spans: spans))
    }

    // MARK: - cross-source dedup (#687)

    private func richRow(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A live strap session: HR trace, peak, strain, zones, distance, energy all captured.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 600, avgHr: 150, maxHr: 178,
                   strain: 14.0, distanceM: 10_000, zonesJSON: #"{"z1":10}"#, notes: nil)
    }
    private func thinImport(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A thin Health Connect / Apple import: only duration + calories.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 590, avgHr: nil, maxHr: nil,
                   strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testSportKeyFoldsCamelCaseAndSpacing() {
        XCTAssertEqual(WorkoutSource.sportKey("TraditionalStrengthTraining"),
                       WorkoutSource.sportKey("Traditional Strength Training"))
        XCTAssertEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("running"))
        XCTAssertNotEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("Cycling"))
    }

    func testSameActivityRequiresSportAndMajorityOverlap() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")        // 60 min
        let importDrift = thinImport(start: 1040, end: 4570, sport: "Running", source: "health-connect")
        XCTAssertTrue(WorkoutSource.sameActivity(live, importDrift))      // same sport, near-full overlap
        // Different sport in the same window is NOT the same activity.
        let otherSport = thinImport(start: 1040, end: 4570, sport: "Cycling", source: "health-connect")
        XCTAssertFalse(WorkoutSource.sameActivity(live, otherSport))
        // Back-to-back same-sport sessions that only touch at the edge stay distinct (<50% overlap).
        let nextRun = richRow(start: 4500, end: 8100, sport: "Running", source: "whoop")
        XCTAssertFalse(WorkoutSource.sameActivity(live, nextRun))
    }

    func testDedupCollapsesLiveAndImportKeepingRicher() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let hc = thinImport(start: 1030, end: 4580, sport: "Running", source: "health-connect")
        // Order shouldn't matter — the richer (live) row always survives.
        let a = WorkoutSource.dedupCrossSource([live, hc])
        let b = WorkoutSource.dedupCrossSource([hc, live])
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a.first?.source, "whoop")
        XCTAssertEqual(b.first?.source, "whoop")
        XCTAssertEqual(a.first?.strain, 14.0)   // kept the row with the captured trace
    }

    func testDedupKeepsNonImportOnRichnessTie() {
        // Two equally-thin rows: a strap "manual" live row and a Health Connect import. Keep the strap one.
        let manual = thinImport(start: 1000, end: 4600, sport: "Walking", source: "manual")
        let hc = thinImport(start: 1010, end: 4590, sport: "Walking", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([hc, manual])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "manual")
    }

    func testDedupLeavesDistinctSessionsAndIsStable() {
        let run = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let lift = richRow(start: 5000, end: 8600, sport: "Strength Training", source: "whoop")
        let hcRun = thinImport(start: 1020, end: 4580, sport: "Running", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([run, lift, hcRun])
        // The run pair collapses to one; the lift is untouched. Two sessions, original order preserved.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].sport, "Running")
        XCTAssertEqual(out[1].sport, "Strength Training")
    }

    // MARK: - buildManualRow validation

    func testBuildManualRowHappyPath() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        let r = WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "  Running ",
                                             avgHr: 150, energyKcal: 540, now: now)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.sport, "Running")          // trimmed
        XCTAssertEqual(r?.source, "manual")
        XCTAssertEqual(r?.durationS, 45 * 60)
        XCTAssertEqual(r?.endTs, r!.startTs + 45 * 60)
        XCTAssertEqual(r?.avgHr, 150)
        XCTAssertNil(r?.strain)                       // never fabricated without a captured HR window
    }

    func testBuildManualRowRejectsBadInput() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 0, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 25 * 60, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "   ", avgHr: nil, energyKcal: nil, now: now))
        // Future start.
        XCTAssertNil(WorkoutSource.buildManualRow(start: now.addingTimeInterval(60), durationMin: 30, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        // Out-of-range HR / kcal.
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: 10, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: nil, energyKcal: 99_999, now: now))
    }

    // MARK: - preservingCaptured

    func testPreservingCapturedCarriesUnexposedFieldsOnEdit() {
        // The sheet rebuilds a row from its 5 inputs; an edit must keep the original's captured
        // maxHr/strain (a live-tracked session has real values the sheet never shows).
        let old = row(start: 100, end: 3700, sport: "Workout", source: "manual",
                      avgHr: 130, maxHr: 175, strain: 13.5)
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        let merged = WorkoutSource.preservingCaptured(rebuilt, from: old)
        XCTAssertEqual(merged.sport, "Running")  // edited field kept
        XCTAssertEqual(merged.avgHr, 140)        // edited field kept
        XCTAssertEqual(merged.maxHr, 175)        // carried over from old
        XCTAssertEqual(merged.strain, 13.5)      // carried over from old
    }

    func testPreservingCapturedIsNoOpForFreshAdd() {
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        XCTAssertEqual(WorkoutSource.preservingCaptured(rebuilt, from: nil), rebuilt)
    }
}
