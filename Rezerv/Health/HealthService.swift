import Foundation
import HealthKit

/// Чтение Apple Health (HealthKit) и раскладка данных в модель движка.
final class HealthService {
    static let shared = HealthService()
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Типы данных

    let heartRate = HKQuantityType(.heartRate)
    let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    let restingHR = HKQuantityType(.restingHeartRate)
    let steps = HKQuantityType(.stepCount)
    let respiratory = HKQuantityType(.respiratoryRate)
    let spo2 = HKQuantityType(.oxygenSaturation)
    let vo2max = HKQuantityType(.vo2Max)
    let distanceRun = HKQuantityType(.distanceWalkingRunning)
    let distanceBike = HKQuantityType(.distanceCycling)
    let bodyMass = HKQuantityType(.bodyMass)
    let activeEnergy = HKQuantityType(.activeEnergyBurned)
    let hrRecovery = HKQuantityType(.heartRateRecoveryOneMinute)
    let sleep = HKCategoryType(.sleepAnalysis)

    var readTypes: Set<HKObjectType> {
        [heartRate, hrv, restingHR, steps, respiratory, spo2, vo2max, distanceRun, distanceBike, bodyMass,
         activeEnergy, hrRecovery, sleep, HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
         HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
    }

    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let ms = HKUnit.secondUnit(with: .milli)

    // MARK: Доступ

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Фоновая доставка: iOS будит приложение, когда в Здоровье появляются новые данные.
    func startBackgroundObservers(onUpdate: @escaping @Sendable () async -> Void) {
        let types: [(HKSampleType, HKUpdateFrequency)] = [
            (HKObjectType.workoutType(), .immediate), (sleep, .immediate),
            (heartRate, .hourly), (hrv, .hourly), (restingHR, .hourly),
        ]
        for (type, freq) in types {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await onUpdate()
                    completion()
                }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: type, frequency: freq) { _, _ in }
        }
    }

    // MARK: Базовые запросы

    private func predicate(_ a: Date, _ b: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: a, end: b, options: [])
    }

    func quantitySamples(_ type: HKQuantityType, _ a: Date, _ b: Date) async throws -> [HKQuantitySample] {
        let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate(a, b))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store)
    }

    func categorySamples(_ type: HKCategoryType, _ a: Date, _ b: Date) async throws -> [HKCategorySample] {
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate(a, b))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store)
    }

    func workouts(_ a: Date, _ b: Date) async throws -> [HKWorkout] {
        let d = HKSampleQueryDescriptor(predicates: [.workout(predicate(a, b))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store)
    }

    func statistics(_ type: HKQuantityType, _ a: Date, _ b: Date, every: DateComponents,
                    options: HKStatisticsOptions) async throws -> [HKStatistics] {
        let d = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate(a, b)),
            options: options, anchorDate: a, intervalComponents: every)
        let c = try await d.result(for: store)
        var out: [HKStatistics] = []
        c.enumerateStatistics(from: a, to: b) { s, _ in out.append(s) }
        return out
    }

    // MARK: Профиль

    func loadProfile(now: Date) async -> Profile {
        var P = Profile()
        let cal = Calendar.current
        if let dob = try? store.dateOfBirthComponents(), let d = cal.date(from: dob) {
            P.age = cal.dateComponents([.year], from: d, to: now).year ?? P.age
        }
        let tanaka = (208 - 0.7 * Double(P.age)).rounded()
        P.maxHR = tanaka
        if let w = try? await quantitySamples(bodyMass, now.addingTimeInterval(-365 * 86400), now).last {
            P.weight = w.quantity.doubleValue(for: .gramUnit(with: .kilo))
        }
        let d30 = now.addingTimeInterval(-30 * 86400)
        if let r = try? await quantitySamples(restingHR, d30, now), !r.isEmpty {
            let v = r.map { $0.quantity.doubleValue(for: bpm) }.sorted()
            P.restingHR = v[v.count / 2].rounded()
        }
        if let h = try? await quantitySamples(hrv, d30, now), !h.isEmpty {
            P.hrvBaseline = (mean(h.map { $0.quantity.doubleValue(for: ms) }) * 10).rounded() / 10
        }
        // Макс. пульс: второй по величине дневной максимум за 180 дней (один выброс датчика отбрасываем)
        if let s = try? await statistics(heartRate, now.addingTimeInterval(-180 * 86400), now,
                                         every: DateComponents(day: 1), options: .discreteMax) {
            let peaks = s.compactMap { $0.maximumQuantity()?.doubleValue(for: bpm) }.sorted(by: >)
            if peaks.count >= 2, peaks[1] >= tanaka - 15, peaks[1] <= 220 { P.maxHR = peaks[1].rounded() }
        }
        return P
    }

    // MARK: Неделя для движка

    /// Загружает 8 дней: день 0 — разгонный (для непрерывности уровня), 1…7 — отображаемая неделя, 7 — сегодня.
    func loadWeek(now: Date, cache: WorkoutCache) async throws -> RawData {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        let days = 8, slots = days * 288
        func minute(_ d: Date) -> Int { Int((d.timeIntervalSince(base) / 60).rounded(.down)) }

        async let hrS = quantitySamples(heartRate, base, now)
        async let stepStats = statistics(steps, base, now, every: DateComponents(minute: 5), options: .cumulativeSum)
        async let hrvS = quantitySamples(hrv, base.addingTimeInterval(-43200), now)
        async let sleepS = categorySamples(sleep, base.addingTimeInterval(-43200), now)
        async let respS = quantitySamples(respiratory, base, now)
        async let spoS = quantitySamples(spo2, base, now)
        async let rhrStats = statistics(restingHR, base, now, every: DateComponents(day: 1), options: .discreteAverage)
        async let vo2S = quantitySamples(vo2max, base.addingTimeInterval(-90 * 86400), now)

        // Пульс по 5-мин слотам
        let hrSamples = try await hrS
        var hrSum = [Double](repeating: 0, count: slots), hrCnt = [Double](repeating: 0, count: slots)
        for s in hrSamples {
            let i = minute(s.startDate) / 5
            guard i >= 0 && i < slots else { continue }
            hrSum[i] += s.quantity.doubleValue(for: bpm); hrCnt[i] += 1
        }
        let hrSlots: [Double?] = (0..<slots).map { hrCnt[$0] > 0 ? (hrSum[$0] / hrCnt[$0]).rounded() : nil }

        var stepSlots = [Double](repeating: 0, count: slots)
        for s in try await stepStats {
            let i = minute(s.startDate) / 5
            if i >= 0 && i < slots { stepSlots[i] = s.sumQuantity()?.doubleValue(for: .count()) ?? 0 }
        }

        let hrvVals = try await hrvS.map { TimedValue(t: minute($0.startDate), value: $0.quantity.doubleValue(for: ms)) }
        let respVals = try await respS.map { TimedValue(t: minute($0.startDate), value: $0.quantity.doubleValue(for: bpm)) }
        let spoVals = try await spoS.map { TimedValue(t: minute($0.startDate), value: $0.quantity.doubleValue(for: .percent()) * 100) }
        let vo2Unit = HKUnit(from: "ml/kg*min")
        let vo2Vals = try await vo2S.map { TimedValue(t: minute($0.startDate), value: $0.quantity.doubleValue(for: vo2Unit)) }

        var rhr = [Double?](repeating: nil, count: days)
        for s in try await rhrStats {
            let k = minute(s.startDate) / 1440
            if k >= 0 && k < days { rhr[k] = s.averageQuantity()?.doubleValue(for: bpm) }
        }

        // Сон
        let (sleepSlots, windows) = buildSleep(try await sleepS, minute: minute, slots: slots, days: days)

        // Тренировки недели (пульс берём из уже загруженных образцов)
        let weekWorkouts = try await workouts(base, now)
        var week: [WorkoutRecord] = []
        for w in weekWorkouts where w.duration >= 180 {
            week.append(try await record(for: w, minute: minute, cache: cache, hrSamples: hrSamples))
        }
        // Пробежки за 90 дней для VO2max
        let longAgo = base.addingTimeInterval(-83 * 86400)
        let runs = try await workouts(longAgo, now).filter { $0.workoutActivityType == .running && $0.duration >= 15 * 60 }
        var all: [WorkoutRecord] = []
        for w in runs {
            if let r = week.first(where: { $0.id == w.uuid }) { all.append(r); continue }
            all.append(try await record(for: w, minute: minute, cache: cache, hrSamples: nil))
        }
        cache.save()

        return RawData(base: base, days: days, heartRate: hrSlots, steps: stepSlots, hrv: hrvVals, sleep: sleepSlots,
                       respiratory: respVals, spo2: spoVals, restingHR: rhr, sleepWindows: windows,
                       workouts: week, allWorkouts: all, vo2Apple: vo2Vals)
    }

    // MARK: Сон

    private func buildSleep(_ samples: [HKCategorySample], minute: (Date) -> Int, slots: Int, days: Int)
        -> ([SleepStage?], [SleepWindow?]) {
        func stage(_ v: Int) -> SleepStage? {
            switch HKCategoryValueSleepAnalysis(rawValue: v) {
            case .asleepDeep: return .deep
            case .asleepCore, .asleepUnspecified: return .core
            case .asleepREM: return .rem
            case .awake: return .awake
            default: return nil // inBed не используем
            }
        }
        // Если есть стадии (Apple Watch), игнорируем «просто сон» от других источников
        let staged = samples.contains {
            [HKCategoryValueSleepAnalysis.asleepDeep, .asleepCore, .asleepREM].map(\.rawValue).contains($0.value)
        }
        let segs: [(s: Int, e: Int, st: SleepStage)] = samples.compactMap { x in
            guard let st = stage(x.value) else { return nil }
            if staged && x.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue { return nil }
            return (minute(x.startDate), minute(x.endDate), st)
        }.sorted { $0.s < $1.s }

        // стадия слота — с наибольшим перекрытием
        var out = [SleepStage?](repeating: nil, count: slots)
        for g in segs {
            let a = max(0, g.s / 5), b = min(slots - 1, g.e / 5)
            guard a <= b else { continue }
            for i in a...b {
                let o = min(i * 5 + 5, g.e) - max(i * 5, g.s)
                guard o > 0 else { continue }
                if o >= 3 || out[i] == nil { out[i] = g.st }
            }
        }
        // сессии: сегменты с разрывом ≤ 90 мин
        var sess: [(start: Int, end: Int)] = []
        for g in segs {
            if let l = sess.last, g.s - l.end <= 90 { sess[sess.count - 1].end = max(l.end, g.e) }
            else { sess.append((g.s, g.e)) }
        }
        var windows: [SleepWindow?] = []
        for k in 0..<days {
            let c = sess.filter { $0.end >= k * 1440 + 120 && $0.end <= k * 1440 + 15 * 60 }
                .max { ($0.end - $0.start) < ($1.end - $1.start) }
            guard let c else { windows.append(nil); continue }
            let st = (c.start / 5) * 5, en = Int((Double(c.end) / 5).rounded(.up)) * 5
            let firstAsleep = (max(0, st / 5)..<min(slots, en / 5)).first { out[$0] != nil && out[$0] != .awake }
            windows.append(SleepWindow(start: st, end: en, latency: firstAsleep.map { $0 * 5 - st } ?? 0))
        }
        return (out, windows)
    }

    // MARK: Тренировка → поминутный поток

    private func record(for w: HKWorkout, minute: (Date) -> Int, cache: WorkoutCache, hrSamples: [HKQuantitySample]?) async throws -> WorkoutRecord {
        let startM = minute(w.startDate), endM = minute(w.endDate)
        if var cached = cache.get(w.uuid) {
            // смещение минут меняется каждый день — пересчитываем
            cached.start = startM; cached.end = endM
            return cached
        }
        let info = WorkoutTypeInfo.of(w.workoutActivityType)
        let dur = max(1, Int((w.duration / 60).rounded()))
        let a = w.startDate, b = w.endDate

        let hrs: [HKQuantitySample]
        if let hrSamples {
            hrs = hrSamples.filter { $0.startDate >= a && $0.startDate <= b }
        } else {
            hrs = try await quantitySamples(heartRate, a, b)
        }
        var hrSum = [Double](repeating: 0, count: dur), hrCnt = [Double](repeating: 0, count: dur)
        for s in hrs {
            let i = Int(s.startDate.timeIntervalSince(a) / 60)
            if i >= 0 && i < dur { hrSum[i] += s.quantity.doubleValue(for: bpm); hrCnt[i] += 1 }
        }

        // распределяем количество образца равномерно по минутам, которые он покрывает
        func perMinute(_ samples: [HKQuantitySample], unit: HKUnit) -> [Double] {
            var v = [Double](repeating: 0, count: dur)
            for s in samples {
                let q = s.quantity.doubleValue(for: unit)
                let s0 = max(0, s.startDate.timeIntervalSince(a)), s1 = min(Double(dur) * 60, s.endDate.timeIntervalSince(a))
                let len = max(1, s1 - s0)
                var t = s0
                while t < s1 {
                    let i = Int(t / 60), next = min(s1, Double(i + 1) * 60)
                    if i >= 0 && i < dur { v[i] += q * (next - t) / len }
                    t = next
                }
                if s1 <= s0 {
                    let i = Int(s0 / 60)
                    if i >= 0 && i < dur { v[i] += q }
                }
            }
            return v
        }
        var dist = [Double](repeating: 0, count: dur), cad = [Double](repeating: 0, count: dur)
        if info.isRun || info.isWalk {
            dist = perMinute(try await quantitySamples(distanceRun, a, b), unit: .meter())
            cad = perMinute(try await quantitySamples(steps, a, b), unit: .count())
        } else if info.isBike {
            dist = perMinute(try await quantitySamples(distanceBike, a, b), unit: .meter())
        }

        let elevTotal = (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()) ?? 0
        let totalDist = dist.reduce(0, +)
        var stream: [WorkoutPoint] = []
        var lastHR: Double? = nil, cum = 0.0
        for i in 0..<dur {
            let h: Double? = hrCnt[i] > 0 ? (hrSum[i] / hrCnt[i]).rounded() : lastHR
            lastHR = h ?? lastHR
            cum += dist[i]
            stream.append(WorkoutPoint(t: i, hr: h, speed: dist[i] / 60, cadence: cad[i], distance: cum,
                                       elevGain: totalDist > 0 ? elevTotal * cum / totalDist : 0, ele: nil))
        }
        // первые минуты без пульса заполняем первым известным
        if let first = stream.first(where: { $0.hr != nil })?.hr {
            for i in stream.indices where stream[i].hr == nil { stream[i].hr = first }
        }

        let kcal = w.statistics(for: activeEnergy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let rec = try? await quantitySamples(hrRecovery, b.addingTimeInterval(-60), b.addingTimeInterval(15 * 60)).first?
            .quantity.doubleValue(for: bpm)

        let r = WorkoutRecord(id: w.uuid, type: info.name, symbol: info.symbol, isRun: info.isRun, isBike: info.isBike,
                              start: startM, end: endM, startDate: a, kcal: kcal, recovery1: rec, stream: stream)
        // кэшируем только завершённые тренировки старше часа
        if b < Date().addingTimeInterval(-3600) { cache.put(r) }
        return r
    }
}

