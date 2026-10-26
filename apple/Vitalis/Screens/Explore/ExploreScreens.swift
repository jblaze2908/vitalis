import SwiftUI
import VitalisKit
import VitalisUI

/// The one place every `Detail` route resolves, so Today, Body and Train push identical screens.
struct DetailView: View {
    let route: Detail
    var body: some View {
        switch route {
        case .session(let id): SessionDetailScreen(store: .shared, id: id)
        case .exercise(let id): ExerciseDetailScreen(store: .shared, id: id)
        case .exercises: ExercisesScreen()
        case .metric(let key): MetricDetailScreen(key: key)
        case .heart(let day): HeartDayScreen(day: day)
        case .allData: AllDataScreen()
        }
    }
}

extension View {
    func detailDestinations() -> some View { navigationDestination(for: Detail.self) { DetailView(route: $0) } }
}

enum ExploreCopy {
    /// Relative where it reads better: Today, Yesterday, else `Mon 20 Oct`.
    static func day(_ day: String, today: String?) -> String {
        guard let today else { return MetricFormat.day(day, "EEE d MMM") }
        if day == today { return "Today" }
        if let t = TrainFormat.day(today), let d = TrainFormat.day(day), t.timeIntervalSince(d) == 86_400 { return "Yesterday" }
        return MetricFormat.day(day, "EEE d MMM")
    }

    static func color(_ key: String) -> Color {
        switch key {
        case "resting_hr", "heart_rate", "walking_hr", "hrv", "vo2max": VColor.pulse
        case "sleep_h", "deep_h", "rem_h", "respiratory_rate", "spo2", "wrist_temp": VColor.sleepCore
        case "weight_kg", "body_fat_pct": VColor.body
        default: VColor.bone
        }
    }

    /// Readings that share a story with this one, one tap away.
    static func related(_ key: String) -> [(String, Detail)] {
        switch key {
        case "resting_hr", "heart_rate", "walking_hr": [("Heart rate today", .heart(day: nil)), ("HRV", .metric(key: "hrv"))]
        case "hrv": [("Resting heart rate", .metric(key: "resting_hr")), ("Time asleep", .metric(key: "sleep_h"))]
        case "sleep_h": [("Deep sleep", .metric(key: "deep_h")), ("REM sleep", .metric(key: "rem_h")), ("HRV", .metric(key: "hrv"))]
        case "steps": [("Distance", .metric(key: "distance_km")), ("Active energy", .metric(key: "active_kcal"))]
        case "active_kcal": [("Exercise", .metric(key: "exercise_min")), ("Resting energy", .metric(key: "resting_kcal"))]
        case "weight_kg": [("Body fat", .metric(key: "body_fat_pct"))]
        default: []
        }
    }
}

// MARK: Metric history

/// Any metric over 7 days to a year: average against usual, an interactive chart, low/high, and the period before.
struct MetricDetailScreen: View {
    let key: String
    var store: ExploreStore = .shared
    @State private var days = 30
    /// nil = ending today.
    @State private var end: String?

