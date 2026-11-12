# 录音转录功能（豆包式）— 实施计划

## Goal

在知了主窗口新增一个「录音」标签页，做一个像豆包录音转录的界面：

- **左侧**：新录音（麦克风采集）+ 顶部开关（自动识别 / 翻译 / 保留音频）+ 下面是实时识别出的文字
- **右侧**：实时总结（随说话内容滚动更新）
- 识别用**端侧 Apple 引擎**（复用 `ListenEngine`/`SpeechAnalyzer`）
- 翻译与总结用**用户已有的 MiniMax 订阅**（`AIClient` → `MiniMaxProvider`）
- 保留音频：录成 `.m4a` 存进会话目录

## 豆包界面（OCR 实测，截图 1954×1298）

```
新录音   ④自动识别～  ZA不翻译～  9保留音频～        │  实时总结
                                                    │
说话人1  00:15                                       │  人物身份确认
        你觉得你自己的欲望是什么？                   │  身份信息介绍：钱程（David）来自科沃斯机器人…
        这是个好问题。                               │
                                                    │  个人状态分享
说话人1  00:41                                       │  个人欲望与状态分析：钱程表示自己曾因…
                                                    │
说话人2  00:41                                       │  当前正在聊…
        我觉得以前我不是一个特别有血性的人…           │  说话人3表达对 David 成长经历的好奇…
                                                    │
                              02:26                 │  10
```

要点（来自 OCR 坐标）：
- 左栏 x≈4%（说话人 + 时间戳 + 文字），右栏 x≈50%（总结段落标题 + 正文）
- 顶部三个开关：`自动识别` / `不翻译` / `保留音频`
- 总结是**分段落**的（人物身份确认 / 个人状态分享 / 当前正在聊…），不是一整块
- 说话人分段 + 每段起始时间戳（`00:15`、`00:41`）

## 决策（已与用户确认）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 识别引擎 | 端侧 Apple `SpeechAnalyzer` | 中文质量接近豆包；不上传音频；零额外费用；复用现成代码 |
| 音频来源 | 麦克风 | 与豆包一致；需麦克风授权 |
| 界面位置 | 主窗口新增「录音」标签页 | 不新增窗口层级，与现有设计一致 |
| 翻译/总结 | MiniMax（用户已有订阅） | `AIClient` 已有 key/限流/优先级机制，直接复用 |

## 复用的现有件

- `ListenEngine` — 端侧识别核心（`SpeechTranscriber` + `SpeechAnalyzer`，interim/final、语言检测、断句）
- `AudioRouter` / `PCMConverter` — PCM 转换、RMS VAD、`AudioFileWriter`（ADTS → .m4a）
- `LanguageDetector` — 多模型置信度语言探测
- `Translator` / `TranslationService` — AI → Google → Apple 三级翻译降级
- `AIClient` / `MiniMaxProvider` — MiniMax 接入（key 在 0600 文件、限流门、优先级）
- `HeardText.clean` — 文本清理
- `SessionStore` — 会话持久化 + `mic.m4a` + Markdown/SRT/DOCX 导出
- `Palette` / `MainWindowView` — 设计令牌与主窗口骨架

## Phases

### Phase 1 — 录音引擎 `RecordEngine`（新文件）— ✅
- [x] `Sources/LiveSubs/RecordEngine.swift`
- [x] 麦克风采集（`AVAudioEngine` + tap + `PCMConverter`，参考 `SpeakEngine.startMic`）
- [x] 端侧识别：`SpeechTranscriber` + `SpeechAnalyzer`，`reportingOptions: [.volatileResults, .fastResults]`
- [x] interim（临时文本）与 final（确认文本）分离；`HeardText.clean`；无字母的句子丢弃
- [x] 音频落盘 `.m4a`（`AudioFileWriter.partial` → `finish`）
- [x] 每段带起始时间戳（`RecordEngine.clock`）
- [x] 电平表（RMS）用于录音时的音量反馈

### Phase 2 — 实时总结 — ✅
- [x] 复用 `AIClient`（MiniMax），`priority: .notes`，JSON 模式
- [x] 分段落总结：标题 + 正文 + 要点（对齐豆包右栏）
- [x] 增量更新：首次 ≥3 句，之后每 45 s 且 ≥3 句新句
- [x] 翻译：每句 final 出来即翻译（`TranslationService`，partial 永不翻译）

### Phase 3 — UI「录音」标签页 — ✅
- [x] `Sources/LiveSubs/RecordViews.swift`
- [x] `MainWindowView` 顶部加 `会议 / 录音` 切换；录音态隐藏侧栏
- [x] 左栏：录音控制 + 三个开关 + 实时文字（时间戳 + 原文 + 译文）
- [x] 右栏：实时总结（分段落）
- [x] 沿用 `Palette` 令牌，中文短文案

