import SwiftUI
import VitalisKit
import VitalisUI

/// Start (frame 30): the server's due template, Start, then repeat rows and Choose exercises.
struct StartScreen: View {
    let model: WorkoutModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let due = model.pack?.due {
                    MonoLabel(due.daysSince.map { "Fresh · \($0) days" } ?? "New", tint: .good)
                }
                HeadlineLines([model.startTitle], size: 54)
                WatchPrimaryButton("Start") { model.startDue() }
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                ForEach(Array((model.pack?.recentSessions ?? []).prefix(3).enumerated()), id: \.offset) { _, recent in
                    WatchRow(title: "Repeat \(recent.title)", detail: WatchFormat.weekday(recent.day)) { model.repeatSession(recent) }
                }
                WatchRow(title: "Choose exercises", detail: nil) { model.showsAddExercise = true }
            }
            .padding(.horizontal, WatchLayout.side)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Vitalis") } }
        .vScreen()
    }
}

#Preview("Start · due legs") {
    NavigationStack { StartScreen(model: .preview(.start)) }.onAppear { VFont.register() }
}

#Preview("Start · no pack yet") {
    NavigationStack { StartScreen(model: .preview(.startNoPack)) }.onAppear { VFont.register() }
}
