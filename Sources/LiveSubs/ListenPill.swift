import AppKit
import SwiftUI

/// The main window's toolbar: the listening pill centred, settings on the right. A real toolbar,
/// so macOS centres the window buttons on the same line instead of leaving them above it.
@MainActor final class MainToolbar: NSObject, NSToolbarDelegate {
    static let pill = NSToolbarItem.Identifier("cicada.pill")
    static let settings = NSToolbarItem.Identifier("cicada.settings")
    let model: AppModel

    init(model: AppModel) { self.model = model }

    func make() -> NSToolbar {
        let t = NSToolbar(identifier: "cicada.main")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        t.centeredItemIdentifiers = [Self.pill]
        return t
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pill, .flexibleSpace, Self.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let root: AnyView
        if id == Self.pill {
            // The floating pill takes over when it is on screen: one pill, not two.
            root = AnyView(ListenPill(model: model, hiddenWhileFloating: true))
            item.label = L("开始听")
        } else {
            root = AnyView(
                Button { [model] in model.openSettings() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("设置")
            )
            item.label = L("设置")
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = .intrinsicContentSize
        item.view = host
        item.isBordered = false
        return item
    }
}

/// The listening switch, led by the logo: still in a white pill while idle, breathing in an ink pill while
/// listening, ringed by a countdown when the meeting is about to end. The brand is the switch.
struct ListenPill: View {
    @ObservedObject var model: AppModel
    @State private var endingTotal: Double = 30
    /// True in the floating panel: the toolbar's own pill steps aside, so there is one pill on
    /// screen, not two copies of the same state.
    var hiddenWhileFloating = false
    /// Where the pill's buttons are, in the pill's own coordinates. The double click opens the
    /// main window only on the pill's body: a double click on a button belongs to that button.
    @State private var buttonRegions: [CGRect] = []

    var body: some View {
        Group {
            if hiddenWhileFloating, model.floatingPillVisible {
                Color.clear.frame(width: 0, height: 0)
            } else if model.running, let p = model.ending {
                ending(p)
            } else if model.running, model.listeningPaused {
                listeningPaused
            } else if model.running {
                listening
            } else if model.micState == .recording || model.micState == .preparing {
                recording
            } else if model.micState == .paused {
                paused
            } else if model.micState == .stopping {
                recording
            } else {
                idle
            }
        }
        .animation(.spring(duration: 0.35), value: model.running)
        .animation(.spring(duration: 0.35), value: model.ending)
        .animation(.spring(duration: 0.35), value: model.micState)
        .onChange(of: model.ending) { _, p in
            if let p { endingTotal = max(1, p.deadline.timeIntervalSinceNow) }
        }
        // A double click on the pill's body opens the main window: the pill is small and its
        // buttons are few, so this is the way back to the records without hunting for the menu.
        .onTapGesture(count: 2) { location in
            guard !isOverButton(location) else { return }
            model.openMainWindow?()
        }
        .coordinateSpace(name: "PillLocalSpace")
        .onPreferenceChange(PillLocalButtonRegions.self) { buttonRegions = $0 }
        .padding(.vertical, 2)
        // A toolbar item keeps the width it was first laid out at: a fixed slot, wide enough for
        // the longest state (the English countdown), with the pill centred in it.
        .frame(width: 420)
    }

    /// Whether a click at this point landed on one of the pill's buttons. The regions are
    /// reported in the same coordinate space the tap gives, so they can be compared directly.
    private func isOverButton(_ location: CGPoint) -> Bool {
        buttonRegions.contains { $0.contains(location) }
    }

    private var idle: some View {
        Button { model.setRunning(true) } label: {
            HStack(spacing: 9) {
                // In colour while idle too: the white pill against the ink one already tells off from on.
                BrandMark(size: 22)
                Text(L("知了")).font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
                Rectangle().fill(Palette.line).frame(width: 1, height: 14)
                Text(model.autoEnded ? L("会议已自动结束") : L("开始听"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("⌘R").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                // The recording is the second switch: a different microphone, the same notes.
                Rectangle().fill(Palette.line).frame(width: 1, height: 14)
                recordIdle
            }
            .padding(.leading, 6).padding(.trailing, 12).frame(height: 32)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pillButton()
        .accessibilityLabel(L("开始听"))
    }

    /// The recording switch, when neither is running. It is the microphone instead of the
    /// system audio: a recording of a person, kept as a meeting.
    private var recordIdle: some View {
        Button { model.startRecording() } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic").font(.system(size: 11))
                Text(L("开始录")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("⌘⇧R").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }
        .buttonStyle(.plain)
        .pillButton()
        .accessibilityLabel(L("开始录"))
    }

    /// The listening state: breathing mark, 正在听, level meter, timer, 暂停 / 结束.
    private var listening: some View {
        HStack(spacing: 10) {
            Button { model.requestStop() } label: { BreathingMark(size: 22) }
                .buttonStyle(.plain).pillButton().accessibilityLabel(L("结束会议"))
            Text("正在听").font(.system(size: 13, weight: .semibold))
            LevelMeter(model: model, bars: 8, height: 15, color: Palette.accent)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TranscriptExport.clock(max(0, model.listenElapsed)))
                    .font(.system(size: 13).monospacedDigit())
            }
            Button { model.pauseListening() } label: {
                Text("暂停").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("暂停收听"))
            Button { model.requestStop() } label: {
                Text("结束").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("结束会议"))
        }
        .foregroundStyle(.white)
        .padding(.leading, 5).padding(.trailing, 4).frame(height: 32)
        .background(Capsule().fill(Palette.ink))
        .help(model.summary)
    }

    /// The listening is on hold: the tap is still open and the meter still moves, but nothing
    /// said while paused is written down. 恢复 / 结束.
    private var listeningPaused: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.fill").font(.system(size: 16)).foregroundStyle(Palette.accent)
            Text("已暂停").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            LevelMeter(model: model, bars: 8, height: 15, color: Palette.accent)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TranscriptExport.clock(max(0, model.listenElapsed)))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
            }
            Button { model.resumeListening() } label: {
                Text("恢复").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("恢复收听"))
            Button { model.requestStop() } label: {
                Text("结束").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("结束会议"))
        }
        .padding(.leading, 5).padding(.trailing, 4).frame(height: 32)
        .background(Capsule().fill(Palette.ink))
        .help(L("收听已暂停"))
    }

    /// The recording state: mic icon, 正在录, level meter, timer, 暂停 / 停止.
    private var recording: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill").font(.system(size: 16)).foregroundStyle(Palette.accent)
            Text("正在录").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            LevelMeter(model: model, bars: 8, height: 15, color: Palette.accent, source: .microphone)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TranscriptExport.clock(max(0, model.recorder.elapsed)))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
            }
            Button { model.recorder.pause() } label: {
                Text("暂停").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("暂停录音"))
            Button { model.endRecording() } label: {
                Text("停止").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("停止录音"))
        }
        .padding(.leading, 5).padding(.trailing, 4).frame(height: 32)
        .background(Capsule().fill(Palette.ink))
        .help(L("麦克风录音中"))
    }

    /// The paused state: the mic is still on but nothing is being written. 恢复 / 停止.
    private var paused: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.fill").font(.system(size: 16)).foregroundStyle(Palette.accent)
            Text("已暂停").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            LevelMeter(model: model, bars: 8, height: 15, color: Palette.accent, source: .microphone)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TranscriptExport.clock(max(0, model.recorder.elapsed)))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
            }
            Button { model.recorder.resume() } label: {
                Text("恢复").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("恢复录音"))
            Button { model.endRecording() } label: {
                Text("停止").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pillButton()
            .accessibilityLabel(L("停止录音"))
        }
        .padding(.leading, 5).padding(.trailing, 4).frame(height: 32)
        .background(Capsule().fill(Palette.ink))
        .help(L("录音已暂停"))
    }

    private func ending(_ p: MeetingEndWatch.Pending) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, p.deadline.timeIntervalSince(ctx.date))
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color(red: 0.227, green: 0.239, blue: 0.27), lineWidth: 2.5)
                    Circle().trim(from: 0, to: min(1, left / endingTotal))
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BrandMark(size: 16)
                }
                .frame(width: 26, height: 26)
                Text(model.endingTitle(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(L("\(Int(left.rounded())) 秒后结束"))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color(red: 0.957, green: 0.647, blue: 0.549))
                Button { model.keepRecording() } label: {
                    Text("继续记录").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pillButton()
            }
            .foregroundStyle(.white)
            .padding(.leading, 4).padding(.trailing, 4).frame(height: 32)
            .background(Capsule().fill(Palette.ink))
        }
    }
}

