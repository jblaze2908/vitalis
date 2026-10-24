import SwiftUI
import VitalisKit
import VitalisUI

/// W-02 stub (spec 21 §2.5, no frame): shown after the planned sets of an exercise. W-02 replaces this file.
struct HandoffScreen: View {
    let model: WorkoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.handoffExerciseID.map(model.name(of:)) ?? WatchFormat.missing).vHeadline(32).lineLimit(2).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            WatchPrimaryButton("Start") { model.startNextExercise() }
        }
        .padding(.horizontal, WatchLayout.side)
        .padding(.bottom, WatchLayout.buttonBottom)
        .ignoresSafeArea(edges: .bottom)
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Next") } }
        .vScreen()
    }
}
