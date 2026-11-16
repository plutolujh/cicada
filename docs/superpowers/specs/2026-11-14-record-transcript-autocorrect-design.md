# 录音转写自动纠错设计文档

*创建：2026-11-14*

---

## 1. 意图与背景

**目标**：在录音结束后（或录音中定期），对本地语音识别产生的逐句转写做「段落级 AI 纠错」，把同音字、漏字、标点错误自动修正（如「红西」→「虹吸」），不影响实时显示速度。

**现状**：
- `RecordEngine` 用 `SpeechAnalyzer` 做本地识别，产出 `RecordLine{id, t, text, translation?, lang, voice?, person?, end?, words[]}`
- `text` 即原始识别文本，直接进 UI 列表、存入 `SessionStore.session.lines`（`TranscriptLine{id, t, speaker, src, dst?, srcLang, dstLang, voice?}`）
- 实时显示已是非阻塞：volatile 文本 → 落地行 → 列表刷新，毫秒级
- 会后由 `NotesEngine` 用 AI 生成纪要（已把「语音识别易错，请从上下文纠正」写进 prompt），但**不回写逐句转写**

**痛点**：用户拿到的逐句转写里全是识别错误，需手动改；导出/分享时也带着错字。

---

## 2. 目标与非目标

### Goals
- **段落级纠错**：把全程转写按静默/说话人/时长切成段（~40–60 秒），逐段发 AI，只改错字/漏字/标点，**不改说话人、时间戳、行顺序**
- **双轨保存**：`RecordLine.src` 保留原始识别，新增 `corrected: String?` 存纠错版；`SessionStore` 同步落盘
- **不阻塞实时**：原文先显，纠错在后台跑，完成后原地替换显示（或打「已润色」标记）
- **复用现有 AI 通道**：走 `AIClient.chat(priority: .notes)` + 用户已配的 key（`AIKey` 0600 文件），**不新增 key 存储**
- **可开关**：设置里「识别后自动纠错」默认关（省 key、省钱、隐私敏感可不开）
- **导出可选**：导出转写时可选「原始」或「纠错后」

### Non-Goals
- 实时逐句纠错（延迟高、上下文少、成本大）
- 改说话人、合并/拆分行（那是编辑功能，另做）
- 新增专门的纠错模型/服务/key
- 改动纪要生成逻辑（纪要已有纠错 prompt，保持不变）

### Anti-Goals
- 阻塞 UI 线程等纠错结果
- 把原始识别覆盖掉（丢失对照/回滚能力）
- 在没有 AI key 时静默失败且无提示

---

## 3. 约束

- **Hard rules (AGENTS.md)**：
  - AI key 只在 0600 `<service>-api-key` 文件，走 `AIClient`/`AIProvider`
  - `@MainActor` 引擎 + 音频队列，不阻塞主线程
  - 无三方依赖，Command Line Tools only
  - 中文为键，`L("…")` 本地化，改 UI 后跑 `scripts/strings.py`
- **数据模型**：`RecordLine` / `TranscriptLine` 已在用，改动要向后兼容（旧会话无 `corrected` 也能读）
- **设计基调**：地 `#F3F4F6`、白卡、墨 `#15171C`、强调 `#E8552B`

---

## 4. 数据模型变更

### 4.1 `RecordLine` (RecordEngine.swift)
```swift
struct RecordLine: Identifiable, Equatable {
    let id: String
    var t: Double
    var text: String          // 原始识别（不变）
    var translation: String?
    var lang: String
    var voice: Int?
    var person: Int?
    var end: Double?
    var words: [LiveWord] = []
    // NEW:
    var corrected: String?    // 纠错后文本，nil=未纠错/纠错后无变化
}
```
- `corrected == nil`：未纠错或纠错结果与 `text` 相同
- `corrected != nil && corrected != text`：有修改，UI 显示 `corrected`，原文可点开看

### 4.2 `TranscriptLine` (SessionStore.swift)
```swift
struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String
    var t: Double
    var speaker: String       // "them" | "me"
    var src: String           // 原始识别
    var dst: String?          // 翻译
    var srcLang: String
    var dstLang: String
    var voice: Int? = nil
    // NEW:
    var corrected: String?    // 纠错后文本
}
```
- `SessionStore` 读写 `session.json` 时自动带上 `corrected`（旧文件无此字段解码为 `nil`，兼容）

### 4.3 设置键 (Settings.swift / AppSettings)
```swift
@Published var recordAutoCorrect: Bool = false   // 默认关
```

---

## 5. 纠错流程设计

### 5.1 切段策略（本地、无 AI）
把 `RecordEngine.lines`（或 `Session.lines`）按以下规则切成段：
1. **静默断句**：相邻两行 `t` 差 > 3 秒 → 新段
2. **说话人切换**：`person/voice` 变化 → 新段
3. **最长时长**：段内累计时长 > 60 秒 → 强制切
4. **最短行数**：段内 < 3 行且非最后一段 → 尽量并入下一段

每段包含：`segmentId`, `lines: [RecordLine]`（或 `TranscriptLine`），`startTime`, `endTime`。

### 5.2 Prompt 设计（发给 AI）
```
你是会议转写润色助手。收到一段原始识别文本（含时间戳、说话人），请仅修正错别字、同音字、漏字、标点，**不改说话人标签、不改时间、不增删行、不改变语序、不润色成书面语**。
已知术语表（识别易错→正确）：
- "红西" → "虹吸"
- "张三" → "张叁"（示例）
…

输入（JSON 数组，每项：{id, t, speaker, text}）：
[{"id":"L12","t":45.2,"speaker":"them","text":"甚至红西了附近很多的人..."}, ...]

输出（同结构，只改 text）：
[{"id":"L12","t":45.2,"speaker":"them","text":"甚至虹吸了附近很多的人..."}, ...]
```
- 只发 `id, t, speaker, text`，**不发翻译、不发 words、不发 voice**，减 token
- 术语表取自当前会话的 `MeetingNotes.terms.heard` 映射（已有）

