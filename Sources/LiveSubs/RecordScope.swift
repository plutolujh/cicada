import SwiftUI

/// The scope next to the record button: it shows how loud the microphone hears you right now.
///
/// The wave is the last few seconds, newest on the right, drawn as one smooth shape rather
/// than bars: a curve reads the small rises and falls of a voice, where bars only show the
/// loud parts. The height is relative to the loudest moment of that window, so a quiet voice
/// still fills the box and a silent room still looks silent.
struct RecordScope: View {
    /// The levels of the last seconds, 0…1, oldest first.
    var levels: [Float]
    /// Whether the microphone is being listened to right now.
    var live: Bool

    /// How wide the scope is.
    private let width: CGFloat = 76
    /// How tall it is.
    private let height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            let samples = live ? levels : []
            let mid = size.height / 2
            let half = max(1, mid - 2)

            // The centre line the wave sits on.
            context.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: mid))
                p.addLine(to: CGPoint(x: size.width, y: mid))
            }, with: .color(Palette.line), lineWidth: 1)

            guard samples.count > 1 else { return }

            // Auto-gain: once there is sound, the loudest moment of the window fills most of
            // the box, so a soft voice is still seen. A room that is only noise stays small,
            // because it never reaches the threshold.
            let peak = CGFloat(samples.max() ?? 0)
            let gain: CGFloat = peak > 0.22 ? min(2.4, 0.66 / peak) : 1
            let heights = samples.map { min(1, CGFloat($0) * gain) * half }

            // One point per sample, spread across the width; the newest is on the right.
            let step = size.width / CGFloat(max(heights.count - 1, 1))
            let top = heights.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: mid - $0.element) }
            let bottom = heights.enumerated().reversed().map { CGPoint(x: CGFloat($0.offset) * step, y: mid + $0.element) }

            let shape = closedWave(top: top, bottom: bottom)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [Palette.accent.opacity(0.75), Palette.accent.opacity(0.28),
                                  Palette.accent.opacity(0.75)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            // The edge of the wave, a shade darker than the fill.
            context.stroke(shape, with: .color(Palette.accent.opacity(0.55)), lineWidth: 1)

            // The peak of the window, held as a mark on the right: how loud it got.
            if let loudest = heights.max(), loudest > 1 {
                let y = mid - loudest
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: size.width - 5, y: y))
                    p.addLine(to: CGPoint(x: size.width - 5, y: y + 6))
                }, with: .color(Palette.accentInk.opacity(0.5)), lineWidth: 1.5)
            }
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
        .help(L("麦克风的响度"))
    }

    /// The wave as one closed shape: the upper edge forwards, the lower edge back.
    private func closedWave(top: [CGPoint], bottom: [CGPoint]) -> Path {
        var p = Path()
        guard let first = top.first else { return p }
        p.move(to: first)
        for (a, b) in zip(top, top.dropFirst()) {
            let dx = (b.x - a.x) / 3
            p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        }
        for (a, b) in zip(bottom, bottom.dropFirst()) {
            let dx = (b.x - a.x) / 3
            p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        }
        p.closeSubpath()
        return p
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
