import Foundation

/// Decides when a meeting is over, so one nobody ended doesn't run on for hours and pull the next
/// video or meeting into its notes.
///
/// Two signals. The main one: a meeting app (Zoom, 腾讯会议…) that was reading a microphone during
/// this meeting lets go of it, which is what hanging up looks like from outside; a short grace
/// covers switching devices. The fallback, for meetings in a browser or in the room: nothing was
/// recognised for a while. "Nothing recognised" counts words, not sound, so background music
/// doesn't keep a meeting alive. While a meeting app is still in a call, silence doesn't count:
/// muted webinars and quiet screen shares are still meetings. Pure; `AppModel` ticks it.
struct MeetingEndWatch: Equatable {
    /// What to do when nobody has said anything for a while.
    ///
    /// "prompt" counts down and then ends, "pause" counts down and then holds the meeting on
    /// hold — the words are still written down, but nothing is recognised while it is quiet, so
    /// a long gap does not cost anything and does not have to be thrown away. "end" stops it at
    /// once, "off" never reacts to silence.
    enum Silence: String { case prompt, pause, end, off }

    struct Config: Equatable {
        var followApps = true
        var silence: Silence = .prompt
        var silenceAfter: TimeInterval = 600
        /// How long the "没人说话" prompt waits before ending.
        var countdown: TimeInterval = 60
        /// How long after a hang-up before ending: a device switch drops the mic for a moment.
        var appGrace: TimeInterval = 30
    }

    enum Reason: Equatable {
        /// The meeting app (by name) hung up.
        case appLeft(String)
        case silence
        /// Nobody spoke at all: there is nothing to keep, so it just stops, without a countdown.
        case nobodySpoke
        /// The room went quiet: the meeting is held on hold instead of being ended.
        case silencePause
    }

    struct Pending: Equatable {
        var reason: Reason
        var deadline: Date
    }

    var config: Config
    /// The meeting ends at `deadline` unless someone keeps it going.
    private(set) var pending: Pending?
    private(set) var lastSpeech: Date
    /// Meeting apps seen in a call during this meeting (bundle id → name).
    private(set) var inCall: [String: String] = [:]

    init(config: Config, start: Date) {
        self.config = config
        lastSpeech = start
    }

    /// Words were recognised (theirs or mine): a silence countdown stops. A hang-up doesn't: the
    /// next video would talk over it.
    mutating func heard(at now: Date) {
        lastSpeech = now
        if pending?.reason == .silence { pending = nil }
    }

    /// "继续记录": forget the hang-up and start counting silence again.
    mutating func keepGoing(at now: Date) {
        pending = nil
        lastSpeech = now
        inCall = [:]
    }

    /// `calls`: meeting apps reading a microphone now. `said`: the meeting has lines. One without
    /// keeps listening for the silence time (the subtitles stay ready), then stops quietly: a
    /// forgotten switch shouldn't listen to an empty room for hours. A call that ended before anyone
    /// spoke doesn't count. Returns why the meeting ends now, if it does.
    mutating func tick(at now: Date, calls: [String: String], said: Bool) -> Reason? {
        guard said else {
            inCall = config.followApps ? calls : [:]
            pending = nil
            let inACall = config.followApps && !calls.isEmpty
            if config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
                // A pause holds the meeting on hold however quiet it is, even before the first
                // words: the same quiet rule, the same answer.
                if config.silence == .pause { return .silencePause }
                return .nobodySpoke
            }
            return nil
        }
        if config.followApps {
            for (id, name) in calls { inCall[id] = name }
            let hungUp = !inCall.isEmpty && inCall.keys.allSatisfy { calls[$0] == nil }
            if case .appLeft = pending?.reason, !hungUp { pending = nil } // rejoined
            if hungUp, pending == nil || pending?.reason == .silence {
                let name = inCall.sorted { $0.key < $1.key }.first?.value ?? ""
                pending = Pending(reason: .appLeft(name), deadline: now.addingTimeInterval(config.appGrace))
            }
        } else if case .appLeft = pending?.reason {
            pending = nil
        }
        let inACall = config.followApps && !calls.isEmpty
        if pending == nil, config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
            if config.silence == .end { return .silence }
            pending = Pending(reason: .silence, deadline: now.addingTimeInterval(config.countdown))
        }
        if config.silence == .off || inACall, pending?.reason == .silence { pending = nil }
        if let p = pending, now >= p.deadline {
            pending = nil
            // A pause is what the quiet was for: the meeting is held on hold, not thrown away.
            if p.reason == .silence, config.silence == .pause { return .silencePause }
            return p.reason
        }
        return nil
    }
}
