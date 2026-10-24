import SwiftUI
import UIKit
import VitalisUI

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.start()
        Services.shared.start()
        return true
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Task { await AppModel.shared.syncNow() }
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        AppModel.shared.scheduleCatchUp()
    }
}

@main
@MainActor
struct VitalisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    init() { VFont.register() }
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
