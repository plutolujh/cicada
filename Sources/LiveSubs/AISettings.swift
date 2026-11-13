import AppKit
import SwiftUI

/// Settings › AI 服务: which service the notes and the translation go to, its key, and what uses it.
struct AISettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: AIClient
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @State private var editing = false

    private var service: AIService { settings.aiService }
    private var provider: AIProvider? { ai.provider(for: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            serviceCard
            keyCard
            Text("用在哪里").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(.top, 4)
            SettingsCard {
                usageRow(L("实时纪要"), tag: ai.usable ? L("用 \(provider?.displayName ?? service.displayName)") : L("需要 key"),
                         on: ai.usable, note: ai.usable ? L("会中每 45 秒更新") : L("填好 key 后可用"))
                usageRow(L("翻译"), tag: ai.usable ? L("用 \(provider?.displayName ?? service.displayName)") : "Google",
                         on: ai.usable, note: ai.usable ? L("整句用它；不行时换 Google、本机") : L("没有 key 时照常可用"))
                usageRow(L("语音识别"), tag: L("本机"), on: false, note: L("更快，不花钱"))
                SettingsRow(title: L("同声传译的声音"),
                            detail: voiceDetail, divider: false) {
                    SoftButton(L("去选声音")) { model.settingsSection = .speak }
                }
            }
            modelCard
            Text(footNote).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
        .onChange(of: settings.aiService) { _, _ in
            // Another service has its own key and its own answer; start its check.
            draft = ""
            editing = false
            if ai.hasKey { Task { await ai.check() } }
        }
    }

    // MARK: Service

    private var serviceCard: some View {
        SettingsCard {
            SettingsRow(title: L("用哪家服务"), detail: serviceDetail, divider: false) {
                PillMenu(value: provider?.displayName ?? service.displayName,
                         options: AIService.allCases.map { ($0.id, $0.displayName) }) { id in
                    settings.aiService = AIService(rawValue: id) ?? .ling
                }
            }
        }
    }

    private var serviceDetail: String {
        switch service {
        case .ling: L("Ling 的纪要和 Ming 的声音")
        case .minimax: L("MiniMax 的纪要和声音")
        case .custom: L("任何 OpenAI 兼容的接口")
        }
    }

    // MARK: Key

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                if let detail = statusDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                Spacer()
            }
            if let key = ai.key, !editing {
                HStack(spacing: 8) {
                    Text(AIKey.masked(key)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    SoftButton(L("更换")) { draft = ""; editing = true }
                    if case .invalid = ai.keyState {} else if case .unreachable = ai.keyState {
                        SoftButton(L("重试")) { Task { await ai.check() } }
                    } else if case .quota = ai.keyState {
                        SoftButton(L("重试")) { Task { await ai.check() } }
                    } else if case .plan = ai.keyState {
                        SoftButton(L("重试")) { Task { await ai.check() } }
                    } else if case .retired = ai.keyState {
                        SoftButton(L("重试")) { Task { await ai.check() } }
                    }
                }
            } else {
                if ai.key == nil {
                    Text(provider?.keyHint ?? L("填入服务商的 API key。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 8) {
                    SecureField(provider?.keyPlaceholder ?? "sk-…", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
                        .onSubmit(save)
                    SoftButton(L("保存并检查"), dark: true, action: save)
                    if editing { SoftButton(L("取消")) { editing = false } }
                }
                if let url = provider?.keyURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text(L("打开 \(provider?.displayName ?? "") 平台 ↗"))
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Text(L("只存在这台 Mac 上（只有你的账户能读），只发给 \(provider?.displayName ?? service.displayName)"))
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                if ai.key != nil && !editing {
                    Button(L("移除")) { ai.removeKey() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.961, green: 0.965, blue: 0.973)))
    }

    // MARK: Model

    @ViewBuilder
    private var modelCard: some View {
        if service == .custom {
            SettingsCard {
                SettingsRow(title: L("接口地址"), detail: L("服务商的 OpenAI 兼容地址"), divider: true) {
                    TextField("https://…/v1", text: $settings.aiBaseURL)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .frame(width: 220).frame(height: 28)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ground))
                }
                SettingsRow(title: L("模型名"), detail: L("这个地址上的模型"), divider: false) {
                    TextField("gpt-4o-mini", text: $settings.aiCustomModel)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .frame(width: 220).frame(height: 28)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ground))
                }
            }
        } else {
            SettingsCard {
                SettingsRow(title: L("模型"), detail: modelDetail, divider: false) {
                    PillMenu(value: modelName, options: (provider?.models ?? []).map { ($0, $0) }) { settings.aiModels[service.rawValue] = $0 }
                }
            }
        }
    }

    private var modelName: String {
        settings.aiModel(for: service, fallback: provider?.defaultModel ?? "",
                         allowed: provider?.models ?? [])
    }

    private var modelDetail: String {
        service == .ling ? L("3.1 更准；3.0 更快、更省") : L("用它自己列出的模型")
    }

    // MARK: Details

    private var voiceDetail: String {
        guard ai.usable else { return L("没有 key 时用本机声音") }
        guard provider?.canSpeak == true else { return L("这家没有自带声音，用本机声音") }
        return provider?.canClone == true ? L("它自己的声音或你自己的声音") : L("用它自己的声音")
    }

    private var footNote: String {
        switch service {
        case .ling: L("一小时会议约 ¥0.15–1（目前优惠价）。发出去的只有文字（用你自己的声音时还有那段录音），语音识别留在本机。")
        case .minimax: L("按 MiniMax 的价格或套餐额度计费。发出去的只有文字，语音识别留在本机；同声传译没有音频模型，按下说话键时先在本机转写再翻译。")
        case .custom: L("按你填的地址计费。发出去的只有文字，语音识别留在本机。")
        }
    }

    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        draft = ""
        editing = false
        Task { await ai.setKey(k) }
    }

    private var statusColor: Color {
        switch ai.keyState {
        case .ok: Palette.ok
        case .invalid, .unreachable, .plan, .retired: Palette.error
        case .quota, .checking, .unchecked: Palette.accent
        case .none: Color(white: 0.75)
        }
    }

    private var statusTitle: String {
        switch ai.keyState {
        case .none: L("还没填 API key")
        case .unchecked, .checking: L("正在检查…")
        case .ok: L("已连接")
        case .invalid: L("这个 key 用不了")
        case .unreachable: L("暂时连不上")
        case .quota: L("套餐额度用完了")
        case .plan: L("套餐里没有这一项")
        case .retired: L("这个模型用不了了")
        }
    }

    private var statusDetail: String? {
        switch ai.keyState {
        case .ok(let s): L("\(modelName) · 响应约 \(String(format: "%.1f", s)) 秒")
        case .invalid: L("\(provider?.displayName ?? "") 提示此密钥无效，请检查是否复制完整，或重新创建一个")
        case .unreachable(let why): why
        case .quota: L("等额度窗口刷新，或换一个 key")
        case .plan: L("这个 key 或模型不在套餐里，换一个试试")
        case .retired: L("平台已经下线了这个模型，换一个试试")
        case .none: L("不填 key 时，字幕和翻译仍可正常使用")
        default: nil
        }
    }

    private func usageRow(_ title: String, tag: String, on: Bool, note: String, divider: Bool = true) -> some View {
        SettingsRow(title: title, detail: note, divider: divider) {
            Text(tag).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Palette.ok : Palette.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.okPale : Palette.fill))
        }
    }
}
