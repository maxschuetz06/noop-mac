import Combine
import Foundation
import WhoopStore
import WidgetKit

/// Publishes the glance snapshot for the macOS desktop widget into the shared App Group.
/// Score changes (new day rows, completed sync, bond state) publish immediately; live heart rate
/// and battery only ride along at most every five minutes to stay within WidgetKit's reload budget.
@MainActor
final class MacWidgetPublisher {
    static let shared = MacWidgetPublisher()

    private var cancellables = Set<AnyCancellable>()
    private weak var repo: Repository?
    private weak var live: LiveState?
    private var smoothedBpm: () -> Int? = { nil }
    private(set) var isStarted = false
    private var lastReload = Date.distantPast
    private var publishing = false
    private let liveReloadInterval: TimeInterval = 300

    private init() {}

    /// Idempotent. `smoothedBpm` is the app's display-ready live heart rate (preferred over the raw value).
    func start(repo: Repository, live: LiveState, smoothedBpm: @escaping () -> Int?) {
        guard !isStarted else { return }
        isStarted = true
        self.repo = repo
        self.live = live
        self.smoothedBpm = smoothedBpm

        repo.$days
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        live.$lastSyncedAt
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        live.$bonded
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        Publishers.Merge(
            live.$heartRate.map { _ in () },
            live.$batteryPct.map { _ in () }
        )
        .throttle(for: .seconds(60), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in self?.schedule(force: false) }
        .store(in: &cancellables)
    }

    private func schedule(force: Bool) {
        if !force && Date().timeIntervalSince(lastReload) < liveReloadInterval { return }
        guard !publishing else { return }
        publishing = true
        Task { [weak self] in
            await self?.publish()
            self?.publishing = false
        }
    }

    private func publish() async {
        guard let repo, let live else { return }
        // Most recent scored day anchors every derived field, matching the iOS widget.
        let day = repo.days.last(where: { $0.recovery != nil })
        var restScore: Double?
        if let day {
            let restSeries = await repo.exploreSeries(key: "sleep_performance", source: SourceID.whoop)
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            restScore = restByDay[day.day] ?? restSeries.last?.value
        }
        let now = Date()
        var snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: smoothedBpm() ?? live.heartRate,
            batteryPct: live.batteryPct.map { Int($0.rounded()) },
            bonded: live.bonded,
            updated: now)
        snap.effort = day?.strain.map { Int($0.rounded()) }
        snap.rest = restScore.map { Int($0.rounded()) }
        snap.hrv = day?.avgHrv.map { Int($0.rounded()) }
        snap.restingHr = day?.restingHr
        snap.lastSync = live.lastSyncedAt.map { Date(timeIntervalSince1970: $0) }
        snap.localeIdentifier = AppLanguage.current().pinnedLocale?.identifier
        snap.save()
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}
