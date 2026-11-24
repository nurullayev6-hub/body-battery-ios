import SwiftUI
import Charts

struct VO2View: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    current
                    trend
                    races
                    runsList
                    method
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("VO2max")
            .toolbar { SettingsButton() }
            .refreshable { await model.refresh() }
        }
    }

    private var appleLatest: Double? { model.raw?.vo2Apple.last?.value }

    private var current: some View {
        Card {
            if let v = model.currentVO2 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.one(v)).font(.system(size: 56, weight: .bold, design: .rounded))
                        Text("мл/кг/мин").foregroundStyle(.secondary)
                    }
                    Text("Уровень: \(VO2Engine.category(v, age: model.profile.age))").font(.headline).foregroundStyle(Palette.accent)
                    HStack {
                        Stat(label: "Кардиофитнес Apple", value: appleLatest.map { Fmt.one($0) } ?? "—")
                        Stat(label: "Пробежек в расчёте", value: "\(model.runs.filter { $0.estimate.value != nil && model.endMinute - $0.workout.start <= 30 * 1440 }.count)")
                    }
                    Text("Оценка по связи пульса и скорости на ровных участках пробежек за 30 дней. Свежие пробежки весят больше.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Нужна хотя бы одна пробежка на улице от 15 минут с Apple Watch за последние 30 дней.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trend: some View {
        let est = model.runs.compactMap { r in r.estimate.value.map { (r.workout.startDate, $0) } }
        let apple = (model.raw?.vo2Apple ?? []).map { (model.date($0.t), $0.value) }
        return Card(title: "Динамика за 90 дней") {
            Chart {
                ForEach(est, id: \.0) { p in
                    PointMark(x: .value("Дата", p.0), y: .value("VO2max", p.1))
                        .foregroundStyle(by: .value("Источник", "По пробежке"))
                }
                ForEach(apple, id: \.0) { p in
                    LineMark(x: .value("Дата", p.0), y: .value("VO2max", p.1))
                        .foregroundStyle(by: .value("Источник", "Apple"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["По пробежке": Palette.accent, "Apple": Color.gray])
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 190)
        }
    }

    private var races: some View {
        Card(title: "Прогноз на дистанциях", subtitle: "По формулам Дэниелса, при хорошей подготовке к дистанции") {
            if let v = model.currentVO2 {
                ForEach([(5000.0, "5 км"), (10000, "10 км"), (21097.5, "Полумарафон"), (42195, "Марафон")], id: \.0) { d in
                    let t = VO2Engine.raceTime(vo2max: v, meters: d.0)
                    HStack {
                        Text(d.1)
                        Spacer()
                        Text(Fmt.clock(t)).font(.headline).monospacedDigit()
                        Text(Fmt.pace(t * 60 / (d.0 / 1000)) + "/км").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private var runsList: some View {
        Card(title: "Оценка по каждой пробежке") {
            ForEach(model.runs.prefix(15)) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.workout.startDate.formatted(.dateTime.day().month().locale(Fmt.ru)))
                            .font(.subheadline)
                        Text("\(Fmt.one(r.analysis.dist / 1000)) км, \(Fmt.hm(r.analysis.dur))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let v = r.estimate.value {
                        VStack(alignment: .trailing) {
                            Text(Fmt.one(v)).font(.headline).monospacedDigit()
                            Text("\(r.estimate.valid) уст. мин").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(r.estimate.reason ?? "нет оценки").font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var method: some View {
        Card(title: "Как считается") {
            Text("""
            1. Берём минуты пробежки после 10-минутной разминки, где скорость ровная (разброс < 6%) и пульс 55–95% резерва.
            2. Кислородная стоимость бега по скорости — уравнение Дэниелса–Гилберта.
            3. VO2max = (VO2 − 3,5) / доля резерва пульса + 3,5, медиана по минутам; при хорошей линейной связи добавляем экстраполяцию до макс. пульса.
            4. Итог — взвешенное среднее за 30 дней.
            Это оценка, а не лабораторный тест. Ошибка обычно 3–5 единиц.
            """)
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
