import XCTest
import WhoopStore
@testable import Strand

/// Visibility / value-selection rules that keep Today a plain display of the user's values: the
/// first-run note, the Calibrating pill, coaching prose cards and the dated "Your cards" values.
final class TodayDisplayRulesTests: XCTestCase {

    private func day(_ key: String, hrv: Double? = nil, rhr: Int? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil, respRateBpm: resp)
    }

    // MARK: "scores are building" note

    func testBuildingNoteShowsOnFreshInstall() {
        XCTAssertTrue(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: false, dismissed: false, importedDays: 0, historyDays: 2))
    }

    func testBuildingNoteHiddenOnceWhoopExportIsImported() {
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: false, dismissed: false, importedDays: 294, historyDays: 294))
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: false, dismissed: false, importedDays: 1, historyDays: 1))
    }

    func testBuildingNoteHiddenWithEnoughHistoryWithoutImport() {
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: false, dismissed: false, importedDays: 0,
            historyDays: TodayDisplayRules.historyDaysEndingOnboarding))
    }

    func testBuildingNoteHiddenWhenDismissedScoredOrPastDay() {
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: false, dismissed: true, importedDays: 0, historyDays: 0))
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: true, todayHasRecovery: true, dismissed: false, importedDays: 0, historyDays: 0))
        XCTAssertFalse(TodayDisplayRules.showScoresBuildingNote(
            isToday: false, todayHasRecovery: false, dismissed: false, importedDays: 0, historyDays: 0))
    }

    // MARK: state pill

    func testPillIsSolidWithScore() {
        XCTAssertEqual(TodayDisplayRules.statePill(score: 71, calibrationNights: nil), .solid)
    }

    func testPillCalibratesOnlyWhileBaselineForms() {
        XCTAssertEqual(TodayDisplayRules.statePill(score: nil, calibrationNights: 2), .calibrating(nights: 2))
    }

    func testPillHiddenForBaselinedUserWithoutTodaysScore() {
        XCTAssertEqual(TodayDisplayRules.statePill(score: nil, calibrationNights: nil), .hidden)
    }

    // MARK: latest dated value

    func testLatestPicksNewestNonNilValueAtOrBeforeDay() {
        let days = [day("2026-07-21", hrv: 50), day("2026-07-23", hrv: 54), day("2026-07-24", hrv: nil)]
        let found = TodayDisplayRules.latest(in: days, upTo: "2026-10-14") { $0.avgHrv }
        XCTAssertEqual(found, TodayDisplayRules.DatedValue(value: 54, day: "2026-07-23"))
    }

    func testLatestIgnoresFutureRowsAndReturnsNilWithoutData() {
        let days = [day("2026-07-21", rhr: 52), day("2026-12-01", rhr: 99)]
        XCTAssertEqual(TodayDisplayRules.latest(in: days, upTo: "2026-10-14") { $0.restingHr }?.value, 52)
        XCTAssertNil(TodayDisplayRules.latest(in: days, upTo: "2026-10-14") { $0.respRateBpm })
        XCTAssertNil(TodayDisplayRules.latest(in: [], upTo: "2026-10-14") { $0.avgHrv })
    }

    func testDateCaptionUsesVitalSignsFormatAndOmitsShownDay() {
        XCTAssertEqual(TodayDisplayRules.dateCaption(valueDay: "2026-07-23", shownDay: "2026-10-14"), "23 Jul")
        XCTAssertNil(TodayDisplayRules.dateCaption(valueDay: "2026-10-14", shownDay: "2026-10-14"))
    }

    // MARK: "Your cards"

    func testEmptyCardsHiddenOnDefaultSelectionOnly() {
        XCTAssertFalse(TodayDisplayRules.showsDashboardCard(hasValue: false, userCustomised: false))
        XCTAssertTrue(TodayDisplayRules.showsDashboardCard(hasValue: true, userCustomised: false))
        XCTAssertTrue(TodayDisplayRules.showsDashboardCard(hasValue: false, userCustomised: true))
    }

    func testCoachingCardsFlagMatchesPlatform() {
        #if os(macOS)
        XCTAssertFalse(TodayDisplayRules.coachingCardsVisible)
        #else
        XCTAssertTrue(TodayDisplayRules.coachingCardsVisible)
        #endif
    }
}
