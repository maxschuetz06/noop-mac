import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the full on-device recompute (`RecomputePipeline.run`) on a deterministic 21-day dataset: every
/// persisted computed row, the scored By-Day results, the per-day diagnostics and the steps-calibration
/// state must stay byte-identical across refactors. The golden was captured from the pre-extraction
/// `IntelligenceEngine.analyzeRecent`.
final class RecomputeGoldenTests: XCTestCase {
    typealias F = RecomputeGoldenFixture

    /// No edited or dismissed sleep (the self-heal path is a no-op); records the strap-log lines.
    private actor RecordingHost: RecomputeHost {
        var lines: [String] = []
        func selfHealEditedStages(from: Int, to: Int) async -> [CachedSleepSession] { [] }
        func dismissedSleepWindows() async -> [(start: Int, end: Int)] { [] }
        func log(_ line: String) async { lines.append(line) }
    }

    func testTwentyOneDayRecomputeIsByteIdentical() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recompute-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("whoop.sqlite").path)
        try await F.populate(store)
        let host = RecordingHost()

        let outcome = await RecomputePipeline.run(F.request, store: store, host: host)

        var lines = outcome.days.map { r in
            "result \(r.day) rec=\(F.n(r.recovery)) strain=\(F.n(r.strain)) sleep=\(F.n(r.sleepMin)) "
                + "hrv=\(F.n(r.hrv)) rhr=\(F.n(r.rhr)) source=\(r.source.logToken)"
        }
        lines += await host.lines.map { "log \($0)" }
        let steps = try XCTUnwrap(outcome.stepsCalibration)
        lines.append("steps coeff=\(steps.coefficient) days=\(steps.sampleDays) "
                     + "conf=\(steps.confidence) manual=\(steps.manual)")
        lines += try await F.persistedFingerprint(store)
        XCTAssertEqual(lines.joined(separator: "\n"), Self.golden)
    }

    static let golden = """
    result 2024-03-20 rec=93.14389511137523 strain=0.0 sleep=467.5 hrv=53.05246694770379 rhr=46 source=computed
    result 2024-03-19 rec=49.60706627553377 strain=66.89 sleep=479.1666666666667 hrv=35.3779312110445 rhr=50 source=computed
    result 2024-03-18 rec=81.59975907075884 strain=0.0 sleep=477.0 hrv=47.36035141943025 rhr=51 source=computed
    result 2024-03-17 rec=56.11815044191691 strain=0.0 sleep=477.1666666666667 hrv=38.75345346678315 rhr=51 source=computed
    result 2024-03-16 rec=64.33450293927238 strain=67.1 sleep=478.0 hrv=38.73541399040505 rhr=48 source=computed
    result 2024-03-15 rec=53.18219840932168 strain=0.0 sleep=491.8333333333333 hrv=37.928299488085315 rhr=52 source=computed
    result 2024-03-14 rec=89.3302160596384 strain=0.0 sleep=457.6666666666667 hrv=47.82220191143651 rhr=46 source=imported:whoop
    result 2024-03-13 rec=44.054295496270996 strain=66.87 sleep=496.5 hrv=35.04934114082448 rhr=51 source=computed
    result 2024-03-12 rec=72.94018788700558 strain=0.0 sleep=485.5 hrv=44.446210913799 rhr=51 source=computed
    result 2024-03-11 rec=89.53944915915336 strain=0.0 sleep=472.3333333333333 hrv=52.98963983114372 rhr=51 source=imported:apple
    result 2024-03-10 rec=66.27705276660292 strain=67.24 sleep=462.5 hrv=39.219420059902085 rhr=48 source=computed
    result 2024-03-09 rec=64.57388845538868 strain=0.0 sleep=452.3333333333333 hrv=41.23205876785662 rhr=51 source=computed
    result 2024-03-08 rec=66.99848812097726 strain=0.0 sleep=472.1666666666667 hrv=38.16082551633494 rhr=47 source=computed
    result 2024-03-07 rec=78.9944777386333 strain=67.23 sleep=489.5 hrv=45.27574665751782 rhr=50 source=computed
    result 2024-03-06 rec=61.79684204382565 strain=0.0 sleep=463.3333333333333 hrv=38.720430392541246 rhr=49 source=computed
    result 2024-03-05 rec=72.49670575815749 strain=0.0 sleep=467.3333333333333 hrv=41.111743995180454 rhr=48 source=computed
    result 2024-03-04 rec=45.04266008256793 strain=66.72 sleep=459.6666666666667 hrv=36.93159586263174 rhr=52 source=computed
    result 2024-03-03 rec=56.396634369720836 strain=0.0 sleep=478.6666666666667 hrv=36.20871146474975 rhr=48 source=computed
    result 2024-03-02 rec=68.11953281090598 strain=0.0 sleep=481.8333333333333 hrv=39.57870886625286 rhr=49 source=computed
    result 2024-03-01 rec=76.51931422111582 strain=66.99 sleep=461.0 hrv=43.75694606183064 rhr=49 source=computed
    result 2024-02-29 rec=84.18670916629787 strain=0.0 sleep=491.0 hrv=50.36373067034905 rhr=52 source=computed
    log rhr day=2024-03-20 floor=46 nightMean=50 inBedSamples=2805 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-19 floor=50 nightMean=56 inBedSamples=3317 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-18 floor=51 nightMean=55 inBedSamples=3334 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-17 floor=51 nightMean=55 inBedSamples=3394 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-16 floor=48 nightMean=52 inBedSamples=3400 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-15 floor=52 nightMean=55 inBedSamples=3412 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-14 floor=46 nightMean=50 inBedSamples=2746 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-13 floor=51 nightMean=57 inBedSamples=3511 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-12 floor=51 nightMean=55 inBedSamples=3444 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-11 floor=51 nightMean=55 inBedSamples=3366 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-10 floor=48 nightMean=51 inBedSamples=2775 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-09 floor=51 nightMean=54 inBedSamples=3227 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-08 floor=47 nightMean=51 inBedSamples=2833 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-07 floor=50 nightMean=54 inBedSamples=3374 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-06 floor=49 nightMean=53 inBedSamples=3312 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-05 floor=48 nightMean=52 inBedSamples=3333 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-04 floor=52 nightMean=56 inBedSamples=3290 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-03 floor=48 nightMean=53 inBedSamples=3399 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-02 floor=49 nightMean=52 inBedSamples=3422 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-03-01 floor=49 nightMean=53 inBedSamples=3291 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log rhr day=2024-02-29 floor=52 nightMean=57 inBedSamples=3452 (floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)
    log sleep day=2024-03-20 totalSleepMin=468 matched=1 source=computed
    log sleep day=2024-03-19 totalSleepMin=479 matched=2 source=computed
    log sleep day=2024-03-18 totalSleepMin=477 matched=2 source=computed
    log sleep day=2024-03-17 totalSleepMin=477 matched=2 source=computed
    log sleep day=2024-03-16 totalSleepMin=478 matched=2 source=computed
    log sleep day=2024-03-15 totalSleepMin=492 matched=2 source=computed
    log sleep day=2024-03-14 totalSleepMin=458 matched=1 source=imported:whoop
    log sleep day=2024-03-13 totalSleepMin=497 matched=2 source=computed
    log sleep day=2024-03-12 totalSleepMin=486 matched=2 source=computed
    log sleep day=2024-03-11 totalSleepMin=472 matched=2 source=imported:apple
    log sleep day=2024-03-10 totalSleepMin=463 matched=1 source=computed
    log sleep day=2024-03-09 totalSleepMin=452 matched=2 source=computed
    log sleep day=2024-03-08 totalSleepMin=472 matched=1 source=computed
    log sleep day=2024-03-07 totalSleepMin=490 matched=2 source=computed
    log sleep day=2024-03-06 totalSleepMin=463 matched=2 source=computed
    log sleep day=2024-03-05 totalSleepMin=467 matched=2 source=computed
    log sleep day=2024-03-04 totalSleepMin=460 matched=2 source=computed
    log sleep day=2024-03-03 totalSleepMin=479 matched=2 source=computed
    log sleep day=2024-03-02 totalSleepMin=482 matched=2 source=computed
    log sleep day=2024-03-01 totalSleepMin=461 matched=2 source=computed
    log sleep day=2024-02-29 totalSleepMin=491 matched=2 source=computed
    steps coeff=8.10960200268797 days=8 conf=0.7101354487673892 manual=false
    daily 2024-02-29 tsm=491.0 eff=1.0 deep=81.0 rem=21.5 light=388.5 dist=0 rhr=52 hrv=50.36373067034905 rec=84.18670916629787 strain=0.0 ex=0 spo2=nil skin=0.06 resp=13.725490196078432 steps=24372 kcal=140.5300335648139
    daily 2024-03-01 tsm=461.0 eff=1.0 deep=73.0 rem=43.0 light=345.0 dist=0 rhr=49 hrv=43.75694606183064 rec=76.51931422111582 strain=66.99 ex=1 spo2=nil skin=0.01 resp=13.333333333333334 steps=38814 kcal=323.17826298218404
    daily 2024-03-02 tsm=481.8333333333333 eff=1.0 deep=98.0 rem=72.5 light=311.3333333333333 dist=0 rhr=49 hrv=39.57870886625286 rec=68.11953281090598 strain=0.0 ex=0 spo2=nil skin=-0.04 resp=13.067804646752016 steps=24811 kcal=142.55550358796305
    daily 2024-03-03 tsm=478.6666666666667 eff=1.0 deep=79.5 rem=37.5 light=361.6666666666667 dist=0 rhr=48 hrv=36.20871146474975 rec=56.396634369720836 strain=0.0 ex=0 spo2=nil skin=0.1 resp=13.832442067736185 steps=24894 kcal=141.2191109953698
    daily 2024-03-04 tsm=459.6666666666667 eff=1.0 deep=63.5 rem=44.0 light=352.1666666666667 dist=0 rhr=52 hrv=36.93159586263174 rec=45.04266008256793 strain=66.72 ex=1 spo2=nil skin=-0.02 resp=13.725490196078432 steps=38346 kcal=324.8684485858483
    daily 2024-03-05 tsm=467.3333333333333 eff=1.0 deep=77.5 rem=55.5 light=334.3333333333333 dist=0 rhr=48 hrv=41.111743995180454 rec=72.49670575815749 strain=0.0 ex=0 spo2=nil skin=0.15 resp=13.529411764705884 steps=25266 kcal=140.13329201388777
    daily 2024-03-06 tsm=463.3333333333333 eff=1.0 deep=71.0 rem=59.0 light=333.3333333333333 dist=0 rhr=49 hrv=38.720430392541246 rec=61.79684204382565 strain=0.0 ex=0 spo2=nil skin=0.02 resp=13.725490196078432 steps=24688 kcal=140.92677511574
    daily 2024-03-07 tsm=489.5 eff=1.0 deep=72.0 rem=54.0 light=363.5 dist=0 rhr=50 hrv=45.27574665751782 rec=78.9944777386333 strain=67.23 ex=1 spo2=nil skin=-0.06 resp=13.157894736842106 steps=37868 kcal=323.70089205391366
    daily 2024-03-08 tsm=472.1666666666667 eff=1.0 deep=92.5 rem=34.5 light=345.1666666666667 dist=0 rhr=47 hrv=38.16082551633494 rec=66.99848812097726 strain=0.0 ex=0 spo2=nil skin=0.08 resp=13.333333333333334 steps=24448 kcal=139.50685798610968
    daily 2024-03-09 tsm=452.3333333333333 eff=1.0 deep=78.5 rem=49.5 light=324.3333333333333 dist=0 rhr=51 hrv=41.23205876785662 rec=64.57388845538868 strain=0.0 ex=0 spo2=nil skin=0.24 resp=13.157894736842106 steps=24970 kcal=139.54862025462822
    daily 2024-03-10 tsm=462.5 eff=1.0 deep=72.5 rem=36.5 light=353.5 dist=0 rhr=48 hrv=39.219420059902085 rec=66.27705276660292 strain=67.24 ex=1 spo2=nil skin=0.0 resp=13.333333333333334 steps=38286 kcal=324.26264514770895
    daily 2024-03-11 tsm=472.3333333333333 eff=1.0 deep=66.0 rem=33.5 light=372.8333333333333 dist=0 rhr=51 hrv=52.98963983114372 rec=89.53944915915336 strain=0.0 ex=0 spo2=nil skin=0.03 resp=13.725490196078432 steps=25271 kcal=142.0334752314813
    daily 2024-03-12 tsm=485.5 eff=1.0 deep=84.5 rem=31.5 light=369.5 dist=0 rhr=51 hrv=44.446210913799 rec=72.94018788700558 strain=0.0 ex=0 spo2=nil skin=0.02 resp=13.946078431372548 steps=24754 kcal=141.40704120370322
    daily 2024-03-13 tsm=496.5 eff=1.0 deep=86.5 rem=56.5 light=353.5 dist=0 rhr=51 hrv=35.04934114082448 rec=44.054295496270996 strain=66.87 ex=1 spo2=nil skin=-0.1 resp=13.725490196078432 steps=37306 kcal=325.5339867435579
    daily 2024-03-14 tsm=457.6666666666667 eff=1.0 deep=68.5 rem=49.5 light=339.6666666666667 dist=0 rhr=46 hrv=47.82220191143651 rec=89.3302160596384 strain=0.0 ex=0 spo2=nil skin=-0.03 resp=13.333333333333334 steps=25443 kcal=141.05206192129563
    daily 2024-03-15 tsm=491.8333333333333 eff=1.0 deep=93.0 rem=51.5 light=347.3333333333333 dist=0 rhr=52 hrv=37.928299488085315 rec=53.18219840932168 strain=0.0 ex=0 spo2=nil skin=-0.14 resp=12.727272727272727 steps=24597 kcal=139.6321447916653
    daily 2024-03-16 tsm=478.0 eff=1.0 deep=80.0 rem=23.5 light=374.5 dist=0 rhr=48 hrv=38.73541399040505 rec=64.33450293927238 strain=67.1 ex=1 spo2=nil skin=0.09 resp=13.725490196078432 steps=37901 kcal=325.0126590706766
    daily 2024-03-17 tsm=477.1666666666667 eff=1.0 deep=62.5 rem=64.5 light=350.1666666666667 dist=0 rhr=51 hrv=38.75345346678315 rec=56.11815044191691 strain=0.0 ex=0 spo2=nil skin=-0.2 resp=13.725490196078432 steps=25103 kcal=141.59497141203664
    daily 2024-03-18 tsm=477.0 eff=1.0 deep=74.5 rem=58.0 light=344.5 dist=0 rhr=51 hrv=47.36035141943025 rec=81.59975907075884 strain=0.0 ex=0 spo2=nil skin=-0.21 resp=13.196078431372548 steps=24980 kcal=139.23540324073917
    daily 2024-03-19 tsm=479.1666666666667 eff=1.0 deep=92.0 rem=44.5 light=342.6666666666667 dist=0 rhr=50 hrv=35.3779312110445 rec=49.60706627553377 strain=66.89 ex=1 spo2=nil skin=-0.1 resp=13.157894736842106 steps=37630 kcal=321.93947275729863
    daily 2024-03-20 tsm=467.5 eff=1.0 deep=89.5 rem=23.0 light=355.0 dist=0 rhr=46 hrv=53.05246694770379 rec=93.14389511137523 strain=0.0 ex=0 spo2=nil skin=0.08 resp=15.897435897435898 steps=14597 kcal=96.7214138888875
    series sleep_performance 2024-02-29 83.35
    series sleep_performance 2024-03-01 83.09
    series sleep_performance 2024-03-02 89.15
    series sleep_performance 2024-03-03 84.64
    series sleep_performance 2024-03-04 82.24
    series sleep_performance 2024-03-05 85.06
    series sleep_performance 2024-03-06 84.49
    series sleep_performance 2024-03-07 85.3
    series sleep_performance 2024-03-08 84.94
    series sleep_performance 2024-03-09 83.44
    series sleep_performance 2024-03-10 82.6
    series sleep_performance 2024-03-11 82.63
    series sleep_performance 2024-03-12 84.56
    series sleep_performance 2024-03-13 86.52
    series sleep_performance 2024-03-14 82.99
    series sleep_performance 2024-03-15 86.75
    series sleep_performance 2024-03-16 83.45
    series sleep_performance 2024-03-17 85.35
    series sleep_performance 2024-03-18 85.8
    series sleep_performance 2024-03-19 86.31
    series sleep_performance 2024-03-20 83.32
    series skin_temp_abs 2024-02-29 33.56
    series skin_temp_abs 2024-03-01 33.51
    series skin_temp_abs 2024-03-02 33.46
    series skin_temp_abs 2024-03-03 33.59
    series skin_temp_abs 2024-03-04 33.48
    series skin_temp_abs 2024-03-05 33.65
    series skin_temp_abs 2024-03-06 33.52
    series skin_temp_abs 2024-03-07 33.44
    series skin_temp_abs 2024-03-08 33.58
    series skin_temp_abs 2024-03-09 33.74
    series skin_temp_abs 2024-03-10 33.5
    series skin_temp_abs 2024-03-11 33.53
    series skin_temp_abs 2024-03-12 33.52
    series skin_temp_abs 2024-03-13 33.39
    series skin_temp_abs 2024-03-14 33.47
    series skin_temp_abs 2024-03-15 33.35
    series skin_temp_abs 2024-03-16 33.59
    series skin_temp_abs 2024-03-17 33.3
    series skin_temp_abs 2024-03-18 33.28
    series skin_temp_abs 2024-03-19 33.4
    series skin_temp_abs 2024-03-20 33.58
    series fitness_age 2024-03-16 28.25778490990991
    series vo2max_est 2024-03-16 51.96469566666666
    series vitality 2024-03-16 61.164252984658056
    series body_age 2024-03-16 29.53429880613678
    series steps_est 2024-02-29 1453.0
    series steps_est 2024-03-01 7445.0
    series steps_est 2024-03-02 1514.0
    series steps_est 2024-03-03 1494.0
    series steps_est 2024-03-04 7638.0
    series steps_est 2024-03-05 1534.0
    series steps_est 2024-03-06 1521.0
    series steps_est 2024-03-07 7543.0
    series steps_est 2024-03-08 1459.0
    series steps_est 2024-03-09 1488.0
    series steps_est 2024-03-10 7610.0
    series steps_est 2024-03-11 1521.0
    series steps_est 2024-03-20 887.0
    sleep 1709155879-1709185339 eff=1.0 rhr=54 hrv=51.62413435371695 stages=86173622a61a689c
    sleep 1709242533-1709247593 eff=1.0 rhr=52 hrv=43.02549104346801 stages=a64851f556e1ed09
    sleep 1709328747-1709333997 eff=1.0 rhr=52 hrv=36.46223454254557 stages=ebe83f945b4bac33
    sleep 1709415081-1709420391 eff=1.0 rhr=52 hrv=34.06286615041157 stages=7f6d75fcfce7ffe1
    sleep 1709501522-1709506792 eff=1.0 rhr=57 hrv=35.46712700025565 stages=b0a755810fc8d53c
    sleep 1709587875-1709593195 eff=1.0 rhr=52 hrv=38.873832441433905 stages=a2322fda9ca76770
    sleep 1709674305-1709679595 eff=1.0 rhr=53 hrv=37.49862162706054 stages=8c0620b869a52d34
    sleep 1709760675-1709765995 eff=1.0 rhr=55 hrv=46.24524248769134 stages=6a6246a0108699a
    sleep 1709848025-1709852395 eff=1.0 rhr=51 hrv=35.57719037765847 stages=474a0edb35a19c4b
    sleep 1709934160-1709961300 eff=1.0 rhr=51 hrv=42.1126571706254 stages=14ae870197fca710
    sleep 1710020063-1710025193 eff=1.0 rhr=51 hrv=36.573298407009716 stages=60466e2b9ed27747
    sleep 1710106280-1710134620 eff=1.0 rhr=51 hrv=53.77091983510887 stages=a852e0324fc580c9
    sleep 1710192674-1710197994 eff=1.0 rhr=56 hrv=48.82770838144966 stages=6978efc70c4f363
    sleep 1710279083-1710284393 eff=1.0 rhr=58 hrv=32.31715156295927 stages=33170b5b5a8b9d5c
    sleep 1710365477-1710370797 eff=1.0 rhr=51 hrv=48.05810962621243 stages=bbc829bce80212a3
    sleep 1710451880-1710481390 eff=1.0 rhr=52 hrv=38.152281455780255 stages=ca9d797543fd513a
    sleep 1710538983-1710543593 eff=1.0 rhr=52 hrv=36.49452337817689 stages=4a745e567d0beeb
    sleep 1710624679-1710629999 eff=1.0 rhr=56 hrv=38.074647710842974 stages=989f45229812607b
    sleep 1710711087-1710716397 eff=1.0 rhr=56 hrv=47.11426646725203 stages=bafbd655fb2460d1
    sleep 1710798071-1710802791 eff=1.0 rhr=56 hrv=31.83077557914069 stages=82003869bbb45df7
    sleep 1710884777-1710889197 eff=1.0 rhr=50 hrv=53.20003504411487 stages=3da7419e2679c4e7
    workout my-whoop-noop 1709308802-1709311802 detected my-whoop-noop dur=3000.0 kcal=750.0750159334943 hr=151/165 strain=56.71
    workout my-whoop-noop 1709568006-1709571002 detected my-whoop-noop dur=2996.0 kcal=747.7315838111233 hr=151/165 strain=56.45
    workout my-whoop-noop 1709827203-1709830203 detected my-whoop-noop dur=3000.0 kcal=755.4229891648511 hr=151/165 strain=56.96
    workout my-whoop-noop 1710086402-1710089402 detected my-whoop-noop dur=3000.0 kcal=752.7434954588911 hr=151/165 strain=56.97
    workout my-whoop-noop 1710864006-1710867002 detected my-whoop-noop dur=2996.0 kcal=748.0432138302446 hr=151/165 strain=56.62
    workout my-whoop 1710345600-1710348600 Cycling manual dur=3000.0 kcal=748.2665547323134 hr=151/165 strain=56.07
    workout my-whoop 1710604800-1710607800 Running whoop dur=3000.0 kcal=520.0 hr=150/166 strain=60.0
    """
}
