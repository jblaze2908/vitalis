import SwiftUI
import VitalisKit
import VitalisUI

/// Set entry (frame 31): weight and reps edited with the Crown, the per-exercise line, Log set.
struct SetEntryScreen: View {
    @Bindable var model: WorkoutModel
    @FocusState private var crownFocused: Bool
    @State private var offersWarmup = false

    var body: some View {
        VStack(spacing: 0) {
            weight
            reps.padding(.top, 4)
            Spacer(minLength: 0)
            PulseLine(events: model.pulseEvents, now: model.pulseNow, style: .watch)
                .padding(.horizontal, WatchLayout.side - WatchLayout.setEntrySide)
                .padding(.bottom, 12)
            logButton
        }
        .padding(.horizontal, WatchLayout.setEntrySide)
        .padding(.bottom, WatchLayout.buttonBottom)
        .focusable()
        .focused($crownFocused)
        .crownEditing($model.crownValue, range: model.crownRange, step: model.crownStep)
        .onAppear { crownFocused = true }
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel(model.setEntryTitle).lineLimit(1).minimumScaleFactor(0.7) } }
        .confirmationDialog("Log as warm-up", isPresented: $offersWarmup) {
            Button("Log as warm-up") { model.logSet(kind: .warmup) }
        }
        .ignoresSafeArea(edges: .bottom)
        .vScreen()
    }

    private var weight: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(WatchFormat.kg(model.weight)).vNumber(75, color: model.weight == nil ? VColor.steel : nil)
                .lineLimit(1).minimumScaleFactor(0.5)
            MonoLabel("kg", size: .custom(12))
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { underline(.weight) }
        .contentShape(Rectangle())
        .onTapGesture { model.focus = .weight; crownFocused = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var reps: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(WatchFormat.reps(model.reps)) reps").vHeadline(25, color: model.reps == nil ? VColor.steel : nil)
                .overlay(alignment: .bottom) { underline(.reps).offset(y: 3) }
            if let last = model.lastWeightText { MonoLabel(last, size: .small) }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.focus = .reps; crownFocused = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func underline(_ field: WorkoutModel.Field) -> some View {
        if model.focus == field { Rectangle().fill(VColor.bone).frame(height: WatchLayout.focusUnderline) }
    }

    private var logButton: some View {
        WatchPrimaryButton("Log set") { model.logSet() }
            .doubleTapPrimaryAction()
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in offersWarmup = true })
    }
}

#Preview("Set entry · squat 2/4") {
    NavigationStack { SetEntryScreen(model: .preview(.setEntry)) }.onAppear { VFont.register() }
}

#Preview("Set entry · first ever, no prefill") {
    NavigationStack { SetEntryScreen(model: .preview(.setEntryFirstEver)) }.onAppear { VFont.register() }
}