struct WorkoutTypeInfo {
    var name: String, symbol: String, isRun = false, isBike = false, isWalk = false

    static func of(_ t: HKWorkoutActivityType) -> WorkoutTypeInfo {
        switch t {
        case .running: return .init(name: "Бег", symbol: "figure.run", isRun: true)
        case .walking: return .init(name: "Ходьба", symbol: "figure.walk", isWalk: true)
        case .hiking: return .init(name: "Хайкинг", symbol: "figure.hiking", isWalk: true)
        case .cycling: return .init(name: "Велосипед", symbol: "figure.outdoor.cycle", isBike: true)
        case .swimming: return .init(name: "Плавание", symbol: "figure.pool.swim")
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return .init(name: "Силовая", symbol: "dumbbell.fill")
        case .highIntensityIntervalTraining: return .init(name: "ВИИТ", symbol: "bolt.heart.fill")
        case .yoga: return .init(name: "Йога", symbol: "figure.yoga")
        case .rowing: return .init(name: "Гребля", symbol: "figure.rower")
        case .elliptical: return .init(name: "Эллипс", symbol: "figure.elliptical")
        case .soccer: return .init(name: "Футбол", symbol: "figure.soccer")
        case .boxing, .martialArts: return .init(name: "Единоборства", symbol: "figure.boxing")
        case .coreTraining: return .init(name: "Кор", symbol: "figure.core.training")
        case .mixedCardio: return .init(name: "Кардио", symbol: "heart.fill")
        case .cooldown: return .init(name: "Заминка", symbol: "figure.cooldown")
        default: return .init(name: "Тренировка", symbol: "figure.mixed.cardio")
        }
    }
}

/// Кэш поминутных потоков тренировок, чтобы не перечитывать 90 дней пробежек при каждой синхронизации
final class WorkoutCache {
    private var items: [UUID: WorkoutRecord] = [:]
    private var dirty = false
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workouts-v1.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([UUID: WorkoutRecord].self, from: d) { items = v }
    }
    func get(_ id: UUID) -> WorkoutRecord? { items[id] }
    func put(_ r: WorkoutRecord) { items[r.id] = r; dirty = true }
    func save() {
        guard dirty else { return }
        let cutoff = Date().addingTimeInterval(-100 * 86400)
        items = items.filter { $0.value.startDate > cutoff }
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        dirty = false
    }
}
