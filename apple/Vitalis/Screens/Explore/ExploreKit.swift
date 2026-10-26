import Charts
import SwiftUI
import VitalisKit
import VitalisUI

/// Every pushed screen: a pinned back + title bar over a scrolling body, so the way back never scrolls away.
/// Content sits on the 16 gutter; pull to refresh reloads the screen's read.
struct DetailScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let refresh: () async -> Void
    let trailing: Trailing
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router: Router?

    init(_ title: String, subtitle: String? = nil, refresh: @escaping () async -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.refresh = refresh; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VSpace.s1) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(VColor.text)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).vText(.title).lineLimit(1).minimumScaleFactor(0.8)
                    if let subtitle { Text(subtitle).vText(.secondary).lineLimit(1) }
                }
                Spacer(minLength: VSpace.s2)
                trailing
            }
            .padding(.leading, VSpace.s1).padding(.trailing, VSpace.edge).padding(.top, VSpace.s1).padding(.bottom, VSpace.s2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, VSpace.edge).padding(.bottom, VSpace.s6)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .vScreen()
        .onAppear { router?.detailDepth += 1 }
        .onDisappear { router.map { $0.detailDepth = max(0, $0.detailDepth - 1) } }
    }
}

/// `SectionLabel` inside a detail screen or sheet, whose content already sits on the gutter.
struct DetailSection: View {
    let title: String
    let trailing: String?
    init(_ title: String, trailing: String? = nil) { self.title = title; self.trailing = trailing }
    var body: some View { SectionLabel(title, note: trailing).padding(.horizontal, -VSpace.edge) }
}

/// A `ListRow` that pushes a detail. One look for every "go deeper" in the app.
struct DrillRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let value: String?
    let route: Detail
    let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, value: String? = nil, route: Detail, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.value = value; self.route = route; self.accessory = accessory()
    }

    var body: some View {
        NavigationLink(value: route) { ListRow(title, subtitle: subtitle, value: value) { accessory } }
            .buttonStyle(.plain)
    }
}

extension DrillRow where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, value: String? = nil, route: Detail) {
        self.init(title, subtitle: subtitle, value: value, route: route) { EmptyView() }
    }
}

extension View {
    /// The one 16 gutter for anything that doesn't carry its own (headers and section labels do).
    func gutter() -> some View { padding(.horizontal, VSpace.edge) }
}

/// A tab's headline under its header: one `.display` line per string.
struct TabHeadline: View {
    let lines: [String]
    var color: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).vText(.display, color: color).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Formatting

enum MetricFormat {
    static let dash = "–"

    /// A value in the metric's own unit: hours as `6h 28m`, energy and steps grouped, the rest to the server's precision.
    static func value(_ v: Double?, unit: String) -> String {
        guard let v else { return dash }
        switch unit {
        case "hours": return hm(v)
        case "steps", "kcal", "flights", "min", "bpm": return TrainFormat.grouped(v)
        default: return v.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(Locale(identifier: "en_US")))
        }
    }

    /// The unit shown next to a number; nil where the number carries it (hours).
    static func unit(_ unit: String) -> String? {
        switch unit {
        case "hours": nil
        case "steps": "steps"
        case "breaths/min": "/min"
        case "ml/kg/min": "ml/kg·min"
        default: unit
        }
    }

    static func hm(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    static func signed(_ v: Double, unit: String) -> String {
        let text = value(abs(v), unit: unit)
        return v == 0 ? "±0" : "\(v > 0 ? "+" : "−")\(text)"
    }

    static func day(_ day: String, _ format: String = "d MMM") -> String {
        TrainFormat.day(day).map { TrainFormat.dayText($0, format).capitalized } ?? day
    }

    static func clock(minute m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

    static func rangeLabel(days: Int) -> String { days == 365 ? "1Y" : "\(days)D" }

    /// Where a reading sits against usual, in the card's dot-and-word language.
    static func status(flag: String?, reading: String?, hasValue: Bool) -> (String, VTone)? {
        guard hasValue else { return nil }
        switch flag {
        case "high": return ("High", reading == "better" ? .good : .watch)
        case "low": return ("Low", reading == "better" ? .good : .watch)
        default: return ("Usual", .usual)
        }
    }

    /// Axis tick text: whole numbers bare, otherwise one decimal.
    static func axis(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.001 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}

// MARK: Charts

/// Shared chart rules: `grid` lines, `.axis` labels in a right-hand lane 8 from the plot, x labels 8 below it.
extension View {
    func vChartYAxis(count: Int = 3) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: count)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(VColor.grid)
                AxisValueLabel(horizontalSpacing: VSpace.s2) {
                    if let d = v.as(Double.self) ?? v.as(Int.self).map(Double.init) { Text(MetricFormat.axis(d)).vText(.axis) }
                }
            }
        }
    }

    func vChartDateAxis(_ format: Date.FormatStyle, count: Int = 4) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: count)) { v in
                AxisValueLabel(verticalSpacing: VSpace.s2) { if let d = v.as(Date.self) { Text(d, format: format).vText(.axis) } }
            }
        }
    }

    /// The empty state laid over a chart with nothing to draw.
    func chartEmpty(_ isEmpty: Bool, _ text: String) -> some View {
        overlay { if isEmpty { Text(text).vText(.secondary) } }
    }
}

