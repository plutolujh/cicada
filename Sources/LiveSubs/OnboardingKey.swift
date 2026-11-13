import AppKit
import SwiftUI

/// Onboarding step 3: connect an AI service. The notes, the better translation and the service's
/// voices all need a key, but it comes after the sample video, once people have seen what the app
/// does. Skipping is allowed: "先不接" first shows what still works and what waits for a key (the
/// notes window asks again later).
struct OnboardingKeyStep: View {
    @ObservedObject var ai: AIClient
    @ObservedObject var settings: AppSettings
    /// "先不接" was clicked: the card shows what skipping leaves out until 回去接上 or 好，先这样.
    @Binding var skipping: Bool
    @State private var draft = ""
    @State private var clipboardEmpty = false

    private var service: AIService { settings.aiService }
    private var provider: AIProvider? { ai.provider(for: service) }
    private var name: String { provider?.displayName ?? service.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("接上 \(name)，用上完整的知了")).font(.system(size: 26, weight: .bold)).foregroundStyle(Palette.ink)
                Text(L("纪要、更准的翻译和自然的同传语音都靠它，约 1 分钟。"))
                    .font(.system(size: 14)).foregroundStyle(Palette.secondary)
            }
            if case .ok = ai.keyState { connected } else if skipping { withoutKey } else { entry }
            if !skipping, service == .ling {
                HStack(spacing: 10) {
                    Text("Ling 每月赠送 ¥10 额度").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.accentPale))
                    Text("约够 10–50 小时会议")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    // MARK: Not connected yet

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                number(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("用哪家服务")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(L("之后可以在设置里换")).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
                PillMenu(value: name, options: AIService.allCases.map { ($0.id, $0.displayName) }) { id in
                    settings.aiService = AIService(rawValue: id) ?? .ling
                    draft = ""
                    clipboardEmpty = false
                }
            }
            .padding(.bottom, 18)
            if let url = provider?.keyURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 5) {
                        Text(L("打开 \(name) 平台"))
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.fill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                number(2)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("复制 key，回来粘贴")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    HStack(spacing: 8) {
                        SecureField(provider?.keyPlaceholder ?? "sk-…", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.35), lineWidth: 1))
                            .onSubmit { save(draft) }
                        Button(action: pasteAndCheck) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 12))
                                Text(draft.isEmpty ? L("粘贴并检查") : L("保存并检查"))
                            }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ink))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    status
                }
            }
            .padding(.top, 18)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        switch ai.keyState {
        case .checking, .unchecked:
            line(Palette.accent, L("正在检查…"), Palette.secondary)
        case .invalid:
            line(Palette.error, L("这个 key 无效，请检查是否复制完整，或重新创建一个"), Palette.accentInk)
        case .unreachable(let why):
            line(Palette.error, why, Palette.accentInk)
        default:
            if clipboardEmpty {
                line(Palette.error, L("剪贴板里没有 key，先去平台复制。"), Palette.accentInk)
            } else {
                Label(L("只保存在这台 Mac 上，只发给 \(name)"), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    // MARK: Connected

    private var connected: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ok)
                    .frame(width: 24, height: 24).background(Circle().fill(Palette.okPale))
                Text("已连接").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                if case .ok(let s) = ai.keyState {
                    Text(L("\(modelName) · 响应约 \(String(format: "%.1f", s)) 秒"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if let key = ai.key {
                    Text(AIKey.masked(key)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
            }
            Divider()
            Text("现在可以用了").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            HStack(spacing: 10) {
                benefit(L("实时纪要"), L("会中每 45 秒更新"))
                benefit(L("更准的翻译"), L("人名、术语前后一致"))
                benefit(L("自然人声"), L("同传约 2 秒出声"))
            }
            Text("开会时，纪要会跟着字幕一起更新。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    // MARK: Skipping

    /// Honest about both sides, so skipping is a choice rather than a dead end.
    private var withoutKey: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("先不接也行，基础功能照常能用").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: 10) {
                column(L("现在可用"), [L("实时翻译字幕"), L("双语文字记录"), L("同声传译（系统语音）")],
                       head: Palette.secondary, fill: Palette.ground, check: true)
                column(L("接上 \(name) 才有"), [L("实时纪要和会后总结"), L("人名、术语前后一致"), L("自然人声，约 2 秒出声")],
                       head: Palette.accentInk, fill: Palette.accentPale, check: false)
            }
            Text("随时可在纪要窗口或设置里接上，开完的会也能补出纪要。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    private func column(_ title: String, _ items: [String], head: Color, fill: Color, check: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(head)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    if check { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ink) }
                    Text(item).font(.system(size: 14)).foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(fill))
    }

    // MARK: Pieces

    private func number(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
            .frame(width: 26, height: 26).background(Circle().fill(Palette.fill))
    }

    private func line(_ dot: Color, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benefit(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ground))
    }

    /// The model the service will use, the way the settings page shows it.
    private var modelName: String {
        settings.aiModel(for: service, fallback: provider?.defaultModel ?? "",
                         allowed: provider?.models ?? [])
    }

    /// Reads the clipboard only when the button is clicked (a deliberate paste, so macOS's paste
    /// privacy prompt, if any, makes sense to the user); a typed key is checked as typed.
    private func pasteAndCheck() {
        if !draft.isEmpty { save(draft); return }
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A key is one long run of characters with no spaces; its exact shape differs per service.
        guard text.count >= 16, !text.contains(where: \.isWhitespace) else { clipboardEmpty = true; return }
        save(text)
    }

    private func save(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        clipboardEmpty = false
        draft = ""
        Task { await ai.setKey(k) }
    }
}

/// Step 3's footer. 继续 waits for a working key; "先不接" turns the card into what skipping leaves out,
/// and only "好，先这样" there moves on without one.
struct OnboardingKeyFooter: View {
    @ObservedObject var ai: AIClient
    @Binding var skipping: Bool
    var next: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if case .ok = ai.keyState {
                primary(L("继续"), arrow: true, action: next)
            } else if skipping {
                Button { skipping = false } label: {
                    Text("回去接上")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.84), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                primary(L("好，先这样"), arrow: false) { skipping = false; next() }
            } else {
                Button("先不接") { skipping = true }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                Text("接上后继续")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 24).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.87)))
            }
        }
    }

    private func primary(_ text: String, arrow: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text)
                if arrow { Image(systemName: "arrow.right") }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 28).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ink))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}
