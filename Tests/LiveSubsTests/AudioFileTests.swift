import AVFoundation
import Foundation
import Testing
@testable import LiveSubs

/// The audio file of a recording is written as a partial and rewrapped into an .m4a when it
/// closes. Two callers can ask for the rewrap at once — the recorder owns the file and the
/// session store finishes it too — and the rewrap of one file has to happen once.
@Suite struct AudioFileTests {
    /// A short piece of real audio, because a rewrap of something that is not audio fails.
    /// It is written the way a recorder writes it: AAC in an ADTS container (a `.aac` partial),
    /// so the rewrap has a real file to work on. The file is closed before the caller goes on,
    /// so everything written is on disk when the rewrap reads it.
    private func writeAudio(to url: URL) {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        autoreleasepool {
            guard let file = AudioFileWriter.open(url, format: format) else { return }
            let frames = AVAudioFrameCount(format.sampleRate / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.int16ChannelData![0]
            for i in 0..<Int(frames) { samples[i] = Int16(2000 * sin(2 * .pi * 220 * Double(i) / format.sampleRate)) }
            try? file.write(from: buffer)
        }
    }

    @Test func oneRewrapPerFileHappensWhenTwoCallersAsk() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cicada-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("mic.m4a")
        // The partial is what a recorder leaves behind; the rewrap turns it into the .m4a.
        writeAudio(to: AudioFileWriter.partial(url))

        // Both callers ask at the same time, as the recorder and the store do.
        async let first = AudioFileWriter.finish(url)
        async let second = AudioFileWriter.finish(url)
        _ = await (first, second)

        // The partial is gone and the .m4a is there: the rewrap ran once and finished.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: AudioFileWriter.partial(url).path))
    }

    @Test func aFinishedFileIsNeverTakenAway() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cicada-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("mic.m4a")
        // A recording that was closed: the partial becomes the .m4a.
        writeAudio(to: AudioFileWriter.partial(url))
        await AudioFileWriter.finish(url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A partial next to a finished file is the leftover of a rewrap that was cut short.
        writeAudio(to: AudioFileWriter.partial(url))

        await AudioFileWriter.finish(url)

        // The recording is still there; only the leftover is cleared away.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: AudioFileWriter.partial(url).path))
    }
}
