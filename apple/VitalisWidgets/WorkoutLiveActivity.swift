import ActivityKit
import AppIntents
import SwiftUI
import VitalisKit
import VitalisUI
import WidgetKit

/// Live workout on the Lock Screen and Dynamic Island, Draft frame "05 · Live workout".
/// Countdowns are timer texts and timer progress views, so they run between app updates.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreen(title: context.attributes.title, state: context.state, rest: rest(context))
                .activitySystemActionForegroundColor(VColor.bone)
                .widgetURL(WidgetLink.liveWorkout)
        } dynamicIsland: { context in
            let state = context.state, rest = rest(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.exercise).font(ActivityFont.ui(15, 600)).foregroundStyle(VColor.bone).lineLimit(1)
                        Text(state.setLine).font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let bpm = state.heartRate { HeartRate(bpm: bpm).padding(.trailing, 4) }
                }
                DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(state: state, rest: rest).padding(.horizontal, 4) }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "dumbbell.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(VColor.pulse)
                    Text(state.compactSetLine).font(ActivityFont.ui(13, 600)).foregroundStyle(VColor.bone).lineLimit(1)
                }
            } compactTrailing: {
                if let rest {
                    Text(timerInterval: rest, countsDown: true).font(ActivityFont.number(13, 600)).foregroundStyle(VColor.pulse)
                        .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 46)
                } else if let bpm = state.heartRate {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(bpm)").font(ActivityFont.number(13, 600)).foregroundStyle(VColor.bone)
                        Text("bpm").font(ActivityFont.ui(9, 500)).foregroundStyle(VColor.muted)
                    }
                } else {
                    Text(timerInterval: Elapsed.range(state), countsDown: false).font(ActivityFont.number(13, 600))
                        .foregroundStyle(VColor.bone).monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 46)
                }
            } minimal: {
                if let rest {
                    ZStack {
                        Circle().stroke(VColor.activityTrack, lineWidth: 2.5)
                        ProgressView(timerInterval: rest, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                            .progressViewStyle(.circular).tint(VColor.pulse)
                    }
                } else {
                    Image(systemName: "dumbbell.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(VColor.pulse)
                }
            }
            .widgetURL(WidgetLink.liveWorkout)
            .keylineTint(VColor.pulse)
        }
    }

    /// The rest still running: a stale activity (its rest end passed with no app update) shows the active layout.
    private func rest(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> ClosedRange<Date>? {
        guard !context.isStale, let r = context.state.restInterval, r.upperBound > Date() else { return nil }
        return r
    }
}

/// Archivo through VitalisUI (registered in the bundle's init); wide cuts for numbers.
private enum ActivityFont {
    static func ui(_ size: CGFloat, _ weight: CGFloat) -> Font { VFont.archivo(size, width: 100, weight: weight) }
    static func number(_ size: CGFloat, _ weight: CGFloat) -> Font { VFont.archivo(size, width: 125, weight: weight) }
}

private enum Elapsed {
    /// Counts up from the start; a Live Activity ends by itself well before the 12 h bound.
    static func range(_ s: WorkoutActivityAttributes.ContentState) -> ClosedRange<Date> {
        s.startedAt...s.startedAt.addingTimeInterval(12 * 3600)
    }
}

private struct HeartRate: View {
    let bpm: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("♥").font(ActivityFont.ui(13, 600)).foregroundStyle(VColor.pulse)
            Text("\(bpm)").font(ActivityFont.number(15, 600)).foregroundStyle(VColor.bone)
            Text("bpm").font(ActivityFont.ui(11, 500)).foregroundStyle(VColor.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate \(bpm) beats per minute")
    }
}

