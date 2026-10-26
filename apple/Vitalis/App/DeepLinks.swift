import Foundation
import VitalisUI

/// Where a deep link, a notification or a button can send the user.
enum Route: Equatable, Sendable {
    case tab(VTab)
    case digest
    case eatAdd(slot: String?)
    case workoutStart
    /// The running workout's logger (the Live Activity's links); with none running it shows its closed state.
    case workoutLive
    case settings
    case settingsSync
}

/// `vitalis://…` links (spec 20 §3). Unknown links return nil so the app stays where it is.
enum DeepLinks {
    static let scheme = "vitalis"
    static let slots: Set<String> = ["breakfast", "lunch", "snack", "dinner"]

    static func parse(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme, let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch (host, path) {
        case ("today", []): return .tab(.today)
        case ("sleep", []): return .tab(.sleep)
        case ("body", []): return .tab(.body)
        case ("train", []): return .tab(.train)
        case ("eat", []): return .tab(.eat)
        case ("eat", ["add"]):
            let slot = query.first { $0.name == "slot" }?.value?.lowercased()
            return .eatAdd(slot: slot.flatMap { slots.contains($0) ? $0 : nil })
        case ("digest", []): return .digest
        case ("workout", ["start"]): return .workoutStart
        case ("workout", ["live"]): return .workoutLive
        case ("settings", []): return .settings
        case ("settings", ["sync"]): return .settingsSync
        default: return nil
        }
    }
}
