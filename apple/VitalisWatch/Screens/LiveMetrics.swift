import SwiftUI
import VitalisKit
import VitalisUI

/// Live metrics (spec 21 §2.4, no frame): swipe left from Set entry or Rest. Readings straight from the live
/// workout builder; nothing here is a score, and there is no button.
struct LiveMetricsScreen: View {
    let model: WorkoutModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: LiveMetricsLayout.gap) {
                reading(model.session.heartRate.map { "\(Int($0.rounded()))" }, "BPM")
                reading(model.session.elapsed(at: context.date).map(Self.elapsed), "Elapsed")
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
                .lineLimit(1).minimumScaleFactor(0.6)
            MonoLabel(caption)
        }
        .accessibilityElement(children: .combine)
    }

    /// `m:ss` under an hour, then `h:mm:ss`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(max(0, seconds)).formatted(.time(pattern: pattern))
    }
}

private enum LiveMetricsLayout {
    static let gap: CGFloat = 8
}

#Preview("Live metrics · readings") {
    NavigationStack { LiveMetricsScreen(model: .preview(.setEntry)) }.onAppear { VFont.register() }
}

#Preview("Live metrics · no readings yet") {
    let session = PreviewWorkoutSession()
    session.heartRate = nil
    session.activeKcal = nil
    return NavigationStack { LiveMetricsScreen(model: WorkoutModel(store: nil, session: session)) }.onAppear { VFont.register() }
}
