import SwiftUI
import VitalisKit
import VitalisUI

/// Exercise detail (frame 10): server e1RM and change, e1RM chart from `points`, heaviest, next suggestion, last sets.
struct ExerciseDetailScreen: View {
    let store: TrainStore
    let id: String
    let back: String

    var body: some View {
        let detail = store.exercise(id)
        let status = trainStatus(detail.value?.freshness, fetchedAt: detail.fetchedAt, failed: detail.error != nil)
        VStack(spacing: 0) {
            TrainTopBar(status: status.0, tint: status.1, pulse: store.pulse)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BackLink(title: back).padding(.top, VSpace.rowPad)
                    if let d = detail.value {
                        content(d)
                        if let error = detail.error as? APIError { MonoLabel(error.statusLine, tint: .watch).padding(.top, VSpace.sectionPad) }
                    } else {
                        ScreenHeader(context: TrainFormat.dash, title: TrainFormat.dash)
                        Text(TrainFormat.dash).vNumber(72, color: VColor.steel).padding(.top, VSpace.sectionTop)
                        TrainLoadError(error: detail.error, hasValue: false) { Task { await store.loadExercise(id) } }
                            .padding(.top, VSpace.sectionTop)
                    }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, VSpace.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .trainPushed()
        .task(id: Services.shared.writesVersion) { await store.loadExercise(id) }
    }

    @ViewBuilder private func content(_ d: ExerciseDetail) -> some View {
        ScreenHeader(context: d.contextLabel ?? TrainFormat.dash, title: d.exercise.name)
        HStack(alignment: .center, spacing: 16) {
            Text(d.e1rm?.currentKg.map { String(format: "%.1f", $0) } ?? TrainFormat.dash)
                .vNumber(72, color: d.e1rm?.currentKg == nil ? VColor.steel : nil).lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 10) {
                MonoLabel("Kg · est. 1-rep max")
                if let change = d.e1rm?.change8wKg {
                    Text("\(change >= 0 ? "+" : "−")\(String(format: "%.1f", abs(change))) kg in 8 weeks")
                        .vReading(tint: change >= 0 ? .good : .steel).textCase(.uppercase)
                }
            }
        }
        .padding(.top, VSpace.sectionTop)
        .accessibilityElement(children: .combine)

        E1RMChart(points: d.e1rm?.points ?? [], today: TrainFormat.day(d.freshness?.today))
            .padding(.top, 28)

        VSection(top: VSpace.sectionTop) {
            HStack(alignment: .top, spacing: 0) {
                figure("Heaviest", heaviest(d.records))
                Rectangle().fill(VColor.rule).frame(width: 1).padding(.horizontal, 16)
                figure("Next time, try", TrainFormat.set(d.next?.weightKg, d.next?.reps) ?? d.next?.suggestion ?? TrainFormat.dash)
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        if let last = d.lastSession { LastSessionSets(last: last) }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(label)
            Text(value).vNumber(32, color: value == TrainFormat.dash ? VColor.steel : nil).lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

/// Per-session best e1RM: `rule` gridlines, `bone` polyline, hollow steel points, last point filled.
struct E1RMChart: View {
    let points: [ExerciseDetail.Point]
    let today: Date?

    var body: some View {
        VStack(spacing: 14) {
            Canvas { context, size in draw(&context, size) }
                .frame(height: 96)
                .overlay { if points.isEmpty { MonoLabel("No sets in 8 weeks") } }
            HStack {
                MonoLabel(label(0))
                Spacer()
                MonoLabel(label(points.count / 2))
                Spacer()
                MonoLabel(label(points.count - 1), tint: .bone)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibility)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let inset: CGFloat = 6
        let plot = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        for y in [plot.minY, plot.midY, plot.maxY] {
            context.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(VColor.rule))
        }
        guard !points.isEmpty else { return }
        let values = points.map(\.kg)
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let xy = points.enumerated().map { i, p in
            CGPoint(x: points.count == 1 ? plot.midX : plot.minX + plot.width * CGFloat(i) / CGFloat(points.count - 1),
                    y: hi == lo ? plot.midY : plot.maxY - plot.height * CGFloat((p.kg - lo) / (hi - lo)))
        }
        var line = Path()
        line.addLines(xy)
        context.stroke(line, with: .color(VColor.bone), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        for p in xy.dropLast() {
            let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(VColor.ground))
            context.stroke(dot, with: .color(VColor.steel), lineWidth: 1.5)
        }
        if let last = xy.last { context.fill(Path(ellipseIn: CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9)), with: .color(VColor.bone)) }
    }

    /// First and middle as `1 SEP`; the last as a weekday when it is within a week of the server's today.
    private func label(_ i: Int) -> String {
        guard points.indices.contains(i), let day = TrainFormat.day(points[i].day) else { return "" }
        let recent = i == points.count - 1 && today.map { $0.timeIntervalSince(day) < 7 * 86_400 } == true
        return TrainFormat.dayText(day, recent ? "EEE" : "d MMM")
    }

    private var accessibility: String {
        guard let first = points.first, let last = points.last else { return "No estimated 1-rep max yet" }
        return "Estimated 1-rep max over \(points.count) sessions, \(TrainFormat.kg(first.kg)) to \(TrainFormat.kg(last.kg)) kilograms"
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
    return NavigationStack { ExerciseDetailScreen(store: store, id: "barbell-bench-press-medium-grip", back: "Push") }
        .onAppear { VFont.register() }
}
#Preview("Exercise detail · loading") {
    NavigationStack { ExerciseDetailScreen(store: TrainStore(api: { nil }), id: "x", back: "Push") }.onAppear { VFont.register() }
}
#endif
