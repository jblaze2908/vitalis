import SwiftUI
import VitalisKit
import VitalisUI

/// Body tab (frame 05, brief 03 → Body): weight trend, activity, vitals vs typical range; `+ Log weight` opens the sheet.
struct BodyScreen: View {
    @State private var store: BodyStore
    @State private var showsLogWeight = false
    @State private var path = Detail.launchPath("body")
    @Environment(Services.self) private var services: Services?
    private let live: Bool
    @Environment(Router.self) private var router

    init() { _store = State(initialValue: BodyStore.shared); live = true }
    /// Previews: a preloaded store and no fetching.
    init(store: BodyStore, showsLogWeight: Bool = false) {
        _store = State(initialValue: store); _showsLogWeight = State(initialValue: showsLogWeight); live = false
    }

    private var v: BodyResponse? { store.value }

    var body: some View {
        NavigationStack(path: $path) {
            page.toolbar(.hidden, for: .navigationBar).detailDestinations()
        }
    }

    private var page: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabHeader("Body") {
                    Button { showsLogWeight = true } label: {
                        Text("+ Weight").vUI(14, weight: 700, color: Color(hex: 0x140A2E)).padding(.horizontal, 13).frame(height: 30)
                            .background(VColor.body, in: Capsule())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Log weight")
                }
                .padding(.top, 2).padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 0) {
                    if v == nil, store.body.error != nil, !store.body.isLoading {
                        unreachable
                    } else {
                        HeadlineLines(BodyCopy.headline(v?.weight), size: 36, colors: v == nil ? [VColor.steel] : []).padding(.top, 9)
                        weightHero.id(BodySection.weight)
                        Text("Heart").vLabel().padding(.top, 22).padding(.bottom, 8)
                        HeartTodayCard(store: .shared, live: live)
                        Text("Vitals vs usual").vLabel().padding(.top, 22).padding(.bottom, 8).id(BodySection.vitals)
                        vitalsCard
                        Text("Activity · today").vLabel().padding(.top, 22).padding(.bottom, 8).id(BodySection.activity)
                        activityCard
                        RowsCard { DrillRow(.allData, value: "Every metric") { Text("All health data").vUI(15, weight: 600) } }.padding(.top, 22)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        // A tap on Today's HRV or Steps lands on that section, once the page has content to scroll to.
        .task(id: [router.bodySection.map { "\($0)" }, v?.day].compactMap { $0 }) {
            guard let section = router.bodySection, v != nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(section, anchor: .top) }
            router.bodySection = nil
        }
        }
        .overlay(alignment: .bottom) { toast }
        .sensoryFeedback(.success, trigger: store.lastSaved) { _, new in new != nil }
        .refreshable { if live { await store.load() } }
        .task { if live { await store.load() } }
        .onChange(of: services?.writesVersion) { if live { Task { await store.load() } } }
        .task(id: store.waitingID) { await pollWaiting() }
        .sheet(isPresented: $showsLogWeight) { LogWeightSheet(store: store) }
    }

    // MARK: 2e Body

    private var weightHero: some View {
        let w = v?.weight
        return VStack(alignment: .leading, spacing: 12) {
            // The number you stepped on the scale with; the smoothed trend sits in the readouts.
            Figure(SleepBodyFormat.kg(w?.latest?.kg ?? w?.trendKg), unit: w?.latest == nil ? "kg trend" : "kg", size: 52,
                   color: w?.latest == nil && w?.trendKg == nil ? VColor.steel : nil).padding(.top, 16)
            WeightTrendChart(series: w?.series ?? [], goal: w?.goalKg).frame(height: 160)
            RowsCard { DrillRow("Weight history", route: .metric(key: "weight_kg"), value: "90 days · 1 year") }
            ReadoutRow([
                Readout("30 days", SleepBodyFormat.signedKg(w?.monthChangeKg),
                        status: w?.monthChangeKg == nil ? nil : w?.towardGoal == true ? ("Toward goal", .good) : ("Away from goal", .watch)),
                Readout("Goal", w?.goalKg.map { "\(SleepBodyFormat.kg($0)) kg" } ?? "–"),
                Readout("Trend", w?.trendKg.map { "\(SleepBodyFormat.kg($0))" } ?? "–", status: w?.latest?.at.flatMap { BodyCopy.when($0) }.map { ($0, .quiet) }),
            ])
        }
    }

    private var vitalsCard: some View {
        VCard(padding: EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)) {
            VStack(spacing: 0) {
                let rows = v?.vitals ?? []
                ForEach(Array(rows.enumerated()), id: \.element.key) { i, vital in
                    NavigationLink(value: Detail.metric(key: vital.key)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(BodyCopy.label(vital)).vUI(15, weight: 500).lineLimit(1)
                                Text([SleepBodyFormat.vital(vital.value), vital.unit].compactMap { $0 }.joined(separator: " ")).vUI(13, weight: 400, color: VColor.muted)
                            }
                            Spacer(minLength: 8)
                            RangeDot(value: vital.value, range: vital.usualRange, tone: BodyCopy.tone(vital)).frame(width: 84, height: 12)
                            StatusWord(BodyCopy.word(vital), tone: BodyCopy.tone(vital)).frame(width: 62, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
                        }
                        .padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    if i < rows.count - 1 { Rectangle().fill(Color(hex: 0x232323)).frame(height: 1) }
                }
            }
        }
    }

    // MARK: Weight

    /// Today's activity; each figure opens its history.
    private var activityCard: some View {
        let a = v?.activity
        return RowsCard {
            DrillRow(.metric(key: "steps"), value: a?.stepsTarget.map { "of \(SleepBodyFormat.grouped($0))" }) {
                activityLabel("Steps", SleepBodyFormat.grouped(a?.steps))
            }
            DrillRow(.metric(key: "active_kcal"), value: "kcal") { activityLabel("Active energy", a?.activeKcal.map { "\(Int($0.rounded()))" } ?? "–") }
            DrillRow(.metric(key: "exercise_min"), value: a?.exerciseTargetMin.map { "of \($0) min" } ?? "min") {
                activityLabel("Exercise", a?.exerciseMin.map(String.init) ?? "–")
            }
        }
    }

    private func activityLabel(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).vUI(15, weight: 500).frame(width: 112, alignment: .leading)
            Text(value).vFigure(18, color: value == "–" ? VColor.steel : nil)
        }
    }

    private var weight: some View {
        let w = v?.weight
        let hasWeight = w?.latest != nil || w?.trendKg != nil
        return VStack(alignment: .leading, spacing: 0) {
            MonoLabel("Weight · kg trend")
            HStack(alignment: .top, spacing: 0) {
                Text(SleepBodyFormat.kg(w?.trendKg))
                    .vNumber(60, color: w?.trendKg == nil ? VColor.steel : nil)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 147, alignment: .leading)
                VStack(spacing: 0) {
                    ReadingRow("This month", value: SleepBodyFormat.signedKg(w?.monthChangeKg),
                               tint: w?.monthChangeKg == nil ? .steel : w?.towardGoal == true ? .good : .bone)
                    ReadingRow("Goal", value: SleepBodyFormat.kg(w?.goalKg), tint: w?.goalKg == nil ? .steel : .bone, showsRule: false)
                }
                .padding(.top, 12)
            }
            .padding(.top, 4)
            if hasWeight, let w {
                WeightChart(series: w.series).frame(height: 56).padding(.top, 18)
                HStack(alignment: .firstTextBaseline) {
                    MonoLabel(latestCaption(w))
                    Spacer()
                    if !w.series.isEmpty { MonoLabel("\(w.series.count) days") }
                }
                .padding(.top, 14)
                if store.waitingToSync { MonoLabel("Waiting to sync", size: .small).padding(.top, 6) }
            } else if v != nil {
                VStack(alignment: .leading, spacing: 14) {
                    Text("No weight yet").vBody()
                    if store.waitingToSync { MonoLabel("Waiting to sync", size: .small) }
                    SecondaryButton("+ Log weight") { showsLogWeight = true }
                }
                .padding(.top, 16)
            }
        }
    }

    /// `76.6 TODAY · SCALE 07:02`: latest raw reading, its day, source name and time.
    private func latestCaption(_ w: WeightBlock) -> String {
        guard let latest = w.latest else { return SleepBodyFormat.dash }
        var head = SleepBodyFormat.kg(latest.kg)
        var tail = latest.source ?? ""
        if let at = latest.at, let date = APIDate.parse(at), let clock = APIDate.clockText(at) {
            head += " " + StaleState.dayLabel(date, now: Date(), calendar: .current)
            tail += tail.isEmpty ? clock : " \(clock)"
        }
        return tail.isEmpty ? head : "\(head) · \(tail)"
    }

    // MARK: Activity

    private var activity: some View {
        let a = v?.activity
        return VSection(top: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MonoLabel("Activity")
                    Spacer()
                    MonoLabel("Today")
                }
                HStack(alignment: .top, spacing: 0) {
                    stat(SleepBodyFormat.grouped(a?.steps), a?.stepsTarget.map { "of \(SleepBodyFormat.grouped($0)) steps" } ?? "steps")
                        .frame(width: 135, alignment: .leading)
                    stat(SleepBodyFormat.grouped(a?.activeKcal.map { Int($0.rounded()) }), "active kcal")
                        .frame(width: 103, alignment: .leading)
                    stat(SleepBodyFormat.grouped(a?.exerciseMin), a?.exerciseTargetMin.map { "of \($0) min" } ?? "min")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 14)
                WeekBars(stepBars(a), maxHeight: 40).padding(.top, 18)
            }
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).vNumber(32, color: value == SleepBodyFormat.dash ? VColor.steel : nil).lineLimit(1).minimumScaleFactor(0.6)
            MonoLabel(caption).lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    /// Bar heights scale to the larger of the week's steps and the server's target (display only).
    private func stepBars(_ a: BodyResponse.Activity?) -> [WeekBars.Bar] {
        guard let a else { return [] }
        let top = Double(max(a.stepsTarget ?? 0, a.week.compactMap(\.steps).max() ?? 0, 1))
        return a.week.map { d in
            WeekBars.Bar(id: d.day, letter: SleepBodyFormat.letter(d.day), height: Double(d.steps ?? 0) / top, isToday: d.day == v?.day)
        }
    }

    // MARK: Vitals

    private var vitals: some View {
        VSection(top: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MonoLabel("Vitals")
                    Spacer()
                    MonoLabel("vs your typical range")
                }
                .padding(.bottom, 4)
                let rows = v?.vitals ?? []
                ForEach(Array(rows.enumerated()), id: \.element.key) { i, vital in
                    VitalRow(vital: vital)
                    if i < rows.count - 1 { Rule() }
                }
            }
        }
    }

    // MARK: Toast and states

    @ViewBuilder private var toast: some View {
        if let saved = store.lastSaved {
            Toast("Logged \(SleepBodyFormat.kg(saved.kg)) kg" + (saved.healthFailed ? " · not in Health" : "")) {
                Task { await store.undoLastSave() }
            }
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: saved) {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled, store.lastSaved == saved { withAnimation { store.dismissToast() } }
            }
        }
    }

    /// The Outbox can deliver from its own flush without bumping `writesVersion`, so a waiting save re-checks itself.
    private func pollWaiting() async {
        guard live else { return }
        while store.waitingID != nil {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await store.recheckWaiting()
        }
    }

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to your server to see your body data.").vBody()
            SecondaryButton("Try again") { Task { await store.load() } }
        }
        .padding(.top, 24)
    }
}

