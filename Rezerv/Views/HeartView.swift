import SwiftUI
import Charts

struct HeartView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DayStrip()
                    if let s = model.summary(day: model.selectedDay) {
                        let pts = s.points.filter { $0.hr != nil }
                        overview(pts)
                        dayChart(pts)
                        byState(pts)
                        zones(pts)
                    }
                    trends()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Пульс")
            .toolbar { SettingsButton() }
            .refreshable { await model.refresh() }
        }
    }

    private func overview(_ pts: [EnergyPoint]) -> some View {
        let hrs = pts.compactMap(\.hr)
        let rhr = model.raw?.restingHR[model.selectedDay] ?? nil
        return Card {
            HStack {
                Stat(label: "Покоя", value: rhr.map { "\(Int($0.rounded()))" } ?? "—", unit: "уд/мин", color: Palette.heart)
                Stat(label: "Средний", value: hrs.isEmpty ? "—" : "\(Int(mean(hrs).rounded()))", unit: "уд/мин")
                Stat(label: "Мин", value: hrs.min().map { "\(Int($0))" } ?? "—")
                Stat(label: "Макс", value: hrs.max().map { "\(Int($0))" } ?? "—")
            }
        }
    }

    private func dayChart(_ pts: [EnergyPoint]) -> some View {
        Card(title: "Пульс за сутки", subtitle: "Цвет точки показывает состояние") {
            Chart {
                ForEach(pts, id: \.m) { p in
                    PointMark(x: .value("Время", model.date(p.m)), y: .value("Пульс", p.hr ?? 0))
                        .symbolSize(10)
                        .foregroundStyle(Palette.kind(p.kind))
                }
                RuleMark(y: .value("Покоя", model.profile.restingHR))
                    .lineStyle(StrokeStyle(dash: [4])).foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
            }
            .frame(height: 200)
        }
    }

    private func byState(_ pts: [EnergyPoint]) -> some View {
        let order: [ActivityKind] = [.sleep, .rest, .low, .med, .high, .activity]
        let rows: [(ActivityKind, Double, Int)] = order.compactMap { k in
            let h = pts.filter { $0.kind == k }.compactMap(\.hr)
            return h.isEmpty ? nil : (k, mean(h), h.count * 5)
        }
        return Card(title: "Пульс по состояниям") {
            Chart {
                ForEach(rows, id: \.0) { r in
                    BarMark(x: .value("Пульс", r.1), y: .value("Состояние", r.0.title))
                        .foregroundStyle(Palette.kind(r.0))
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text("\(Int(r.1.rounded())) · \(Fmt.hm(r.2))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(rows.count) * 34 + 10)
        }
    }

    private func zones(_ pts: [EnergyPoint]) -> some View {
        var mins = [0, 0, 0, 0, 0]
        for p in pts { if let h = p.hr { let z = zoneIndex(h, maxHR: model.profile.maxHR); if z >= 0 { mins[z] += 5 } } }
        return Card(title: "Время в пульсовых зонах", subtitle: "Макс. пульс \(Int(model.profile.maxHR)) уд/мин") {
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.zones[i]).frame(width: 14, height: 14)
                    Text(hrZones[i].name).font(.subheadline)
                    Text("\(Int(hrZones[i].lo * model.profile.maxHR))+ · \(hrZones[i].note)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.hm(mins[i])).font(.subheadline).monospacedDigit()
                }
            }
        }
    }

    private func trends() -> some View {
        let rhr: [(Int, Double)] = (1...7).compactMap { k in (model.raw?.restingHR[k] ?? nil).map { (k, $0) } }
        let hrv: [(Int, Double)] = (1...7).compactMap { k in model.night(endingOn: k)?.hrvAvg.map { (k, $0) } }
        return Card(title: "Неделя: пульс покоя и HRV", subtitle: "HRV — среднее за ночь") {
            Chart {
                ForEach(rhr, id: \.0) { r in
                    LineMark(x: .value("День", Fmt.dayShort(model.dayDate(r.0))), y: .value("Значение", r.1), series: .value("Ряд", "Пульс покоя"))
                        .foregroundStyle(by: .value("Ряд", "Пульс покоя"))
                        .symbol(.circle)
                }
                ForEach(hrv, id: \.0) { r in
                    LineMark(x: .value("День", Fmt.dayShort(model.dayDate(r.0))), y: .value("Значение", r.1), series: .value("Ряд", "HRV"))
                        .foregroundStyle(by: .value("Ряд", "HRV"))
                        .symbol(.square)
                }
            }
            .chartForegroundStyleScale(["Пульс покоя": Palette.heart, "HRV": Palette.sleep])
            .frame(height: 170)
        }
    }
}
