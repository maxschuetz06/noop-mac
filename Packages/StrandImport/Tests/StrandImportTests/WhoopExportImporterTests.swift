import XCTest
@testable import StrandImport

final class WhoopExportImporterTests: XCTestCase {

    // MARK: - Header normalization

    func testHeaderNormalization() {
        XCTAssertEqual(HeaderNorm.normalize("Heart rate variability (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Recovery score %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("In bed duration (min)"), "in_bed_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("  Cycle start time  "), "cycle_start_time")
        XCTAssertEqual(HeaderNorm.normalize("HR Zone 1 %"), "hr_zone_1_pct")
    }

    // MARK: - BOM stripping

    func testBOMIsStripped() {
        let raw = Fixtures.data("physiological_cycles.csv")
        // Confirm the fixture actually carries a UTF-8 BOM.
        XCTAssertGreaterThanOrEqual(raw.count, 3)
        XCTAssertEqual(Array(raw.prefix(3)), [0xEF, 0xBB, 0xBF])

        let table = CSVTable(data: raw)
        // After stripping, the first header must normalize to cycle_start_time,
        // not "\u{FEFF}cycle_start_time".
        XCTAssertTrue(table.normalizedHeaders.contains("cycle_start_time"))
        XCTAssertFalse(table.normalizedHeaders.first?.contains("\u{FEFF}") ?? false)
    }

    // MARK: - Timezone parsing

    func testTimezoneOffsetParsing() {
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+01:00"), 60)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC-05:00"), -300)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("+02:30"), 150)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("Z"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes(nil), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+0530"), 330)
    }

    func testTimestampParsedInGivenOffsetToUTC() {
        // 06:30 at UTC+01:00 == 05:30 UTC.
        let d = WhoopTime.parse("2024-01-02 06:30:00", offsetMinutes: 60)
        XCTAssertEqual(d, Fixtures.utc(2024, 1, 2, 5, 30, 0))

        // 00:05 at UTC-05:00 == 05:05 UTC.
        let d2 = WhoopTime.parse("2024-01-03 00:05:00", offsetMinutes: -300)
        XCTAssertEqual(d2, Fixtures.utc(2024, 1, 3, 5, 5, 0))
    }

    // MARK: - physiological_cycles.csv

    func testCyclesParseToExpectedValues() throws {
        let table = CSVTable(data: Fixtures.data("physiological_cycles.csv"))
        let rows = WhoopExportImporter().parseCycles(table)

        XCTAssertEqual(rows.count, 2)
        let r0 = rows[0]

        // Cycle start: 2024-01-02 06:30:00 at UTC+01:00 -> 05:30 UTC.
        XCTAssertEqual(r0.cycleStart, Fixtures.utc(2024, 1, 2, 5, 30, 0))
        XCTAssertEqual(r0.tzOffsetMin, 60)
        XCTAssertEqual(r0.recoveryScore, 72)
        XCTAssertEqual(r0.restingHeartRate, 52)
        XCTAssertEqual(r0.hrvMs, 68.4)
        XCTAssertEqual(r0.skinTempCelsius, 33.1)
        XCTAssertEqual(r0.bloodOxygenPct, 96.0)
        XCTAssertEqual(r0.dayStrain, 12.5)
        XCTAssertEqual(r0.energyKcal, 2450)        // "(cal)" treated as kcal, not converted
        XCTAssertEqual(r0.maxHeartRate, 165)
        XCTAssertEqual(r0.avgHeartRate, 68)
        XCTAssertEqual(r0.sleepPerformancePct, 85)
        XCTAssertEqual(r0.respiratoryRate, 14.2)
        XCTAssertEqual(r0.asleepDurationMin, 420)   // kept in minutes
        XCTAssertEqual(r0.inBedDurationMin, 455)
        XCTAssertEqual(r0.lightSleepDurationMin, 210)
        XCTAssertEqual(r0.deepSleepDurationMin, 95)
        XCTAssertEqual(r0.remDurationMin, 115)
        XCTAssertEqual(r0.awakeDurationMin, 35)
        XCTAssertEqual(r0.sleepEfficiencyPct, 92.3)
        XCTAssertEqual(r0.sleepConsistencyPct, 88.0)
        XCTAssertEqual(r0.sleepNeedMin, 480)
        XCTAssertEqual(r0.sleepDebtMin, 60)

        // Sleep onset 2024-01-01 23:15 at +01:00 -> 22:15 UTC.
        XCTAssertEqual(r0.sleepOnset, Fixtures.utc(2024, 1, 1, 22, 15, 0))

        // Second row uses a negative offset.
        let r1 = rows[1]
        XCTAssertEqual(r1.tzOffsetMin, -300)
        XCTAssertEqual(r1.cycleStart, Fixtures.utc(2024, 1, 3, 11, 29, 0)) // 06:29 -05:00
        XCTAssertEqual(r1.recoveryScore, 55)
    }

    // MARK: - workouts.csv WITHOUT GPS columns

    func testWorkoutsWithoutGPSColumnsStillParse() throws {
        let table = CSVTable(data: Fixtures.data("workouts.csv"))
        let rows = WhoopExportImporter().parseWorkouts(table)

        XCTAssertEqual(rows.count, 2)
        let w0 = rows[0]
        XCTAssertEqual(w0.activityName, "Running")
        XCTAssertEqual(w0.activityStrain, 11.2)
        XCTAssertEqual(w0.energyKcal, 540)
        XCTAssertEqual(w0.maxHeartRate, 182)
        XCTAssertEqual(w0.avgHeartRate, 158)
        XCTAssertEqual(w0.hrZone3Pct, 40.0)
        XCTAssertEqual(w0.workoutStart, Fixtures.utc(2024, 1, 2, 17, 0, 0)) // +00:00

        // GPS / distance / altitude columns are absent → nil, not an error.
        XCTAssertNil(w0.distanceMeters)
        XCTAssertNil(w0.altitudeGainMeters)
        XCTAssertNil(w0.altitudeChangeMeters)
    }

    // MARK: - workouts.csv WITH GPS columns (synthetic, in-memory)

    func testWorkoutsWithGPSColumnsParse() throws {
        let csv = """
        Workout start time,Cycle timezone,Activity name,Distance (meters),Altitude gain (meters),Altitude change (meters)
        2024-02-01 09:00:00,UTC+00:00,Cycling,15230.5,210.0,-5.0
        """
        let rows = WhoopExportImporter().parseWorkouts(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activityName, "Cycling")
        XCTAssertEqual(rows[0].distanceMeters, 15230.5)
        XCTAssertEqual(rows[0].altitudeGainMeters, 210.0)
        XCTAssertEqual(rows[0].altitudeChangeMeters, -5.0)
    }

    // MARK: - sleeps.csv with Nap column

    func testSleepsNapColumn() throws {
        let table = CSVTable(data: Fixtures.data("sleeps.csv"))
        let rows = WhoopExportImporter().parseSleeps(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].isNap, false)
        XCTAssertEqual(rows[1].isNap, true)
        XCTAssertEqual(rows[0].sleepPerformancePct, 85)
        // Nap row has blank optional cells -> nil, not crash.
        XCTAssertNil(rows[1].sleepPerformancePct)
        XCTAssertEqual(rows[1].asleepDurationMin, 25)
    }

    // MARK: - journal_entries.csv

    func testJournalPivot() throws {
        let table = CSVTable(data: Fixtures.data("journal_entries.csv"))
        let rows = WhoopExportImporter().parseJournal(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Did you drink any alcohol?")
        XCTAssertEqual(rows[0].answer, "false")
        XCTAssertNil(rows[0].notes)
        XCTAssertEqual(rows[1].question, "Did you have any caffeine?")
        XCTAssertEqual(rows[1].answer, "true")
        XCTAssertEqual(rows[1].notes, "One coffee in the morning")
    }

    // MARK: - Folder import end to end

    func testImportFromFolder() throws {
        // The Resources directory itself is a folder containing all the CSVs.
        let folder = Fixtures.url("physiological_cycles.csv").deletingLastPathComponent()
        let result = try WhoopExportImporter().import(from: folder)

        XCTAssertEqual(result.cycles.count, 2)
        XCTAssertEqual(result.sleeps.count, 2)
        XCTAssertEqual(result.workouts.count, 2)
        XCTAssertEqual(result.journal.count, 2)

        XCTAssertEqual(result.summary.sourceKind, .whoopExport)
        XCTAssertEqual(result.summary.recordCount, 8)
        XCTAssertEqual(result.summary.countsByCategory["cycles"], 2)
        XCTAssertEqual(result.summary.countsByCategory["workouts"], 2)
        XCTAssertNotNil(result.summary.earliest)
        XCTAssertNotNil(result.summary.latest)
        XCTAssertLessThanOrEqual(result.summary.earliest!, result.summary.latest!)
    }

    // MARK: - Robustness: extra/unknown columns, reordered headers

    func testExtraAndReorderedColumnsTolerated() throws {
        let csv = """
        Some Future Column,Cycle timezone,Recovery score %,Cycle start time,Another Unknown
        hello,UTC+00:00,80,2024-03-01 06:00:00,world
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - CSV quoting

    func testQuotedFieldsWithCommasAndQuotes() {
        let csv = "a,b,c\n\"hello, world\",\"she said \"\"hi\"\"\",plain\n"
        let table = CSVTable(text: csv)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0]["a"], "hello, world")
        XCTAssertEqual(table.rows[0]["b"], "she said \"hi\"")
        XCTAssertEqual(table.rows[0]["c"], "plain")
    }

    // MARK: - Localized (German) column headers — issue #3

    func testGermanHeaderNormalizationAliases() {
        // Diacritic-folded German headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Erholungswert %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Ruheherzfrequenz (Schläge pro Minute)"), "resting_heart_rate_bpm")
        XCTAssertEqual(HeaderNorm.normalize("Herzfrequenzvariabilität (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Schlafbeständigkeit %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Name der Aktivität"), "activity_name")
        XCTAssertEqual(HeaderNorm.normalize("HF-Zone 3 %"), "hr_zone_3_pct")
        // English headers are unaffected by the folding + alias.
        XCTAssertEqual(HeaderNorm.normalize("Recovery score %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Cycle start time"), "cycle_start_time")
    }

    func testGermanCyclesValuesParse() throws {
        // A real German physiologische_zyklen.csv header row + one data row: values must come through.
        let csv = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Erholungswert %,Ruheherzfrequenz (Schläge pro Minute),Herzfrequenzvariabilität (ms),Tagesbelastung,Durchschnittliche HF (Schläge pro Minute)
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,12.5,61
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - Localized (Spanish) column headers — issue #76

    func testSpanishHeaderNormalizationAliases() {
        // Diacritic-folded Spanish headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Puntuación de recuperación (%)"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Frecuencia cardíaca en reposo (lpm)"), "resting_heart_rate_bpm")
        XCTAssertEqual(HeaderNorm.normalize("Variabilidad de la frecuencia cardíaca (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Temp. cutánea (grados centígrados)"), "skin_temp_celsius")
        XCTAssertEqual(HeaderNorm.normalize("Tempo despierto/a (min)"), "awake_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("Regularidad del sueño %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Siesta"), "nap")
    }

    func testSpanishCyclesValuesParse() throws {
        // The EXACT physiological_cycles.csv header from a real Spanish export (issue #76) + one data row.
        let csv = """
        Hora de inicio del ciclo,Hora de finalización del ciclo,Zona horaria del ciclo,Puntuación de recuperación (%),Frecuencia cardíaca en reposo (lpm),Variabilidad de la frecuencia cardíaca (ms),Temp. cutánea (grados centígrados),Oxígeno en sangre %,Esfuerzo del día,Energía quemada (cal),FC máx. (lpm),FC promedio (lpm),Inicio del sueño,Inicio de la vigilia,Calificación del sueño (%),Frecuencia respiratoria (rpm),Duración del sueño (min),Tiempo en la cama (min),Duración de sueño ligero (min),Duración de sueño profundo (SWS) (min),Duración de sueño REM (min),Tempo despierto/a (min),Sueño necesario (min),Deuda de sueño (min),Eficiencia del sueño %,Regularidad del sueño %
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - Localized (French) column headers — issue #79

    func testFrenchHeaderNormalizationAliases() {
        // Diacritic-folded French headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Score de récupération %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Variabilité de la fréquence cardiaque (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Durée du sommeil paradoxal (min)"), "rem_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("Régularité du sommeil %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Sieste"), "nap")
        // The apostrophe folds to "_" — BOTH the straight (') and the curly (’) variant must map.
        XCTAssertEqual(HeaderNorm.normalize("Niveau d'oxygène %"), "blood_oxygen_pct")
        XCTAssertEqual(HeaderNorm.normalize("Niveau d’oxygène %"), "blood_oxygen_pct")
        XCTAssertEqual(HeaderNorm.normalize("Temps d'éveil (min)"), "awake_duration_min")
        // The workout zone headers carry a NON-BREAKING SPACE before % — it folds to "_" too.
        XCTAssertEqual(HeaderNorm.normalize("Zone FC 1\u{00A0}%"), "hr_zone_1_pct")
        XCTAssertEqual(HeaderNorm.normalize("Nom de l'activité"), "activity_name")
    }

    func testFrenchCyclesValuesParse() throws {
        // The EXACT physiological_cycles.csv header from a real French export (issue #79) + one data row.
        let csv = """
        Heure de début du cycle,Heure de fin du cycle,Fuseau horaire du cycle,Score de récupération %,Fréquence cardiaque au repos (bpm),Variabilité de la fréquence cardiaque (ms),Température cutanée (Celsius),Niveau d'oxygène %,Effort du jour,Dépense énergétique (cal.),FC max. (bpm),FC moyenne (bpm),Premiers signes de sommeil,Premiers signes de réveil,Performance Sommeil %,Fréquence respiratoire (tr/min),Durée du sommeil (min),Temps passé au lit (min),Durée du sommeil léger (min),Durée du sommeil profond (min),Durée du sommeil paradoxal (min),Temps d'éveil (min),Besoins en sommeil (min),Dette de sommeil (min),Efficacité du sommeil %,Régularité du sommeil %
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - German export (real header rows + synthetic data rows)

    /// A complete German WHOOP export: the EXACT header rows of the four German CSVs
    /// (physiologische_zyklen / Schlaf / Trainings / logbuch_eintraege) with 2–3 synthetic rows each — no
    /// real health data. Every value the WHOOP app shows must survive the import.
    func testGermanExportImportsEveryValue() throws {
        let cycles = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Erholungswert %,Ruheherzfrequenz (Schläge pro Minute),Herzfrequenzvariabilität (ms),Hauttemperatur (Celsius),Blutsauerstoff %,Tagesbelastung,Verbrannte Energie (cal),Max HF (Schläge pro Minute),Durchschnittliche HF (Schläge pro Minute),Beginn des Schlafs,Beginn des Aufwachens,Schlafleistung %,Atemfrequenz (Atemzüge/Min.),Schlafdauer (Min.),Dauer im Bett (Min.),Dauer des Leichtschlafs (Min.),Dauer des Tiefschlafs (Min.),Dauer des REM-Schlafs (Min.),Dauer des Aufwachens (Min.),Schlafbedarf (Min.),Schlafdefizit (Min.),Schlafeffizienz %,Schlafbeständigkeit %
        2024-03-03 23:00:00,,UTC+02:00,60,50,70,33.50,95.00,,,,,2024-03-03 23:00:00,2024-03-04 07:00:00,85,15.0,420,450,200,100,120,30,480,60,93,80
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,70,52,65,34.00,97.00,10.0,2200,160,70,2024-03-02 23:00:00,2024-03-03 07:00:00,90,15.5,440,480,220,100,120,40,500,60,92,75
        2024-03-01 23:00:00,2024-03-02 23:00:00,UTC+02:00,80,55,60,33.80,96.00,6.0,2000,140,65,2024-03-01 23:00:00,2024-03-02 06:00:00,75,16.0,380,400,180,100,100,20,460,80,95,70
        """
        let sleeps = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Beginn des Schlafs,Beginn des Aufwachens,Schlafleistung %,Atemfrequenz (Atemzüge/Min.),Schlafdauer (Min.),Dauer im Bett (Min.),Dauer des Leichtschlafs (Min.),Dauer des Tiefschlafs (Min.),Dauer des REM-Schlafs (Min.),Dauer des Aufwachens (Min.),Schlafbedarf (Min.),Schlafdefizit (Min.),Schlafeffizienz %,Schlafbeständigkeit %,Nickerchen
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,2024-03-02 23:00:00,2024-03-03 07:00:00,90,15.5,440,480,220,100,120,40,500,60,92,75,false
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,2024-03-03 15:00:00,2024-03-03 15:30:00,,,25,30,20,0,5,5,,,83,,true
        """
        let workouts = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Startzeit des Trainings,Endzeit des Trainings,Dauer (Min.),Name der Aktivität,Aktivitätsbelastung,Verbrannte Energie (cal),Max HF (Schläge pro Minute),Durchschnittliche HF (Schläge pro Minute),HF-Zone 1 %,HF-Zone 2 %,HF-Zone 3 %,HF-Zone 4 %,HF-Zone 5 %,GPS aktiviert
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,2024-03-03 18:00:00,2024-03-03 19:00:00,60,Laufen,8.0,500.0,170,140,10,20,30,30,10,false
        """
        let journal = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Fragetext,Beantwortet mit Ja,Anmerkungen
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,Alkohol konsumiert?,false,
        2024-03-02 23:00:00,2024-03-03 23:00:00,UTC+02:00,Koffein konsumiert?,true,Testnotiz
        """

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whoop-de-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("physiologische_zyklen.csv", cycles), ("Schlaf.csv", sleeps),
                             ("Trainings.csv", workouts), ("logbuch_eintraege.csv", journal)] {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let result = try WhoopExportImporter().import(from: dir)

        // Cycles: all three rows, newest (open) cycle included.
        XCTAssertEqual(result.cycles.count, 3)
        let c = try XCTUnwrap(result.cycles.first { $0.recoveryScore == 70 })
        XCTAssertEqual(c.cycleStart, Fixtures.utc(2024, 3, 2, 21, 0, 0))   // 23:00:00 at UTC+02:00
        XCTAssertEqual(c.tzOffsetMin, 120)
        XCTAssertEqual(c.restingHeartRate, 52)
        XCTAssertEqual(c.hrvMs, 65)
        XCTAssertEqual(c.skinTempCelsius, 34.00)          // absolute °C
        XCTAssertEqual(c.bloodOxygenPct, 97.00)
        XCTAssertEqual(c.dayStrain, 10.0)                 // WHOOP 0–21 scale, verbatim
        XCTAssertEqual(c.energyKcal, 2200)
        XCTAssertEqual(c.maxHeartRate, 160)
        XCTAssertEqual(c.avgHeartRate, 70)
        XCTAssertEqual(c.sleepPerformancePct, 90)
        XCTAssertEqual(c.respiratoryRate, 15.5)
        XCTAssertEqual(c.asleepDurationMin, 440)
        XCTAssertEqual(c.inBedDurationMin, 480)
        XCTAssertEqual(c.lightSleepDurationMin, 220)
        XCTAssertEqual(c.deepSleepDurationMin, 100)
        XCTAssertEqual(c.remDurationMin, 120)
        XCTAssertEqual(c.awakeDurationMin, 40)
        XCTAssertEqual(c.sleepNeedMin, 500)
        XCTAssertEqual(c.sleepDebtMin, 60)
        XCTAssertEqual(c.sleepEfficiencyPct, 92)
        XCTAssertEqual(c.sleepConsistencyPct, 75)
        XCTAssertEqual(c.sleepOnset, Fixtures.utc(2024, 3, 2, 21, 0, 0))
        XCTAssertEqual(c.wakeOnset, Fixtures.utc(2024, 3, 3, 5, 0, 0))
        // The still-open cycle has no strain / energy / HR yet — nil, not 0.
        let open = try XCTUnwrap(result.cycles.first { $0.recoveryScore == 60 })
        XCTAssertNil(open.dayStrain)
        XCTAssertNil(open.energyKcal)
        XCTAssertEqual(open.skinTempCelsius, 33.50)

        // Sleeps: the main night and the nap are both parsed; the nap is flagged.
        XCTAssertEqual(result.sleeps.count, 2)
        let night = try XCTUnwrap(result.sleeps.first { !$0.isNap })
        XCTAssertEqual(night.asleepDurationMin, 440)
        XCTAssertEqual(night.deepSleepDurationMin, 100)
        XCTAssertEqual(night.sleepNeedMin, 500)
        XCTAssertEqual(night.sleepDebtMin, 60)
        XCTAssertEqual(night.sleepConsistencyPct, 75)
        let nap = try XCTUnwrap(result.sleeps.first { $0.isNap })
        XCTAssertEqual(nap.asleepDurationMin, 25)
        XCTAssertNil(nap.sleepPerformancePct)

        // Workouts with HR zones.
        XCTAssertEqual(result.workouts.count, 1)
        let w = result.workouts[0]
        XCTAssertEqual(w.activityName, "Laufen")
        XCTAssertEqual(w.activityStrain, 8.0)
        XCTAssertEqual(w.energyKcal, 500)
        XCTAssertEqual(w.maxHeartRate, 170)
        XCTAssertEqual(w.avgHeartRate, 140)
        XCTAssertEqual(w.hrZone1Pct, 10)
        XCTAssertEqual(w.hrZone2Pct, 20)
        XCTAssertEqual(w.hrZone3Pct, 30)
        XCTAssertEqual(w.hrZone4Pct, 30)
        XCTAssertEqual(w.hrZone5Pct, 10)
        XCTAssertEqual(w.workoutStart, Fixtures.utc(2024, 3, 3, 16, 0, 0))

        // Journal answers + notes.
        XCTAssertEqual(result.journal.count, 2)
        let alcohol = try XCTUnwrap(result.journal.first { $0.question == "Alkohol konsumiert?" })
        XCTAssertEqual(alcohol.answer, "false")
        XCTAssertNil(alcohol.notes)
        let caffeine = try XCTUnwrap(result.journal.first { $0.question == "Koffein konsumiert?" })
        XCTAssertEqual(caffeine.answer, "true")
        XCTAssertEqual(caffeine.notes, "Testnotiz")
    }
}
