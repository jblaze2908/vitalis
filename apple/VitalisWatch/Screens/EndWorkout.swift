import SwiftUI
import VitalisKit
import VitalisUI

/// Controls page (spec 21 §2.7, no frame): swipe right from Set entry. End asks once, in place, so the question
/// uses the Headline role rather than the system dialog's type.
struct EndWorkoutScreen: View {
    let model: WorkoutModel
    @State private var confirming: Bool

    init(model: WorkoutModel, confirming: Bool = false) {
        self.model = model
        _confirming = State(initialValue: confirming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EndLayout.gap) {
            if confirming {
                Text("End workout?").vHeadline(20)
                Spacer(minLength: 0)
                ControlButton("End", filled: true) { Task { await model.end() } }
                ControlButton("Resume", filled: false) {
                    confirming = false
                    if model.isPaused { model.resume() }
                }
            } else {
                Spacer(minLength: 0)
                ControlButton("End", filled: true) { confirming = true }
                ControlButton(model.isPaused ? "Resume" : "Pause", filled: false) {
                    if model.isPaused { model.resume() } else { model.pause() }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, WatchLayout.side)
        .padding(.bottom, WatchLayout.buttonBottom)
        .toolbar { ToolbarItem(placement: .topBarLeading) { if model.isPaused { MonoLabel("Paused") } } }
        .vScreen()
    }
}

private enum EndLayout {
    static let buttonHeight: CGFloat = 44
    static let gap: CGFloat = 8
    static let ring: CGFloat = 1.5
}

/// 44 pt control: `pulse` fill with a black label, or the secondary ring.
private struct ControlButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    init(_ title: String, filled: Bool, action: @escaping () -> Void) {
        self.title = title; self.filled = filled; self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VRadius.button, style: .continuous)
        Button(action: action) {
            Text(title).vAction(17, color: filled ? VColor.ground : VColor.bone).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: EndLayout.buttonHeight)
                .background(filled ? VColor.pulse : .clear, in: shape)
                .overlay { if !filled { shape.strokeBorder(VColor.future, lineWidth: EndLayout.ring) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

#Preview("End · controls") {
    NavigationStack { EndWorkoutScreen(model: .preview(.setEntry)) }.onAppear { VFont.register() }
}

#Preview("End · paused") {
    let model = WorkoutModel.preview(.setEntry)
    model.pause()
    return NavigationStack { EndWorkoutScreen(model: model) }.onAppear { VFont.register() }
}

#Preview("End · confirm") {
    NavigationStack { EndWorkoutScreen(model: .preview(.setEntry), confirming: true) }.onAppear { VFont.register() }
}