/// HRV / RESTING HR / SPO2 / BREATHING against the server's usual range; tint from the server's `reading`.
private struct VitalRow: View {
    let vital: BodyResponse.Vital

    private var tint: VTint {
        switch vital.reading { case "better": .good; case "worse": .watch; default: .bone }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(vital.label).vReading(13, tint: .steel).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let p = Self.positions(vital) {
                RangeBar(low: p.low, high: p.high, value: p.value, tint: tint)
            } else {
                Color.clear.frame(width: 92, height: 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(SleepBodyFormat.vital(vital.value)).vNumber(19, color: vital.value == nil ? VColor.steel : tint.color)
                if let unit = vital.unit { MonoLabel(unit, size: .small) }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 78, alignment: .trailing)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }

    /// Places the server's usual range and value on a bar spanning those same numbers plus equal margins (display only).
    static func positions(_ vital: BodyResponse.Vital) -> (low: Double, high: Double, value: Double)? {
        guard let value = vital.value, let range = vital.usualRange, range.count == 2 else { return nil }
        let lo = min(range[0], value), hi = max(range[1], value)
        guard hi > lo else { return (0.5, 0.5, 0.5) }
        let start = lo - (hi - lo) * 0.5, span = (hi - lo) * 2
        return ((range[0] - start) / span, (range[1] - start) / span, (value - start) / span)
    }
}

/// Raw readings as `rawDot` circles, the server's trend as a 2 pt bone line with an end dot, on a 1 pt rule baseline.
struct WeightChart: View {
    let series: [WeightBlock.Point]