### Phase 4 — 设置与文案 — ✅
- [x] `AppModel` 上的 `recordTarget` / `recordAutoLang` / `recordKeepsAudio`（`@Published` + UserDefaults）
- [x] `Resources/{en,ja,ko}.lproj/Localizable.strings` 补翻译
- [x] `python3 scripts/strings.py` — 863 keys, 0 missing / 0 unused / 0 TODO（三语）

### Phase 5 — 验证 — ✅
- [x] `scripts/test.sh` — 68 tests in 12 suites
- [x] `scripts/build.sh` 编译通过 → `build/Cicada.app`
- [x] 真实语音跑通：BlackHole 2ch 喂 `say` 合成的中/英文片段 → 3 句 transcript + 逐句翻译 + 3 段总结
- [x] 录音落盘：`Sessions/<id>/mic.m4a` 存在、可解码、时长与录音吻合
- [x] 英文界面（`AppleLanguages=en`）OCR 核对：开关、标题、总结都走翻译

## 本轮修掉的三个 bug

1. **总结请求被自己取消**（`RecordEngine.maybeSummarize`）：tick 每 0.1 s 跑一次，
   `lastSummaryLineCount` 原先在任务内部才记，于是下一帧又发一次请求、把上一次取消。
   现在**在发请求时**就认领行数与时间。
2. **切模型丢掉正在说的那句话**（`switchModel` / `handle`）：`generation` +1 让旧模型的
   final 结果被丢掉。现在旧模型的 final 结果照收，只有 volatile 的半句丢掉；
   切模型的门槛也提高了（`chars>=6`、`confidence>=0.6`、领先 ≥0.15、切换需领先当前 ≥0.35）。
3. **录音文件丢失**（`AudioFileWriter.finish` 被并发调用两次）：`RecordEngine.closeRecorder()`
   和 `AppModel.endRecording()` 都调了 finish，第二次的 catch 分支把刚写好的 `.m4a` 删了。
   现在只有引擎负责收尾，且 `finish` 变成幂等：已有的 `.m4a` 不会被删，失败时保留 partial。

另外还修了 `RecordEngine.parse` 的越界崩溃（`}` 在 `{` 之前时 `String index is out of bounds`），
并补了 `RecordEngineTests`（5 个用例）守住这个回归。

## Constraints（来自 AGENTS.md）

- 不引入第三方依赖；不用 `.xcodeproj`
- AI key 只存 0600 文件，**绝不**进 UserDefaults / 日志 / 导出
- 所有 AI 调用走 `AIClient`
- UI 与引擎状态 `@MainActor`；音频回调把 buffer 交给队列
- 不改发布 bundle id `com.wquguru.cicada`
- 界面文案用中文，`L("…")`；改完跑 `python3 scripts/strings.py`
- 注释说「为什么」，密度与现有代码一致
- commit message 英文、Conventional Commits；用户可见改动要写 `site/changelog.json` 中文条目

## Next Step

打开 app 验证录音界面；真人对着麦克风说话验收（麦克风授权与真人音色需要人来测）。

## 说话人分段（人物1 / 人物2）

豆包会把不同的人分开标。复用 `SpeakerID.swift` 里已有的声纹机器
（WeSpeaker ResNet34-LM Core ML + `VoiceClusterer`），录音时给每句算声纹：

1. **录音要留住每句话的音频**。原来只留了最近 12 秒给语言识别用；现在另外留
   90 秒的 16 kHz 单声道，**按 analyzer 的时钟**摆好——analyzer 的
   `result.range` 就在这个时钟上，这样一句话的起止时间能切出它自己的那段声音。
   （和 `AudioRouter.voiceSamples` 同一套做法，`fed` 计喂给 analyzer 的秒数。）
2. **每句定了以后算声纹**：`RecordEngine.tag()` 把那段时间的采样交给
   `SpeakerTagger.tag(lineID:samples:)`，回来的声音号写回 `RecordLine.voice`。
3. **人物号从 1 开始、按听到的先后排**：`PersonNumbers` 把声纹 id 映射成
   人物 1、人物 2……同一个人一直用同一个号。
   - 声纹 id 是 0 起的，`SpeakerColor.ink(0)` 会取 `inks[-1]` 崩掉，
     所以显示用的号单独算，不直接用声纹 id。
4. **界面在换人时才标**：`RecordViews` 在声音变化的那行显示「人物 N」，
   和聊天软件一个样子；颜色跟着 `SpeakerColor` 轮换。
5. **总结也带上是谁说的**：转写给模型时带上「人物 N:」前缀，提示词里让它
   说清楚谁说的。
