import AppKit
import SwiftUI

/// The passage from a finished recording to the meeting record.
///
/// The recording does not simply stop: the audio, the words, the translation and the notes all
/// go into one meeting, and this shows that happening — each part landing in turn — before the
/// record opens.
struct RecordSavingView: View {
    let saving: RecordSaving
    /// Opens the meeting the recording became.
    var onOpen: () -> Void = {}

    @State private var landed: Set<RecordSaving.Part> = []
    /// All the parts have landed and the record is complete: only then the user is asked to
    /// confirm and open the meeting record.
    @State private var allLanded = false

    var body: some View {
        ZStack {
            // The surface behind fades out of the way.
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15)).foregroundStyle(Palette.accent)
                        Text("已保存到会议记录").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }

                    Text(saving.title)
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.top, 3)

                    // Each part of the record lands in turn.
                    HStack(spacing: 10) {
                        ForEach(Array(saving.parts.enumerated()), id: \.element) { i, part in
                            partChip(part)
                                .opacity(landed.contains(part) ? 1 : 0)
                                .offset(y: landed.contains(part) ? 0 : 6)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .padding(.top, 16)

                    Text(L("\(saving.lines) 句 · \(RecordEngine.clock(saving.duration))"))
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                        .padding(.top, 14)

                    HStack(spacing: 8) {
                        Button(action: onOpen) {
                            Text("查看会议记录").font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!allLanded)
                        .opacity(allLanded ? 1 : 0.5)
                    }
                    .padding(.top, 18)

                    Spacer(minLength: 0)
                }
                .padding(22)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                .padding(.horizontal, 40)

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            // The parts land one after another: the reading has a shape, not a jump.
            let total = saving.parts.count
            for (i, part) in saving.parts.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.22) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        landed.insert(part)
                        if landed.count == total { allLanded = true }
                    }
                }
            }
        }
    }

    private func partChip(_ part: RecordSaving.Part) -> some View {
        HStack(spacing: 6) {
            Image(systemName: part.glyph).font(.system(size: 11))
            Text(part.title).font(.system(size: 12))
        }
        .foregroundStyle(Palette.ink.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
    }
}
