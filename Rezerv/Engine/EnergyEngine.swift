import Foundation

/// Резерв энергии: собственная приближённая модель (не алгоритм Garmin/Firstbeat).
/// Формулы и коэффициенты совпадают с веб-демо (engine.js).
enum EnergyConfig {
    static let slotMin = 5
    static let sleepRate: [SleepStage: Double] = [.deep: 15, .core: 10.5, .rem: 8.5, .awake: -1]
    static let restCharge = 2.5
    static let baseDrain = 1.5
    static let stressDrain: [ActivityKind: Double] = [.low: 1.0, .med: 2.5, .high: 4.0]
    static let activityK = 0.24
    static let activityMinDrain = 1.5
    static let walkStepsPerSlot = 300.0
    static let postWorkoutMin = 20
    static let headroomFull = 102.0, headroomSpan = 60.0, headroomMin = 0.15
    static let qHRV: ClosedRange<Double> = 0.55...1.25
    static let qHR: ClosedRange<Double> = 0.5...1.1
    static let bounds: ClosedRange<Double> = 5...100
    static let startLevel = 50.0
}

@inline(__always) func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
@inline(__always) func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, v)) }
func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

/// Banister TRIMP за минуту, x — доля резерва пульса
func trimpPerMin(_ x: Double) -> Double { x * 0.64 * exp(1.92 * x) }

func stressFrom(hr: Double, hrvRatio: Double, profile P: Profile) -> Int {
    let sHR = (hr - P.restingHR - 4) / (0.4 * P.hrReserve) * 100
    let sHRV = (1.1 - hrvRatio) / 0.5 * 100
    return Int(clamp(0.75 * clamp(sHR, 0, 100) + 0.25 * clamp(sHRV, 0, 100), 0, 100).rounded())
}

func stressZone(_ s: Int) -> ActivityKind {
    s <= 25 ? .rest : s <= 50 ? .low : s <= 75 ? .med : .high
}

enum EnergyEngine {

    static func sleepScore(_ n: Night, profile P: Profile) -> (Int, [SleepScoreComponent]) {
        func lin(_ v: Double, _ a: Double, _ b: Double) -> Double { clamp((v - a) / (b - a), 0, 1) }
        let deep = Double(n.stages[.deep] ?? 0), core = Double(n.stages[.core] ?? 0), rem = Double(n.stages[.rem] ?? 0)
        let asleep = max(1, deep + core + rem)
        let a = Int(asleep)
        var comp: [(String, Int, Double, String)] = [
            ("Длительность", 30, lin(asleep, 240, 480), "\(a / 60) ч \(a % 60) мин из 8 ч"),
            ("Глубокий сон", 15, lin(deep / asleep, 0.08, 0.2), "\(Int((deep / asleep * 100).rounded()))% (норма 13–23%)"),
            ("REM", 15, lin(rem / asleep, 0.12, 0.24), "\(Int((rem / asleep * 100).rounded()))% (норма 20–25%)"),
            ("Эффективность", 15, lin(n.efficiency, 0.75, 0.92), "\(Int((n.efficiency * 100).rounded()))% времени в постели"),
        ]
        if let h = n.hrvAvg {
            comp.append(("Восстановление (HRV)", 15, lin(h / P.hrvBaseline, 0.6, 1.0),
                         "\(Int(h.rounded())) мс, \(Int((h / P.hrvBaseline * 100).rounded()))% нормы"))
        } else {
            comp.append(("Восстановление (HRV)", 15, 0.5, "нет замеров HRV за ночь, засчитано 50%"))
        }
        comp.append(("Пульс во сне", 10, lin(-(n.hrAvg - P.restingHR), -10, 0),
                     "\(Int(n.hrAvg.rounded())) уд/мин при пульсе покоя \(Int(P.restingHR))"))
        let parts = comp.map { SleepScoreComponent(name: $0.0, max: $0.1, pts: Int((Double($0.1) * $0.2).rounded()), note: $0.3) }
        return (parts.reduce(0) { $0 + $1.pts }, parts)
    }

