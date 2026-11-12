import Foundation
import Testing
@testable import LiveSubs

/// The clock of a capture that can be put on hold: a pause stops it, and the time on hold is
/// not part of the meeting.
@Suite struct CaptureClockTests {
    @Test func theClockRunsWhileTheCaptureRuns() {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = CaptureClock(startedAt: start)
        #expect(clock.elapsed(at: start) == 0)
        #expect(clock.elapsed(at: start.addingTimeInterval(30)) == 30)
    }

    @Test func aPauseStopsTheClock() {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = CaptureClock(startedAt: start)
        clock.pause(at: start.addingTimeInterval(30))
        #expect(clock.isPaused)
        // The clock stands still: five minutes on hold are still thirty seconds of meeting.
        #expect(clock.elapsed(at: start.addingTimeInterval(330)) == 30)
    }

    @Test func resumingTakesTheTimeOnHoldOffTheClock() {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = CaptureClock(startedAt: start)
        clock.pause(at: start.addingTimeInterval(30))
        clock.resume(at: start.addingTimeInterval(330))
        #expect(!clock.isPaused)
        // Thirty seconds before the pause, five minutes after the resume.
        #expect(clock.elapsed(at: start.addingTimeInterval(360)) == 60)
    }

    @Test func twoPausesAreBothTakenOff() {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = CaptureClock(startedAt: start)
        clock.pause(at: start.addingTimeInterval(10))
        clock.resume(at: start.addingTimeInterval(40))
        clock.pause(at: start.addingTimeInterval(50))
        clock.resume(at: start.addingTimeInterval(70))
        // Twenty seconds of meeting: 10 before the first pause, 10 between the two.
        #expect(clock.elapsed(at: start.addingTimeInterval(70)) == 20)
    }

    @Test func pausingTwiceKeepsTheFirstPause() {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = CaptureClock(startedAt: start)
        clock.pause(at: start.addingTimeInterval(30))
        clock.pause(at: start.addingTimeInterval(60))
        #expect(clock.elapsed(at: start.addingTimeInterval(120)) == 30)
    }

    @Test func resumingWhileRunningChangesNothing() {
        let start = Date(timeIntervalSince1970: 1000)
        var clock = CaptureClock(startedAt: start)
        clock.resume(at: start.addingTimeInterval(30))
        #expect(!clock.isPaused)
        #expect(clock.elapsed(at: start.addingTimeInterval(60)) == 60)
    }
}
