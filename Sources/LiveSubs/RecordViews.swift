import AppKit
import SwiftUI

/// The recording surface: the microphone on the left with what it heard under it, the running
/// summary on the right.
///
/// The transcript is on the left because that is where the eye stays while someone talks; the
/// summary is on the right because it is read afterwards, and it should not push the words
/// around while they are arriving.
struct RecordView: View {
    @ObservedObject var engine: RecordEngine
    @ObservedObject var model: AppModel

    /// The language the sentences are translated into; "none" leaves them as they were said.
    private var target: String { model.recordTarget }
    /// Detect the language instead of using one fixed model.
    private var autoLang: Bool { model.recordAutoLang }
    /// Keep the audio next to the transcript.
    private var keepsAudio: Bool { model.recordKeepsAudio }

    /// The sentence being corrected, when the user is correcting one.
    @State private var editing: String?
    /// The words being corrected.
    @State private var editText = ""
    /// The export menu, when it is open.
    @State private var exporting = false

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(MainWindowView.hairline).frame(width: 1)
            right
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
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
    }

    // MARK: Left — the microphone and the words

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Rectangle().fill(MainWindowView.hairline).frame(height: 1)
            transcript
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("新录音").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            chips
            displayPicker
            exportButton
            recordButton
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// The three switches, each one saying what it does rather than what it is.
    private var chips: some View {
        HStack(spacing: 8) {
            chip("自动识别", icon: "waveform.badge.magnifyingglass", on: autoLang) { model.recordAutoLang.toggle() }
            chip(translationLabel, icon: "character.bubble", on: target != "none") { toggleTranslation() }
            chip("保留音频", icon: "waveform", on: keepsAudio) { model.recordKeepsAudio.toggle() }
        }
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
    ///
    /// The picker only appears when there is a translation to show; without one, the original
    /// is all there is.
    private var displayPicker: some View {
        HStack(spacing: 0) {
            ForEach(RecordEngine.Display.allCases, id: \.self) { mode in
                Button { engine.display = mode } label: {
                    Text(displayTitle(mode)).font(.system(size: 11, weight: engine.display == mode ? .semibold : .regular))
                        .foregroundStyle(engine.display == mode ? Palette.accentInk : Palette.secondary)
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

    private func displayTitle(_ mode: RecordEngine.Display) -> LocalizedStringKey {
        switch mode {
        case .original: return "原文"
        case .translated: return "译文"
        case .bilingual: return "双语"
        }
    }

    /// The button that exports the recording, in the same formats a meeting can be exported in.
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

    /// The button that starts and stops the recording: a red dot while it runs.
    private var recordButton: some View {
        let live = engine.state == .recording
        return Button {
            if live {
                engine.stop()
                model.endRecording()
            } else {
                model.startRecording()
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(live ? Palette.accent : Palette.ink).frame(width: 9, height: 9)
                Text(live ? "停止" : "开始录音").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(live ? Palette.accent : Palette.ink))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(engine.state == .preparing || engine.state == .stopping)
    }

    // MARK: The words

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if engine.lines.isEmpty, engine.live.isEmpty {
                        empty
                    }
                    ForEach(engine.lines) { line in
                        row(line)
                            .id(line.id)
                    }
                    if !engine.live.isEmpty {
                        liveRow
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: engine.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("点“开始录音”，对着麦克风说话。").font(.system(size: 14)).foregroundStyle(Palette.secondary)
            Text("识别在本机完成，只有翻译和总结会用到 AI 服务。")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
        .padding(.top, 24)
    }

    /// The sentence being spoken right now: the words show up as they are said.
    private var liveRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecordEngine.clock(engine.elapsed))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if engine.liveWords.isEmpty {
                    Text(engine.live).font(.system(size: 14)).foregroundStyle(Palette.secondary)
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

    /// The words of the sentence being heard, with the newest one marked.
    private var liveText: AttributedString {
        var out = AttributedString()
        for (i, word) in engine.liveWords.enumerated() {
            var piece = AttributedString(word.text)
            piece.foregroundColor = i == engine.liveWords.count - 1 ? Palette.accent : Palette.ink
            out.append(piece)
            out.append(AttributedString(" "))
        }
        return out
    }

    /// One settled sentence: when it was said, what was said, and what it means.
    private func row(_ line: RecordLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecordEngine.clock(line.t))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                // The voice is named where it changes, the way a chat shows who is talking.
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

    /// The words of a settled sentence, in the mode the transcript is in.
    @ViewBuilder
    private func texts(_ line: RecordLine) -> some View {
        let translation = line.translation.flatMap { $0.isEmpty ? nil : $0 }
        switch engine.display {
        case .original:
            Text(line.text).font(.system(size: 14)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .translated:
            if let translation {
                Text(translation).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line.text).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bilingual:
            Text(line.text).font(.system(size: 14)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let translation {
                Text(translation).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    engine.edit(line.id, text: editText)
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

    /// The little buttons beside a sentence: play it, change it, cut it up.
    @ViewBuilder
    private func lineActions(_ line: RecordLine) -> some View {
        HStack(spacing: 8) {
            if keepsAudio, engine.audioURL != nil {
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
                editText = line.text
                editing = line.id
            } label: {
                Image(systemName: "pencil").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.tertiary)
            .help(L("改一下"))
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
        .padding(.top, 2)
    }

    /// The lines where the voice changes: the name is shown there only.
    private var starts: Set<String> {
        var out: Set<String> = [], last: Int??
        for l in engine.lines {
            let key = l.person
            if key != last { out.insert(l.id) }
            last = key
        }
        return out
    }

    // MARK: Right — the running summary

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("实时总结").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if engine.summarizing {
                    Text("正在更新…").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                } else if !engine.topics.isEmpty {
                    Button { Task { await engine.refreshSummary(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary).help(L("重新总结"))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Rectangle().fill(MainWindowView.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if engine.topics.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(engine.lines.isEmpty ? "说几句之后，这里会边听边写。" : "正在整理…")
                                .font(.system(size: 14)).foregroundStyle(Palette.secondary)
                            if !engine.lines.isEmpty {
                                Text("总结由 AI 服务整理，需要在设置里填好服务 key。")
                                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            }
                        }
                        .padding(.top, 24)
                    }
                    ForEach(engine.topics) { topic in
                        topicView(topic)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }

    private func topicView(_ topic: RecordTopic) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(topic.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            if !topic.detail.isEmpty {
                Text(topic.detail).font(.system(size: 13)).foregroundStyle(Palette.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 7) {
                    Text("•").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    Text(point).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The translation target

    private func toggleTranslation() {
        if target == "none" {
            // The language the user reads, which is the one the notes are written in.
            model.recordTarget = model.settings.myLanguage
            if model.recordTarget == "none" { model.recordTarget = "zh-CN" }
        } else {
            model.recordTarget = "none"
        }
    }
}
