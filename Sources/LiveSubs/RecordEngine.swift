import AVFoundation
import Foundation
import Speech

// MARK: - A recording

/// One word of the sentence being heard right now, with the moment it was said.
///
/// The words arrive one by one, so the transcript can show the sentence as it is being spoken
/// rather than all at once when it is finished.
struct LiveWord: Identifiable, Equatable {
    let id: Int
    /// The word as it was heard.
    var text: String
    /// Seconds from the start of the recording.
    var t: Double
    /// How sure the model is about this word (0…1), when it says.
    var confidence: Double?
}

/// One settled sentence: what was said, when it started, and in which language.
struct RecordLine: Identifiable, Equatable {
    let id: String
    /// Seconds from the start of the recording.
    var t: Double
    var text: String
    var translation: String?
    var lang: String
    /// Which voice said it, when the voiceprints can tell them apart.
    var voice: Int?
    /// The number the voice is shown under: 人物 1, 人物 2… The numbers follow the order the
    /// voices were first heard, so a person keeps their number.
    var person: Int?
    /// How long the sentence took, so playback knows where it ends.
    var end: Double?
    /// When each word of the sentence was said, so the words can be stepped through.
    var words: [LiveWord] = []
    /// AI 纠错后的文本；nil = 未纠错或纠错后无变化。保留原始 `text` 以便对照/回滚。
    var corrected: String?

    var displayText: String { corrected ?? text }
}

/// The numbers the people of a recording are shown under: 人物 1, 人物 2, 人物 3…
///
/// The numbers follow the order the voices were first heard, so a person keeps their number
/// for the whole recording, however many lines they say.
struct PersonNumbers {
    private var numbers: [Int: Int] = [:]

    /// The number of a voice; the first voice heard is 1.
    mutating func number(for voice: Int) -> Int {
        if let n = numbers[voice] { return n }
        let n = numbers.count + 1
        numbers[voice] = n
        return n
    }

    /// How many people have been heard.
    var count: Int { numbers.count }
}

// MARK: - The engine

