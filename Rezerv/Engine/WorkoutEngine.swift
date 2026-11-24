import Foundation

let hrZones: [(lo: Double, name: String, note: String)] = [
    (0.5, "Зона 1", "восстановление"), (0.6, "Зона 2", "аэробная база"), (0.7, "Зона 3", "темп"),
    (0.8, "Зона 4", "порог"), (0.9, "Зона 5", "максимум"),
]

func zoneIndex(_ hr: Double, maxHR: Double) -> Int {
    let p = hr / maxHR
    var z = -1
    for (i, zz) in hrZones.enumerated() where p >= zz.lo { z = i }
    return z
}

/// Keytel 2005, ккал/мин по пульсу (мужская формула, как в демо)
func kcalPerMin(_ hr: Double, _ P: Profile) -> Double {
    max(1.2, (-55.0969 + 0.6309 * hr + 0.1988 * P.weight + 0.2017 * Double(P.age)) / 4.184)
}

struct Split: Identifiable {
    var id: Double { km }
    var km: Double
    var sec: Double
    var hr: Int
    var partial: Bool
}

struct WorkoutAnalysis {
    var stream: [WorkoutPoint]
    var dur: Int
    var dist: Double
    var run: Bool
    var bike: Bool
    var avgHR: Int
    var maxHR: Int
    var zones: [Int]
    var trimp: Double
    var kcal: Double
    var splits: [Split]
    var recovery1: Double?
    var effect: String
    var cadence: Int
    var elev: Int
    var pace: Double?      // сек/км
    var speedKmh: Double?
}

enum WorkoutEngine {
    static func analyze(_ w: WorkoutRecord, profile P: Profile) -> WorkoutAnalysis {
        let st = w.stream
        let hrs = st.compactMap(\.hr)
        var zones = [0, 0, 0, 0, 0]
        var trimp = 0.0, kcal = 0.0
        for p in st {
            guard let h = p.hr else { continue }
            let z = zoneIndex(h, maxHR: P.maxHR)
            if z >= 0 { zones[z] += 1 }
            trimp += trimpPerMin(clamp((h - P.restingHR) / P.hrReserve, 0, 1))
            kcal += kcalPerMin(h, P)
        }
        let dist = st.last?.distance ?? 0
        let run = w.isRun && dist > 300
        var splits: [Split] = []
        if run {
            var next = 1000.0, lastT = 0, lastHR: [Double] = []
            for p in st {
                if let h = p.hr { lastHR.append(h) }
                if p.distance >= next {
                    splits.append(Split(km: next / 1000, sec: Double(p.t + 1 - lastT) * 60, hr: Int(mean(lastHR).rounded()), partial: false))
                    lastT = p.t + 1; lastHR = []; next += 1000
                }
            }
            let rest = dist - (next - 1000)
            if rest > 150 {
                splits.append(Split(km: (dist / 10).rounded() / 100, sec: Double(st.count - lastT) * 60 * 1000 / rest,
                                    hr: Int(mean(lastHR).rounded()), partial: true))
            }
        }
        if let k = w.kcal { kcal = k }
        let effect = trimp < 25 ? "Восстановительная" : trimp < 55 ? "Поддерживающая" : trimp < 100 ? "Развивающая" : "Высокая нагрузка"
        let cad: Double
        if !w.isBike { cad = st.reduce(0) { $0 + $1.cadence } / Double(max(1, st.count)) }
        else { let c = st.map(\.cadence).filter { $0 > 0 }; cad = mean(c) }
        let dur = st.count
        return WorkoutAnalysis(
            stream: st, dur: dur, dist: dist, run: run, bike: w.isBike,
            avgHR: Int(mean(hrs).rounded()), maxHR: Int(hrs.max() ?? 0), zones: zones, trimp: trimp, kcal: kcal,
            splits: splits, recovery1: w.recovery1, effect: effect, cadence: Int(cad.rounded()),
            elev: Int((st.last?.elevGain ?? 0).rounded()),
            pace: run && dist > 0 ? Double(dur) * 60 / (dist / 1000) : nil,
            speedKmh: w.isBike && dur > 0 ? dist / 1000 / (Double(dur) / 60) : nil)
    }
}

// MARK: - VO2max (метод «пульс–скорость»)

/// Кислородная стоимость бега, мл/кг/мин; v в м/мин (Daniels & Gilbert, 1979)
func vo2ForSpeed(_ v: Double) -> Double { -4.60 + 0.182258 * v + 0.000104 * v * v }

struct VO2Point {
    var t: Int, hr: Double, x: Double, speed: Double, vo2: Double, ok: Bool, est: Double?
}

struct VO2Estimate {
    var points: [VO2Point]
    var valid: Int
    var value: Double?
    var reason: String?
    var median: Double?
    var regression: Double?
    var r2: Double?
    var useRegression = false
}

