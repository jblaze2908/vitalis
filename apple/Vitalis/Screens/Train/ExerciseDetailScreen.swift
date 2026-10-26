import SwiftUI
import VitalisKit
import VitalisUI

/// One exercise over time: estimated 1-rep max and its trend, records, what to try next, and every session it was done in.
struct ExerciseDetailScreen: View {
    let store: TrainStore
    let id: String

    var body: some View {
        let detail = store.exercise(id), d = detail.value
        DetailScaffold(d?.exercise.name ?? "Exercise", subtitle: d.map(subtitle)) {
            if let d {
                content(d)
                if let error = detail.error as? APIError { MonoLabel(error.statusLine, tint: .watch).padding(.top, 12) }
            } else {
                LoadState(error: detail.error) { Task { await store.loadExercise(id) } }.padding(.top, 40)
            }
        }
        .task(id: Services.shared.writesVersion) { await store.loadExercise(id) }
    }

    private func subtitle(_ d: ExerciseDetail) -> String {
        [d.exercise.equipment?.capitalized, (d.exercise.primary.map(TrainCopy.name)).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func content(_ d: ExerciseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated 1-rep max").vUI(13, weight: 500, color: VColor.muted)
            Figure(d.e1rm?.currentKg.map { TrainFormat.kg($0) } ?? TrainFormat.dash, unit: "kg", size: 44, color: d.e1rm?.currentKg == nil ? VColor.steel : nil)
            if let change = d.e1rm?.change8wKg {
                StatusWord("\(change >= 0 ? "+" : "−")\(TrainFormat.kg(abs(change))) kg in 8 weeks", tone: change > 0 ? .good : .usual)
            }
        }
        .padding(.top, 8)
        VCard { E1RMHistoryChart(points: d.e1rm?.points ?? []).frame(height: 190) }.padding(.top, 14)
        ReadoutRow([
            Readout("Heaviest", heaviest(d.records)),
            Readout("Best e1RM", d.records?.bestE1rmKg.map { "\(TrainFormat.kg($0)) kg" } ?? TrainFormat.dash,
                    status: d.records?.on.map { (MetricFormat.day($0), .quiet) }),
            Readout("Sessions", TrainFormat.int(d.sessionsTotal)),
        ])
        .padding(.top, 14)
        if let next = d.next, next.weightKg != nil || next.suggestion != nil {
            DetailSection("Next time")
            VCard {
                VStack(alignment: .leading, spacing: 6) {
                    Figure(TrainFormat.set(next.weightKg, next.reps).map { $0.replacingOccurrences(of: " x ", with: " × ") } ?? TrainFormat.dash,
                           unit: next.sets.map { TrainFormat.plural($0, "set", "sets") }, size: 26)
                    if let s = next.suggestion { Text(s).vUI(13, weight: 400, color: VColor.muted).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        if let history = d.history, !history.isEmpty {
            DetailSection("History", trailing: TrainFormat.plural(history.count, "session", "sessions"))
            RowsCard {
                ForEach(history, id: \.sessionId) { p in
                    DrillRow(.session(id: p.sessionId), value: p.volumeKg.map { "\(TrainFormat.grouped($0)) kg" }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text([MetricFormat.day(p.day, "EEE d MMM"), p.title].compactMap { $0 }.joined(separator: " · ")).vUI(14, weight: 600).lineLimit(1)
                            Text(p.sets.filter { $0.kind != "warmup" }.compactMap { TrainFormat.set($0.weightKg, $0.reps) }.joined(separator: "  ·  "))
                                .vUI(12, weight: 500, color: VColor.muted).lineLimit(2)
                        }
                    }
                }
            }
        } else if let last = d.lastSession {
            LastSessionSets(last: last)
        }
    }

    /// `best_set` carries the reps when it is also the heaviest set; otherwise only `heaviest_kg` is known.
    private func heaviest(_ r: ExerciseDetail.Records?) -> String {
        guard let kg = r?.heaviestKg else { return TrainFormat.dash }
        if let best = r?.bestSet, let w = best.split(separator: " ").first.flatMap({ Double($0) }), w == kg {
            return TrainFormat.serverSet(best) ?? TrainFormat.kg(kg)
        }
        return "\(TrainFormat.kg(kg)) kg"
    }
}

/// Last session's sets as chips; the heaviest working set is ringed brighter.
struct LastSessionSets: View {
    let last: ExerciseDetail.LastSession

    var body: some View {
        let top = last.sets.indices.filter { last.sets[$0].kind != "warmup" }.max { (last.sets[$0].weightKg ?? 0) < (last.sets[$1].weightKg ?? 0) }
        VSection(top: VSpace.sectionTop) {
            HStack {
                MonoLabel(TrainFormat.day(last.day).map { TrainFormat.dayText($0, "EEE d MMM") } ?? last.day, tint: .bone)
                Spacer()
                MonoLabel(TrainFormat.plural(last.sets.count, "set", "sets"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(last.sets.enumerated()), id: \.offset) { i, s in
                    let isTop = i == top
                    Text(TrainFormat.set(s.weightKg, s.reps) ?? TrainFormat.dash)
                        .vReading(14, tint: isTop ? .bone : .steel)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .overlay(RoundedRectangle(cornerRadius: VRadius.field, style: .continuous)
                            .stroke(isTop ? VColor.future : VColor.rule, lineWidth: 1.5))
                }
            }
            .padding(.top, VSpace.sectionPad)
        }
    }
}

#if DEBUG
#Preview("Exercise detail") {
    let store = TrainPreviewData.trainStore(.fixture)
    return NavigationStack { ExerciseDetailScreen(store: store, id: "barbell-bench-press-medium-grip") }
        .onAppear { VFont.register() }
}
#Preview("Exercise detail · loading") {
    NavigationStack { ExerciseDetailScreen(store: TrainStore(api: { nil }), id: "x") }.onAppear { VFont.register() }
}
#endif
