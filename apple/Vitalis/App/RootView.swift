import SwiftUI
import VitalisKit
import VitalisUI

/// Setup gate, then the five-tab shell with Settings, the digest and sheets on top.
@MainActor
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var router = Router()
    @AppStorage("setupCompleted") private var setupCompleted = false

    var body: some View {
        Group {
            if setupCompleted { shell } else { SetupFlow(model: model) { setupCompleted = true } }
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
    }
}
