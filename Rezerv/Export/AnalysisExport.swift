import Foundation

/// Пакет данных для анализа (Claude, тренер): компактный JSON за последние 7 дней.
/// Схема описана в docs/export-format.md.
enum AnalysisExport {
    static let schema = "rezerv-export-1"

    private static let isoF: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dayF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func iso(_ d: Date) -> String { isoF.string(from: d) }
    private static func dayString(_ d: Date) -> String { dayF.string(from: d) }
    private static func int(_ v: Double?) -> Any { v.map { Int($0.rounded()) as Any } ?? NSNull() }
    private static func int(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }

    private static func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func r1(_ v: Double?) -> Any { v.map { r1($0) as Any } ?? NSNull() }

    private static let kindCode: [ActivityKind: String] = [
        .nodata: "-", .sleep: "S", .activity: "A", .rest: "R", .low: "L", .med: "M", .high: "H",
    ]

    /// Всё, что нужно для выгрузки одного 8-дневного окна
    struct Input {
        var raw: RawData
        var result: EnergyResult
        var profile: Profile
        var endMinute: Int
        var workouts: [(WorkoutRecord, WorkoutAnalysis)]
        var runs: [RunVO2]
        var currentVO2: Double?

        func dayDate(_ k: Int) -> Date { raw.base.addingTimeInterval(TimeInterval(k * 86400)) }
        func night(endingOn k: Int) -> Night? { k >= 0 && k < result.nights.count ? result.nights[k] : nil }

        /// Расчёт окна без AppModel (для выгрузки истории)
        static func compute(raw: RawData, profile P: Profile, endMinute: Int) -> Input {
            let res = EnergyEngine.compute(raw, profile: P, endMinute: endMinute)
            let wos = raw.workouts.filter { $0.start >= 1440 && $0.end <= endMinute }
                .map { ($0, WorkoutEngine.analyze($0, profile: P)) }
            let runs = raw.allWorkouts.map { w in
                RunVO2(workout: w, analysis: WorkoutEngine.analyze(w, profile: P), estimate: VO2Engine.estimate(w.stream, profile: P))
            }
            let vo2 = VO2Engine.smoothed(runs.map { ($0.workout.start, $0.estimate) }, at: endMinute)
            return Input(raw: raw, result: res, profile: P, endMinute: endMinute, workouts: wos, runs: runs, currentVO2: vo2)
        }
    }

    @MainActor
    static func input(_ m: AppModel) -> Input? {
        guard let raw = m.raw, let res = m.result else { return nil }
        return Input(raw: raw, result: res, profile: m.profile, endMinute: m.endMinute,
                     workouts: m.workouts, runs: m.runs, currentVO2: m.currentVO2)
    }