    var body: some View {
        Canvas { context, size in
            let values = series.flatMap { [$0.rawKg, $0.trendKg].compactMap { $0 } }
            guard let lo = values.min(), let hi = values.max() else { return }
            let baseline = size.height - 0.5
            let top: CGFloat = 4, bottom = baseline - 10
            let x = { (i: Int) in series.count > 1 ? 4 + (size.width - 8) * CGFloat(i) / CGFloat(series.count - 1) : size.width / 2 }
            let y = { (kg: Double) in hi > lo ? top + (bottom - top) * CGFloat((hi - kg) / (hi - lo)) : (top + bottom) / 2 }

            var base = Path()
            base.move(to: CGPoint(x: 0, y: baseline)); base.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(base, with: .color(VColor.rule), lineWidth: 1)

            for (i, p) in series.enumerated() {
                guard let raw = p.rawKg else { continue }
                context.fill(Path(ellipseIn: CGRect(x: x(i) - 2.2, y: y(raw) - 2.2, width: 4.4, height: 4.4)), with: .color(VColor.rawDot))
            }

            var trend = Path(), drawing = false, last: CGPoint?
            for (i, p) in series.enumerated() {
                guard let kg = p.trendKg else { drawing = false; continue }
                let pt = CGPoint(x: x(i), y: y(kg))
                if drawing { trend.addLine(to: pt) } else { trend.move(to: pt); drawing = true }
                last = pt
            }
            context.stroke(trend, with: .color(VColor.bone), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let last { context.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)), with: .color(VColor.bone)) }
        }
        .accessibilityHidden(true)
    }
}