6. **存进会议记录**：录音的行 `speaker: "them"`（录的是别人，不是你），
   声纹号存进 `TranscriptLine.voice`，记录窗口里也能分人。

## 豆包路线图 Phase 1（`2026-11-05-doubao-record-comparison.md`）— ✅

按对比文档第 3 期的 Phase 1 逐条做，五项都落地了：

1. **1.1 逐字流式** ✅ — `RecordEngine.liveWords`（`[LiveWord]`）拿 `SpeechTranscriber`
   的 `attributeOptions: [.audioTimeRange]`，volatile 结果给的是整句一个 run，
   所以 `words(of:)` 把 run 的时间跨度均分给每个字；final 结果给的是逐字 run，
   各自带准确时间，直接换上去。界面用 `AttributedString` 渲染，最新的字是橙色。
   - 注意：属性在 **run** 上（`run[Scope.TimeRangeAttribute.self]`），
     `run.scope` / `text.scope.range(for:)` 都不存在。
2. **1.2 句子编辑 / 合并 / 拆分** ✅ — `RecordEngine.edit/merge/split` 改 `lines`，
   `AppModel.recordEdit`/`recordRewrite` 同步进 `SessionStore`。
   `SessionStore` 多了 `setSource(in:)` / `setTranslation(in:)` / `replaceLines(in:)`，
   录完的录音改完也写回同一个会议（`recordSessionID` 不再在 `endRecording` 里清空）。
3. **1.3 音频回放** ✅ — `RecordEngine.play(from:)` + `AVAudioPlayer`，
   引擎不是 `NSObject`，所以用一个私有的 `PlaybackDelegate` 代理。
4. **1.4 双语三态** ✅ — `RecordEngine.Display`（original / translated / bilingual），
   顶部三选一；没有译文目标时选择器置灰。
5. **1.5 导出** ✅ — `AppModel.exportRecording(kind:)` 复用 `model.export(session, kind:)`，
   Markdown / Word / SRT 三种，录音页右上角一个菜单。

顺手修掉的 bug：

- `mic.reset()`：录完不 reset，**同一进程里的第二段录音全聋**。
- 电平表恒为 0：analyzer 的格式是 Int16，`floatChannelData` 是 nil，
  改成 `rms(of:)` 两种格式都算。
- 停录时正在说的那句丢了：新增 `settleLive()` 把它留成一行。
- 录完再改句子进不了记录：`onEdit`/`onRewrite` 之前在 `endRecording` 里被摘掉。
- 固定语种：`RecordEngine.heardLanguage` + `AppModel.recordHeardLang`
  （UserDefaults `recordHeardLang`，默认 `auto`），不用等语言探测。

## 本轮：录音用会议那一套实时纪要（2026-11-12）

用户看完录音页后说：**「系统已经有的实时纪要界面，录本地机器播放的声音识别已经很完善了，
只要这个界面可以支持麦克风录音就可以」**。

也就是说：不要再做一套并行的总结，**录音直接驱动会议那套 `NotesEngine`**。

### 改了什么

1. **录音接上 `NotesEngine`** — `AppModel.startRecording()` 里 `notes.begin(session.id)`，
   `endRecording()` 里 `notes.finish()`（最后一遍全文纪要）。
   `NotesEngine` 本来就只读 `store.session(id).lines`，怎么听进去的它不关心。
2. **录音页右栏换成会议那套** — 删掉 `RecordEngine.topics` / `summarizing` /
   `maybeSummarize` / `refreshSummary` / `parse` / `fishbone`（约 120 行），
   改成直接渲染 `NotesContentView`：总结、议题、结论、待办、人名术语、鱼骨图。
   `RecordTopic` 结构体也删了——`NoteTopic` 取代它。
3. **录完的转场** — 新文件 `RecordSaving.swift`（存了什么）+ `RecordSavingView.swift`
   （怎么显示）。录音结束 → 一张卡盖在录音页上，`录音音频 / 原文 / 翻译 / 纪要`
   四块依次落位 → 2.2 s 后自动切到那条会议记录（`mainShow = "<id>,notes"`，
   侧栏滑走、详情滑入）。
4. **入口分清** — 顶部标签「会议」→「会议记录」、「录音」→「麦克风录音」，
   主窗口右上角加「听系统声音」按钮（走新的 `openPanel`，只开不关）。

### 验证

- 录音 4 句 → 会议记录里：标题、总结、议题（带 4 分支鱼骨图）、结论 2 条、术语 4 个、
  `mic.m4a` 在。
- 转场卡 OCR 读出「已保存到会议记录」「查看会议记录」「原文 / 翻译 / 纪要」。
- `scripts/test.sh` — 70 tests in 12 suites（删掉了 4 个测已删解析器的用例）。
- `python3 scripts/strings.py` — 883 keys, 0 missing / 0 unused / 0 TODO（en/ja/ko）。

