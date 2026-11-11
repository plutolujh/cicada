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
                        HStack(alignment: .top, spacing: 10) {
                            Text(RecordEngine.clock(engine.elapsed))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                                .frame(width: 40, alignment: .leading)
                            Text(engine.live).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                            Spacer(minLength: 0)
                        }
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

    /// One settled sentence: when it was said, what was said, and what it means.
    private func row(_ line: RecordLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(RecordEngine.clock(line.t))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.tertiary)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let t = line.translation, !t.isEmpty {
                    Text(t).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
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
