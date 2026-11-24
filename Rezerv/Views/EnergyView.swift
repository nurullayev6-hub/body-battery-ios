import SwiftUI
import Charts

struct EnergyView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DayStrip()
                    if let s = model.summary(day: model.selectedDay) {
                        header(s)
                        LevelChart(points: s.points, base: model.raw?.base ?? Date())
                        balance(s)
                        states(s)
                        week()
                        events(s)
                    } else {
                        Card { Text("За этот день нет данных.").foregroundStyle(.secondary) }
                    }
                    if let t = model.lastSync {
                        Text("Синхронизировано в \(Fmt.time(t))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Резерв")
            .toolbar { SettingsButton() }
            .refreshable { await model.refresh() }
        }
    }

    private func header(_ s: DaySummary) -> some View {
        Card {
            VStack(spacing: 14) {
                LevelRing(level: s.current, size: 190)
                    .frame(maxWidth: .infinity)
                Text(model.selectedDay == 7 ? "Сейчас" : "Конец дня, \(Fmt.dayLong(model.dayDate(model.selectedDay)))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stat(label: "Максимум", value: "\(Int(s.high.rounded()))")
                    Stat(label: "Минимум", value: "\(Int(s.low.rounded()))")
                    Stat(label: "Заряд", value: Fmt.signed(s.charged), color: Palette.rest)
                    Stat(label: "Расход", value: Fmt.signed(s.drained), color: Palette.high)
                }
            }
        }
    }

    private func balance(_ s: DaySummary) -> some View {
        Card(title: "Откуда заряд и куда ушло", subtitle: "Единицы резерва за день") {
            Chart {
                ForEach(s.bySource, id: \.0) { item in
                    BarMark(x: .value("Ед.", item.1), y: .value("Источник", item.0))
                        .foregroundStyle(item.1 >= 0 ? Palette.rest : Palette.high)
                        .annotation(position: item.1 >= 0 ? .trailing : .leading) {
                            Text(Fmt.signed(item.1)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 170)
        }
    }

    private func states(_ s: DaySummary) -> some View {
        let order: [ActivityKind] = [.sleep, .rest, .low, .med, .high, .activity]
        let total = max(1, order.reduce(0) { $0 + (s.minutesByKind[$1] ?? 0) })
        return Card(title: "Состояние за день", subtitle: s.avgStress.map { "Средний стресс в покое: \($0) из 100" }) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(order, id: \.self) { k in
                        let m = s.minutesByKind[k] ?? 0
                        if m > 0 {
                            Rectangle().fill(Palette.kind(k))
                                .frame(width: max(2, g.size.width * CGFloat(m) / CGFloat(total) - 2))
                        }
                    }
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(order, id: \.self) { k in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.kind(k)).frame(width: 8, height: 8)
                        Text(k.title).font(.caption)
                        Spacer()
                        Text(Fmt.hm(s.minutesByKind[k] ?? 0)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func week() -> some View {
        let days = (1...7).compactMap { model.summary(day: $0) }
        return Card(title: "Неделя", subtitle: "Диапазон резерва по дням") {
            Chart {
                ForEach(days, id: \.day) { d in
                    BarMark(x: .value("День", Fmt.dayShort(model.dayDate(d.day))),
                            yStart: .value("Мин", d.low), yEnd: .value("Макс", d.high), width: 18)
                        .foregroundStyle(Palette.level(d.high).gradient)
                        .cornerRadius(9)
                        .opacity(d.day == model.selectedDay ? 1 : 0.55)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 150)
        }
    }

    private func events(_ s: DaySummary) -> some View {
        let k = model.selectedDay
        let night = model.night(endingOn: k)
        let wos = (model.raw?.workouts ?? []).filter { $0.start / 1440 == k }
        return Card(title: "События дня") {
            VStack(alignment: .leading, spacing: 12) {
                if let n = night {
                    eventRow(icon: "moon.fill", color: Palette.sleep, title: "Сон \(Fmt.hm(n.asleep))",
                             detail: "\(Fmt.time(model.date(n.start)))–\(Fmt.time(model.date(n.end))), оценка \(n.score)",
                             delta: n.charge)
                }
                ForEach(wos) { w in
                    let drain = s.points.filter { $0.m >= w.start && $0.m < w.end + EnergyConfig.postWorkoutMin }
                        .reduce(0) { $0 + $1.parts.activity }
                    eventRow(icon: w.symbol, color: Palette.activity, title: w.type,
                             detail: "\(Fmt.time(w.startDate)), \(Fmt.hm(w.duration))", delta: drain)
                }
                if night == nil && wos.isEmpty {
                    Text("Нет сна и тренировок за этот день.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func eventRow(icon: String, color: Color, title: String, detail: String, delta: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 34, height: 34)
                .background(Circle().fill(color))
            VStack(alignment: .leading) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.signed(delta)).font(.headline).monospacedDigit()
                .foregroundStyle(delta >= 0 ? Palette.rest : Palette.high)
        }
    }
}

/// График уровня за сутки с полосой состояний снизу
struct LevelChart: View {
    var points: [EnergyPoint]
    var base: Date

    private func d(_ m: Int) -> Date { base.addingTimeInterval(TimeInterval(m * 60)) }

    var body: some View {
        Card(title: "Уровень за сутки") {
            Chart {
                ForEach(points, id: \.m) { p in
                    AreaMark(x: .value("Время", d(p.m)), y: .value("Резерв", p.level))
                        .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.35), Palette.accent.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Время", d(p.m)), y: .value("Резерв", p.level))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                    RectangleMark(xStart: .value("с", d(p.m)), xEnd: .value("по", d(p.m + 5)),
                                  yStart: .value("н", -12), yEnd: .value("в", -4))
                        .foregroundStyle(Palette.kind(p.kind))
                }
            }
            .chartYScale(domain: -12...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { _ in AxisGridLine(); AxisValueLabel() }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 220)
        }
    }
}
