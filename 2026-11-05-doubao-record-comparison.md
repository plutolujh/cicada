# 豆包录音转录功能对比 & 实现计划

*文档创建：2026-11-11*

---

## 1. 豆包录音转录的核心体验（基于公开产品形态推断）

| 维度 | 豆包典型体验 | Cicada 现状 |
|------|-------------|-------------|
| **入口** | 主界面显眼「录音」入口，一键开始 | 主窗口有「录音」标签页，但入口在菜单栏/主窗口切换中 |
| **录音态** | 大按钮 + 实时波形/音量条，计时器显眼 | `RecordView` 有红点按钮 + `elapsed` 计时 + `level` 音量，已具备 |
| **实时转写** | **逐字流式**出现，高亮当前句，自动分段、标点、说话人 | `engine.live` 只显示**最后一句易变文本**，已落地的 `lines` 不再动；无逐字流式高亮 |
| **说话人** | 自动区分「说话人 1/2/…」，支持重命名、合并 | `RecordLine.person` + `SpeakerTagger` 钩子已有，**但 UI 不展示重命名/合并** |
| **翻译** | 同屏双语，目标语言可随时切换 | `target` 芯片可切，`line.translation` 已存，**但无「原文/译文/双语」三态切换** |
| **实时总结** | 右侧/底部滚动更新：议题、结论、待办、关键词 | `RecordTopic` + `refreshSummary()` 已跑，**但只有「议题+要点」，缺结论/待办/鱼骨图** |
| **录音回放** | 点任意句子跳转播放，变速、静音检测跳过 | `keepsAudio` 存了 `audioURL`，**但 `RecordView` 完全没有播放控件** |
| **编辑/修正** | 长按/点击句子可改文本、改说话人、合并/拆分 | **不可编辑**，`RecordLine` 是 `let` 只有 `translation` 可改 |
| **导出** | 一键导出 Markdown/Word/SRT/JSON，含时间戳/说话人/翻译 | `AppMenu` 有导出菜单，**但录音会话未接入 `SessionStore` 导出流程** |
| **会话管理** | 列表页：重命名、删除、搜索、标签、云同步 | 录音只存在内存，**无持久化会话列表**，`RecordEngine.demo()` 只演示 |
| **多语言** | 中英混说自动切模型，支持方言/粤语/日韩等 | `detectsLanguage` + `candidates` 多模型切换已有，**但无方言/粤语模型** |
| **隐私** | 本地识别可选，云端可关 | 全本地 `SpeechAnalyzer`，**完全符合** |

---

## 2. 差距清单（按优先级）

| # | 缺口 | 涉及文件 | 难度 |
|---|------|----------|------|
| 1 | **逐字流式转写**：`live` 只显示最后一句，不高亮、不逐字 | `RecordEngine.swift` (analyzer 回调), `RecordViews.swift` (transcript 行) | 中 |
| 2 | **句子可编辑/改说话人/合并拆分** | `RecordLine` 改 `var`, `RecordViews.swift` 加编辑态, `RecordEngine` 加 `replaceLine/merge/split` | 中 |
| 3 | **音频回放**：点句子跳转、变速、静音跳过 | `RecordEngine.audioURL` + `AVAudioPlayer`, `RecordView` 行加播放按钮 | 中 |
| 4 | **实时总结增强**：结论/待办/鱼骨图/术语表 | `RecordTopic` 扩展字段, `refreshSummary` prompt 重写, `topicView` 新增区块 | 低 |
| 5 | **会话持久化 & 列表页**：落盘、重命名、删除、搜索、导出 | 新增 `RecordSession` 模型, `SessionStore` 复用/扩展, 新建 `RecordsWindow` | 高 |
| 6 | **双语显示三态**：原文/译文/双语切换 | `RecordView` 加 `Segments` 控件, `line.translation` 渲染逻辑分支 | 低 |
| 7 | **说话人重命名/合并 UI** | `PersonNumbers` 暴露映射, `RecordView` 加重命名弹窗, `RecordEngine` 同步修改 | 中 |
| 8 | **入口显眼化**：菜单栏/主窗口「录音」一键直达 | `AppMenu.swift` 加「新录音」, `AppModel` 加 `newRecording()` | 低 |
| 9 | **方言/粤语模型** | `Lang` 扩展, `SpeechTranscriber` locale 支持 | 低(数据) |

