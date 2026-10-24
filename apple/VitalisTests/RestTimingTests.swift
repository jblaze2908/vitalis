import Foundation
import Testing
import VitalisKit

@Suite struct RestTimingTests {
    let start = Date(timeIntervalSince1970: 1_792_800_000)

    @Test func remainingAndFractionComeFromTheEndDate() {
        let timer = RestTimer(start: start, duration: 120)
        #expect(timer.remaining(at: start) == 120)
        #expect(timer.remaining(at: start.addingTimeInterval(36)) == 84)
        #expect(abs(timer.fraction(at: start.addingTimeInterval(36)) - 0.7) < 1e-9)
        #expect(timer.remaining(at: start.addingTimeInterval(500)) == 0)
        #expect(timer.fraction(at: start.addingTimeInterval(500)) == 0)
        #expect(timer.isFinished(at: start.addingTimeInterval(120)))
        #expect(!timer.isFinished(at: start.addingTimeInterval(119.5)))
    }

    @Test func staysCorrectAfterAMinuteWithNoTicks() {
        // Wrist-down: no view updates for 60 s, the next read is still exact.
        let timer = RestTimer(start: start, duration: 120)
        #expect(timer.remaining(at: start.addingTimeInterval(60)) == 60)
        #expect(timer.fraction(at: start.addingTimeInterval(60)) == 0.5)
    }

    @Test func plusAndMinusFifteen() {
        let timer = RestTimer(start: start, duration: 120)
        let now = start.addingTimeInterval(36)
        let plus = timer.adjusted(by: RestTimer.step, at: now)
        #expect(plus.remaining(at: now) == 99)
        #expect(plus.total == 120)
        let minus = timer.adjusted(by: -RestTimer.step, at: now)
        #expect(minus.remaining(at: now) == 69)
    }

    @Test func plusFifteenAtTheStartGrowsTheTotalSoTheRingIsFull() {
        let timer = RestTimer(start: start, duration: 120).adjusted(by: 15, at: start)
        #expect(timer.remaining(at: start) == 135)
        #expect(timer.total == 135)
        #expect(timer.fraction(at: start) == 1)
    }

    @Test func minusFifteenNearZeroFinishes() {
        let now = start.addingTimeInterval(110)
        let timer = RestTimer(start: start, duration: 120).adjusted(by: -15, at: now)
        #expect(timer.isFinished(at: now))
        #expect(timer.fraction(at: now) == 0)
    }

    @Test func clockTextRoundsUp() {
        #expect(RestTimer.clockText(120) == "2:00")
        #expect(RestTimer.clockText(84) == "1:24")
        #expect(RestTimer.clockText(83.2) == "1:24")
        #expect(RestTimer.clockText(9) == "0:09")
        #expect(RestTimer.clockText(0) == "0:00")
        #expect(RestTimer.clockText(-3) == "0:00")
    }

    @Test func zeroOrNegativeDurationDoesNotDivideByZero() {
        let timer = RestTimer(start: start, duration: 0)
        #expect(timer.fraction(at: start) == 0)
        #expect(timer.isFinished(at: start))
    }
}
