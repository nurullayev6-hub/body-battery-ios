import SwiftUI
import Charts

struct SleepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DayStrip()
                    if let n = model.night(endingOn: model.selectedDay) {
                        score(n)
                        hypnogram(n)
                        stages(n)
                        metrics(n)
                        components(n)
                    } else {
                        Card { Text("Нет записи сна за эту ночь. Сон с этапами пишут Apple Watch, если носить их ночью.").foregroundStyle(.secondary) }
                    }
                    trend()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Сон")
            .toolbar { SettingsButton() }
            .refreshable { await model.refresh() }
        }
    }

    private func score(_ n: Night) -> some View {
        Card {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                    Circle().trim(from: 0, to: Double(n.score) / 100)
                        .stroke(Palette.sleep, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(n.score)").font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("из 100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(n.score >= 85 ? "Отличный сон" : n.score >= 70 ? "Хороший сон" : n.score >= 55 ? "Средний сон" : "Слабый сон")
                        .font(.title3.weight(.semibold))
                    Text("\(Fmt.time(model.date(n.start)))–\(Fmt.time(model.date(n.end)))").foregroundStyle(.secondary)
                    Text("Сон \(Fmt.hm(n.asleep)), заряд \(Fmt.signed(n.charge))").font(.footnote)
                }
            }
        }
    }

    private func hypnogram(_ n: Night) -> some View {
        let order: [SleepStage] = [.awake, .rem, .core, .deep]
        return Card(title: "Стадии сна") {
            Chart {
                ForEach(n.segments, id: \.m) { s in
                    RectangleMark(xStart: .value("с", model.date(s.m)), xEnd: .value("по", model.date(s.m + 5)),
                                  y: .value("Стадия", s.stage.title))
                        .foregroundStyle(Palette.stage(s.stage))
                        .cornerRadius(2)
                }
            }
            .chartYScale(domain: order.map(\.title))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
            }
            .frame(height: 170)
        }
    }

    private func stages(_ n: Night) -> some View {
        let asleep = max(1, n.asleep)
        return Card(title: "Распределение") {
            ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { st in
                let m = n.stages[st] ?? 0
                HStack {
                    Circle().fill(Palette.stage(st)).frame(width: 10, height: 10)
                    Text(st.title)
                    Spacer()
                    Text(Fmt.hm(m)).monospacedDigit()
                    if st != .awake {
                        Text("\(Int((Double(m) / Double(asleep) * 100).rounded()))%")
                            .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing).monospacedDigit()
                    } else {
                        Text("").frame(width: 44)
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func metrics(_ n: Night) -> some View {
        Card(title: "Показатели ночи") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Stat(label: "HRV (SDNN)", value: n.hrvAvg.map { "\(Int($0.rounded()))" } ?? "—", unit: "мс")
                    Stat(label: "Норма HRV", value: "\(Int(model.profile.hrvBaseline.rounded()))", unit: "мс")
                }
                GridRow {
                    Stat(label: "Пульс средний", value: "\(Int(n.hrAvg.rounded()))", unit: "уд/мин")
                    Stat(label: "Пульс минимум", value: n.hrMin.map { "\(Int($0))" } ?? "—", unit: "уд/мин")
                }
                GridRow {
                    Stat(label: "Дыхание", value: n.resp.map { Fmt.one($0) } ?? "—", unit: "вд/мин")
                    Stat(label: "Пробуждения", value: "\(n.awakenings)")
                }
                GridRow {
                    Stat(label: "Эффективность", value: "\(Int((n.efficiency * 100).rounded()))", unit: "%")
                    Stat(label: "Засыпание", value: "\(n.window.latency)", unit: "мин")
                }
            }
        }
    }

    private func components(_ n: Night) -> some View {
        Card(title: "Из чего сложилась оценка") {
            ForEach(n.scoreParts) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.name).font(.subheadline)
                        Spacer()
                        Text("\(c.pts) / \(c.max)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    ProgressView(value: Double(c.pts), total: Double(c.max)).tint(Palette.sleep)
                    Text(c.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func trend() -> some View {
        let items: [(Int, Night)] = (1...7).compactMap { k in model.night(endingOn: k).map { (k, $0) } }
        return Card(title: "Сон за неделю") {
            Chart {
                ForEach(items, id: \.0) { item in
                    BarMark(x: .value("День", Fmt.dayShort(model.dayDate(item.0))), y: .value("Часы", Double(item.1.asleep) / 60))
                        .foregroundStyle(Palette.sleep.opacity(item.0 == model.selectedDay ? 1 : 0.5))
                        .annotation(position: .top) { Text("\(item.1.score)").font(.caption2).foregroundStyle(.secondary) }
                }
                RuleMark(y: .value("Цель", 8)).lineStyle(StrokeStyle(dash: [4])).foregroundStyle(.secondary)
            }
            .frame(height: 160)
        }
    }
}
