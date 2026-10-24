import HealthKit
import SwiftUI
import VitalisKit
import VitalisUI

/// Start choice (frame 11): Start on Watch / Log on iPhone, remember my choice. Today and Train both open it;
/// with a remembered choice it acts on appear.
struct WorkoutStartSheet: View {
    private let train: TrainStore
    private let live: LiveSessionStore
    /// Off in previews so they never launch the Watch app or the logger.
    private let actsOnAppear: Bool

    @Environment(Router.self) private var router
    @AppStorage("rememberedStart") private var rememberedStart = ""
    @State private var remember = false
    @State private var watchError: String?
    @State private var starting = false

    init() { self.init(train: .shared, live: .shared, actsOnAppear: true) }
    init(train: TrainStore, live: LiveSessionStore, actsOnAppear: Bool) {
        self.train = train; self.live = live; self.actsOnAppear = actsOnAppear
    }

    private var due: DueWorkout? { train.week.value?.due }

    var body: some View {
        SheetChrome {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(dueLabel).padding(.top, 28)
                HeadlineLines([due?.name ?? "Workout"], size: 56).padding(.top, 6)
                if let due, !due.exercises.isEmpty {
                    Text(due.exercises.map(\.name).joined(separator: " · ")).vReading(14, tint: .steel).textCase(.uppercase)
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                }

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
                            MonoLabel("Remember my choice", tint: .bone)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(remember ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VSpace.gutter)
        }
        .presentationDetents([.height(486)])
        .task {
            if train.week.value == nil { await train.load() }
            guard actsOnAppear else { return }
            switch rememberedStart {
            case "watch": await startOnWatch()
            case "phone": logOnPhone()
            default: break
            }
        }
    }

    private var dueLabel: String {
        guard let due else { return "Pick exercises as you go" }
        return "Fresh · " + (due.daysSince.map { "\(TrainFormat.plural($0, "day", "days")) since" } ?? "New")
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
        WatchBridge.sendPlan(template: due?.template, exerciseIDs: due?.exercises.map(\.id) ?? [])
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
        live.begin(due: due)
        router.startLoggingOnPhone()
    }
}

#if DEBUG
#Preview("Start choice") {
    Color.clear.sheet(isPresented: .constant(true)) {
        WorkoutStartSheet(train: TrainPreviewData.trainStore(.due), live: TrainPreviewData.idleLive,
                          actsOnAppear: false)
    }
    .vScreen().environment(Router()).onAppear { VFont.register() }
}
#Preview("Start choice · nothing due") {
    Color.clear.sheet(isPresented: .constant(true)) {
        WorkoutStartSheet(train: TrainPreviewData.trainStore(.fixture), live: TrainPreviewData.idleLive,
                          actsOnAppear: false)
    }
    .vScreen().environment(Router()).onAppear { VFont.register() }
}
#endif