/// The value under the finger: a rule and one `ChartCallout` above the plot.
private func calloutRule<X: Plottable>(_ x: PlottableValue<X>, _ text: String) -> some ChartContent {
    RuleMark(x: x).foregroundStyle(VColor.chevron).lineStyle(StrokeStyle(lineWidth: 1))
        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { ChartCallout(text) }
}

/// One metric across days or weeks: line + points, the usual range as a band, per-day min–max where the server sends it.
/// Touch and drag to read a day.
struct HistoryChart: View {
    let history: MetricHistory
    let color: Color
    @State private var selected: Date?

    private struct P: Identifiable { let id: String; let date: Date; let value: Double }
    private var points: [P] {
        history.points.compactMap { p in TrainFormat.day(p.day).map { P(id: p.day, date: $0, value: p.value) } }
    }

    var body: some View {
        let pts = points
        let pick = selected.flatMap { s in pts.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        Chart {
            if let u = history.usual, let from = TrainFormat.day(history.from), let to = TrainFormat.day(history.to) {
                RectangleMark(xStart: .value("From", from), xEnd: .value("To", to.addingTimeInterval(86_400)),
                              yStart: .value("Low", u.low), yEnd: .value("High", u.high))
                    .foregroundStyle(VColor.range)
            }
            ForEach(history.band ?? [], id: \.day) { b in
                if let d = TrainFormat.day(b.day), let lo = b.lo, let hi = b.hi {
                    RuleMark(x: .value("Day", d, unit: .day), yStart: .value("Low", lo), yEnd: .value("High", hi))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round)).foregroundStyle(color.opacity(0.25))
                }
            }
            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value(history.name, p.value))
                    .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).foregroundStyle(color)
                if pts.count <= 40 || p.id == pts.last?.id {
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value(history.name, p.value))
                        .symbolSize(p.id == pts.last?.id ? 40 : 14).foregroundStyle(p.id == pts.last?.id ? color : color.opacity(0.7))
                }
            }
            if let pick {
                calloutRule(.value("Day", pick.date, unit: .day),
                            "\(MetricFormat.day(pick.id, history.every == "week" ? "'Week of' d MMM" : "EEE d MMM")) · \(MetricFormat.value(pick.value, unit: history.unit))")
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .vChartDateAxis(history.days <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
        .vChartYAxis()
        .chartEmpty(pts.isEmpty, "Nothing recorded in this range")
        .accessibilityLabel("\(history.name), \(pts.count) readings")
    }
}

/// A day of heart rate: the average line over each bucket's min–max, sleep shaded blue, workouts in red. Drag to read.
struct HeartDayChart: View {
    let day: HeartDay
    @Binding var selected: Int?

    var body: some View {
        let pick = selected.flatMap { s in day.points.min { abs($0.m - s) < abs($1.m - s) } }
        Chart {
            ForEach(Array(day.sleep.enumerated()), id: \.offset) { _, s in
                RectangleMark(xStart: .value("Start", s.startM), xEnd: .value("End", s.endM)).foregroundStyle(VColor.sleepCore.opacity(0.12))
            }
            ForEach(day.workouts, id: \.id) { w in
                RectangleMark(xStart: .value("Start", w.startM), xEnd: .value("End", max(w.endM, w.startM + 5))).foregroundStyle(VColor.accent.opacity(0.14))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                ForEach(seg, id: \.m) { p in
                    AreaMark(x: .value("Minute", p.m), yStart: .value("Low", p.lo), yEnd: .value("High", p.hi), series: .value("Run", seg.first?.m ?? 0))
                        .foregroundStyle(VColor.accent.opacity(0.18)).interpolationMethod(.monotone)
                    LineMark(x: .value("Minute", p.m), y: .value("BPM", p.avg), series: .value("Run", seg.first?.m ?? 0))
                        .foregroundStyle(VColor.accent).lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round)).interpolationMethod(.monotone)
                }
            }
            if let now = day.nowM {
                RuleMark(x: .value("Now", now)).foregroundStyle(VColor.dashed).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let pick {
                calloutRule(.value("Minute", pick.m), "\(MetricFormat.clock(minute: pick.m)) · \(pick.avg) bpm" + (pick.hi > pick.lo ? " (\(pick.lo)–\(pick.hi))" : ""))
            }
        }
        .chartXScale(domain: 0...1440)
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: [0, 360, 720, 1080, 1440]) { v in
                AxisGridLine().foregroundStyle(VColor.grid)
                AxisValueLabel(verticalSpacing: VSpace.s2) { if let m = v.as(Int.self) { Text(MetricFormat.clock(minute: m == 1440 ? 0 : m)).vText(.axis) } }
            }
        }
        .vChartYAxis()
        .chartEmpty(day.points.isEmpty, "No heart rate recorded")
        .accessibilityLabel("Heart rate across the day")
    }

    /// Runs of buckets with no gap over 30 minutes, so time off the wrist draws as a break, not a straight line.
    private var segments: [[HeartDay.Point]] {
        var out: [[HeartDay.Point]] = []
        for p in day.points {
            if let last = out.last?.last, p.m - last.m <= 30 { out[out.count - 1].append(p) } else { out.append([p]) }
        }
        return out
    }
}

