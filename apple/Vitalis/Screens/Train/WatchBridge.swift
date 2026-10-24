import Foundation

/// Phone → Watch seam for the start-choice sheet. W-02 wires this to WatchConnectivity
/// (`WatchMessage.plan` via `sendMessage` when reachable, else inside the pack, spec 21 §6); until then it does nothing.
enum WatchBridge {
    static func sendPlan(template: String?, exerciseIDs: [String], intensity: String? = nil) {}
}
