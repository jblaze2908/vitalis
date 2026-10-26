import Charts
import SwiftUI
import VitalisKit
import VitalisUI

/// Every pushed screen: a pinned back + title bar over a scrolling body, so the way back never scrolls away.
struct DetailScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router: Router?

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(VColor.bone)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).vUI(17, weight: 700).lineLimit(1).minimumScaleFactor(0.8)
                    if let subtitle { Text(subtitle).vUI(12, weight: 500, color: VColor.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .vScreen()
        .onAppear { router?.detailDepth += 1 }
        .onDisappear { router.map { $0.detailDepth = max(0, $0.detailDepth - 1) } }
    }
}

/// Section caption inside a detail screen, matching the tabs' `vLabel` captions.
struct DetailSection: View {
    let title: String
    let trailing: String?
    init(_ title: String, trailing: String? = nil) { self.title = title; self.trailing = trailing }
    var body: some View {
        HStack { Text(title).vLabel(); Spacer(); if let trailing { Text(trailing).vLabel() } }
            .padding(.top, 22).padding(.bottom, 8)
    }
}

/// A card row that pushes a detail: title, value, a chevron. One look for every "go deeper" in the app.
struct DrillRow<Leading: View>: View {
    let route: Detail
    let leading: Leading
    let value: String?
    init(_ route: Detail, value: String? = nil, @ViewBuilder leading: () -> Leading) { self.route = route; self.value = value; self.leading = leading() }
    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 8)
                if let value { Text(value).vUI(14, weight: 500, color: VColor.muted).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
            }
            .padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DrillTitle: View {
    let text: String
    var body: some View { Text(text).vUI(15, weight: 500) }
}

extension DrillRow where Leading == DrillTitle {
    init(_ title: String, route: Detail, value: String? = nil) {
        self.init(route, value: value) { DrillTitle(text: title) }
    }
}

/// Rows separated by the card hairline, inside one card.
struct RowsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VCard(padding: EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)) {
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { i, v in
                        if i > 0 { Rectangle().fill(VColor.hairline).frame(height: 1) }
                        v
                    }
                }
            }
        }
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
}

// MARK: Charts

