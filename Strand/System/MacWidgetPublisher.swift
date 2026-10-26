import Combine
import Foundation
import WidgetKit

/// Publishes the glance snapshot for the macOS desktop widget into the shared App Group.
/// Score changes (new day rows, completed sync, bond state) publish immediately; live heart rate
/// and battery only ride along at most every five minutes to stay within WidgetKit's reload budget.
@MainActor
final class MacWidgetPublisher {
    static let shared = MacWidgetPublisher()

    private var cancellables = Set<AnyCancellable>()
    private weak var model: AppModel?
    private var lastReload = Date.distantPast
    private var publishing = false
    private let liveReloadInterval: TimeInterval = 300

    private init() {}

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model

        model.repo.$days
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        model.live.$lastSyncedAt
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        model.live.$bonded
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &cancellables)

        Publishers.Merge(
            model.live.$heartRate.map { _ in () },
            model.live.$batteryPct.map { _ in () }
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
        guard let model else { return }
        // Most recent scored day anchors every derived field, matching the iOS widget.
        let day = model.repo.days.last(where: { $0.recovery != nil })
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            restScore = restByDay[day.day] ?? restSeries.last?.value
        }
        let now = Date()
        let snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: now,
            effort: day?.strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr,
            lastSync: model.live.lastSyncedAt.map { Date(timeIntervalSince1970: $0) }
        )
        snap.save()
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}