---

## 3. 具体实现路线（分 3 期，每期可独立验收）

### Phase 1 — 核心体验对齐（1-2 周）
**目标**：把现有「录音」页做到可用、可回放、可编辑、可导出单次录音。

| 任务 | 代码变更点 | 验收标准 |
|------|------------|----------|
| 1.1 逐字流式：`RecordEngine` 把 `SpeechAnalyzer` 的 `volatile` 片段下发到 `liveSegments: [LiveSegment]`（`text`+`range`），`RecordView` 用 `Text` + `ForegroundStyle` 高亮当前段 | `RecordEngine.swift` 新增 `@Published var liveSegments`, `handleResult` 追加; `RecordViews.swift` `transcript` 行渲染 `liveSegments` | 说话时文字像打字机逐字出现，当前段高亮 |
| 1.2 `RecordLine` 全部改 `var`，新增 `replaceText(_:)`, `mergeWith(next:)`, `split(at:)`，`RecordEngine` 暴露 `editLine(id, newText)`, `mergeLines(id, nextId)`, `splitLine(id, offset)` | `RecordEngine.swift` `struct RecordLine` 去 `let`→`var`, 加方法; `RecordViews.swift` 行加长按/双击进入编辑态 | 双击句子可改文本，工具栏出现「合并/拆分」 |
| 1.3 音频回放：`RecordEngine` 持有 `AVAudioPlayer?`, `play(from: TimeInterval)`, `pause()`, `seek(to:)`；`RecordView` 每行左侧加 `▶️` 按钮，点击 `engine.play(from: line.t)` | `RecordEngine.swift` 加 `audioPlayer`, `func play/pause/seek`; `RecordViews.swift` `row(_:)` 加播放按钮 | 点任意句子从该处播放，再次点击暂停，波形/进度可选 |
| 1.4 双语三态：`RecordView` 顶部加 `Picker("显示", selection: $displayMode)` 三选项 `.original / .translated / .bilingual`，行渲染按 mode 分支 | `RecordViews.swift` `@State var displayMode`, `row` 切分支 | 顶部一键切换原文/译文/双语 |
| 1.5 单次录音导出：`RecordEngine.exportMarkdown() -> String` 生成含时间戳/说话人/翻译的 MD，`RecordView` 右上角加「导出」按钮 | `RecordEngine.swift` 加 `exportMarkdown()`, `RecordViews.swift` `controls` 加按钮 | 点导出弹出保存面板，得到可读 MD |

---

### Phase 2 — 会话管理 & 总结增强（1-2 周）
**目标**：录音变成可管理的「会话列表」，总结达到会议纪要级。

| 任务 | 代码变更点 | 验收标准 |
|------|------------|----------|
| 2.1 `RecordSession` 模型：`id, title, createdAt, duration, lines: [RecordLine], topics: [RecordTopic], audioURL?, lang`，落盘 `~/Library/Application Support/LiveSubs/Records/<id>/session.json + audio.m4a` | 新建 `Sources/LiveSubs/RecordSession.swift`, 复用 `SessionStore` 目录逻辑 | 录音停止自动生成会话文件夹，重启可见 |
| 2.2 `RecordsWindow`（或复用 `NotesWindow` 侧边栏）：列表显示标题/时间/时长/语言，支持重命名、删除、搜索、双击打开 | 新建 `RecordSessionsView.swift` + `RecordSessionList.swift`, `AppModel.recordsWindow` | 菜单栏「录音记录」打开列表，能管理所有历史录音 |
| 2.3 总结 Prompt 重写：输出 JSON `{topics:[{title,detail,points,conclusions:[],todos:[],terms:[],fishbone:{}}]}`，`RecordTopic` 扩展字段，`topicView` 分区块渲染 | `RecordEngine.refreshSummary` prompt 重写, `RecordTopic` 加字段, `RecordViews.swift` `topicView` 分区 | 右侧实时出现「结论/待办/术语/鱼骨图」，点结论/待办跳回原文 |
| 2.4 说话人重命名：`PersonNumbers` 暴露 `nameMap: [Int:String]`, `RecordView` 说话人标签长按→弹窗改名，`RecordEngine` 同步修改所有 `line.person` 显示 | `RecordEngine.swift` 加 `renamePerson(_:to:)`, `RecordViews.swift` 行标签加手势 | 列表里「人物 1」→「张三」，全会话生效 |

