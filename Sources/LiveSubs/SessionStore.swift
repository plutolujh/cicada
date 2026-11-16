import AppKit
import Foundation

struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String
    /// Seconds from the start of the session.
    var t: Double
    /// "them" (system audio) or "me" (microphone).
    var speaker: String
    var src: String
    var dst: String?
    var srcLang: String
    var dstLang: String
    /// Experimental: which of the other side's voices said it (SpeakerID.swift); nil when unknown.
    var voice: Int? = nil
    /// AI 纠错后的文本；nil = 未纠错或纠错后无变化。保留原始 `src` 以便对照/回滚。
    var corrected: String? = nil
}

/// A name Ling found for a voice, and the line it is based on ("00:06 “Sure, Emma…”").
struct VoiceGuess: Codable, Equatable {
    var name: String
    var evidence: String
}

struct Session: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var lines: [TranscriptLine]
    var hasAudio: Bool
    /// AI notes (absent in older sessions and without an API key).
    var notes: MeetingNotes?
    /// The user renamed it; nil in older sessions, where any title but the default counts as renamed.
    var renamed: Bool?
    /// Experimental 说话人识别: names the user gave voices, keyed by voice id. An empty name means
    /// "not Ling's guess": the voice shows as 说话人 N.
    var voiceNames: [String: String]? = nil
    /// Names Ling read from the conversation, keyed by voice id; shown until the user says otherwise.
    var voiceGuesses: [String: VoiceGuess]? = nil
    /// When the meeting was moved to the trash; nil for meetings still in the list.
    var deletedAt: Date? = nil
    /// Pinned meetings stay at the top of the list, out of the time groups.
    var pinned: Bool? = nil

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// The user's own title, else the date and the name the notes gave the meeting
    /// ("11月1日 产品路线评审", in the notes' language), else "会议 11月1日 14:30".
    var displayTitle: String {
        if renamed ?? !title.hasPrefix("会议 ") { return title }
        // The stored default title is Chinese ("会议 11月1日 14:30"); shown in the UI language.
        guard let name = notes?.title, !name.isEmpty else { return L("会议 \(dateText(startedAt, "MMMdHHmm"))") }
        let thisYear = Calendar.current.isDate(startedAt, equalTo: Date(), toGranularity: .year)
        return "\(dateText(startedAt, thisYear ? "MMMd" : "yMMMd")) \(name)"
    }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "会议 \(f.string(from: date))"
    }
}

