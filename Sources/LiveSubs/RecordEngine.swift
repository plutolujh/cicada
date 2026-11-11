import AVFoundation
import Foundation
import Speech

// MARK: - A recording

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
}

/// A piece of the running summary: a heading and what was said under it.
struct RecordTopic: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var detail: String
    /// The lines this topic covers, so the summary can be rebuilt from them.
    var points: [String]
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
        case stopping
    }

    // MARK: Outputs

    /// The sentence being heard right now; it changes as the speaker continues.
    @Published private(set) var live = ""
    /// The sentences that are settled.
    @Published private(set) var lines: [RecordLine] = []
    /// The summary, rebuilt as the recording goes on.
    @Published private(set) var topics: [RecordTopic] = []
    /// The language heard in the last sentence.
    @Published private(set) var lang: Lang?
    /// How long the recording has run.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var state: State = .idle
    /// The level of the microphone right now, 0…1, for the meter.
    @Published private(set) var level: Float = 0
    /// Why the recording stopped early, when it did.
    @Published private(set) var problem: String?
    /// True while the summary is being rebuilt, so the panel can show it is working.
    @Published private(set) var summarizing = false

    /// The translation target; "none" leaves the sentences untranslated.
    var target = "none"
    /// Keep the audio next to the transcript.
    var keepsAudio = true
    /// Detect the language instead of using one fixed model.
    var detectsLanguage = true

    // MARK: Wiring

    /// The service that translates and summarizes.
    var ai: AIClient?
    /// Called for every settled sentence, so it can be put into the meeting record.
    var onLine: ((RecordLine) -> Void)?
    /// Called when a sentence's translation arrives, so the record can be updated too.
    var onTranslation: ((String, String) -> Void)?
    /// Called when a sentence's voice is known, so the record can be updated too.
    var onVoice: ((String, Int?) -> Void)?
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
    private var lastSummaryAt = Date.distantPast
    private var lastSummaryLineCount = 0
    private var summaryTask: Task<Void, Never>?

    // MARK: Start / stop

    func start() {
        guard state == .idle else { return }
        state = .preparing
        problem = nil
        live = ""
        lines = []
        topics = []
        elapsed = 0
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
        lastSummaryAt = .distantPast
        lastSummaryLineCount = 0
        lastDetectionAt = .distantPast
        detecting = false
        nextDetectionAt = 20.0
        confirmed = false

        // The detector needs at least two models to choose from; with fewer it would always
        // guess the same one, so the first language is used until more are installed.
        let pool = candidates.filter { installed.contains($0.locale) }
        let first = pool.first ?? candidates.first ?? sourceLanguages[0]
        Task {
            await prepare(first)
            guard state == .preparing else { return }
            startMic()
            guard state == .preparing else { return }
            startTick()
            state = .recording
            debugLog("record: started lang=\(first.locale)")
        }
    }

    func stop() {
        guard state == .recording || state == .preparing else { return }
        state = .stopping
        generation += 1
        tickTimer?.invalidate()
        tickTimer = nil
        summaryTask?.cancel()
        summaryTask = nil
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
        closeRecorder()
        state = .idle
        debugLog("record: stopped lines=\(lines.count)")
    }

    // MARK: The model

    /// A transcriber for one language, its analyzer and the format it wants.
    private func prepare(_ lang: Lang) async {
        guard SpeechTranscriber.isAvailable else {
            state = .idle
            problem = L("此 Mac 不支持本机语音识别")
            return
        }
        let t = SpeechTranscriber(locale: Locale(identifier: lang.locale), transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
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
        }
    }

    private func stopMic() {
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
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
        if let data = buffer.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            levelPeak = max(levelPeak, min(1, rms * 12))
        }
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
        guard state == .recording else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        level = levelPeak
        levelPeak = 0
        maybeDetectLanguage()
        maybeSummarize()
    }

    // MARK: The results

    private func handle(_ result: SpeechTranscriber.Result, generation gen: Int) {
        // A final result is kept even if the model has changed since: it is a sentence that was
        // said, and throwing it away would lose the words that were in flight. Only the
        // half-sentence of a model that is gone is dropped.
        if gen != generation {
            guard result.isFinal else { return }
        }
        guard state == .recording else { return }
        var text = HeardText.clean(String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
        if result.isFinal {
            // A breath or a click is not a sentence: it would sit in the record as a line.
            guard text.contains(where: \.isLetter) else { live = ""; return }
            live = ""
            add(text, at: CMTimeGetSeconds(result.range.start), until: CMTimeGetSeconds(result.range.end))
        } else {
            live = text
        }
    }

    /// A settled sentence: it goes into the transcript, and into the running summary.
    private func add(_ text: String, at start: Double, until end: Double) {
        let code = modelLang?.code ?? "zh-CN"
        // The transcript shows when the sentence was started; the recorder's own clock is the
        // authority, but the model counts from the first buffer it was given.
        let t = start.isFinite && start >= 0 ? start : elapsed
        var line = RecordLine(id: "r\(nextLineID)", t: t, text: text, translation: nil, lang: code, voice: nil, person: nil)
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

    // MARK: The summary

    /// The running summary: the same service the notes use, asked for a short list of topics.
    /// It is rebuilt from everything said so far, so it never contradicts itself.
    ///
    /// It is not asked more often than it can answer: a summary that takes ten seconds is worth
    /// less than one that keeps up.
    private func maybeSummarize() {
        // The tick runs ten times a second, so the count is checked first: nothing is logged
        // until there is something new to say.
        guard lines.count != lastSummaryLineCount else { return }
        guard let ai, ai.usable else {
            debugLog("record: summary skipped ai=\(self.ai != nil) usable=\(self.ai?.usable.description ?? "-") lines=\(lines.count)")
            return
        }
        guard !lines.isEmpty else { return }
        let since = Date().timeIntervalSince(lastSummaryAt)
        guard lastSummaryAt == .distantPast ? lines.count >= 3 : (since >= 45 && lines.count - lastSummaryLineCount >= 3) else { return }
        // The count is claimed here, not in the task: the tick would otherwise ask again on the
        // next frame and cancel the request that is still on its way.
        lastSummaryLineCount = lines.count
        lastSummaryAt = Date()
        debugLog("record: summary asking (\(lines.count) lines)")
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            await self?.refreshSummary()
        }
    }

    /// Rebuilds the summary from everything said so far.
    func refreshSummary(force: Bool = false) async {
        guard let ai, ai.usable, !lines.isEmpty else {
            debugLog("record: summary refresh skipped ai=\(self.ai != nil) usable=\(self.ai?.usable.description ?? "-") lines=\(lines.count)")
            return
        }
        if force { summaryTask?.cancel() }
        summarizing = true
        defer { summarizing = false }
        // The count and the time are claimed when the request is made; a forced refresh claims
        // them here, because it was not asked for by the tick.
        if force {
            lastSummaryAt = Date()
            lastSummaryLineCount = lines.count
        }

        // The person who said each line is named when the voice is known, so the summary can
        // say who said what.
        let transcript = lines.map { l in
            let who = l.person.map { "人物 \($0): " } ?? ""
            return "[\(Self.clock(l.t))] \(who)\(l.text)"
        }.joined(separator: "\n")
        let language = TranslationService.englishName(heard.first ?? "zh-CN")
        let prompt = """
        You summarize a recording that is still running.
        Write the summary in \(language).
        The transcript names the speakers as 人物 1, 人物 2…; say who said what when it matters.
        Output JSON only: {"topics":[{"title":"...","detail":"...","points":["..."]}]}
        Use at most 6 topics. Each title is a short heading (a few words). Each detail is one or two
        sentences about what was said under it. Each point is one short line of what was actually
        said. Do not invent anything that was not said.
        """
        let content = prompt + "\n\nTranscript so far:\n" + transcript
        do {
            let raw = try await ai.chat(content: content, instruction: "Update the summary. Output JSON only.",
                                        priority: .notes, json: true, maxTokens: 2000, timeout: 45)
            guard let next = Self.parse(raw) else {
                debugLog("record: summary unparsed (\(raw.count) chars)")
                return
            }
            topics = next
            debugLog("record: summary \(next.count) topics")
        } catch {
            debugLog("record: summary failed \(error)")
        }
    }

    /// The topics out of the model's JSON.
    nonisolated static func parse(_ raw: String) -> [RecordTopic]? {
        var text = raw
        // The model may answer with prose around the JSON, so the braces are picked out. The
        // closing brace has to come after the opening one, or there is no JSON to read; the
        // offsets are used rather than the indices, because indices from two separate searches
        // do not always describe one range.
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), close > open {
            let end = text.index(after: close)
            text = String(text[open..<end])
        }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["topics"] as? [[String: Any]] else { return nil }
        let out = arr.compactMap { item -> RecordTopic? in
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let detail = (item["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let points = (item["points"] as? [String])?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
            return RecordTopic(title: title, detail: detail, points: points)
        }
        return out.isEmpty ? nil : out
    }

    /// "02:26", the way a recording's clock reads.
    nonisolated static func clock(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Fills the recorder with sample lines and a summary, so the surface can be looked at
    /// without a microphone (debug).
    func demo() {
        // The voices are given too, so the people can be seen on the surface without a microphone.
        let sample: [(Double, String, String?, Int, Int)] = [
            (15, "你觉得你自己的欲望是什么？", "What do you think your own desire is?", 0, 1),
            (21, "这是个好问题。", "That's a good question.", 1, 2),
            (41, "你享受战斗吗？我享受那种拼尽全力的厮杀。", "Do you enjoy a fight? I enjoy battling with everything I have.", 0, 1),
            (63, "我觉得以前我不是一个特别有血性的人，还是那句话，就是你可能拥有的比较多，没有需要去拼搏、厮杀去获取。", "I don't think I used to be a very driven person. Put simply, you may already have more than you need, with no need to fight or strive to get it.", 1, 2),
            (92, "但我觉得我是有。", "But I think I do have it.", 0, 1),
        ]
        lines = sample.enumerated().map { i, s in
            RecordLine(id: "d\(i)", t: s.0, text: s.1, translation: s.2, lang: "zh-CN", voice: s.3, person: s.4)
        }
        topics = [
            RecordTopic(title: "人物身份确认",
                        detail: "钱程（David）来自科沃斯机器人，现任科沃斯机器人 CEO，是 90 后、曾为中国最年轻 A 股上市公司 CEO。",
                        points: ["David 确认自己 1990 年出生于深圳，11 岁前都在深圳生活，曾在纽约度过三年时间。"]),
            RecordTopic(title: "个人状态分享",
                        detail: "个人欲望与状态分析：钱程表示自己曾因拥有较多未主动拼搏厮杀，自身拼搏欲望是被环境激发的，认为人是环境的动物。",
                        points: ["谈到战斗时表示享受拼尽全力的厮杀。"]),
            RecordTopic(title: "当前正在聊…",
                        detail: "说话人3表达对 David 成长经历的好奇，提及 David 为深圳出生长大，并非苏州出身。",
                        points: []),
        ]
        live = "所以我觉得……"
        elapsed = 146
        lang = sourceLanguages.first { $0.code == "zh-CN" }
        debugLog("record: demo filled \(lines.count) lines")
    }
}
