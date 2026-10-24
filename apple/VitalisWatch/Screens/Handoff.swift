import SwiftUI
import VitalisKit
import VitalisUI

/// Next-exercise handoff (spec 21 §2.5, no frame): after the planned sets of an exercise. The Crown browses the
/// rest of the plan; Start begins the one shown (moved up to next when it isn't), Skip sends the next one to the end.
struct HandoffScreen: View {
    @Bindable var model: WorkoutModel
    @State private var browse = 0.0
    @FocusState private var crownFocused: Bool

    /// Plan exercises after the current one, in order.
    private var upcoming: [String] {
        guard let ids = model.record?.exerciseIDs, model.currentIndex + 1 < ids.count else { return [] }
        return Array(ids[(model.currentIndex + 1)...])
    }
    private var shownIndex: Int { min(max(Int(browse.rounded()), 0), max(upcoming.count - 1, 0)) }
    private var shownID: String? { upcoming.indices.contains(shownIndex) ? upcoming[shownIndex] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HandoffLayout.gap) {
                VStack(alignment: .leading, spacing: HandoffLayout.labelGap) {
                    Text(shownID.map(model.name(of:)) ?? WatchFormat.missing).vHeadline(32)
                        .lineLimit(3).minimumScaleFactor(0.5)
                    MonoLabel(lastText)
                    Spacer(minLength: 0)
                    if shownIndex == 0, upcoming.count > 1 {
                        Button { model.skipNextExercise(); browse = 0 } label: { MonoLabel("Skip", tint: .bone) }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shownID { muscles(shownID) }
            }
            .frame(height: HandoffLayout.mapHeight)
            Spacer(minLength: 0)
            WatchPrimaryButton("Start", action: start)
        }
        .padding(.horizontal, WatchLayout.side)
        .padding(.bottom, WatchLayout.buttonBottom)
        .ignoresSafeArea(edges: .bottom)
        .focusable()
        .focused($crownFocused)
        .crownEditing($browse, range: 0...Double(max(upcoming.count - 1, 1)), step: 1)
        .onAppear { crownFocused = true }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MonoLabel(positionText) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showsAddExercise = true } label: { Image(systemName: "plus").foregroundStyle(VColor.bone) }
                    .accessibilityLabel("Add exercise")
            }
        }
        .vScreen()
    }

    /// `NEXT · 3/5`: the shown exercise's place in the whole plan.
    private var positionText: String {
        let total = model.record?.exerciseIDs.count ?? 0
        return shownID == nil ? "Next" : "Next · \(model.currentIndex + 2 + shownIndex)/\(total)"
    }

    /// `LAST 95 × 8`: the first working set of the server's last session for it, or `NEW`.
    private var lastText: String {
        guard let id = shownID, let sets = model.exercise(id)?.prefill?.sets,
              let set = sets.first(where: \.isWorking) ?? sets.first else { return "New" }
        return "Last \(WatchFormat.kg(set.weightKg)) × \(WatchFormat.reps(set.reps))"
    }

    private func start() {
        guard let id = shownID else { model.startNextExercise(); return }
        if shownIndex == 0 { model.startNextExercise() } else { model.addExercise(id) }
        browse = 0
    }

    /// Catalog lighting (primary 4, secondary 3) on whichever side shows more of the primary muscles.
    private func muscles(_ id: String) -> some View {
        let info = model.exercise(id)
        let primary = Self.muscles(info?.primary ?? []), secondary = Self.muscles(info?.secondary ?? [])
        let backCount = primary.filter(Self.back.contains).count, frontCount = primary.filter(Self.front.contains).count
        return MuscleMap(heat: MuscleMap.catalogLighting(primary: primary, secondary: secondary),
                         view: backCount > frontCount ? .back : .front)
            .frame(height: HandoffLayout.mapHeight)
    }

    private static func muscles(_ slugs: [String]) -> [Muscle] {
        slugs.compactMap { Muscle(rawValue: $0.replacingOccurrences(of: " ", with: "-")) }
    }

    // Calves and forearms show on both figures.
    private static let front: Set<Muscle> = [.abdominals, .abductors, .adductors, .biceps, .calves, .chest, .forearms, .neck,
                                             .quadriceps, .shoulders]
    private static let back: Set<Muscle> = [.calves, .forearms, .glutes, .hamstrings, .lats, .lowerBack, .middleBack, .traps,
                                            .triceps]
}

private enum HandoffLayout {
    static let mapHeight: CGFloat = 120
    static let gap: CGFloat = 6
    static let labelGap: CGFloat = 4
}

#Preview("Handoff · RDL next, from prefill") {
    NavigationStack { HandoffScreen(model: .preview(.handoff)) }.onAppear { VFont.register() }
}

#Preview("Handoff · next exercise never done") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitalis-handoff-\(UUID().uuidString)")
    let model = WorkoutModel(store: try? WatchSessionStore(root: root), session: PreviewWorkoutSession())
    model.apply(pack: WatchPreviewData.pack)
    model.start(WatchPlan(title: "Legs", template: "legs", exerciseIDs: ["barbell-squat", "hack-squat"]))
    for _ in 0..<4 { model.weight = 100; model.reps = 6; model.logSet() }
    model.skipRest()
    return NavigationStack { HandoffScreen(model: model) }.onAppear { VFont.register() }
}