---

### Phase 3 — 打磨 & 高阶（视反馈）
- 入口显眼化：菜单栏「新录音」`⌘N`、Dock 右键、主窗口显眼 Tab
- 变速/静音跳过/波形概览条
- 云同步/导出 Word/SRT/JSON 选项
- 方言/粤语模型下载入口
- 键盘快捷键：`Space` 播放/暂停、`←/→` 跳句、`⌘E` 导出

---

## 4. 需遵守的硬性约束（来自 AGENTS.md）

| 约束 | 在本实现中的体现 |
|------|------------------|
| **AI key 只在 0600 文件** | 总结依然走 `AIClient.chat(priority:.notes)`，不新增 key 存储 |
| **所有 AI 调用走 `AIClient`/`AIProvider`** | `refreshSummary` 已用 `ai?.chat(...)`，保持不变 |
| **不讲未翻译文本** | 录音页无「说回会议」功能，无需关注 |
| **不打包 BlackHole** | 录音只用系统麦克风，不涉及虚拟麦克风 |
| **`@MainActor` 引擎 + 音频队列** | `RecordEngine` 已是 `@MainActor`，mic tap → `queue` → `converter` → `analyzer` 链路不动 |
| **Bundle ID / DR 不变** | 纯功能增强，不改签名 |
| **无三方依赖 / 无 `.xcodeproj`** | 只用 `AVFoundation` `Speech` `SwiftUI` 系统框架 |
| **中文为键，`L("…")` 本地化，改 UI 后跑 `scripts/strings.py`** | 所有新增文案用 `L("…")` 或 SwiftUI 字面量 |
| **设计基调**：地 `#F3F4F6`、白卡、墨 `#15171C`、单一强调 `#E8552B` | 新增控件复用 `Palette.*`、`MainWindowView.hairline`、`Capsule/RoundedRectangle` 现有风格 |

---

## 5. 立即可动手的第一个 PR 范围（Phase 1.1-1.5）

```text
Sources/LiveSubs/
  RecordEngine.swift   // +liveSegments, +edit/merge/split, +audioPlayer, +exportMarkdown
  RecordViews.swift    // 逐字高亮行、编辑态、播放按钮、三态 Picker、导出按钮
  RecordLine.swift     // 单独文件或留在 RecordEngine，全 var 化
  RecordTopic.swift    // 先不动，Phase 2 再扩展
```

**验收脚本**：
```bash
scripts/build.sh && open build/Cicada.app
# 1. 点菜单栏「新录音」→ 说话 10 秒 → 观察逐字高亮
# 2. 双击任意句子 → 修改文本 → 合并/拆分
# 3. 点句子前 ▶️ → 从该处回放
# 4. 顶部切换 原文/译文/双语
# 5. 点「导出」→ 存为 MD → 用编辑器打开核对
```

---

## 6. 需要你确认的决策点

| 决策 | 选项 | 建议 |
|------|------|------|
| **会话列表入口** | A) 复用主窗口 Tab「记录」 B) 新建 `RecordsWindow`(类似 `NotesWindow`) C) 菜单栏二级菜单 | **B**——非激活面板、不占主窗口、符合「随时可查」心智 |
| **编辑持久化** | A) 仅内存 B) 落盘 `session.json` 覆盖 C) 追加版本历史 | **B**——Phase 1 先落盘，Phase 2 再加历史 |
| **总结结构** | A) 兼容现有 `RecordTopic` 只加字段 B) 重新设计 `Summary` 模型 | **A**——最小改动，`RecordTopic` 加 `conclusions/todos/terms/fishbone` 可选字段 |
| **音频格式** | 现有 `keepsAudio` 存 ADTS→m4a，回放直接用 `AVAudioPlayer` | **不动**——已可播放，Phase 1 只接播放器 |

---

确认后我直接按 Phase 1 顺序改代码，每完成一项跑一次 `scripts/build.sh` 验收。要从哪一项开始？