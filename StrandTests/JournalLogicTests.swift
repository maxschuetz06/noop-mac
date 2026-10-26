import XCTest
import WhoopStore
@testable import Strand

/// Pins the native-journal merge logic, mirroring the Android JournalLogTest value-for-value so the
/// two platforms merge catalogs and entries identically — question strings are opaque exact-match
/// keys to the effects engines on both sides.
final class JournalLogicTests: XCTestCase {

    private func e(_ day: String, _ q: String, _ yes: Bool) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil)
    }

    func testNativeWinsOnCollision() {
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].answeredYes)
    }

    func testDisjointKeysUnionAndSort() {
        let imported = [e("2026-06-09", "B?", true)]
        let native = [e("2026-06-10", "A?", false), e("2026-06-09", "A?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 3)
        // Sorted day ASC then question ASC — matches the DAO/store read order.
        XCTAssertEqual(merged.map(\.question), ["A?", "B?", "A?"])
        XCTAssertEqual(merged.map(\.day), ["2026-06-09", "2026-06-09", "2026-06-10"])
    }

    @MainActor
    func testCatalogAdoptsImportedCasing() {
        let cat = JournalCatalogStore.mergeCatalog(imported: ["DID YOU DRINK ANY ALCOHOL?"], custom: [])
        XCTAssertEqual(cat.first, "DID YOU DRINK ANY ALCOHOL?")
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testCustomsAppendAndBlanksDrop() {
        let cat = JournalCatalogStore.mergeCatalog(imported: [],
                                                   custom: ["  ", "Did you nap?", "did you NAP?"])
        XCTAssertEqual(Array(cat.prefix(JournalCatalogStore.starterQuestions.count)),
                       JournalCatalogStore.starterQuestions)
        XCTAssertEqual(cat.last, "Did you nap?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count + 1)
    }

    @MainActor
    func testImportedMagnesiumWithTrailingWhitespaceDoesNotDoublePrompt() {
        // #224: a WHOOP export leaves a trailing newline / non-breaking space on the cell, so the
        // imported "Did you take magnesium?\n" must fold onto the starter, NOT add a second row.
        let cat = JournalCatalogStore.mergeCatalog(
            imported: ["Did you take magnesium?\n", "Did you take  magnesium?"],
            custom: [])
        let magCount = cat.filter {
            $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .caseInsensitiveCompare("Did you take magnesium?") == .orderedSame
        }.count
        XCTAssertEqual(magCount, 1)
        // No net growth — both imported variants dedupe against the starter.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testHiddenQuestionsFilteredOutCaseInsensitively() {
        // Hide one starter (different casing) + one custom; both must drop from the merged catalog.
        let cat = JournalCatalogStore.mergeCatalog(
            imported: [],
            custom: ["Did you nap?"],
            hidden: ["did you drink any alcohol?", "DID YOU NAP?"])
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you drink any alcohol?") == .orderedSame })
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you nap?") == .orderedSame })
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count - 1)
    }
}
