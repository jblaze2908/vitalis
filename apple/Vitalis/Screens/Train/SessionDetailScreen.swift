import SwiftUI
import VitalisKit
import VitalisUI

/// One workout: headline numbers, the heart-rate line with each set ticked on it, the muscles it loaded, and every set.
struct SessionDetailScreen: View {
    let store: TrainStore
    let id: String

    var body: some View {
        let detail = store.session(id), d = detail.value
        DetailScaffold(d.map { $0.isCardio ? WorkoutCopy.name($0.name ?? $0.title ?? "Workout") : ($0.title ?? "Workout") } ?? "Workout",
                       subtitle: d.map(subtitle)) {
            if let d {
                if d.isCardio { cardio(d) } else { strength(d) }
                if let error = detail.error as? APIError { MonoLabel(error.statusLine, tint: .watch).padding(.top, 12) }
            } else if store.isPending(id) && (detail.error as? APIError) == .notFound {
                Text("Saving your workout…").vUI(15, weight: 500, color: VColor.muted).padding(.top, 40)
            } else {
                LoadState(error: detail.error) { Task { await store.loadSession(id) } }.padding(.top, 40)
            }
        }
        .task(id: Services.shared.writesVersion) { await store.loadSession(id) }
    }

    private func subtitle(_ d: SessionDetail) -> String {
        let day = (d.day ?? d.start.map { String($0.prefix(10)) }).map { MetricFormat.day($0, "EEE d MMM") }
        let minutes = d.durationMin ?? d.durationS.map { Int(($0 / 60).rounded()) }
        return [day, d.start.flatMap(APIDate.clockText), minutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func strength(_ d: SessionDetail) -> some View {
        ReadoutRow([
            Readout("Sets", TrainFormat.int(d.workingSets)),
            Readout("Volume", d.volumeKg.map { "\(TrainFormat.grouped($0)) kg" } ?? TrainFormat.dash),
            Readout("Avg HR", (d.hr?.avg ?? d.avgBpm.map { Int($0.rounded()) }).map { "\($0)" } ?? TrainFormat.dash, status: d.hr.map { ("max \($0.max)", .quiet) }),
        ])
        .padding(.top, 8)
        heart(d, sets: setOffsets(d))
        partsCard(d)
        if let heat = d.heat, !heat.isEmpty {
            DetailSection("Muscles worked")
            VCard { MuscleMap(heat: heat, view: .both, seam: VColor.card).frame(height: 150).frame(maxWidth: .infinity) }
        }
        if let exercises = d.exercises, !exercises.isEmpty {
            DetailSection("Exercises", trailing: "\(exercises.count)")
            VStack(spacing: 10) { ForEach(exercises, id: \.id) { ExerciseSetsCard(exercise: $0) } }
        }
    }

    @ViewBuilder private func cardio(_ d: SessionDetail) -> some View {
        ReadoutRow([
            Readout("Time", TrainFormat.int(d.durationS.map { Int(($0 / 60).rounded()) } ?? d.durationMin) + " min"),
            Readout("Distance", d.distanceKm.map { "\(TrainFormat.kg($0)) km" } ?? TrainFormat.dash),
            Readout("Active", d.activeKcal.map { "\(TrainFormat.grouped($0)) kcal" } ?? TrainFormat.dash),
        ])
        .padding(.top, 8)
        heart(d, sets: [])
        partsCard(d)
        if d.hr == nil, d.hrAvg != nil {
            ReadoutRow([Readout("Avg HR", TrainFormat.int(d.hrAvg.map { Int($0.rounded()) })), Readout("Max HR", TrainFormat.int(d.hrMax.map { Int($0.rounded()) })),
                        Readout("Min HR", TrainFormat.int(d.hrMin.map { Int($0.rounded()) }))]).padding(.top, 14)
        }
        if let source = d.source { Text("Recorded by \(source)").vUI(12, weight: 400, color: VColor.muted).padding(.top, 14) }
    }

    @ViewBuilder private func heart(_ d: SessionDetail, sets: [Double]) -> some View {
        if let hr = d.hr, hr.points.count > 1 {
            DetailSection("Heart rate", trailing: "\(hr.min)–\(hr.max) bpm")
            VCard {
                VStack(alignment: .leading, spacing: 8) {
                    WorkoutHeartChart(hr: hr, sets: sets, spans: spans(d)).frame(height: 180)
                    if !sets.isEmpty { Text("Each tick is a set. Drag to read.").vUI(11, weight: 500, color: Color(hex: 0x6E6E6E)) }
                }
            }
            if let day = d.day ?? d.start.map({ String($0.prefix(10)) }) {
                RowsCard { DrillRow("Heart rate that day", route: .heart(day: day)) }.padding(.top, 10)
            }
        }
    }

    /// The Watch workouts inside a visit, in seconds from the heart-rate line's start, shaded on the chart.
    private func spans(_ d: SessionDetail) -> [ClosedRange<Double>] {
        guard let start = APIDate.parse(d.hr?.start ?? d.start), let parts = d.parts, parts.count > 1 else { return [] }
        return parts.filter { $0.kind == "cardio" }.compactMap { p in
            guard let a = APIDate.parse(p.start), let b = APIDate.parse(p.end) else { return nil }
            return a.timeIntervalSince(start)...max(b.timeIntervalSince(start), a.timeIntervalSince(start))
        }
    }

    /// Every workout this visit merged: the Watch saves each activity on its own.
    @ViewBuilder private func partsCard(_ d: SessionDetail) -> some View {
        if let parts = d.parts, parts.count > 1 {
            DetailSection("In this visit", trailing: "\(parts.count)")
            RowsCard {
                ForEach(parts, id: \.id) { p in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.kind == "strength" ? (p.title ?? "Workout") : WorkoutCopy.name(p.title ?? "Workout")).vUI(15, weight: 500)
                            Text([APIDate.clockText(p.start), APIDate.clockText(p.end)].compactMap { $0 }.joined(separator: "–") + " · \(p.durationMin) min")
                                .vUI(12, weight: 400, color: VColor.muted)
                        }
                        Spacer(minLength: 8)
                        Text(partStat(p)).vUI(13, weight: 500, color: VColor.muted).lineLimit(1)
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func partStat(_ p: SessionDetail.Part) -> String {
        if p.kind == "strength" { return TrainFormat.plural(p.workingSets ?? 0, "set", "sets") }
        return [p.hrAvg.map { "\(Int($0.rounded())) bpm" }, p.activeKcal.map { "\(Int($0.rounded())) kcal" }, p.distanceKm.map { "\(TrainFormat.kg($0)) km" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func setOffsets(_ d: SessionDetail) -> [Double] {
        guard let start = APIDate.parse(d.hr?.start ?? d.start) else { return [] }
        return (d.exercises ?? []).flatMap(\.sets).filter { $0.kind != "warmup" }.compactMap { APIDate.parse($0.at)?.timeIntervalSince(start) }.filter { $0 >= 0 }
    }
}

/// One exercise in a workout: every set in order, the top set brighter, warm-ups marked; the header opens its history.
struct ExerciseSetsCard: View {
    let exercise: SessionDetail.Exercise

    var body: some View {
        let top = exercise.sets.filter { $0.kind != "warmup" }.max { ($0.weightKg ?? 0, $0.reps ?? 0) < ($1.weightKg ?? 0, $1.reps ?? 0) }?.id
        VCard {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink(value: Detail.exercise(id: exercise.id)) {
                    HStack(spacing: 8) {
                        Text(exercise.name).vUI(16, weight: 600).lineLimit(2)
                        if exercise.pr { Text("PR").vUI(11, weight: 700, color: VColor.ground).padding(.horizontal, 6).padding(.vertical, 2).background(VColor.good, in: Capsule()) }
                        Spacer(minLength: 6)
                        Text("History").vUI(13, weight: 500, color: VColor.muted)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5A5A))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 0) {
                        Text(s.kind == "warmup" ? "W" : "\(workingIndex(i))").vUI(13, weight: 600, color: s.kind == "warmup" ? Color(hex: 0x6E6E6E) : VColor.muted)
                            .frame(width: 28, alignment: .leading)
                        Text(TrainFormat.set(s.weightKg, s.reps).map { $0.replacingOccurrences(of: " x ", with: " kg × ") } ?? TrainFormat.dash)
                            .vUI(15, weight: s.id == top ? 700 : 500, color: s.kind == "warmup" ? VColor.muted : s.id == top ? VColor.bone : VColor.usual)
                        Spacer()
                        if s.kind != "normal", s.kind != "warmup" { Text(s.kind.capitalized).vUI(12, weight: 500, color: VColor.muted) }
                        if let at = s.at.flatMap(APIDate.clockText) { Text(at).vUI(12, weight: 500, color: Color(hex: 0x6E6E6E)).padding(.leading, 10) }
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Rectangle().fill(VColor.hairline).frame(height: 1) }
                }
            }
        }
    }

    private func workingIndex(_ i: Int) -> Int { exercise.sets.prefix(i + 1).filter { $0.kind != "warmup" }.count }
}

#if DEBUG
#Preview("Session detail") {
    let store = TrainPreviewData.trainStore(.fixture)
    return NavigationStack { SessionDetailScreen(store: store, id: "D-0").detailDestinations() }
        .onAppear { VFont.register() }
}
#Preview("Session detail · loading") {
    NavigationStack { SessionDetailScreen(store: TrainStore(api: { nil }), id: "missing") }.onAppear { VFont.register() }
}
#endif
