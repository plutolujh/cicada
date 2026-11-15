import AppKit
import SwiftUI

/// The one place where words are heard: the system audio or the microphone.
///
/// Both are the same to the reader — words heard on the left, a summary written from them on
/// the right — so they share this surface and differ only in the source switch at the top.
/// The switch is also where the two paths are told apart: whichever is picked is the one that
/// is running and the one whose words are shown.
struct CaptureView: View {
    @ObservedObject var model: AppModel
    /// The notes engine the capture drives: the same one a meeting does.
    @ObservedObject var notes: NotesEngine
    /// The microphone path, read when it is the one running.
    @ObservedObject var engine: RecordEngine
    /// The live words, in the one shape both sources are read through.
    @ObservedObject var feed: CaptureFeed

    /// Which source the user picked. Changing it while a capture is running stops the one that
    /// was: the microphone and the system audio cannot both be listened to at once.
    @State private var picked: CaptureSource = .system
    /// The divider position between the transcript and the live notes (0–1, share of total width
    /// given to the left pane). Resets to half every time the surface opens; not persisted.
    @State private var divider: CGFloat = 0.5
    /// The divider value when the current drag began, so the drag accumulates on it.
    @State private var dragStart: CGFloat = 0.5
    /// The source the surface shows: the one that is running, or the one that was picked when
    /// nothing runs. The toolbar pill and this surface therefore always show the same thing.
    ///
    /// The engine state is the immediate source of truth for the microphone: it changes the
    /// instant the recording starts, pauses or stops, so the surface and the toolbar pill see
    /// the same state without waiting for the capture feed's 0.1s tick.
    private var source: CaptureSource {
        if engine.state == .recording || engine.state == .preparing || engine.state == .paused {
            return .mic
        }
        if model.running {
            return .system
        }
        return picked
    }
    /// The sentence being corrected, when the user is correcting one.
    @State private var editing: String?
    /// The words being corrected.
    @State private var editText = ""
    /// Which right-pane tab is showing: "ai" (可视化) or "text" (文字总结).
    @State private var notesTab = "ai"
    /// Whether the AI view's drawer-style table of contents is open over the visualization.
    @State private var tocOpen = false
    /// A moment picked in the notes (a fishbone branch, a time link): the transcript scrolls to it.
    @State private var jumpToTime: Double?

    /// The language the sentences are translated into; "none" leaves them as they were said.
    private var target: String { model.recordTarget }
    /// Detect the language instead of using one fixed model.
    private var autoLang: Bool { model.recordAutoLang }
    /// Keep the audio next to the transcript.
    private var keepsAudio: Bool { model.recordKeepsAudio }

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let minLeft: CGFloat = 360
            let minRight: CGFloat = 320
            let leftWidth = max(minLeft, min(total - minRight, total * divider))
            HStack(spacing: 0) {
                left
                    .frame(width: leftWidth, alignment: .leading)
                    .frame(maxHeight: .infinity)
                dividerBar(totalWidth: total)
                right
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
        .overlay {
            // The passage from the recording to the meeting record.
            if let saving = model.recordSaving {
                RecordSavingView(saving: saving, onOpen: { model.openSavedMeeting() }, correcting: model.recordCorrecting)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // The engine is also wired when the recording starts, so these are for a recording
            // that is already running when the surface comes up.
            engine.ai = model.ai
            engine.target = target
            engine.detectsLanguage = autoLang
            engine.keepsAudio = keepsAudio
            engine.installed = model.installed
            engine.candidates = model.candidates
        }
        .onChange(of: model.recordTarget) { _, v in engine.target = v }
        .onChange(of: model.recordAutoLang) { _, v in engine.detectsLanguage = v }
        .onChange(of: model.recordKeepsAudio) { _, v in engine.keepsAudio = v }
        .onChange(of: engine.state) { _, _ in feed.source = source }
    }

    /// A draggable bar between the transcript and the notes. A 1pt hairline is what the eye
    /// sees; the wider hit area is what the pointer grabs.
    private func dividerBar(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(MainWindowView.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let delta = value.translation.width / max(totalWidth, 1)
                                divider = dragStart + delta
                            }
                            .onEnded { _ in
                                dragStart = divider
                            }
                    )
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
    }

