import Foundation
import VitalisKit

/// Phone → Watch seam for the start-choice sheet and Today; the relay itself is `PhoneSessionDelegate` (spec 21 §6).
@MainActor enum WatchBridge {
    /// `WatchMessage.plan` via `sendMessage` when reachable, else parked in the pack.
    static func sendPlan(template: String?, exerciseIDs: [String], intensity: String? = nil) {
        PhoneSessionDelegate.shared.sendPlan(WatchPlan(template: template, exerciseIDs: exerciseIDs, intensity: intensity))
    }

    /// Complications (spec 21 §3) after each new Today snapshot; also a cue to refresh the pack (throttled).
    static func sendToday(_ snapshot: TodaySnapshot) {
        PhoneSessionDelegate.shared.sendToday(snapshot)
        Task { await WatchPackSender.shared.refresh() }
    }
}
