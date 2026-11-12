import Foundation

/// Whether a finished sentence may go into the meeting record.
///
/// The language a line was heard in has to be settled first: a sentence transcribed with the
/// wrong model would be translated wrong too, and the record would keep it for good. In
/// 自动识别 the language is settled by the detection, and the detection needs a second model to
/// choose between — on a Mac with one installed model there is nothing to choose, so waiting for
/// a confirmation that can never come leaves the record empty while the subtitles work.
enum RecordGate {
    static func recordable(mode: SourceMode, candidates: [Lang], active: Lang?,
                           confirmed: Bool, ambiguous: Int) -> Bool {
        // The language was chosen by hand: nothing to settle.
        if case .fixed = mode { return true }
        // One model installed and it is the one in use: the language is the only possibility.
        if candidates.count == 1, let only = candidates.first, active == only { return true }
        return confirmed || ambiguous >= 2
    }
}
