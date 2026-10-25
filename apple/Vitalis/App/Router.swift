import Observation
import SwiftUI
import VitalisUI

enum SettingsPage: Hashable { case sync, splits }
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
    /// The full-screen iPhone logger (I-12); the tab bar hides while it shows.
    var showsLiveWorkout = false
    var settingsPath: [SettingsPage] = []
    /// When a URL last opened the app: the morning digest waits so it doesn't cover where the link (Siri, a widget) went.
    private(set) var linkedAt: Date?

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

    func open(_ url: URL, at now: Date = Date()) {
        guard let r = DeepLinks.parse(url) else { return }
        linkedAt = now
        open(r)
    }

    func openedByLink(within seconds: TimeInterval = 10, now: Date = Date()) -> Bool {
        linkedAt.map { now.timeIntervalSince($0) < seconds } ?? false
    }

    /// Leave the start-choice sheet for the iPhone logger.
    func startLoggingOnPhone() { sheet = nil; showsLiveWorkout = true }

    private func dismissAll() { sheet = nil; showsDigest = false; showsSettings = false }
}
