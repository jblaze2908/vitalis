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
                .navigationDestination(for: TrainRoute.self) { route in
                    switch route {
                    case .session(let id): SessionDetailScreen(store: store, id: id)
                    case .exercise(let id, let back): ExerciseDetailScreen(store: store, id: id, back: back)
                    }
                }
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
        VStack(spacing: 0) {
            TrainTopBar(status: status(t).0, tint: status(t).1, pulse: store.pulse)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let t, t.empty { TrainEmptyBody(heat: t.heat, start: start) } else { week(t) }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, VSpace.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .vScreen()
    }

    private func status(_ t: TrainingResponse?) -> (String, VTint) {
        if let t, t.empty { return ("\(TrainFormat.int(t.stats?.workingSets)) sets this week", .steel) }
        return trainStatus(t?.freshness, fetchedAt: store.week.fetchedAt, failed: store.week.error != nil)
    }

    @ViewBuilder private func week(_ t: TrainingResponse?) -> some View {
        ScreenHeader(context: t?.label ?? "This week", title: "Train")
            .padding(.top, VSpace.sectionTop)
        VStack(spacing: 16) {
            MuscleMap(heat: t?.heat ?? [:], view: .both).frame(width: 220)
            HeatLegend()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VSpace.sectionTop)

        TrainLoadError(error: store.week.error, hasValue: t != nil) { Task { await store.load() } }
            .padding(.top, VSpace.sectionPad)

        if let live {
            VSection { PrimaryButton("Resume \(live.title)", action: start) }
        } else if t != nil {
            VSection {
                if let splits = t?.splits, !splits.isEmpty {
                    MonoLabel(Self.readyLine(splits))
                }
                PrimaryButton("Start workout", action: start).padding(.top, t?.splits?.isEmpty ?? true ? 0 : 14)
            }
        }

        VSection {
            HStack(alignment: .top) {
                StatColumn(value: TrainFormat.int(t?.stats?.sessions), label: "Sessions")
                StatColumn(value: TrainFormat.int(t?.stats?.workingSets), label: "Working sets")
                StatColumn(value: TrainFormat.int(t?.stats?.musclesHit),
                           suffix: t?.stats.map { "/\($0.musclesTotal)" }, label: "Muscles hit")
            }
        }

        if t != nil { sessions }
        if let t, let weekly = t.weeklySets, !t.muscles.isEmpty { WeeklySetsSection(muscles: t.muscles, weekly: weekly) }
    }

    /// "Fresh · Push · Lower" or "All splits loaded"; the start sheet is where one gets picked.
    static func readyLine(_ splits: [Split]) -> String {
        let ready = splits.filter(\.ready).map(\.name)
        return ready.isEmpty ? "All splits loaded" : "Fresh · " + ready.joined(separator: " · ")
    }

    @ViewBuilder private var sessions: some View {
        VSection {
            MonoLabel("Sessions")
            VStack(spacing: 0) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Rule() }
                    NavigationLink(value: TrainRoute.session(id: row.id)) { SessionRowView(row: row) }
                        .buttonStyle(.plain)
                }
            }
            if store.hasMore {
                Button { Task { await store.loadMore() } } label: {
                    MonoLabel(store.isPaging ? "Loading…" : "Earlier sessions", tint: .bone)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isPaging)
            }
            if let error = store.pageError as? APIError { MonoLabel(error.statusLine, tint: .watch) }
        }
    }
}

/// FRESH / RECOVERING / LOADED with 8 pt squares in the heat colours.
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
struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        let day = TrainFormat.day(row.day)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(day.map { TrainFormat.dayText($0, "EEE") } ?? TrainFormat.dash)
                Text(day.map { TrainFormat.dayText($0, "d") } ?? TrainFormat.dash).vNumber(20)
            }
            .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title ?? "Workout").vHeadline(21).lineLimit(1).minimumScaleFactor(0.7)
                MonoLabel(detail, size: .small)
            }
            Spacer(minLength: 12)
            if let tag = row.tag { MonoLabel(tag.label, tint: tag.kind == "pr" ? .good : .steel) }
        }
        .frame(minHeight: 52)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
        let minutes = "\(TrainFormat.int(row.durationMin)) min"
        if row.kind == "cardio" { return "\(minutes) · avg \(TrainFormat.int(row.hrAvg.map { Int($0.rounded()) })) bpm" }
        return "\(minutes) · \(TrainFormat.int(row.workingSets)) sets"
    }
}

/// This week's working sets per muscle against the owner's weekly range; tint from the server's `status`.
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