/// A workout's heart rate with each logged set as a tick on the floor of the chart.
struct WorkoutHeartChart: View {
    let hr: WorkoutHeart
    /// Seconds from `hr.start` for each working set.
    let sets: [Double]
    /// Seconds from the start: the Watch workouts inside a visit.
    var spans: [ClosedRange<Double>] = []
    /// Minutes from the start, as the chart's x.
    @State private var selected: Double?

    private struct P: Identifiable { let id: Int; let min: Double; let bpm: Double; let run: Int }

    /// A new run wherever readings stop for over four buckets (no Watch on, sparse background readings), so gaps draw as gaps.
    private var runs: [P] {
        var run = 0, last: Double?
        return hr.points.enumerated().map { i, p in
            if let last, p.s - last > hr.bucketS * 4 { run += 1 }
            last = p.s
            return P(id: i, min: p.s / 60, bpm: Double(p.bpm), run: run)
        }
    }

    var body: some View {
        let pts = runs
        let pick = selected.flatMap { s in pts.min { abs($0.min - s) < abs($1.min - s) } }
        let floor = Double(hr.min) - 6
        Chart {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, r in
                RectangleMark(xStart: .value("Start", r.lowerBound / 60), xEnd: .value("End", r.upperBound / 60)).foregroundStyle(VColor.surface2)
            }
            line(pts, floor: floor)
            ticks(floor: floor)
            if let pick { calloutRule(.value("Time", pick.min), "\(TrainFormat.elapsed(pick.min * 60)) · \(Int(pick.bpm)) bpm") }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: floor...(Double(hr.max) + 6))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel(verticalSpacing: VSpace.s2) { if let m = v.as(Double.self) { Text("\(Int(m))m").vText(.axis) } }
            }
        }
        .vChartYAxis()
        .accessibilityLabel("Heart rate during the workout, \(hr.min) to \(hr.max) beats per minute")
    }

    @ChartContentBuilder private func line(_ pts: [P], floor: Double) -> some ChartContent {
        let fill = LinearGradient(colors: [VColor.accent.opacity(0.22), VColor.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        ForEach(pts) { p in
            AreaMark(x: .value("Time", p.min), yStart: .value("Floor", floor), yEnd: .value("BPM", p.bpm), series: .value("Run", p.run))
                .foregroundStyle(fill).interpolationMethod(.monotone)
        }
        ForEach(pts) { p in
            LineMark(x: .value("Time", p.min), y: .value("BPM", p.bpm), series: .value("Run", p.run))
                .foregroundStyle(VColor.accent).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round)).interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private func ticks(floor: Double) -> some ChartContent {
        ForEach(Array(sets.enumerated()), id: \.offset) { _, s in
            RuleMark(x: .value("Set", s / 60), yStart: .value("Floor", floor), yEnd: .value("Tick", floor + 4))
                .foregroundStyle(VColor.text2).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

/// Estimated 1-rep max per session; drag to read a session.
struct E1RMHistoryChart: View {
    let points: [ExerciseDetail.Point]
    @State private var selected: Date?

    var body: some View {
        let pts = points.compactMap { p in TrainFormat.day(p.day).map { (p, $0) } }
        let pick = selected.flatMap { s in pts.min { abs($0.1.timeIntervalSince(s)) < abs($1.1.timeIntervalSince(s)) } }
        Chart {
            ForEach(pts, id: \.0.day) { p, d in
                LineMark(x: .value("Day", d, unit: .day), y: .value("kg", p.kg))
                    .foregroundStyle(VColor.text).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.monotone)
                PointMark(x: .value("Day", d, unit: .day), y: .value("kg", p.kg))
                    .symbolSize(p.day == pts.last?.0.day ? 44 : 18).foregroundStyle(p.day == pts.last?.0.day ? VColor.accent : VColor.text)
            }
            if let p = pick?.0, let d = pick?.1 {
                calloutRule(.value("Day", d, unit: .day), "\(MetricFormat.day(p.day, "EEE d MMM")) · \(TrainFormat.kg(p.kg)) kg")
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .vChartDateAxis(.dateTime.day().month(.abbreviated))
        .vChartYAxis()
        .chartEmpty(pts.isEmpty, "No estimate in 12 weeks")
    }
}
