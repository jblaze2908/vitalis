import Foundation
import Testing
import VitalisKit
@testable import Vitalis

struct WidgetSnapshotTests {
    /// The file as the app writes it (snake_case via `APICoding`), so a key rename breaks here first.
    static let fileJSON = """
    {"day": "2026-10-24", "generated_at": "2026-10-24T09:39:00+05:30", "last_sync": "2026-10-24T09:31:00+05:30",
     "verdict": {"band": "ready", "label": "READY", "headline": "Train legs today"},
     "recovery": {"score": 78, "band": "ready"},
     "steps": 3206, "steps_target": 9000, "kcal_left": 1780, "protein_g": 38, "protein_target_g": 160,
     "pulse": {"window": {"start": "2026-10-24T06:50:00+05:30", "end": "2026-10-24T23:20:00+05:30"},
               "now": "2026-10-24T09:39:00+05:30", "events": [{"at": "2026-10-24T08:10:00+05:30", "kind": "meal"}]}}
    """
    let now = Date(timeIntervalSince1970: 1_792_800_000)

    @Test func snapshotFileDecodes() throws {
        let s = try APICoding.decoder().decode(TodaySnapshot.self, from: Data(Self.fileJSON.utf8))
        #expect(s.day == "2026-10-24")
        #expect(s.verdict.label == "READY")
        #expect(s.recovery.score == 78)
        #expect(s.steps == 3206 && s.stepsTarget == 9000)
        #expect(s.kcalLeft == 1780 && s.proteinG == 38 && s.proteinTargetG == 160)
        #expect(s.pulse?.events.map(\.kind) == ["meal"])
        #expect(s.generatedAt == "2026-10-24T09:39:00+05:30")
    }

    @Test func modelFormatsFrame29() throws {
        let m = WidgetModel(try APICoding.decoder().decode(TodaySnapshot.self, from: Data(Self.fileJSON.utf8)))
        #expect(m.recovery == "78")
        #expect(m.recoveryGauge == 0.78)
        #expect(m.label == "READY" && m.tone == .good)
        #expect(m.headline == "Train legs today")
        #expect(m.context == "TODAY · 09:39")
        #expect(m.stepsReading == "3,206 / 9,000")
        #expect(m.fuelReading == "1,780 KCAL")
        #expect(m.proteinReading == "38 / 160 G")
        #expect(m.stepsLine == "3,206 STEPS" && m.kcalLine == "1,780 KCAL LEFT")
        #expect(m.inline == "78 READY · 3,206 STEPS")
    }

    @Test func timelineFromFixtureSnapshotFile() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try TodaySnapshot(Fixture.decode(TodayResponse.self, "today")).write(to: dir)
        let entries = WidgetTimeline.entries(directory: dir, now: now)
        #expect(entries.count == 1)
        #expect(entries[0].date == now)
        let m = entries[0].model
        #expect(m.recovery == "78" && m.label == "READY" && m.tone == .good)
        #expect(m.headline == "Done for today")
        #expect(m.stepsReading == "8,000 / 8,000")
        #expect(m.fuelReading == "110 KCAL")
        #expect(m.proteinReading == "105 / 150 G")
        #expect(m.context == "TODAY · 22:14")
        #expect(m.pulse?.events.count == 5)
    }

    @Test func missingSnapshotShowsDashes() {
        let dir = temporaryDirectory()
        for m in [WidgetTimeline.entries(directory: dir, now: now)[0].model, WidgetTimeline.entries(directory: nil, now: now)[0].model] {
            #expect(m == .missing)
            #expect(m.recovery == nil && m.label == nil && m.headline == nil && m.recoveryGauge == nil && m.pulse == nil)
            #expect(m.tone == .steel)
            #expect(m.context == "TODAY")
            #expect(m.stepsReading == "–" && m.fuelReading == "–" && m.proteinReading == "–")
            #expect(m.stepsLine == "– STEPS" && m.kcalLine == "– KCAL LEFT")
            #expect(m.inline == "– · – STEPS")
        }
    }

    @Test func partialSnapshotDashesOnlyWhatIsMissing() {
        let s = TodaySnapshot(day: "2026-10-24", verdict: .init(band: nil, label: nil, headline: ""),
                              recovery: .init(score: nil, band: "ease"), steps: 1200, stepsTarget: nil, kcalLeft: nil,
                              proteinG: 20, proteinTargetG: nil, pulse: nil, lastSync: nil, generatedAt: nil)
        let m = WidgetModel(s)
        #expect(m.recovery == nil && m.recoveryGauge == nil)
        #expect(m.label == "EASE" && m.tone == .watch)
        #expect(m.headline == nil)
        #expect(m.stepsReading == "1,200" && m.fuelReading == "–" && m.proteinReading == "20 G")
    }

    @Test func extensionsShareTheAppGroup() {
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: "com.example.vitalis.widgets") == "group.com.example.vitalis")
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: "com.example.vitalis.watchkitapp.widgets") == "group.com.example.vitalis")
        #expect(WidgetTimeline.sharedDirectory(bundleIdentifier: "com.example.other") == nil)
    }

    @Test func widgetLinksRouteInTheApp() {
        #expect(DeepLinks.parse(WidgetLink.today) == .tab(.today))
        #expect(DeepLinks.parse(WidgetLink.logMeal) == .eatAdd(slot: nil))
    }

    // MARK: Complication transfer (spec 21 §3)

    @Test func complicationChannelFallsBackWhenTheBudgetIsSpent() {
        #expect(ComplicationTransfer.channel(isPaired: true, isWatchAppInstalled: true, remainingComplicationTransfers: 3) == .complicationUserInfo)
        #expect(ComplicationTransfer.channel(isPaired: true, isWatchAppInstalled: true, remainingComplicationTransfers: 0) == .applicationContext)
        #expect(ComplicationTransfer.channel(isPaired: false, isWatchAppInstalled: true, remainingComplicationTransfers: 3) == .none)
        #expect(ComplicationTransfer.channel(isPaired: true, isWatchAppInstalled: false, remainingComplicationTransfers: 3) == .none)
    }

    @Test func complicationPayloadRoundTripsAndWritesOnce() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = TodaySnapshot(try Fixture.decode(TodayResponse.self, "today"))
        let payload = try #require(ComplicationTransfer.payload(snapshot))
        #expect(ComplicationTransfer.snapshot(from: payload) == snapshot)
        #expect(ComplicationTransfer.snapshot(from: ["today": Data("nope".utf8)]) == nil)
        #expect(ComplicationTransfer.snapshot(from: [:]) == nil)
        #expect(ComplicationTransfer.receive(payload, into: dir))
        #expect(!ComplicationTransfer.receive(payload, into: dir))
        #expect(WidgetTimeline.entries(directory: dir, now: now)[0].model == WidgetModel(snapshot))
    }
}
