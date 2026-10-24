import Observation
import SwiftUI
import VitalisUI

enum SettingsPage: Hashable { case sync }
enum AppSheet: Identifiable, Equatable {
    case quickAdd(slot: String?)
    case workoutStart
    var id: String {
        switch self { case .quickAdd(let s): "quickAdd-\(s ?? "")"; case .workoutStart: "workoutStart" }
    }
}

/// Navigation state for the five-tab shell; screens ask it to move instead of presenting things themselves.
@MainActor @Observable
final class Router {
    var tab: VTab = .today
    var sheet: AppSheet?
    var showsDigest = false
    var showsSettings = false
    var settingsPath: [SettingsPage] = []

    func open(_ route: Route) {
        switch route {
        case .tab(let t): dismissAll(); tab = t
        case .digest: dismissAll(); tab = .today; showsDigest = true
        case .eatAdd(let slot): dismissAll(); tab = .eat; sheet = .quickAdd(slot: slot)
        case .workoutStart: dismissAll(); tab = .train; sheet = .workoutStart
        case .settings: sheet = nil; showsDigest = false; settingsPath = []; showsSettings = true
        case .settingsSync: sheet = nil; showsDigest = false; settingsPath = [.sync]; showsSettings = true
        }
    }

    func open(_ url: URL) { if let r = DeepLinks.parse(url) { open(r) } }

    private func dismissAll() { sheet = nil; showsDigest = false; showsSettings = false }
}
