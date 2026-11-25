import Foundation
import SwiftUI
import UserNotifications

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Как в системе" : self == .light ? "Светлая" : "Тёмная" }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}

struct RunVO2: Identifiable {
    var id: UUID { workout.id }
    var workout: WorkoutRecord
    var analysis: WorkoutAnalysis
    var estimate: VO2Estimate
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum State: Equatable { case idle, needsAccess, loading, ready, failed(String) }

    @Published var state: State = .idle
    @Published var raw: RawData?
    @Published var profile = Profile()
    @Published var autoProfile = Profile()
    @Published var result: EnergyResult?
    @Published var workouts: [(WorkoutRecord, WorkoutAnalysis)] = []
    @Published var runs: [RunVO2] = []
    @Published var selectedDay = 7
    @Published var lastSync: Date?
    @Published var endMinute = 0

    @Published var theme: ThemeChoice = ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .light {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    @Published var authorized = UserDefaults.standard.bool(forKey: "authorized") {
        didSet { UserDefaults.standard.set(authorized, forKey: "authorized") }
    }
    @Published var overrideMaxHR = UserDefaults.standard.double(forKey: "overrideMaxHR") {
        didSet { UserDefaults.standard.set(overrideMaxHR, forKey: "overrideMaxHR") }
    }
    @Published var overrideRestingHR = UserDefaults.standard.double(forKey: "overrideRestingHR") {
        didSet { UserDefaults.standard.set(overrideRestingHR, forKey: "overrideRestingHR") }
    }
    @Published var lowAlert = (UserDefaults.standard.object(forKey: "lowAlert") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(lowAlert, forKey: "lowAlert") }
    }

    private let cache = WorkoutCache()
    private var refreshing = false

    init() {
        if !authorized { state = .needsAccess }
    }

    func connect() async {
        guard HealthService.isAvailable else { state = .failed("Apple Health недоступно на этом устройстве"); return }
        do {
            try await HealthService.shared.requestAuthorization()
            if !authorized {
                HealthService.shared.startBackgroundObservers { await AppModel.shared.refresh(background: true) }
            }
            authorized = true
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func applyOverrides() {
        var p = autoProfile
        if overrideMaxHR > 0 { p.maxHR = overrideMaxHR }
        if overrideRestingHR > 0 { p.restingHR = overrideRestingHR }
        profile = p
        recompute()
    }

    func refresh(background: Bool = false) async {
        guard authorized, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if raw == nil { state = .loading }
        let now = Date()
        do {
            let hs = HealthService.shared
            autoProfile = await hs.loadProfile(now: now)
            var p = autoProfile
            if overrideMaxHR > 0 { p.maxHR = overrideMaxHR }
            if overrideRestingHR > 0 { p.restingHR = overrideRestingHR }
            profile = p
            let r = try await hs.loadWeek(now: now, cache: cache)
            raw = r
            endMinute = r.minute(now)
            recompute()
            lastSync = now
            state = .ready
            if background { notifyIfLow() }
            await GitHubSync.sync(self)
        } catch {
            if raw == nil { state = .failed(error.localizedDescription) }
        }
    }

    func recompute() {
        guard let raw else { return }
        let res = EnergyEngine.compute(raw, profile: profile, endMinute: endMinute)
        result = res
        workouts = raw.workouts
            .filter { $0.start >= 1440 && $0.end <= endMinute }
            .map { ($0, WorkoutEngine.analyze($0, profile: profile)) }
            .reversed()
        runs = raw.allWorkouts.map { w in
            let a = WorkoutEngine.analyze(w, profile: profile)
            return RunVO2(workout: w, analysis: a, estimate: VO2Engine.estimate(w.stream, profile: profile))
        }.sorted { $0.workout.start > $1.workout.start }
        if let l = res.series.last?.level { UserDefaults.standard.set(l, forKey: "lastLevel") }
    }

    // MARK: Удобные выборки

    func summary(day k: Int) -> DaySummary? {
        guard let s = result?.series else { return nil }
        return DaySummary.make(s, day: k)
    }

    func night(endingOn k: Int) -> Night? {
        guard let n = result?.nights, k >= 0, k < n.count else { return nil }
        return n[k]
    }

    func dayDate(_ k: Int) -> Date {
        (raw?.base ?? Calendar.current.startOfDay(for: Date())).addingTimeInterval(TimeInterval(k * 86400))
    }

    func date(_ minute: Int) -> Date { (raw?.base ?? Date()).addingTimeInterval(TimeInterval(minute * 60)) }

    var currentVO2: Double? {
        VO2Engine.smoothed(runs.map { ($0.workout.start, $0.estimate) }, at: endMinute)
    }

    var currentLevel: Double? { result?.series.last?.level }

    private func notifyIfLow() {
        guard lowAlert, let l = currentLevel, l < 25 else { return }
        let key = "lowAlertDay"
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        let c = UNMutableNotificationContent()
        c.title = "Резерв \(Int(l))"
        c.body = "Запас энергии низкий. Хорошее время для отдыха."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low", content: c, trigger: nil))
    }
}
