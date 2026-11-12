import Foundation

/// The moment a finished recording is put into the meeting list.
///
/// A recording does not simply stop: the audio, the words, the translation and the notes all
/// go into one meeting record, and the user is shown that happening rather than being dropped
/// into a list where the recording used to be.
struct RecordSaving: Equatable {
    /// What the recording becomes.
    let sessionID: String
    /// The name the meeting will be known by.
    let title: String
    /// How long the recording ran.
    let duration: Double
    /// How many sentences were heard.
    let lines: Int
    /// Whether the translation was written.
    let translated: Bool
    /// Whether the notes are being written.
    let notes: Bool
    /// The audio file that was kept.
    let hasAudio: Bool

    /// The parts of the record, in the order they are put in.
    var parts: [Part] {
        var out: [Part] = []
        if hasAudio { out.append(.audio) }
        out.append(.transcript)
        if translated { out.append(.translation) }
        if notes { out.append(.notes) }
        return out
    }

    /// One thing that goes into the meeting record.
    enum Part: String, Equatable, CaseIterable {
        case audio, transcript, translation, notes

        /// The name shown while it is being saved.
        var title: String {
            switch self {
            case .audio: return L("录音音频")
            case .transcript: return L("原文")
            case .translation: return L("翻译")
            case .notes: return L("纪要")
            }
        }

        /// The glyph that stands for it.
        var glyph: String {
            switch self {
            case .audio: return "waveform"
            case .transcript: return "text.quote"
            case .translation: return "character.bubble"
            case .notes: return "list.bullet.rectangle"
            }
        }
    }
}
