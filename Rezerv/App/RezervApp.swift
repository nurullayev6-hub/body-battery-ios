import SwiftUI
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTask = "app.rezerv.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Наблюдатели HealthKit должны запускаться при каждом старте, иначе фоновая доставка не работает
        if UserDefaults.standard.bool(forKey: "authorized") && HealthService.isAvailable {
            HealthService.shared.startBackgroundObservers {
                await AppModel.shared.refresh(background: true)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task { await AppModel.shared.refresh(background: true); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
        }
        Self.scheduleRefresh()
        return true
    }

    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}

@main
struct RezervApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.theme.scheme)
                .tint(Palette.accent)
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await model.refresh() } }
        }
    }
}
