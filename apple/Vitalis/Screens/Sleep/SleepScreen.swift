import SwiftUI
import VitalisKit
import VitalisUI

/// The tab headline: one `.display` line per entry.
private struct SleepHeadline: View {
    let lines: [String]
    var placeholder = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).vText(.display, color: placeholder ? VColor.text3 : nil).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Sleep tab (2e): Night (stages across the clock, naps apart), Week (bed→wake per night) and Month (a calendar of hours).
struct SleepScreen: View {
    @State private var store: SleepStore
    @Environment(\.scenePhase) private var scenePhase
    private let live: Bool

    init() { _store = State(initialValue: SleepStore.shared); live = true }
    /// Previews: a preloaded store and no fetching.
    init(store: SleepStore) { _store = State(initialValue: store); live = false }

    private var v: SleepResponse? { store.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VHeader("Sleep", freshness: DataFreshness(fetchedAt: store.night.fetchedAt, refreshing: store.night.isLoading))
                HStack {
                    PillPicker(SleepStore.Range.allCases.map { ($0, $0.rawValue) }, selection: Binding(get: { store.range }, set: { r in choose(r) }))
                    Spacer(minLength: VSpace.s2)
                    stepper
                }
                .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
                if v == nil, store.night.error != nil, !store.night.isLoading {
                    unreachable.padding(.horizontal, VSpace.edge)
                } else {
                    switch store.range {
                    case .night: nightView
                    case .week: weekView
                    case .month: monthView
                    }
                }
            }
            .padding(.bottom, VSpace.s6)
        }
        .scrollIndicators(.hidden)
        .refreshable { if live { await store.load(force: true) } }
        // First appearance and every return to the foreground.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if live { await store.load() }
            #if DEBUG
            // Screenshots without taps: `-VitalisSleepRange Week`.
            if let raw = UserDefaults.standard.string(forKey: "VitalisSleepRange"), let r = SleepStore.Range(rawValue: raw) { await store.select(r) }
            #endif
        }
        .onChange(of: live ? Services.shared.writesVersion : 0) { Task { await store.load() } }
    }

    private func choose(_ r: SleepStore.Range) { Task { await store.select(r) } }

    @ViewBuilder private var stepper: some View {
        switch store.range {
        case .night:
            PeriodStepper(v.map { $0.nextDay == nil ? "Last night" : SleepCopy.dayTitle($0.day) } ?? "Last night",
                          back: store.canGoBack ? { Task { await store.back() } } : nil,
                          forward: store.canGoForward ? { Task { await store.forward() } } : nil)
        case .week:
            PeriodStepper(store.shownWeek.map { SleepCopy.weekTitle(end: $0.end) } ?? "This week",
                          back: { Task { await store.stepWeek(-1) } },
                          forward: store.canStepWeekForward ? { Task { await store.stepWeek(1) } } : nil)
        case .month:
            PeriodStepper(store.shownMonth.map { SleepCopy.monthTitle($0.month) } ?? "This month",
                          back: store.shownMonth?.prevMonth == nil ? nil : { Task { await store.stepMonth(-1) } },
                          forward: store.shownMonth?.nextMonth == nil ? nil : { Task { await store.stepMonth(1) } })
        }
    }

    // MARK: Night

    @ViewBuilder private var nightView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SleepHeadline(lines: SleepCopy.headline(v), placeholder: v == nil).padding(.top, VSpace.s4).padding(.horizontal, VSpace.edge)
            if v?.hasNight == false {
                Text("No sleep recorded for this night.").vText(.body).padding(.top, VSpace.s4).padding(.horizontal, VSpace.edge)
            } else {
                HStack(alignment: .lastTextBaseline) {
                    Figure(v?.night.flatMap { $0.asleepH.map(SleepCopy.hm) } ?? "–", unit: "asleep", size: 56)
                    Spacer(minLength: VSpace.s2)
                    Figure(v?.score.map(String.init) ?? "–", unit: "score", size: 28)
                }
                .padding(.horizontal, VSpace.edge).padding(.top, VSpace.s4)
                if let segs = v?.night?.segments, !segs.isEmpty {
                    StageChart(segments: segs).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
                    stageLegend.padding(.horizontal, VSpace.edge).padding(.top, VSpace.s3)
                }
                naps
                ReadoutRow(SleepCopy.readouts(v)).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
                tonight
            }
        }
    }

    private var stageLegend: some View {
        let st = v?.stages
        return HStack(spacing: VSpace.s3) {
            legend(VColor.sleepDeep, "Deep", st?.deepH)
            legend(VColor.sleepCore, "Core", st?.coreH)
            legend(VColor.sleepREM, "REM", st?.remH)
            legend(VColor.watch, "Awake", st?.awakeH)
        }
    }

    private func legend(_ color: Color, _ name: String, _ h: Double?) -> some View {
        HStack(spacing: VSpace.s1) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).vText(.secondary)
            Text(h.map(SleepCopy.hm) ?? "–").vText(.secondary, color: VColor.text)
        }
        .accessibilityElement(children: .combine)
    }

    /// Naps sit apart from the night: they count toward need but not toward the score.
    @ViewBuilder private var naps: some View {
        let list = v?.naps ?? []
        if !list.isEmpty {
            SectionLabel("Naps")
            ListCard {
                ForEach(Array(list.enumerated()), id: \.offset) { _, nap in
                    ListRow("Nap", subtitle: "\(APIDate.clockText(nap.start) ?? "")–\(APIDate.clockText(nap.end) ?? "") · not in score",
                            value: SleepCopy.hm(nap.asleepH), chevron: false)
                }
            }
            .padding(.horizontal, VSpace.edge)
        }
    }

    @ViewBuilder private var tonight: some View {
        if let t = v?.tonight, let bed = t.bedBy, v?.nextDay == nil {
            SectionLabel("Tonight")
            VCard {
                HStack(spacing: VSpace.s3) {
                    Image(systemName: "moon").font(.system(size: 18)).foregroundStyle(VColor.sleepCore)
                    VStack(alignment: .leading, spacing: VSpace.s1) {
                        Text("Bed by \(bed)").vText(.title)
                        Text(SleepCopy.tonightLine(t, napCredit: v?.duration?.napCreditH)).vText(.secondary)
                    }
                    Spacer(minLength: VSpace.s2)
                    if store.reminder != .set {
                        SecondaryButton("Remind me") { Task { await store.remindMe() } }
                    } else { Text("Reminder set").vText(.secondary) }
                }
            }
            .padding(.horizontal, VSpace.edge)
        }
    }

    // MARK: Week

    @ViewBuilder private var weekView: some View {
        let w = store.shownWeek
        VStack(alignment: .leading, spacing: 0) {
            SleepHeadline(lines: SleepCopy.weekHeadline(w?.avg), placeholder: w == nil).padding(.top, VSpace.s4).padding(.horizontal, VSpace.edge)
            ReadoutRow(SleepCopy.weekReadouts(w)).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
            SectionLabel("Each night", note: "Bed → wake · hours")
            if let w {
                VCard { WeekSchedule(nights: w.nights, aimBed: v?.tonight?.bedBy, aimWake: v?.tonight?.wakeTime) }
                    .padding(.horizontal, VSpace.edge)
            }
        }
    }

    // MARK: Month

    @ViewBuilder private var monthView: some View {
        let m = store.shownMonth
        VStack(alignment: .leading, spacing: 0) {
            SleepHeadline(lines: SleepCopy.monthHeadline(m?.avg), placeholder: m == nil).padding(.top, VSpace.s4).padding(.horizontal, VSpace.edge)
            ReadoutRow(SleepCopy.monthReadouts(m)).padding(.horizontal, VSpace.edge).padding(.top, VSpace.s5)
            if let m {
                SectionLabel("Each night", note: "Hours asleep")
                VCard { MonthCalendar(month: m.month, days: m.days) }.padding(.horizontal, VSpace.edge)
            }
        }
    }

    // MARK: Error without cache

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: VSpace.s4) {
            Text("Connect to your server to see your sleep.").vText(.body)
            SecondaryButton("Try again") { Task { await store.load(force: true) } }
        }
        .padding(.top, VSpace.s5)
    }
}

