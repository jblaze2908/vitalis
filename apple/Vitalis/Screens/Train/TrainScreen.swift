import SwiftUI
import VitalisKit
import VitalisUI

/// Train tab (frame 06, empty frame 26) with Session and Exercise detail pushed in its own stack.
struct TrainScreen: View {
    @State private var store: TrainStore
    private let live: LiveSessionStore
    @Environment(Router.self) private var router

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
                TabHeader("Train") { if let e = t?.weekEnd { Text(SleepCopy.weekTitle(end: e)).vUI(13, weight: 600, color: VColor.muted) } }.padding(.horizontal, 20).padding(.top, 2)
                if let t, t.empty, store.sessions.isEmpty { TrainEmptyBody(heat: t.heat, start: start).padding(.horizontal, VSpace.gutter) } else { week(t) }
            }
            .padding(.bottom, VSpace.gutter)
        }
        .scrollIndicators(.hidden)
        .vScreen()
    }

    @ViewBuilder private func week(_ t: TrainingResponse?) -> some View {
        HeadlineLines(TrainCopy.headline(t), size: 36, colors: t == nil ? [VColor.steel] : []).padding(.horizontal, 20).padding(.top, 9)
        MuscleMap(heat: t?.heat ?? [:], view: .both).frame(maxWidth: 330).frame(maxWidth: .infinity).padding(.top, 14)
        let loaded = TrainCopy.loaded(t)
        if !loaded.isEmpty {
            HStack(spacing: 14) {
                ForEach(loaded, id: \.0) { name, word in
                    (Text(name).font(VFont.archivo(13, width: 100, weight: 600)).foregroundStyle(VColor.bone)
                     + Text(" \(word)").font(VFont.archivo(13, width: 100, weight: 400)).foregroundStyle(VColor.muted))
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 8)
        }
        TrainLoadError(error: store.week.error, hasValue: t != nil) { Task { await store.load() } }.padding(.horizontal, 20).padding(.top, 8)
        Button(action: start) {
            HStack(spacing: 10) {
                Image(systemName: "dumbbell").font(.system(size: 17, weight: .semibold))
                Text(live.map { "Resume \($0.title)" } ?? "Start workout").vUI(17, weight: 700, color: Color(hex: 0x1A0503))
            }
            .foregroundStyle(Color(hex: 0x1A0503))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(VColor.pulse, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 16)
        RowsCard {
            DrillRow(.exercises, value: "Progress") {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 14, weight: .semibold)).foregroundStyle(VColor.muted).frame(width: 20)
                    Text("Exercises").vUI(15, weight: 500)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
        HStack {
            Text("This week").vLabel()
            Spacer()
            if let st = t?.stats { Text("\(st.sessions) sessions · \(st.workingSets) sets").vLabel() }
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
        WeekTiles(weekStart: t?.weekStart, sessions: store.sessions).padding(.horizontal, 16)
        if let t, let weekly = t.weeklySets, t.muscles.contains(where: { ($0.weekSets ?? 0) > 0 }) {
            HStack { Text("Sets per muscle").vLabel(); Spacer(); Text("Aim \(weekly.min)–\(weekly.max)").vLabel() }
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 10)
            SetsBars(muscles: t.muscles, weekly: weekly).padding(.horizontal, 20)
        }
        if t != nil { sessionsCard }
    }

    @ViewBuilder private var sessionsCard: some View {
        Text("All workouts").vLabel()
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
        VCard(padding: EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)) {
            VStack(spacing: 0) {
                if store.sessions.isEmpty, !store.isPaging {
                    Text("No workouts yet").vUI(14, weight: 500, color: VColor.muted).frame(maxWidth: .infinity, minHeight: 48)
                }
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Rectangle().fill(Color(hex: 0x232323)).frame(height: 1) }
                    NavigationLink(value: Detail.session(id: row.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.kind == "strength" ? (row.title ?? "Workout") : WorkoutCopy.name(row.title ?? "Workout")).vUI(15, weight: 500)
                                Text(TrainCopy.sessionLine(row) + (row.partCount.map { " · \($0) parts" } ?? "")).vUI(13, weight: 400, color: VColor.muted)
                            }
                            Spacer()
                            if row.kind == "strength" {
                                Figure(row.workingSets.map(String.init) ?? "–", unit: "sets", size: 17)
                            } else {
                                Figure(row.hrAvg.map { String(Int($0.rounded())) } ?? "–", unit: "avg bpm", size: 17)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
                        }
                        .padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if store.hasMore {
                    Button { Task { await store.loadMore() } } label: {
                        Text(store.isPaging ? "Loading…" : "Earlier workouts").vUI(14, weight: 600, color: VColor.muted).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).disabled(store.isPaging)
                }
            }
        }
        .padding(.horizontal, 16)
        if let error = store.pageError as? APIError { MonoLabel(error.statusLine, tint: .watch).padding(.horizontal, 20) }
    }

    static func readyLine(_ splits: [Split]) -> String {
        let ready = splits.filter(\.ready).map(\.name)
        return ready.isEmpty ? "All splits loaded" : "Fresh · " + ready.joined(separator: " · ")
    }

}

struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            item(1, "Fresh"); item(2, "Recovering"); item(4, "Loaded")
        }
        .accessibilityHidden(true)
    }

    private func item(_ level: Int, _ name: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(VColor.heat(level)).frame(width: 8, height: 8)
            MonoLabel(name, size: .small)
        }
    }
}

/// Sessions list row (52): day + date, title + duration line, PR / CARDIO tag.
struct WeeklySetsSection: View {
    let muscles: [TrainingResponse.Muscle]
    let weekly: TrainingResponse.WeeklySets

    var body: some View {
        VSection {
            HStack {
                MonoLabel("Sets per muscle")
                Spacer()
                MonoLabel("\(weekly.min)–\(weekly.max) a week")
            }
            .padding(.bottom, VSpace.rowPad)
            ForEach(Array(muscles.enumerated()), id: \.element.slug) { i, m in
                ReadingRow(m.slug.replacingOccurrences(of: "-", with: " "),
                           value: TrainFormat.int(weekly.byMuscle[m.slug] ?? m.weekSets),
                           tint: m.status == "in_range" ? .good : m.status == "over" ? .watch : .bone,
                           showsRule: i < muscles.count - 1)
            }
        }
    }
}

/// Frame 26: no strength session ever logged.
struct TrainEmptyBody: View {
    let heat: MuscleHeat
    let start: () -> Void
    private let steps = ["Tap Start workout", "Log on your Watch or this iPhone", "Name it when you finish, to repeat it later"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeadlineLines(["Train"], size: 46).padding(.top, VSpace.sectionTop)
            MuscleMap(heat: heat, view: .both).frame(width: 240).frame(maxWidth: .infinity).padding(.top, VSpace.sectionTop)
            Text("No workouts yet").vHeadline(30).padding(.top, 28)
            Text("Every set you log lights up the muscles you trained.").vBody(15)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    Rule()
                    HStack(spacing: 0) {
                        MonoLabel(String(format: "%02d", i + 1)).frame(width: 36, alignment: .leading)
                        Text(step).vBody(16, color: VColor.bone)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 47)
                }
                Rule()
            }
            .padding(.top, VSpace.sectionTop)
            PrimaryButton("Start workout", action: start).padding(.top, VSpace.sectionTop)
        }
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


/// Monday to Sunday as tiles; a day with a session shows its name in a red ring.
private struct WeekTiles: View {
    let weekStart: String?
    let sessions: [SessionRow]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = weekStart.flatMap { SleepStore.addDays($0, i) }
                let s = sessions.first { $0.day == day }
                VStack(spacing: 6) {
                    Text(s.map { String(($0.title ?? "Done").prefix(5)).uppercased() } ?? "")
                        .font(VFont.archivo(10.5, width: 100, weight: 700)).foregroundStyle(VColor.bone).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(s == nil ? Color(hex: 0x141414) : Color(hex: 0x2B1412)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(s == nil ? .clear : VColor.pulse, lineWidth: 1.5))
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).vUI(11, weight: 600, color: Color(hex: 0x7A7A7A))
                }
            }
        }
    }
}

/// Weekly sets per muscle against the aim band; under the band reads amber.
private struct SetsBars: View {
    let muscles: [TrainingResponse.Muscle]
    let weekly: TrainingResponse.WeeklySets
    var body: some View {
        let rows = muscles.filter { ($0.weekSets ?? 0) > 0 }.sorted { ($0.weekSets ?? 0) > ($1.weekSets ?? 0) }.prefix(8)
        let top = Double(max(weekly.max + 4, rows.map { $0.weekSets ?? 0 }.max() ?? 0))
        VStack(spacing: 10) {
            ForEach(Array(rows), id: \.slug) { m in
                let n = m.weekSets ?? 0
                HStack(spacing: 10) {
                    Text(TrainCopy.name(m.slug)).vUI(14, weight: 500).frame(width: 84, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        let w = g.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(hex: 0x1A1A1A))
                            Rectangle().fill(Color(hex: 0x2A2A2A)).frame(width: w * Double(weekly.max - weekly.min) / top).offset(x: w * Double(weekly.min) / top)
                            Capsule().fill(n < weekly.min ? Color(hex: 0x8F352E) : VColor.pulse).frame(width: max(6, w * Double(n) / top))
                        }
                    }
                    .frame(height: 6)
                    Text("\(n)").vLabel().frame(width: 26, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
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