/// One folder per meeting under ~/Library/Application Support/LiveSubs/Sessions/<id>/:
/// session.json, system.m4a (what you heard) and mic.m4a (what you said). Deleted meetings
/// are moved to ~/Library/Application Support/LiveSubs/Trash/<id>/ until restored or removed.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var trashedSessions: [Session] = []
    @Published private(set) var liveID: String?

    let root: URL
    let trashRoot: URL
    private var saveWork: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = base.appendingPathComponent(DevBuild.supportFolder, isDirectory: true)
        root = support.appendingPathComponent("Sessions", isDirectory: true)
        trashRoot = support.appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func trashFolder(_ id: String) -> URL { trashRoot.appendingPathComponent(id, isDirectory: true) }
    func systemAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("system.m4a") }
    func micAudioURL(_ id: String) -> URL { folder(id).appendingPathComponent("mic.m4a") }

    /// Total size on disk of a meeting's folder (audio, transcript, notes, etc.).
    func folderSize(_ id: String) -> Int64 {
        let url = folder(id)
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { continue }
            total += Int64(vals?.fileSize ?? 0)
        }
        return total
    }

    private func load() {
        sessions = loadSessions(in: root).sorted { $0.startedAt > $1.startedAt }
        trashedSessions = loadSessions(in: trashRoot).sorted { ($0.deletedAt ?? $0.startedAt) > ($1.deletedAt ?? $1.startedAt) }
    }

    private func loadSessions(in directory: URL) -> [Session] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Session] = []
        for dir in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
               var s = try? decoder.decode(Session.self, from: data) {
                if directory == root {
                    if s.endedAt == nil { s.endedAt = s.lines.last.map { s.startedAt.addingTimeInterval($0.t + 5) } ?? s.startedAt }
                    // The app quit mid-meeting: its recording is still in the partial file.
                    if s.id != liveID, hasPartialAudio(s.id) {
                        s.hasAudio = true
                        finishAudio(s.id)
                    }
                }
                out.append(s)
            }
        }
        return out
    }

    // MARK: Live session

    @discardableResult
    func begin() -> Session {
        let now = Date()
        let fid = DateFormatter()
        fid.dateFormat = "yyyyMMdd-HHmmss"
        let s = Session(id: fid.string(from: now), title: Session.defaultTitle(now),
                        startedAt: now, endedAt: nil, lines: [], hasAudio: false)
        sessions.insert(s, at: 0)
        liveID = s.id
        try? FileManager.default.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        return s
    }

    /// `at`: when the meeting really ended, for one that ended by itself after a hang-up or a
    /// long silence; the recordings are cut there too.
    func end(at: Date? = nil) {
        guard let id = liveID, let i = index(id) else { liveID = nil; return }
        let now = Date()
        sessions[i].endedAt = at.map { min(now, max(sessions[i].startedAt, $0)) } ?? now
        liveID = nil
        if sessions[i].lines.isEmpty {
            // Nothing was said: don't keep an empty meeting around.
            try? FileManager.default.removeItem(at: folder(id))
            sessions.remove(at: i)
            return
        }
        sessions[i].hasAudio = [systemAudioURL(id), micAudioURL(id)].contains {
            FileManager.default.fileExists(atPath: $0.path) || FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path)
        }
        saveNow(id)
        finishAudio(id, until: at == nil ? nil : sessions[i].duration)
    }

    private func hasPartialAudio(_ id: String) -> Bool {
        [systemAudioURL(id), micAudioURL(id)].contains { FileManager.default.fileExists(atPath: AudioFileWriter.partial($0).path) }
    }

    /// Turns the meeting's recordings into .m4a files (call after the recorders are closed).
    func finishAudio(_ id: String, until: Double? = nil) {
        let urls = [systemAudioURL(id), micAudioURL(id)]
        Task.detached(priority: .utility) { for u in urls { await AudioFileWriter.finish(u, until: until) } }
    }

    var liveStart: Date? { liveID.flatMap { index($0) }.map { sessions[$0].startedAt } }

    func append(_ line: TranscriptLine) {
        guard let id = liveID, let i = index(id) else { return }
        sessions[i].lines.append(line)
        scheduleSave(id)
    }

    func setTranslation(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        scheduleSave(id)
    }

    /// The same, but for a session that is not the live one: a recording can be corrected
    /// after it has ended.
    func setTranslation(in sessionID: String, lineID: String, _ text: String) {
        guard let i = index(sessionID),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].dst = text
        scheduleSave(sessionID)
    }

    /// A line joined with the one after it (`HeardText.join`).
    func setSource(lineID: String, _ text: String) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        scheduleSave(id)
    }

    /// The same, but for a session that is not the live one: a recording can be corrected
    /// after it has ended.
    func setSource(in sessionID: String, lineID: String, _ text: String) {
        guard let i = index(sessionID),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].src = text
        scheduleSave(sessionID)
    }

    func setVoice(lineID: String, _ voice: Int) {
        guard let id = liveID, let i = index(id),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].voice = voice
        scheduleSave(id)
    }

    /// Replaces the lines of the live session, for when the user merged or split them.
    ///
    /// The lines are written out one by one, so a line that has no place in the new set is
    /// removed rather than left behind.
    func replaceLines(_ lines: [TranscriptLine]) {
        guard let id = liveID, let i = index(id) else { return }
        sessions[i].lines = lines
        scheduleSave(id)
    }

    /// The same, but for a session that is not the live one: a recording can be corrected
    /// after it has ended.
    func replaceLines(in sessionID: String, _ lines: [TranscriptLine]) {
        guard let i = index(sessionID) else { return }
        sessions[i].lines = lines
        scheduleSave(sessionID)
    }

    /// The same, but for a session that is not the live one: a recording can be corrected
    /// after it has ended.
    func setCorrected(in sessionID: String, lineID: String, _ text: String?) {
        guard let i = index(sessionID),
              let j = sessions[i].lines.firstIndex(where: { $0.id == lineID }) else { return }
        sessions[i].lines[j].corrected = text
        scheduleSave(sessionID)
    }

    /// Applies AI corrections to recorded lines of an ended session. `nil` clears the correction
    /// for that line (undo). Lines not found are skipped.
    func updateCorrections(in sessionID: String, _ corrections: [(lineID: String, corrected: String?)]) {
        guard let i = index(sessionID) else { return }
        for c in corrections {
            guard let j = sessions[i].lines.firstIndex(where: { $0.id == c.lineID }) else { continue }
            sessions[i].lines[j].corrected = c.corrected
        }
        scheduleSave(sessionID)
    }

    /// The user names a voice. nil drops their name (Ling's guess shows again); "" keeps 说话人 N.
    func setVoiceName(_ id: String, voice: Int, _ name: String?) {
        guard let i = index(id) else { return }
        var names = sessions[i].voiceNames ?? [:]
        names[String(voice)] = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].voiceNames = names.isEmpty ? nil : names
        saveNow(id)
    }

    /// Ling's latest guesses; earlier ones stay for voices it no longer mentions, unless it now named
    /// them without evidence (`refuted`, voice → name): then that earlier name goes too.
    func setVoiceGuesses(_ id: String, _ guesses: [Int: VoiceGuess], refuted: [Int: String] = [:]) {
        guard let i = index(id), !guesses.isEmpty || !refuted.isEmpty else { return }
        var all = sessions[i].voiceGuesses ?? [:]
        for (v, name) in refuted where guesses[v] == nil && all[String(v)]?.name == name { all[String(v)] = nil }
        for (v, g) in guesses { all[String(v)] = g }
        guard all != sessions[i].voiceGuesses else { return }
        sessions[i].voiceGuesses = all.isEmpty ? nil : all
        saveNow(id)
    }

    /// The user said two voices are the same person: `from`'s lines become `into`'s.
    func mergeVoice(_ id: String, _ from: Int, into: Int) {
        guard let i = index(id), from != into else { return }
        for j in sessions[i].lines.indices where sessions[i].lines[j].voice == from { sessions[i].lines[j].voice = into }
        if var names = sessions[i].voiceNames, let moved = names.removeValue(forKey: String(from)) {
            // A turned-down guess ("") stays with the voice it was about; a real name moves over.
            if names[String(into)] == nil, !moved.isEmpty { names[String(into)] = moved }
            sessions[i].voiceNames = names.isEmpty ? nil : names
        }
        if var guesses = sessions[i].voiceGuesses, let moved = guesses.removeValue(forKey: String(from)) {
            if guesses[String(into)] == nil { guesses[String(into)] = moved }
            sessions[i].voiceGuesses = guesses.isEmpty ? nil : guesses
        }
        saveNow(id)
    }

    func setNotes(_ id: String, _ notes: MeetingNotes) {
        guard let i = index(id) else { return }
        sessions[i].notes = notes
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    // MARK: Editing

    /// An empty title, or the one shown already, goes back to the automatic one.
    func rename(_ id: String, to title: String) {
        guard let i = index(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != sessions[i].displayTitle else { return }
        if t.isEmpty {
            sessions[i].title = Session.defaultTitle(sessions[i].startedAt)
            sessions[i].renamed = false
        } else {
            sessions[i].title = t
            sessions[i].renamed = true
        }
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    /// Pins or unpins a meeting. Pinned meetings are shown in their own group at the top.
    func togglePin(_ id: String) {
        guard let i = index(id) else { return }
        sessions[i].pinned = !(sessions[i].pinned ?? false)
        id == liveID ? scheduleSave(id) : saveNow(id)
    }

    /// Moves a meeting to the trash instead of deleting it outright, so it can be restored.
    func delete(_ id: String) {
        guard id != liveID, let i = index(id) else { return }
        var s = sessions.remove(at: i)
        s.deletedAt = Date()
        try? FileManager.default.createDirectory(at: trashFolder(s.id), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: folder(s.id), to: trashFolder(s.id))
        saveNow(s.id)
        trashedSessions.append(s)
        trashedSessions.sort { ($0.deletedAt ?? $0.startedAt) > ($1.deletedAt ?? $1.startedAt) }
    }

    /// Moves multiple meetings to the trash at once. Live sessions are skipped.
    func delete(_ ids: Set<String>) {
        // Remove by descending index so earlier removals don't shift later ones.
        let targetIds = ids.filter { $0 != liveID }
        let indices = targetIds.compactMap(index).sorted(by: >)
        guard !indices.isEmpty else { return }
        var moved: [Session] = []
        for i in indices {
            var s = sessions.remove(at: i)
            s.deletedAt = Date()
            try? FileManager.default.createDirectory(at: trashFolder(s.id), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: folder(s.id), to: trashFolder(s.id))
            saveNow(s.id)
            moved.append(s)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trashedSessions.append(contentsOf: moved)
        trashedSessions.sort { ($0.deletedAt ?? $0.startedAt) > ($1.deletedAt ?? $1.startedAt) }
    }

    /// Restore a meeting from the trash back to the meetings list.
    func restore(_ id: String) {
        guard let i = trashedIndex(id) else { return }
        var s = trashedSessions.remove(at: i)
        s.deletedAt = nil
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: trashFolder(s.id), to: folder(s.id))
        saveNow(s.id)
        sessions.insert(s, at: 0)
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    /// Permanently remove everything left in the trash.
    func emptyTrash() {
        for s in trashedSessions {
            try? FileManager.default.removeItem(at: trashFolder(s.id))
        }
        trashedSessions.removeAll()
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions.first(where: { $0.id == id }) ?? trashedSessions.first(where: { $0.id == id })
    }

    private func index(_ id: String) -> Int? { sessions.firstIndex(where: { $0.id == id }) }
    private func trashedIndex(_ id: String) -> Int? { trashedSessions.firstIndex(where: { $0.id == id }) }

    private func scheduleSave(_ id: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow(id) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow(_ id: String) {
        guard let s = session(id) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s) else { return }
        let dir = s.deletedAt == nil ? folder(id) : trashFolder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }
}

// MARK: - Export

/// What an export contains, and in which format.
///
/// The notes have two readings — the visualization and the written summary — and the
/// transcript is a third thing. A file gets what was asked for and nothing else.
struct ExportOptions {
    enum Format: String, CaseIterable {
        case md, word, pdf
        var ext: String {
            switch self {
            case .md: return "md"
            case .word: return "docx"
            case .pdf: return "pdf"
            }
        }
    }
    /// The visualization: the topics with their fishbone, the conclusions with the sentences
    /// they rest on.
    var aiView = true
    /// The written notes: the summary and the topics as prose.
    var textSummary = true
    /// The transcript: what was said, and what it was translated to.
    var transcript = true
    var format: Format = .md
    /// How the AI view draws each topic's diagram in the export (平衡图 / 树形 / 鱼骨图 / 自动).
    var mindMapStyle: MindMapStyle = .auto

    /// Nothing to write: the file would be empty.
    var isEmpty: Bool { !aiView && !textSummary && !transcript }
}

/// The meeting the export panel is for.
struct ExportRequest: Identifiable {
    let id: String
    let session: Session
}

enum TranscriptExport {
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Experimental speaker numbers on (设置 › 通用 › 实验功能); kept in step by AppModel.
    nonisolated(unsafe) static var voices = false

    static func speakerName(_ line: TranscriptLine, _ numbers: [String: Int] = [:], _ names: [Int: String] = [:]) -> String {
        if line.speaker == "me" { return L("你") }
        if let n = numbers[line.id] { return SpeakerLabels.label(n, names) }
        return numbers.isEmpty ? L("对方") : L("未识别")
    }

    static func speakerNumbers(_ s: Session) -> [String: Int] { voices ? SpeakerLabels.numbers(s.lines) : [:] }

    static func header(_ s: Session) -> String {
        let mins = Int(s.duration / 60)
        return "\(dateText(s.startedAt, "yMMMdHHmm")) · " + (mins < 1 ? L("不到 1 分钟") : L("\(mins) 分钟"))
    }

    /// The notes as Markdown (empty when there are none).
    static func notesMarkdown(_ n: MeetingNotes?) -> String {
        guard let n, !n.isEmpty else { return "" }
        var out = "## \(L("纪要"))\n\n\(n.summary)\n\n"
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            if let f = t.fishbone {
                out += "\n**\(f.question)**\n\n"
                for b in f.branches { out += "- \(b.label)：\(b.detail)\n" }
            }
            out += "\n"
        }
        if !n.conclusions.isEmpty { out += "### \(L("结论"))\n\n" + n.conclusions.map { "- \($0.text)\n" }.joined() + "\n" }
        if !n.todos.isEmpty {
            out += "### \(L("待办"))\n\n" + n.todos.map { "- [ ] \($0.text)" + ($0.owner.map { "（\($0)）" } ?? "") + "\n" }.joined() + "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(L("人名和术语"))\n\n" + n.terms.map { "- **\($0.name)** \($0.note)\n" }.joined() + "\n"
        }
        return out
    }

    /// The AI view as Markdown: the topics with their points and their fishbone, the
    /// conclusions with the sentences they rest on.
    static func aiViewMarkdown(_ n: MeetingNotes) -> String {
        var out = ""
        if !n.summary.isEmpty { out += "**\(L("总结"))**\n\n\(n.summary)\n\n" }
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            if !t.points.isEmpty { out += "\n" }
            if let f = t.fishbone {
                out += "**\(f.question.isEmpty ? L("为什么") : f.question)**\n\n"
                for b in f.branches { out += "- **\(b.label)**\(b.detail.isEmpty ? "" : "：\(b.detail)")\n" }
                out += "\n"
            }
        }
        if !n.conclusions.isEmpty {
            out += "### \(L("结论"))\n\n"
            for c in n.conclusions { out += "- \(c.text)\(evidence(c))\n" }
            out += "\n"
        }
        if !n.todos.isEmpty {
            out += "### \(L("待办"))\n\n"
            for t in n.todos { out += "- [ ] \(t.text)" + (t.owner.map { "（\($0)）" } ?? "") + evidence(t) + "\n" }
            out += "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(L("人名和术语"))\n\n" + n.terms.map { "- **\($0.name)** \($0.note)\(heard($0))\n" }.joined() + "\n"
        }
        return out
    }

    /// The written summary as Markdown: the summary and the topics, as prose.
    static func textSummaryMarkdown(_ n: MeetingNotes) -> String {
        var out = ""
        if !n.summary.isEmpty { out += "\(n.summary)\n\n" }
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            out += "\n"
        }
        if !n.conclusions.isEmpty {
            out += "### \(L("结论"))\n\n" + n.conclusions.map { "- \($0.text)\n" }.joined() + "\n"
        }
        if !n.todos.isEmpty {
            out += "### \(L("待办"))\n\n"
            + n.todos.map { "- [ ] \($0.text)" + ($0.owner.map { "（\($0)）" } ?? "") + "\n" }.joined() + "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(L("人名和术语"))\n\n" + n.terms.map { "- **\($0.name)** \($0.note)\(heard($0))\n" }.joined() + "\n"
        }
        return out
    }

    /// "（依据 3 句 · 12:04）": how much of the meeting a conclusion rests on, and when it was said.
    private static func evidence(_ item: NoteItem) -> String {
        var parts: [String] = []
        if item.support > 0 { parts.append(L("依据 \(item.support) 句")) }
        if let t = item.t { parts.append(clock(t)) }
        return parts.isEmpty ? "" : "（" + parts.joined(separator: " · ") + "）"
    }

    /// " · 原识别 知了": the ways the name was heard, as the chips on screen show them.
    private static func heard(_ term: NoteTerm) -> String {
        guard !term.heard.isEmpty else { return "" }
        return " · " + L("原识别 \(term.heard.prefix(2).joined(separator: "、"))")
    }

    static func markdown(_ s: Session, options: ExportOptions = ExportOptions()) -> String {
        var out = "# \(s.displayTitle)\n\n\(header(s))\n\n"
        if options.aiView, let n = s.notes {
            let part = aiViewMarkdown(n)
            if !part.isEmpty { out += "## \(L("AI 视图"))\n\n" + part + "\n" }
        }
        if options.textSummary, let n = s.notes {
            let part = textSummaryMarkdown(n)
            if !part.isEmpty { out += "## \(L("文字总结"))\n\n" + part + "\n" }
        }
        if options.transcript {
            out += "## \(L("原始记录"))\n\n"
            let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
            for l in s.lines {
                out += "**[\(clock(l.t))] \(speakerName(l, numbers, names))**  \n\(l.corrected ?? l.src)\n"
                if let d = l.dst, d != l.corrected ?? l.src { out += "> \(d)\n" }
                out += "\n"
            }
        }
        return out
    }

    static func srt(_ s: Session) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, l) in s.lines.enumerated() {
            let next = i + 1 < s.lines.count ? s.lines[i + 1].t : l.t + 4
            let end = max(l.t + 1, min(next, l.t + 8))
            out += "\(i + 1)\n\(ts(l.t)) --> \(ts(end))\n\(l.corrected ?? l.src)\n"
            if let d = l.dst, d != l.corrected ?? l.src { out += "\(d)\n" }
            out += "\n"
        }
        return out
    }

    static func docx(_ s: Session, options: ExportOptions = ExportOptions(), images: [String: NSImage] = [:]) throws -> Data {
        let doc = styledDocument(s, options: options, images: images)
        return try doc.data(from: NSRange(location: 0, length: doc.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    static func pdf(_ s: Session, options: ExportOptions = ExportOptions(), images: [String: NSImage] = [:]) -> Data {
        let doc = styledDocument(s, options: options, images: images)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4
        let inset = CGRect(x: 48, y: 48, width: page.width - 96, height: page.height - 96)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Data() }
        // TextKit lays out the styled document (text + the fishbone pictures as attachments)
        // and paginates it onto A4 pages; Core Text's framesetter would drop the pictures.
        let storage = NSTextStorage(attributedString: doc)
        let container = NSTextContainer(size: CGSize(width: inset.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var current = 0
        let total = doc.length
        while current < total {
            var media = page
            ctx.beginPage(mediaBox: &media)
            // TextKit reports line-fragment rects from the top-left of the inset area with y
            // pointing down; map them onto the page (PDF origin is bottom-left). NSGraphicsContext
            // is needed so that NSTextAttachment images (the fishbone) actually draw.
            ctx.translateBy(x: inset.origin.x, y: page.height - inset.origin.y)
            ctx.scaleBy(x: 1, y: -1)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsCtx
            var drewAny = false
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: current, length: total - current)) { rect, _, _, glyphRange, stop in
                let bottom = rect.origin.y + rect.size.height
                guard bottom <= inset.height else { stop.pointee = true; return }
                manager.drawBackground(forGlyphRange: glyphRange, at: rect.origin)
                manager.drawGlyphs(forGlyphRange: glyphRange, at: rect.origin)
                current = glyphRange.upperBound
                drewAny = true
            }
            NSGraphicsContext.current = nil
            ctx.endPage()
            if !drewAny { break } // a fragment taller than the page: stop rather than loop forever
        }
        ctx.closePDF()
        return data as Data
    }

    static func styledDocument(_ s: Session, options: ExportOptions = ExportOptions(), images: [String: NSImage] = [:]) -> NSMutableAttributedString {
        let doc = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black, after: CGFloat = 4) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = after
            doc.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: p,
            ]))
        }
        /// A picture in the text: the fishbone, drawn the way the meeting record draws it.
        func addPicture(_ image: NSImage, maxWidth: CGFloat = 460) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            let w = min(maxWidth, image.size.width)
            attachment.bounds = CGRect(x: 0, y: 0, width: w, height: image.size.height * (w / image.size.width))
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 10
            doc.append(NSAttributedString(attachment: attachment))
            doc.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p]))
        }
        /// The notes in one of the two readings: the visualization (the fishbone and the
        /// grounds the conclusions rest on) or the written summary.
        func notes(_ n: MeetingNotes, aiView: Bool) {
            if !n.summary.isEmpty { add(n.summary, size: 11, after: 10) }
            for t in n.topics {
                add("\(clock(t.start))  \(t.title)", size: 12, weight: .semibold, after: 3)
                if !t.summary.isEmpty { add(t.summary, size: 11, color: .darkGray, after: 3) }
                for p in t.points { add("• \(p)", size: 11, after: 2) }
                if aiView, let f = t.fishbone {
                    let q = f.question.isEmpty ? L("为什么") : f.question
                    add(q, size: 11, weight: .semibold, after: 2)
                    // The diagram itself when there is one; the branches as text otherwise.
                    if let image = images[t.id] {
                        addPicture(image)
                    } else {
                        for b in f.branches { add("  – \(b.label)：\(b.detail)", size: 11, after: 2) }
                    }
                }
                add("", size: 6, after: 4)
            }
            if !n.conclusions.isEmpty {
                add(L("结论"), size: 12, weight: .semibold, after: 3)
                for c in n.conclusions { add("• \(c.text)" + (aiView ? evidence(c) : ""), size: 11, after: 2) }
                add("", size: 6, after: 4)
            }
            if !n.todos.isEmpty {
                add(L("待办"), size: 12, weight: .semibold, after: 3)
                for t in n.todos {
                    add("☐ \(t.text)" + (t.owner.map { "（\($0)）" } ?? "") + (aiView ? evidence(t) : ""), size: 11, after: 2)
                }
                add("", size: 6, after: 4)
            }
            if !n.terms.isEmpty {
                add(L("人名和术语"), size: 12, weight: .semibold, after: 3)
                for t in n.terms { add("• \(t.name) \(t.note)\(heard(t))", size: 11, after: 2) }
                add("", size: 6, after: 4)
            }
        }
        add(s.displayTitle, size: 20, weight: .bold, after: 6)
        add(header(s), size: 10, color: .darkGray, after: 14)
        if options.aiView, let n = s.notes, !n.isEmpty {
            add(L("AI 视图"), size: 15, weight: .bold, after: 6)
            notes(n, aiView: true)
        }
        if options.textSummary, let n = s.notes, !n.isEmpty {
            add(L("文字总结"), size: 15, weight: .bold, after: 6)
            notes(n, aiView: false)
        }
        if options.transcript {
            add(L("原始记录"), size: 15, weight: .bold, after: 6)
            let numbers = speakerNumbers(s), names = SpeakerLabels.names(s)
            for l in s.lines {
                add("[\(clock(l.t))] \(speakerName(l, numbers, names))", size: 9, weight: .semibold, color: .darkGray, after: 2)
                let text = l.corrected ?? l.src
                add(text, size: 11, after: 2)
                if let d = l.dst, d != text { add(d, size: 11, color: NSColor(calibratedWhite: 0.3, alpha: 1), after: 10) }
            }
        }
        return doc
    }
}
