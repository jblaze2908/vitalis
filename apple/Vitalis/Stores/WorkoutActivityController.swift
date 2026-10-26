import ActivityKit
import Foundation
import VitalisKit

/// Starts, updates and ends the workout Live Activity from the live session. `sync` runs on every
/// `LiveSessionStore.persist` (per keystroke while editing a set), so the O(rows) mapping is compared with the
/// last pushed state and ActivityKit is only called when what the activity shows has changed.
@MainActor
final class WorkoutActivityController {
    static let shared = WorkoutActivityController()

    private var pushed: (id: String, state: WorkoutActivityAttributes.ContentState)?
    /// One chain, so updates reach ActivityKit in the order the session changed.
    private var queue: Task<Void, Never>?

    func sync(_ session: LiveSession?) {
        guard let session else {
            guard pushed != nil || !Activity<WorkoutActivityAttributes>.activities.isEmpty else { return }
            pushed = nil
            enqueue(nil, nil)
            return
        }
        let id = session.id.uuidString, state = Self.content(for: session)
        guard pushed?.id != id || pushed?.state != state else { return }
        // A process launched for a Live Activity button has no handle yet, so the activity is found by session id.
        if Activity<WorkoutActivityAttributes>.activities.contains(where: { $0.attributes.sessionID == id }) {
            pushed = (id, state)
            enqueue(id, state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: WorkoutActivityAttributes(sessionID: id, title: session.title),
                                     content: ActivityContent(state: state, staleDate: state.restEnd))
            pushed = (id, state)
            enqueue(id, nil)
        } catch {
            // Not in the foreground, or the system refused; the next change tries again.
        }
    }

    private func enqueue(_ id: String?, _ state: WorkoutActivityAttributes.ContentState?) {
        let previous = queue
        queue = Task { await previous?.value; await Self.apply(id, state) }
    }

    /// Updates the session's activity and ends every other one (a crash or a finished workout can leave one behind).
    /// Activities are looked up here rather than held, since `Activity` isn't Sendable.
    nonisolated private static func apply(_ id: String?, _ state: WorkoutActivityAttributes.ContentState?) async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            if activity.attributes.sessionID != id {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else if let state {
                await activity.update(ActivityContent(state: state, staleDate: state.restEnd))
            }
        }
    }

    // MARK: Mapping

    /// What the activity shows for a session; pure, so it is tested without ActivityKit.
    nonisolated static func content(for s: LiveSession, heartRate: Int? = nil) -> WorkoutActivityAttributes.ContentState {
        let ex = s.current
        let rows = ex?.rows ?? []
        let working = rows.filter { !$0.isWarmup }
        let counted = working.isEmpty ? rows : working
        let total = max(counted.count, 1)
        let index = min(counted.filter(\.isDone).count + 1, total)
        let logged = s.loggedSets + (s.watchSets ?? [])
        let mine = logged.filter { $0.exercise == ex?.id }.max { $0.performedAt < $1.performedAt }
        let last = mine.flatMap { set($0.weightKg, $0.reps) } ?? counted.first(where: { !$0.isDone })?.last.map(times)
        let pending = ex?.pendingRowIndex.map { rows[$0] }
        let next = pending.flatMap { set(LiveSessionStore.number($0.weight), Int($0.reps)) }
        let volume = logged.filter { $0.kind != "warmup" }.reduce(0.0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) }
        return .init(exercise: ex?.name ?? s.title, setIndex: index, setTotal: total, last: last, next: next,
                     restEnd: s.restEnd, restTotal: s.restTotal, heartRate: heartRate, startedAt: s.startedAt,
                     totalSets: logged.count, volumeKg: volume)
    }

    /// `80 × 8` as the activity prints a set (the app's tables use `x`).
    nonisolated private static func set(_ weight: Double?, _ reps: Int?) -> String? {
        TrainFormat.set(weight, reps).map(times)
    }

    nonisolated private static func times(_ text: String) -> String { text.replacingOccurrences(of: " x ", with: " × ") }
}

/// What the Live Activity buttons do; `perform()` of the shared intents runs here, in the app process.
@MainActor
enum WorkoutActivityActions {
    static func extendRest(by seconds: TimeInterval) { LiveSessionStore.shared.adjustRest(by: seconds) }
    static func skipRest() { LiveSessionStore.shared.skipRest() }
}