## 待办 / 已知缺口

- **固定语种没有界面**：`recordHeardLang` 只能靠 debug 命令 `recordLang:<code>` 设，
  还没有选择器。
- **真人验收**：麦克风授权、真人音色、BlackHole 安装仍需一个人来测。
  合成语音经喇叭再被麦克风收进来，声纹会被「喇叭染色」盖过，
  两个人的声音会变得像（实测 0.736，高于合并门槛 0.5），
  所以真人对话的验收还是要人来。
- **断句**：zh-CN 模型在本机不把两句话切成两行（两句 → 一行），
  断句行为要真人说话才能判。

---

## 本轮：界面语言 + 修掉 `finish` 的真 bug

### 用户要的

用户跑过一轮英文界面后问：**「哪里可以切换成中文呢？需要有个地方设置界面语言的功能」**。

之前没有这个设置——界面只跟着系统语言走，想换只能靠启动参数
（`-AppleLanguages "(en)"`）或 `defaults write`。

### 改了什么

1. **新文件 `InterfaceLanguage.swift`** — 界面语言的选择和读写。
   走 macOS 认的那把钥匙：`AppleLanguages` 写在应用自己的 UserDefaults 里，
   「跟随系统」就是把钥匙删掉。`current` 是「有挑就挑，没挑就系统」。
2. **设置页加一行** — `LanguageSettings.swift` 顶上多一组「界面」，
   `界面语言` → `PillMenu`：跟随系统 / 简体中文 / English / 日本語 / 한국어。
   一行灰字：「应用的菜单和页面用哪种语言」。
3. **挑完要重启才生效** — SwiftUI 不能热换本地化，所以
   `AppModel.setInterfaceLanguage(_:)` 存好以后弹一个 `NSAlert`：
   「界面语言已改为 X / 重启应用后生效。现在重启吗？」→ 「现在重启」就
   `restartApp()`（`/bin/sh` 等本进程退出再 `open` 同一个 bundle，和 Updater 一样的手法）。
4. **调试命令** `interfaceLanguage:<code|system>` — 改 `AppleLanguages` 不用重启，
   方便查英文界面（`system` 是删钥匙）。

### 顺手修掉一个真 bug

`AudioFileWriter.finish(_:)` 的并发守卫有个洞：新起的那个 `Task` **没有被 await**——
`let waiting: Task? = lock.withLock { ... return nil }` 里新建任务时返回 `nil`，
后面 `await waiting?.value` 就什么也没等。也就是 `finish` 是「发射后不管」的，
调用方拿到手时 `.m4a` 往往还没生成。

这不只是测试的问题：应用里 `store.end()` 和录音器都会调 `finish`，
录音刚结束就去读文件的话会读不到。改成把任务本身返回出来、**总是 await 它**：

```swift
let task: Task<Void, Never> = lock.withLock {
    if let running = rewrites[key] { return running }
    let task = Task { await rewrap(url, until: until); lock.withLock { rewrites[key] = nil } }
    rewrites[key] = task
    return task
}
await task.value
```

### 测试

`Tests/LiveSubsTests/AudioFileTests.swift` 原来用 `AVAudioFile` 写 Int16 PCM 到 `.aac`
路径——`AVAssetExportSession` 的 passthrough 不认，rewrap 必然失败，所以那个用例一直红。
改成用 `AudioFileWriter.open`（和录音器同一个入口）写真的 ADTS AAC，
`aFinishedFileIsNeverTakenAway` 也改成「先 rewrap 出真的 `.m4a`，再放一个残留的 partial」。

### 验证

- `scripts/test.sh` — **72 tests in 13 suites 全绿**（连跑 5 次，不再飘）。
- 英文界面 OCR 读出 `Interface / Interface language / English`；
  中文界面读出「界面 / 界面语言 / 应用的菜单和页面用哪种语言 / 简体中文」；
  日文界面读出「表示 / 表示言語」。
- 挑「日本語」→ 重启 → 界面变日文；挑「跟随系统」→ 钥匙被删 → 回到中文。
- 录音实测：zh-CN 识别 1 句 → `mic.m4a` 是合法的 AAC-LC（10.05 s），
  `session.json` 里有 1 行原文、1 个议题、一段总结。
- `python3 scripts/strings.py` — 892 keys, 0 missing / 0 unused / 0 TODO（en/ja/ko）。

### 待办

- **会议记录回收站**（用户要：「删除的会议记录需要有个回收站，防止删错」）——还没做。
- 真人验收仍然需要人：麦克风授权、真人音色分人、zh-CN 断句。