enum VO2Engine {
    static let skipStartMin = 10, skipEndMin = 5, speedWindowMin = 3
    static let maxCV = 0.06, minHRR = 0.55, maxHRR = 0.95, minSpeed = 1.8
    static let minValidMin = 8, minR2 = 0.6, minHRSpan = 8.0

    static func estimate(_ st: [WorkoutPoint], profile P: Profile) -> VO2Estimate {
        let hrmax = P.maxHR, hrr = max(20, hrmax - P.restingHR)
        var pts: [VO2Point] = []
        if st.count > skipStartMin {
            for t in skipStartMin..<st.count {
                if st.count > 25 && t >= st.count - skipEndMin { continue }
                guard let hr = st[t].hr else { continue }
                let ws = Array(st[(t - speedWindowMin)..<t])
                let win = ws.map(\.speed)
                let prev = t - speedWindowMin - 1 >= 0 ? st[t - speedWindowMin - 1] : ws[0]
                let dd = ws.last!.distance - prev.distance
                var grade = 0.0
                if dd > 50, let e1 = ws.last!.ele, let e0 = prev.ele { grade = clamp((e1 - e0) / dd, -0.1, 0.15) }
                let sp = mean(win)
                guard sp > 0 else { continue }
                let cv = sqrt(mean(win.map { ($0 - sp) * ($0 - sp) })) / sp
                let x = (hr - P.restingHR) / hrr
                let ok = cv < maxCV && x >= minHRR && x <= maxHRR && sp >= minSpeed
                let vo2 = vo2ForSpeed(sp * 60) + 0.9 * sp * 60 * (grade > 0 ? grade : grade * 0.5)
                pts.append(VO2Point(t: t, hr: hr, x: x, speed: sp, vo2: vo2, ok: ok, est: ok ? (vo2 - 3.5) / x + 3.5 : nil))
            }
        }
        let v = pts.filter(\.ok)
        var res = VO2Estimate(points: pts, valid: v.count)
        guard v.count >= minValidMin else {
            res.reason = "мало устойчивых минут (\(v.count) из \(minValidMin))"
            return res
        }
        let ests = v.compactMap(\.est).sorted()
        let med = ests[ests.count / 2]
        let mx = mean(v.map(\.hr)), my = mean(v.map(\.vo2))
        let sxx = v.reduce(0) { $0 + ($1.hr - mx) * ($1.hr - mx) }
        let sxy = v.reduce(0) { $0 + ($1.hr - mx) * ($1.vo2 - my) }
        let slope = sxx != 0 ? sxy / sxx : 0, icpt = my - slope * mx
        let ssr = v.reduce(0) { $0 + pow($1.vo2 - (icpt + slope * $1.hr), 2) }
        let sst = v.reduce(0) { $0 + pow($1.vo2 - my, 2) }
        let r2 = sst != 0 ? 1 - ssr / sst : 0
        let span = (v.map(\.hr).max() ?? 0) - (v.map(\.hr).min() ?? 0)
        let reg = icpt + slope * hrmax
        let useReg = r2 >= minR2 && span >= minHRSpan && slope > 0
        res.median = med; res.regression = reg; res.r2 = r2; res.useRegression = useReg
        res.value = useReg ? 0.5 * reg + 0.5 * med : med
        return res
    }

    /// Взвешенное среднее за 30 дней: свежие пробежки весят больше
    static func smoothed(_ list: [(start: Int, est: VO2Estimate)], at: Int) -> Double? {
        let use = list.filter { $0.est.value != nil && $0.start <= at && at - $0.start <= 30 * 1440 }
        guard !use.isEmpty else { return nil }
        var sw = 0.0, s = 0.0
        for r in use {
            let age = Double(at - r.start) / 1440
            let w = exp(-age / 12) * min(1, Double(r.est.valid) / 20)
            sw += w; s += w * r.est.value!
        }
        return sw > 0 ? s / sw : nil
    }

    /// Прогноз времени на дистанции по Дэниелсу (VDOT ≈ VO2max), минуты
    static func raceTime(vo2max: Double, meters: Double) -> Double {
        func f(_ t: Double) -> Double {
            let v = meters / t, vo2 = vo2ForSpeed(v)
            let pct = 0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
            return vo2 / pct - vo2max
        }
        var lo = 5.0, hi = 600.0
        for _ in 0..<60 { let mid = (lo + hi) / 2; if f(mid) > 0 { lo = mid } else { hi = mid } }
        return (lo + hi) / 2
    }

    static func category(_ v: Double, age: Int) -> String {
        // нормы для мужчин 30–39 (ACSM), как в демо
        let norms: [(Double, String)] = [(0, "Низкий"), (35, "Ниже среднего"), (40, "Средний"), (44, "Хороший"), (49, "Отличный"), (54, "Превосходный")]
        var c = norms[0].1
        for (lo, n) in norms where v >= lo { c = n }
        return c
    }
}
