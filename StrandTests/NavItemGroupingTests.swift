import XCTest
@testable import Strand

/// Unit tests for the focused-sidebar grouping on `NavItem` (core sections vs. the collapsible
/// "More" group) and for the `NavRouter.Destination` → `NavItem` mapping.
final class NavItemGroupingTests: XCTestCase {

    func testCoreOrderIsAsSpecified() {
        XCTAssertEqual(
            NavItem.core,
            [.today, .dayDetails, .sleep, .trends, .workouts, .health, .stress,
             .live, .breathe, .dataSources, .devices, .settings]
        )
    }

    func testCoreHasNoDuplicates() {
        XCTAssertEqual(Set(NavItem.core).count, NavItem.core.count)
    }

    func testCoreAndMorePartitionAllCasesExactlyOnce() {
        XCTAssertTrue(Set(NavItem.core).isDisjoint(with: NavItem.more))
        XCTAssertEqual(Set(NavItem.more).count, NavItem.more.count)
        XCTAssertEqual(Set(NavItem.core + NavItem.more), Set(NavItem.allCases))
        XCTAssertEqual(NavItem.core.count + NavItem.more.count, NavItem.allCases.count)
    }

    func testCountsMatchDefaultSidebar() {
        XCTAssertEqual(NavItem.core.count, 12)
        XCTAssertEqual(NavItem.more.count, 13)
        XCTAssertEqual(NavItem.allCases.count, 25)
    }

    func testMoreKeepsAllCasesOrder() {
        XCTAssertEqual(NavItem.more, NavItem.allCases.filter { !NavItem.core.contains($0) })
    }

    func testRawValuesAreUnchanged() {
        // The sidebar uses these as stable ids.
        XCTAssertEqual(NavItem.today.rawValue, "Today")
        XCTAssertEqual(NavItem.insightsHub.rawValue, "What Moves You")
        XCTAssertEqual(NavItem.labBook.rawValue, "Lab Book")
        XCTAssertEqual(NavItem.fusedRecord.rawValue, "Your Data, Fused")
        XCTAssertEqual(NavItem.dataSources.rawValue, "Data Sources")
    }

    func testCoreIsMainThenTools() {
        XCTAssertEqual(NavItem.core, NavItem.main + NavItem.tools)
        XCTAssertEqual(NavItem.main.first, .today)
    }

    func testEverySidebarItemUsesAnOutlineIcon() {
        for item in NavItem.core + NavItem.more {
            XCTAssertFalse(item.outlineIcon.hasSuffix(".fill"), "\(item) should use an outline symbol")
        }
    }

    func testSidebarTitlesHaveEnglishSourceStrings() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(NavItem.today.title(in: english), "Overview")
        XCTAssertEqual(NavItem.workouts.title(in: english), "Training")
        for item in NavItem.allCases {
            XCTAssertFalse(item.title(in: english).isEmpty, "\(item) has no title")
        }
    }

    /// The German sidebar must read exactly as before the labels moved into the String Catalog.
    func testSidebarTitlesKeepTheirGermanLabels() {
        let expected: [NavItem: String] = [
            .today: "Übersicht", .dayDetails: "Tagesdetails", .sleep: "Schlaf", .trends: "Trends",
            .workouts: "Training", .health: "Gesundheit", .stress: "Stress", .live: "Live-Puls",
            .breathe: "Atmen", .dataSources: "Datenquellen", .devices: "Geräte", .settings: "Einstellungen",
            .insightsHub: "Was dich bewegt", .intervals: "Intervalle", .explore: "Entdecken",
            .compare: "Vergleichen", .insights: "Einblicke", .labBook: "Laborbuch", .rhythm: "Rhythmus",
            .appleHealth: "Apple Health", .xiaomi: "Mi Band", .fusedRecord: "Alle Daten",
            .notifications: "Mitteilungen", .automation: "Automationen", .about: "Über",
        ]
        XCTAssertEqual(Set(expected.keys), Set(NavItem.core + NavItem.more))
        let german = Locale(identifier: "de_DE")
        for (item, title) in expected {
            XCTAssertEqual(item.title(in: german), title, "\(item)")
        }
    }

    func testIsCoreMatchesCoreList() {
        for item in NavItem.allCases {
            XCTAssertEqual(item.isCore, NavItem.core.contains(item))
        }
    }

    func testSearchMatchesTheLocalizedTitleOrTheRawValue() {
        let german = Locale(identifier: "de_DE"), english = Locale(identifier: "en_US")
        XCTAssertTrue(NavItem.today.matches("übers", locale: german))
        XCTAssertFalse(NavItem.today.matches("übers", locale: english))
        XCTAssertTrue(NavItem.today.matches(" Overview ", locale: english))
        XCTAssertTrue(NavItem.today.matches("today", locale: german), "raw value matches in every language")
        XCTAssertFalse(NavItem.sleep.matches("overview", locale: english))
    }

    // MARK: - NavRouter destinations

    func testRouterDestinationsMapToExpectedItems() {
        XCTAssertEqual(NavItem(destination: .devices), .devices)
        XCTAssertEqual(NavItem(destination: .insightsHub), .insightsHub)
        XCTAssertEqual(NavItem(destination: .labBook), .labBook)
        XCTAssertEqual(NavItem(destination: .fusedRecord), .fusedRecord)
        XCTAssertEqual(NavItem(destination: .rhythm), .rhythm)
        XCTAssertEqual(NavItem(destination: .trends), .trends)
    }

    func testEveryRouterDestinationIsReachableInSidebar() {
        // Reachable = listed in the core group, or in "More" (which auto-expands when selected).
        let destinations: [NavRouter.Destination] =
            [.devices, .insightsHub, .labBook, .fusedRecord, .rhythm, .trends]
        let reachable = Set(NavItem.core + NavItem.more)
        for destination in destinations {
            XCTAssertTrue(reachable.contains(NavItem(destination: destination)),
                          "\(destination) is not reachable")
        }
    }

    func testMoreDestinationsAreNotCore() {
        for destination in [NavRouter.Destination.insightsHub, .labBook, .fusedRecord, .rhythm] {
            XCTAssertFalse(NavItem(destination: destination).isCore, "\(destination) should live in More")
        }
        for destination in [NavRouter.Destination.devices, .trends] {
            XCTAssertTrue(NavItem(destination: destination).isCore, "\(destination) should be core")
        }
    }
}