    static func nights(_ raw: RawData, profile P: Profile) -> [Night?] {
        raw.sleepWindows.map { w -> Night? in
            guard let w else { return nil }
            let a = max(0, w.start / 5), b = min(raw.slotCount, w.end / 5)
            guard b > a else { return nil }
            let hv = raw.hrv.filter { $0.t >= w.start && $0.t < w.end }.map(\.value)
            var hrs: [Double] = []
            var hrMin: Double? = nil, hrMinAt: Int? = nil
            var stages: [SleepStage: Int] = [.deep: 0, .core: 0, .rem: 0, .awake: 0]
            var segs: [(m: Int, stage: SleepStage)] = []
            for i in a..<b {
                if let h = raw.heartRate[i] {
                    hrs.append(h)
                    if hrMin == nil || h < hrMin! { hrMin = h; hrMinAt = i * 5 }
                }
                if let st = raw.sleep[i] { stages[st, default: 0] += 5; segs.append((i * 5, st)) }
            }
            let hrvAvg: Double? = hv.isEmpty ? nil : mean(hv)
            let hrAvg = hrs.isEmpty ? P.restingHR : mean(hrs)
            let qHRV = hrvAvg.map { clamp($0 / P.hrvBaseline, EnergyConfig.qHRV) } ?? 1
            let qHR = clamp(1 - (hrAvg - P.restingHR) / 20, EnergyConfig.qHR)
            var awakenings = 0
            for i in segs.indices where i > 0 {
                if segs[i].stage == .awake && segs[i - 1].stage != .awake && segs[i].m >= w.start + w.latency { awakenings += 1 }
            }
            let inBed = w.end - w.start
            let asleep = inBed - (stages[.awake] ?? 0)
            let rr = raw.respiratory.filter { $0.t >= w.start && $0.t < w.end }.map(\.value)
            var n = Night(window: w, hrvAvg: hrvAvg, hrAvg: hrAvg, qHRV: qHRV, qHR: qHR, stages: stages,
                          awakenings: awakenings, inBed: inBed, asleep: asleep,
                          efficiency: Double(asleep) / Double(max(1, inBed)),
                          resp: rr.isEmpty ? nil : mean(rr), hrMin: hrMin, hrMinAt: hrMinAt, segments: segs)
            let (score, parts) = sleepScore(n, profile: P)
            n.score = score; n.scoreParts = parts
            return n
        }
    }

