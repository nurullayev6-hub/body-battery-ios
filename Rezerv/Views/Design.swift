import SwiftUI

enum Palette {
    static let accent = Color(red: 0.13, green: 0.55, blue: 0.47)
    static let sleep = Color(red: 0.36, green: 0.38, blue: 0.85)
    static let deep = Color(red: 0.22, green: 0.24, blue: 0.66)
    static let core = Color(red: 0.42, green: 0.50, blue: 0.93)
    static let rem = Color(red: 0.55, green: 0.72, blue: 0.98)
    static let awake = Color(red: 0.96, green: 0.62, blue: 0.35)
    static let rest = Color(red: 0.20, green: 0.70, blue: 0.55)
    static let low = Color(red: 0.98, green: 0.78, blue: 0.35)
    static let med = Color(red: 0.96, green: 0.56, blue: 0.25)
    static let high = Color(red: 0.88, green: 0.30, blue: 0.25)
    static let activity = Color(red: 0.93, green: 0.35, blue: 0.52)
    static let nodata = Color.gray.opacity(0.35)
    static let heart = Color(red: 0.90, green: 0.25, blue: 0.30)

    static func level(_ v: Double) -> Color {
        v >= 76 ? Color(red: 0.13, green: 0.60, blue: 0.45)
        : v >= 51 ? Color(red: 0.36, green: 0.70, blue: 0.40)
        : v >= 26 ? Color(red: 0.95, green: 0.65, blue: 0.25)
        : Color(red: 0.88, green: 0.32, blue: 0.27)
    }

    static func kind(_ k: ActivityKind) -> Color {
        switch k {
        case .nodata: return nodata
        case .sleep: return sleep
        case .activity: return activity
        case .rest: return rest
        case .low: return low
        case .med: return med
        case .high: return high
        }
    }

    static func stage(_ s: SleepStage) -> Color {
        switch s { case .deep: return deep; case .core: return core; case .rem: return rem; case .awake: return awake }
    }

    static let zones: [Color] = [
        Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.30, green: 0.70, blue: 0.50),
        Color(red: 0.95, green: 0.75, blue: 0.30), Color(red: 0.95, green: 0.50, blue: 0.25), Color(red: 0.88, green: 0.28, blue: 0.28),
    ]
}

func levelWord(_ v: Double) -> String {
    v >= 76 ? "Высокий запас" : v >= 51 ? "Хороший запас" : v >= 26 ? "Умеренный запас" : "Низкий запас"
}

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(ru)) }
    static func dayShort(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).locale(ru)) }
    static func dayLong(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(ru)) }
    static func dayNum(_ d: Date) -> String { d.formatted(.dateTime.day().locale(ru)) }

    static func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
    static func pace(_ secPerKm: Double) -> String {
        let s = Int(secPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func clock(_ minutes: Double) -> String {
        let s = Int((minutes * 60).rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func one(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + String(Int(abs(v).rounded())) }
}

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct Stat: View {
    var label: String
    var value: String
    var unit: String = ""
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).foregroundStyle(color).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Кольцо уровня резерва
struct LevelRing: View {
    var level: Double
    var size: CGFloat = 200

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: size * 0.09)
            Circle()
                .trim(from: 0, to: max(0.01, level / 100))
                .stroke(AngularGradient(colors: [Palette.level(level).opacity(0.6), Palette.level(level)], center: .center),
                        style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(level.rounded()))")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(levelWord(level)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut, value: level)
    }
}

/// Полоса выбора дня недели (1…7)
struct DayStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { k in
                let d = model.dayDate(k)
                let sel = model.selectedDay == k
                Button {
                    model.selectedDay = k
                } label: {
                    VStack(spacing: 2) {
                        Text(k == 7 ? "Сег." : Fmt.dayShort(d)).font(.caption2)
                        Text(Fmt.dayNum(d)).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(sel ? Palette.accent : Color(.secondarySystemGroupedBackground)))
                    .foregroundStyle(sel ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
