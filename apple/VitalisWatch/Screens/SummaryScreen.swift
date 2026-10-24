import SwiftUI
import VitalisKit
import VitalisUI

/// Summary (frame 33): catalog lighting and `SYNCING` until the phone relays the server's heat and PRs.
struct SummaryScreen: View {
    let model: WorkoutModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    MuscleMap(heat: model.summaryHeat, view: .both, strokeWidth: WatchLayout.summaryMapStroke)
                        .frame(width: WatchLayout.summaryMapWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                    HeadlineLines([model.record?.title ?? "Workout"], size: 32)
                    stats
                }
                .padding(.bottom, WatchLayout.summaryBottom)
                .containerRelativeFrame(.vertical)
                SecondaryButton("Done", size: .full) { model.done() }
                    .padding(.bottom, WatchLayout.summaryBottom)
            }
            .padding(.horizontal, WatchLayout.summarySide)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Saved", tint: .pulse) } }
        .vScreen()
    }

    private var stats: some View {
        HStack(spacing: 0) {
            MonoLabel(model.summaryStats)
            if model.hasPR {
                MonoLabel(" · ")
                MonoLabel("PR", tint: .pulse)
            } else if !model.hasServerResult {
                MonoLabel(" · ")
                MonoLabel("Syncing", size: .small)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

#Preview("Summary · syncing, catalog lighting") {
    NavigationStack { SummaryScreen(model: .preview(.summarySyncing)) }.onAppear { VFont.register() }
}

#Preview("Summary · server heat and PR") {
    NavigationStack { SummaryScreen(model: .preview(.summaryServer)) }.onAppear { VFont.register() }
}
