import SwiftUI
import VitalisKit
import VitalisUI

/// Start, the logging pager (controls · set entry/rest/handoff · live metrics), Summary.
struct WatchRootView: View {
    @Bindable var model: WorkoutModel

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .start: StartScreen(model: model)
            case .logging: LoggingPager(model: model)
            case .summary: SummaryScreen(model: model)
            }
        }
        .sheet(isPresented: $model.showsAddExercise) { AddExerciseScreen(model: model) }
        .task { await model.bootstrap() }
    }
}

private struct LoggingPager: View {
    enum Page: Hashable { case controls, main, metrics }
    let model: WorkoutModel
    @State private var page = Page.main

    var body: some View {
        TabView(selection: $page) {
            EndWorkoutScreen(model: model).tag(Page.controls)
            main.tag(Page.main)
            LiveMetricsScreen(model: model).tag(Page.metrics)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder private var main: some View {
        switch model.step {
        case .setEntry: SetEntryScreen(model: model)
        case .rest(let timer): RestScreen(model: model, timer: timer)
        case .handoff: HandoffScreen(model: model)
        }
    }
}

#Preview("Logging · handoff stub") {
    WatchRootView(model: .preview(.handoff)).onAppear { VFont.register() }
}
