import Foundation
import Testing
@testable import LiveSubs

/// The pill carries three kinds of place, and a double click has to answer differently on
/// each of them: the logo keeps ending the meeting, the buttons keep doing their own thing,
/// and only the body opens the main window.
@Suite struct PillDoubleClickTests {
    /// The listening state as it is drawn: the logo on the left, the body in the middle with
    /// the meter and the clock, and 暂停 / 结束 on the right.
    func listening() -> PillDoubleClick {
        PillDoubleClick(
            body: CGRect(x: 30, y: 0, width: 150, height: 32),
            buttons: [
                CGRect(x: 4, y: 5, width: 22, height: 22),   // the logo
                CGRect(x: 190, y: 4, width: 48, height: 24),  // 暂停
                CGRect(x: 248, y: 4, width: 48, height: 24),  // 结束
            ]
        )
    }

    @Test func theBodyOpensTheMainWindow() {
        #expect(listening().opensMainWindow(at: CGPoint(x: 100, y: 16)))
    }

    @Test func theLogoDoesNotOpenTheMainWindow() {
        // The logo ends the meeting; a double click there must keep that and open nothing.
        #expect(!listening().opensMainWindow(at: CGPoint(x: 15, y: 16)))
    }

    @Test func theButtonsDoNotOpenTheMainWindow() {
        #expect(!listening().opensMainWindow(at: CGPoint(x: 210, y: 16)))
        #expect(!listening().opensMainWindow(at: CGPoint(x: 270, y: 16)))
    }

    @Test func aPillWithoutABodyOpensNothing() {
        // The idle state: the whole pill is the 开始听 button, so there is no body.
        let idle = PillDoubleClick(body: .null, buttons: [CGRect(x: 0, y: 0, width: 300, height: 32)])
        #expect(!idle.opensMainWindow(at: CGPoint(x: 150, y: 16)))
    }

    @Test func aButtonThatReachesIntoTheBodyWins() {
        // The regions are measured from the same drawing, but a button's frame can reach over
        // the body's stretch; the button wins, so the meeting is never ended by accident.
        let pill = PillDoubleClick(
            body: CGRect(x: 30, y: 0, width: 150, height: 32),
            buttons: [CGRect(x: 4, y: 5, width: 60, height: 22)]
        )
        #expect(!pill.opensMainWindow(at: CGPoint(x: 50, y: 16)))
        #expect(pill.opensMainWindow(at: CGPoint(x: 120, y: 16)))
    }

    @Test func aClickOutsideThePillOpensNothing() {
        #expect(!listening().opensMainWindow(at: CGPoint(x: 400, y: 16)))
        #expect(!listening().opensMainWindow(at: CGPoint(x: 100, y: 80)))
    }
}