@MainActor private func previewStore(_ value: BodyResponse?, waiting: Bool = false) -> BodyStore {
    let store = BodyStore(api: { nil }, health: FakeHealthWriter(), writes: BodyPreviewWrites())
    store.preload(value, waiting: waiting)
    return store
}

/// Previews never queue anything.
struct BodyPreviewWrites: BodyStore.Writes {
    func send(_ request: APIRequest) async -> UUID? { nil }
    func drop(_ id: UUID) async -> Bool { true }
    func isPending(_ id: UUID) async -> Bool { false }
}

#Preview("Body · loaded") {
    BodyScreen(store: previewStore(SleepBodyPreviewData.body)).vScreen().onAppear { VFont.register() }
}

#Preview("Body · flagged vitals, no weight yet") {
    BodyScreen(store: previewStore(SleepBodyPreviewData.noWeight)).vScreen().onAppear { VFont.register() }
}

#Preview("Body · waiting to sync") {
    BodyScreen(store: previewStore(SleepBodyPreviewData.body, waiting: true)).vScreen().onAppear { VFont.register() }
}

#Preview("Body · loading") {
    BodyScreen(store: previewStore(nil)).vScreen().onAppear { VFont.register() }
}

#Preview("Body · log weight sheet") {
    BodyScreen(store: previewStore(SleepBodyPreviewData.body), showsLogWeight: true).vScreen().onAppear { VFont.register() }
}


