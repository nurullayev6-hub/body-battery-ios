import Foundation

/// Все времена внутри движка — целые минуты от `RawData.base` (полночь «вспомогательного» дня 0).
/// Это повторяет модель веб-демо, поэтому формулы переносятся один к одному.

enum SleepStage: String, Codable, CaseIterable {
    case deep, core, rem, awake

    var title: String {
        switch self {
        case .deep: return "Глубокий"
        case .core: return "Основной"
        case .rem: return "REM"
        case .awake: return "Бодрствование"
        }
    }
}

struct Profile: Codable, Equatable {
    var age: Int = 32
    var weight: Double = 78
    var restingHR: Double = 56
    var hrvBaseline: Double = 48
    var maxHR: Double = 186

    var hrReserve: Double { max(20, maxHR - restingHR) }
}

struct SleepWindow: Equatable {
    var start: Int
    var end: Int
    var latency: Int
}

/// Поминутная точка тренировки (HKWorkout + HeartRate + Distance + StepCount)
struct WorkoutPoint: Codable, Equatable {
    var t: Int
    var hr: Double?
    var speed: Double        // м/с
    var cadence: Double      // шаг/мин
    var distance: Double     // м, накопительно
    var elevGain: Double     // м, накопительно
    var ele: Double?         // высота, м (если есть маршрут)
}

struct WorkoutRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var type: String
    var symbol: String
    var isRun: Bool
    var isBike: Bool
    var start: Int           // минуты от base
    var end: Int
    var startDate: Date
    var kcal: Double?
    var recovery1: Double?   // HeartRateRecoveryOneMinute
    var stream: [WorkoutPoint]

    var duration: Int { max(1, end - start) }
}

struct TimedValue: Codable, Equatable {
    var t: Int
    var value: Double
}

/// «Сырые» данные в форме, близкой к HealthKit, разложенные по 5-минутным слотам.
struct RawData {
    var base: Date
    var days: Int
    var heartRate: [Double?]      // средний пульс за слот
    var steps: [Double]           // шаги за слот
    var hrv: [TimedValue]         // SDNN, мс
    var sleep: [SleepStage?]      // стадия сна в слоте
    var respiratory: [TimedValue] // дыхание, вдох/мин
    var spo2: [TimedValue]
    var restingHR: [Double?]      // по дням
    var sleepWindows: [SleepWindow?] // ночь, закончившаяся в день k
    var workouts: [WorkoutRecord]     // тренировки отображаемой недели
    var allWorkouts: [WorkoutRecord]  // все тренировки за 90 дней (для VO2max)
    var vo2Apple: [TimedValue]        // HKQuantityTypeIdentifierVO2Max

    var slotCount: Int { heartRate.count }

    func date(_ minute: Int) -> Date { base.addingTimeInterval(TimeInterval(minute * 60)) }
    func minute(_ date: Date) -> Int { Int((date.timeIntervalSince(base) / 60).rounded(.down)) }
}

enum ActivityKind: String, Codable {
    case nodata, sleep, activity, rest, low, med, high

    var title: String {
        switch self {
        case .nodata: return "Нет данных"
        case .sleep: return "Сон"
        case .activity: return "Активность"
        case .rest: return "Отдых"
        case .low: return "Низкий стресс"
        case .med: return "Средний стресс"
        case .high: return "Высокий стресс"
        }
    }
}

struct EnergyParts: Codable, Equatable {
    var sleep = 0.0, rest = 0.0, base = 0.0, stress = 0.0, activity = 0.0
    var total: Double { sleep + rest + base + stress + activity }
}

struct EnergyPoint: Codable, Equatable {
    var m: Int
    var hr: Double?
    var steps: Double
    var hrv: Double?
    var stage: SleepStage?
    var kind: ActivityKind
    var stress: Int?
    var level: Double
    var parts: EnergyParts
}

struct SleepScoreComponent: Identifiable {
    var id: String { name }
    var name: String
    var max: Int
    var pts: Int
    var note: String
}

struct Night {
    var window: SleepWindow
    var hrvAvg: Double?
    var hrAvg: Double
    var qHRV: Double
    var qHR: Double
    var q: Double { qHRV * qHR }
    var stages: [SleepStage: Int]
    var charge: Double = 0
    var awakenings: Int
    var inBed: Int
    var asleep: Int
    var efficiency: Double
    var resp: Double?
    var hrMin: Double?
    var hrMinAt: Int?
    var segments: [(m: Int, stage: SleepStage)]
    var score: Int = 0
    var scoreParts: [SleepScoreComponent] = []

    var start: Int { window.start }
    var end: Int { window.end }
}

struct EnergyResult {
    var series: [EnergyPoint]
    var nights: [Night?]
}
