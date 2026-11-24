import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.state {
        case .needsAccess:
            OnboardingView()
        case .idle, .loading:
            if model.result == nil {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Читаю данные из Здоровья…").foregroundStyle(.secondary)
                }
                .task { if model.state == .idle { await model.refresh() } }
            } else { MainTabs() }
        case .failed(let msg):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Не удалось загрузить данные").font(.headline)
                Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Повторить") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .ready:
            MainTabs()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            EnergyView().tabItem { Label("Резерв", systemImage: "bolt.fill") }
            SleepView().tabItem { Label("Сон", systemImage: "bed.double.fill") }
            HeartView().tabItem { Label("Пульс", systemImage: "heart.fill") }
            WorkoutsView().tabItem { Label("Тренировки", systemImage: "figure.run") }
            VO2View().tabItem { Label("VO2max", systemImage: "lungs.fill") }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            LevelRing(level: 72, size: 180)
            Text("Резерв").font(.largeTitle.bold())
            Text("Запас энергии на день по данным Apple Watch и Здоровья: сон, пульс, вариабельность пульса, стресс и тренировки.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Данные читаются только на телефоне и никуда не отправляются", systemImage: "lock.fill")
                Label("Приложение ничего не записывает в Здоровье", systemImage: "eye")
                Label("Обновляется в фоне, когда приходят новые данные с часов", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.footnote)
            Spacer()
            Button {
                busy = true
                Task { await model.connect(); busy = false }
            } label: {
                HStack { if busy { ProgressView().tint(.white) }; Text("Подключить Здоровье") }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("На следующем экране включите все пункты чтения.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

/// Кнопка настроек в навбаре каждого экрана
struct SettingsButton: View {
    @State private var show = false
    var body: some View {
        Button { show = true } label: { Image(systemName: "gearshape") }
            .sheet(isPresented: $show) { SettingsView().environmentObject(AppModel.shared) }
    }
}
