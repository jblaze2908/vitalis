import SwiftUI
import VitalisKit
import VitalisUI

/// Body tab (frame 05, brief 03 → Body): weight trend, activity, vitals vs typical range; `+ Log weight` opens the sheet.
struct BodyScreen: View {
    @State private var store: BodyStore
    @State private var showsLogWeight = false
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
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabTopChrome(status: TabTopChrome.status(store.body, freshness: v?.freshness))
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(context: v.map { SleepBodyFormat.dayTitle($0.day) } ?? "Today", title: "Body") {
                        SecondaryButton("+ Log weight") { showsLogWeight = true }
                    }
                    .padding(.top, 2)
                    if v == nil, store.body.error != nil, !store.body.isLoading {
                        unreachable
                    } else {
                        weight.padding(.top, 22).id(BodySection.weight)
                        activity.id(BodySection.activity)
                        vitals.id(BodySection.vitals)
                    }
                }
                .padding(.horizontal, VSpace.gutter)
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

    // MARK: Weight

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
