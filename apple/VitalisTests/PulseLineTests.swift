import Foundation
import Testing
@testable import VitalisUI

@Suite struct PulseLineTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var end: Date { start.addingTimeInterval(1000) }

    @Test func fractionClampsToTheWindow() {
        #expect(PulseLine.fraction(at: start.addingTimeInterval(-60), start: start, end: end) == 0)
        #expect(PulseLine.fraction(at: end.addingTimeInterval(60), start: start, end: end) == 1)
        #expect(PulseLine.fraction(at: start.addingTimeInterval(250), start: start, end: end) == 0.25)
        #expect(PulseLine.fraction(at: start, start: start, end: start) == 1)
    }

    @Test func positionsParseIsoStringsWithOffsets() throws {
        let p = try #require(PulseLine.positions(
            windowStart: "2026-10-24T06:00:00+05:30", windowEnd: "2026-10-24T22:00:00+05:30",
            now: "2026-10-24T04:30:00Z", // 10:00 IST
            events: ["2026-10-24T06:00:00+05:30", "2026-10-24T08:00:00.500+05:30"]))
        #expect(p.now == 0.25)
        #expect(p.events.count == 2)
        #expect(p.events[0] == 0)
        #expect(abs(p.events[1] - (2 * 3600 + 0.5) / (16 * 3600)) < 1e-9)
        #expect(PulseLine.positions(windowStart: "nope", windowEnd: "2026-10-24T22:00:00+05:30",
                                    now: "2026-10-24T10:00:00+05:30", events: []) == nil)
    }

    @Test func eventsAfterNowAreDropped() throws {
        let p = try #require(PulseLine.positions(
            windowStart: "2026-10-24T06:00:00+05:30", windowEnd: "2026-10-24T22:00:00+05:30",
            now: "2026-10-24T10:00:00+05:30",
            events: ["2026-10-24T12:00:00+05:30", "2026-10-24T07:00:00+05:30", "garbage"]))
        #expect(p.events.count == 1)
        #expect(p.events[0] == 1.0 / 16)

        let layout = PulseLine.layout(events: [0.2, 0.9], now: 0.5, style: .phone, width: 390)
        let deepest = try #require(layout.past.map(\.y).max())
        #expect(deepest == 34) // baseline 12 + depth 22, only the 0.2 dip
        #expect(layout.past.allSatisfy { $0.x <= 195 })
        #expect(layout.dotX == 195)
    }

    @Test func dipsClampInsideTheWidth() throws {
        let layout = PulseLine.layout(events: [0], now: 1, style: .phone, width: 390)
        let bottom = try #require(layout.past.first { $0.y == 34 })
        #expect(bottom.x == 16)
        #expect(layout.past.allSatisfy { $0.x >= 0 && $0.x <= 390 })
        #expect(layout.dotX == 390 - 4.5)
        #expect(PulseLine.Style.phone.height == 40)
        #expect(PulseLine.Style.progress.height == 40)
    }
}
