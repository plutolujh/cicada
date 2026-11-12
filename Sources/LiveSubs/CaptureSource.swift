import Foundation
import SwiftUI

/// Where the words are coming from: what the Mac is playing, or the microphone in front of it.
///
/// The two are the same thing to the reader — words heard, then a summary written from them —
/// so they share one surface: the same transcript column on the left, the same live notes on
/// the right. Only the way in differs, and this is where that difference is kept.
enum CaptureSource: String, CaseIterable, Identifiable, Equatable {
    /// What the Mac is playing: a call, a video, a song.
    case system
    /// The microphone: the people in the room.
    case mic

    var id: String { rawValue }

    /// The name on the switch that picks the source.
    var title: LocalizedStringKey {
        switch self {
        case .system: return "系统声音"
        case .mic: return "麦克风"
        }
    }

    /// A line under the name, saying what this source hears.
    var hint: LocalizedStringKey {
        switch self {
        case .system: return "听电脑里放的声音：会议、视频。"
        case .mic: return "录房间里的声音：说话的人。"
        }
    }

    var icon: String {
        switch self {
        case .system: return "hifispeaker.2"
        case .mic: return "mic"
        }
    }

    /// Where the recording of this source goes, so the two never fight over one file.
    var audioFolder: String {
        switch self {
        case .system: return "system"
        case .mic: return "mic"
        }
    }
}

/// The live words, as the reader sees them: what is being said right now, and the sentences
/// that have settled.
///
/// The microphone path has its own engine, which knows its words as they arrive. The system
/// audio path reports them through callbacks. This is the one shape both are read through, so
/// the transcript column does not care where the words came from.
@MainActor
final class CaptureFeed: ObservableObject {
    /// The sentence being heard right now; it changes as the speaker continues.
    @Published var live = ""
    /// The words of the sentence being heard, in the order they were said.
    @Published var liveWords: [LiveWord] = []
    /// The sentences that have settled, oldest first.
    @Published var lines: [RecordLine] = []
    /// The level of the input right now, 0…1.
    @Published var level: Float = 0
    /// The last few seconds of level, for the scope: the newest sample is last.
    @Published var waveform: [Float] = []
    /// How long this capture has run.
    @Published var elapsed: TimeInterval = 0
    /// The language heard in the last sentence.
    @Published var lang: Lang?
    /// Why the capture stopped early, when it did.
    @Published var problem: String?

    /// Whether a capture is running right now.
    @Published var running = false

    /// The source these words are coming from.
    @Published var source: CaptureSource = .system

    /// How the transcript shows each sentence: as it was said, translated, or both.
    enum Display: String, CaseIterable, Equatable {
        case original
        case translated
        case bilingual
    }
    @Published var display: Display = .bilingual

    /// Replaces the whole transcript; used when the source changes or a capture ends.
    func reset() {
        live = ""
        liveWords = []
        lines = []
        level = 0
        waveform = []
        elapsed = 0
        problem = nil
    }

    /// Takes the words of a sentence being heard.
    func setLive(_ text: String, words: [LiveWord]) {
        live = text
        liveWords = words
    }
}
