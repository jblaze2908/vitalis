import SwiftUI
import VitalisKit
import VitalisUI

/// Start (frame 30): every split as an equal row in pack order (11 §7.3: none is picked), repeat rows, Choose exercises.
struct StartScreen: View {
    let model: WorkoutModel

    private var splits: [WatchPack.Split] { model.pack?.splits ?? [] }

    /// Recent sessions a split doesn't already offer: history splits are those same titles.
    private var repeats: [WatchPack.RecentSession] {
        let names = Set(splits.map { $0.name.lowercased() })
        return (model.pack?.recentSessions ?? []).filter { !names.contains($0.title.lowercased()) }.prefix(3).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HeadlineLines(["Workout"], size: 54)
                    .padding(.bottom, 10)
                ForEach(splits) { split in
                    WatchRow(title: split.name, detail: Self.label(split), detailTint: split.ready ? .good : .steel) {
                        model.start(split: split)
                    }
                }
                ForEach(Array(repeats.enumerated()), id: \.offset) { _, recent in
                    WatchRow(title: "Repeat \(recent.title)", detail: WatchFormat.weekday(recent.day)) { model.repeatSession(recent) }
                }
                WatchRow(title: "Choose exercises", detail: nil) { model.showsAddExercise = true }
            }
            .padding(.horizontal, WatchLayout.side)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Vitalis") } }
        .vScreen()
    }

    /// `Loaded` still starts: the owner decides.
    static func label(_ split: WatchPack.Split) -> String {
        guard split.ready else { return "Loaded" }
        return split.daysSince.map { "Fresh · \($0) \($0 == 1 ? "day" : "days")" } ?? "New"
    }
}

#Preview("Start · three splits") {
    NavigationStack { StartScreen(model: .preview(.start)) }.onAppear { VFont.register() }
}

#Preview("Start · no pack yet") {
    NavigationStack { StartScreen(model: .preview(.startNoPack)) }.onAppear { VFont.register() }
}
