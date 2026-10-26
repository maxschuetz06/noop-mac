import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// `Repository.liveStrain` is the one in-progress Effort calculation Home and Day Details share. It must
/// score the stored HR window with the daily pass's parameters: Tanaka HRmax from a known age, the day's
/// resting HR (else the scorer default) and the profile sex.
@MainActor
final class RepositoryLiveStrainTests: XCTestCase {
    private let base = 1_780_000_000

    private func repository(samples: [HRSample]) async throws -> Repository {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        try await store.insert(Streams(hr: samples), deviceId: "my-whoop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return repo
    }

    private func workout(count: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: base + $0, bpm: 90 + ($0 % 60)) }
    }

    func testUsesAgeRestingHrAndSex() async throws {
        let samples = workout(count: 1_200)
        let repo = try await repository(samples: samples)
        let live = await repo.liveStrain(from: base, to: base + 1_200, restingHr: 52, age: 34, sex: "female")
        let expected = StrainScorer.strain(samples, maxHR: StrainScorer.tanakaHRmax(age: 34), restingHR: 52, sex: "female")
        XCTAssertNotNil(live)
        XCTAssertEqual(live, expected)
    }

    func testFallsBackToScorerDefaultsWithoutAgeOrRestingHr() async throws {
        let samples = workout(count: 1_200)
        let repo = try await repository(samples: samples)
        let live = await repo.liveStrain(from: base, to: base + 1_200, restingHr: nil, age: 0, sex: "male")
        let expected = StrainScorer.strain(samples, maxHR: nil, restingHR: StrainScorer.defaultRestingHR, sex: "male")
        XCTAssertEqual(live, expected)
    }

    func testIsNilBelowMinimumReadings() async throws {
        let repo = try await repository(samples: workout(count: 20))
        let live = await repo.liveStrain(from: base, to: base + 20, restingHr: 55, age: 30, sex: "male")
        XCTAssertNil(live)
    }
}
