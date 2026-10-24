import Foundation
import VitalisKit

/// Frame 29 / 34 values as the app writes them (snake_case `TodaySnapshot` JSON). Previews only.
enum WidgetPreviewData {
    static let snapshotJSON = """
    {"day": "2026-10-24", "generated_at": "2026-10-24T09:39:00+05:30", "last_sync": "2026-10-24T09:31:00+05:30",
     "verdict": {"band": "ready", "label": "READY", "headline": "Train legs today"},
     "recovery": {"score": 78, "band": "ready"},
     "steps": 3206, "steps_target": 9000, "kcal_left": 1780, "protein_g": 38, "protein_target_g": 160,
     "pulse": {"window": {"start": "2026-10-24T06:50:00+05:30", "end": "2026-10-24T23:20:00+05:30"},
               "now": "2026-10-24T09:39:00+05:30",
               "events": [{"at": "2026-10-24T07:05:00+05:30", "kind": "weigh_in"}, {"at": "2026-10-24T08:10:00+05:30", "kind": "meal"}]}}
    """

    static let snapshot = try? APICoding.decoder().decode(TodaySnapshot.self, from: Data(snapshotJSON.utf8))
    static let ready = TodayEntry(date: .now, model: WidgetModel(snapshot))
    static let missing = TodayEntry(date: .now, model: .missing)
}