### 5.3 调用时机
| 触发点 | 行为 |
|--------|------|
| 录音结束（`RecordEngine.state == .stopping`） | 全量分段 → 后台任务逐段纠错 → 结果回写 `RecordLine.corrected` → 同步到 `SessionStore` |
| 录音中每 60 秒（可选增量） | 只纠错新增的段，避免会后一次跑太久 |
| 设置开关从关→开，且已有会话 | 对该会话全量跑一次（后台） |

### 5.4 并发与限流
- 复用 `AIClient` 的 `priority: .notes`（同纪要队列，已有速率闸）
- 段落间串行或小并发（`max 2`），避免把纪要挤掉
- 单段超时 30 秒，失败重试 1 次，再失败标记该段「纠错失败」，不阻塞其它段

### 5.5 结果回写
```swift
// RecordEngine
func applyCorrection(segmentId: String, correctedLines: [(id: String, text: String)]) {
    for (id, text) in correctedLines {
        if let idx = lines.firstIndex(where: { $0.id == id }), lines[idx].text != text {
            lines[idx].corrected = text
        }
    }
    // 同步到 SessionStore（若已落盘）
    model?.sessionStore?.updateCorrections(sessionId: currentSessionId, correctedLines)
}
```
- `SessionStore` 新增 `updateCorrections(sessionId, [(lineId, correctedText)])`，原地改 `session.json` 里对应行的 `corrected`

---

## 6. UI 变更

### 6.1 录音页 / 实时识别页转写行
- **默认显示**：`corrected ?? text`
- **指示器**：行尾加个极小灰标「✦ 已润色」（`corrected != nil && corrected != text` 时）
- **长按/右键菜单**：
  - 「查看原文」→ 弹窗对照 `text` vs `corrected`
  - 「撤销纠错」→ 清 `corrected`，回显 `text`
  - 「重新纠错该段」→ 触发该段重跑

### 6.2 设置页
- 新增「识别后自动纠错」开关（`recordAutoCorrect`），默认关
- 开关下灰字一行：「录音结束后在后台自动润色转写，不改说话人与时间；原文保留可对照」

### 6.3 导出（SessionStore.export / AppModel.export）
- `TranscriptExport` 新增 `kind: "corrected"` 或在现有 `markdown/docx/srt` 里加选项
- 导出时：`corrected` 存在用 `corrected`，否则回落 `src/text`

---

## 7. 实现文件清单

| 文件 | 变更 |
|------|------|
| `Sources/LiveSubs/RecordEngine.swift` | `RecordLine` + `corrected`；纠错触发入口 `runAutoCorrect()`；`applyCorrection()` |
| `Sources/LiveSubs/SessionStore.swift` | `TranscriptLine` + `corrected`；`updateCorrections()`；导出逻辑可选 `corrected` |
| `Sources/LiveSubs/AIProvider.swift` / `AIClient.swift` | 新增 `correctTranscriptSegment(...)` 方法（复用 `chat`，仅换 prompt/response 解析） |
| `Sources/LiveSubs/Settings.swift` / 设置视图 | `recordAutoCorrect` @AppStorage/绑定 |
| `Sources/LiveSubs/CaptureViews.swift` / 录音页视图 | 行显示 `corrected ?? text`、指示器、原文对照菜单 |
| `Sources/LiveSubs/NotesEngine.swift` | 复用 `terms.heard` 作为术语表传给纠错 prompt |
| `Resources/{en,ja,ko,zh-Hans}.lproj/Localizable.strings` | 新增文案（自动跑 `strings.py --write` 打 TODO） |

---

## 8. 验收标准

```bash
# 1. 开启开关 → 新建录音 → 说话 30 秒含同音字错误（如「红西」）→ 停止
#    - 实时列表立刻显示原文「红西」（无延迟）
#    - 几秒后该行自动变「虹吸」，尾部出现「✦ 已润色」
#    - 长按可看原文「红西」vs 纠错「虹吸」

# 2. 关闭开关 → 同操作 → 全程显示原文，无纠错、无指示器

# 3. 导出 Markdown（原始/纠错两版）→ 核对文件内容

# 4. 旧会话（无 corrected 字段）打开 → 正常显示、不崩

# 5. 无 AI key 时开启开关 → 录音结束后 Toast「需在设置配置 AI key 才能纠错」，不崩

scripts/build.sh && open build/Cicada.app
scripts/test.sh  # 91 tests 通过
```

---

## 9. 留给建造者的自由度

- 切段阈值（3 秒静默、60 秒上限）可在代码里微调，不需再问
- Prompt 具体措辞可迭代，只要保持「只改错字/标点、不动结构」即可
- 指示器样式（颜色/图标/位置）遵循现有 `Palette`/设计基调即可
- 并发数/超时/重试次数在 `AIClient` 现有限流框架内自行调节

---

## 10. 相关记忆

- [[cicada-record-engine]] `RecordEngine` 现有结构
- [[cicada-session-store]] `SessionStore` 落盘格式
- [[cicada-ai-client]] `AIClient` 优先级/限流
- [[cicada-notes-engine]] `NotesEngine` 已有术语表来源