/// Records the microphone, transcribes it on this Mac, and keeps a running summary beside it.
///
/// The microphone instead of the system audio (which is what listening does) is the point: this is
/// a recording of a person, and it has to be one file they can keep.
///
/// The transcription is the same on-device engine listening uses, so the words are never in the
/// cloud; the summary and the translation are the only things that leave the Mac, and they go
/// through the same AI client as everything else.
@MainActor
final class RecordEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case stopping
    }

    // MARK: Outputs

    /// The sentence being heard right now; it changes as the speaker continues.
    @Published private(set) var live = ""
    /// The words of the sentence being heard, in the order they were said.
    ///
    /// This is what makes the transcript look like it is being written: the words show up as
    /// they are spoken, before the sentence is finished.
    @Published private(set) var liveWords: [LiveWord] = []
    /// The sentences that are settled.
    @Published private(set) var lines: [RecordLine] = []
    /// The language heard in the last sentence.
    @Published private(set) var lang: Lang?
    /// How long the recording has run.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var state: State = .idle
    /// The level of the microphone right now, 0…1, for the meter.
    @Published private(set) var level: Float = 0
    /// The last few seconds of level, for the scope: the newest sample is last.
    @Published private(set) var waveform: [Float] = []
    /// Why the recording stopped early, when it did.
    @Published private(set) var problem: String?

    /// How the transcript shows each sentence: as it was said, translated, or both.
    enum Display: String, CaseIterable, Equatable {
        /// The words as they were heard.
        case original
        /// The translation on its own.
        case translated
        /// The words as they were heard, with the translation underneath.
        case bilingual
    }
    /// What the transcript shows now.
    @Published var display: Display = .bilingual

    /// The translation target; "none" leaves the sentences untranslated.
    var target = "none"
    /// Keep the audio next to the transcript.
    var keepsAudio = true
    /// Detect the language instead of using one fixed model.
    var detectsLanguage = true
    /// The language to record in, when it is not detected; "auto" detects it.
    var heardLanguage = "auto"

    // MARK: Wiring

    /// The service that translates and summarizes.
    var ai: AIClient?
    /// Called for every settled sentence, so it can be put into the meeting record.
    var onLine: ((RecordLine) -> Void)?
    /// Called when a sentence's translation arrives, so the record can be updated too.
    var onTranslation: ((String, String) -> Void)?
    /// Called when a sentence's voice is known, so the record can be updated too.
    var onVoice: ((String, Int?) -> Void)?
    /// Called when a sentence is edited, merged or split, so the record is updated too.
    var onEdit: ((String) -> Void)?
    /// Called when the sentences of the recording change, so the record is rewritten.
    var onRewrite: (() -> Void)?
    /// Called when the sentences of the recording change, so the record is rewritten.
    var onAutoCorrect: (() -> Void)?
    /// Called when the polishing starts and when it is done, so the surfaces can say so.
    var onCorrecting: ((Bool) -> Void)?
    /// Called whenever the recording state changes, so the toolbar pill stays in step.
    var onState: ((State) -> Void)?
    /// The languages a model is installed for.
    var installed: Set<String> = []
    /// The languages worth detecting between.
    var candidates: [Lang] = []
    /// Where the recording is written.
    var audioURL: URL?
    /// The microphone to record from; nil is the system default.
    var inputDevice: OutputDevice?
    /// Tells the voices apart: each settled sentence's audio becomes a voiceprint, and the
    /// voiceprint says who said it.
    var tagger: SpeakerTagger?

    // MARK: Internals

    private let mic = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.wquguru.cicada.record", qos: .userInitiated)
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter = PCMConverter()
    private var recorder: AVAudioFile?
    private var tickTimer: Timer?
    private var generation = 0
    private var nextLineID = 0
    private var startedAt = Date()
    /// The clock of the recording: it stands still while the recording is paused, so the time
    /// on hold is not part of the recording.
    private var clock = CaptureClock(startedAt: Date())
    private var recordingFormat: AVAudioFormat?
    private var levelPeak: Float = 0
    /// The language the current model is for.
    private var modelLang: Lang?
    /// The languages heard since the recording started, for the summary.
    private var heard: [String] = []
    /// The recent audio, so the language can be detected again mid-recording.
    private var clip: [AVAudioPCMBuffer] = []
    private var clipSeconds = 0.0
    private let clipLimit = 12.0
    /// The audio of the last minute or so, 16 kHz mono, on the analyzer's clock: the voiceprint
    /// of a settled sentence is cut out of it.
    private var voiceAudio: [Float] = []
    private var voiceStart = 0.0
    private let voiceLimit = 90.0
    /// Seconds of audio given to the analyzer: its clock, the one a result's time range is on.
    private var fed = 0.0
    /// Its own converter: the analyzer's converter is stateful and cannot be reused for another format.
    private let voiceConverter = PCMConverter()
    private let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// Voice id → the number the person is shown under (人物 1, 人物 2…).
    private var persons = PersonNumbers()
    /// When the language was last looked at, and whether a look is already running.
    private var lastDetectionAt = Date.distantPast
    private var detecting = false
    /// How much speech has to be heard before the language is looked at again.
    private var nextDetectionAt = 20.0
    /// The language the recording was confirmed to be in.
    private var confirmed = false

    // MARK: Start / stop

    func start() {
        guard state == .idle else { return }
        state = .preparing
        onState?(.preparing)
        problem = nil
        live = ""
        liveWords = []
        lines = []
        elapsed = 0
        level = 0
        waveform = []
        heard = []
        clip = []
        clipSeconds = 0
        voiceAudio = []
        voiceStart = 0
        fed = 0
        persons = PersonNumbers()
        nextLineID = 0
        generation += 1
        startedAt = Date()
        clock = CaptureClock(startedAt: startedAt)
        lastDetectionAt = .distantPast
        detecting = false
        nextDetectionAt = 20.0
        confirmed = false

        // The detector needs at least two models to choose from; with fewer it would always
        // guess the same one, so the first language is used until more are installed.
        let pool = candidates.filter { installed.contains($0.locale) }
        let first = pool.first(where: { $0.locale == heardLanguage })
            ?? pool.first ?? candidates.first ?? sourceLanguages[0]
        Task {
            await prepare(first)
            guard state == .preparing else { return }
            startMic()
            guard state == .preparing else { return }
            startTick()
            state = .recording
            onState?(.recording)
            debugLog("record: started lang=\(first.locale)")
        }
    }

    func stop() {
        guard state == .recording || state == .preparing || state == .paused else { return }
        state = .stopping
        onState?(.stopping)
        generation += 1
        tickTimer?.invalidate()
        tickTimer = nil
        stopMic()
        resultsTask?.cancel()
        resultsTask = nil
        input?.finish()
        input = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        // The sentence that was being spoken is kept: the person stopped talking in the middle
        // of it, but what they said is not thrown away.
        settleLive()
        closeRecorder()
        state = .idle
        onState?(.idle)
        debugLog("record: stopped lines=\(lines.count)")
        // Auto-correction runs after recording ends; caller should call runAutoCorrect(glossary:)
        // which is triggered by AppModel.
    }

    /// Pauses the recording: the microphone stays on but no new sentences are transcribed and
    /// the clock freezes. Press 恢复 to continue; 停止 ends the recording.
    func pause() {
        guard state == .recording else { return }
        clock.pause()
        elapsed = clock.elapsed()
        state = .paused
        onState?(.paused)
        generation += 1
        debugLog("record: paused lines=\(lines.count)")
    }

    /// Resumes a paused recording: new sentences are transcribed again and the clock moves on
    /// from where it stopped.
    func resume() {
        guard state == .paused else { return }
        clock.resume()
        startedAt = Date().addingTimeInterval(-clock.elapsed())
        state = .recording
        onState?(.recording)
        debugLog("record: resumed lines=\(lines.count)")
    }

    /// Turns the sentence being heard into a settled one, when the recording ends in the middle
    /// of it.
    private func settleLive() {
        let text = HeardText.clean(live.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.contains(where: \.isLetter) else { return }
        let start = liveWords.first?.t ?? elapsed
        let end = liveWords.last?.t ?? elapsed
        live = ""
        liveWords = []
        add(text, at: start, until: end)
    }

    // MARK: The model

    /// A transcriber for one language, its analyzer and the format it wants.
    private func prepare(_ lang: Lang) async {
        guard SpeechTranscriber.isAvailable else {
            state = .idle
            problem = L("此 Mac 不支持本机语音识别")
            return
        }
        // The audio time range is asked for: it gives each word its own moment, which is what
        // lets the words show up one by one as they are spoken.
        let t = SpeechTranscriber(locale: Locale(identifier: lang.locale), transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults],
                                  attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [t]) != .installed,
           let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard state != .idle else { return }
        analyzerFormat = format
        transcriber = t
        modelLang = lang
        self.lang = lang
        startAnalyzer(t, format: format)
    }

    /// Swaps in another language's model, for when the speaker changes language.
    ///
    /// The old analyzer is finished rather than cancelled, so the sentence it was in the middle
    /// of still arrives; the new one takes over from the next buffer.
    private func switchModel(to lang: Lang) async {
        guard lang != modelLang, state == .recording else { return }
        generation += 1
        let oldTask = resultsTask
        resultsTask = nil
        if let old = analyzer {
            analyzer = nil
            // finishAndRestart would throw the pending results away; cancelAndFinishNow lets
            // the final ones out first.
            await old.cancelAndFinishNow()
        }
        oldTask?.cancel()
        live = ""
        liveWords = []
        debugLog("record: switching model to \(lang.locale)")
        await prepare(lang)
    }

    private func startAnalyzer(_ t: SpeechTranscriber, format: AVAudioFormat) {
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        input = cont
        let gen = generation
        let task = Task { [weak self] in
            do {
                for try await result in t.results { self?.handle(result, generation: gen) }
            } catch {
                debugLog("record: recognition error: \(error)")
            }
        }
        resultsTask = task
        let a = SpeechAnalyzer(modules: [t])
        analyzer = a
        Task {
            do {
                try await a.prepareToAnalyze(in: format)
                try await a.start(inputSequence: stream)
            } catch {
                debugLog("record: analyzer start failed: \(error)")
            }
        }
    }

    // MARK: The language

    /// Looks at what was just said and decides which language it was in.
    ///
    /// The recording keeps going with the model it has; only a clear answer (a good margin over
    /// the runner-up) changes the model, because swapping models mid-sentence loses words.
    private func maybeDetectLanguage() {
        guard detectsLanguage, !detecting, state == .recording else { return }
        let pool = candidates.filter { installed.contains($0.locale) }
        guard pool.count >= 2 else { return }
        guard Date().timeIntervalSince(lastDetectionAt) >= 3 else { return }
        guard clipSeconds >= 3 else { return }
        guard elapsed >= nextDetectionAt || !confirmed else { return }

        detecting = true
        lastDetectionAt = Date()
        let clip = self.clip
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let ranked = await LanguageDetector.rank(clip, candidates: pool)
            self.detecting = false
            guard self.state == .recording else { return }
            let summary = ranked.map { String(format: "%@ s=%.2f c=%.2f n=%d", $0.lang.locale, $0.score, $0.confidence, $0.chars) }
            debugLog("record: detect (\(String(format: "%.2f", Date().timeIntervalSince(started)))s): \(summary.joined(separator: " | "))")
            self.applyDetection(ranked)
        }
    }

    private func applyDetection(_ ranked: [LanguageDetector.Candidate]) {
        guard let best = ranked.first else { return }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        // The clip has to hold real speech: a couple of characters are noise, and a language
        // decided on noise is a language decided wrongly.
        guard best.chars >= 6, best.confidence >= 0.6, best.score - runnerUp >= 0.15 else {
            debugLog("record: detect: ambiguous, keeping \(modelLang?.locale ?? "-")")
            return
        }
        confirmed = true
        nextDetectionAt = elapsed + 20
        if best.lang == modelLang {
            debugLog("record: detect: \(best.lang.locale) confirmed")
            return
        }
        // A change of language in the middle of a recording is worth a model swap, but only when
        // the new language is clearly ahead of the one in use: swapping models mid-sentence
        // loses the words in flight.
        let current = ranked.first(where: { $0.lang == modelLang })?.score ?? 0
        guard best.score - current >= 0.35 else {
            debugLog("record: detect: \(best.lang.locale) not clearly ahead of \(modelLang?.locale ?? "-"), keeping it")
            return
        }
        Task { await switchModel(to: best.lang) }
    }

    // MARK: The microphone

    private func startMic() {
        let inputNode = mic.inputNode
        AudioDevices.pinInput(mic, to: inputDevice)
        let inFormat = inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            problem = L("没有可用的麦克风")
            state = .idle
            onState?(.idle)
            return
        }
        inputNode.removeTap(onBus: 0)
        let conv = converter
        let queue = self.queue
        let format = analyzerFormat
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            queue.async {
                guard let self, self.state == .recording, let format else { return }
                guard let c = conv.convert(buf, to: format) else { return }
                self.record(c)
                self.keep(c)
                // The analyzer is fed from here, so this is where its clock moves.
                self.keepVoice(c)
                self.fed += Double(c.frameLength) / c.format.sampleRate
                self.input?.yield(AnalyzerInput(buffer: c))
            }
        }
        do {
            try mic.start()
        } catch {
            debugLog("record: mic start failed: \(error)")
            problem = L("麦克风无法启动，请在系统设置里允许\(appDisplayName)使用麦克风")
            state = .idle
            onState?(.idle)
        }
    }

    private func stopMic() {
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        // The engine is used again for the next recording; without a reset it keeps the old
        // graph, and the second recording hears nothing at all.
        mic.reset()
    }

    // MARK: The audio file

    /// The recording is written as ADTS while it runs, so a crash leaves a readable file; it is
    /// rewrapped into .m4a when the recording stops (AudioFileWriter.finish).
    private func record(_ buffer: AVAudioPCMBuffer) {
        guard keepsAudio, let url = audioURL else { return }
        if recorder == nil {
            recorder = AudioFileWriter.open(AudioFileWriter.partial(url), format: buffer.format)
            recordingFormat = buffer.format
            guard recorder != nil else { return }
        }
        guard let recorder, let format = recordingFormat,
              buffer.format.channelCount == format.channelCount,
              buffer.format.sampleRate == format.sampleRate else { return }
        try? recorder.write(from: buffer)
    }

    private func closeRecorder() {
        recorder = nil
        guard let url = audioURL else { return }
        Task { await AudioFileWriter.finish(url) }
    }

    /// Keeps the last few seconds and the level, for the meter and the language detector.
    private func keep(_ buffer: AVAudioPCMBuffer) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        clip.append(buffer)
        clipSeconds += seconds
        while clipSeconds > clipLimit, !clip.isEmpty {
            let first = clip.removeFirst()
            clipSeconds -= Double(first.frameLength) / first.format.sampleRate
        }
        // The scale is a curve, not a multiply: a multiply either sends ordinary speech to the
        // top of the range or leaves it too small to see, and the scope then says nothing about
        // how loud the room is. The curve lifts the quiet speech into view and keeps the loud
        // moments from flattening into one.
        levelPeak = max(levelPeak, Self.meter(rms(of: buffer)))
    }

    /// Turns the loudness of a buffer into a level for the scope, 0…1.
    ///
    /// The reference is the loudness of speech at a normal distance from the microphone: a tenth
    /// of the full scale. Around it the curve is steep enough to show the difference between
    /// words, and it flattens near the top so a shout does not become a bar as tall as the box.
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let dB = 20 * log10(rms)
        // -68 dB is silence, -18 dB is loud speech; anything above stays at the top. The
        // range is wide enough that a soft voice still moves the scope, and the top is
        // high enough that ordinary speech does not sit against the ceiling.
        let t = (dB + 68) / 50
        return min(1, max(0, t))
    }

    /// How loud a buffer is, whatever shape it is in: the analyzer's format is Int16, so the
    /// samples are not always there as floats.
    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let floats = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n { sum += floats[i] * floats[i] }
            return sqrt(sum / Float(n))
        }
        if let ints = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<n { let v = Float(ints[i]) / 32768; sum += v * v }
            return sqrt(sum / Float(n))
        }
        return 0
    }

    /// Keeps the audio of the last minute, so a settled sentence can be given a voiceprint.
    ///
    /// The samples are placed on the analyzer's clock, the one a result's time range is on: the
    /// tap is what feeds the analyzer, so the two are the same sound at the same time.
    private func keepVoice(_ buffer: AVAudioPCMBuffer) {
        guard let b = voiceConverter.convert(buffer, to: voiceFormat), let d = b.floatChannelData else { return }
        if voiceAudio.isEmpty { voiceStart = fed }
        voiceAudio.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
        let over = voiceAudio.count - Int(voiceLimit * 16000)
        if over > 16000 {
            voiceAudio.removeFirst(over)
            voiceStart += Double(over) / 16000
        }
    }

    /// 16 kHz mono audio between two analyzer-clock times, or nil when it is no longer kept.
    private func voiceSamples(from start: Double, to end: Double) -> [Float]? {
        let a = Int(((start - voiceStart) * 16000).rounded()), b = Int(((end - voiceStart) * 16000).rounded())
        guard a >= 0, b > a, b <= voiceAudio.count + 1600 else { return nil }
        return Array(voiceAudio[a..<min(b, voiceAudio.count, a + Int(Voiceprints.maxSeconds * 16000))])
    }

    // MARK: The clock and the meter

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        playbackTick()
        switch state {
        case .recording:
            elapsed = clock.elapsed()
            level = levelPeak
            levelPeak = 0
            waveform.append(level)
            if waveform.count > Self.scopeSamples { waveform.removeFirst(waveform.count - Self.scopeSamples) }
            maybeDetectLanguage()
        case .paused:
            // Mic is still on: keep the meter alive, but freeze the clock and detection.
            level = levelPeak
            levelPeak = 0
            waveform.append(level)
            if waveform.count > Self.scopeSamples { waveform.removeFirst(waveform.count - Self.scopeSamples) }
        default:
            return
        }
    }

    /// How many samples the scope keeps: ten ticks a second, so forty is four seconds.
    static let scopeSamples = 40

    // MARK: The results

    private func handle(_ result: SpeechTranscriber.Result, generation gen: Int) {
        // A final result is kept even if the model has changed since: it is a sentence that was
        // said, and throwing it away would lose the words that were in flight. Only the
        // half-sentence of a model that is gone is dropped.
        if gen != generation {
            guard result.isFinal else { return }
        }
        guard state == .recording else { return }
        lastText = result.text
        lastRuns = "\(result.isFinal ? "final" : "volatile") " + Self.describe(result.text)
        let words = Self.words(of: result.text)
        var text = HeardText.clean(String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
        if result.isFinal {
            // A breath or a click is not a sentence: it would sit in the record as a line.
            guard text.contains(where: \.isLetter) else { live = ""; liveWords = []; return }
            live = ""
            liveWords = []
            add(text, at: CMTimeGetSeconds(result.range.start), until: CMTimeGetSeconds(result.range.end),
                words: words)
        } else {
            live = text
            liveWords = words
        }
    }

    /// The last result the model gave, kept for the debug commands.
    private var lastText = AttributedString()
    /// How the last result looked, written down when it arrived.
    private var lastRuns = ""

    /// Shows what the model gave: the runs of the last result and the time of each.
    func debugRuns() {
        debugLog("record: runs \(lastRuns)")
    }

    /// What the model gave: the runs of a result and the time of each, for the debug commands.
    nonisolated static func describe(_ text: AttributedString) -> String {
        typealias Scope = AttributeScopes.SpeechAttributes
        var out: [String] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run[Scope.TimeRangeAttribute.self]
            let sure = run[Scope.ConfidenceAttribute.self]
            out.append("[\(piece)|\(range.map { "\(CMTimeGetSeconds($0.start))-\(CMTimeGetSeconds($0.end))" } ?? "nil")|\(sure.map { String(format: "%.2f", $0) } ?? "nil")]")
        }
        return out.joined(separator: " ")
    }

    /// The words of a result, each with the moment it was said.
    ///
    /// While a sentence is still being spoken the model gives it as one run with the span it
    /// covers, so the words in it are spread over that span: the text appears letter by letter
    /// as it is said, and each letter has the moment it was said. When the sentence is finished
    /// the model gives every word its own time, and those exact times are used instead.
    nonisolated static func words(of text: AttributedString) -> [LiveWord] {
        typealias Scope = AttributeScopes.SpeechAttributes
        var out: [LiveWord] = []
        for run in text.runs {
            let range = run[Scope.TimeRangeAttribute.self]
            let sure = run[Scope.ConfidenceAttribute.self]
            let pieces = Self.pieces(of: String(text[run.range].characters))
            guard !pieces.isEmpty else { continue }
            guard let range else {
                // No time at all: the words take the time of the word before them.
                for piece in pieces {
                    out.append(LiveWord(id: out.count, text: piece, t: out.last?.t ?? 0, confidence: sure))
                }
                continue
            }
            // The run covers the whole phrase; each word is given its share of it.
            let start = CMTimeGetSeconds(range.start)
            let span = max(0, CMTimeGetSeconds(range.end) - start)
            let step = span / Double(pieces.count)
            for (i, piece) in pieces.enumerated() {
                out.append(LiveWord(id: out.count, text: piece, t: start + step * Double(i), confidence: sure))
            }
        }
        return out
    }

    /// The words of a piece of text: spaces separate words in English, characters are the words
    /// in Chinese.
    nonisolated static func pieces(of text: String) -> [String] {
        let hasSpaces = text.contains(" ")
        return text.split(separator: " ", omittingEmptySubsequences: true).flatMap { piece -> [String] in
            guard !hasSpaces else { return [String(piece)] }
            // Without spaces the piece is one word; each character of it is shown on its own.
            return piece.map { String($0) }
        }
    }

    /// A settled sentence: it goes into the transcript, and into the running summary.
    private func add(_ text: String, at start: Double, until end: Double, words: [LiveWord] = []) {
        let code = modelLang?.code ?? "zh-CN"
        // The transcript shows when the sentence was started; the recorder's own clock is the
        // authority, but the model counts from the first buffer it was given.
        let t = start.isFinite && start >= 0 ? start : elapsed
        let until = end.isFinite && end > t ? end : nil
        var line = RecordLine(id: "r\(nextLineID)", t: t, text: text, translation: nil, lang: code,
                              voice: nil, person: nil, end: until, words: words)
        nextLineID += 1
        lines.append(line)
        heard.append(code)
        onLine?(line)
        debugLog("record: line \(line.id) t=\(Int(line.t)) \(text.prefix(40))")
        translate(line)
        tag(line, from: start, to: end)
    }

    // MARK: The voices

    /// Who said this sentence: the audio of the sentence becomes a voiceprint, and the
    /// voiceprint is matched against the ones heard so far.
    ///
    /// The voice comes back later, so the line is updated when it does. A sentence too short to
    /// have a voiceprint, or one whose voice is not like any heard so far, keeps no voice.
    private func tag(_ line: RecordLine, from start: Double, to end: Double) {
        guard let tagger else { return }
        // A word or two is not enough to tell voices apart; the model needs half a second.
        guard line.text.filter(\.isLetter).count >= 2 else { return }
        guard start.isFinite, end.isFinite, end > start else { return }
        guard let samples = voiceSamples(from: start, to: end) else {
            debugLog("record: voice: no audio for \(line.id)")
            return
        }
        debugLog("record: voice: \(line.id) \(Double(samples.count) / 16000)s")
        tagger.tag(lineID: line.id, samples: samples)
    }

    /// The voice of a line, once the voiceprint has been matched.
    ///
    /// True when the line is one of the recorder's: the caller then leaves it alone, so the
    /// recording and the meeting record are written to once.
    @discardableResult
    func setVoice(_ voice: Int?, lineID: String) -> Bool {
        guard let i = lines.firstIndex(where: { $0.id == lineID }) else { return false }
        guard lines[i].voice != voice else { return true }
        lines[i].voice = voice
        // The first voice heard is 人物 1, the next 人物 2; the numbers never move.
        if let voice { lines[i].person = persons.number(for: voice) }
        debugLog("record: voice: \(lineID) → \(voice.map(String.init) ?? "none")")
        onVoice?(lineID, voice)
        return true
    }

    // MARK: The playback

    /// Where the audio is being played from, in seconds; nil when nothing is playing.
    @Published private(set) var playing: Double?
    /// True while the audio is playing.
    @Published private(set) var isPlaying = false

    /// The player for the recording's own audio file.
    private var player: AVAudioPlayer?
    /// Stands between the player and the engine; the player wants a delegate that is an
    /// NSObject, and the engine is not one.
    private let playbackDelegate = PlaybackDelegate()

    /// Plays the recording from a moment in it, so a sentence can be heard again.
    ///
    /// The audio is the one that was kept next to the transcript; if it was not kept, there is
    /// nothing to play and the sentence is simply left as it is.
    func play(from t: Double) {
        guard let url = audioURL, FileManager.default.fileExists(atPath: url.path) else {
            debugLog("record: play: no audio")
            return
        }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                playbackDelegate.onFinish = { [weak self] in
                    Task { @MainActor in
                        self?.isPlaying = false
                        self?.playing = nil
                    }
                }
                player?.delegate = playbackDelegate
            }
            guard let player else { return }
            player.currentTime = max(0, min(t, player.duration - 0.05))
            player.play()
            playing = player.currentTime
            isPlaying = true
            debugLog("record: play from \(Int(t))s")
        } catch {
            debugLog("record: play failed: \(error)")
        }
    }

    /// Stops the playback.
    func stopPlayback() {
        player?.pause()
        isPlaying = false
        playing = nil
    }

    /// How far the playback has come, for the line that is being heard.
    private func playbackTick() {
        guard let player, player.isPlaying else {
            if isPlaying {
                isPlaying = false
                playing = nil
            }
            return
        }
        playing = player.currentTime
    }

    // MARK: The editing

    /// Changes the words of a sentence: what was heard can be corrected.
    func edit(_ id: String, text: String, correct: Bool = false) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if correct {
            if lines[i].corrected == trimmed { return }
            lines[i].corrected = trimmed
            debugLog("record: edit corrected \(id)")
            onAutoCorrect?()
        } else if lines[i].corrected != nil && lines[i].corrected != lines[i].text {
            guard trimmed != lines[i].corrected else { return }
            lines[i].corrected = trimmed
            debugLog("record: edit corrected \(id)")
            onAutoCorrect?()
        } else {
            guard trimmed != lines[i].text else { return }
            lines[i].text = trimmed
            // Manual edit invalidates AI correction
            lines[i].corrected = nil
            correctedIDs.remove(id)
            debugLog("record: edit \(id)")
            onEdit?(id)
        }
    }

    /// Joins two sentences into one, the way a recording that was cut in half is put back
    /// together.
    func merge(_ id: String, with nextID: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }),
              let j = lines.firstIndex(where: { $0.id == nextID }), j > i else { return }
        // The two sentences are one now; the voice of the first one is kept, because it is the
        // one that started.
        lines[i].text = lines[i].text + " " + lines[j].text
        if let t = lines[j].translation, !t.isEmpty {
            lines[i].translation = [lines[i].translation, t].compactMap { $0 }.joined(separator: " ")
        }
        lines[i].end = lines[j].end ?? lines[i].end
        lines.remove(at: j)
        debugLog("record: merge \(id) + \(nextID)")
        onRewrite?()
    }

    /// Cuts a sentence in two at a place in its text.
    ///
    /// The second half keeps the time of the word it starts at, so the transcript still shows
    /// when it was said.
    func split(_ id: String, at offset: Int) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        let text = lines[i].text
        let chars = Array(text)
        guard offset > 0, offset < chars.count else { return }
        let head = String(chars[..<offset]).trimmingCharacters(in: .whitespaces)
        let tail = String(chars[offset...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return }
        // The second sentence starts where the cut is, so the two are still in order.
        let gap = Double(offset) / Double(max(chars.count, 1))
        let span = (lines[i].end ?? lines[i].t + 1) - lines[i].t
        var second = RecordLine(id: "r\(nextLineID)", t: lines[i].t + span * gap, text: tail,
                                 translation: nil, lang: lines[i].lang, voice: lines[i].voice,
                                 person: lines[i].person, end: lines[i].end)
        nextLineID += 1
        lines[i].text = head
        lines[i].end = second.t
        lines[i].translation = nil
        lines.insert(second, at: i + 1)
        debugLog("record: split \(id) at \(offset)")
        onRewrite?()
    }

    // MARK: The translation

    /// Each settled sentence is translated on its own; the partial one never is, because a
    /// half-sentence makes a half-translation.
    private func translate(_ line: RecordLine) {
        guard target != "none", !target.isEmpty, let ai, ai.usable else { return }
        let id = line.id
        Task { [weak self] in
            guard let self else { return }
            let service = TranslationService(ai: ai)
            let out = await service.translate(line.text, source: line.lang, target: self.target, kind: .sentence)
            guard let out, !out.isEmpty else { return }
            await MainActor.run {
                guard let i = self.lines.firstIndex(where: { $0.id == id }) else { return }
                self.lines[i].translation = out
                self.onTranslation?(id, out)
            }
        }
    }

    /// "02:26", the way a recording's clock reads.
    nonisolated static func clock(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Auto-correction

    /// 纠错任务标记，避免并发重复跑。Published so the surfaces can say the polishing is running.
    @Published private(set) var correcting = false
    /// 已提交纠错的行 id 集合（避免重复）。
    private var correctedIDs: Set<String> = []

    /// 在录音结束后后台自动纠错：按静默/说话人/时长切段，逐段发 AI，只改错字/标点。
    /// `glossary` 取自 NotesEngine 的术语表，提升专名准确率。
    func runAutoCorrect(glossary: [String] = []) {
        guard !correcting, let ai, ai.usable else { return }
        let candidates = lines.filter { $0.corrected == nil && !correctedIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }
        correcting = true
        onCorrecting?(true)
        debugLog("record: autocorrect start \(candidates.count) lines")
        Task { [weak self] in
            guard let self else { return }
            for seg in Self.segment(candidates) {
                await self.correctSegment(seg, glossary: glossary, ai: ai)
            }
            await MainActor.run {
                self.correcting = false
                self.onCorrecting?(false)
                self.onAutoCorrect?()
                debugLog("record: autocorrect done")
            }
        }
    }

    /// 按静默间隔、说话人变化、时长上限切段。
    private static func segment(_ lines: [RecordLine]) -> [[RecordLine]] {
        guard !lines.isEmpty else { return [] }
        var segments: [[RecordLine]] = []
        var current: [RecordLine] = []
        var segStart = lines[0].t
        for line in lines {
            let prev = current.last
            let gap = prev.map { line.t - ($0.end ?? $0.t) } ?? 0
            let speakerChange = prev.map { $0.person != nil && line.person != nil && $0.person != line.person } ?? false
            let tooLong = line.t - segStart > 60
            if !current.isEmpty && (gap > 3.0 || speakerChange || tooLong) {
                segments.append(current)
                current = []
                segStart = line.t
            }
            current.append(line)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private func correctSegment(_ seg: [RecordLine], glossary: [String], ai: AIClient) async {
        let items = seg.map {
            Corrector.Item(id: $0.id, t: $0.t, speaker: $0.person.map { "人物\($0)" } ?? "说话人", text: $0.text)
        }
        let ends = Dictionary(uniqueKeysWithValues: seg.map { ($0.id, $0.end ?? $0.t) })
        let fixed = await Corrector.correct(items: items, endTimes: ends, glossary: glossary, ai: ai)
        await MainActor.run { [weak self] in
            guard let self else { return }
            var changed = 0
            for (id, text) in fixed {
                self.correctedIDs.insert(id)
                guard let idx = self.lines.firstIndex(where: { $0.id == id }) else { continue }
                self.lines[idx].corrected = text
                changed += 1
            }
            if changed > 0 {
                debugLog("record: autocorrect applied \(changed)/\(seg.count) in segment")
                self.onAutoCorrect?()
            }
        }
    }

    /// Clears correction for a line (undo).
    func clearCorrection(_ lineID: String) {
        guard let idx = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[idx].corrected = nil
        correctedIDs.remove(lineID)
        onAutoCorrect?()
    }

    /// Re-run correction for a specific line's segment (finds its segment and corrects that batch).
    func recorrect(lineID: String, glossary: [String] = []) {
        guard let ai, ai.usable else { return }
        guard let target = lines.first(where: { $0.id == lineID }) else { return }
        // Find segment containing this line using same segmentation logic
        let all = lines
        let segments = Self.segment(all)
        guard let seg = segments.first(where: { $0.contains(where: { $0.id == lineID }) }) else { return }
        // Clear existing corrections in segment so they can be re-applied
        for l in seg {
            if let idx = lines.firstIndex(where: { $0.id == l.id }) {
                lines[idx].corrected = nil
                correctedIDs.remove(l.id)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.correctSegment(seg, glossary: glossary, ai: ai)
            await MainActor.run { self.onAutoCorrect?() }
        }
        _ = target
    }

    /// Fills the recorder with sample lines and a summary, so the surface can be looked at
    /// without a microphone (debug).
    func demo() {        // The voices are given too, so the people can be seen on the surface without a microphone.
        let sample: [(Double, String, String?, Int, Int)] = [
            (15, "你觉得你自己的欲望是什么？", "What do you think your own desire is?", 0, 1),
            (21, "这是个好问题。", "That's a good question.", 1, 2),
            (41, "你享受战斗吗？我享受那种拼尽全力的厮杀。", "Do you enjoy a fight? I enjoy battling with everything I have.", 0, 1),
            (63, "我觉得以前我不是一个特别有血性的人，还是那句话，就是你可能拥有的比较多，没有需要去拼搏、厮杀去获取。", "I don't think I used to be a very driven person. Put simply, you may already have more than you need, with no need to fight or strive to get it.", 1, 2),
            (92, "但我觉得我是有。", "But I think I do have it.", 0, 1),
        ]
        lines = sample.enumerated().map { i, s in
            RecordLine(id: "d\(i)", t: s.0, text: s.1, translation: s.2, lang: "zh-CN",
                       voice: s.3, person: s.4, end: s.0 + 4)
        }
        live = "所以我觉得"
        liveWords = "所以我觉得".enumerated().map { i, c in
            LiveWord(id: i, text: String(c), t: 146 + Double(i) * 0.2, confidence: nil)
        }
        elapsed = 146
        lang = sourceLanguages.first { $0.code == "zh-CN" }
        debugLog("record: demo filled \(lines.count) lines")
    }

    /// Fills the recorder with a talk about why something happened, so the fishbone the summary
    /// draws for such a topic can be checked without a microphone (debug).
    func demoCauses() {
        let sample: [(Double, String, String?, Int, Int)] = [
            (10, "我们这个项目为什么最后没做成？", "Why did our project not get done in the end?", 0, 1),
            (24, "第一个原因是需求一直不清楚，从立项到改了三版，谁都没拍板。", "The first reason is the requirements were never clear; from kickoff to three rewrites, nobody made the final call.", 1, 2),
            (48, "第二个原因是关键的人力一直没到位，两个后端拖了两个月才招到。", "The second reason is the key people were never in place; two backend engineers took two months to hire.", 0, 1),
            (76, "第三个原因是依赖的上游接口一直没有测试环境，我们本地跑不通。", "The third reason is the upstream interface we depend on never had a test environment, so we could not run it locally.", 1, 2),
            (104, "所以复盘下来，这三件事其实是同一个问题：没有人对结果负责。", "So looking back, these three things are really one problem: nobody was accountable for the outcome.", 0, 1),
        ]
        lines = sample.enumerated().map { i, s in
            RecordLine(id: "c\(i)", t: s.0, text: s.1, translation: s.2, lang: "zh-CN",
                       voice: s.3, person: s.4, end: s.0 + 5)
        }
        elapsed = 130
        lang = sourceLanguages.first { $0.code == "zh-CN" }
        debugLog("record: demo causes filled \(lines.count) lines")
    }
}

// MARK: - The playback

/// Tells the engine when the audio ran out.
///
/// The player wants a delegate, and a delegate wants an NSObject; the engine is not one, so
/// this stands in for it.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
