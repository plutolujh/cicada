import SwiftUI

/// The scope next to the record button: it shows how loud the microphone hears you right now.
///
/// The bars are the last few seconds, newest on the right, so a gap in the speech shows up as a
/// gap. The height is relative to the loudest moment of that window, not to the absolute level:
/// a scope that is always full when somebody talks says nothing about how loud they were, and a
/// room that is quiet but constant would otherwise sit at the bottom of the box.
struct RecordScope: View {
    /// The levels of the last seconds, 0…1, oldest first.
    var levels: [Float]
    /// Whether the microphone is being listened to right now.
    var live: Bool

    /// How wide the scope is.
    private let width: CGFloat = 96
    /// How tall it is.
    private let height: CGFloat = 26
    /// How many bars there are, however many samples there are.
    private let bars = 24

    var body: some View {
        Canvas { context, size in
            let samples = levels
            let step = size.width / CGFloat(bars)
            let barWidth = max(1, step * 0.55)
            for i in 0..<bars {
                // The newest sample is on the right; older ones fill in to the left.
                let index = samples.count - bars + i
                guard index >= 0 else { continue }
                let level = live ? CGFloat(samples[index]) : 0
                let barHeight = max(1.5, level * size.height)
                let x = CGFloat(i) * step + (step - barWidth) / 2
                let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(level > 0.02 ? Palette.accent : Palette.line))
            }
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
        .help(L("麦克风的响度"))
    }
}

/// The clock of the recording: how long it has been running.
struct RecordClock: View {
    /// The seconds the recording has run.
    var elapsed: TimeInterval
    /// Whether the microphone is being listened to right now.
    var live: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 10))
            Text(RecordEngine.clock(elapsed)).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(live ? Palette.accentInk : Palette.secondary)
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(live ? Palette.accentPale : Palette.fill))
        .help(L("录音时长"))
    }
}