    var body: some View {
        let l = store.metric(key, days: days, end: end), h = l.value
        DetailScaffold(h?.name ?? "History", subtitle: h.map { "\(MetricFormat.day($0.from)) – \(MetricFormat.day($0.to))" }) {
            HStack {
                PillPicker(ExploreStore.ranges.map { ($0, MetricFormat.rangeLabel(days: $0)) }, selection: $days)
                Spacer(minLength: 8)
                PeriodStepper(end == nil ? "To today" : "To \(MetricFormat.day(h?.to ?? ""))", back: h.map { prev in { end = prev.prevEnd } },
                              forward: h?.nextEnd.map { next in { end = next == h?.freshness?.today ? nil : next } })
            }
            .padding(.top, 6)
            if let h {
                summary(h).padding(.top, 18)
                VCard { HistoryChart(history: h, color: ExploreCopy.color(key)).frame(height: 220) }.padding(.top, 14)
                ReadoutRow([Readout("Low", MetricFormat.value(h.min, unit: h.unit)), Readout("High", MetricFormat.value(h.max, unit: h.unit)),
                            Readout("Days", "\(h.daysWithData)/\(h.days)")]).padding(.top, 14)
                if let u = h.usual {
                    Text("Your usual is \(MetricFormat.value(u.low, unit: h.unit))–\(MetricFormat.value(u.high, unit: h.unit))\(MetricFormat.unit(h.unit).map { " \($0)" } ?? ""), from \(u.days) days before \(MetricFormat.day(h.to)). The shaded band on the chart.")
                        .vUI(13, weight: 400, color: VColor.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
                let related = ExploreCopy.related(key)
                if !related.isEmpty {
                    DetailSection("Related")
                    RowsCard { ForEach(related, id: \.0) { title, route in DrillRow(title, route: route) } }
                }
            } else {
                LoadState(error: l.error) { Task { await store.loadMetric(key, days: days, end: end) } }.padding(.top, 40)
            }
        }
        .task(id: "\(days)|\(end ?? "")") { await store.loadMetric(key, days: days, end: end) }
    }

    private func summary(_ h: MetricHistory) -> some View {
        let delta = h.average.flatMap { a in h.previousAverage.map { a - $0 } }
        let better = delta.map { d in h.better == "neutral" || d == 0 ? VTone.usual : (d > 0) == (h.better == "higher") ? .good : .watch }
        return VStack(alignment: .leading, spacing: 8) {
            Text(h.every == "week" ? "Weekly average" : "Average").vUI(13, weight: 500, color: VColor.muted)
            Figure(MetricFormat.value(h.average, unit: h.unit), unit: MetricFormat.unit(h.unit), size: 44, color: h.average == nil ? VColor.steel : nil)
            if let delta, let better {
                StatusWord("\(MetricFormat.signed(delta, unit: h.unit)) vs the \(h.days) days before", tone: better)
            }
        }
    }
}

// MARK: Heart rate, one day

struct HeartDayScreen: View {
    var store: ExploreStore = .shared
    @State private var day: String?
    @State private var selected: Int?

    init(day: String?, store: ExploreStore = .shared) { _day = State(initialValue: day); self.store = store }

    var body: some View {
        let l = store.heart(day), h = l.value
        DetailScaffold("Heart rate", subtitle: h.map { ExploreCopy.day($0.day, today: $0.freshness?.today) }) {
            HStack {
                PeriodStepper(h.map { ExploreCopy.day($0.day, today: $0.freshness?.today) } ?? "–",
                              back: h.map { v in { day = v.prevDay } },
                              forward: h?.nextDay.map { n in { day = n == h?.freshness?.today ? nil : n } })
                Spacer()
            }
            if let h {
                let pick = selected.flatMap { s in h.points.min { abs($0.m - s) < abs($1.m - s) } }
                VStack(alignment: .leading, spacing: 6) {
                    Text(pick.map { "At \(MetricFormat.clock(minute: $0.m))" } ?? "Average").vUI(13, weight: 500, color: VColor.muted)
                    Figure(pick.map { String($0.avg) } ?? h.summary.avg.map(String.init) ?? "–", unit: "bpm", size: 44)
                    if pick == nil, let avg = h.summary.avg, let usual = h.summary.avgUsual {
                        StatusWord(avg == usual ? "Same as your usual day" : "\(abs(avg - usual)) \(avg > usual ? "above" : "below") your usual day (\(usual))", tone: .usual)
                    }
                }
                .padding(.top, 8)
                VCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HeartDayChart(day: h, selected: $selected).frame(height: 230)
                        HStack(spacing: 14) {
                            legend(VColor.sleepCore.opacity(0.5), "Asleep")
                            legend(VColor.pulse.opacity(0.5), "Workout")
                            Spacer()
                            Text("\(h.readings) readings").vUI(11, weight: 500, color: Color(hex: 0x6E6E6E))
                        }
                    }
                }
                .padding(.top, 14)
                ReadoutRow([
                    Readout("Low", h.summary.min.map(String.init) ?? "–", status: h.summary.minAt.map { ($0, .quiet) }),
                    Readout("High", h.summary.max.map(String.init) ?? "–", status: h.summary.maxAt.map { ($0, .quiet) }),
                    Readout("Resting", h.summary.resting?.value.map { String(Int($0.rounded())) } ?? "–",
                            status: MetricFormat.status(flag: h.summary.resting?.flag, reading: h.summary.resting?.reading, hasValue: h.summary.resting?.value != nil)),
                ])
                .padding(.top, 14)
                if !h.workouts.isEmpty {
                    DetailSection("Workouts")
                    RowsCard {
                        ForEach(h.workouts, id: \.id) { w in
                            DrillRow(.session(id: w.id), value: [w.avgBpm.map { "avg \($0)" }, w.maxBpm.map { "max \($0)" }].compactMap { $0 }.joined(separator: " · ")) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(WorkoutCopy.name(w.title)).vUI(15, weight: 500)
                                    Text("\(MetricFormat.clock(minute: w.startM))–\(MetricFormat.clock(minute: w.endM))").vUI(12, weight: 400, color: VColor.muted)
                                }
                            }
                        }
                    }
                }
                DetailSection("Over time")
                RowsCard {
                    DrillRow("Resting heart rate", route: .metric(key: "resting_hr"))
                    DrillRow("Daily range", route: .metric(key: "heart_rate"))
                    DrillRow("Walking heart rate", route: .metric(key: "walking_hr"))
                    DrillRow("HRV", route: .metric(key: "hrv"))
                }
            } else {
                LoadState(error: l.error) { Task { await store.loadHeart(day) } }.padding(.top, 40)
            }
        }
        .task(id: day ?? "") { selected = nil; await store.loadHeart(day) }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text(text).vUI(11, weight: 500, color: VColor.muted) }
    }
}

