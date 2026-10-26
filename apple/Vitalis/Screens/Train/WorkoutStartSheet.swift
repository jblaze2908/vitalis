import HealthKit
import SwiftUI
import VitalisKit
import VitalisUI

/// Start (frame 11, 11 §7.3): the owner's splits as equal choices, then one Start for a workout shared by this iPhone
/// and the Watch; while a Watch workout is already live, Join it instead.
struct WorkoutStartSheet: View {
    private let train: TrainStore
    private let live: LiveSessionStore
    /// Off in previews so they never launch the Watch app or the logger.
    private let actsOnAppear: Bool

    @Environment(Router.self) private var router
    @State private var chosen: String?
    /// Nothing reads as selected until the owner taps a row, Empty workout included.
    @State private var picked = false
    @State private var watchError: String?
    @State private var starting = false

    init() { self.init(train: .shared, live: .shared, actsOnAppear: true) }
    init(train: TrainStore, live: LiveSessionStore, actsOnAppear: Bool) {
        self.train = train; self.live = live; self.actsOnAppear = actsOnAppear
    }

    private var splits: [Split] { train.week.value?.splits ?? [] }
    private var split: Split? { splits.first { $0.id == chosen } }

    var body: some View {
        SheetChrome {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailSection(splits.isEmpty ? "Pick exercises as you go" : "Your splits · you pick")
                    TabHeadline(lines: [split?.name ?? "Workout"])
                    if let split, !split.exercises.isEmpty {
                        Text(split.exercises.map(\.name).joined(separator: " · ")).vText(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, VSpace.s2)
                    }
                    if !splits.isEmpty { choices.padding(.top, VSpace.s5) }

                    if live.watchSessionLive, live.liveWatch != nil {
                        // Already running on the Watch: open that same workout here.
                        PrimaryButton("Join Watch workout", icon: "applewatch") { joinWatch() }.padding(.top, VSpace.s5)
                        caption("Add sets here too · the Watch keeps recording", color: VColor.text2)
                    } else {
                        PrimaryButton(starting ? "Starting" : "Start workout") { Task { await start() } }
                            .disabled(starting)
                            .padding(.top, VSpace.s5)
                        caption(watchError ?? "One workout on this iPhone and your Watch · the Watch records heart rate",
                                color: watchError == nil ? VColor.text2 : VColor.watch)
                    }
                }
                .gutter()
                .padding(.bottom, VSpace.s4)
            }
        }
        .presentationDetents([.large])
        .task { if train.week.value == nil { await train.load() } }
    }

    /// One row per split, in server order; loaded ones stay tappable because the owner decides.
    private var choices: some View {
        ListCard {
            ForEach(splits) { s in choiceRow(s.name, detail: Self.detail(s), dim: !s.ready, on: chosen == s.id) { pick(s.id) } }
            choiceRow("Empty workout", detail: "Pick as you go", dim: false, on: picked && chosen == nil) { pick(nil) }
        }
    }

    static func detail(_ s: Split) -> String {
        guard s.ready else { return "Loaded" }
        return "Fresh · " + (s.daysSince.map { TrainFormat.plural($0, "day", "days") } ?? "New")
    }

    private func choiceRow(_ name: String, detail: String, dim: Bool, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ListRow(name, chevron: false) {
                StatusWord(detail, tone: dim ? .quiet : .good)
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? VColor.accent : VColor.chevron)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pick(_ id: String?) { chosen = id; picked = true }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text).vText(.secondary, color: color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, VSpace.s3)
    }

    /// One workout for both devices (20 §4): the phone mints the id, the Watch app opens on it and records Health;
    /// when the Watch can't be opened the phone owns the workout alone. Either way the phone logger opens.
    private func start() async {
        guard !starting, !live.watchSessionLive || live.liveWatch == nil else { return }
        starting = true
        defer { starting = false }
        live.begin(split: split)
        guard let id = live.session?.id, actsOnAppear else { router.startLoggingOnPhone(); return }
        WatchBridge.sendPlan(title: split?.name, template: split?.templateID, exerciseIDs: split?.exercises.map(\.id) ?? [], sessionID: id)
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let opened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AppModel.shared.healthStore.startWatchApp(with: config) { ok, _ in cont.resume(returning: ok) }
        }
        if opened { live.startedWithWatch() } else { watchError = "No Watch reachable · logging on this iPhone" }
        router.startLoggingOnPhone()
    }

    /// One workout from both devices: the phone shows the Watch's sets and adds its own (20 §4).
    private func joinWatch() {
        live.join()
        router.startLoggingOnPhone()
    }

}

#if DEBUG
#Preview("Start choice") {
    Color.clear.sheet(isPresented: .constant(true)) {
        WorkoutStartSheet(train: TrainPreviewData.trainStore(.splits), live: TrainPreviewData.idleLive,
                          actsOnAppear: false)
    }
    .vScreen().environment(Router()).onAppear { VFont.register() }
}
#Preview("Start choice · no splits") {
    Color.clear.sheet(isPresented: .constant(true)) {
        WorkoutStartSheet(train: TrainPreviewData.trainStore(.fixture), live: TrainPreviewData.idleLive,
                          actsOnAppear: false)
    }
    .vScreen().environment(Router()).onAppear { VFont.register() }
}
#endif