/// Shared chart styling: dark hairline grid, mono axis labels, the scrub rule in bone.
private extension View {
    func vChartStyle() -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color(hex: 0x1C1C1C))
                AxisValueLabel().font(VFont.mono(10, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E))
            }
        }
    }
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
                    .foregroundStyle(Color.white.opacity(0.06))
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
                RuleMark(x: .value("Day", pick.date, unit: .day)).foregroundStyle(VColor.bone.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout("\(MetricFormat.day(pick.id, history.every == "week" ? "'Week of' d MMM" : "EEE d MMM")) · \(MetricFormat.value(pick.value, unit: history.unit))")
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: history.days <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                    .font(VFont.mono(10, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E))
            }
        }
        .vChartStyle()
        .overlay { if pts.isEmpty { Text("Nothing recorded in this range").vUI(13, weight: 500, color: VColor.muted) } }
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
                RectangleMark(xStart: .value("Start", w.startM), xEnd: .value("End", max(w.endM, w.startM + 5))).foregroundStyle(VColor.pulse.opacity(0.14))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                ForEach(seg, id: \.m) { p in
                    AreaMark(x: .value("Minute", p.m), yStart: .value("Low", p.lo), yEnd: .value("High", p.hi), series: .value("Run", seg.first?.m ?? 0))
                        .foregroundStyle(VColor.pulse.opacity(0.18)).interpolationMethod(.monotone)
                    LineMark(x: .value("Minute", p.m), y: .value("BPM", p.avg), series: .value("Run", seg.first?.m ?? 0))
                        .foregroundStyle(VColor.pulse).lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round)).interpolationMethod(.monotone)
                }
            }
            if let now = day.nowM {
                RuleMark(x: .value("Now", now)).foregroundStyle(Color(hex: 0x4A4A4A)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let pick {
                RuleMark(x: .value("Minute", pick.m)).foregroundStyle(VColor.bone.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout("\(MetricFormat.clock(minute: pick.m)) · \(pick.avg) bpm" + (pick.hi > pick.lo ? " (\(pick.lo)–\(pick.hi))" : ""))
                    }
            }
        }
        .chartXScale(domain: 0...1440)
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: [0, 360, 720, 1080, 1440]) { v in
                AxisGridLine().foregroundStyle(Color(hex: 0x161616))
                AxisValueLabel { if let m = v.as(Int.self) { Text(MetricFormat.clock(minute: m == 1440 ? 0 : m)) } }
                    .font(VFont.mono(10, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E))
            }
        }
        .vChartStyle()
        .overlay { if day.points.isEmpty { Text("No heart rate recorded").vUI(13, weight: 500, color: VColor.muted) } }
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
    /// Minutes from the start, as the chart's x.
    @State private var selected: Double?

    private struct P: Identifiable { let id: Int; let min: Double; let bpm: Double }

    var body: some View {
        let pts = hr.points.enumerated().map { P(id: $0.offset, min: $0.element.s / 60, bpm: Double($0.element.bpm)) }
        let pick = selected.flatMap { s in pts.min { abs($0.min - s) < abs($1.min - s) } }
        let floor = Double(hr.min) - 6
        Chart {
            line(pts, floor: floor)
            ticks(floor: floor)
            if let pick { callout(pick) }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: floor...(Double(hr.max) + 6))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel { if let m = v.as(Double.self) { Text("\(Int(m))m") } }
                    .font(VFont.mono(10, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E))
            }
        }
        .vChartStyle()
        .accessibilityLabel("Heart rate during the workout, \(hr.min) to \(hr.max) beats per minute")
    }

    @ChartContentBuilder private func line(_ pts: [P], floor: Double) -> some ChartContent {
        let fill = LinearGradient(colors: [VColor.pulse.opacity(0.22), VColor.pulse.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        ForEach(pts) { p in
            AreaMark(x: .value("Time", p.min), yStart: .value("Floor", floor), yEnd: .value("BPM", p.bpm))
                .foregroundStyle(fill).interpolationMethod(.monotone)
        }
        ForEach(pts) { p in
            LineMark(x: .value("Time", p.min), y: .value("BPM", p.bpm))
                .foregroundStyle(VColor.pulse).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round)).interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private func ticks(floor: Double) -> some ChartContent {
        ForEach(Array(sets.enumerated()), id: \.offset) { _, s in
            RuleMark(x: .value("Set", s / 60), yStart: .value("Floor", floor), yEnd: .value("Tick", floor + 4))
                .foregroundStyle(VColor.bone.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func callout(_ p: P) -> some ChartContent {
        RuleMark(x: .value("Time", p.min)).foregroundStyle(VColor.bone.opacity(0.4))
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                ChartCallout("\(TrainFormat.elapsed(p.min * 60)) · \(Int(p.bpm)) bpm")
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
                    .foregroundStyle(VColor.bone).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.monotone)
                PointMark(x: .value("Day", d, unit: .day), y: .value("kg", p.kg))
                    .symbolSize(p.day == pts.last?.0.day ? 44 : 18).foregroundStyle(p.day == pts.last?.0.day ? VColor.pulse : VColor.bone)
            }
            if let p = pick?.0, let d = pick?.1 {
                RuleMark(x: .value("Day", d, unit: .day)).foregroundStyle(VColor.bone.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout("\(MetricFormat.day(p.day, "EEE d MMM")) · \(TrainFormat.kg(p.kg)) kg")
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(VFont.mono(10, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E))
            }
        }
        .vChartStyle()
        .overlay { if pts.isEmpty { Text("No estimate in 12 weeks").vUI(13, weight: 500, color: VColor.muted) } }
    }
}
