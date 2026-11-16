import Accelerate
import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Wires the engines, the meeting store, the subtitle bar and the UI together.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let store = SessionStore()
    let overlay = OverlayController()
    let talkCombo = HotKey(id: 1, shortcut: .defaultTalk)
    let talkRight = RightOptionKey()
    let toggleKey = HotKey(id: 2, shortcut: .defaultToggle)
    lazy var listen = ListenEngine(settings: settings)
    lazy var speak = SpeakEngine(settings: settings)
    /// The recording surface: the microphone, its transcript and the running summary.
    lazy var recorder = RecordEngine()
    lazy var speakTester = SpeakTester(speak: speak, ai: ai, settings: settings)
    /// Key released → the room heard the first sound, from the latest real press or sound test.
    @Published var lastSpeakLatency: Double? = UserDefaults.standard.object(forKey: "lastSpeakLatency") as? Double {
        didSet { UserDefaults.standard.set(lastSpeakLatency, forKey: "lastSpeakLatency") }
    }
    /// The 试一句 sheet in settings.
    @Published var speakTestShown = false
    /// The panel is asking, the first time, what turning 同声传译 on changes.
    @Published var speakAsking = false
    /// Meeting apps and the microphone each reads; refreshed every second once the virtual mic exists.
    @Published var micUsers: [MicUser] = []
    lazy var systemMic = SystemMic(settings: settings)
    /// Whether the system default input is the virtual mic, and anything left to put back.
    @Published private(set) var systemMicState: SystemMic.State = .off
    /// The app whose "怎么改" sheet is open in Settings.
    @Published var micGuide: MicUser?
    /// Settings › 同声传译: the voice list under "对方听到" is open.
    @Published var voicePickerOpen = false

    @Published var running = false
    /// The listening is on hold: the tap is still open, but nothing said while paused is
    /// written down. The toolbar pill and the capture surface both read this.
    @Published private(set) var listeningPaused = false
    /// The meeting is about to end by itself (a hang-up or a long silence) unless someone keeps it going.
    @Published private(set) var ending: MeetingEndWatch.Pending?
    /// The last meeting ended by itself: the menu says so, and the next call in a meeting app starts a new one.
    @Published private(set) var autoEnded = false
    /// The notes window is on screen: the menu bar panel's 显示 / 收起 follows it.
    @Published private(set) var notesShown = false
    private var endWatch: MeetingEndWatch?
    /// The same watch for a recording: the 通用 settings answer to both sources.
    private var recordWatch: MeetingEndWatch?
    private var endTimer: Timer?
    /// The capture surface's level and clock.
    private var captureTimer: Timer?
    /// The clock of the listening: it stands still while the listening is on hold, so the time
    /// spent on hold is not part of the meeting.
    private var listenClock: CaptureClock?
    /// Debug: meeting apps in a call instead of what Core Audio says, and shorter waits.
    private var fakeCalls: [String: String]?
    private var endTimesOverride: (silence: Double, countdown: Double, grace: Double)?
    @Published var status = L("准备就绪")
    @Published var summary = ""
    @Published var installed: Set<String> = []
    @Published var candidates: [Lang] = []
    @Published var outputs: [OutputDevice] = []
    @Published var speakPhase: SpeakEngine.Phase = .idle
    @Published var settingsSection: SettingsSection =
        SettingsSection(rawValue: UserDefaults.standard.string(forKey: "settingsSection") ?? "") ?? .speak {
        didSet {
            UserDefaults.standard.set(settingsSection.rawValue, forKey: "settingsSection")
            // People pick a voice and move on: don't greet them with the list still open next time.
            if settingsSection != oldValue { voicePickerOpen = false }
        }
    }
    @Published var systemAudioOK = false
    /// The microphone recording's state, mirrored from the engine so the toolbar pill can
    /// watch it: the engine is a `lazy var`, so `model.recorder.state` would not notify anyone.
    @Published private(set) var micState: RecordEngine.State = .idle
    @Published var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var liveSource = ""
    @Published var liveTranslation = ""
    @Published var onboardingStep = 1
    /// Step 3 is showing what skipping the key leaves out (debug: `onboarding:3,skip`).
    @Published var onboardingKeySkip = false
    /// Step 4's yes/no (false) or checklist (true); nil follows whether speaking is on
    /// (debug: `onboarding:4,ask` / `onboarding:4,setup`).
    @Published var onboardingSpeakSetup: Bool?
    /// Debug: which meeting and tab the main window shows ("<id>" or "<id>,transcript").
    @Published var mainShow: String?
    /// The meeting the export panel is for, while it is open.
    @Published var exportRequest: ExportRequest?
    /// What the file should contain, and in which format.
    @Published var exportOptions = ExportOptions()
    /// The AI view's diagram style, shared by every surface that shows it: the notes window,
    /// the meeting record and the export. One pick, one look.
    @Published var aiViewStyle: MindMapStyle = .auto
    /// Hold right ⌥ is chosen but "输入监控" isn't allowed yet.
    @Published var talkNeedsPermission = false
    @Published var toggleKeyTaken = false
    private var permissionPoll: Timer?
    private var shortcutsSuspended = false
    let installer = VirtualMicInstaller()
    let ai = AIClient()
    lazy var translator = TranslationService(ai: ai)
    let diagnostics = Diagnostics()
    let updates = Updates()
    let loginItem = LoginItem()
    lazy var notes = NotesEngine(ai: ai, store: store)
    lazy var notesWindow = NotesWindowController(model: self)
    lazy var floatingPill = FloatingPillWindowController(model: self)
    /// True while the floating pill is on screen. The main window's toolbar pill steps aside
    /// then, so there is one pill on screen and not two copies of the same state.
    @Published private(set) var floatingPillVisible = false
    /// Where the toolbar pill's buttons are, in the pill's own coordinates. The pill reports
    /// them as it is drawn; a test can then aim a click at the body between them.
    var toolbarPillRegions: [CGRect] = []
    /// Where the toolbar pill's body is, in the pill's own coordinates. The body is the stretch
    /// between the buttons, and a double click there opens the main window.
    var toolbarPillBody: CGRect = .null

    /// The floating pill says it is up or down; the toolbar pill watches.
    func setFloatingPillVisible(_ on: Bool) {
        floatingPillVisible = on
    }
    /// The live words of whichever source is running, in the one shape both are read through.
    let capture = CaptureFeed()
    let sample = SamplePlayer()
    let speakers = SpeakerTagger()
    lazy var speakerNamer = SpeakerNamer(ai: ai, store: store)
    /// Set by the notes window; the records window's people row opens that voice's editor.
    @Published var speakerEdit: SpeakerEditRequest?
    private var speakerSetting: AnyCancellable?
    var openOnboarding: (() -> Void)?

    /// Opens the records window, never minimising it: everything that names a meeting means
    /// "show me that one".
    var openMainWindow: (() -> Void)?
    /// Opens the export panel.
    var showExportPanel: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var showPanel: (() -> Void)?
    /// Opens the menu bar panel, leaving it open if it already is: the main window's button
    /// means "show me the listener", not "flip the listener".
    var openPanel: (() -> Void)?
    /// Toggles the main window: opens it if closed/minimized, minimizes it if frontmost.
    var toggleMainWindow: (() -> Void)?
    /// Shows the app's own menu (纪要 / 显示 / 窗口 …) next to a point in the window, so the
    /// commands are one click away without going to the menu bar.
    var showMenu: ((_ anchor: NSRect) -> Void)?

    private var lineForSegment: [Int: String] = [:]
    private var lineCounter = 0
    /// The other side's last recorded line, which the next one may carry on (`HeardText.continues`).
    private var lastHeard: (seg: Segment, line: String)?
    /// A line that may carry on `lastHeard`, waiting to hear whose voice it is; its translation if
    /// that comes first.
    private var heldJoin: (seg: Segment, t: Double, translation: String?)?

    init() {
        let defaults = UserDefaults.standard
        recordTarget = defaults.string(forKey: "recordTarget") ?? "none"
        recordAutoLang = defaults.object(forKey: "recordAutoLang") as? Bool ?? true
        recordHeardLang = defaults.string(forKey: "recordHeardLang") ?? "auto"
        recordKeepsAudio = defaults.object(forKey: "recordKeepsAudio") as? Bool ?? true
        listen.onSubtitle = { [weak self] src, dst in
            self?.liveSource = src
            self?.liveTranslation = dst
            // The system audio path reports the words being heard through the subtitle callback;
            // the transcript column reads them from here, like the microphone path does.
            self?.capture.setLive(src, words: [])
            // Only a confirmed sentence counts as words: a volatile guess can change, and a
            // noise that looks like speech would keep the quiet timer alive for good.
            if !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.heardSpeech() }
            guard let self, self.settings.displayMode == "bar" else { return }
            self.overlay.clearStatus()
            let shown = self.displayed(src, dst)
            self.overlay.setSubtitle(source: shown.source, translation: shown.translation)
        }
        listen.onStatus = { [weak self] text in
            self?.status = text
            self?.overlay.setStatus(text)
        }
        listen.onStateChange = { [weak self] in self?.refresh() }
        listen.onFinal = { [weak self] seg, duration in
            self?.heardWords()
            self?.recordHeard(seg, duration: duration)
        }
        speakers.onVoice = { [weak self] line, voice in
            guard let self else { return }
            // A recorded sentence is shown with the voice it turned out to have; the recorder
            // keeps its own copy of the sentence, and writes the voice into the record itself.
            if !self.recorder.setVoice(voice, lineID: line) { self.store.setVoice(lineID: line, voice) }
            if let id = self.store.liveID { self.speakerNamer.guess(id) }
        }
        speakerSetting = settings.$speakerVoices.sink { [weak self] on in
            TranscriptExport.voices = on
            self?.listen.router.setVoiceCapture(on)
        }
        listen.onTranslated = { [weak self] segID, text in
            guard let self else { return }
            if self.heldJoin?.seg.id == segID { self.heldJoin?.translation = text }
            guard let line = self.lineForSegment[segID] else { return }
            self.store.setTranslation(lineID: line, text)
            // The translation arrives after the sentence: the transcript shows it in place.
            if let i = self.capture.lines.firstIndex(where: { $0.id == line }) {
                self.capture.lines[i].translation = text
            }
        }

        diagnostics.enabled = { [weak self] in self?.settings.diagnostics ?? false }
        diagnostics.folder = { [weak self] in
            guard let self, let id = self.store.liveID else { return nil }
            return self.store.folder(id)
        }
        listen.onTiming = { [weak self] in self?.diagnostics.record($0) }
        speak.onTiming = { [weak self] in self?.diagnostics.record($0) }
        speak.onLatency = { [weak self] in self?.lastSpeakLatency = $0 }
        speakTester.onLatency = { [weak self] in self?.lastSpeakLatency = $0 }
        speakTester.translate = { [weak self] text, from, to in
            await self?.listen.translate(text, source: from, target: to, kind: .speak, trace: TranslateTrace())
        }
        ai.onCall = { [weak self] in self?.diagnostics.record($0) }

        // Which service, and which of its models: both come from the settings, so the client
        // never has to know how they are stored.
        ai.service = { [weak self] in self?.settings.aiService ?? .ling }
        ai.model = { [weak self] in self?.aiModelName ?? "Ling-3.1-flash" }
        if let custom = ai.provider(for: .custom) as? CustomProvider {
            custom.baseURL = { [weak self] in self?.settings.aiBaseURL ?? "" }
            custom.modelName = { [weak self] in self?.settings.aiCustomModel ?? "" }
        }
        listen.translator = translator
        translator.glossary = { [weak self] in self?.notes.glossary ?? [] }
        notes.language = { [weak self] id in
            TranslationService.englishName(self?.notesLanguageCode(id) ?? "zh-CN")
        }
        listen.translationOff = { [weak self] in self?.subtitles == "original" }
        if ai.hasKey { Task { await ai.check() } }

        installer.speakThrough = { [weak self] text, lang, device in
            await self?.speak.speak(text, language: lang, device: device)
        }
        installer.onLoaded = { [weak self] in self?.virtualMicInstalled() }

        speak.translate = { [weak self] text, from, to, trace in
            await self?.listen.translate(text, source: from, target: to, kind: .speak, trace: trace)
        }
        speak.interpret = { [weak self] wav, from, to, trace in
            await self?.translator.interpret(wav: wav, source: from, target: to, trace: trace)
        }
        speak.roomLanguage = { [weak self] in self?.listen.activeLang?.code }
        speak.inputDevice = { [weak self] in self?.systemMic.recordingDevice }
        applyVoice()
        speak.onStatus = { [weak self] text in self?.status = text }
        speak.onLive = { [weak self] phase, src, dst in
            guard let self else { return }
            self.speakPhase = phase
            // A 试一句 rehearsal shows in its own sheet: no notes window, caption or subtitle bar.
            if self.speakTester.busy { return }
            if phase == .listening && !src.isEmpty { self.heardSpeech(); self.heardWords() }
            guard self.settings.displayMode == "bar" else {
                // The notes window's caption line shows what you are saying.
                if phase != .idle || !src.isEmpty {
                    self.liveSource = src.isEmpty ? L("你正在说…") : L("你：\(src)")
                    self.liveTranslation = dst
                }
                return
            }
            if !self.overlay.isShown { self.overlay.show() }
            if phase == .idle && src.isEmpty {
                self.overlay.setSpeaking(nil)
            } else {
                self.overlay.setSpeaking(.init(phase: phase, source: src, translation: dst))
            }
        }
        speak.onUtterance = { [weak self] src, dst, from, to, ago in
            self?.recordSaid(src, dst, from: from, to: to, secondsAgo: ago)
        }

        let began: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressBegan() } }
        }
        let ended: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressEnded() } }
        }
        talkCombo.onDown = began
        talkCombo.onUp = ended
        talkRight.onDown = began
        talkRight.onUp = ended
        talkRight.onCancel = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressCancelled() } }
        }
        overlay.onCollapsed = { [weak self] in
            self?.listen.clearDisplay()
            self?.overlay.setSubtitle(source: "", translation: "")
        }
        overlay.mode = { [weak self] in
            (self?.settings.overlayAuto ?? true, self?.settings.overlayHideAfter ?? 4)
        }
        toggleKey.onDown = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.cycleDisplay() } }
        }
        applyToggleKey()
        refreshOutputs()
        let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            // Timer fires from the run loop, not on the main actor executor; hop to the executor
            // before assumeIsolated, or swift_task_isMainExecutorImpl can crash on a null executor.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.watchEnd() }
            }
        }
        endTimer = watch
        RunLoop.main.add(watch, forMode: .common)
        // The capture surface shows how loud the input is and how long it has run: both need
        // reading a few times a second while something is being heard.
        let captureTick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            // Timer fires from the run loop, not on the main actor executor; hop to the executor
            // before assumeIsolated, or swift_task_isMainExecutorImpl can crash on a null executor.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.tickCapture() }
            }
        }
        captureTimer = captureTick
        RunLoop.main.add(captureTick, forMode: .common)
    }

    /// Keeps the live capture's level and clock moving, whichever source is running.
    ///
    /// A paused recording counts as running: the microphone is still open, so the meter keeps
    /// moving, and the two places that show the capture (the toolbar pill and the capture
    /// surface) read the same numbers.
    private func tickCapture() {
        if recorder.state == .recording || recorder.state == .preparing || recorder.state == .paused {
            capture.source = .mic
            capture.level = recorder.level
            capture.waveform = recorder.waveform
            capture.elapsed = recorder.elapsed
            capture.running = true
            return
        }
        if listen.isRunning {
            capture.source = .system
            capture.running = true
            // The system audio path reports its level in decibels; the scope wants the same
            // 0…1 the microphone gives.
            let rms = listen.router.takeLevel()
            let db = 20 * log10(max(Double(rms), 1e-6))
            let v = Float(min(1, max(0, (db + 40) / 40)))
            capture.level = v
            capture.waveform.append(v)
            if capture.waveform.count > 48 { capture.waveform.removeFirst(capture.waveform.count - 48) }
            // The clock stands still while the listening is on hold.
            capture.elapsed = listenElapsed
            return
        }
        capture.running = false
    }

    func setOverlayAuto(_ on: Bool) {
        settings.overlayAuto = on
        overlay.modeChanged()
        objectWillChange.send()
    }

    func launch() async {
        await listen.refreshInstalledLocales()
        refresh()
        if settings.speakEnabled { enableSpeaking(true) }
    }

    func refresh() {
        running = listen.isRunning
        listeningPaused = listen.isPaused
        micState = recorder.state
        // Once the tap has run, the permission is there: pausing doesn't take it away.
        systemAudioOK = systemAudioOK || listen.isRunning
        summary = listen.languageSummary()
        candidates = listen.candidates
        installed = listen.installedLocales
        if running { status = listen.statusText }
    }

    func refreshOutputs() {
        outputs = AudioDevices.outputs()
    }

    var virtualMic: OutputDevice? { outputs.first(where: \.isVirtualMic) }

    // MARK: Permissions (all from the UI, no Terminal)

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }
        let devices = AudioDevices.outputs()
        if devices.map(\.uid) != outputs.map(\.uid) { outputs = devices }
        if listen.isRunning && !systemAudioOK { systemAudioOK = true }
        refreshMicUsers()
        refreshSystemMic()
    }

    // MARK: System microphone

    /// Switching the system mic only helps when our voice goes into the virtual mic.
    var wantsSystemMic: Bool {
        guard settings.speakEnabled, settings.autoSystemMic, virtualMic != nil else { return false }
        return settings.speakOutput.isEmpty || (outputs.first { $0.uid == settings.speakOutput }?.isVirtualMic ?? true)
    }

    func refreshSystemMic() {
        let state = systemMic.refresh(wanted: wantsSystemMic)
        if state != systemMicState { systemMicState = state }
    }

    /// Switches or lets go to match the settings (同声传译, 自动切换, 声音输出到).
    func applySystemMic() {
        // Speaking off: turning it off already put the mic back; a crash leftover waits for 还原.
        if wantsSystemMic { systemMic.engage(wanted: true) } else if settings.speakEnabled { systemMic.release() }
        refreshSystemMic()
    }

    /// 还原: the real mic back now. While speaking it stays back until 换回 or the next time speaking starts.
    func restoreSystemMic() {
        systemMic.release()
        refreshSystemMic()
    }

    /// 换回 / 切换: the virtual mic as the system default again.
    func switchSystemMic() {
        systemMic.engage(wanted: true)
        refreshSystemMic()
    }

    func setAutoSystemMic(_ on: Bool) {
        settings.autoSystemMic = on
        applySystemMic()
    }

    func refreshMicUsers() {
        // Compare against where our voice actually goes: 高级 › 声音输出到 can point elsewhere.
        let target = outputs.first { !settings.speakOutput.isEmpty && $0.uid == settings.speakOutput } ?? virtualMic
        let users = virtualMic != nil ? target.map { MicUsers.current(virtualMic: $0.id) } ?? [] : []
        if users != micUsers { micUsers = users }
    }

    /// Opens the "怎么改" sheet for an app, from the panel or Settings.
    func showMicGuide(_ user: MicUser) {
        micGuide = user
        openSettings(.speak)
    }

    /// Brings a meeting app forward so the user can change its microphone.
    func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Starting the tap triggers the system prompt; if it still fails, open the pane.
    func requestSystemAudio() {
        if !listen.isRunning { start() }
        if !listen.isRunning {
            openSettingsPane("Privacy_ScreenCapture")
        }
        refreshPermissions()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshPermissions() } }
        }
    }

    func openMicrophoneSettings() { openSettingsPane("Privacy_Microphone") }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        // The 诊断 tab only exists while its switch is on.
        if settingsSection == .diagnostics && !settings.diagnostics { settingsSection = .overlay }
        openSettingsWindow?()
    }

    func ensureListening() {
        if !listen.isRunning { start() }
    }

    func virtualMicInstalled() {
        refreshOutputs()
        // Core Audio restarted to load the driver: device IDs changed, reattach the
        // system-audio tap and rebuild the voice output.
        speak.resetOutput()
        listen.reconnectAudio()
        if settings.speakEnabled { applySystemMic() }
        objectWillChange.send()
    }

    // MARK: Start / stop

    func start() {
        guard !listen.isRunning else { return }
        let session = store.begin()
        diagnostics.begin()
        speakers.reset()
        lineForSegment = [:]
        lastHeard = nil
        heldJoin = nil
        speechHeard = false
        meetingSubtitles = nil
        autoEnded = false
        endWatch = MeetingEndWatch(config: endConfig, start: Date())
        setEnding(nil)
        listenClock = CaptureClock(startedAt: Date())
        if settings.recordAudio {
            listen.router.setRecording(store.systemAudioURL(session.id))
            speak.setRecording(store.micAudioURL(session.id))
        }
        listen.start()
        notes.begin(session.id)
        if listen.isRunning {
            showDisplay()
        } else {
            store.end()
        }
        refresh()
    }

    /// `endedAt`: when a meeting that ends by itself really ended (see `autoEnd`).
    func stop(endedAt: Date? = nil) {
        autoEnded = false
        endWatch = nil
        setEnding(nil)
        listenClock = nil
        diagnostics.end()
        listen.stop()
        listen.router.setRecording(nil)
        speak.setRecording(nil)
        if let held = heldJoin {
            heldJoin = nil
            appendHeard(held.seg, t: held.t, translation: held.translation)
        }
        // Read the whole meeting for names once more (the id outlives store.end).
        let ended = store.liveID
        store.end(at: endedAt)
        if settings.speakerVoices, let ended { speakerNamer.guess(ended, force: true) }
        notes.finish()
        overlay.hide()
        refresh()
    }

    func setRunning(_ on: Bool) { on ? start() : requestStop() }

    // MARK: Recording

    /// Starts a recording: the microphone instead of the system audio, and the same meeting
    /// record at the end, so a recording is a meeting like any other.
    func startRecording() {
        guard recorder.state == .idle else { return }
        // A recording and a meeting cannot both be live: they would fight over the microphone.
        if listen.isRunning { stop() }
        let session = store.begin()
        // The engine is wired here, not in the view: a recording started from the panel or a
        // debug command must translate and summarize too.
        recorder.ai = ai
        recorder.installed = installed
        recorder.candidates = candidates
        recorder.target = recordTarget
        recorder.detectsLanguage = recordAutoLang
        recorder.heardLanguage = recordHeardLang
        recorder.keepsAudio = recordKeepsAudio
        recorder.audioURL = store.micAudioURL(session.id)
        // Each recording hears its own voices; the ones heard in a meeting are forgotten.
        speakers.reset()
        recorder.tagger = speakers
        recordSessionID = session.id
        recorder.onLine = { [weak self] line in
            self?.appendRecorded(line)
        }
        recorder.onTranslation = { [weak self] id, text in
            self?.store.setTranslation(lineID: id, text)
        }
        recorder.onVoice = { [weak self] id, voice in
            self?.recordVoice(id, voice)
        }
        recorder.onEdit = { [weak self] id in
            self?.recordEdit(id)
        }
        recorder.onRewrite = { [weak self] in
            self?.recordRewrite()
        }
        recorder.onAutoCorrect = { [weak self] in
            self?.syncCorrectionsToStore()
        }
        recorder.onCorrecting = { [weak self] working in
            guard let self else { return }
            if working {
                self.polishingSessionID = self.recordSessionID
            } else if self.polishingSessionID == self.recordSessionID {
                self.polishingSessionID = nil
            }
        }
        // The toolbar pill watches micState; keep it in step with the engine immediately,
        // instead of waiting for the 0.1s capture tick.
        recorder.onState = { [weak self] state in
            self?.micState = state
            // A recording that starts again gets the full quiet time: the pause it was on hold
            // for is not quiet, so it must not count against it.
            if state == .recording { self?.recordWatch?.heard(at: Date()) }
        }
        recorder.start()
        // A recording answers to the same 通用 settings as a meeting: the same quiet rule, the
        // same minutes, the same action.
        recordWatch = MeetingEndWatch(config: endConfig, start: Date())
        setEnding(nil)
        // The recording drives the same live notes as a meeting: the notes window, the summary
        // panel and the saved record are one thing, however the words were heard.
        notes.begin(session.id)
        micState = recorder.state
        refresh()
    }

    /// Ends the recording and keeps it in the meeting list.
    /// Ends the recording and saves it. `showCard` says whether the passage to the meeting
    /// record is shown: when the recording was stopped to switch to the other source, the user
    /// has something else in mind and the card would only be in the way.
    func endRecording(showCard: Bool = true) {
        recorder.stop()
        recordWatch = nil
        setEnding(nil)
        micState = recorder.state
        guard let id = recordSessionID else { return }
        // The session id is kept: a recording can still be corrected after it has ended, and
        // the changes go into the same meeting.
        recorder.onLine = nil
        recorder.onTranslation = nil
        recorder.onVoice = nil
        recorder.onState = nil
        // The recorder owns its own audio file and rewraps it into .m4a when it closes; the
        // store is not asked to do it again, or the two would race and the second one would
        // take the finished file away.
        store.end()
        // One last pass over the whole recording, so the saved record reads like a finished
        // meeting: the full notes, not the quick ones.
        notes.finish()
        // Auto-correction runs after recording ends: paragraph-level, non-blocking.
        if settings.recordAutoCorrect {
            recorder.runAutoCorrect(glossary: notes.glossary)
        }
        refresh()
        // What was saved is shown for a moment, so the recording does not simply vanish into
        // the meeting list.
        if showCard { showSaving(id) }
    }

    /// The passage from a finished recording to the meeting record: what went in, and where it
    /// went.
    private func showSaving(_ id: String) {
        guard let s = store.session(id) else { return }
        let translated = s.lines.contains { $0.dst?.isEmpty == false }
        let saving = RecordSaving(sessionID: id,
                                   title: s.displayTitle,
                                   duration: s.duration,
                                   lines: s.lines.count,
                                   translated: translated,
                                   notes: ai.hasKey && !s.lines.isEmpty,
                                   hasAudio: s.hasAudio)
        withAnimation(.easeOut(duration: 0.25)) {
            recordSaving = saving
        }
        // The passage stays until the user taps 查看会议记录, then the meeting record opens.
    }

    /// The meeting the finished recording became, opened in the records window.
    func openSavedMeeting() {
        guard let id = recordSaving?.sessionID ?? recordSessionID else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            recordSaving = nil
        }
        mainShow = "\(id),notes"
        // A recording just ended: the record is what the user asked for, so it is opened, never
        // toggled away. The pill's double click is the one that toggles.
        openMainWindow?()
    }

    /// A settled sentence goes into the meeting record, so the recording can be read, exported
    /// and searched like a meeting.
    private func appendRecorded(_ line: RecordLine) {
        guard recordSessionID != nil else { return }
        store.append(TranscriptLine(id: line.id, t: line.t, speaker: "them", src: line.text,
                                    dst: line.translation, srcLang: line.lang, dstLang: target,
                                    voice: line.voice, corrected: line.corrected))
        // Someone spoke: the quiet timer starts over.
        recordWatch?.heard(at: Date())
        setEnding(recordWatch?.pending)
    }

    /// Whose voice a recorded sentence turned out to be: it goes into the meeting record, so the
    /// people are told apart there too.
    private func recordVoice(_ id: String, _ voice: Int?) {
        guard recordSessionID != nil, let voice else { return }
        store.setVoice(lineID: id, voice)
    }

    /// A sentence the user corrected: the record gets the new words.
    private func recordEdit(_ id: String) {
        guard let session = recordSessionID,
              let line = recorder.lines.first(where: { $0.id == id }) else { return }
        store.setSource(in: session, lineID: id, line.text)
    }

    /// The sentences were merged or split: the record is written out again, because the set of
    /// lines is different now.
    private func recordRewrite() {
        guard let session = recordSessionID else { return }
        store.replaceLines(in: session, recorder.lines.map {
            TranscriptLine(id: $0.id, t: $0.t, speaker: "them", src: $0.text,
                           dst: $0.translation, srcLang: $0.lang, dstLang: target,
                           voice: $0.voice, corrected: $0.corrected)
        })
    }

    /// 把引擎里已纠正的行回写到 SessionStore，供持久化和导出。
    private func syncCorrectionsToStore() {
        guard let id = recordSessionID else { return }
        // Sync all lines that have been considered (corrected or explicitly cleared)
        let corrections = recorder.lines.map { (lineID: $0.id, corrected: $0.corrected) }
        store.updateCorrections(in: id, corrections)
    }

    /// Undoes the polish of one sentence in a saved meeting.
    ///
    /// The recording still holds its own copy, so the engine is told too: otherwise the next
    /// sync would write the correction back and the undo would not last.
    func clearCorrection(in sessionID: String, lineID: String) {
        if sessionID == recordSessionID {
            recorder.clearCorrection(lineID)
        } else {
            store.setCorrected(in: sessionID, lineID: lineID, nil)
        }
    }

    /// Polishes one sentence of a saved meeting again, with the same service that polished it
    /// before: the sentence and its neighbours go out together, so the wording stays consistent.
    func recorrect(in sessionID: String, lineID: String) {
        guard ai.usable, let session = store.session(sessionID) else { return }
        guard session.lines.contains(where: { $0.id == lineID }) else { return }
        let items = session.lines.map {
            Corrector.Item(id: $0.id, t: $0.t, speaker: $0.speaker, text: $0.src)
        }
        let ends = Dictionary(uniqueKeysWithValues: session.lines.map { ($0.id, $0.t) })
        // The sentence's own chunk: the pauses and speaker changes around it.
        let segments = Corrector.segment(items, endTimes: ends)
        guard let chunk = segments.first(where: { $0.contains { $0.id == lineID } }) else { return }
        polishingSessionID = sessionID
        Task {
            let fixed = await Corrector.correct(items: chunk, endTimes: ends, glossary: notes.glossary, ai: ai)
            await MainActor.run {
                for (id, text) in fixed {
                    self.store.setCorrected(in: sessionID, lineID: id, text)
                }
                // The recording still holds the old copy; the record is the one being read.
                if sessionID == self.recordSessionID {
                    self.syncCorrectionsToStore()
                }
                self.polishingSessionID = nil
                debugLog("correct: recorrect \(lineID) → \(fixed.count) changed")
            }
        }
    }

    /// The menu (⌘R) and the panel switch: a meeting with lines is ended only after asking, with
    /// "继续记录" as the default so a stray Return keeps it going. An empty one just stops.
    func requestStop() {
        guard listen.isRunning, let id = store.liveID, let s = store.session(id), !s.lines.isEmpty else { stop(); return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("结束这场会议？")
        alert.informativeText = L("已记录 \(NotesEngine.clock(Date().timeIntervalSince(s.startedAt))) · \(s.lines.count) 句。结束后停止收听，并整理一份完整版纪要。")
        let end = alert.addButton(withTitle: L("结束会议"))
        let keep = alert.addButton(withTitle: L("继续记录"))
        end.hasDestructiveAction = true
        end.keyEquivalent = ""
        keep.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { stop() }
    }

    /// Asks before the source is switched while the other one is running. The microphone and the
    /// system audio cannot both be listened to, so the running one has to stop — and stopping a
    /// recording is not something the app should do on its own.
    func confirmSwitch(from old: CaptureSource, to new: CaptureSource) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = new == .mic ? L("切换到麦克风？") : L("切换到系统声音？")
        alert.informativeText = old == .mic
            ? L("麦克风正在录音，切换会结束这场录音并保存到会议记录。")
            : L("系统声音正在收听，切换会结束这场收听。")
        // The switch is the action, cancelling is the safe answer: Return does nothing.
        let go = alert.addButton(withTitle: L("切换"))
        let cancel = alert.addButton(withTitle: L("取消"))
        go.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    //// Puts the listening on hold: the tap stays open (the meter still moves) but nothing said
    /// while paused is written down, and the clock stands still.
    func pauseListening() {
        guard listen.isRunning, !listen.isPaused else { return }
        listen.pause()
        listenClock?.pause()
        refresh()
        debugLog("listen: paused elapsed=\(Int(listenElapsed))")
    }

    /// Takes the listening back up. The words continue from where the pause was.
    func resumeListening() {
        guard listen.isRunning, listen.isPaused else { return }
        listen.resume()
        listenClock?.resume()
        refresh()
        debugLog("listen: resumed elapsed=\(Int(listenElapsed))")
    }

    /// How long the meeting has been running. A pause stops the clock: the time spent on hold
    /// is not part of the meeting.
    var listenElapsed: TimeInterval {
        listenClock?.elapsed() ?? 0
    }

    // The bottom-left 诊断 switch in settings: shows or hides the 诊断 tab.
    func setDiagnostics(_ on: Bool) {
        settings.diagnostics = on
        if !on && settingsSection == .diagnostics { settingsSection = .overlay }
        objectWillChange.send()
    }

    // MARK: Languages

    /// This meeting's 字幕 choice from the notes window's language chip (nil: the settings').
    @Published var meetingSubtitles: String?
    /// Notes language chosen for one meeting (the chip during it, 重新整理 after it).
    @Published private(set) var notesLanguageFor: [String: String] = [:]

    var subtitles: String { meetingSubtitles ?? settings.subtitles }

    func notesChoice(_ id: String) -> String { notesLanguageFor[id] ?? settings.notesLanguage }

    /// The language the other side spoke most in a meeting (the detected one while nothing is recorded yet).
    func meetingLanguage(_ id: String?) -> String? {
        let heard = id.flatMap { store.session($0) }?.lines.filter { $0.speaker != "me" }.map(\.srcLang) ?? []
        let counts = Dictionary(heard.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? (id == store.liveID ? listen.activeLang?.code : nil)
    }

    func notesLanguageCode(_ id: String) -> String {
        notesChoice(id) == "source" ? (meetingLanguage(id) ?? settings.myLanguage) : settings.myLanguage
    }

    /// The subtitle as the 字幕 choice shows it: both lines, the translation alone, or the
    /// original alone as the main line.
    func displayed(_ src: String, _ dst: String) -> (source: String, translation: String) {
        switch subtitles {
        case "original": return ("", src)
        case "translation": return dst.isEmpty ? (src, "") : ("", dst)
        default: return (src, dst)
        }
    }

    func setSubtitles(_ mode: String, meetingOnly: Bool = false) {
        let wasOff = subtitles == "original"
        if meetingOnly { meetingSubtitles = mode } else { settings.subtitles = mode; meetingSubtitles = nil }
        if wasOff && subtitles != "original" { listen.translationResumed() }
        debugLog("subtitles=\(subtitles) meetingOnly=\(meetingOnly)")
        objectWillChange.send()
    }

    /// A different notes language during a meeting rewrites the notes in it right away.
    func setNotesLanguage(_ choice: String, meetingOnly: Bool = false) {
        let live = store.liveID
        let before = live.map(notesLanguageCode)
        if meetingOnly, let live { notesLanguageFor[live] = choice } else { settings.notesLanguage = choice }
        if let live, notesLanguageCode(live) != before { notes.rewrite() }
        debugLog("notesLanguage=\(live.map(notesLanguageCode) ?? settings.notesLanguage) meetingOnly=\(meetingOnly)")
        objectWillChange.send()
    }

    /// Picks the interface language; it takes effect the next time the app opens, so offer to
    /// relaunch right away. Only the relaunch is asked for, the pick is saved either way.
    func setInterfaceLanguage(_ id: String) {
        guard InterfaceLanguage.choose(id) else { return }
        debugLog("interfaceLanguage=\(id)")
        objectWillChange.send()
        let alert = NSAlert()
        alert.messageText = L("界面语言已改为 \(InterfaceLanguage.currentTitle)")
        alert.informativeText = L("重启应用后生效。现在重启吗？")
        alert.addButton(withTitle: L("现在重启"))
        alert.addButton(withTitle: L("稍后自己重启"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { restartApp() }
    }

    /// Quits and reopens the app, like the updater does for an install.
    private func restartApp() {
        let url = Bundle.main.bundleURL
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to end, then reopen the same bundle.
        script.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; open \"$2\"", "--", String(getpid()), url.path]
        try? script.run()
        NSApp.terminate(nil)
    }

    /// After a meeting: write its notes again in the other language.
    func regenerateNotes(_ id: String, choice: String) {
        notesLanguageFor[id] = choice
        notes.generate(for: id)
    }

    // MARK: Display (live notes / subtitle bar / nothing)

    /// 录屏时可见: every place that shows it (settings, menu bar panel, 显示 menu, the notes
    /// window's badge) flips this one setting.
    func setNotesCapturable(_ on: Bool) {
        settings.notesCapturable = on
        notesWindow.setCapturable(on)
        objectWillChange.send()
    }

    func setDisplayMode(_ mode: String) {
        settings.displayMode = mode
        objectWillChange.send()
        showDisplay(force: true)
    }

    /// ⌃⌥S: notes → subtitle bar → nothing → notes.
    func cycleDisplay() {
        let order = ["notes", "bar", "none"]
        let i = order.firstIndex(of: settings.displayMode) ?? 0
        setDisplayMode(order[(i + 1) % order.count])
    }

    /// Set at the first words of a meeting: until then listening stays out of sight.
    private var speechHeard = false

    private func heardSpeech() {
        guard !speechHeard, listen.isRunning else { return }
        speechHeard = true
        if settings.displayMode == "notes" { notesWindow.show() }
    }

    /// `force`: the user asked for this mode, show it even before anyone speaks.
    private func showDisplay(force: Bool = false) {
        switch settings.displayMode {
        case "bar":
            notesWindow.hide()
            if listen.isRunning { overlay.show() }
        case "none":
            notesWindow.hide()
            overlay.hide()
        default:
            overlay.hide()
            // The notes window waits for someone to speak, so launching or a silent tab
            // doesn't put an empty window on screen.
            if listen.isRunning && (speechHeard || force) { notesWindow.show() }
        }
    }

    /// The user closed the notes window: show the same meeting in the records window.
    func notesWindowClosed() {
        let id = store.liveID ?? notes.shownID
        openMainWindow?()
        if let id {
            mainShow = nil
            mainShow = "\(id),notes"
        }
    }

    func openNotesWindow() {
        if settings.displayMode != "notes" { setDisplayMode("notes") }
        notesWindow.show()
    }

    /// 收起 in the menu bar panel: out of the way for now, still in 实时纪要 mode
    /// (unlike the close button, it doesn't open the records window).
    func hideNotesWindow() { notesWindow.hide() }

    func notesVisibilityChanged(_ shown: Bool) {
        if notesShown != shown { notesShown = shown }
    }

    // MARK: Settings actions

    var sourceSelection: String {
        get {
            if case .fixed(let l) = settings.sourceMode { return l.locale }
            return "auto"
        }
        set {
            settings.sourceMode = newValue == "auto" ? .auto
                : .fixed(sourceLanguages.first(where: { $0.locale == newValue }) ?? sourceLanguages[0])
            listen.sourceModeChanged()
            refresh()
            objectWillChange.send()
        }
    }

    var targetSelection: String {
        get { settings.target }
        set {
            settings.target = newValue
            listen.targetChanged()
            refresh()
            objectWillChange.send()
        }
    }

    /// The meeting being recorded, while one is.
    private var recordSessionID: String?
    /// The meeting whose words are being polished right now, if any. The surfaces say so: the
    /// sentences change under the reader while the service is working.
    @Published private(set) var polishingSessionID: String?
    /// Whether the recording's own words are being polished.
    var recordCorrecting: Bool { polishingSessionID != nil && polishingSessionID == recordSessionID }
    /// The session currently being recorded by the microphone path, for UI that needs it.
    var activeRecordingSessionID: String? { recordSessionID }
    /// The title shown for the recording in progress: the automatic name (e.g. notes title/date)
    /// until the user renames it, then the user's title.
    var recordSessionDisplayTitle: String {
        guard let id = recordSessionID, let s = store.session(id) else { return "" }
        return s.displayTitle
    }
    /// Renames the recording in progress. An empty string reverts to the automatic title.
    func renameRecordingSession(to title: String) {
        guard let id = recordSessionID else { return }
        store.rename(id, to: title)
    }
    /// The language the recorded sentences are translated into.
    var target: String { recordTarget == "none" ? settings.myLanguage : recordTarget }

    // MARK: Recording settings

    /// The recording that is being put into the meeting list: the moment of saving, shown as a
    /// short passage rather than a sudden jump.
    @Published private(set) var recordSaving: RecordSaving?

    /// The language the recording translates into; "none" leaves the sentences as they were said.
    @Published var recordTarget: String {
        didSet { UserDefaults.standard.set(recordTarget, forKey: "recordTarget") }
    }
    /// Detect the language instead of using one fixed model.
    @Published var recordAutoLang: Bool {
        didSet { UserDefaults.standard.set(recordAutoLang, forKey: "recordAutoLang") }
    }
    /// The language the recording is made in; "auto" detects it.
    @Published var recordHeardLang: String {
        didSet { UserDefaults.standard.set(recordHeardLang, forKey: "recordHeardLang") }
    }
    /// Keep the audio next to the transcript.
    @Published var recordKeepsAudio: Bool {
        didSet { UserDefaults.standard.set(recordKeepsAudio, forKey: "recordKeepsAudio") }
    }
    /// 自动润色录音转写（识别后后台纠错同音字/错字/标点）。
    var recordAutoCorrect: Bool { settings.recordAutoCorrect }

    func enableSpeaking(_ on: Bool) {
        settings.speakEnabled = on
        if on { settings.speakConfirmed = true }
        objectWillChange.send()
        if on {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { debugLog("microphone permission denied") }
            }
            if settings.talkKey.isRightOption && !RightOptionKey.allowed { RightOptionKey.requestAccess() }
            applyTalkKey()
            refreshOutputs()
            applySystemMic()
            Task { await speak.prepare() }
        } else {
            applyTalkKey()
            restoreSystemMic()
            Task { await speak.teardownAnalyzer() }
        }
    }

    // MARK: Shortcuts

    enum ShortcutRole { case talk, toggle }

    /// Arms the talk key for the current setting. Right ⌥ waits for "输入监控" and
    /// arms itself as soon as it's allowed (no relaunch).
    func applyTalkKey() {
        talkCombo.unregister()
        talkRight.stop()
        var needsPermission = false
        if settings.speakEnabled && !shortcutsSuspended {
            if settings.talkKey.isRightOption {
                needsPermission = !talkRight.start()
            } else {
                talkCombo.register(settings.talkKey)
            }
        }
        if talkNeedsPermission != needsPermission { talkNeedsPermission = needsPermission }
        if needsPermission, permissionPoll == nil {
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if RightOptionKey.allowed || !self.settings.speakEnabled || !self.settings.talkKey.isRightOption {
                        self.permissionPoll?.invalidate()
                        self.permissionPoll = nil
                        self.applyTalkKey()
                    }
                }
            }
        }
    }

    func applyToggleKey() {
        toggleKey.unregister()
        guard !shortcutsSuspended else { return }
        let ok = toggleKey.register(settings.toggleKey)
        if toggleKeyTaken == ok { toggleKeyTaken = !ok }
    }

    func allowTalkKey() {
        RightOptionKey.requestAccess()
        RightOptionKey.openSystemSettings()
    }

    /// While a shortcut field is recording, our own shortcuts must not swallow the keys.
    func suspendShortcuts(_ on: Bool) {
        shortcutsSuspended = on
        applyTalkKey()
        applyToggleKey()
    }

    /// Validates and saves a new shortcut. Returns why it was refused, or nil.
    func setShortcut(_ s: Shortcut, for role: ShortcutRole) -> String? {
        if role == .toggle && s.isRightOption { return L("右 ⌥ 只能用于“按住说话”") }
        if let p = s.typingProblem { return p }
        let other = role == .talk ? settings.toggleKey : settings.talkKey
        if s == other { return L("与另一个快捷键冲突") }
        if s.isSystemShortcut { return L("\(s.display) 是系统快捷键，换一个吧") }
        // The one already in use is registered by us: probing it would always fail.
        let current = role == .talk ? settings.talkKey : settings.toggleKey
        if !s.isRightOption && s != current {
            // Probe: Carbon refuses a combo another app already registered.
            let probe = HotKey(id: 9, shortcut: s)
            let free = probe.register()
            probe.unregister()
            if !free { return L("\(s.display) 已被其他应用占用，换一个吧") }
        }
        switch role {
        case .talk:
            settings.talkKey = s
            if s.isRightOption && settings.speakEnabled && !RightOptionKey.allowed { RightOptionKey.requestAccess() }
        case .toggle:
            settings.toggleKey = s
        }
        applyTalkKey()
        applyToggleKey()
        objectWillChange.send()
        return nil
    }

    /// The room hears the voice chosen for its language (looked up each time it speaks).
    func applyVoice() {
        speak.route = { [weak self] language in
            guard let self else { return .system(nil) }
            return self.voiceRoute(id: self.voiceID(for: language), language: language)
        }
    }

    /// The model the notes and the translation use now: the one the user picked for the service
    /// in use, or that service's own default.
    var aiModelName: String {
        let service = settings.aiService
        let provider = ai.provider(for: service)
        return settings.aiModel(for: service, fallback: provider?.defaultModel ?? "",
                                allowed: provider?.models ?? [])
    }

    /// The chosen voice for a language, or its default (Ming's first with a key, else the Mac's).
    func voiceID(for language: String) -> String? {
        if let id = settings.speakVoices[VoiceCatalog.key(for: language)] {
            if id == "clone" && !VoiceReference.exists { return VoiceCatalog.defaultID(for: language, service: settings.aiService, hasKey: ai.usable) }
            return id
        }
        return VoiceCatalog.defaultID(for: language, service: settings.aiService, hasKey: ai.usable)
    }

    func setVoice(_ id: String, for language: String) {
        settings.speakVoices[VoiceCatalog.key(for: language)] = id
    }

    /// Ming's voices need a working key; without one the Mac's voice speaks.
    func voiceRoute(id: String?, language: String) -> SpeakEngine.VoiceRoute {
        guard let id else { return .system(nil) }
        if id.hasPrefix("system:") { return .system(String(id.dropFirst("system:".count))) }
        guard ai.usable else { return .system(nil) }
        let lang = VoiceCatalog.key(for: language)
        if id == "clone" {
            // Only the services that can clone the user's own voice offer it.
            guard ai.currentProvider?.canClone == true, let ref = VoiceReference.reference() else { return .system(nil) }
            return .stream { [weak self] text in
                self?.ai.speech(text, voice: "", reference: ref, language: lang)
                    ?? AsyncThrowingStream { $0.finish(throwing: AIFailure.noKey) }
            }
        }
        // "ai:<service>:<voice>": the voice belongs to the service that speaks it, so a voice
        // chosen for another service is not used.
        guard id.hasPrefix("ai:") else { return .system(nil) }
        let rest = String(id.dropFirst("ai:".count))
        guard let split = rest.firstIndex(of: ":"), let service = AIService(rawValue: String(rest[..<split])) else { return .system(nil) }
        guard service == settings.aiService else { return .system(nil) }
        let voice = String(rest[rest.index(after: split)...])
        return .stream { [weak self] text in
            self?.ai.speech(text, voice: voice, language: lang)
                ?? AsyncThrowingStream { $0.finish(throwing: AIFailure.noKey) }
        }
    }

    /// Plays a voice on the speakers (not into the room) with a line in that language.
    @Published var previewing: String?

    func previewVoice(_ id: String, language: String, text: String? = nil) {
        previewing = id
        let route = voiceRoute(id: id, language: language)
        Task {
            let started = Date()
            await speak.speak(text ?? VoiceCatalog.sample(for: language), language: language,
                              device: AudioDevices.defaultOutput, route: route)
            debugLog("voice preview \(id) \(language) took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            if previewing == id { previewing = nil }
        }
    }

    func speakFromChanged() {
        objectWillChange.send()
        if settings.speakEnabled { Task { await speak.prepare() } }
    }

    // MARK: Meeting end

    private var endConfig: MeetingEndWatch.Config {
        var c = MeetingEndWatch.Config()
        c.followApps = settings.endWithApp
        c.silence = MeetingEndWatch.Silence(rawValue: settings.silenceEnd) ?? .prompt
        c.silenceAfter = settings.silenceMinutes * 60
        if let o = endTimesOverride { (c.silenceAfter, c.countdown, c.appGrace) = (o.silence, o.countdown, o.grace) }
        return c
    }

    private func heardWords() {
        endWatch?.heard(at: Date())
        setEnding(endWatch?.pending)
    }

    /// Every 2 s: while listening or recording, whether the meeting is over; after one ended by
    /// itself, whether a meeting app started the next call.
    ///
    /// Both sources answer to the same 通用 setting: a recording that goes quiet for a while
    /// does the same thing a meeting that goes quiet does, because from the reader's side they
    /// are the same thing.
    private func watchEnd() {
        if listen.isRunning, var w = endWatch {
            w.config = endConfig
            let said = store.liveID.flatMap { store.session($0) }.map { !$0.lines.isEmpty } ?? false
            let calls = w.config.followApps ? (fakeCalls ?? MicUsers.currentCalls()) : [:]
            let reason = w.tick(at: Date(), calls: calls, said: said)
            endWatch = w
            setEnding(w.pending)
            if let reason { autoEnd(reason, watch: w) }
        } else if recorder.state == .recording, var w = recordWatch {
            w.config = endConfig
            let said = recorder.lines.isEmpty == false
            let reason = w.tick(at: Date(), calls: [:], said: said)
            recordWatch = w
            setEnding(w.pending)
            if let reason { recordAutoAction(reason, watch: w) }
        } else if !listen.isRunning, autoEnded, settings.endWithApp, !(fakeCalls ?? MicUsers.currentCalls()).isEmpty {
            debugLog("meeting end: a meeting app started a call, starting a new meeting")
            start()
        }
    }

    private func setEnding(_ p: MeetingEndWatch.Pending?) {
        guard p != ending else {
            if p != nil { showEndingOnBar() }
            return
        }
        if let p { debugLog("meeting end: pending \(p.reason), ends in \(Int(p.deadline.timeIntervalSinceNow)) s") }
        else if ending != nil { debugLog("meeting end: pending cleared"); overlay.clearStatus() }
        ending = p
        showEndingOnBar()
    }

    /// The subtitle bar has no buttons: it says what will happen, and speaking keeps a silent meeting going.
    private func showEndingOnBar() {
        guard settings.displayMode == "bar", let p = ending else { return }
        let left = max(0, Int(p.deadline.timeIntervalSinceNow.rounded()))
        overlay.notice(endingTitle(p) + " · " + (endConfig.silence == .pause ? L("\(left) 秒后暂停") : L("\(left) 秒后结束")))
    }

    func endingTitle(_ p: MeetingEndWatch.Pending) -> String {
        switch p.reason {
        case .appLeft(let name): L("\(name) 已挂断")
        case .silence, .nobodySpoke, .silencePause: L("已经 \(max(1, Int((endConfig.silenceAfter / 60).rounded()))) 分钟没人说话")
        }
    }

    func endingDetail(_ p: MeetingEndWatch.Pending, now: Date = Date()) -> String {
        let left = max(0, Int(p.deadline.timeIntervalSince(now).rounded()))
        // A pause is not an ending: it says what is about to happen, which is different.
        if endConfig.silence == .pause { return L("\(left) 秒后暂停") }
        return L("\(left) 秒后结束会议并整理纪要")
    }

    /// "继续记录" on the ending prompt.
    func keepRecording() {
        endWatch?.keepGoing(at: Date())
        recordWatch?.keepGoing(at: Date())
        setEnding(nil)
        debugLog("meeting end: kept going")
    }

    /// Ends where the meeting really ended: a little after the last words, or at the hang-up if
    /// that was later. Never before a line that was kept, or its audio would be cut.
    private func autoEnd(_ reason: MeetingEndWatch.Reason, watch w: MeetingEndWatch) {
        if reason == .nobodySpoke {
            // Nothing to keep or summarise: back to "开始听", not "会议已自动结束".
            debugLog("meeting end: nobody spoke for \(Int(w.config.silenceAfter)) s, stopped")
            stop()
            return
        }
        if reason == .silencePause {
            // The room went quiet: the meeting is held on hold, not ended. The words are kept
            // and the clock stops, so the quiet is not counted as part of the meeting.
            debugLog("meeting end: quiet for \(Int(w.config.silenceAfter)) s, paused")
            pauseListening()
            endWatch?.keepGoing(at: Date())
            setEnding(nil)
            return
        }
        var at = w.lastSpeech.addingTimeInterval(5)
        if case .appLeft = reason { at = max(at, Date().addingTimeInterval(-w.config.appGrace)) }
        debugLog("meeting end: ended by itself (\(reason)), end time \(Int(Date().timeIntervalSince(at))) s ago")
        stop(endedAt: at)
        autoEnded = true
    }

    /// The same thing for a recording: a quiet room pauses it, an empty one ends it.
    private func recordAutoAction(_ reason: MeetingEndWatch.Reason, watch w: MeetingEndWatch) {
        if reason == .nobodySpoke {
            debugLog("record: nobody spoke for \(Int(w.config.silenceAfter)) s, stopped")
            endRecording()
            return
        }
        if reason == .silencePause {
            debugLog("record: quiet for \(Int(w.config.silenceAfter)) s, paused")
            recorder.pause()
            recordWatch?.keepGoing(at: Date())
            setEnding(nil)
            refresh()
            return
        }
        debugLog("record: ended by itself (\(reason))")
        endRecording()
    }

    // MARK: Meeting record

    /// Names are typed in the records window: the notes window never takes focus.
    func editSpeaker(session: String, voice: Int) {
        speakerEdit = SpeakerEditRequest(session: session, voice: voice)
        mainShow = nil
        mainShow = "\(session),transcript"
        openMainWindow?()
    }

    private func recordHeard(_ seg: Segment, duration: Double) {
        guard let start = store.liveStart else { return }
        let t = max(0, Date().timeIntervalSince(start) - duration)
        // A line still waiting for its voice is overtaken: it stands on its own.
        if let held = heldJoin {
            heldJoin = nil
            appendHeard(held.seg, t: held.t, translation: held.translation)
        }
        guard let prev = lastHeard, store.session(store.liveID ?? "")?.lines.last?.id == prev.line,
              prev.seg.clock == seg.clock, prev.seg.sourceCode == seg.sourceCode,
              HeardText.continues(prev.seg.text, seg.text, gap: seg.start - prev.seg.end, cut: prev.seg.cut) else {
            appendHeard(seg, t: t, tag: true)
            return
        }
        // Two voices never share a line: hear whose this is first (a few hundredths of a second).
        if settings.speakerVoices, let samples = seg.voiceSamples, seg.text.filter(\.isLetter).count >= 2 {
            heldJoin = (seg, t, nil)
            speakers.voice(of: samples) { [weak self] voice in self?.heardVoice(seg, voice) }
            return
        }
        join(seg, onto: prev)
    }

    private func heardVoice(_ seg: Segment, _ voice: Int?) {
        guard let held = heldJoin, held.seg.id == seg.id else {
            // Already recorded on its own (another line came first).
            if let voice, let line = lineForSegment[seg.id] { speakers.onVoice?(line, voice) }
            return
        }
        heldJoin = nil
        let lines = store.session(store.liveID ?? "")?.lines ?? []
        if let prev = lastHeard, let last = lines.last, last.id == prev.line,
           voice == nil || last.voice == nil || voice == last.voice {
            join(seg, onto: prev)   // the earlier line's voice stays
        } else {
            appendHeard(seg, t: held.t, translation: held.translation)
            if let voice, let line = lineForSegment[seg.id] { speakers.onVoice?(line, voice) }
        }
    }

    /// One sentence a pause cut in two: the earlier line takes the rest and is translated again whole.
    private func join(_ seg: Segment, onto prev: (seg: Segment, line: String)) {
        let text = HeardText.join(prev.seg.text, seg.text)
        var joined = prev.seg
        joined.text = text
        joined.end = seg.end
        joined.cut = seg.cut
        lastHeard = (joined, prev.line)
        store.setSource(lineID: prev.line, text)
        // The sentence grew: the transcript shows the whole of it now.
        if let i = capture.lines.firstIndex(where: { $0.id == prev.line }) {
            capture.lines[i].text = text
        }
        listen.join(seg.id, into: prev.seg.id, text: text)
        contentLog("JOIN \(prev.line) += \(seg.text)")
        heardWords()
    }

    private func appendHeard(_ seg: Segment, t: Double, translation: String? = nil, tag: Bool = false) {
        lineCounter += 1
        let id = "h\(lineCounter)-\(seg.id)"
        lineForSegment[seg.id] = id
        store.append(TranscriptLine(id: id, t: t, speaker: "them", src: seg.text, dst: translation ?? seg.translation,
                                    srcLang: seg.sourceCode, dstLang: listen.resolvedTarget))
        // The sentence has settled: it joins the transcript the reader sees, and the live row
        // gives way to it.
        capture.lines.append(RecordLine(id: id, t: t, text: seg.text, translation: translation ?? seg.translation,
                                        lang: seg.sourceCode))
        capture.setLive("", words: [])
        var kept = seg
        kept.voiceSamples = nil
        lastHeard = (kept, id)
        // A line with hardly a letter ("." from a breath or a click) gets no voiceprint.
        if tag, settings.speakerVoices, let samples = seg.voiceSamples, seg.text.filter(\.isLetter).count >= 2 {
            speakers.tag(lineID: id, samples: samples)
        }
        heardWords()
    }

    private func recordSaid(_ src: String, _ dst: String, from: String, to: String, secondsAgo: Double) {
        guard let start = store.liveStart else { return }
        lineCounter += 1
        let t = max(0, Date().timeIntervalSince(start) - secondsAgo)
        store.append(TranscriptLine(id: "m\(lineCounter)", t: t, speaker: "me", src: src, dst: dst,
                                    srcLang: from, dstLang: to))
        heardWords()
    }

    // MARK: Export

    /// The recording being made, as a session, so it can be exported like any other meeting.
    var recordSession: Session? {
        guard let id = recordSessionID, let s = store.session(id), !s.lines.isEmpty else { return nil }
        return s
    }

    /// Exports the recording; nothing happens when there is nothing to export yet.
    func exportRecording(kind: String) {
        guard let session = recordSession else { return }
        export(session, kind: kind)
    }

    /// Opens the export panel for a meeting: what goes into the file, and in which format.
    /// The diagram style the reader last picked is the one the file gets.
    func requestExport(_ session: Session, mindMapStyle: MindMapStyle? = nil) {
        exportOptions.mindMapStyle = mindMapStyle ?? aiViewStyle
        exportRequest = ExportRequest(id: session.id, session: session)
        showExportPanel?()
    }

    /// Exports a meeting. `done` runs once the file is written: the export panel waits for it,
    /// so the panel is not closed while the save sheet is still up.
    func export(_ session: Session, kind: String, options: ExportOptions = ExportOptions(), done: (() -> Void)? = nil) {
        if kind == "copy" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TranscriptExport.markdown(session, options: options), forType: .string)
            return
        }
        let panel = NSSavePanel()
        let ext: String
        switch kind {
        case "word": ext = "docx"
        case "srt": ext = "srt"
        case "pdf": ext = "pdf"
        default: ext = "md"
        }
        panel.nameFieldStringValue = "\(session.displayTitle.replacingOccurrences(of: "/", with: "-")).\(ext)"
        panel.canCreateDirectories = true
        if let w = NSApp.keyWindow, !(w is NSPanel), w.isVisible {
            panel.beginSheetModal(for: w) { [weak self] r in
                guard r == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.writeExport(session, kind: kind, options: options, to: url) { done?() }
                }
            }
            return
        }
        NSApp.activate()
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if writeExport(session, kind: kind, options: options, to: url) { done?() }
    }

    @discardableResult
    func writeExport(_ session: Session, kind: String, options: ExportOptions = ExportOptions(), to url: URL) -> Bool {
        do {
            let images = options.aiView ? FishboneImage.images(session.notes ?? MeetingNotes(), style: options.mindMapStyle) : [:]
            switch kind {
            case "word": try TranscriptExport.docx(session, options: options, images: images).write(to: url)
            case "srt": try TranscriptExport.srt(session).write(to: url, atomically: true, encoding: .utf8)
            case "pdf": try TranscriptExport.pdf(session, options: options, images: images).write(to: url)
            default: try TranscriptExport.markdown(session, options: options).write(to: url, atomically: true, encoding: .utf8)
            }
            debugLog("export wrote \(url.path)")
            return true
        } catch {
            debugLog("export failed: \(error)")
            return false
        }
    }

    /// Exports several meetings at once: pick a folder once, each meeting becomes a file in it.
    func exportBatch(_ sessions: [Session]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("选择一个文件夹，每场会议导出成一个文件")
        if let w = NSApp.keyWindow, !(w is NSPanel), w.isVisible {
            panel.beginSheetModal(for: w) { [weak self] r in
                guard r == .OK, let self, let url = panel.url else { return }
                self.writeBatch(sessions, to: url)
            }
            return
        }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeBatch(sessions, to: url)
    }

    private func writeBatch(_ sessions: [Session], to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for s in sessions {
            let name = s.displayTitle.replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent(name).appendingPathExtension("md")
            _ = writeExport(s, kind: "md", options: ExportOptions(), to: url)
        }
    }

    // MARK: Debug control (only with `defaults write com.wquguru.cicada debug -bool true`)

    func installDebugControl() {
        guard settings.debug || DevBuild.isDev else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(DevBuild.debugChannel), object: nil, queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(cmd) }
        }
        debugLog("debug control ready")
    }

    /// Where the toolbar's pill sits on the screen, in Quartz's top-left coordinates.
    ///
    /// The window's frame is in Cocoa coordinates (bottom-left); the screen's own height turns
    /// it into the top-left coordinates a click uses.
    private func pillFrameReport() -> String {
        guard let window = NSApp.windows.first(where: { $0.toolbar != nil && $0.isVisible }),
              let toolbar = window.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier == MainToolbar.pill }),
              let view = item.view else {
            return "pill frame: no toolbar pill"
        }
        let inWindow = view.convert(view.bounds, to: nil)
        let frame = window.convertToScreen(inWindow)
        guard let screen = window.screen ?? NSScreen.main else { return "pill frame: no screen" }
        // Cocoa counts from the bottom of the screen; Quartz counts from the top.
        let topLeftY = screen.frame.maxY - frame.maxY
        // The buttons are reported in the pill's own space; the pill's space starts at the
        // hosting view's left edge, which is the toolbar item's left edge on the screen.
        let buttons = toolbarPillRegions.map { r in
            "\(Int(frame.minX + r.minX)),\(Int(topLeftY + r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        // The body is the stretch between the buttons; a double click there opens the window.
        let body = toolbarPillBody.isNull ? "none" :
            "\(Int(frame.minX + toolbarPillBody.minX)),\(Int(topLeftY + toolbarPillBody.minY)) \(Int(toolbarPillBody.width))x\(Int(toolbarPillBody.height))"
        return "pill frame: x=\(Int(frame.minX)) y=\(Int(topLeftY)) w=\(Int(frame.width)) h=\(Int(frame.height)) buttons=[\(buttons.joined(separator: ", "))] body=\(body)"
    }

    /// Where the floating pill sits on the screen, in Quartz's top-left coordinates.
    ///
    /// Its buttons are reported too, so a click can be aimed at the body between them.
    private func floatingPillFrameReport() -> String {
        guard let window = floatingPill.window else { return "floating pill: no window" }
        let frame = window.frame
        guard let screen = window.screen ?? NSScreen.main else { return "floating pill: no screen" }
        // The buttons are in the overlay's coordinates; the overlay sits on the content.
        let topLeftY = screen.frame.maxY - frame.maxY
        let buttons = floatingPill.buttonRegions.map { r in
            "\(Int(frame.minX + r.minX)),\(Int(topLeftY + r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        return "floating pill: x=\(Int(frame.minX)) y=\(Int(topLeftY)) w=\(Int(frame.width)) h=\(Int(frame.height)) buttons=[\(buttons.joined(separator: ", "))]"
    }

    private func debugCommand(_ cmd: String) {
        debugLog("debug command: \(cmd)")
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "start": start()
        case "stop": stop()
        case "open": openMainWindow?()
        case "panel": showPanel?()
        case "onboarding":
            // onboarding:<step>[,skip|setup]: the step, optionally in its second state.
            let p = arg.split(separator: ",").map(String.init)
            onboardingStep = min(max(Int(p.first ?? "") ?? 1, 1), OnboardingView.done)
            onboardingKeySkip = p.contains("skip")
            onboardingSpeakSetup = p.contains("setup") ? true : p.contains("ask") ? false : nil
            openOnboarding?()
        case "step": onboardingStep = Int(arg) ?? 1
        case "samplePlay": ensureListening(); sample.play()
        case "speakers": settings.speakerVoices = arg == "on"
        case "speakerGuess": speakerNamer.guess(arg, force: true)
        case "speakersRender":
            // speakersRender:<session id>=<png>[@width]: the people strip and the first lines with their labels.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let s = store.session(p[0]) else { break }
            let out = p[1].split(separator: "@").map(String.init)
            let width = out.count > 1 ? CGFloat(Double(out[1]) ?? 360) : 360
            let r = ImageRenderer(content: SpeakerPreview(model: self, session: s).environment(\.speakerNames, SpeakerLabels.names(s)).frame(width: width).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out[0]))
            }
        case "voiceprintFile":
            // voiceprintFile:<audio>=<json>: the app's voiceprint of a whole file, to compare with the reference model.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { break }
            DispatchQueue.global().async {
                let samples = Voiceprints.samples(of: URL(fileURLWithPath: p[0]))
                let v = samples.flatMap { s in (try? Voiceprints.load())?.embed(s) }
                let data = try? JSONSerialization.data(withJSONObject: ["seconds": Double(samples?.count ?? 0) / 16000, "v": v ?? []])
                try? data?.write(to: URL(fileURLWithPath: p[1]))
                debugLog("voiceprintFile: \(v == nil ? "failed" : "ok") \(p[0])")
            }
        case "micVerify": installer.install(verifyOnly: true)
        case "settings":
            settingsSection = SettingsSection(rawValue: arg) ?? settingsSection
            openSettings(settingsSection)
        case "diagnostics":
            setDiagnostics(arg != "off")
            debugLog("diagnostics \(settings.diagnostics ? "on" : "off")")
        case "diagReport":
            debugLog("diag report:\n" + diagnostics.report(version: "", model: aiModelName))
        case "micTest": installer.runTest()
        case "micNext": installer.next()
        case "sysMic":
            refreshSystemMic()
            debugLog("system mic state=\(systemMicState) default=\(AudioDevices.defaultInput?.name ?? "-") saved=\(AudioDevices.inputs().first { $0.uid == settings.savedSystemInput }?.name ?? "-") recording=\(systemMic.recordingDevice?.name ?? "-") engine=\(speak.micDeviceName) auto=\(settings.autoSystemMic) wanted=\(wantsSystemMic)")
        case "sysMicSet":
            // Simulates another app or the user moving the system mic (part of a device name).
            if let d = AudioDevices.inputs().first(where: { $0.name.localizedCaseInsensitiveContains(arg) }) { AudioDevices.setDefaultInput(d) }
            refreshSystemMic()
        case "sysMicRestore": restoreSystemMic()
        case "sysMicSwitch": switchSystemMic()
        case "sysMicAuto": setAutoSystemMic(arg != "off")
        case "speakMic":
            settings.speakMic = arg.isEmpty ? "" : systemMic.realInputs.first { $0.name.localizedCaseInsensitiveContains(arg) }?.uid ?? ""
        case "micUsers":
            refreshMicUsers()
            debugLog("mic users virtual=\(virtualMic?.id ?? 0) readers=\(MicUsers.readers().map { "\($0.bundleID)\($0.inputs)" }) users=\(micUsers.map { "\($0.name)=\($0.state)" })")
        case "micGuide":
            refreshMicUsers()
            if let user = micUsers.first(where: { $0.bundleID == arg || $0.name == arg }) { showMicGuide(user) } else { micGuide = nil }
        case "talkKey", "toggleKey":
            let s = arg == "right" ? Shortcut.rightOption : Shortcut(stored: arg)
            let refusal = s.map { setShortcut($0, for: parts[0] == "talkKey" ? .talk : .toggle) } ?? "bad shortcut"
            debugLog("\(parts[0]) \(arg): \(refusal ?? "ok")")
        case "shortcuts":
            debugLog("shortcuts talk=\(settings.talkKey.display) armed=\(talkRight.isRunning || talkCombo.isRegistered) needsPermission=\(talkNeedsPermission) inputMonitoring=\(RightOptionKey.allowed) toggle=\(settings.toggleKey.display) taken=\(toggleKeyTaken)")
        case "aiKeyFile":
            // Dev testing: the key comes from a file so it never passes through the log.
            if let k = try? String(contentsOfFile: arg, encoding: .utf8) { Task { await ai.setKey(k) } }
        case "aiCheck": Task { await ai.check() }
        case "voice":
            // voice:<lang>=<id> chooses ("voice:en=ai:ling:UK_George", "voice:zh=clone"); voice:<lang> logs the choice.
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { setVoice(kv[1], for: kv[0]) }
            debugLog("voice \(kv[0]) → \(voiceID(for: kv[0]) ?? "none") options=\(VoiceCatalog.options(for: kv[0], service: settings.aiService).map(\.id)) clone=\(VoiceReference.exists)")
        case "voiceCloneFile":
            // voiceCloneFile:<wav> uses a recording as "my voice", transcribing it like the sheet does.
            Task {
                let url = URL(fileURLWithPath: arg)
                guard let f = try? AVAudioFile(forReading: url),
                      let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                      (try? f.read(into: buf)) != nil else { debugLog("voiceCloneFile: unreadable"); return }
                let text = await LoopbackTest.transcribe([buf], locale: settings.speakFromLang.locale)
                do { try VoiceReference.save(wav: url, text: text) } catch { debugLog("voiceCloneFile: \(error)") }
                debugLog("voiceCloneFile: saved, transcript \(text.count) chars")
            }
        case "voicePreview":
            // voicePreview:<lang>=<id>
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { previewVoice(kv[1], language: kv[0]) }
        case "notesNow": notes.updateNow()
        case "endSim":
            // endSim:<app name>[,<app name>] pretends those meeting apps are in a call; endSim: none; endSim:off real.
            fakeCalls = arg == "off" ? nil : Dictionary(arg.split(separator: ",").map { ("sim.\($0)", String($0)) }) { a, _ in a }
            debugLog("meeting end: simulated calls \(fakeCalls.map { $0.values.sorted().description } ?? "off")")
        case "endTimes":
            // endTimes:<silence>,<countdown>,<grace> in seconds; endTimes: back to the settings.
            let v = arg.split(separator: ",").compactMap { Double($0) }
            endTimesOverride = v.count == 3 ? (v[0], v[1], v[2]) : nil
        case "endKeep": keepRecording()
        case "endState":
            debugLog("meeting end: running=\(listen.isRunning) autoEnded=\(autoEnded) pending=\(ending.map { "\($0.reason) in \(Int($0.deadline.timeIntervalSinceNow)) s" } ?? "none") inCall=\(endWatch?.inCall.values.sorted() ?? []) silent=\(endWatch.map { Int(Date().timeIntervalSince($0.lastSpeech)) } ?? -1) s config=\(endConfig)")
        case "updateFeed":
            // updateFeed:<release json url>: check a fake release (file:// works), even in a dev build.
            if let url = URL(string: arg) { updates.checker.feed = url }
            updates.checkNow()
        case "updateCheck": updates.checkNow()
        case "updateInstall": updates.install(model: self)
        case "updateState": debugLog("update current=\(Updates.current) found=\(updates.update?.version ?? "-") check=\(updates.check) progress=\(updates.progress.map { String($0) } ?? "-") failure=\(updates.failure ?? "-")")
        case "loginItem":
            if !arg.isEmpty { loginItem.set(arg == "on") }
            loginItem.refresh()
            debugLog("login item enabled=\(loginItem.enabled) needsApproval=\(loginItem.needsApproval)")
        case "about": AboutPanel.show()
        case "display": setDisplayMode(arg)
        case "notesWindow":
            let v = arg.split(separator: ",").compactMap { Double($0) }
            openNotesWindow()
            if v.count == 4 { notesWindow.place(NSRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
        case "notesFrame": debugLog("notes window frame=\(String(describing: notesWindow.frame)) visible=\(notesWindow.isVisible) policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory")")
        case "notesReplay": Task { await notes.replay(arg) }
        case "notesShow": notes.show(arg)
        case "notesCapturable": notesWindow.setCapturable(arg != "off")
        case "notesClose": notesWindow.performClose()
        case "closeWindow":
            // closeWindow:<main|settings|onboarding>: what the window's close button does.
            let w = NSApp.windows.first { w in
                switch arg {
                case "main": w.contentView is NSHostingView<MainWindowView>
                case "settings": w.contentView is NSHostingView<SettingsView>
                default: w.contentView is NSHostingView<OnboardingView>
                }
            }
            w?.performClose(nil)
        case "notesRender":
            // The whole notes column as a PNG, for checking what is below the fold.
            let view = NotesContentView(notes: notes.notes, fresh: notes.fresh, live: store.liveID != nil,
                                        updating: notes.state == .updating)
                .padding(24).frame(width: 460).background(Color.white)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arg))
            }
        case "mainShow": mainShow = arg
        case "recordRender":
            // The recording surface drawn offscreen, for checking it without a person at the mic.
            let host = NSHostingView(rootView: CaptureView(model: self, notes: notes, engine: recorder, feed: capture)
                .frame(width: 1180, height: 720))
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1180, height: 720),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
                w.orderOut(nil)
            }
        case "recordSaving":
            // The passage from a finished recording to the meeting record, drawn offscreen so it
            // can be looked at without stopping a recording in front of the user.
            let id = recordSessionID ?? store.sessions.first?.id ?? ""
            let s = store.session(id)
            let saving = RecordSaving(sessionID: id,
                                      title: s?.displayTitle ?? "会议记录",
                                      duration: s?.duration ?? 0,
                                      lines: s?.lines.count ?? 0,
                                      translated: s?.lines.contains { $0.dst?.isEmpty == false } ?? false,
                                      notes: true,
                                      hasAudio: s?.hasAudio ?? false)
            // The parts land one after another, so the picture is taken after they have all
            // landed.
            let host = NSHostingView(rootView: ZStack {
                Color.white
                RecordSavingView(saving: saving) {}
            }
            .frame(width: 1180, height: 720))
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1180, height: 720),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                    debugLog("record: saving rendered")
                }
                w.orderOut(nil)
            }
        case "recordDemo":
            // Fills the recorder with sample lines and a summary, so the surface can be looked at
            // without a microphone.
            recorder.demo()
        case "recordCauses":
            // Fills the recorder with a talk about why something happened, so the fishbone the
            // notes draw for such a topic can be checked.
            recorder.demoCauses()
            if let id = recordSessionID ?? store.liveID {
                notes.begin(id)
                Task { await notes.replay(id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                debugLog("record: causes topics=\(self.notes.notes.topics.count) "
                    + self.notes.notes.topics.map { "\($0.title) fish=\($0.fishbone?.branches.count ?? 0)" }.joined(separator: ","))
            }
        case "recordWords":
            // The words of the sentence being heard, with the moment each was said.
            let words = recorder.liveWords.map { "\($0.text)@\(String(format: "%.1f", $0.t))" }
            debugLog("record: words \(words.count): \(words.joined(separator: " "))")
        case "recordRuns":
            // What the model gave for the last result: the runs and the time of each.
            recorder.debugRuns()
        case "recordPlay":
            // recordPlay:<seconds>: plays the recording's own audio from that moment.
            let t = Double(arg) ?? 0
            recorder.play(from: t)
            debugLog("record: play from \(t)")
        case "recordEdit":
            // recordEdit:<words>: corrects the first sentence of the recording, to check that
            // the change reaches the meeting record.
            let id = recorder.lines.first?.id ?? ""
            recorder.edit(id, text: arg)
            let stored = recordSession?.lines.first?.src ?? "-"
            debugLog("record: edit \(id) → \(stored)")
        case "recordMerge":
            // recordMerge: joins the first two sentences of the recording.
            guard recorder.lines.count >= 2 else { break }
            recorder.merge(recorder.lines[0].id, with: recorder.lines[1].id)
            debugLog("record: merged → \(recorder.lines.count) lines, store has \(recordSession?.lines.count ?? 0)")
        case "recordSplit":
            // recordSplit: cuts the first sentence of the recording in two.
            guard let first = recorder.lines.first else { break }
            recorder.split(first.id, at: max(1, Array(first.text).count / 2))
            debugLog("record: split → \(recorder.lines.count) lines, store has \(recordSession?.lines.count ?? 0)")
        case "recordExport":
            // recordExport:<kind>:<path>: writes the recording out, to check the formats
            // without the save panel.
            let p = arg.split(separator: "|").map(String.init)
            guard p.count == 2, let session = recordSession else { break }
            let ok = writeExport(session, kind: p[0], to: URL(fileURLWithPath: p[1]))
            debugLog("record: export \(p[0]) → \(ok ? "ok" : "failed") \(p[1])")
        case "recordDisplay":
            // recordDisplay:<original|translated|bilingual>: what the transcript shows.
            recorder.display = RecordEngine.Display(rawValue: arg) ?? .bilingual
            debugLog("record: display=\(recorder.display.rawValue)")
        case "recordTarget":
            // recordTarget:<code|none>: the language the sentences are translated into.
            recordTarget = arg.isEmpty ? "none" : arg
            recorder.target = recordTarget
            debugLog("record: target=\(recordTarget)")
        case "recordLang":
            // recordLang:<code>: fixes the language the recording is made in, so a test does
            // not have to wait for the detector to make up its mind.
            recordHeardLang = arg.isEmpty ? "auto" : arg
            recorder.heardLanguage = recordHeardLang
            recorder.detectsLanguage = recordHeardLang == "auto"
            debugLog("record: lang=\(recordHeardLang)")
        case "recordStart":
            // Starts a real recording, to check the microphone, the session and the audio file.
            startRecording()
            debugLog("record: started session=\(store.liveID ?? "?") state=\(recorder.state)")
        case "recordStop":
            endRecording()
            debugLog("record: stopped session=\(store.liveID ?? "?") lines=\(recorder.lines.count)")
        case "recordPause":
            recorder.pause()
            micState = recorder.state
            debugLog("record: paused state=\(recorder.state)")
        case "recordResume":
            recorder.resume()
            micState = recorder.state
            debugLog("record: resumed state=\(recorder.state)")
        case "recordState":
            debugLog("record: state=\(recorder.state) elapsed=\(Int(recorder.elapsed)) lines=\(recorder.lines.count) "
                + "live=\(recorder.live.prefix(30)) lang=\(recorder.lang?.locale ?? "-") problem=\(recorder.problem ?? "-") "
                + "level=\(String(format: "%.3f", recorder.level)) words=\(recorder.liveWords.count)")
        case "captureState":
            // Both sources as the capture surface sees them.
            debugLog("capture: source=\(capture.source.rawValue) running=\(capture.running) "
                + "feed=\(capture.lines.count) live=\(capture.live.prefix(30)) elapsed=\(Int(capture.elapsed)) "
                + "level=\(String(format: "%.3f", capture.level)) systemRunning=\(listen.isRunning) "
                + "micState=\(recorder.state) micLines=\(recorder.lines.count)")
        case "switchConfirm":
            // switchConfirm:<source>: the question the source switch asks, to see how it reads.
            let to: CaptureSource = arg == "mic" ? .mic : .system
            let from: CaptureSource = to == .mic ? .system : .mic
            let yes = confirmSwitch(from: from, to: to)
            debugLog("switch: confirm \(from.rawValue)→\(to.rawValue) = \(yes)")
        case "listenPause":
            pauseListening()
            debugLog("listen: paused paused=\(listen.isPaused) elapsed=\(Int(listenElapsed))")
        case "listenResume":
            resumeListening()
            debugLog("listen: resumed paused=\(listen.isPaused) elapsed=\(Int(listenElapsed))")
        case "listenState":
            debugLog("listen: running=\(listen.isRunning) paused=\(listen.isPaused) "
                + "elapsed=\(Int(listenElapsed)) lines=\(store.session(store.liveID ?? "")?.lines.count ?? 0) "
                + "status=\(listen.statusText)")
        case "listenStats":
            // Where the system audio dies: the tap's loudness, what the analyzer was given, and
            // what the recognizer answered.
            let s = listen.recognitionStats
            debugLog("listen stats: results=\(s.0) finals=\(s.1) analyzerBuffers=\(s.2) "
                + "analyzerSeconds=\(String(format: "%.1f", s.3)) convertFailures=\(s.4) "
                + "level=\(String(format: "%.3f", capture.level))")
        case "recordScope":
            // The levels the scope draws, so the shape can be checked without a person at the mic.
            let levels = recorder.waveform.map { String(format: "%.2f", $0) }
            debugLog("record: scope \(levels.count): \(levels.joined(separator: " "))")
        case "recordVoices":
            // Who the recorder has heard: the number each voice is shown under.
            let voices = recorder.lines.filter { $0.person != nil }
                .map { "\($0.id)=person\($0.person ?? 0)/voice\($0.voice ?? -1)" }
            debugLog("record: voices lines=\(voices.count): \(voices.joined(separator: " "))")
        case "voiceCompare":
            // voiceCompare:<file a>|<file b>: how alike two voices are to the voiceprint model.
            // The same voice is about 0.7 and up, different people under 0.5.
            let files = arg.split(separator: "|").map(String.init)
            guard files.count == 2 else { break }
            Task {
                guard let v = try? Voiceprints.load() else { debugLog("voice: model failed to load"); return }
                let embs = files.map { f -> [Float]? in
                    guard let s = Voiceprints.samples(of: URL(fileURLWithPath: f)) else { return nil }
                    return v.embed(s)
                }
                guard let a = embs[0], let b = embs[1] else { debugLog("voice: no voiceprint"); return }
                var dot: Float = 0
                vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
                debugLog(String(format: "voice: similarity %.3f", dot))
            }
        case "voiceFiles":
            // voiceFiles:<file>|<file>…: the voices of several clips, put through the model and
            // the clusterer exactly as a recording does, so the thresholds can be checked.
            let files = arg.split(separator: "|").map(String.init)
            guard files.count >= 2 else { break }
            Task {
                guard let v = try? Voiceprints.load() else { debugLog("voice: model failed to load"); return }
                var clusterer = VoiceClusterer()
                for f in files {
                    guard let s = Voiceprints.samples(of: URL(fileURLWithPath: f)),
                          let e = v.embed(s) else { debugLog("voice: no voiceprint for \(f)"); continue }
                    let seconds = Double(s.count) / 16000
                    let voice = clusterer.label(e, seconds: seconds)
                    debugLog(String(format: "voice: %@ %.1fs → voice %@", (f as NSString).lastPathComponent,
                                    seconds, voice.map(String.init) ?? "none"))
                }
            }
        case "recordMic":
            // The microphone the recording takes from; empty is the system default.
            recorder.inputDevice = arg.isEmpty ? nil
                : AudioDevices.inputs().first { $0.name.localizedCaseInsensitiveContains(arg) }
            debugLog("record: input=\(recorder.inputDevice?.name ?? "default")")
        case "recordSummary":
            // Rebuilds the notes from the demo lines with the real service, to check the
            // prompt and the JSON it answers with.
            recorder.demo()
            if let id = recordSessionID ?? store.liveID {
                notes.begin(id)
                Task { await notes.replay(id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                debugLog("record: summary topics=\(self.notes.notes.topics.count) "
                    + self.notes.notes.topics.map { "\($0.title)(\($0.points.count)) fish=\($0.fishbone != nil)" }.joined(separator: ","))
            }
        case "mainRender":
            // The main window as drawn, for checking it without Screen Recording permission.
            guard let view = NSApp.windows.first(where: { $0.contentView is NSHostingView<MainWindowView> })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            // And the shown meeting's whole notes page beside it, for what is below the fold.
            if let id = mainShow?.split(separator: ",").first.map(String.init), let n = store.session(id)?.notes {
                let r = ImageRenderer(content: NotesContentView(notes: n, document: true).padding(32).frame(width: 744).background(Color.white))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let full = NSBitmapImageRep(data: tiff) {
                    try? full.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg + ".notes.png"))
                }
            }
        case "exportPanel":
            // exportPanel:<session id>: the export panel for that meeting.
            if !arg.isEmpty, let s = store.session(arg) { requestExport(s) }
        case "exportSave":
            // exportSave:<session id>: the export panel with the save sheet up, to see the flow.
            guard !arg.isEmpty, let s = store.session(arg) else { break }
            requestExport(s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    self.export(s, kind: self.exportOptions.format.rawValue, options: self.exportOptions) {}
                }
            }
        case "exportRender":
            // exportRender:<session id>=<png>: the export panel as drawn.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let s = store.session(p[0]) else { break }
            exportRequest = ExportRequest(id: s.id, session: s)
            // The live window when there is one: the format picker is a real control and only
            // draws itself in a window.
            if let view = NSApp.windows.first(where: { $0.contentView is NSHostingView<ExportSheet> })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
                break
            }
            let view = ExportSheet(model: self).frame(width: 440, height: 340).background(Color.white)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: p[1]))
            }
        case "panelRender":
            // The menu bar panel drawn offscreen with real AppKit controls: the popover closes
            // as soon as another app is active, so it can't be caught by windowsRender.
            let host = NSHostingView(rootView: MenuPanelView(model: self, settings: settings))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
                w.orderOut(nil)
            }
        case "settingsRender":
            // settingsRender:<section>=<png>: one settings page in full, scroll view or not.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let section = SettingsSection(rawValue: p[0]) else { break }
            settingsSection = section
            let r = ImageRenderer(content: SettingsView(model: self, settings: settings, installer: installer).page
                .frame(width: 530).background(Color(red: 0.965, green: 0.969, blue: 0.976)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
            }
        case "pillRender":
            // The toolbar pill as drawn, for checking it against the capture surface without
            // Screen Recording permission.
            let host = NSHostingView(rootView: ListenPill(model: self))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
                w.orderOut(nil)
            }
        case "floatingPill":
            // The floating pill on its own: floatingPill:on / :off / :move:x,y / (no arg = state).
            let p = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let sub = p.first ?? ""
            switch sub {
            case "on": floatingPill.show()
            case "off": floatingPill.hide()
            case "move":
                // move:x,y puts the pill at a spot, to check it can be dragged there.
                let xy = (p.count > 1 ? p[1] : "").split(separator: ",").compactMap { Double($0) }
                if xy.count == 2, let w = floatingPill.window { w.setFrameOrigin(NSPoint(x: xy[0], y: xy[1])) }
            default:
                debugLog("floating pill visible=\(floatingPill.isVisible) frame=\(String(describing: floatingPill.window?.frame)) toolbarHidden=\(floatingPillVisible) buttons=\(floatingPill.buttonRegions.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
            }
        case "windowsRender":
            // Every visible window as drawn (<dir>/<n>-<class>.png), without Screen Recording permission.
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView, view.bounds.width > 40,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "\(i)-\(String(describing: type(of: w)).prefix(24)).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg).appendingPathComponent(name))
            }
        case "pillFrame":
            // Where the toolbar pill sits on the screen, in Quartz's top-left coordinates,
            // so a click can be aimed at it.
            debugLog(pillFrameReport())
        case "floatingPillFrame":
            // The same for the floating pill, with its buttons.
            debugLog(floatingPillFrameReport())
        case "interfaceLanguage":
            // Puts the interface in a language without a restart, for checking the English UI.
            // It goes through the same door as the settings row, so the pick in memory and the
            // pick on disk stay the same.
            InterfaceLanguage.choose(arg)
            debugLog("interfaceLanguage=\(InterfaceLanguage.current)")
        case "notesState": debugLog("notes state=\(notes.state) topics=\(notes.notes.topics.count) covered=\(notes.notes.covered) glossary=\(notes.glossary.count) timedPoints=\(notes.notes.topics.reduce(0) { $0 + ($1.pointTimes?.compactMap { $0 }.count ?? 0) })/\(notes.notes.topics.reduce(0) { $0 + $1.points.count }) fresh=\(notes.fresh.count)")
        case "aiSimulate", "lingSimulate":
            // Every failure the settings page can show, so each state can be looked at.
            ai.simulate = ["429": .rateLimited, "hijack": .hijacked, "timeout": .timeout,
                           "retired": .retired, "plan": .plan, "quota": .quota,
                           "invalid": .invalidKey, "http": .http(404)][arg]
            debugLog("ai simulate=\(String(describing: ai.simulate))")
        case "aiRemove": ai.removeKey()
        case "aiHide":
            // aiHide:<on|off>: the key file stays; the app behaves as if there were none (for screenshots).
            ai.hideKey = arg != "off"
            Task { await ai.check() }
        case "aiState": debugLog("ai state=\(ai.keyState) hasKey=\(ai.hasKey) service=\(settings.aiService.rawValue) model=\(aiModelName)")
        case "subtitles": setSubtitles(arg)
        case "meetingSubtitles": setSubtitles(arg, meetingOnly: true)
        case "notesLang": setNotesLanguage(arg)
        case "meetingNotesLang": setNotesLanguage(arg, meetingOnly: true)
        case "notesRegenerate":
            let p = arg.split(separator: "=").map(String.init)
            if p.count == 2 { regenerateNotes(p[0], choice: p[1]) }
        case "speakAsk":
            // speakAsk[:off]: the panel's one-time question, as if the switch was flipped for the first time.
            speakAsking = arg != "off"
        case "speakConfirmed": settings.speakConfirmed = arg != "off"
        case "speakOn": enableSpeaking(true)
        case "speakOff": enableSpeaking(false)
        case "speakOut": speak.debugOutputURL = arg.isEmpty ? nil : URL(fileURLWithPath: arg)
        case "speakFile": speak.speakFile(URL(fileURLWithPath: arg))
        case "speakTest":
            // speakTest:<sample|voice>: open settings › 同声传译 with the 试一句 sheet and run it.
            settingsSection = .speak
            openSettingsWindow?()
            speakTestShown = true
            speakTester.start(arg == "voice" ? .voice : .sample)
        case "speakOutput":
            // speakOutput:<part of a device name>, or empty for the virtual mic (automatic).
            settings.speakOutput = arg.isEmpty ? "" : AudioDevices.outputs().first { $0.name.localizedCaseInsensitiveContains(arg) }?.uid ?? ""
            applySystemMic()
            speak.resetOutput()
            debugLog("speak output=\(speak.outputDevice()?.name ?? "-")")
        case "voicePicker": voicePickerOpen = arg != "off"
        case "speakTestBegin": speakTester.beginTalking()
        case "speakTestEnd": speakTester.endTalking()
        case "speakTestClose": speakTester.cancel(); speakTestShown = false
        case "speakTestState":
            debugLog("speak test phase=\(speakTester.phase) reached=\(String(describing: speakTester.reached)) result=\(speakTester.result?.report.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
        case "micGuideRender":
            // micGuideRender:<bundle id>=<png>: the 怎么改 sheet for an app in the list.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let user = micUsers.first(where: { $0.bundleID == p[0] }) else { break }
            let r = ImageRenderer(content: MicGuideView(model: self, bundleID: user.bundleID, name: user.name, close: {}).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
            }
        case "speakTestRender":
            let r = ImageRenderer(content: SpeakTestView(model: self, tester: speakTester, close: {}).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "place":
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { overlay.place(x: n[0], y: n[1], width: n[2], fontSize: n[3]) }
        case "overlayState": debugLog("overlay \(overlay.stateDescription)")
        case "overlayToggle": overlay.toggleManual()
        case "overlayAuto": setOverlayAuto(arg != "off")
        case "hideAfter": settings.overlayHideAfter = Double(arg) ?? 4
        case "frame":
            debugLog("overlay frame=\(overlay.barFrame) font=\(overlay.currentFontSize)")
        case "export":
            guard let s = store.sessions.first(where: { $0.id != store.liveID }) ?? store.sessions.first else { return }
            let dir = URL(fileURLWithPath: arg)
            for (kind, ext) in [("md", "md"), ("srt", "srt"), ("word", "docx")] {
                let ok = writeExport(s, kind: kind, to: dir.appendingPathComponent("export.\(ext)"))
                debugLog("export \(ext) ok=\(ok)")
            }
        case "exportPick":
            // exportPick:ai,text,lines@pdf (or "all"/"none"): what the panel has ticked, and in
            // which format.
            let p = arg.split(separator: "@").map(String.init)
            let picks = p.first?.split(separator: ",").map(String.init) ?? []
            if picks == ["all"] {
                exportOptions = ExportOptions()
            } else if picks == ["none"] {
                exportOptions.aiView = false
                exportOptions.textSummary = false
                exportOptions.transcript = false
            } else {
                exportOptions.aiView = picks.contains("ai")
                exportOptions.textSummary = picks.contains("text")
                exportOptions.transcript = picks.contains("lines")
            }
            if p.count > 1, let f = ExportOptions.Format(rawValue: p[1]) { exportOptions.format = f }
        case "exportStyle":
            // exportStyle:radial|tree|fishbone|graph|auto: how the exported AI view draws each topic.
            if let s = MindMapStyle(rawValue: arg) {
                exportOptions.mindMapStyle = s
                aiViewStyle = s
            }
        case "exportWrite":
            // exportWrite:<session id>=<path>: write the export with the panel's choices, no save panel.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let s = store.session(p[0]) else { break }
            let ok = writeExport(s, kind: exportOptions.format.rawValue, options: exportOptions, to: URL(fileURLWithPath: p[1]))
            debugLog("export write ok=\(ok) kind=\(exportOptions.format.rawValue) ai=\(exportOptions.aiView) text=\(exportOptions.textSummary) lines=\(exportOptions.transcript)")
        default: break
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    /// Kept alive for the app's life: Core Audio holds the blocks, not the other way round.
    private var deviceListeners: [AudioObjectPropertyListenerBlock] = []
    private var deviceWork: DispatchWorkItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// The export panel: its own window, so it can be opened from the records window, the
    /// recording page and the menu bar alike.
    private var exportWindow: NSWindow?
    private var pollTimer: Timer?
    private var runningObserver: Any?
    private var popoverClickMonitor: Any?
    private lazy var menu = AppMenu(model: model)
    /// Held here: a toolbar keeps only a weak reference to its delegate.
    private lazy var mainToolbar = MainToolbar(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.showMainWindow = { [weak self] in self?.showMainWindow() }
        menu.showOnboarding = { [weak self] in self?.showOnboarding() }
        menu.install()
        setupStatusItem()
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        model.showExportPanel = { [weak self] in self?.presentExportPanel() }
        model.toggleMainWindow = { [weak self] in self?.toggleMainWindow() }
        model.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        model.showPanel = { [weak self] in self?.togglePopover() }
        model.openPanel = { [weak self] in self?.openPopover() }
        model.showMenu = { [weak self] anchor in
            self?.showAppMenu(under: anchor)
        }
        model.openOnboarding = { [weak self] in self?.showOnboarding() }
        runningObserver = model.$running.combineLatest(model.updates.$update).sink { [weak self] live, update in
            self?.statusItem.button?.image = BrandImage.menuBar(live: live, badge: update != nil)
        }
        // Touch the floating pill so it subscribes and can auto-show when a capture starts.
        _ = model.floatingPill
        let poll = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }
        pollTimer = poll
        RunLoop.main.add(poll, forMode: .common)
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.showOnboarding() }
            }
        } else if !Self.launchedAsLoginItem {
            // Opened by hand (Finder, Launchpad, Spotlight): show something, like the Dock icon does.
            showMainWindow()
        }
        model.installDebugControl()
        installDeviceListener()
        Task { await model.launch() }
        model.updates.start()
    }

    /// Started by the system at login: stay in the menu bar.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        // Other apps would be left on the virtual mic, hearing nothing.
        model.systemMic.release()
    }

    /// Dock icon or Finder: bring back what is open; the main window only when nothing is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let open = [mainWindow, settingsWindow, onboardingWindow].compactMap { $0 }.filter { $0.isVisible || $0.isMiniaturized }
        if open.isEmpty { showMainWindow() } else { open.forEach { $0.deminiaturize(nil) }; NSApp.activate() }
        return false
    }

    /// Quitting ends the meeting being recorded: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.updates.installing, model.running, let id = model.store.liveID, !(model.store.session(id)?.lines.isEmpty ?? true) else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("正在记录会议")
        alert.informativeText = L("退出会结束这场记录，已记下的内容会保存。")
        alert.addButton(withTitle: L("退出"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = BrandImage.menuBar(live: false)
            if DevBuild.isDev {
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(string: " DEV", attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                    .baselineOffset: 1,
                ])
                button.toolTip = "\(appDisplayName) · \(DevBuild.label ?? "")"
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover.behavior = .transient
        popover.animates = false
        let panel = NSHostingController(rootView: MenuPanelView(model: model, settings: model.settings))
        // The popover follows the panel's height as it changes (a status line, the virtual-mic
        // warning). Without this the hosting view resized the popover window from its bottom
        // edge, pushing the top of the panel above the screen.
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        // .transient closes on focus changes, but the notes panel and the subtitle bar never take
        // focus: a click on them would leave the popover open on top. Close it ourselves.
        popoverClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, self.popover.isShown, let w = e.window, w !== self.popover.contentViewController?.view.window,
               w !== self.statusItem.button?.window {
                self.popover.performClose(nil)
            }
            return e
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Shows the panel, or leaves it where it is: the caller asked to see it, not to flip it.
    private func openPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refreshOutputs()
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Shows the app's own menu (纪要 / 显示 / 窗口 …) under a point on the screen.
    ///
    /// The menu bar is where the commands live, but the records window is where people are when
    /// they want them, so the same menu is shown here: the 纪要 menu with its ⌘R, the 显示
    /// menu, the window list.
    func showAppMenu(under anchor: NSRect) {
        guard let main = NSApp.mainMenu else { return }
        // The first item is the app's own menu; the commands start at 纪要.
        guard let notes = main.items.first(where: { $0.title == L("纪要") })?.submenu else { return }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        // The menu pops open where the mouse is, the way a menu bar menu does.
        let point = NSPoint(x: anchor.minX, y: anchor.minY)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSMenu.popUpContextMenu(notes, with: event, for: view)
    }

    // MARK: Main window

    /// Creates the main window once, reusing it afterwards: opening the record after a recording
    /// ends should show the same window, not build a new one.
    func ensureMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = appDisplayName
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainWindowView(model: model, store: model.store, settings: model.settings))
            w.toolbar = mainToolbar.make()
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .none
            w.center()
            w.setFrameAutosaveName("LiveSubsMain")
            mainWindow = w
        }
    }

    /// Brings the records window to the front. It never minimises: everything that names a
    /// meeting — the notes window, the panel, the menu — means "show me that one".
    func showMainWindow() {
        popover.performClose(nil)
        ensureMainWindow()
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The export panel, in a window of its own so it can be opened from anywhere. It asks
    /// what goes into the file and in which format; the file itself is chosen afterwards.
    func presentExportPanel() {
        guard model.exportRequest != nil else { return }
        if exportWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("导出会议记录")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            exportWindow = w
        }
        exportWindow?.contentViewController = NSHostingController(rootView: ExportSheet(model: model) { [weak self] in
            self?.closeExportPanel()
        })
        // A regular app while the panel is up: it takes focus, and the save sheet hangs off it.
        NSApp.setActivationPolicy(.regular)
        exportWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func closeExportPanel() {
        model.exportRequest = nil
        exportWindow?.close()
    }

    /// The pill's way back to the records: a double click opens the window, and a double click
    /// on the open window puts it away again.
    func toggleMainWindow() {
        if let w = mainWindow, w.isVisible, w.isKeyWindow {
            w.miniaturize(nil)
            return
        }
        showMainWindow()
    }

    func showSettingsWindow() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("设置")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model, settings: model.settings, installer: model.installer))
            w.center()
            w.setFrameAutosaveName("LiveSubsSettings")
            settingsWindow = w
        }
        model.refreshOutputs()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showOnboarding() {
        popover.performClose(nil)
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("欢迎使用\(appDisplayName)")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView(
                model: model, settings: model.settings, installer: model.installer, sample: model.sample,
                onFinish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    self?.onboardingWindow?.close()
                }))
            w.center()
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        let w = notification.object as? NSWindow
        updateActivationPolicy(closing: w)
        if w == exportWindow {
            model.exportRequest = nil
        }
        if w == onboardingWindow {
            model.sample.stop()
            UserDefaults.standard.set(true, forKey: "onboarded")
            // Done (or 稍后): land on the records window rather than nothing but the menu bar icon.
            if mainWindow?.isVisible != true {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.showMainWindow() } }
            }
        }
    }

    /// A regular app (name and menus top left, Dock icon, ⌘Tab) while the main, settings or
    /// onboarding window is open; only the menu bar item otherwise. The notes window doesn't
    /// count: it floats beside the meeting app and never takes focus from it.
    func updateActivationPolicy(closing: NSWindow? = nil) {
        let open = [mainWindow, onboardingWindow, settingsWindow, exportWindow].contains { $0 != nil && $0 != closing && $0!.isVisible }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        debugLog("activation policy → \(open ? "regular" : "accessory")")
    }

    // MARK: Output device changes

    private func installDeviceListener() {
        // The tap follows the device the user hears (the system output, or the default output
        // when there is no separate one), so both can change which device it listens to.
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        for selector in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.outputDeviceChanged() }
            }
            deviceListeners.append(block)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
    }

    private func outputDeviceChanged() {
        deviceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                debugLog("default output device changed → reconnecting tap")
                self?.model.listen.reconnectAudio()
                self?.model.refreshOutputs()
            }
        }
        deviceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

@main
struct LiveSubsMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-dmg-background"), args.count > i + 1 {
            let scale = args.count > i + 2 ? Int(args[i + 2]) ?? 1 : 1
            do {
                try DMGBackground.render(to: URL(fileURLWithPath: args[i + 1]), scale: scale)
                exit(0)
            } catch {
                FileHandle.standardError.write("render failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        // AppKit adds "进入全屏幕" to a menu titled 显示 (View) unless told before launch;
        // no Live Subs window goes full screen.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