/// 8 pt rest bar: the built-in linear style is the one that animates from a timer interval, scaled up and clipped.
private struct RestBar: View {
    let rest: ClosedRange<Date>
    var body: some View {
        ProgressView(timerInterval: rest, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            .progressViewStyle(.linear)
            .tint(VColor.pulse)
            .scaleEffect(x: 1, y: 2, anchor: .center)
            .frame(height: 8)
            .background(VColor.activityTrack)
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

private struct ExpandedBottom: View {
    let state: WorkoutActivityAttributes.ContentState
    let rest: ClosedRange<Date>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rest {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(timerInterval: rest, countsDown: true).font(ActivityFont.number(40, 300)).foregroundStyle(VColor.pulse)
                        .monospacedDigit().lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(["rest", state.next.map { "next \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
                }
                RestBar(rest: rest)
                HStack(spacing: 8) {
                    Button(intent: ExtendRestIntent()) { label("+30 s", fill: VColor.cardRaised, text: VColor.bone) }
                        .buttonStyle(.plain).accessibilityLabel("Add 30 seconds of rest")
                    Button(intent: SkipRestIntent()) { label("Skip rest", fill: VColor.cardRaised, text: VColor.bone) }
                        .buttonStyle(.plain)
                    logSet
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(state.next.map { "next \($0)" } ?? state.totalsLine)
                        .font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    logSet.frame(maxWidth: 120)
                }
            }
        }
    }

    private var logSet: some View {
        Link(destination: WidgetLink.liveWorkout) { label("Log set", fill: VColor.pulse, text: VColor.onPulse) }
    }

    private func label(_ title: String, fill: Color, text: Color) -> some View {
        Text(title).font(ActivityFont.ui(13, 600)).foregroundStyle(text).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(fill, in: Capsule())
    }
}

private struct WorkoutLockScreen: View {
    let title: String
    let state: WorkoutActivityAttributes.ContentState
    let rest: ClosedRange<Date>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(VColor.pulse).frame(width: 8, height: 8)
                (Text("\(title) · ") + Text(timerInterval: Elapsed.range(state), countsDown: false))
                    .font(ActivityFont.ui(13, 600)).foregroundStyle(VColor.bone).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                if let bpm = state.heartRate { HeartRate(bpm: bpm) }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.exercise).font(ActivityFont.ui(15, 600)).foregroundStyle(VColor.bone).lineLimit(1)
                    Text(state.setLine).font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let rest {
                    Text(timerInterval: rest, countsDown: true).font(ActivityFont.number(32, 300)).foregroundStyle(VColor.pulse)
                        .monospacedDigit().multilineTextAlignment(.trailing).lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
                } else if let next = state.next {
                    Text("next \(next)").font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
                }
            }
            if let rest { RestBar(rest: rest) }
            HStack {
                Text(state.totalsLine)
                Spacer(minLength: 8)
                if let rest { Text("Rest ends \(rest.upperBound.formatted(date: .omitted, time: .shortened))") }
            }
            .font(ActivityFont.ui(13, 400)).foregroundStyle(VColor.muted).lineLimit(1)
        }
        .padding(16)
    }
}

#Preview("Lock Screen", as: .content, using: WorkoutActivityAttributes(sessionID: "preview", title: "Push")) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityPreview.resting
    WorkoutActivityPreview.lifting
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes(sessionID: "preview", title: "Push")) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityPreview.resting
}

#Preview("Compact", as: .dynamicIsland(.compact), using: WorkoutActivityAttributes(sessionID: "preview", title: "Push")) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityPreview.resting
    WorkoutActivityPreview.lifting
}

private enum WorkoutActivityPreview {
    static var resting: WorkoutActivityAttributes.ContentState {
        .init(exercise: "Barbell Bench Press", setIndex: 3, setTotal: 4, last: "80 × 8", next: "80 × 8",
              restEnd: Date().addingTimeInterval(84), restTotal: 120, heartRate: 142,
              startedAt: Date().addingTimeInterval(-24 * 60), totalSets: 9, volumeKg: 3105)
    }
    static var lifting: WorkoutActivityAttributes.ContentState {
        var s = resting
        s.restEnd = nil
        return s
    }
}
