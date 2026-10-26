import SwiftUI
import VitalisKit
import VitalisUI

/// Train tab (frame 06, empty frame 26) with Session and Exercise detail pushed in its own stack.
struct TrainScreen: View {
    @State private var store: TrainStore
    private let live: LiveSessionStore
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    init() { self.init(store: .shared, live: .shared) }
    init(store: TrainStore, live: LiveSessionStore) { _store = State(initialValue: store); self.live = live }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            TrainWeekView(store: store, live: live.session, start: start)
                .toolbar(.hidden, for: .navigationBar)
                .detailDestinations()
        }
        .task(id: Services.shared.writesVersion) { await store.load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.load() } } }
    }

    /// A restored session resumes; otherwise the start-choice sheet (which acts on a remembered choice itself).
    private func start() {
        if live.isLive { router.startLoggingOnPhone() } else { router.sheet = .workoutStart }
    }
}

struct TrainWeekView: View {
    let store: TrainStore
    let live: LiveSession?
    let start: () -> Void

    var body: some View {
        let t = store.week.value
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VHeader("Train", freshness: DataFreshness(fetchedAt: store.week.fetchedAt, refreshing: store.week.isLoading)) {
                    if let e = t?.weekEnd { Text(SleepCopy.weekTitle(end: e)).vText(.secondary) }
                }
                if let t, t.empty, store.sessions.isEmpty { TrainEmptyBody(heat: t.heat, start: start) } else { week(t) }
            }
            .padding(.bottom, VSpace.s6)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.load() }
        .vScreen()
    }

    @ViewBuilder private func week(_ t: TrainingResponse?) -> some View {
        let loaded = TrainCopy.loaded(t)
        TabHeadline(lines: TrainCopy.headline(t), color: t == nil ? VColor.text3 : nil).gutter().padding(.top, VSpace.s3)
        // A week with nothing loaded has nothing to read on the map, so it takes less room.
        MuscleMap(heat: t?.heat ?? [:], view: .both).frame(maxWidth: loaded.isEmpty ? 200 : 330).frame(maxWidth: .infinity).padding(.top, VSpace.s4)
        if !loaded.isEmpty {
            CenteredWrap(spacing: VSpace.s3, lineSpacing: VSpace.s1) {
                ForEach(loaded, id: \.0) { name, word in
                    HStack(alignment: .firstTextBaseline, spacing: VSpace.s1) {
                        Text(name).vText(.headline)
                        Text(word).vText(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity).gutter().padding(.top, VSpace.s2)
        }
        TrainLoadError(error: store.week.error, hasValue: t != nil) { Task { await store.load() } }.gutter().padding(.top, VSpace.s2)
        PrimaryButton(live.map { "Resume \($0.title)" } ?? "Start workout", icon: "dumbbell", action: start).gutter().padding(.top, VSpace.s4)
        ListCard { DrillRow("Exercises", value: "Progress", route: .exercises) }.gutter().padding(.top, VSpace.s3)
        SectionLabel("This week", note: t?.stats.map { "\($0.sessions) sessions · \($0.workingSets) sets" })
        WeekTiles(weekStart: t?.weekStart, today: t?.freshness?.today, sessions: store.sessions).gutter()
        if let t, let weekly = t.weeklySets, t.muscles.contains(where: { ($0.weekSets ?? 0) > 0 }) {
            SectionLabel("Sets per muscle", note: "Aim \(weekly.min)–\(weekly.max)")
            VCard { SetsPerMuscle(muscles: t.muscles, weekly: weekly) }.gutter()
        }
        if t != nil { sessionsCard }
    }

    @ViewBuilder private var sessionsCard: some View {
        SectionLabel("All workouts")
        ListCard {
            if store.sessions.isEmpty, !store.isPaging {
                ListRow("No workouts yet", chevron: false)
            }
            ForEach(store.sessions, id: \.id) { row in
                DrillRow(row.kind == "strength" ? (row.title ?? "Workout") : WorkoutCopy.name(row.title ?? "Workout"),
                         subtitle: TrainCopy.sessionLine(row) + (row.partCount.map { " · \($0) parts" } ?? ""), route: .session(id: row.id)) {
                    if row.kind == "strength" {
                        Figure(row.workingSets.map(String.init) ?? "–", unit: "sets", size: 20)
                    } else {
                        Figure(row.hrAvg.map { String(Int($0.rounded())) } ?? "–", unit: "avg bpm", size: 20)
                    }
                }
            }
            if store.hasMore {
                Button { Task { await store.loadMore() } } label: {
                    Text(store.isPaging ? "Loading…" : "Earlier workouts").vText(.headline, color: VColor.text2).frame(maxWidth: .infinity, minHeight: VSpace.rowMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(store.isPaging)
            }
        }
        .gutter()
        if let error = store.pageError as? APIError { Text(error.statusLine).vText(.secondary, color: VColor.watch).gutter().padding(.top, VSpace.s2) }
    }
}

/// Frame 26: no strength session ever logged.
struct TrainEmptyBody: View {
    let heat: MuscleHeat
    let start: () -> Void
    private let steps = ["Tap Start workout", "Log on your Watch or this iPhone", "Name it when you finish, to repeat it later"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabHeadline(lines: ["No workouts yet"]).padding(.top, VSpace.s3)
            MuscleMap(heat: heat, view: .both).frame(width: 200).frame(maxWidth: .infinity).padding(.top, VSpace.s4)
            Text("Every set you log lights up the muscles you trained.").vText(.body, color: VColor.text2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s4)
            ListCard {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: VSpace.s3) {
                        Text("\(i + 1)").vText(.numS, color: VColor.text2).frame(width: 20, alignment: .leading)
                        Text(step).vText(.body).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: VSpace.rowMin).padding(.vertical, VSpace.s3)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, VSpace.s5)
            PrimaryButton("Start workout", icon: "dumbbell", action: start).padding(.top, VSpace.s5)
        }
        .gutter()
    }
}

#if DEBUG
#Preview("Train · week with splits") {
    TrainScreen(store: TrainPreviewData.trainStore(.splits), live: TrainPreviewData.idleLive).environment(Router()).onAppear { VFont.register() }
}
#Preview("Train · week, no splits") {
    TrainScreen(store: TrainPreviewData.trainStore(.fixture), live: TrainPreviewData.idleLive).environment(Router()).onAppear { VFont.register() }
}
#Preview("Train · empty") {
    TrainScreen(store: TrainPreviewData.trainStore(.empty), live: TrainPreviewData.idleLive).environment(Router()).onAppear { VFont.register() }
}
#Preview("Train · loading") {
    TrainScreen(store: TrainStore(api: { nil }), live: TrainPreviewData.idleLive).environment(Router()).onAppear { VFont.register() }
}
#endif

