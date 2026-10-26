import Foundation
import Observation
import VitalisKit
import VitalisUI

/// Pushed screens inside the Train tab's NavigationStack.
enum TrainRoute: Hashable {
    case session(id: String)
    /// `back` is the session title shown in the back link (`< PUSH`).
    case exercise(id: String, back: String)
}

/// PulseLine x positions (display mapping only, 10 §4).
struct PulsePositions: Equatable, Sendable {
    var events: [Double]
    var now: Double
}

/// Train week, paged session history and the detail reads. Shared so the logger's Finish can push Session detail.
@MainActor @Observable
final class TrainStore {
    static let shared = TrainStore(api: { Services.shared.api })

    let week = Loadable<TrainingResponse>()
    /// Rows from `/v2/training/sessions` pages that the week view doesn't already show, newest first.
    private(set) var history: [SessionRow] = []
    private(set) var nextCursor: String?
    private(set) var hasMore = true
    private(set) var isPaging = false
    private(set) var pageError: Error?
    private(set) var pulse: PulsePositions?
    var path = Detail.launchPath("train")
    /// Set by Finish: the detail may 404 until the outbox delivers the session, so it shows loading meanwhile.
    private(set) var pendingSessionID: String?

    @ObservationIgnored private let api: @MainActor () -> VitalisAPI?
    @ObservationIgnored private var sessionDetails: [String: Loadable<SessionDetail>] = [:]
    @ObservationIgnored private var exerciseDetails: [String: Loadable<ExerciseDetail>] = [:]

    init(api: @escaping @MainActor () -> VitalisAPI?) { self.api = api }

    /// The week's rows, then older history, each session once.
    var sessions: [SessionRow] {
        let weekRows = week.value?.sessions ?? []
        let ids = Set(weekRows.map(\.id))
        return weekRows + history.filter { !ids.contains($0.id) }
    }

    func load() async {
        guard let api = api() else { return }
        await week.load(cached: { await api.cached(TrainingResponse.self, path: "v2/training") }) { try await api.training() }
        if history.isEmpty, nextCursor == nil { await loadMore() }
        pulse = await Self.cachedPulse(api: api, now: Date())
    }

    /// Next page of `GET /v2/training/sessions`; overlapping rows (the first page repeats this week) are skipped.
    func loadMore() async {
        guard hasMore, !isPaging, let api = api() else { return }
        isPaging = true
        defer { isPaging = false }
        do {
            let page = try await api.sessions(before: nextCursor).value
            var seen = Set(history.map(\.id))
            for row in page.sessions where seen.insert(row.id).inserted { history.append(row) }
            nextCursor = page.next
            hasMore = page.next != nil
            pageError = nil
        } catch {
            pageError = error
        }
    }

    // MARK: Details

    func session(_ id: String) -> Loadable<SessionDetail> {
        if let l = sessionDetails[id] { return l }
        let l = Loadable<SessionDetail>(); sessionDetails[id] = l; return l
    }

    func loadSession(_ id: String) async {
        guard let api = api() else { return }
        let l = session(id)
        await l.load(cached: { await api.cached(SessionDetail.self, path: "v2/training/sessions/\(HTTPCore.pathSegment(id))") }) {
            try await api.session(id: id)
        }
        if l.value != nil, pendingSessionID == id { pendingSessionID = nil }
    }

    func exercise(_ id: String) -> Loadable<ExerciseDetail> {
        if let l = exerciseDetails[id] { return l }
        let l = Loadable<ExerciseDetail>(); exerciseDetails[id] = l; return l
    }

    func loadExercise(_ id: String) async {
        guard let api = api() else { return }
        await exercise(id).load(cached: { await api.cached(ExerciseDetail.self, path: "v2/exercises/\(HTTPCore.pathSegment(id))") }) {
            try await api.exercise(id: id)
        }
    }

    /// After the iPhone logger's Finish: show that session's detail inside the Train tab.
    func showFinished(_ id: String) {
        pendingSessionID = id
        path = [.session(id: id)]
    }

    func isPending(_ id: String) -> Bool { pendingSessionID == id }

    // MARK: Pulse

    /// Today's pulse from the cached `/v2/today` body (no request), with now moved to the current time.
    static func cachedPulse(api: VitalisAPI, now: Date) async -> PulsePositions? {
        guard let p = await api.cached(TodayResponse.self, path: "v2/today")?.value.pulse else { return nil }
        return positions(p, now: now)
    }

    nonisolated static func positions(_ p: Pulse, now: Date) -> PulsePositions? {
        guard let start = APIDate.parse(p.window.start), let end = APIDate.parse(p.window.end) else { return nil }
        let events = p.events.compactMap { APIDate.parse($0.at) }.filter { $0 <= now }
        return PulsePositions(events: events.map { PulseLine.fraction(at: $0, start: start, end: end) },
                              now: PulseLine.fraction(at: now, start: start, end: end))
    }
}
