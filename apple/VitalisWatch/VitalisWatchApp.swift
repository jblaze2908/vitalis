import SwiftUI
import VitalisKit

@main
struct VitalisWatchApp: App {
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
