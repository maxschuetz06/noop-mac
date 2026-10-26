import XCTest
@testable import NoopLocalAccessCore

final class MCPServerTests: XCTestCase {
    func testInitializeIncludesReadOnlyInstructionsForCodex() throws {
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: "/unused"))
        let response = try XCTUnwrap(try server.handle(RPCRequest(id: .int(1), method: "initialize", params: nil)))
        let result = try XCTUnwrap(response.objectValue?["result"]?.objectValue)

        XCTAssertEqual(result["protocolVersion"], .string(noopLocalAccessProtocolVersion))
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("read-only") == true)
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("do not diagnose") == true)
    }

    func testToolsAreAnnotatedReadOnly() throws {
        let tools = try XCTUnwrap(toolsList().objectValue?["tools"])
        guard case .array(let values) = tools else {
            return XCTFail("Expected tools array")
        }

        XCTAssertFalse(values.isEmpty)
        for tool in values {
            let annotations = try XCTUnwrap(tool.objectValue?["annotations"]?.objectValue)
            XCTAssertEqual(annotations["readOnlyHint"], .bool(true))
            XCTAssertEqual(annotations["openWorldHint"], .bool(false))
        }
    }

    func testMetricSeriesUsesComputedFallbackForMissingImportedDay() throws {
        let url = try TemporaryDatabase.seeded()
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: url.path))
        let response = try XCTUnwrap(try server.handle(RPCRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("metric_series"),
                "arguments": .object([
                    "key": .string("hrv"),
                    "from_day": .string("2026-06-10"),
                    "to_day": .string("2026-06-11"),
                ]),
            ])
        )))

        let structured = try XCTUnwrap(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["returned"], .int(2))
        guard case .array(let points) = structured["points"] else {
            return XCTFail("Expected points array")
        }
        XCTAssertEqual(points.compactMap { $0.objectValue?["source"]?.stringValue }, ["my-whoop", "my-whoop-noop"])
    }

    private func sleepSummary(_ url: URL) throws -> [String: JSONValue] {
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: url.path))
        let response = try XCTUnwrap(try server.handle(RPCRequest(
            id: .int(3),
            method: "tools/call",
            params: .object(["name": .string("sleep_summary"),
                             "arguments": .object(["days": .int(4000)])])
        )))
        return try XCTUnwrap(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
    }

    func testSleepSummaryExcludesNapsFromNightlyAggregatesAndListsThemSeparately() throws {
        let withNap = try sleepSummary(TemporaryDatabase.seededWithRecentNight(nap: true))
        let baseline = try sleepSummary(TemporaryDatabase.seededWithRecentNight(nap: false))

        // The nap (60 min) must not change the nightly count / average duration / efficiency.
        XCTAssertEqual(withNap["count"], .int(1))
        XCTAssertEqual(withNap["count"], baseline["count"])
        XCTAssertEqual(withNap["averageDurationMin"], baseline["averageDurationMin"])
        XCTAssertEqual(withNap["averageEfficiency"], baseline["averageEfficiency"])
        guard case .array(let sessions) = withNap["sessions"] else { return XCTFail("Expected sessions array") }
        XCTAssertEqual(sessions.compactMap { $0.objectValue?["isNap"] }, [.bool(false)])

        XCTAssertEqual(withNap["napCount"], .int(1))
        XCTAssertEqual(withNap["napTotalDurationMin"], .double(60))
        guard case .array(let naps) = withNap["naps"] else { return XCTFail("Expected naps array") }
        XCTAssertEqual(naps.count, 1)
        XCTAssertEqual(naps.compactMap { $0.objectValue?["isNap"] }, [.bool(true)])
    }

    func testSleepSummaryOnPreV19FileReportsNoNaps() throws {
        let summary = try sleepSummary(TemporaryDatabase.seededWithRecentNight(nap: false))
        XCTAssertEqual(summary["count"], .int(1))
        XCTAssertEqual(summary["napCount"], .int(0))
        XCTAssertEqual(summary["naps"], .array([]))
    }
}
