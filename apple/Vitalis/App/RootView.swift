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
            if setupCompleted { shell } else { SetupPlaceholder(model: model) { setupCompleted = true } }
        }
        .vScreen()
        .environment(router)
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
                case .today: TabPlaceholder(tab: .today) { router.open(.settings) }
                case .sleep: TabPlaceholder(tab: .sleep)
                case .body: TabPlaceholder(tab: .body)
                case .train: TabPlaceholder(tab: .train)
                case .eat: TabPlaceholder(tab: .eat)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(selection: $router.tab)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(isPresented: $router.showsSettings) {
            NavigationStack(path: $router.settingsPath) {
                SettingsView(model: model)
                    .navigationDestination(for: SettingsPage.self) { page in
                        switch page { case .sync: SyncView(model: model) }
                    }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink("Sync", value: SettingsPage.sync) } }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $router.sheet) { sheet in
            SheetChrome { Text(sheet.id).vReading().padding(VSpace.gutter) }.presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $router.showsDigest) {
            VStack { Text("Morning digest").vHeadline(44); SecondaryButton("Start my day", size: .full) { router.showsDigest = false } }
                .padding(VSpace.gutter).vScreen()
        }
    }
}