/// The night across the clock: Awake, REM, Core and Deep rows, one block per stage spell; row names in the right lane.
private struct StageChart: View {
    let segments: [SleepResponse.Segment]
    @State private var sx: Double?
    private static let rowH: CGFloat = 26, lane: CGFloat = 40
    private static let rows = ["Awake", "REM", "Core", "Deep"]

    var body: some View {
        let spans = segments.compactMap { s -> (String, Date, Date)? in
            guard let a = APIDate.parse(s.start), let b = APIDate.parse(s.end) else { return nil }; return (s.stage, a, b)
        }
        let start = spans.map(\.1).min() ?? Date(), end = spans.map(\.2).max() ?? Date()
        let plotH = Self.rowH * 4 + VSpace.s1 * 3
        VStack(spacing: VSpace.s2) {
            HStack(alignment: .top, spacing: VSpace.s2) {
                Canvas { ctx, size in
                    let total = max(end.timeIntervalSince(start), 60), rowH = Self.rowH, gap = VSpace.s1
                    for i in 0..<4 {
                        var line = Path(); let y = CGFloat(i) * (rowH + gap) + rowH / 2
                        line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(line, with: .color(VColor.grid), lineWidth: 1)
                    }
                    for (stage, a, b) in spans {
                        let row: Int, color: Color
                        switch stage {
                        case "awake": row = 0; color = VColor.watch
                        case "rem": row = 1; color = VColor.sleepREM
                        case "deep": row = 3; color = VColor.sleepDeep
                        default: row = 2; color = VColor.sleepCore
                        }
                        let x0 = size.width * a.timeIntervalSince(start) / total, x1 = size.width * b.timeIntervalSince(start) / total
                        let rect = CGRect(x: x0, y: CGFloat(row) * (rowH + gap), width: max(x1 - x0, row == 0 ? 3 : 2), height: rowH)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: row == 0 ? 2 : 3), with: .color(color))
                    }
                }
                .frame(height: plotH)
                .overlay {
                    GeometryReader { g in
                        if let sx {
                            let t = start.addingTimeInterval(end.timeIntervalSince(start) * sx)
                            let hit = spans.first { $0.1 <= t && t < $0.2 }
                            Rectangle().fill(VColor.text.opacity(0.5)).frame(width: 1, height: g.size.height).offset(x: g.size.width * sx)
                            ChartCallout(hit.map { "\(SleepCopy.stageName($0.0)) · \(SleepCopy.clock($0.1, like: segments.first?.start))–\(SleepCopy.clock($0.2, like: segments.first?.start))" }
                                         ?? SleepCopy.clock(t, like: segments.first?.start))
                                .position(x: min(max(g.size.width * sx, 80), g.size.width - 80), y: -12)
                        }
                    }
                }
                .scrub($sx)
                VStack(alignment: .leading, spacing: VSpace.s1) {
                    ForEach(Self.rows, id: \.self) { Text($0).vText(.axis).frame(height: Self.rowH) }
                }
                .frame(width: Self.lane, alignment: .leading)
                .accessibilityHidden(true)
            }
            HStack(spacing: VSpace.s2) {
                HStack {
                    ForEach(0..<4, id: \.self) { i in
                        let t = start.addingTimeInterval(end.timeIntervalSince(start) * Double(i) / 3)
                        Text(SleepCopy.clock(t, like: segments.first?.start)).vText(.axis)
                        if i < 3 { Spacer() }
                    }
                }
                Color.clear.frame(width: Self.lane, height: 1)
            }
        }
        .accessibilityLabel("Sleep stages across the night")
    }
}

