import SwiftUI
import VitalisKit
import VitalisUI

/// W-02 stub (spec 21 §2.6, no frame): plan exercises not done, then recent ones; selecting inserts it as next.
/// W-02 replaces this file (search and catalog ranking live there).
struct AddExerciseScreen: View {
    let model: WorkoutModel

    private var ids: [String] {
        let plan = (model.record?.exerciseIDs ?? model.pack?.due?.exerciseIDs ?? [])
        let done = Set(model.record?.visibleSets.map(\.exerciseID) ?? [])
        var seen = Set<String>()
        return (plan.filter { !done.contains($0) } + (model.pack?.recentExerciseIDs ?? [])).filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    WatchRow(title: model.name(of: id), detail: model.exercise(id)?.equipment) { model.addExercise(id) }
                }
            }
            .padding(.horizontal, WatchLayout.side)
        }
        .vScreen()
    }
}
