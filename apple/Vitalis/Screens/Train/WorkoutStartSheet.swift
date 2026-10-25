import HealthKit
import SwiftUI
import VitalisKit
import VitalisUI

/// Start choice (frame 11, 11 §7.3): the owner's splits as equal choices (none preselected), then Watch or iPhone.
/// A remembered destination starts as soon as a split is tapped; with no splits it acts on appear.
struct WorkoutStartSheet: View {
    private let train: TrainStore
    private let live: LiveSessionStore
    /// Off in previews so they never launch the Watch app or the logger.
    private let actsOnAppear: Bool

    @Environment(Router.self) private var router
    @AppStorage("rememberedStart") private var rememberedStart = ""
    @State private var remember = false
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
                    MonoLabel(splits.isEmpty ? "Pick exercises as you go" : "Your splits · you pick").padding(.top, 28)
                    HeadlineLines([split?.name ?? "Workout"], size: 56).padding(.top, 6)
                    if let split, !split.exercises.isEmpty {
                        Text(split.exercises.map(\.name).joined(separator: " · ")).vReading(14, tint: .steel).textCase(.uppercase)
                            .lineSpacing(6).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                    }
                    if !splits.isEmpty { choices.padding(.top, 20) }

                    PrimaryButton("Start on Watch", icon: "applewatch") { Task { await startOnWatch() } }
                        .disabled(starting)
                        .padding(.top, 28)
                    caption(watchError ?? "Log sets from your wrist · phone stays away", tint: watchError == nil ? .steel : .watch)

                    SecondaryButton(live.watchSessionLive ? "Workout live on Watch" : "Log on iPhone", systemImage: "iphone",
                                    size: .full, enabled: !live.watchSessionLive) { logOnPhone() }
                        .padding(.top, 20)
                    caption("Full set table · good for new exercises", tint: .steel)

                    VSection(top: 20) {
                        Button { remember.toggle() } label: {
                            HStack(spacing: 16) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).inset(by: 0.75)
                                    .stroke(VColor.future, lineWidth: 1.5)
                                    .frame(width: 18, height: 18)
                                    .overlay { if remember { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(VColor.bone) } }
                                MonoLabel("Remember Watch or iPhone", tint: .bone)
                                Spacer()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(remember ? .isSelected : [])
                    }
                }
                .padding(.horizontal, VSpace.gutter)
                .padding(.bottom, VSpace.gutter)
            }
        }
        .presentationDetents([.large])
        .task {
            if train.week.value == nil { await train.load() }
            guard actsOnAppear, splits.isEmpty else { return }
            await startRemembered()
        }
    }

    /// One row per split, in server order; loaded ones stay tappable because the owner decides.
    private var choices: some View {
        VStack(spacing: 0) {
            Rule()
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
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? VColor.bone : VColor.future)
                    Text(name).vReading(15, tint: dim ? .steel : .bone).textCase(.uppercase).lineLimit(1)
                    Spacer(minLength: 8)
                    MonoLabel(detail, tint: dim ? .steel : .good)
                }
                .frame(minHeight: 52)
                Rule()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pick(_ id: String?) {
        chosen = id; picked = true
        guard actsOnAppear else { return }
        Task { await startRemembered() }
    }

    private func startRemembered() async {
        switch rememberedStart {
        case "watch": await startOnWatch()
        case "phone": logOnPhone()
        default: break
        }
    }

    private func caption(_ text: String, tint: VTint) -> some View {
        MonoLabel(text, size: .small, tint: tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }

    /// Plan first, then `startWatchApp`; on failure the error replaces the caption and Log on iPhone stays.
    private func startOnWatch() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        WatchBridge.sendPlan(title: split?.name, template: split?.templateID, exerciseIDs: split?.exercises.map(\.id) ?? [])
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let opened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AppModel.shared.healthStore.startWatchApp(with: config) { ok, _ in cont.resume(returning: ok) }
        }
        if opened {
            if remember { rememberedStart = "watch" }
            watchError = nil
            router.sheet = nil
        } else {
            watchError = "No paired Watch with Vitalis · log on iPhone instead"
        }
    }

    private func logOnPhone() {
        guard !live.watchSessionLive else { return }
        if remember { rememberedStart = "phone" }
        live.begin(split: split)
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
