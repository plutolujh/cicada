import AppKit
import SwiftUI

// The export panel: what goes into the file, and in which format.
//
// The notes have two readings — the visualization and the written summary — and the transcript
// is a third thing. The panel asks which of them the file should have; nothing is written
// until the file itself is chosen.

struct ExportSheet: View {
    @ObservedObject var model: AppModel
    /// The panel is closed: either the export was started or it was cancelled.
    var onClose: () -> Void = {}

    private var options: ExportOptions { model.exportOptions }
    private var session: Session? { model.exportRequest?.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                content
                format
            }
            .padding(20)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 440, height: 340)
        .background(Color.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("导出会议记录")).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
            if let s = session {
                Text(s.displayTitle).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
    }

    /// What the file should contain.
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("包含")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            row(L("AI 视图"), L("议题、鱼骨图、结论和待办"), $model.exportOptions.aiView)
            row(L("文字总结"), L("总结和议题的文字"), $model.exportOptions.textSummary)
            row(L("原始记录"), L("原话和翻译"), $model.exportOptions.transcript)
        }
    }

    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .tint(Palette.accent)
    }

    /// Which file the reader can open.
    private var format: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("格式")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            Picker("", selection: $model.exportOptions.format) {
                Text("Markdown").tag(ExportOptions.Format.md)
                Text("Word").tag(ExportOptions.Format.word)
                Text("PDF").tag(ExportOptions.Format.pdf)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            SoftButton(L("取消")) { onClose() }
            SoftButton(L("导出…"), dark: true) {
                guard let s = session else { return }
                // The panel stays open until the file is written: the save sheet hangs off it,
                // and closing the panel would take the sheet with it.
                model.export(s, kind: model.exportOptions.format.rawValue, options: model.exportOptions) {
                    onClose()
                }
            }
            .disabled(options.isEmpty)
            .opacity(options.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