/// Daily weigh-ins as faint dots, the trend as a violet line, the latest trend as a dot.
private struct WeightTrendChart: View {
    let series: [WeightBlock.Point]
    let goal: Double?
    @State private var sx: Double?
    var body: some View {
        Canvas { ctx, size in
            let raws = series.compactMap(\.rawKg), trends = series.compactMap(\.trendKg)
            let all = raws + trends
            guard let lo0 = all.min(), let hi0 = all.max(), series.count > 1 else { return }
            let pad = max((hi0 - lo0) * 0.15, 0.5), lo = lo0 - pad, hi = hi0 + pad
            let h = size.height - 18, w = size.width - 24
            let x = { (i: Int) in CGFloat(i) / CGFloat(series.count - 1) * w }
            let y = { (kg: Double) in h * CGFloat(1 - (kg - lo) / (hi - lo)) }
            for t in stride(from: (lo / 2).rounded(.up) * 2, through: hi, by: 2) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(t))); p.addLine(to: CGPoint(x: w, y: y(t)))
                ctx.stroke(p, with: .color(Color(hex: 0x1C1C1C)), lineWidth: 1)
                ctx.draw(Text(String(Int(t))).font(VFont.mono(11, weight: 600)).foregroundStyle(Color(hex: 0x6E6E6E)), at: CGPoint(x: size.width, y: y(t)), anchor: .trailing)
            }
            for (i, p) in series.enumerated() { if let r = p.rawKg { ctx.fill(Path(ellipseIn: CGRect(x: x(i) - 2, y: y(r) - 2, width: 4, height: 4)), with: .color(Color(hex: 0x4B3F75))) } }
            var line = Path(), started = false, last: CGPoint?
            for (i, p) in series.enumerated() {
                guard let t = p.trendKg else { continue }
                let pt = CGPoint(x: x(i), y: y(t))
                if started { line.addLine(to: pt) } else { line.move(to: pt); started = true }
                last = pt
            }
            ctx.stroke(line, with: .color(VColor.body), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            if let last { ctx.fill(Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)), with: .color(VColor.body)) }
            let first = series.first?.day ?? "", end = series.last?.day ?? ""
            ctx.draw(Text(BodyCopy.short(first)).font(VFont.mono(11, weight: 600)).foregroundStyle(Color(hex: 0x7A7A7A)), at: CGPoint(x: 0, y: size.height - 4), anchor: .leading)
            ctx.draw(Text(BodyCopy.short(end)).font(VFont.mono(11, weight: 600)).foregroundStyle(Color(hex: 0x7A7A7A)), at: CGPoint(x: w, y: size.height - 4), anchor: .trailing)
        }
        .overlay {
            GeometryReader { g in
                if let sx, series.count > 1 {
                    let i = Int((sx * Double(series.count - 1)).rounded()), p = series[i]
                    let px = (g.size.width - 24) * Double(i) / Double(series.count - 1)
                    Rectangle().fill(VColor.bone.opacity(0.5)).frame(width: 1, height: g.size.height - 18).offset(x: px)
                    ChartCallout([BodyCopy.short(p.day), p.rawKg.map { "\(SleepBodyFormat.kg($0)) kg" }, p.trendKg.map { "trend \(SleepBodyFormat.kg($0))" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .position(x: min(max(px, 90), g.size.width - 90), y: 8)
                }
            }
        }
        .scrub($sx)
        .accessibilityLabel("Weight trend")
    }
}

/// Where today's value sits against your usual range: a band and a dot.
private struct RangeDot: View {
    let value: Double?
    let range: [Double]?
    let tone: VTone
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x2A2A2A)).frame(height: 2)
                if let r = range, r.count == 2 {
                    let span = max(r[1] - r[0], 0.0001), lo = r[0] - span, hi = r[1] + span
                    let pos = { (v: Double) in CGFloat(min(max((v - lo) / (hi - lo), 0), 1)) * w }
                    Capsule().fill(Color(hex: 0x3B3359)).frame(width: max(pos(r[1]) - pos(r[0]), 6), height: 6).offset(x: pos(r[0]))
                    if let v = value { Circle().fill(tone == .usual ? VColor.body : tone.color).frame(width: 9, height: 9).offset(x: pos(v) - 4.5) }
                }
            }
            .frame(height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

enum BodyCopy {
    static func headline(_ w: WeightBlock?) -> [String] {
        guard let c = w?.monthChangeKg else { return [w?.trendKg.map { "\(SleepBodyFormat.kg($0)) kg." } ?? "–"] }
        let first = abs(c) < 0.05 ? "Holding steady." : "\(c < 0 ? "Down" : "Up") \(SleepBodyFormat.kg(abs(c))) kg."
        return [first, w?.goalKg.map { "Goal \(SleepBodyFormat.kg($0))." } ?? "This month."]
    }
    static func label(_ v: BodyResponse.Vital) -> String {
        ["hrv": "HRV", "resting_hr": "Resting HR", "spo2": "Blood oxygen", "respiratory_rate": "Breathing", "wrist_temp": "Wrist temp", "vo2max": "VO₂ max"][v.key]
            ?? v.label.capitalized
    }
    static func word(_ v: BodyResponse.Vital) -> String { v.flag == "high" ? "High" : v.flag == "low" ? "Low" : v.value == nil ? "–" : "Usual" }
    static func tone(_ v: BodyResponse.Vital) -> VTone { v.flag == nil ? .usual : .watch }
    static func when(_ iso: String) -> String? {
        guard let clock = APIDate.clockText(iso) else { return nil }
        let day = String(iso.prefix(10)), today = EatStore.iso(Date(), calendar: .current).prefix(10)
        return day == today ? "Weighed \(clock)" : "Weighed \(short(day).capitalized)"
    }
    static func short(_ day: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        f.dateFormat = "d MMM"; return f.string(from: d).uppercased()
    }
}
