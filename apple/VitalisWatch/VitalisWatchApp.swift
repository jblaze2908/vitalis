import SwiftUI
import VitalisKit
import VitalisUI

@main
struct VitalisWatchApp: App {
    init() { VFont.register() }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional").font(.largeTitle)
                Text("Workouts coming soon").multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