/// One bar per night from bed to wake on a 22:00–10:00 clock, the aim window as a band behind, hours on the right.
private struct WeekSchedule: View {
    let nights: [SleepNightRow]
    let aimBed: String?
    let aimWake: String?
    private static let from = 22 * 60, span = 12 * 60
    private static let dayLane: CGFloat = 40, valueLane: CGFloat = 64, rowH: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            ForEach(nights, id: \.day) { n in row(n) }
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.dayLane)
                GeometryReader { g in
                    ForEach([0, 4, 8, 12], id: \.self) { h in
                        Text(String(format: "%02d:00", (22 + h) % 24)).vText(.axis)
                            .position(x: g.size.width * Double(h) / 12, y: VSpace.s2)
                    }
                }
                .frame(height: VSpace.s4)
                Color.clear.frame(width: Self.valueLane)
            }
            .padding(.top, VSpace.s2)
        }
    }

    private func x(_ iso: String?) -> Double? {
        guard let iso, let c = APIDate.clockText(iso) else { return nil }
        let parts = c.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let m = ((parts[0] * 60 + parts[1]) - Self.from + 1440) % 1440
        return min(max(Double(m) / Double(Self.span), 0), 1)
    }

    private func row(_ n: SleepNightRow) -> some View {
        HStack(spacing: 0) {
            Text(SleepCopy.weekday(n.day)).vText(.secondary).frame(width: Self.dayLane, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    // Rows touch, so the aim window reads as one band down the chart.
                    if let a = x(aimBed.map { "T\($0)" }), let b = x(aimWake.map { "T\($0)" }), b > a {
                        Rectangle().fill(VColor.range).frame(width: g.size.width * (b - a)).offset(x: g.size.width * a)
                    }
                    if let a = x(n.sleepStart), let b = x(n.sleepEnd), b > a {
                        Capsule().fill(VColor.sleepCore).frame(width: g.size.width * (b - a), height: VBar.meter).offset(x: g.size.width * a)
                    } else if n.asleepH == nil {
                        Text("No data").vText(.secondary, color: VColor.text3).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.rowH)
            }
            .frame(height: Self.rowH)
            VStack(alignment: .trailing, spacing: 0) {
                Text(n.asleepH.map(SleepCopy.hm) ?? "–").vText(.headline, color: (n.asleepH ?? 9) < 6 ? VColor.watch : nil)
                if let s = n.score { Text("score \(s)").vText(.secondary).lineLimit(1) }
            }
            .frame(width: Self.valueLane, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The month as a calendar; each night shaded by hours slept, a dot on nap days.
private struct MonthCalendar: View {
    let month: String
    let days: [SleepNightRow]
    var body: some View {
        let lead = SleepCopy.leadingBlanks(month)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        let count = SleepCopy.daysIn(month)
        let cols = Array(repeating: GridItem(.flexible(), spacing: VSpace.s1), count: 7)
        VStack(spacing: VSpace.s3) {
            LazyVGrid(columns: cols, spacing: VSpace.s1) {
                // One id space for headers, blanks and days: shared Int ids made the grid drop the 1st and 2nd.
                ForEach((0..<7).map { "h\($0)" } + (0..<lead).map { "b\($0)" } + (1...count).map { "d\($0)" }, id: \.self) { key in
                    let n = Int(key.dropFirst()) ?? 0
                    switch key.first {
                    case "h": Text(String(Array("MTWTFSS")[n])).vText(.axis)
                    case "b": Color.clear.frame(height: 44)
                    default: cell(n, byDay[String(format: "%@-%02d", month, n)])
                    }
                }
            }
            HStack(spacing: VSpace.s2) {
                ForEach(Array(SleepCopy.hourBands.enumerated()), id: \.offset) { _, band in
                    HStack(spacing: VSpace.s1) {
                        RoundedRectangle(cornerRadius: 2).fill(band.1).frame(width: 14, height: 10)
                        Text(band.0).vText(.secondary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: VSpace.s1) {
                    Circle().fill(VColor.sleepREM).frame(width: 7, height: 7)
                    Text("nap").vText(.secondary)
                }
            }
        }
    }

    private func cell(_ d: Int, _ n: SleepNightRow?) -> some View {
        let h = n?.asleepH
        let fill = h.map(SleepCopy.hourColor) ?? .clear
        let dark = h.map(SleepCopy.darkInk) ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(d)").vText(.axis, color: dark ? VColor.ground : VColor.text2)
            Spacer(minLength: 0)
            HStack { Spacer(minLength: 0); Text(h.map(SleepCopy.hm) ?? "").vText(.headline, color: dark ? VColor.ground : VColor.text).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .padding(VSpace.s1)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: VRadius.control, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: VRadius.control, style: .continuous).stroke(h == nil ? VColor.line : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) { if (n?.napH ?? 0) > 0 { Circle().fill(VColor.sleepREM).frame(width: 6, height: 6).padding(VSpace.s1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(d): \(h.map(SleepCopy.hm) ?? "no data")")
    }
}

/// Sleep's words and small maths, apart from layout.
enum SleepCopy {
    static func stageName(_ s: String) -> String { ["rem": "REM", "deep": "Deep", "core": "Core", "awake": "Awake"][s] ?? "Asleep" }
    static func hm(_ h: Double) -> String { let m = Int((h * 60).rounded()); return "\(m / 60):" + String(format: "%02d", m % 60) }

    static func headline(_ v: SleepResponse?) -> [String] {
        guard let v, v.hasNight else { return [v == nil ? "–" : "No night."] }
        let first: String = switch v.band { case "good": "Great night."; case "ok": "Solid night."; case "low": "Rough night."; default: "Last night." }
        guard let a = v.night?.asleepH, let n = v.duration?.needH else { return [first] }
        let diff = Int(((a - n) * 60).rounded())
        return [first, diff < -5 ? "\(-diff) min short." : diff > 5 ? "\(diff) min over." : "Right on need."]
    }

    static func readouts(_ v: SleepResponse?) -> [Readout] {
        let part = { (k: String) in v?.parts?.first { $0.key == k } }
        let a = v?.night?.asleepH, n = v?.duration?.needH
        let dur: (String, VTone)? = a.flatMap { a in n.map { n in a + 0.25 < n ? ("Short", .watch) : a >= n ? ("Good", .good) : ("OK", .usual) } }
        func flag(_ p: SleepResponse.Part?, _ bad: String, _ ok: String) -> (String, VTone)? {
            guard let p, p.score != nil else { return nil }
            return p.flagged == true ? (bad, .watch) : (ok, .good)
        }
        let bed = part("consistency")?.detail ?? ""
        let bedValue = v?.night.flatMap { APIDate.clockText($0.sleepStart) } ?? "–"
        let eff = part("efficiency")?.detail.flatMap { d in d.firstIndex(of: "%").map { String(d[..<$0]) + "%" } } ?? "–"
        let wake = part("wakeups")?.detail.map { String($0.prefix { $0.isNumber }) } ?? "–"
        return [Readout("Duration", a.map(hm) ?? "–", status: dur),
                Readout("Bedtime", bedValue, status: flag(part("consistency"), bed.contains("EARLY") ? "Early" : "Late", "On time")),
                Readout("Efficiency", eff, status: flag(part("efficiency"), "Low", "Good")),
                Readout("Wake-ups", wake.isEmpty ? "–" : wake, status: flag(part("wakeups"), "Many", "Few"))]
    }

    static func tonightLine(_ t: SleepResponse.Tonight, napCredit: Double?) -> String {
        let wake = t.wakeTime.map { "\($0) wake" } ?? "for your wake"
        guard let c = napCredit, c > 0.05 else { return wake }
        return "\(wake) · \(hm(c)) less for the nap"
    }

    static func weekHeadline(_ a: SleepAverages?) -> [String] {
        guard let h = a?.asleepH else { return ["–"] }
        return ["\(hm(h)) a night."]
    }

    static func weekReadouts(_ w: SleepWeekResponse?) -> [Readout] {
        let a = w?.avg
        let delta = a?.score.flatMap { s in w?.prevAvgScore.map { s - $0 } }
        return [Readout("Asleep", a?.asleepH.map(hm) ?? "–"),
                Readout("Score", a?.score.map(String.init) ?? "–", status: delta.map { ($0 >= 0 ? "+\($0) vs last" : "\($0) vs last", $0 >= 0 ? .good : .watch) }),
                Readout("Bedtime", a?.bedtime ?? "–"),
                Readout("Naps", a.map { $0.napH ?? 0 }.map { $0 > 0 ? hm($0) : "–" } ?? "–")]
    }

    static func monthHeadline(_ a: SleepAverages?) -> [String] { a?.asleepH.map { ["\(hm($0)) a night."] } ?? ["–"] }

    static func monthReadouts(_ m: SleepMonthResponse?) -> [Readout] {
        let a = m?.avg
        let delta = a?.score.flatMap { s in m?.prevAvgScore.map { s - $0 } }
        return [Readout("Asleep", a?.asleepH.map(hm) ?? "–"),
                Readout("Score", a?.score.map(String.init) ?? "–", status: delta.map { ($0 >= 0 ? "+\($0) vs last" : "\($0) vs last", $0 >= 0 ? .good : .watch) }),
                Readout("Bedtime", a?.bedtime ?? "–"),
                Readout("Nights", a.map { String($0.nights) } ?? "–", status: a.flatMap { $0.missing > 0 ? ("\($0.missing) missing", .quiet) : nil })]
    }

    /// Darker to lighter as the night gets longer; the two lightest take dark ink (`darkInk`).
    static let hourBands: [(String, Color)] = [("<6h", VColor.barTrack), ("6–7h", VColor.sleepDeep), ("7–7½h", VColor.sleepCore), ("7½h+", VColor.sleepREM)]
    static func darkInk(_ h: Double) -> Bool { h >= 7 }
    static func hourColor(_ h: Double) -> Color { h < 6 ? hourBands[0].1 : h < 7 ? hourBands[1].1 : h < 7.5 ? hourBands[2].1 : hourBands[3].1 }

    private static let iso: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static func date(_ day: String) -> Date? { iso.date(from: day) }
    private static func fmt(_ d: Date, _ p: String) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = p; return f.string(from: d) }

    static func dayTitle(_ day: String) -> String { date(day).map { fmt($0, "EEE d MMM") } ?? day }
    static func weekday(_ day: String) -> String { date(day).map { fmt($0, "EEE") } ?? "" }
    static func weekTitle(end: String) -> String {
        guard let e = date(end), let s = Calendar(identifier: .gregorian).date(byAdding: .day, value: -6, to: e) else { return end }
        // A week across two months names both: "26 Oct–1 Nov", not "26–1 Nov".
        return "\(fmt(s, fmt(s, "MMM") == fmt(e, "MMM") ? "d" : "d MMM"))–\(fmt(e, "d MMM"))"
    }
    static func monthTitle(_ m: String) -> String { date("\(m)-01").map { fmt($0, "MMMM") } ?? m }
    static func daysIn(_ m: String) -> Int {
        guard let d = date("\(m)-01") else { return 30 }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.range(of: .day, in: .month, for: d)?.count ?? 30
    }
    /// Monday-first blanks before the 1st.
    static func leadingBlanks(_ m: String) -> Int {
        guard let d = date("\(m)-01") else { return 0 }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return (c.component(.weekday, from: d) + 5) % 7
    }
    /// A chart tick in the night's own offset (taken from one of its timestamps).
    static func clock(_ t: Date, like sample: String?) -> String {
        let off = sample.flatMap(APIDate.offsetSeconds) ?? 0
        return fmt(t.addingTimeInterval(TimeInterval(off)), "HH:mm")
    }
}

@MainActor private func previewStore(_ value: SleepResponse?, week: SleepWeekResponse? = SleepBodyPreviewData.week) -> SleepStore {
    let store = SleepStore(api: { nil })
    store.preload(value, week: week)
    return store
}

#Preview("Sleep · loaded") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.sleep)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · flagged part, earlier night") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.flagged, week: nil)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · no sleep recorded") {
    SleepScreen(store: previewStore(SleepBodyPreviewData.noNight)).vScreen().onAppear { VFont.register() }
}

#Preview("Sleep · loading") {
    SleepScreen(store: previewStore(nil, week: nil)).vScreen().onAppear { VFont.register() }
}
