import VitalisKit
import WidgetKit

struct TodayEntry: TimelineEntry {
    let date: Date
    let model: WidgetModel
}

/// Reads only the App Group snapshot (no HealthKit, no network). One entry and `.never`: the app (or, on the Watch,
/// the WatchConnectivity receiver) calls `reloadAllTimelines()` after each new snapshot (spec 20 §9).
struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: .now, model: .missing) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    private static func current() -> TodayEntry {
        let e = WidgetTimeline.entries(directory: WidgetTimeline.sharedDirectory(), now: .now)[0]
        return TodayEntry(date: e.date, model: e.model)
    }
}
