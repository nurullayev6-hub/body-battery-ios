import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var maxHR = ""
    @State private var restHR = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Оформление") {
                    Picker("Тема", selection: $model.theme) {
                        ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("Возраст", value: "\(model.profile.age)")
                    LabeledContent("Вес", value: "\(Fmt.one(model.profile.weight)) кг")
                    LabeledContent("Норма HRV (30 дней)", value: "\(Fmt.one(model.profile.hrvBaseline)) мс")
                    HStack {
                        Text("Пульс покоя")
                        Spacer()
                        TextField("\(Int(model.autoProfile.restingHR))", text: $restHR)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                    }
                    HStack {
                        Text("Макс. пульс")
                        Spacer()
                        TextField("\(Int(model.autoProfile.maxHR))", text: $maxHR)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                    }
                    Button("Применить") {
                        model.overrideMaxHR = Double(maxHR) ?? 0
                        model.overrideRestingHR = Double(restHR) ?? 0
                        model.applyOverrides()
                    }
                } header: {
                    Text("Профиль")
                } footer: {
                    Text("Значения берутся из Здоровья автоматически. Пустое поле — автоматическое значение. Если знаете свой максимальный пульс по тесту, впишите его: от него зависят зоны и VO2max.")
                }

                AnalysisSyncSection()

                Section("Синхронизация") {
                    Toggle("Уведомлять при резерве ниже 25", isOn: $model.lowAlert)
                    Button("Обновить сейчас") { Task { await model.refresh() } }
                    if let t = model.lastSync { LabeledContent("Последняя", value: Fmt.time(t)) }
                }

                Section("Как считается резерв") {
                    Text("""
                    Уровень от 5 до 100 пересчитывается каждые 5 минут.
                    • Сон заряжает: глубокий 15 ед/ч, основной 10,5, REM 8,5. Скорость умножается на качество ночи (HRV и пульс во сне относительно вашей нормы) и замедляется у верхней границы.
                    • Спокойное бодрствование (стресс ≤ 25) заряжает 2,5 ед/ч.
                    • Любое бодрствование расходует 1,5 ед/ч, стресс добавляет 1–4 ед/ч.
                    • Стресс 0–100 считается по пульсу выше пульса покоя (75%) и HRV ниже нормы (25%).
                    • Движение и тренировки расходуют пропорционально нагрузке TRIMP (по Банистеру).
                    Это собственная приближённая модель, а не алгоритм Garmin.
                    """)
                    .font(.footnote)
                }

                Section {
                    Text("Все расчёты выполняются на телефоне. Приложение только читает данные Здоровья и никуда их не отправляет.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .onAppear {
                maxHR = model.overrideMaxHR > 0 ? "\(Int(model.overrideMaxHR))" : ""
                restHR = model.overrideRestingHR > 0 ? "\(Int(model.overrideRestingHR))" : ""
            }
        }
    }
}

/// Отправка данных для анализа: закрытый репозиторий GitHub + ручной файл
struct AnalysisSyncSection: View {
    @EnvironmentObject var model: AppModel
    @State private var repo = GitHubSync.repo
    @State private var token = ""
    @State private var auto = GitHubSync.auto
    @State private var busy = false
    @State private var note = ""
    @State private var shareURL: URL?

    var body: some View {
        Section {
            TextField("владелец/репозиторий", text: $repo)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(GitHubSync.token == nil ? "Токен GitHub" : "Токен сохранён, ввести новый", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Отправлять автоматически", isOn: $auto)
                .onChange(of: auto) { _, v in GitHubSync.auto = v }
            Button("Сохранить и отправить сейчас") {
                GitHubSync.repo = repo
                if !token.isEmpty { GitHubSync.setToken(token); token = "" }
                run { await GitHubSync.sync(model, force: true); note = GitHubSync.status }
            }
            .disabled(busy || repo.isEmpty)
            Button("Отправить историю за 90 дней") {
                run { await GitHubSync.backfill(model) { note = $0 } }
            }
            .disabled(busy || !GitHubSync.isConfigured)
            if busy { HStack { ProgressView(); Text(note.isEmpty ? "Отправляю…" : note).font(.footnote) } }
            else if !note.isEmpty || !GitHubSync.status.isEmpty {
                Text(note.isEmpty ? GitHubSync.status : note).font(.footnote).foregroundStyle(.secondary)
            }
            if let t = GitHubSync.lastSync { LabeledContent("Последняя отправка", value: Fmt.time(t)) }
            if let url = shareURL {
                ShareLink(item: url) { Label("Поделиться файлом за 7 дней", systemImage: "square.and.arrow.up") }
            } else {
                Button { shareURL = AnalysisExport.fileURL(model) } label: {
                    Label("Подготовить файл за 7 дней", systemImage: "doc.badge.arrow.up")
                }
            }
        } header: {
            Text("Данные для анализа")
        } footer: {
            Text("Резерв сам отправляет сводку и 5-минутные данные за 7 дней в ваш закрытый репозиторий GitHub, откуда их читает Claude. Токен хранится в Связке ключей iPhone и уходит только на api.github.com. В открытый репозиторий отправка запрещена.")
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true; note = ""
        Task { await work(); busy = false }
    }
}
