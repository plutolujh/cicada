import Foundation

/// The clock of a capture that can be put on hold.
///
/// A pause stops the clock: the time spent on hold is not part of the meeting, so the clock
/// stands still while paused and goes on from where it stopped when the capture is taken back
/// up. The toolbar pill and the capture surface both read this, so they show the same time.
struct CaptureClock: Equatable {
    /// When the capture began.
    private let startedAt: Date
    /// When the capture was put on hold, while it is on hold.
    private var pausedAt: Date?
    /// How long the capture has been on hold in total.
    private var heldTotal: TimeInterval = 0

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Puts the capture on hold, at this moment.
    mutating func pause(at now: Date = Date()) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    /// Takes the capture back up, at this moment: the time on hold is taken off the clock.
    mutating func resume(at now: Date = Date()) {
        guard let at = pausedAt else { return }
        heldTotal += now.timeIntervalSince(at)
        pausedAt = nil
    }

    /// Whether the capture is on hold right now.
    var isPaused: Bool { pausedAt != nil }

    /// How long the capture has been running, without the time spent on hold.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - heldTotal)
    }
}
