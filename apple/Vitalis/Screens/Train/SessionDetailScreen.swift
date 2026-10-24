import SwiftUI
import VitalisKit
import VitalisUI

/// Session detail (frame 09): session heat, sets / volume / avg bpm, exercise rows → Exercise detail. No red action.
struct SessionDetailScreen: View {
    let store: TrainStore
    let id: String

    var body: some View {
        let detail = store.session(id)
        let status = trainStatus(detail.value?.freshness, fetchedAt: detail.fetchedAt, failed: detail.error != nil)
        VStack(spacing: 0) {
            TrainTopBar(status: status.0, tint: status.1, pulse: store.pulse)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BackLink(title: "Train").padding(.top, VSpace.rowPad)
                    if let d = detail.value {
                        if d.isCardio { cardio(d) } else { strength(d) }
                        if let error = detail.error as? APIError { MonoLabel(error.statusLine, tint: .watch).padding(.top, VSpace.sectionPad) }
                    } else {
                        placeholder
                        // Just finished on this phone: the outbox may not have delivered it yet, so keep the loading layout.
                        if !(store.isPending(id) && (detail.error as? APIError) == .notFound) {
                            TrainLoadError(error: detail.error, hasValue: false) { Task { await store.loadSession(id) } }
                                .padding(.top, VSpace.sectionTop)
                        }
                    }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, VSpace.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .trainPushed()
        .task(id: Services.shared.writesVersion) { await store.loadSession(id) }
    }

    @ViewBuilder private func strength(_ d: SessionDetail) -> some View {
        ScreenHeader(context: d.contextLabel ?? TrainFormat.dash, title: d.title ?? "Workout")
        MuscleMap(heat: d.heat ?? [:], view: .both).frame(width: 230).frame(maxWidth: .infinity).padding(.top, VSpace.sectionTop)
        VSection {
            HStack(alignment: .top) {
                StatColumn(value: TrainFormat.int(d.workingSets), label: "Sets")
                StatColumn(value: TrainFormat.grouped(d.volumeKg), label: "Kg volume")
                StatColumn(value: TrainFormat.int(d.avgBpm.map { Int($0.rounded()) }), label: "Avg bpm")
            }
        }
        if let exercises = d.exercises, !exercises.isEmpty {
            VSection(top: VSpace.sectionTop) {
                VStack(spacing: 0) {
                    ForEach(Array(exercises.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Rule() }
                        NavigationLink(value: TrainRoute.exercise(id: e.id, back: d.title ?? "Session")) { ExerciseRowView(exercise: e) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Watch-only workouts return the `hk_workouts` row: name, duration, heart rate, energy, distance.
    @ViewBuilder private func cardio(_ d: SessionDetail) -> some View {
        ScreenHeader(context: cardioContext(d), title: d.name ?? d.title ?? "Workout")
        VSection {
            HStack(alignment: .top) {
                StatColumn(value: TrainFormat.int(d.durationS.map { Int(($0 / 60).rounded()) } ?? d.durationMin), label: "Min")
                StatColumn(value: TrainFormat.int(d.hrAvg.map { Int($0.rounded()) }), label: "Avg bpm")
                StatColumn(value: TrainFormat.grouped(d.activeKcal), label: "Kcal")
            }
        }
        if let km = d.distanceKm {
            VSection { ReadingRow("Distance", value: "\(TrainFormat.kg(km)) km", showsRule: false) }
        }
    }

    private func cardioContext(_ d: SessionDetail) -> String {
        let day = TrainFormat.day(d.day).map { TrainFormat.dayText($0, "EEE d MMM") }
        let clock = d.start.flatMap(APIDate.clockText)
        return [day, clock, d.source].compactMap { $0 }.joined(separator: " · ")
    }

    /// Loading / no-cache layout: labels with `–` values.
    @ViewBuilder private var placeholder: some View {
        ScreenHeader(context: TrainFormat.dash, title: TrainFormat.dash)
        MuscleMap(heat: MuscleHeat(), view: .both).frame(width: 230).frame(maxWidth: .infinity).padding(.top, VSpace.sectionTop)
        VSection {
            HStack(alignment: .top) {
                StatColumn(value: TrainFormat.dash, label: "Sets")
                StatColumn(value: TrainFormat.dash, label: "Kg volume")
                StatColumn(value: TrainFormat.dash, label: "Avg bpm")
            }
        }
    }
}

/// Exercise row (52): name, `4 SETS · TOP 82.5 X 6`, PR in good, chevron.
struct ExerciseRowView: View {
    let exercise: SessionDetail.Exercise

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.name).vHeadline(21).lineLimit(1).minimumScaleFactor(0.6)
                MonoLabel(exercise.summary ?? TrainFormat.plural(exercise.workingSets, "set", "sets"))
            }
            Spacer(minLength: 0)
            if exercise.pr { MonoLabel("PR", tint: .good) }
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(VColor.steel)
        }
        .frame(minHeight: 52)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#if DEBUG
#Preview("Session detail") {
    let store = TrainPreviewData.trainStore(.fixture)
    return NavigationStack { SessionDetailScreen(store: store, id: "7ad4a98b-290a-4d12-b99a-c3ab21b20d1d") }
        .onAppear { VFont.register() }
}
#Preview("Session detail · loading") {
    NavigationStack { SessionDetailScreen(store: TrainStore(api: { nil }), id: "missing") }.onAppear { VFont.register() }
}
#endif
