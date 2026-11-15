import AppKit
import Foundation

enum SourceMode: Equatable {
    case auto
    case fixed(Lang)
}

/// Persisted user choices. Everything the menu panel and settings sheet edit lives here.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var sourceMode: SourceMode {
        didSet { save() }
    }
    /// "system" or a translation code.
    @Published var target: String {
        didSet { save() }
    }
    /// What the subtitles show: "both" (original + translation), "translation", or "original"
    /// (nothing is translated, so no translator is called).
    @Published var subtitles: String {
        didSet { save() }
    }
    /// The language notes are written in: "mine" (the translate-to language, or the system's when
    /// that follows the system) or "source" (the meeting's own language).
    @Published var notesLanguage: String {
        didSet { save() }
    }
    @Published var speakEnabled: Bool {
        didSet { save() }
    }
    /// The user has seen what turning 同声传译 on changes (the panel asks once, in place).
    @Published var speakConfirmed: Bool {
        didSet { save() }
    }
    /// Locale of the language I speak.
    @Published var speakFrom: String {
        didSet { save() }
    }
    /// "room" (follow the detected room language) or a translation code.
    @Published var speakTo: String {
        didSet { save() }
    }
    /// Output device UID for spoken translations, "" = automatic.
    @Published var speakOutput: String {
        didSet { save() }
    }
    /// While speaking, make the virtual mic the system default input (and put it back after).
    @Published var autoSystemMic: Bool {
        didSet { save() }
    }
    /// The microphone Cicada records my voice from (UID), "" = the real mic the system had.
    @Published var speakMic: String {
        didSet { save() }
    }
    /// The real system input replaced by the virtual mic, kept until it's put back (survives a crash).
    @Published var savedSystemInput: String {
        didSet { save() }
    }
    @Published var recordAudio: Bool {
        didSet { save() }
    }
    /// 录音结束后在后台自动润色转写（同音字/错字/标点），不改说话人和时间；原文保留可对照。
    @Published var recordAutoCorrect: Bool {
        didSet { save() }
    }
    /// Subtitle bar: show only while someone talks ("auto") or always.
    @Published var overlayAuto: Bool {
        didSet { save() }
    }
    @Published var overlayHideAfter: Double {
        didSet { save() }
    }

    /// Hold to talk: the right ⌥ key (default) or a key combination.
    @Published var talkKey: Shortcut {
        didSet { save() }
    }
    /// Hide / show the subtitle bar.
    @Published var toggleKey: Shortcut {
        didSet { save() }
    }

    /// What shows while listening: "notes" (live notes window, default), "bar" (subtitle bar), "none".
    @Published var displayMode: String {
        didSet { save() }
    }
    /// The voice the room hears, per language ("en" → "ming:US_Emma", "system:<id>" or "clone").
    /// A language not listed uses `VoiceCatalog.defaultID`.
    @Published var speakVoices: [String: String] {
        didSet { save() }
    }
    /// The AI service the notes and the translation go to.
    @Published var aiService: AIService {
        didSet { save() }
    }
    /// The model per service, so switching back and forth keeps each one's choice.
    @Published var aiModels: [String: String] {
        didSet { save() }
    }
    /// The address of the "自定义" service, and the model name that goes with it.
    @Published var aiBaseURL: String {
        didSet { save() }
    }
    @Published var aiCustomModel: String {
        didSet { save() }
    }

    /// End the meeting when the meeting app it was heard through hangs up.
    @Published var endWithApp: Bool {
        didSet { save() }
    }
    /// When nobody has said anything for `silenceMinutes`: "prompt" (count down, then end),
    /// "pause" (count down, then hold the session on hold), "end" or "off". See `MeetingEndWatch`.
    @Published var silenceEnd: String {
        didSet { save() }
    }
    @Published var silenceMinutes: Double {
        didSet { save() }
    }

    /// Let screen recordings (and so screen sharing too: macOS has one switch for both) capture the
    /// notes window. Off by default; kept across launches like 始终置顶, so the window shows a badge.
    @Published var notesCapturable: Bool {
        didSet { save() }
    }

    /// Experimental: tell the other side's voices apart (说话人 1、2…). Off by default.
    @Published var speakerVoices: Bool {
        didSet { save() }
    }

    /// Record per-sentence timings (never text) and show the 诊断 tab. On by default in dev builds.
    @Published var diagnostics: Bool {
        didSet { save() }
    }

    var debug: Bool { defaults.bool(forKey: "debug") }

    init() {
        if let s = defaults.string(forKey: "sourceMode"), s != "auto",
           let lang = sourceLanguages.first(where: { $0.locale == s }) {
            sourceMode = .fixed(lang)
        } else {
            sourceMode = .auto
        }
        target = defaults.string(forKey: "target") ?? "system"
        subtitles = defaults.string(forKey: "subtitles") ?? "both"
        notesLanguage = defaults.string(forKey: "notesLanguage") ?? "mine"
        speakEnabled = defaults.bool(forKey: "speakEnabled")
        // Anyone who had it on before this question existed already knows.
        speakConfirmed = defaults.object(forKey: "speakConfirmed") as? Bool ?? defaults.bool(forKey: "speakEnabled")
        speakFrom = defaults.string(forKey: "speakFrom")
            ?? speakLocale(forLanguage: LiveSubs.myLanguage(systemLanguages: systemLanguages()))
        speakTo = defaults.string(forKey: "speakTo") ?? "room"
        speakOutput = defaults.string(forKey: "speakOutput") ?? ""
        autoSystemMic = defaults.object(forKey: "autoSystemMic") as? Bool ?? true
        speakMic = defaults.string(forKey: "speakMic") ?? ""
        savedSystemInput = defaults.string(forKey: "savedSystemInput") ?? ""
        recordAudio = defaults.object(forKey: "recordAudio") as? Bool ?? true
        recordAutoCorrect = defaults.bool(forKey: "recordAutoCorrect")
        overlayAuto = defaults.object(forKey: "overlayAuto") as? Bool ?? true
        overlayHideAfter = defaults.object(forKey: "overlayHideAfter") as? Double ?? 4
        talkKey = Shortcut(stored: defaults.string(forKey: "talkKey")) ?? .defaultTalk
        toggleKey = Shortcut(stored: defaults.string(forKey: "toggleKey")) ?? .defaultToggle
        aiService = defaults.string(forKey: "aiService").flatMap { AIService(rawValue: $0) } ?? .ling
        var models = defaults.dictionary(forKey: "aiModels") as? [String: String] ?? [:]
        // Builds before the services were split kept one model name, and it was Ling's.
        if models.isEmpty, let legacy = defaults.string(forKey: "aiModel") { models[AIService.ling.rawValue] = legacy }
        // The MiniMax models the app used are gone; the ones the platform still serves take their
        // place, so a picked name that no longer exists does not break every call.
        if let picked = models[AIService.minimax.rawValue], !MiniMaxProvider.availableModels.contains(picked) {
            models[AIService.minimax.rawValue] = MiniMaxProvider.defaultModelName
        }
        aiModels = models
        aiBaseURL = defaults.string(forKey: "aiBaseURL") ?? ""
        aiCustomModel = defaults.string(forKey: "aiCustomModel") ?? ""
        displayMode = defaults.string(forKey: "displayMode") ?? "notes"
        speakVoices = (defaults.dictionary(forKey: "speakVoices") as? [String: String] ?? [:]).mapValues { id in
            // Builds before the services were split wrote Ming's voices as "ming:<id>".
            guard id.hasPrefix("ming:") else { return Self.renamedVoice(id) }
            return "ai:\(AIService.ling.rawValue):\(id.dropFirst("ming:".count))"
        }
        endWithApp = defaults.object(forKey: "endWithApp") as? Bool ?? true
        silenceEnd = defaults.string(forKey: "silenceEnd") ?? "prompt"
        silenceMinutes = defaults.object(forKey: "silenceMinutes") as? Double ?? 10
        diagnostics = defaults.object(forKey: "diagnostics") as? Bool ?? DevBuild.isDev
        notesCapturable = defaults.bool(forKey: "notesCapturable")
        speakerVoices = defaults.bool(forKey: "speakerVoices")
    }

    private func save() {
        switch sourceMode {
        case .auto: defaults.set("auto", forKey: "sourceMode")
        case .fixed(let lang): defaults.set(lang.locale, forKey: "sourceMode")
        }
        defaults.set(target, forKey: "target")
        defaults.set(subtitles, forKey: "subtitles")
        defaults.set(notesLanguage, forKey: "notesLanguage")
        defaults.set(speakEnabled, forKey: "speakEnabled")
        defaults.set(speakConfirmed, forKey: "speakConfirmed")
        defaults.set(speakFrom, forKey: "speakFrom")
        defaults.set(speakTo, forKey: "speakTo")
        defaults.set(speakOutput, forKey: "speakOutput")
        defaults.set(autoSystemMic, forKey: "autoSystemMic")
        defaults.set(speakMic, forKey: "speakMic")
        defaults.set(savedSystemInput, forKey: "savedSystemInput")
        defaults.set(recordAudio, forKey: "recordAudio")
        defaults.set(recordAutoCorrect, forKey: "recordAutoCorrect")
        defaults.set(overlayAuto, forKey: "overlayAuto")
        defaults.set(overlayHideAfter, forKey: "overlayHideAfter")
        defaults.set(talkKey.stored, forKey: "talkKey")
        defaults.set(toggleKey.stored, forKey: "toggleKey")
        defaults.set(aiService.rawValue, forKey: "aiService")
        defaults.set(aiModels, forKey: "aiModels")
        defaults.set(aiBaseURL, forKey: "aiBaseURL")
        defaults.set(aiCustomModel, forKey: "aiCustomModel")
        defaults.set(displayMode, forKey: "displayMode")
        defaults.set(speakVoices, forKey: "speakVoices")
        defaults.set(endWithApp, forKey: "endWithApp")
        defaults.set(silenceEnd, forKey: "silenceEnd")
        defaults.set(silenceMinutes, forKey: "silenceMinutes")
        defaults.set(diagnostics, forKey: "diagnostics")
        defaults.set(notesCapturable, forKey: "notesCapturable")
        defaults.set(speakerVoices, forKey: "speakerVoices")
    }

    /// The model to use for a service: the one the user picked, or the service's own default. A
    /// pick the service no longer offers (the platform retired the model) falls back too, so the
    /// app never calls a model that is gone.
    func aiModel(for service: AIService, fallback: String, allowed: [String] = []) -> String {
        let picked = aiModels[service.rawValue] ?? ""
        guard !picked.isEmpty else { return fallback }
        if !allowed.isEmpty, !allowed.contains(picked) { return fallback }
        return picked
    }

    /// A voice the platform renamed: the old id is not on the list any more, so the choice follows
    /// it to the new name.
    private static func renamedVoice(_ id: String) -> String {
        let prefix = "ai:\(AIService.minimax.rawValue):"
        guard id.hasPrefix(prefix) else { return id }
        let voice = String(id.dropFirst(prefix.count))
        guard let fresh = VoiceCatalog.minimaxRenames[voice] else { return id }
        return prefix + fresh
    }

    /// Target language. "Follow system" translates into my language, or into the next system
    /// language when they speak mine.
    func resolvedTarget(source: String?) -> String {
        target == "system" ? followSystemTarget(source: source, systemLanguages: systemLanguages()) : target
    }

    /// The reader's own language: the translate-to choice, or with "follow system" the one
    /// `myLanguage(systemLanguages:)` picks. Notes in 我的语言 use it too.
    var myLanguage: String {
        target == "system" ? LiveSubs.myLanguage(systemLanguages: systemLanguages()) : target
    }

    /// "简体中文 / English": my language, then what it translates into when they speak mine.
    func systemTargetDescription() -> String {
        let prefs = systemLanguages()
        let mine = LiveSubs.myLanguage(systemLanguages: prefs)
        return [mine, followSystemTarget(source: mine, systemLanguages: prefs)].map(targetName).joined(separator: " / ")
    }

    var speakFromLang: Lang {
        sourceLanguages.first(where: { $0.locale == speakFrom }) ?? sourceLanguages[0]
    }
}

func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = DevBuild.logPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Transcript content is only logged when `defaults write com.wquguru.cicada debug -bool true`.
func contentLog(_ message: @autoclosure () -> String) {
    if UserDefaults.standard.bool(forKey: "debug") { debugLog(message()) }
}
