import SwiftUI
import VitalisKit
import VitalisUI

/// Setup gate, then the five-tab shell with Settings, the digest and sheets on top.
@MainActor
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var router = Router()
    @AppStorage("setupCompleted") private var setupCompleted = false
    @Environment(\.scenePhase) private var scenePhase
    // A restored phone has no Keychain token, so it goes back through setup.
    @State private var hasToken = (try? TokenStore.read()) != nil

    var body: some View {
        Group {
            if (setupCompleted && hasToken) || Services.shared.isDemo { shell }
            else { SetupFlow(model: model) { setupCompleted = true; hasToken = true } }
        }
        .onReceive(model.$snapshot) { SyncStore.shared.observe($0) }
        // The digest must appear on the first foreground after waking, whichever tab was left open.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, setupCompleted else { return }
            Task { await TodayStore.shared.refresh(); TodayStore.shared.presentDigestIfDue(router: router) }
        }
        .vScreen()
        .environment(router)
        .environment(Services.shared)
        .onOpenURL { router.open($0) }
        #if DEBUG
        // Simulator screenshots without taps: launch with `-VitalisRoute vitalis://train`.
        .task { if let raw = UserDefaults.standard.string(forKey: "VitalisRoute"), let url = URL(string: raw) { router.open(url) } }
        #endif
    }

    /// Settings from every tab, level with each tab's status row (Today used to be the only way in).
    private var settingsButton: some View {
        // A 28 pt card-coloured disc inside a 44 pt target, sitting in the slot every TabHeader leaves at its leading edge.
        Button { router.open(.settings) } label: {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).foregroundStyle(VColor.bone)
                .frame(width: 28, height: 28).background(VColor.card, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.top, 2)
        .accessibilityLabel("Settings")
    }

    /// A minimised workout stays one tap away above the tab bar.
    private var resumeBar: some View {
        Button { router.showsLiveWorkout = true } label: {
            HStack(spacing: 10) {
                Circle().fill(VColor.pulse).frame(width: 8, height: 8)
                MonoLabel("Workout live · \(LiveSessionStore.shared.session?.title ?? "Workout")", tint: .bone)
                Spacer()
                MonoLabel("Resume ›", tint: .bone)
            }
            .padding(.horizontal, VSpace.gutter)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(VColor.ground)
            .overlay(alignment: .top) { Rule() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume workout")
    }

    private var shell: some View {
        VStack(spacing: 0) {
            ZStack {
                switch router.tab {
                case .today: TodayScreen()
                case .sleep: SleepScreen()
                case .body: BodyScreen()
                case .train: TrainScreen()
                case .eat: EatScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { settingsButton }
            .overlay(alignment: .bottom) {
                // Eat draws its own toast; elsewhere a food add from Today still gets its Undo.
                if router.tab != .eat, let toast = EatStore.shared.toast {
                    Toast(toast.text) { Task { await EatStore.shared.undo() } }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: EatStore.shared.toast)
            if LiveSessionStore.shared.isLive, !router.showsLiveWorkout { resumeBar }
            TabBar(selection: $router.tab)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(isPresented: $router.showsSettings) { SettingsScreen(model: model).preferredColorScheme(.dark) }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .quickAdd(let slot): QuickAddSheet(slot: slot)
            case .workoutStart: WorkoutStartSheet()
            }
        }
        .fullScreenCover(isPresented: $router.showsDigest) { DigestScreen() }
        .fullScreenCover(isPresented: $router.showsLiveWorkout) { LiveWorkoutScreen() }
        // A session saved before a crash or quit reopens where it was.
        .task { if LiveSessionStore.shared.isLive { router.showsLiveWorkout = true } }
    }
}