/// Monday to Sunday as seven equal tiles: a workout day tinted with an accent ring and its name, today outlined.
private struct WeekTiles: View {
    let weekStart: String?
    let today: String?
    let sessions: [SessionRow]
    var body: some View {
        let today = today ?? String(EatStore.iso(Date(), calendar: .current).prefix(10))
        HStack(spacing: VSpace.s1) {
            ForEach(0..<7, id: \.self) { i in
                let day = weekStart.flatMap { SleepStore.addDays($0, i) }
                let s = sessions.first { $0.day == day }
                let shape = RoundedRectangle(cornerRadius: VRadius.control, style: .continuous)
                VStack(spacing: VSpace.s1) {
                    Text(s.map { String(($0.title ?? "Done").prefix(5)) } ?? "")
                        .vText(.secondary, color: VColor.text).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(shape.fill(s == nil ? VColor.surface : VColor.accentTint))
                        .overlay {
                            if s != nil { shape.inset(by: 0.75).stroke(VColor.accent, lineWidth: 1.5) }
                            else if day == today { shape.inset(by: 0.75).stroke(VColor.dashed, lineWidth: 1.5) }
                        }
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).vText(.axis, color: day == today ? VColor.text : nil)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Weekly sets per muscle against the aim range; under the range reads in the dimmer red.
private struct SetsPerMuscle: View {
    let muscles: [TrainingResponse.Muscle]
    let weekly: TrainingResponse.WeeklySets
    var body: some View {
        let rows = muscles.filter { ($0.weekSets ?? 0) > 0 }.sorted { ($0.weekSets ?? 0) > ($1.weekSets ?? 0) }.prefix(8)
        let top = Double(max(weekly.max + 4, rows.map { $0.weekSets ?? 0 }.max() ?? 0))
        VStack(spacing: VSpace.s3) {
            ForEach(Array(rows), id: \.slug) { m in
                let n = m.weekSets ?? 0
                ComparisonBar(TrainCopy.name(m.slug), value: n, fraction: Double(n) / top,
                              range: Double(weekly.min) / top...Double(weekly.max) / top,
                              fill: n < weekly.min ? VColor.heat(2) : VColor.accent)
            }
        }
    }
}

/// Lays its children in centred lines that wrap inside the proposed width, so a long row never reaches the screen edge.
private struct CenteredWrap: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for i in line.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var out: [Line] = [], line = Line()
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            let next = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, next > width { out.append(line); line = Line() }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(i)
        }
        if !line.items.isEmpty { out.append(line) }
        return out
    }
}

enum TrainCopy {
    static func name(_ slug: String) -> String { slug.replacingOccurrences(of: "-", with: " ").capitalized }

    /// Muscles carrying load, hottest first: heat 4 "just trained", 3 "loaded", 2 "easing".
    static func loaded(_ t: TrainingResponse?) -> [(String, String)] {
        (t?.muscles ?? []).filter { $0.heat >= 2 }.sorted { ($0.heat, $0.load ?? 0) > ($1.heat, $1.load ?? 0) }.prefix(3)
            .map { (name($0.slug), $0.heat >= 4 ? "just trained" : $0.heat == 3 ? "loaded" : "easing") }
    }

    static func headline(_ t: TrainingResponse?) -> [String] {
        guard let t else { return ["–"] }
        let first = loaded(t).first.map { "\($0.0) loaded." } ?? "All clear."
        return [first, "\(t.stats?.workingSets ?? 0) sets this week."]
    }

    static func sessionLine(_ r: SessionRow) -> String {
        [SleepCopy.dayTitle(r.day), r.start.flatMap(APIDate.clockText), r.durationMin.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")
    }
}