    // MARK: Left — the source and the words

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceSwitch
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            titleRow
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            controls
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            transcript
        }
    }

    /// The switch between the two ways in. It says which one is running, so the place where
    /// the words come from is never in doubt.
    private var sourceSwitch: some View {
        HStack(spacing: 8) {
            ForEach(CaptureSource.allCases) { s in
                sourceButton(s)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func sourceButton(_ s: CaptureSource) -> some View {
        let on = source == s
        let live = running(s)
        return Button { switchSource(to: s) } label: {
            HStack(spacing: 6) {
                Image(systemName: s.icon).font(.system(size: 11))
                Text(s.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                if live {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(on ? Palette.ink : Palette.secondary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Palette.fill : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(on ? Palette.line : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(s.hint))
    }

    /// Whether this source is the one running right now: recording, paused, or getting ready.
    private func running(_ s: CaptureSource) -> Bool {
        switch s {
        case .system: return model.running
        case .mic: return engine.state == .recording || engine.state == .preparing || engine.state == .paused
        }
    }

    /// Picks the source. The one that was running is stopped first: the microphone and the
    /// system audio cannot both be listened to at once, and the words of one would be mixed
    /// with the words of the other.
    private func switchSource(to s: CaptureSource) {
        guard s != picked else { return }
        if running(picked) { stopRunning(picked) }
        picked = s
        feed.source = s
        feed.reset()
    }

    private func stopRunning(_ s: CaptureSource) {
        switch s {
        case .system: model.requestStop()
        case .mic:
            engine.stop()
            model.endRecording()
        }
    }

    private func pauseRunning(_ s: CaptureSource) {
        switch s {
        case .system: model.pauseListening()
        case .mic: engine.pause()
        }
    }

    private func resumeRunning(_ s: CaptureSource) {
        switch s {
        case .system: model.resumeListening()
        case .mic: engine.resume()
        }
    }

    /// The title of the recording in progress: editable, shown above the controls so it is not
    /// mixed with the buttons. Only the microphone recording gets a title; system listening
    /// keeps its fixed label.
    @State private var titleEdit = ""
    @State private var editingTitle = false

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if source == .mic, model.activeRecordingSessionID != nil {
                HStack(spacing: 8) {
                    if editingTitle {
                        TextField(model.recordSessionDisplayTitle, text: $titleEdit)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .onSubmit { commitTitle() }
                        Button("完成") { commitTitle() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.accent)
                            .font(.system(size: 12))
                    } else {
                        Text(model.recordSessionDisplayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .onTapGesture { beginTitleEdit() }
                        Button { beginTitleEdit() } label: {
                            Image(systemName: "pencil").font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("修改标题"))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
            }
            // The polishing runs after the recording ends: the words below still change.
            // Only while the recording's own words are the ones on the left.
            if model.recordCorrecting, source == .mic {
                PolishingHint()
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .onChange(of: model.activeRecordingSessionID) { _, _ in
            editingTitle = false
            titleEdit = model.recordSessionDisplayTitle
        }
    }

    private func beginTitleEdit() {
        titleEdit = model.recordSessionDisplayTitle
        editingTitle = true
    }

    private func commitTitle() {
        model.renameRecordingSession(to: titleEdit)
        editingTitle = false
    }

    // MARK: The controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                chips
                displayPicker
                exportButton
                scope
                clock
                actionButtons
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 8) {
                chips
                VStack(alignment: .leading, spacing: 8) {
                    displayPicker
                    exportButton
                }
                HStack(spacing: 12) {
                    scope
                    clock
                    actionButtons
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    /// The scope: how loud the input hears you right now.
    private var scope: some View {
        RecordScope(levels: feed.waveform, live: running(source))
    }

    /// How long the capture has been running.
    private var clock: some View {
        RecordClock(elapsed: feed.elapsed, live: running(source))
    }

    /// The three switches, each one saying what it does rather than what it is.
    private var chips: some View {
        HStack(spacing: 8) {
            chip("自动识别", icon: "waveform.badge.magnifyingglass", on: autoLang) { model.recordAutoLang.toggle() }
            translationChip
            chip("保留音频", icon: "waveform", on: keepsAudio) { model.recordKeepsAudio.toggle() }
        }
    }

    /// The language the sentences go into. A menu, not a switch: recording in Chinese and
    /// reading in English is as ordinary as the other way round, and the sentence's own
    /// language is only known while it is being heard.
    private var translationChip: some View {
        Menu {
            ForEach(targetOptions, id: \.id) { o in
                Button(o.title) { model.recordTarget = o.id }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "character.bubble").font(.system(size: 11))
                Text(translationLabel).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(target == "none" ? Palette.secondary : Palette.accentInk)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(target == "none" ? Palette.fill : Palette.accentPale))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(L("录音翻译成哪种语言"))
    }

    /// The chip says which language the sentences go into, or that they stay as they were said.
    private var translationLabel: LocalizedStringKey {
        target == "none" ? "不翻译" : "翻译成 \(targetName(target))"
    }

    /// The title is a `LocalizedStringKey`, so the chip is translated; a plain string here would
    /// stay in Chinese on an English Mac.
    private func chip(_ title: LocalizedStringKey, icon: String, on: Bool, _ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(on ? Palette.accentInk : Palette.secondary)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Palette.accentPale : Palette.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What the transcript shows: the words as they were said, the translation, or both.
    private var displayPicker: some View {
        HStack(spacing: 0) {
            ForEach(CaptureFeed.Display.allCases, id: \.self) { mode in
                Button { feed.display = mode } label: {
                    Text(displayTitle(mode)).font(.system(size: 11, weight: feed.display == mode ? .semibold : .regular))
                        .foregroundStyle(feed.display == mode ? Palette.accentInk : Palette.secondary)
                        .padding(.horizontal, 8).frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
        .opacity(target == "none" ? 0.4 : 1)
        .disabled(target == "none")
        .help(L("原文、译文或双语"))
    }

    private func displayTitle(_ mode: CaptureFeed.Display) -> LocalizedStringKey {
        switch mode {
        case .original: return "原文"
        case .translated: return "译文"
        case .bilingual: return "双语"
        }
    }

    /// Starts, pauses/resumes and stops the capture. While something is running, show 暂停/恢复
    /// and a separate 停止 so "pause" never means "end this recording".
    @ViewBuilder
    private var actionButtons: some View {
        if running(source) {
            if paused(source) {
                resumeButton
            } else {
                pauseButton
            }
            stopButton
        } else {
            startButton
        }
    }

    /// Whether the running source is on hold.
    private func paused(_ s: CaptureSource) -> Bool {
        switch s {
        case .system: return model.listeningPaused
        case .mic: return engine.state == .paused
        }
    }

    /// The button that starts the capture.
    private var startButton: some View {
        Button {
            switch source {
            case .system: model.start()
            case .mic: model.startRecording()
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Palette.ink).frame(width: 9, height: 9)
                Text(startLabel).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(Palette.ink))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(source == .mic && (engine.state == .preparing || engine.state == .stopping))
    }

    private var startLabel: LocalizedStringKey {
        source == .system ? "开始听" : "开始录音"
    }

    private var pauseButton: some View {
        Button { pauseRunning(source) } label: {
            Text("暂停").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Palette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var resumeButton: some View {
        Button { resumeRunning(source) } label: {
            Text("恢复").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Palette.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button { stopRunning(source) } label: {
            Text("停止").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Palette.ink))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(source == .mic && engine.state == .stopping)
    }

    /// The button that exports the capture, in the same formats a meeting can be exported in.
    private var exportButton: some View {
        Menu {
            Button(L("导出 Markdown")) { model.exportRecording(kind: "md") }
            Button(L("导出 Word")) { model.exportRecording(kind: "word") }
            Button(L("导出字幕 (SRT)")) { model.exportRecording(kind: "srt") }
            Divider()
            Button(L("复制 Markdown")) { model.exportRecording(kind: "copy") }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                .foregroundStyle(model.recordSession == nil ? Palette.tertiary : Palette.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.recordSession == nil)
        .help(L("导出录音"))
    }

    // MARK: The words

    /// The words of the source that is running: the microphone's own lines, or the system
    /// audio's, read through the same column.
    private var lines: [RecordLine] {
        source == .mic ? engine.lines : feed.lines
    }

    private var liveText: String {
        source == .mic ? engine.live : feed.live
    }

    private var liveWords: [LiveWord] {
        source == .mic ? engine.liveWords : feed.liveWords
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if lines.isEmpty, liveText.isEmpty {
                        empty
                    }
                    ForEach(lines) { line in
                        row(line)
                            .id(line.id)
                    }
                    if !liveText.isEmpty {
                        liveRow
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: jumpToTime) { _, t in
                guard let t, let line = lines.first(where: { $0.t >= t - 1 }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(line.id, anchor: .top) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyTitle).font(.system(size: 14)).foregroundStyle(Palette.secondary)
            Text("识别在本机完成，只有翻译和总结会用到 AI 服务。")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
        .padding(.top, 24)
    }

    /// The empty column says what this source is waiting for.
    private var emptyTitle: LocalizedStringKey {
        source == .mic ? "点“开始录音”，对着麦克风说话。" : "点“开始听”，电脑里放的声音会出现在这里。"
    }

    /// The sentence being spoken right now: the words show up as they are said.
    private var liveRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecordEngine.clock(elapsed))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if liveWords.isEmpty {
                    Text(liveText).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                } else {
                    // The words are shown one by one, the way they are heard; the newest one is
                    // the accent colour, so the eye follows the speaker.
                    Text(liveText)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// How long the capture has run.
    private var elapsed: TimeInterval {
        source == .mic ? engine.elapsed : feed.elapsed
    }

    /// One settled sentence: when it was said, what was said, and what it means.
    private func row(_ line: RecordLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecordEngine.clock(line.t))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if starts.contains(line.id), let person = line.person {
                    HStack(spacing: 5) {
                        Circle().fill(SpeakerColor.ink(person)).frame(width: 6, height: 6)
                        Text(L("人物 \(person)")).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpeakerColor.ink(person))
                    }
                }
                if editing == line.id {
                    editor(line)
                } else {
                    texts(line)
                }
            }
            Spacer(minLength: 0)
            lineActions(line)
        }
    }

    /// The little buttons beside a sentence: play it, change it, cut it up.
    ///
    /// The microphone can be played back and cut up; the system audio is what the Mac was
    /// playing, so it is only read and corrected.
    @ViewBuilder
    private func lineActions(_ line: RecordLine) -> some View {
        HStack(spacing: 8) {
            if source == .mic, keepsAudio, engine.audioURL != nil {
                Button {
                    engine.play(from: line.t)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.tertiary)
                .help(L("从这里播放"))
            }
            Button {
                editText = line.corrected ?? line.text
                editing = line.id
            } label: {
                Image(systemName: "pencil").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.tertiary)
            .help(L("改一下"))
            if source == .mic {
                Menu {
                    Button(L("和下一句合并")) {
                        guard let next = engine.lines.first(where: { $0.t > line.t }) else { return }
                        engine.merge(line.id, with: next.id)
                    }
                    Button(L("从这里分成两句")) {
                        engine.split(line.id, at: max(1, Array(line.text).count / 2))
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.tertiary)
                .help(L("合并或拆分"))
            }
        }
        .padding(.top, 2)
    }

    /// The words of a settled sentence, in the mode the transcript is in.
    @ViewBuilder
    private func texts(_ line: RecordLine) -> some View {
        let translation = line.translation.flatMap { $0.isEmpty ? nil : $0 }
        let shown = line.corrected ?? line.text
        let isCorrected = line.corrected != nil && line.corrected != line.text
        switch feed.display {
        case .original:
            VStack(alignment: .leading, spacing: 2) {
                Text(shown).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if isCorrected {
                    correctedBadge(line)
                }
            }
        case .translated:
            if let translation {
                Text(translation).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown).font(.system(size: 14)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCorrected { correctedBadge(line) }
                }
            }
        case .bilingual:
            VStack(alignment: .leading, spacing: 2) {
                Text(shown).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if isCorrected { correctedBadge(line) }
            }
            if let translation {
                Text(translation).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func correctedBadge(_ line: RecordLine) -> some View {
        Menu {
            Button(L("查看原文")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
            Button(L("撤销纠错")) {
                engine.clearCorrection(line.id)
            }
            Button(L("重新纠错")) {
                engine.recorrect(lineID: line.id, glossary: model.notes.glossary)
            }
        } label: {
            Text("✦ " + L("已润色"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help(line.text)
    }

    /// The box the words are corrected in.
    private func editor(_ line: RecordLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("改正这句话"), text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...6)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.fill))
            HStack(spacing: 10) {
                Button(L("保存")) {
                    save(line.id)
                    editing = nil
                }
                .font(.system(size: 12, weight: .semibold))
                Button(L("取消")) { editing = nil }
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accentInk)
        }
    }

    /// A corrected sentence: the microphone's own copy and the meeting record are both
    /// written; the system audio's copy is only in the meeting record.
    private func save(_ id: String) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if source == .mic {
            // Check if this line currently has a correction (before editing)
            let hasCorrection = engine.lines.first(where: { $0.id == id })?.corrected != nil
            engine.edit(id, text: text, correct: hasCorrection)
        } else if let i = feed.lines.firstIndex(where: { $0.id == id }) {
            guard text != feed.lines[i].text else { return }
            feed.lines[i].text = text
            model.store.setSource(lineID: id, text)
        }
    }

    /// The lines where the voice changes: the name is shown there only.
    private var starts: Set<String> {
        var out: Set<String> = [], last: Int??
        for l in lines {
            let key = l.person
            if key != last { out.insert(l.id) }
            last = key
        }
        return out
    }

    // MARK: Right — the live notes

    /// The same notes a meeting gets: the summary, the topics, the conclusions and the
    /// fishbone, written by the same service and read the same way.
    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            notesHeader
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            notesTabs
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        if notes.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(lines.isEmpty ? "说几句之后，这里会边听边写。" : "正在整理…")
                                    .font(.system(size: 14)).foregroundStyle(Palette.secondary)
                                if !lines.isEmpty {
                                    Text("纪要由 AI 服务整理，需要在设置里填好服务 key。")
                                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                                }
                            }
                            .padding(.top, 24).padding(.horizontal, 20)
                        } else if notesTab == "text" {
                            NotesContentView(notes: notes.notes, fresh: notes.fresh, live: recording,
                                             document: true,
                                             updating: notes.state == .updating,
                                             summaryJustChanged: notes.summaryChangedAt.map { Date().timeIntervalSince($0) < 20 } ?? false,
                                             coveredUntil: coveredUntil,
                                             endedAt: endedAt)
                            .padding(.horizontal, 20).padding(.vertical, 16)
                        } else {
                            AIView(notes: notes.notes, live: recording,
                                   updating: notes.state == .updating,
                                   summaryJustChanged: notes.summaryChangedAt.map { Date().timeIntervalSince($0) < 20 } ?? false,
                                   onJump: { jumpToTime = $0 })
                            .padding(.horizontal, 20).padding(.vertical, 16)
                        }
                    }
                    .scrollIndicators(.never)

                    if notesTab == "ai" && tocOpen {
                        Color.black.opacity(0.2).ignoresSafeArea()
                            .onTapGesture { tocOpen = false }
                        AIToC(notes: notes.notes, isOpen: $tocOpen) { id in
                            withAnimation { proxy.scrollTo(id, anchor: .top) }
                        }
                        .transition(.move(edge: .leading))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Header row: the "实时纪要" title, the re-summarize button, and the hamburger TOC toggle.
    private var notesHeader: some View {
        HStack(spacing: 8) {
            if notesTab == "ai" && !notes.notes.topics.isEmpty {
                Button { tocOpen = true } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).help(L("目录"))
            }
            Text("实时纪要").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            if notes.state == .updating {
                Text("正在更新…").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            } else if !notes.notes.isEmpty {
                Button { notes.updateNow() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).help(L("重新总结"))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// The two tabs: AI 视图 and 文字总结.
    private var notesTabs: some View {
        HStack(spacing: 0) {
            tabButton(L("AI 视图"), id: "ai")
            tabButton(L("文字总结"), id: "text")
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.fill))
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    private func tabButton(_ title: String, id: String) -> some View {
        Button { notesTab = id } label: {
            Text(title).font(.system(size: 13, weight: notesTab == id ? .semibold : .regular))
                .foregroundStyle(notesTab == id ? Palette.ink : Palette.secondary)
                .frame(maxWidth: .infinity).frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(notesTab == id ? Color.white : .clear)
                .shadow(color: .black.opacity(notesTab == id ? 0.08 : 0), radius: 1.5, y: 1)
        )
    }

    /// The capture is still going.
    private var recording: Bool { running(source) }
    /// The time of the last line the notes cover ("到 03:52").
    private var coveredUntil: Double? {
        guard notes.notes.covered > 0 else { return nil }
        let lines = model.store.session(notes.shownID ?? "")?.lines ?? []
        guard notes.notes.covered <= lines.count else { return nil }
        return lines[notes.notes.covered - 1].t
    }
    /// Where the last topic ends, once the capture has stopped.
    private var endedAt: Double? {
        guard !recording else { return nil }
        return model.store.session(notes.shownID ?? "")?.lines.last?.t
    }

    // MARK: The translation target

    /// The languages a capture can be translated into, with the one in use marked.
    private var targetOptions: [(id: String, title: String)] {
        [("none", L("不翻译"))] + targetLanguages.map { ($0.code, $0.name) }
    }
}

// MARK: - AI view

/// The "AI 视图" tab: a headline summary, fishbone diagrams per topic, a table of topics,
/// and a hamburger drawer that overlays the table of contents on tap.
struct AIView: View {
    let notes: MeetingNotes
    var live = false
    var updating = false
    var summaryJustChanged = false
    var onJump: (Double) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L("总结")).font(.system(size: 15, weight: .bold))
                        if summaryJustChanged { Tag(L("刚更新"), live: true) }
                        Spacer()
                        if notes.final { Tag(L("完整版")) } else if live {
                            Tag(notes.notesCoveredClock.map { L("速记版 · 到 \(NotesEngine.clock($0))") } ?? L("速记版"))
                        }
                    }
                    Text(notes.summary).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    title(L("议题"))
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(NotesEngine.clock(topic.start))
                                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.tertiary)
                                Text(topic.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                                if !topic.summary.isEmpty {
                                    Text(topic.summary).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            if let fish = topic.fishbone {
                                FishboneView(fishbone: fish, onJump: onJump)
                            }
                            if !topic.points.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(topic.points.enumerated()), id: \.offset) { i, p in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("•").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                            Text(p).font(.system(size: 14)).foregroundStyle(Palette.ink)
                                                .lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.leading, 16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.fill))
                        .id(Self.topicID(topic))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 18)
            }

            if !notes.conclusions.isEmpty || !notes.todos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    title(notes.todos.isEmpty ? L("结论") : L("结论和待办"))
                    FramedList {
                        items
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }

            if !notes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    title(L("人名和术语"))
                    TermChips(terms: notes.terms, showHeard: true)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.bottom, 2)
    }

    /// A stable per-topic scroll anchor, shared with the TOC.
    static func topicID(_ t: NoteTopic) -> String { "ai-topic-\(Int(t.start))-\(t.title)" }

    @ViewBuilder
    private var items: some View {
        let all = notes.conclusions + notes.todos
        ForEach(Array(all.enumerated()), id: \.offset) { i, item in
            let todo = i >= notes.conclusions.count
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if todo {
                    Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                } else {
                    Circle().fill(Palette.ink.opacity(0.55)).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        .frame(width: 13)
                }
                Text(item.text + (item.owner.map { "（\($0)）" } ?? ""))
                    .font(.system(size: 14)).lineSpacing(2)
                    .foregroundStyle(item.support == 0 ? Palette.tertiary : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.support == 0 {
                    Tag(L("依据较少"))
                } else if let t = item.t {
                    TimeLink(text: L("\(NotesEngine.clock(t)) · \(item.support) 句"), t: t, onJump: onJump)
                } else {
                    Tag(L("依据 \(item.support) 句"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
        }
    }
}

/// The drawer-style table of contents that overlays the AI view's visualization.
///
/// Opens from the left edge over the fishbone/table content, listing every topic and its points.
/// Tapping an item jumps to that section in the AI view (and closes the drawer).
struct AIToC: View {
    let notes: MeetingNotes
    @Binding var isOpen: Bool
    var onJump: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("目录")).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Button { isOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Rectangle().fill(MainWindowView.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if notes.topics.isEmpty {
                        Text(L("没有可跳转的议题")).font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                            .padding(.vertical, 14).padding(.horizontal, 20)
                    }
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        Button {
                            isOpen = false
                            DispatchQueue.main.async { onJump(AIView.topicID(topic)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(NotesEngine.clock(topic.start)).font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(Palette.tertiary)
                                    Text(topic.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                                }
                                if !topic.points.isEmpty {
                                    Text(topic.points.joined(separator: " · "))
                                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                        .lineLimit(2)
                                        .lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 10).padding(.horizontal, 20)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < notes.topics.count - 1 {
                            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .background(Color.white)
        .shadow(color: .black.opacity(0.12), radius: 12, x: 4, y: 0)
    }
}

/// Extension to expose a clock-friendly covered-time on MeetingNotes for the AI view.
extension MeetingNotes {
    var notesCoveredClock: Double? { covered > 0 ? Double(covered) : nil }
}

// MARK: - Polishing

/// The line that says the words are being polished in the background.
///
/// The polishing runs after the recording ends and takes a while, so the reader is told: the
/// sentences they are reading will still change under them.
struct PolishingHint: View {
    var body: some View {
        HStack(spacing: 6) {
            BreathingDot(size: 5)
            Text(L("正在润色…")).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("正在润色…"))
    }
}
