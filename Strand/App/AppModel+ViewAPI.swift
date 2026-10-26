import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - View-facing API
//
// Screens observe `AppModel` and read feature state through these forwarders to the services it owns.
// The services publish their own changes, which `AppModel.relayServiceChanges()` re-publishes here.

extension AppModel {
    // MARK: Data-source imports

    var hasActiveImport: Bool { imports.hasActiveImport }
    func isImporting(_ source: DataSourceImportKind) -> Bool { imports.isImporting(source) }
    func importFailed(_ source: DataSourceImportKind) -> Bool { imports.importFailed(source) }
    var whoopImportSummary: String? { imports.whoopImportSummary }
    var whoopImportFailed: Bool { imports.whoopImportFailed }
    var xiaomiImportSummary: String? { imports.xiaomiImportSummary }
    var xiaomiImportFailed: Bool { imports.xiaomiImportFailed }
    var appleHealthImportSummary: String? {
        get { imports.appleHealthImportSummary }
        set { imports.appleHealthImportSummary = newValue }
    }
    var appleHealthImportFailed: Bool {
        get { imports.appleHealthImportFailed }
        set { imports.appleHealthImportFailed = newValue }
    }
    func importWhoop(url: URL) { imports.importWhoop(url: url) }
    func importXiaomi(url: URL) { imports.importXiaomi(url: url) }
    func importAppleHealth(url: URL) { imports.importAppleHealth(url: url) }

    // MARK: Manual workouts

    typealias ActiveWorkout = ManualWorkoutController.ActiveWorkout
    var activeWorkout: ActiveWorkout? { workouts.activeWorkout }
    var lastWorkout: WorkoutRow? { workouts.lastWorkout }
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) { workouts.startWorkout(sport: sport) }
    func endWorkout() { workouts.endWorkout() }

    // MARK: Moments and strap inputs

    var moments: [Date] {
        get { marks.moments }
        set { marks.moments = newValue }
    }
    /// Record a "moment" (double-tap marker) with a confirming buzz.
    func markMoment() { marks.markMoment(at: Date()) }
    func runMacAction(_ kind: MacActionKind, shortcut: String) { strapInputs.runMacAction(kind, shortcut: shortcut) }

    // MARK: Health signals

    static let cycleAwarenessKey = HealthSignalEngines.cycleAwarenessKey
    var healthAlert: String? { healthSignals.healthAlert }
    var illnessSignal: IllnessSignalEngine.Result? { healthSignals.illnessSignal }
    var cyclePhase: CyclePhaseEngine.Result? { healthSignals.cyclePhase }
    var cycleCurve: [Double] { healthSignals.cycleCurve }
    var circadianPhase: CircadianEngine.PhaseEstimate? { healthSignals.circadianPhase }
    var cycleAwarenessEnabled: Bool {
        get { healthSignals.cycleAwarenessEnabled }
        set { healthSignals.cycleAwarenessEnabled = newValue }
    }
    func refreshV5Signals() async { await healthSignals.refreshV5Signals() }
    func reevaluateIllness() { healthSignals.reevaluateIllness() }

    // MARK: Storage and fused record

    typealias StorageReport = StorageDiagnostics.Report
    func storageReport() async -> StorageReport { await StorageDiagnostics.report(store: repo.storeHandle()) }
    @discardableResult
    func cleanUpStorage() async -> StorageReport { await StorageDiagnostics.cleanUp(store: repo.storeHandle()) }
    func buildTodayFusedRecord() async -> FusedRecord {
        await FusedRecordBuilder.today(store: repo.storeHandle(), whoopDeviceId: deviceId, appleDeviceId: appleDeviceId)
    }
}
