import SwiftUI
import VitalisKit
import VitalisUI

/// W-02 stub (spec 21 §2.7, no frame): controls page to the right of Set entry. W-02 replaces this file.
struct EndWorkoutScreen: View {
    let model: WorkoutModel
    @State private var confirmsEnd = false

    var body: some View {
        VStack(spacing: 8) {
            WatchPrimaryButton("End") { confirmsEnd = true }
            SecondaryButton(model.isPaused ? "Resume" : "Pause", size: .full) {
                if model.isPaused { model.resume() } else { model.pause() }
            }
        }
        .padding(.horizontal, WatchLayout.side)
        .confirmationDialog("End workout?", isPresented: $confirmsEnd) {
            Button("End", role: .destructive) { Task { await model.end() } }
            Button("Resume", role: .cancel) {}
        }
        .vScreen()
    }
}
