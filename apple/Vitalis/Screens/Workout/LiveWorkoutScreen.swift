import SwiftUI
import VitalisKit
import VitalisUI

/// iPhone logging (frame 12): rest block, set table for the current exercise, other exercises, Add exercise, Finish.
/// Full screen without the tab bar; read-only while a Watch session is live.
struct LiveWorkoutScreen: View {
    private let store: LiveSessionStore
    private let train: TrainStore

    @Environment(Router.self) private var router
    @FocusState private var focus: SetField?
    @State private var confirmFinish = false
    @State private var addingExercise = false
    @State private var finishing = false
    @State private var naming = false
    @State private var name = ""

    init() { self.init(store: .shared, train: .shared) }
    init(store: LiveSessionStore, train: TrainStore) { self.store = store; self.train = train }

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.session { content(s) } else { closed }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focus = nil; Task { await store.commitEdits() } } label: { Text("Done").vAction(17) }
                }
            }
            .vScreen()
        }
        .sensoryFeedback(.success, trigger: store.session?.sets.count ?? 0) { old, new in new > old }
        .task { await store.prepare() }
        .sheet(isPresented: $addingExercise) {
            AddExerciseSheet(api: Services.shared.api) { info in
                store.addExercise(id: info.id, name: info.name)
                Task { await store.prefill(info.id) }
            }
        }
    }

    private var readOnly: Bool { store.watchSessionLive }

    private func content(_ s: LiveSession) -> some View {
        VStack(spacing: 0) {
            TrainTopBar(status: readOnly ? "Live on Watch · read only" : "Workout · live", pulse: train.pulse)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.periodic(from: s.startedAt, by: 1)) { tick in
                        VStack(alignment: .leading, spacing: 0) {
                            header(s, now: tick.date)
                            rest(s, now: tick.date)
                        }
                    }
                    if let ex = s.current { CurrentExercise(store: store, exercise: ex, index: s.currentIndex, readOnly: readOnly, focus: $focus) }
                    others(s)
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, VSpace.buttonHeight + 50)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if !readOnly && focus == nil {
                    SecondaryButton("+ Add exercise", size: .full) { addingExercise = true }
                        .background(VColor.ground)
                        .padding(.horizontal, VSpace.gutter)
                        .padding(.bottom, 34)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .confirmationDialog(s.sets.isEmpty ? "Nothing logged yet" : "Finish \(s.title)?", isPresented: $confirmFinish, titleVisibility: .visible) {
            if s.sets.isEmpty {
                Button("Discard workout", role: .destructive) { store.discard(); router.showsLiveWorkout = false }
            } else {
                Button("Finish and save") { Task { await finish() } }
            }
            Button("Keep going", role: .cancel) {}
        }
        .alert("Name this workout", isPresented: $naming) {
            TextField("Push, Upper, Legs…", text: $name).textInputAutocapitalization(.words)
            Button("Save and finish") { store.rename(name); Task { await finish() } }
            Button("Finish without a name") { Task { await finish() } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Named workouts are offered when you start the next one.")
        }
    }

    private func header(_ s: LiveSession, now: Date) -> some View {
        let context = "\(TrainFormat.elapsed(now.timeIntervalSince(s.startedAt))) · \(s.sets.count) of \(max(s.plannedSets, s.sets.count)) sets"
        return ScreenHeader(context: context, title: s.title) {
            if !readOnly {
                SecondaryButton("Finish", enabled: !finishing) {
                    focus = nil
                    // An unnamed workout can't be offered again, so ask for a name once at the end.
                    if s.title == "Workout", !s.sets.isEmpty { name = ""; naming = true } else { confirmFinish = true }
                }
            }
        }
        .padding(.top, VSpace.sectionTop)
    }

    @ViewBuilder private func rest(_ s: LiveSession, now: Date) -> some View {
        let remaining = RestTimer.remaining(end: s.restEnd, now: now)
        if remaining > 0 {
            VSection {
                MonoLabel("Rest · next \(nextSet(s) ?? TrainFormat.dash)")
                HStack(alignment: .center, spacing: 8) {
                    Text(RestTimer.text(remaining)).vNumber(52).monospacedDigit().lineLimit(1)
                        .accessibilityLabel("Rest, \(Int(remaining.rounded(.up))) seconds left")
                    Spacer(minLength: 8)
                    SecondaryButton("-15s", size: .mini) { store.adjustRest(by: -RestTimer.step) }
                    SecondaryButton("Skip", size: .mini) { store.skipRest() }
                    SecondaryButton("+15s", size: .mini) { store.adjustRest(by: RestTimer.step) }
                }
                .padding(.top, 4)
                ProgressTrack(RestTimer.fraction(end: s.restEnd, total: s.restTotal, now: now)).padding(.top, 14)
            }
            .disabled(readOnly)
        }
    }

    /// The set the rest leads into: the current row's prefilled values.
    private func nextSet(_ s: LiveSession) -> String? {
        guard let ex = s.current, let i = ex.pendingRowIndex else { return nil }
        let row = ex.rows[i]
        return TrainFormat.set(LiveSessionStore.number(row.weight), Int(row.reps))
    }

    @ViewBuilder private func others(_ s: LiveSession) -> some View {
        let rest = s.exercises.indices.filter { $0 != s.currentIndex }
        if !rest.isEmpty {
            VSection(top: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element) { n, i in
                        if n > 0 { Rule() }
                        Button { focus = nil; store.select(i) } label: { OtherExerciseRow(exercise: s.exercises[i]) }
                            .buttonStyle(.plain)
                    }
                    Rule()
                }
            }
            .padding(.top, VSpace.sectionPad)
        }
    }

    private var closed: some View {
        VStack(spacing: 16) {
            Text("No workout running.").vBody()
            SecondaryButton("Close") { router.showsLiveWorkout = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Save, then show the session in the Train tab (its id is our `client_id`).
    private func finish() async {
        finishing = true
        defer { finishing = false }
        if let id = await store.finish() {
            train.showFinished(id)
            router.tab = .train
        }
        router.showsLiveWorkout = false
    }
}

enum SetField: Hashable {
    case weight(UUID), reps(UUID)
}

/// Name + best, the set table and `+ ADD SET`.
struct CurrentExercise: View {
    let store: LiveSessionStore
    let exercise: LiveExercise
    let index: Int
    let readOnly: Bool
    var focus: FocusState<SetField?>.Binding

    var body: some View {
        VSection {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.name).vHeadline(26).lineLimit(2).minimumScaleFactor(0.7)
                Spacer(minLength: 12)
                MonoLabel("Best \(TrainFormat.serverSet(exercise.best) ?? TrainFormat.dash)")
            }
            SetTableHeader().padding(.top, 14)
            let current = exercise.pendingRowIndex
            ForEach(Array(exercise.rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Rule() }
                SetRowView(store: store, row: row, exerciseIndex: index, label: label(i),
                           state: row.isDone ? .done : i == current ? .current : .upcoming, readOnly: readOnly, focus: focus)
            }
            Rule()
            Button { store.addSet(to: index) } label: {
                MonoLabel("+ Add set", tint: .bone).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(readOnly)
        }
    }

    /// `W` for warm-ups, then working sets numbered from 1.
    private func label(_ i: Int) -> String {
        let row = exercise.rows[i]
        if row.isWarmup { return "W" }
        return String(exercise.rows[...i].filter { !$0.isWarmup }.count)
    }
}

private enum SetGrid {
    static let set: CGFloat = 30, kg: CGFloat = 66, reps: CGFloat = 56, check: CGFloat = 38, gap: CGFloat = 8
}

struct SetTableHeader: View {
    var body: some View {
        HStack(spacing: SetGrid.gap) {
            MonoLabel("Set", size: .small).frame(width: SetGrid.set)
            MonoLabel("Last", size: .small).frame(maxWidth: .infinity, alignment: .leading)
            MonoLabel("Kg", size: .small).frame(width: SetGrid.kg)
            MonoLabel("Reps", size: .small).frame(width: SetGrid.reps)
            Color.clear.frame(width: SetGrid.check, height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// One table row (46): done rows are steel, the current row carries the screen's one red action (its check).
struct SetRowView: View {
    enum Phase { case done, current, upcoming }

    let store: LiveSessionStore
    let row: SetRow
    let exerciseIndex: Int
    let label: String
    let state: Phase
    let readOnly: Bool
    var focus: FocusState<SetField?>.Binding

    var body: some View {
        HStack(spacing: SetGrid.gap) {
            Text(label).vRole(.reading(14), color: state == .current ? VColor.pulse : textColor).frame(width: SetGrid.set)
            Text(row.last ?? TrainFormat.dash).vRole(.reading(14), color: state == .current ? VColor.bone : textColor)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            field(.weight(row.id), text: row.weight, keyboard: .decimalPad, width: SetGrid.kg) {
                store.setWeight($0, row: row.id, in: exerciseIndex)
            }
            field(.reps(row.id), text: row.reps, keyboard: .numberPad, width: SetGrid.reps) {
                store.setReps($0, row: row.id, in: exerciseIndex)
            }
            check.frame(width: SetGrid.check)
        }
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set \(label)")
    }

    private var textColor: Color { state == .done ? VColor.steel : VColor.disabled }

    private func field(_ id: SetField, text: String, keyboard: UIKeyboardType, width: CGFloat, set: @escaping @MainActor @Sendable (String) -> Void) -> some View {
        let focused = focus.wrappedValue == id
        let ring = focused ? VColor.pulse : state == .current ? VColor.future : VColor.rule
        // Binding wants a Sendable setter; SwiftUI calls it on the main actor.
        return TextField("", text: Binding(get: { text }, set: { v in MainActor.assumeIsolated { set(v) } }), prompt: Text(TrainFormat.dash).foregroundStyle(VColor.disabled))
            .focused(focus, equals: id)
            .keyboardType(keyboard)
            .multilineTextAlignment(.center)
            .vNumber(17, color: state == .current ? VColor.bone : textColor)
            .frame(width: width, height: 34)
            .overlay(RoundedRectangle(cornerRadius: VRadius.field, style: .continuous).inset(by: 0.75).stroke(ring, lineWidth: 1.5))
            .disabled(readOnly || state == .upcoming)
            .accessibilityLabel(id.isWeight ? "Kilograms" : "Reps")
    }

    @ViewBuilder private var check: some View {
        let shape = RoundedRectangle(cornerRadius: VRadius.field, style: .continuous)
        switch state {
        case .done:
            Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(VColor.bone)
                .frame(width: 34, height: 34).overlay(shape.inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                .accessibilityLabel("Logged")
        case .current:
            Button {
                if LiveSessionStore.canLog(row) { focus.wrappedValue = nil; Task { await store.check() } }
                else { focus.wrappedValue = .reps(row.id) }
            } label: {
                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(VColor.ground)
                    .frame(width: 34, height: 34).background(VColor.pulse, in: shape)
            }
            .buttonStyle(.plain)
            .disabled(readOnly)
            .opacity(readOnly ? 0 : 1)
            .accessibilityLabel("Log set")
        case .upcoming:
            shape.inset(by: 0.75).stroke(VColor.rule, lineWidth: 1.5).frame(width: 34, height: 34).accessibilityHidden(true)
        }
    }
}

private extension SetField {
    var isWeight: Bool { if case .weight = self { true } else { false } }
}

/// Collapsed exercise (48): name in steel, `3 SETS · LAST 95 X 8`.
struct OtherExerciseRow: View {
    let exercise: LiveExercise

    var body: some View {
        HStack(spacing: 12) {
            Text(exercise.name).vHeadline(20, color: VColor.steel).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            MonoLabel(summary, size: .small)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var summary: String {
        let done = exercise.rows.filter(\.isDone).count, count = exercise.rows.count
        let sets = done > 0 ? "\(done) of \(count) sets" : TrainFormat.plural(count, "set", "sets")
        let last = exercise.rows.first { !$0.isWarmup && $0.last != nil }?.last
        return [sets, last.map { "last \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Logging · resting") {
    LiveWorkoutScreen(store: TrainPreviewData.liveStore(), train: TrainPreviewData.trainStore(.splits))
        .environment(Router()).onAppear { VFont.register() }
}
#Preview("Logging · Watch live, read only") {
    LiveWorkoutScreen(store: TrainPreviewData.liveStore(watchLive: true), train: TrainPreviewData.trainStore(.splits))
        .environment(Router()).onAppear { VFont.register() }
}
#endif
