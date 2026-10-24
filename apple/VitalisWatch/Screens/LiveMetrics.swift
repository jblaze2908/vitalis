import SwiftUI
import VitalisKit
import VitalisUI

/// W-02 stub (spec 21 §2.4, no frame): swipe left from Set entry or Rest. W-02 replaces this file.
struct LiveMetricsScreen: View {
    let model: WorkoutModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                reading(model.session.heartRate.map { "\(Int($0.rounded()))" }, "BPM")
                reading(model.session.elapsed(at: context.date).map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }, "Elapsed")
                reading(model.session.activeKcal.map { "\(Int($0.rounded()))" }, "Active kcal")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WatchLayout.side)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { MonoLabel("Live") } }
        .vScreen()
    }

    private func reading(_ value: String?, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? WatchFormat.missing).vNumber(32, color: value == nil ? VColor.steel : nil)
            MonoLabel(caption)
        }
    }
}