/// The logo with accent rings swelling out of it while Cicada listens.
struct BreathingMark: View {
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrandMark(size: size)
            .background {
                if !reduceMotion {
                    ZStack {
                        Ring(size: size, delay: 0)
                        Ring(size: size, delay: 1.1)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private struct Ring: View {
        let size: CGFloat
        let delay: Double
        @State private var out = false
        var body: some View {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Palette.accent)
                .scaleEffect(out ? 1.7 : 1).opacity(out ? 0 : 0.55)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(delay)) { out = true }
                }
        }
    }
}

/// An accent dot with a ring that keeps swelling out of it: "live", without blinking.
struct BreathingDot: View {
    var size: CGFloat = 8
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Palette.accent).frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    Circle().fill(Palette.accent)
                        .scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 0.6)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { out = true }
            }
            .accessibilityHidden(true)
    }
}

/// Bars that follow the loudness of what Cicada hears, newest on the right.
struct LevelMeter: View {
    @ObservedObject var model: AppModel
    var bars = 9
    var height: CGFloat = 16
    var color: Color = Palette.accent
    /// Where the levels come from: the system audio while listening, the microphone while
    /// recording. Both are read the same way, so the pill and the capture surface show the
    /// same meter.
    var source: LevelSource = .system
    @State private var levels: [CGFloat] = []
    private let tick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    /// The two inputs the meter can show.
    enum LevelSource {
        case system
        case microphone
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let v = i < levels.count ? levels[i] : 0
                Capsule().fill(color).frame(width: 2.5, height: max(3, v * height))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: levels)
        .onReceive(tick) { _ in
            let v: CGFloat
            switch source {
            case .microphone:
                // The recorder keeps its own 0…1 level; it is the same number the scope draws.
                guard model.recorder.state == .recording || model.recorder.state == .paused else { return }
                v = CGFloat(model.recorder.level)
            case .system:
                guard model.running else { return }
                // Map −40…0 dBFS onto the bar height: quiet speech sits low, a loud voice near the top.
                let rms = model.listen.router.takeLevel()
                let db = 20 * log10(max(Double(rms), 1e-6))
                v = CGFloat(min(1, max(0, (db + 40) / 40)))
            }
            levels = Array((levels + [v]).suffix(bars))
        }
        .accessibilityHidden(true)
    }
}
