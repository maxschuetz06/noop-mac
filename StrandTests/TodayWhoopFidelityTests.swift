import XCTest
@testable import Strand

/// Imported-WHOOP fidelity on Today: absolute skin temperature, calories fallback, Max/Ø HR caption and
/// the WHOOP 0–21 default Effort scale.
final class TodayWhoopFidelityTests: XCTestCase {

    private let en = Locale(identifier: "en")
    private let de = Locale(identifier: "de")

    // MARK: Skin temperature (mixed absolute / deviation semantics)

    func testImportedAbsoluteSkinTempShowsAsCelsius() {
        XCTAssertEqual(TodayView.skinTempDisplay(33.8, unit: .celsius), "33.8 °C")
    }

    func testImportedAbsoluteSkinTempConvertsToFahrenheitWithOffset() {
        XCTAssertEqual(TodayView.skinTempDisplay(33.8, unit: .fahrenheit), "92.8 °F")
    }

    func testNegativeZeroDeviationHasNoSign() {
        XCTAssertEqual(TodayView.skinTempDisplay(-0.04, unit: .celsius), "0.0 °C")
        XCTAssertEqual(TodayView.skinTempDisplay(0.04, unit: .celsius), "0.0 °C")
        XCTAssertEqual(TodayView.skinTempDisplay(-0.0, unit: .celsius), "0.0 °C")
        XCTAssertEqual(TodayView.skinTempDisplay(-0.02, unit: .fahrenheit), "0.0 °F")
    }

    func testOnDeviceDeviationStaysSigned() {
        XCTAssertEqual(TodayView.skinTempDisplay(0.3, unit: .celsius), "+0.3 °C")
        XCTAssertEqual(TodayView.skinTempDisplay(-0.4, unit: .celsius), "-0.4 °C")
    }

    func testDeviationInFahrenheitScalesWithoutOffset() {
        XCTAssertEqual(TodayView.skinTempDisplay(1.0, unit: .fahrenheit), "+1.8 °F")
    }

    // MARK: Calories fallback

    func testAppleActiveEnergyWinsOverWhoop() {
        let r = TodayView.caloriesResolution(appleDisplay: "512", whoopKcal: 2405, locale: en)
        XCTAssertFalse(r.isWhoop)
        XCTAssertEqual(r.caption, "active")
        XCTAssertNil(r.value)
    }

    func testWhoopEnergyFillsInWhenAppleHasNone() {
        let r = TodayView.caloriesResolution(appleDisplay: "—", whoopKcal: 2405, locale: en)
        XCTAssertTrue(r.isWhoop)
        XCTAssertEqual(r.value, 2405)
        XCTAssertEqual(r.caption, "WHOOP total")
    }

    func testNeitherSourceKeepsTheEmptyAppleState() {
        let r = TodayView.caloriesResolution(appleDisplay: "—", whoopKcal: nil, locale: en)
        XCTAssertFalse(r.isWhoop)
        XCTAssertNil(r.value)
    }

    func testCaloriesCaptionsAreLocalized() {
        XCTAssertEqual(TodayView.caloriesResolution(appleDisplay: "—", whoopKcal: 2405, locale: de).caption,
                       "WHOOP gesamt")
        XCTAssertEqual(TodayView.caloriesResolution(appleDisplay: "512", whoopKcal: nil, locale: de).caption,
                       "aktiv")
    }

    // MARK: Max / average HR

    func testHeartRateCaption() {
        XCTAssertEqual(TodayView.heartRateCaption(max: 153, avg: 69, locale: en), "Max 153 · Ø 69 bpm")
        XCTAssertEqual(TodayView.heartRateCaption(max: 153.4, avg: nil, locale: en), "Max 153 bpm")
        XCTAssertEqual(TodayView.heartRateCaption(max: nil, avg: 68.6, locale: en), "Ø 69 bpm")
        XCTAssertNil(TodayView.heartRateCaption(max: nil, avg: nil, locale: en))
    }

    func testHeartRateCaptionIsLocalizedGerman() {
        XCTAssertEqual(TodayView.heartRateCaption(max: 153, avg: 69, locale: de), "Max 153 · Ø 69 bpm")
        XCTAssertEqual(TodayView.heartRateCaption(max: 153.4, avg: nil, locale: de), "Max 153 bpm")
    }

    // MARK: Effort scale default

    func testEffortScaleDefaultsToWhoopWhenUnset() {
        let key = UnitPrefs.effortScaleKey          // evaluating the key registers the default
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } }
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), EffortScale.whoop.rawValue)
        XCTAssertEqual(UnitPrefs.resolveEffortScale(""), .whoop)
    }

    func testExplicitEffortChoiceIsKept() {
        let key = UnitPrefs.effortScaleKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(EffortScale.hundred.rawValue, forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), EffortScale.hundred.rawValue)
        XCTAssertEqual(UnitPrefs.resolveEffortScale(EffortScale.hundred.rawValue), .hundred)
    }
}
