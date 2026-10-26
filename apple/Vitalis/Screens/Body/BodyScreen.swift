import Charts
import SwiftUI
import VitalisKit
import VitalisUI

/// Body tab (frame 05, brief 03 → Body): weight trend, heart, vitals vs usual, activity; `+ Weight` opens the sheet.
struct BodyScreen: View {
    @State private var store: BodyStore
    @State private var showsLogWeight = false
    @State private var path = Detail.launchPath("body")
    @Environment(Services.self) private var services: Services?
    @Environment(\.scenePhase) private var scenePhase
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
                VHeader("Body", freshness: DataFreshness(fetchedAt: store.body.fetchedAt, refreshing: store.body.isLoading)) {
                    PillButton("+ Weight", fill: VColor.body, ink: VColor.onBody) { showsLogWeight = true }.accessibilityLabel("Log weight")
                }
                if v == nil, store.body.error != nil, !store.body.isLoading {
                    unreachable.gutter()
                } else {
                    TabHeadline(lines: BodyCopy.headline(v?.weight), color: v == nil ? VColor.text3 : nil).gutter().padding(.top, VSpace.s3)
                    weightHero.gutter().id(BodySection.weight)
                    SectionLabel("Heart")
                    HeartTodayCard(store: .shared, live: live).gutter()
                    SectionLabel("Vitals", note: "vs usual").id(BodySection.vitals)
                    vitalsCard.gutter()
                    SectionLabel("Activity", note: "Today").id(BodySection.activity)
                    activityCard.gutter()
                    ListCard { DrillRow("All health data", value: "Every metric", route: .allData) }.gutter().padding(.top, VSpace.s5)
                }
            }
            .padding(.bottom, VSpace.s6)
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
        .refreshable { if live { await reload() } }
        .task(id: services?.writesVersion) { if live { await store.load() } }
        .onChange(of: scenePhase) { _, phase in if live, phase == .active { Task { await reload() } } }
        .task(id: store.waitingID) { await pollWaiting() }
        .sheet(isPresented: $showsLogWeight) { LogWeightSheet(store: store) }
    }

    /// Pull and foreground: the body read plus today's heart card.
    private func reload() async {
        await store.load()
        await ExploreStore.shared.loadHeart(nil)
    }

    // MARK: Weight

    private var weightHero: some View {
        let w = v?.weight
        return VStack(alignment: .leading, spacing: VSpace.s3) {
            // The number you stepped on the scale with; the smoothed trend sits in the readouts.
            VStack(alignment: .leading, spacing: VSpace.s1) {
                Figure(SleepBodyFormat.kg(w?.latest?.kg ?? w?.trendKg), unit: w?.latest == nil ? "kg trend" : "kg", size: 56,
                       color: w?.latest == nil && w?.trendKg == nil ? VColor.text3 : nil)
                if store.waitingToSync { Text("Waiting to sync").vText(.secondary, color: VColor.watch) }
            }
            .padding(.top, VSpace.s4)
            WeightTrendChart(series: w?.series ?? []).frame(height: 160)
            ListCard { DrillRow("Weight history", value: "90 days · 1 year", route: .metric(key: "weight_kg")) }
            ReadoutRow([
                Readout("30 days", SleepBodyFormat.signedKg(w?.monthChangeKg),
                        status: w?.monthChangeKg == nil ? nil : w?.towardGoal == true ? ("Toward goal", .good) : ("Away from goal", .watch)),
                Readout("Goal", w?.goalKg.map { "\(SleepBodyFormat.kg($0)) kg" } ?? "–"),
                Readout("Trend", w?.trendKg.map { "\(SleepBodyFormat.kg($0))" } ?? "–", status: w?.latest?.at.flatMap { BodyCopy.when($0) }.map { ($0, .quiet) }),
            ])
        }
    }

    // MARK: Vitals and activity

    private var vitalsCard: some View {
        ListCard {
            ForEach(v?.vitals ?? [], id: \.key) { vital in
                DrillRow(BodyCopy.label(vital), subtitle: [SleepBodyFormat.vital(vital.value), vital.unit].compactMap { $0 }.joined(separator: " "),
                         route: .metric(key: vital.key)) {
                    RangeDot(value: vital.value, range: vital.usualRange, tone: BodyCopy.tone(vital)).frame(width: 84, height: 12)
                    StatusWord(BodyCopy.word(vital), tone: BodyCopy.tone(vital)).frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    /// Today's activity; each figure opens its history.
    private var activityCard: some View {
        let a = v?.activity
        return ListCard {
            DrillRow("Steps", route: .metric(key: "steps")) {
                activityFigure(SleepBodyFormat.grouped(a?.steps), a?.stepsTarget.map { "of \(SleepBodyFormat.grouped($0))" })
            }
            DrillRow("Active energy", route: .metric(key: "active_kcal")) {
                activityFigure(a?.activeKcal.map { "\(Int($0.rounded()))" } ?? "–", "kcal")
            }
            DrillRow("Exercise", route: .metric(key: "exercise_min")) {
                activityFigure(a?.exerciseMin.map(String.init) ?? "–", a?.exerciseTargetMin.map { "of \($0) min" } ?? "min")
            }
        }
    }

    private func activityFigure(_ value: String, _ unit: String?) -> some View {
        Figure(value, unit: unit, size: 20, color: value == SleepBodyFormat.dash ? VColor.text3 : nil)
    }

    // MARK: Toast and states

    @ViewBuilder private var toast: some View {
        if let saved = store.lastSaved {
            Toast("Logged \(SleepBodyFormat.kg(saved.kg)) kg" + (saved.healthFailed ? " · not in Health" : "")) {
                Task { await store.undoLastSave() }
            }
            .padding(.bottom, VSpace.s4)
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
        VStack(alignment: .leading, spacing: VSpace.s4) {
            Text("Connect to your server to see your body data.").vText(.body, color: VColor.text2)
            SecondaryButton("Try again") { Task { await store.load() } }
        }
        .padding(.top, VSpace.s5)
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



/// Daily weigh-ins as faint dots, the trend as a violet line ending in a dot. The y domain hugs the data, so the line
/// fills the plot; kg labels sit in the right lane, dates 8 below. Drag to read a day.
private struct WeightTrendChart: View {
    let series: [WeightBlock.Point]
    @State private var selected: Date?

    private struct P: Identifiable { let id: String; let date: Date; let raw: Double?; let trend: Double? }

    var body: some View {
        let pts = series.compactMap { p in TrainFormat.day(p.day).map { P(id: p.day, date: $0, raw: p.rawKg, trend: p.trendKg) } }
        let kgs = pts.flatMap { [$0.raw, $0.trend].compactMap { $0 } }
        let lo = kgs.min() ?? 0, hi = kgs.max() ?? 1, pad = max((hi - lo) * 0.05, 0.2)
        let last = pts.last { $0.trend != nil }
        let pick = selected.flatMap { s in pts.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        Chart {
            ForEach(pts) { p in
                if let r = p.raw {
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Weigh-in", r)).symbolSize(14).foregroundStyle(VColor.body.opacity(0.35))
                }
            }
            ForEach(pts) { p in
                if let t = p.trend {
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Trend", t), series: .value("Series", "trend"))
                        .foregroundStyle(VColor.body).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }
            }
            if let last, let t = last.trend {
                PointMark(x: .value("Day", last.date, unit: .day), y: .value("Trend", t)).symbolSize(70).foregroundStyle(VColor.body)
            }
            if let pick {
                RuleMark(x: .value("Day", pick.date, unit: .day)).foregroundStyle(VColor.chevron).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout([MetricFormat.day(pick.id), pick.raw.map { "\(SleepBodyFormat.kg($0)) kg" }, pick.trend.map { "trend \(SleepBodyFormat.kg($0))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .vChartDateAxis(.dateTime.day().month(.abbreviated), count: 3)
        .vChartYAxis()
        .chartEmpty(pts.count < 2, "No weigh-ins yet")
        .accessibilityLabel("Weight trend")
    }
}

/// Where today's value sits against your usual range: the range as a band on the track, and a dot.
private struct RangeDot: View {
    let value: Double?
    let range: [Double]?
    let tone: VTone
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(VColor.barTrack).frame(height: 2)
                if let r = range, r.count == 2 {
                    let span = max(r[1] - r[0], 0.0001), lo = r[0] - span, hi = r[1] + span
                    let pos = { (v: Double) in CGFloat(min(max((v - lo) / (hi - lo), 0), 1)) * w }
                    Capsule().fill(VColor.range).frame(width: max(pos(r[1]) - pos(r[0]), 6), height: 6).offset(x: pos(r[0]))
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
