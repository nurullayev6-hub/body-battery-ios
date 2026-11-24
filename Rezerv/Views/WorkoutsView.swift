import SwiftUI
import Charts

struct WorkoutsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Эта неделя") {
                    if model.workouts.isEmpty {
                        Text("Тренировок за неделю нет").foregroundStyle(.secondary)
                    }
                    ForEach(model.workouts, id: \.0.id) { item in
                        NavigationLink { WorkoutDetail(workout: item.0, a: item.1) } label: { WorkoutRow(w: item.0, a: item.1) }
                    }
                }
                let weekIds = Set(model.workouts.map(\.0.id))
                let older = model.runs.filter { !weekIds.contains($0.workout.id) }
                if !older.isEmpty {
                    Section("Пробежки за 90 дней") {
                        ForEach(older) { r in
                            NavigationLink { WorkoutDetail(workout: r.workout, a: r.analysis) } label: { WorkoutRow(w: r.workout, a: r.analysis) }
                        }
                    }
                }
            }
            .navigationTitle("Тренировки")
            .toolbar { SettingsButton() }
            .refreshable { await model.refresh() }
        }
    }
}

struct WorkoutRow: View {
    var w: WorkoutRecord
    var a: WorkoutAnalysis

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: w.symbol).foregroundStyle(.white).frame(width: 38, height: 38)
                .background(Circle().fill(Palette.activity))
            VStack(alignment: .leading, spacing: 2) {
                Text(w.type).font(.headline)
                Text(w.startDate.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute().locale(Fmt.ru)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if a.dist > 300 { Text("\(Fmt.one(a.dist / 1000)) км").font(.subheadline.weight(.semibold)) }
                Text(Fmt.hm(a.dur)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WorkoutDetail: View {
    @EnvironmentObject var model: AppModel
    var workout: WorkoutRecord
    var a: WorkoutAnalysis

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(workout.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Fmt.ru)))
                            .font(.caption).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                            GridRow {
                                Stat(label: "Время", value: Fmt.clock(Double(a.dur)))
                                if a.dist > 300 { Stat(label: "Дистанция", value: Fmt.one(a.dist / 1000), unit: "км") }
                                else { Stat(label: "Калории", value: "\(Int(a.kcal.rounded()))", unit: "ккал") }
                            }
                            GridRow {
                                if let p = a.pace { Stat(label: "Темп", value: Fmt.pace(p), unit: "/км") }
                                else if let v = a.speedKmh { Stat(label: "Скорость", value: Fmt.one(v), unit: "км/ч") }
                                else { Stat(label: "Нагрузка (TRIMP)", value: "\(Int(a.trimp.rounded()))") }
                                Stat(label: "Пульс ср./макс.", value: "\(a.avgHR) / \(a.maxHR)", color: Palette.heart)
                            }
                            GridRow {
                                Stat(label: "Эффект", value: a.effect)
                                Stat(label: "Восстановление 1 мин", value: a.recovery1.map { "−\(Int($0.rounded()))" } ?? "—", unit: "уд")
                            }
                            if a.run || a.dist > 300 {
                                GridRow {
                                    Stat(label: "Каденс", value: a.cadence > 0 ? "\(a.cadence)" : "—", unit: "шаг/мин")
                                    Stat(label: "Калории", value: "\(Int(a.kcal.rounded()))", unit: "ккал")
                                }
                            }
                        }
                    }
                }
                hrChart
                if a.run { paceChart; splits }
                zones
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(workout.type)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hrChart: some View {
        Card(title: "Пульс") {
            Chart {
                ForEach(a.stream.filter { $0.hr != nil }, id: \.t) { p in
                    LineMark(x: .value("Мин", p.t), y: .value("Пульс", p.hr ?? 0))
                        .foregroundStyle(Palette.heart)
                        .interpolationMethod(.monotone)
                }
                ForEach(0..<5, id: \.self) { i in
                    RuleMark(y: .value("Зона", hrZones[i].lo * model.profile.maxHR))
                        .foregroundStyle(Palette.zones[i].opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartXAxisLabel("минуты")
            .frame(height: 190)
        }
    }

    private var paceChart: some View {
        let pts = a.stream.indices.compactMap { i -> (Int, Double)? in
            let lo = max(0, i - 1), hi = min(a.stream.count - 1, i + 1)
            let sp = mean(a.stream[lo...hi].map(\.speed))
            return sp > 1.2 ? (a.stream[i].t, 1000 / sp / 60) : nil
        }
        return Card(title: "Темп", subtitle: "мин/км, ниже — быстрее") {
            Chart {
                ForEach(pts, id: \.0) { p in
                    LineMark(x: .value("Мин", p.0), y: .value("Темп", p.1))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .frame(height: 170)
        }
    }

    private var splits: some View {
        Card(title: "Отрезки по километрам") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Км").foregroundStyle(.secondary)
                    Text("Темп").foregroundStyle(.secondary)
                    Text("Пульс").foregroundStyle(.secondary)
                }
                .font(.caption)
                let best = a.splits.filter { !$0.partial }.map(\.sec).min() ?? 0
                ForEach(a.splits) { s in
                    GridRow {
                        Text(s.partial ? Fmt.one(s.km) : "\(Int(s.km))").monospacedDigit()
                        Text(Fmt.pace(s.sec)).monospacedDigit().fontWeight(s.sec == best ? .bold : .regular)
                        Text("\(s.hr)").monospacedDigit().foregroundStyle(Palette.heart)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var zones: some View {
        let total = max(1, a.zones.reduce(0, +))
        return Card(title: "Пульсовые зоны") {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Text(hrZones[i].name).font(.subheadline).frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 4).fill(Palette.zones[i])
                            .frame(width: max(2, g.size.width * CGFloat(a.zones[i]) / CGFloat(total)))
                    }
                    .frame(height: 14)
                    Text(Fmt.hm(a.zones[i])).font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}
