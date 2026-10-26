import Foundation
import Observation
import VitalisKit

/// Every pushed detail screen, shared by the Today, Body and Train stacks so any number can open the same view.
enum Detail: Hashable {
    case session(id: String)
    case exercise(id: String)
    case exercises
    case metric(key: String)
    /// nil = today.
    case heart(day: String?)
    case allData
}

/// Reads behind the detail screens: metric history, the all-data overview, a day of heart rate and the exercises list.
/// One instance per app so a screen pushed twice shows its last answer at once.
@MainActor @Observable
final class ExploreStore {
    static let shared = ExploreStore(api: { Services.shared.api })

    let overview = Loadable<MetricsOverview>()
    let exercises = Loadable<PerformedExercises>()
    @ObservationIgnored private var metrics: [String: Loadable<MetricHistory>] = [:]
    @ObservationIgnored private var hearts: [String: Loadable<HeartDay>] = [:]
    @ObservationIgnored private let api: @MainActor () -> VitalisAPI?

    init(api: @escaping @MainActor () -> VitalisAPI?) { self.api = api }

    static let ranges = [7, 30, 90, 365]

    func metric(_ key: String, days: Int, end: String?) -> Loadable<MetricHistory> {
        let id = "\(key)|\(days)|\(end ?? "")"
        if let l = metrics[id] { return l }
        let l = Loadable<MetricHistory>(); metrics[id] = l; return l
    }

    func heart(_ day: String?) -> Loadable<HeartDay> {
        if let l = hearts[day ?? ""] { return l }
        let l = Loadable<HeartDay>(); hearts[day ?? ""] = l; return l
    }

    func loadOverview() async {
        guard let api = api() else { return }
        await overview.load(cached: { await api.cached(MetricsOverview.self, path: "v2/metrics") }) { try await api.metrics() }
    }

    func loadExercises() async {
        guard let api = api() else { return }
        await exercises.load(cached: { await api.cached(PerformedExercises.self, path: "v2/training/exercises") }) { try await api.performedExercises() }
    }

    func loadMetric(_ key: String, days: Int, end: String?) async {
        guard let api = api() else { return }
        let path = "v2/metrics/\(HTTPCore.pathSegment(key))", query = VitalisAPI.query(["days": String(days), "end": end])
        await metric(key, days: days, end: end).load(cached: { await api.cached(MetricHistory.self, path: path, query: query) }) {
            try await api.metric(key: key, days: days, end: end)
        }
    }

    func loadHeart(_ day: String?) async {
        guard let api = api() else { return }
        await heart(day).load(cached: { await api.cached(HeartDay.self, path: "v2/heart", query: VitalisAPI.query(["date": day])) }) {
            try await api.heart(date: day)
        }
    }

    #if DEBUG
    func preload(overview o: MetricsOverview? = nil, exercises e: PerformedExercises? = nil, metric m: MetricHistory? = nil, heart h: HeartDay? = nil) {
        if let o { overview.set(o) }
        if let e { exercises.set(e) }
        if let m { metric(m.key, days: m.days, end: nil).set(m) }
        if let h { heart(nil).set(h) }
    }
    #endif
}

extension Detail {
    /// Debug builds: `-VitalisDetail body/metric/resting_hr` opens that screen on launch, for simulator screenshots without taps.
    static func launchPath(_ tab: String) -> [Detail] {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "VitalisDetail") else { return [] }
        let p = raw.split(separator: "/").map(String.init)
        guard p.count >= 2, p[0] == tab else { return [] }
        let arg = p.count > 2 ? p[2] : nil
        switch (p[1], arg) {
        case ("metric", let k?): return [.metric(key: k)]
        case ("heart", _): return [.heart(day: arg)]
        case ("all", _): return [.allData]
        case ("exercises", _): return [.exercises]
        case ("session", let id?): return [.session(id: id)]
        case ("exercise", let id?): return [.exercise(id: id)]
        default: return []
        }
        #else
        return []
        #endif
    }
}