    /// Основной расчёт уровня резерва с шагом 5 минут.
    static func compute(_ raw: RawData, profile P: Profile, startLevel: Double = EnergyConfig.startLevel, endMinute: Int) -> EnergyResult {
        let dt = Double(EnergyConfig.slotMin) / 60
        var hrvAt: [Int: Double] = [:]
        for h in raw.hrv { hrvAt[(h.t / 5) * 5] = h.value }
        var nights = Self.nights(raw, profile: P)
        var L = startLevel, lastHRV = P.hrvBaseline
        var out: [EnergyPoint] = []
        out.reserveCapacity(raw.slotCount)

        for i in 0..<raw.slotCount {
            let m = i * 5
            if m >= endMinute { break }
            let hr = raw.heartRate[i], steps = raw.steps[i]
            if let h = hrvAt[m] { lastHRV = h }
            let stage = raw.sleep[i]
            if stage == nil && hr == nil {
                out.append(EnergyPoint(m: m, hr: nil, steps: steps, hrv: hrvAt[m], stage: nil, kind: .nodata, stress: nil, level: L, parts: EnergyParts()))
                continue
            }
            let head = clamp((EnergyConfig.headroomFull - L) / EnergyConfig.headroomSpan, EnergyConfig.headroomMin, 1)
            var parts = EnergyParts()
            var kind: ActivityKind
            var stress: Int? = nil
            let inWo = raw.workouts.contains { m >= $0.start && m < $0.end + EnergyConfig.postWorkoutMin }
            if let stage {
                kind = .sleep
                let night = nights.firstIndex { n in n.map { m >= $0.start && m < $0.end } ?? false }
                let q = night.flatMap { nights[$0]?.q } ?? 1
                parts.sleep = stage == .awake
                    ? EnergyConfig.sleepRate[.awake]! * dt
                    : EnergyConfig.sleepRate[stage]! * q * head * dt
            } else if inWo || steps >= EnergyConfig.walkStepsPerSlot {
                kind = .activity
                let x = clamp(((hr ?? P.restingHR) - P.restingHR) / P.hrReserve, 0, 1)
                parts.activity = -max(EnergyConfig.activityMinDrain, EnergyConfig.activityK * trimpPerMin(x) * 60) * dt
            } else {
                let s = stressFrom(hr: hr!, hrvRatio: lastHRV / P.hrvBaseline, profile: P)
                stress = s
                kind = stressZone(s)
                parts.base = -EnergyConfig.baseDrain * dt
                if kind == .rest { parts.rest = EnergyConfig.restCharge * head * dt }
                else { parts.stress = -(EnergyConfig.stressDrain[kind] ?? 0) * dt }
            }
            let total = parts.total
            let nL = clamp(L + total, EnergyConfig.bounds), actual = nL - L
            if abs(actual - total) > 1e-9 {
                // упёрлись в границу: пропорционально урезаем вклад
                let pos = [parts.sleep, parts.rest].filter { $0 > 0 }.reduce(0, +)
                let neg = [parts.sleep, parts.base, parts.stress, parts.activity].filter { $0 < 0 }.reduce(0, +)
                if actual >= neg && pos > 0 {
                    let k = (actual - neg) / pos
                    if parts.sleep > 0 { parts.sleep *= k }
                    if parts.rest > 0 { parts.rest *= k }
                } else {
                    if parts.sleep > 0 { parts.sleep = 0 }
                    if parts.rest > 0 { parts.rest = 0 }
                    let k = neg != 0 ? actual / neg : 0
                    if parts.sleep < 0 { parts.sleep *= k }
                    parts.base *= k; parts.stress *= k; parts.activity *= k
                }
            }
            if stage != nil, let ni = nights.firstIndex(where: { n in n.map { m >= $0.start && m < $0.end } ?? false }) {
                nights[ni]?.charge += parts.sleep
            }
            L = nL
            out.append(EnergyPoint(m: m, hr: hr, steps: steps, hrv: hrvAt[m], stage: stage, kind: kind, stress: stress, level: L, parts: parts))
        }
        return EnergyResult(series: out, nights: nights)
    }
}

/// Сводка одного дня (для экрана «Резерв»)
struct DaySummary {
    var day: Int
    var points: [EnergyPoint]
    var current: Double
    var high: Double
    var low: Double
    var charged: Double
    var drained: Double
    var bySource: [(String, Double)]
    var minutesByKind: [ActivityKind: Int]
    var avgStress: Int?

    static func make(_ series: [EnergyPoint], day k: Int) -> DaySummary? {
        let s = series.filter { $0.m / 1440 == k }
        guard let last = s.last else { return nil }
        var sum = EnergyParts()
        var mins: [ActivityKind: Int] = [:]
        var stress: [Int] = []
        for p in s {
            sum.sleep += p.parts.sleep; sum.rest += p.parts.rest; sum.base += p.parts.base
            sum.stress += p.parts.stress; sum.activity += p.parts.activity
            mins[p.kind, default: 0] += 5
            if let st = p.stress { stress.append(st) }
        }
        let levels = s.map(\.level)
        let charged = [sum.sleep, sum.rest].filter { $0 > 0 }.reduce(0, +)
        let drained = [sum.sleep, sum.base, sum.stress, sum.activity].filter { $0 < 0 }.reduce(0, +)
        return DaySummary(day: k, points: s, current: last.level, high: levels.max() ?? 0, low: levels.min() ?? 0,
                          charged: charged, drained: drained,
                          bySource: [("Сон", sum.sleep), ("Отдых", sum.rest), ("Фон", sum.base), ("Стресс", sum.stress), ("Активность", sum.activity)],
                          minutesByKind: mins,
                          avgStress: stress.isEmpty ? nil : stress.reduce(0, +) / stress.count)
    }
}