/// Today's heart rate as a card: the day's line, average and range; opens the full day.
struct HeartTodayCard: View {
    let store: ExploreStore
    let live: Bool

    var body: some View {
        let h = store.heart(nil).value
        let resting = h?.summary.resting
        NavigationLink(value: Detail.heart(day: nil)) {
            VCard {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader("Heart rate today", status: resting?.value.map { ("Resting \(Int($0.rounded()))", MetricFormat.status(flag: resting?.flag, reading: resting?.reading, hasValue: true)?.1 ?? .usual) })
                    Sparkline(sparkValues(h), tone: .load).frame(height: 34)
                    HStack(alignment: .firstTextBaseline) {
                        Figure(h?.summary.avg.map(String.init) ?? "–", unit: "avg bpm", color: h?.summary.avg == nil ? VColor.steel : nil)
                        Spacer()
                        if let lo = h?.summary.min, let hi = h?.summary.max { Text("\(lo)–\(hi) bpm").vUI(13, weight: 500, color: VColor.muted) }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { if live { await store.loadHeart(nil) } }
    }

    /// One value per half hour so the card reads as a shape, not noise; gaps stay gaps.
    private func sparkValues(_ h: HeartDay?) -> [Double?] {
        guard let h else { return [] }
        let last = (h.nowM ?? 1440) / 30
        return (0..<max(last, 1)).map { slot in
            let xs = h.points.filter { $0.m / 30 == slot }.map { Double($0.avg) }
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
    }
}

// MARK: Everything tracked

struct AllDataScreen: View {
    var store: ExploreStore = .shared

    var body: some View {
        let o = store.overview.value
        DetailScaffold("All health data", subtitle: "Latest reading against your usual") {
            if let o {
                ForEach(o.groups, id: \.name) { g in
                    DetailSection(g.name)
                    RowsCard {
                        if g.name == "Heart" {
                            DrillRow("Heart rate today", route: .heart(day: nil), value: "Curve")
                        }
                        ForEach(g.metrics, id: \.key) { m in MetricRow(metric: m, today: o.day) }
                    }
                }
            } else {
                LoadState(error: store.overview.error) { Task { await store.loadOverview() } }.padding(.top, 40)
            }
        }
        .task { await store.loadOverview() }
    }
}

private struct MetricRow: View {
    let metric: MetricsOverview.Metric
    let today: String

    var body: some View {
        let status = MetricFormat.status(flag: metric.flag, reading: metric.reading, hasValue: metric.value != nil)
        let usual = metric.usualRange.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
        NavigationLink(value: Detail.metric(key: metric.key)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.name).vUI(15, weight: 500).lineLimit(1)
                    Text(subtitle).vUI(12, weight: 400, color: VColor.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if metric.value != nil {
                    Sparkline(metric.spark, usual: usual, tone: status?.1 ?? .usual).frame(width: 64, height: 22)
                    Circle().fill((status?.1 ?? .usual).color).frame(width: 7, height: 7)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
            }
            .padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        guard let v = metric.value, let day = metric.day else { return "Nothing recorded in 2 weeks" }
        let value = [MetricFormat.value(v, unit: metric.unit), MetricFormat.unit(metric.unit)].compactMap { $0 }.joined(separator: " ")
        return day == today ? value : "\(value) · \(ExploreCopy.day(day, today: today))"
    }
}

// MARK: Exercises

struct ExercisesScreen: View {
    var store: ExploreStore = .shared

    var body: some View {
        let e = store.exercises.value
        DetailScaffold("Exercises", subtitle: e.map { TrainFormat.plural($0.count, "exercise", "exercises") + " logged" }) {
            if let e {
                if e.exercises.isEmpty {
                    Text("Every exercise you log shows up here with its progress.").vUI(15, weight: 400, color: VColor.muted).padding(.top, 24)
                } else {
                    RowsCard { ForEach(e.exercises, id: \.id) { x in ExerciseProgressRow(exercise: x, today: e.freshness?.today) } }.padding(.top, 8)
                }
            } else {
                LoadState(error: store.exercises.error) { Task { await store.loadExercises() } }.padding(.top, 40)
            }
        }
        .task(id: Services.shared.writesVersion) { await store.loadExercises() }
    }
}

private struct ExerciseProgressRow: View {
    let exercise: PerformedExercises.Exercise
    let today: String?

    var body: some View {
        NavigationLink(value: Detail.exercise(id: exercise.id)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name).vUI(15, weight: 500).lineLimit(1)
                    Text(subtitle).vUI(12, weight: 400, color: VColor.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if exercise.spark.count > 1 { Sparkline(exercise.spark.map { $0 }, tone: .usual).frame(width: 52, height: 20) }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(exercise.e1rmKg.map { "\(TrainFormat.kg($0)) kg" } ?? TrainFormat.dash).vUI(14, weight: 600)
                    if let c = exercise.change8wKg, c != 0 {
                        Text("\(c > 0 ? "+" : "−")\(TrainFormat.kg(abs(c))) in 8 wk").vUI(11, weight: 500, color: c > 0 ? VColor.good : VColor.muted)
                    } else {
                        Text("e1RM").vUI(11, weight: 500, color: Color(hex: 0x6E6E6E))
                    }
                }
                .frame(minWidth: 66, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
            }
            .padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let top = TrainFormat.set(exercise.lastTop?.weightKg, exercise.lastTop?.reps).map { " · top \($0)" } ?? ""
        return "\(ExploreCopy.day(exercise.lastDay, today: today))\(top)"
    }
}

/// HealthKit's activity names arrive camelCased (`traditionalStrengthTraining`); show them as words.
enum WorkoutCopy {
    static func name(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }
}

/// Spinner while the first answer is on its way; a retry once a fetch failed with nothing cached.
struct LoadState: View {
    let error: Error?
    let retry: () -> Void
    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 12) {
                Text((error as? APIError) == .notFound ? "Nothing here yet." : "Couldn't reach your server.").vUI(15, weight: 500, color: VColor.muted)
                if (error as? APIError) != .notFound { SecondaryButton("Try again", action: retry) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView().tint(VColor.muted).frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
@MainActor enum ExplorePreviewData {
    static func store() -> ExploreStore {
        let s = ExploreStore(api: { nil })
        s.preload(overview: TrainPreviewData.decode(MetricsOverview.self, TrainPreviewData.json("metrics")),
                  exercises: TrainPreviewData.decode(PerformedExercises.self, TrainPreviewData.json("training-exercises")),
                  metric: TrainPreviewData.decode(MetricHistory.self, TrainPreviewData.json("metric")),
                  heart: TrainPreviewData.decode(HeartDay.self, TrainPreviewData.json("heart")))
        return s
    }
}
#Preview("All health data") { NavigationStack { AllDataScreen(store: ExplorePreviewData.store()).detailDestinations() }.onAppear { VFont.register() } }
#Preview("Metric history") { NavigationStack { MetricDetailScreen(key: "resting_hr", store: ExplorePreviewData.store()) }.onAppear { VFont.register() } }
#Preview("Heart rate day") { NavigationStack { HeartDayScreen(day: nil, store: ExplorePreviewData.store()) }.onAppear { VFont.register() } }
#Preview("Exercises") { NavigationStack { ExercisesScreen(store: ExplorePreviewData.store()) }.onAppear { VFont.register() } }
#endif