    /// Строит словарь для JSON. `days` — какие дни включить (1…7, 7 = последний день окна).
    static func build(_ m: Input, days: ClosedRange<Int> = 1...7) -> [String: Any]? {
        let raw = m.raw, res = m.result
        let P = m.profile
        var out: [String: Any] = [
            "schema": schema,
            "generated": iso(Date()),
            "timezone": TimeZone.current.identifier,
            "dataUntil": iso(raw.date(m.endMinute)),
            "app": "Rezerv (Резерв) — energy reserve 0–100, own approximate model, not Garmin",
            "profile": ["age": P.age, "weightKg": r1(P.weight), "restingHR": P.restingHR, "hrvBaselineMs": r1(P.hrvBaseline), "maxHR": P.maxHR] as [String: Any],
        ]

        var dayList: [[String: Any]] = []
        for k in days {
            let date = m.dayDate(k)
            var d: [String: Any] = ["date": dayString(date)]
            if let rhr = raw.restingHR[k] { d["restingHR"] = r1(rhr) }
            if let s = DaySummary.make(res.series, day: k) {
                d["reserve"] = [
                    "end": r1(s.current), "high": r1(s.high), "low": r1(s.low),
                    "charged": r1(s.charged), "drained": r1(s.drained),
                    "bySource": Dictionary(uniqueKeysWithValues: s.bySource.map { ($0.0, r1($0.1)) }),
                ] as [String: Any]
                d["minutesByState"] = Dictionary(uniqueKeysWithValues: s.minutesByKind.map { ($0.key.rawValue, $0.value) })
                if let st = s.avgStress { d["avgStressAwakeRest"] = st }
                // 5-минутный ряд: индексы от полуночи
                let pts = s.points
                d["series5min"] = [
                    "start": iso(date),
                    "stepMin": 5,
                    "hr": pts.map { int($0.hr) },
                    "steps": pts.map { Int($0.steps) },
                    "reserve": pts.map { r1($0.level) },
                    "stress": pts.map { int($0.stress) },
                    "state": pts.map { kindCode[$0.kind] ?? "-" }.joined(),
                    "stateLegend": "S sleep, R rest, L/M/H stress low/med/high, A activity, - no data",
                ] as [String: Any]
            }
            if let n = m.night(endingOn: k) {
                d["sleep"] = [
                    "start": iso(raw.date(n.start)), "end": iso(raw.date(n.end)),
                    "inBedMin": n.inBed, "asleepMin": n.asleep, "latencyMin": n.window.latency,
                    "stagesMin": Dictionary(uniqueKeysWithValues: n.stages.map { ($0.key.rawValue, $0.value) }),
                    "efficiency": r1(n.efficiency * 100), "awakenings": n.awakenings,
                    "hrvAvgMs": r1(n.hrvAvg), "hrAvg": r1(n.hrAvg), "hrMin": r1(n.hrMin), "respRate": r1(n.resp),
                    "score": n.score, "scoreParts": n.scoreParts.map { ["name": $0.name, "pts": $0.pts, "max": $0.max] as [String: Any] },
                    "reserveCharge": r1(n.charge),
                    "hypnogram5min": n.segments.map { String($0.stage.rawValue.prefix(1)) }.joined(),
                ] as [String: Any]
            }
            dayList.append(d)
        }
        out["days"] = dayList

        let since = days.lowerBound * 1440
        out["hrvSDNN"] = raw.hrv.filter { $0.t >= since }.map { [iso(raw.date($0.t)), r1($0.value)] as [Any] }
        out["respiratoryRate"] = raw.respiratory.filter { $0.t >= since }.map { [iso(raw.date($0.t)), r1($0.value)] as [Any] }
        out["spo2"] = raw.spo2.filter { $0.t >= since }.map { [iso(raw.date($0.t)), r1($0.value)] as [Any] }

        out["workouts"] = m.workouts.map { item -> [String: Any] in
            let w = item.0, a = item.1
            var x: [String: Any] = [
                "type": w.type, "start": iso(w.startDate), "durationMin": a.dur,
                "avgHR": a.avgHR, "maxHR": a.maxHR, "kcal": Int(a.kcal.rounded()), "trimp": Int(a.trimp.rounded()),
                "effect": a.effect, "zonesMin": a.zones, "recovery1minBpm": r1(w.recovery1),
            ]
            if a.dist > 0 { x["distanceKm"] = (a.dist / 10).rounded() / 100 }
            if let p = a.pace { x["paceSecPerKm"] = Int(p.rounded()) }
            if let v = a.speedKmh { x["speedKmh"] = r1(v) }
            if a.cadence > 0 { x["cadence"] = a.cadence }
            if a.elev > 0 { x["elevGainM"] = a.elev }
            if !a.splits.isEmpty { x["splits"] = a.splits.map { ["km": $0.km, "sec": Int($0.sec.rounded()), "hr": $0.hr] as [String: Any] } }
            if let e = m.runs.first(where: { $0.id == w.id })?.estimate, let v = e.value {
                x["vo2maxEstimate"] = r1(v); x["vo2StableMinutes"] = e.valid
            }
            x["perMinute"] = [
                "hr": a.stream.map { int($0.hr) },
                "speedMps": a.stream.map { (($0.speed * 100).rounded()) / 100 },
                "cadence": a.stream.map { Int($0.cadence) },
            ] as [String: Any]
            return x
        }

        out["vo2max"] = [
            "estimate30d": r1(m.currentVO2),
            "apple": raw.vo2Apple.map { [iso(raw.date($0.t)), r1($0.value)] as [Any] },
            "runs": m.runs.compactMap { r -> [Any]? in
                guard let v = r.estimate.value else { return nil }
                return [iso(r.workout.startDate), r1(v), r.estimate.valid, (r.analysis.dist / 10).rounded() / 100] as [Any]
            },
        ] as [String: Any]
        return out
    }

    static func jsonData(_ m: Input, days: ClosedRange<Int> = 1...7) -> Data? {
        guard let obj = build(m, days: days) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Файл для «Поделиться»
    @MainActor
    static func fileURL(_ m: AppModel) -> URL? {
        guard let i = input(m), let d = jsonData(i) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rezerv-\(dayString(Date())).json")
        try? d.write(to: url, options: .atomic)
        return url
    }

    static func todayString() -> String { dayString(Date()) }
    static func dayKey(_ d: Date) -> String { dayString(d) }
}
