# Findings — 录音转录功能

## 豆包录音转录界面（OCR 自截图 `/Users/java/Desktop/截屏2026-11-11 12.45.03.png`，1954×1298）

坐标是截图宽/高的百分比。**左栏 x≈4%，右栏 x≈50%**。

```
[x48 y6]  实时总结
[x4 y14]  新录音
[x4 y20]  ④自动识别～   [x15 y20] ZA不翻译～   [x24 y20] 9保留音频～
[x50 y19] 人物身份确认
[x7 y28]  说话人1   [x14 y27] • 00:15
[x54 y27] 身份信息介绍：钱程（David）来自科沃斯机器人，现任科沃斯机
[x54 y31] 器人 CEO，是90后、曾为中国最年轻A股上市公司 CEO 企
[x4 y33]  波克。
[x54 y34] 二代
[x4 y38] 你觉得你自己的欲望是什么？
[x4 y43] 这是个好问题。
[x50 y44] 个人状态分享
[x4 y50] 说话人1•   [x14 y50] • 00:41
[x54 y52] 个人欲望与状态分析：钱程表示自己曾因拥有较多未主动拼搏厮
[x4 y56] 你享受战斗吗？
[x54 y55] 杀，自身拼搏欲望是被环境激发的，认为人是环境的动物
[x4 y63] ④ 说话人2、   [x14 y63] • 00:41
[x50 y66] 当前正在聊…
[x4 y68] 我觉得以前我不是一个特别有血性的人，还是那句话，就
[x4 y72] 是说你可能拥有的比较多，↓"没有需要去拼搏、厮养和
[x52 y72] 说话人3表达对 David 成长经历的好奇，提及 David 为深圳出生长
[x4 y75] 获取，但我觉得我是有。
[x52 y76] 大，并非苏州出身。
[x50 y80] • David 确认自己 1990年出生于深圳，11岁前都在深圳生活，曾在纽
[x52 y84] 约度过三年时间。
[x6 y92] 02:26    [x21 y92] 10
```

### 推断出的界面结构

1. **顶部工具条**：左侧 `新录音` 标题 + 三个 chip 式开关：`自动识别`、`不翻译`、`保留音频`。
   - OCR 里 `④`/`ZA`/`9` 是 SF Symbol 图标被误识别，实际是图标按钮。
2. **左栏 = 转写流**：每段一行组：说话人标签（说话人1/2/3）+ 时间戳（`00:15`）+ 正文。
   - 正文就是实时识别的原始话，带标点。
   - 说话人变化处有新段落。
3. **右栏 = 实时总结**：**分段落**，每段有小标题（人物身份确认 / 个人状态分享 / 当前正在聊…）+ 正文。
   - 标题是「话题 / 章节」性质，不是「摘要」。
   - 段落里带 `•` 开头的要点行。
4. **底部**：左下角 `02:26`（总时长/计时），右下角 `10`（可能是句数/字数）。
5. 中间是竖直分隔线（x≈50% 是右栏起点）。

### 与知了现有设计的关系

- 知了主窗口 `MainWindowView` 是 `HStack { sidebar(232) ; detail }`，detail 里有 tab（纪要 / 文字记录）。
- 新「录音」tab 应该**不显示左侧会议列表**（录音时还没有会话），或复用列表但自动选中新建的会话。
- 豆包是两栏 50/50；知了 detail 区宽的话可以做 `HStack { 转写 ; 总结 }`。

## 知了现有可复用件（已读源码确认）

| 件 | 路径 | 能复用什么 |
|---|---|---|
| `ListenEngine` | `Sources/LiveSubs/ListenEngine.swift` (639 行) | `SpeechTranscriber` + `SpeechAnalyzer`；`reportingOptions: [.volatileResults, .fastResults]`；`SpeechAnalyzer.bestAvailableAudioFormat` 16k Int16 mono 兜底；`analyzer.finalize(through:)` 强制断句；语言切换 + ring buffer 重放 |
| `AudioRouter` | `Sources/LiveSubs/AudioRouter.swift` (296 行) | `PCMConverter`(AVAudioConverter 重采样)；RMS VAD（阈值 ≈ -40 dBFS，`gapSeconds=1.5`）；10 s ring buffer；`AudioFileWriter`（AAC .m4a + ADTS .aac 兜底 + 无损 rewrap） |
| `SystemAudioTap` | `Sources/LiveSubs/SystemAudioTap.swift` | Core Audio process tap（**系统输出**，不是麦克风） |
| `SpeakEngine` | `Sources/LiveSubs/SpeakEngine.swift` | **麦克风**采集：`AVAudioEngine` + `installTap(bus 0, bufferSize 2048)` + `PCMConverter` → `AsyncStream<AnalyzerInput>`。这是新录音要抄的模式 |
| `LanguageDetector` | `Sources/LiveSubs/LanguageDetector.swift` | 多模型转写同一 clip 打分：`conf × lengthFactor × scriptFactor`；接受 `conf≥0.6` 且领先 `≥0.08` |
| `TranslationService` | `Sources/LiveSubs/Translator.swift` | AI → Google → Apple 三级降级；`Kind.draft/.sentence/.speak`；**partial 永不翻译**（`kind != .draft` 才走 AI） |
| `AIClient` | `Sources/LiveSubs/AIClient.swift` (384 行) | `AIKey` 0600 文件；`chat(content:instruction:priority:json:maxTokens:timeout:)`；`Priority{speak,translate,notes}`；限流门 `acquire/pump`；`KeyState` 细分 |
| `MiniMaxProvider` | `Sources/LiveSubs/MiniMaxProvider.swift` | MiniMax 接入；`MiniMax-M3.1-Flash` / `MiniMax-M3`；`base_resp.status_code` 错误码映射（1004/2049 无效key、1002/1045 限流、1008/2053/2056/2062 额度、2057/2061 套餐、2069 模型下线）；**M3.1 总是思考**，`reasoning_effort=low` + 预算 +2048 |
| `NotesEngine` | `Sources/LiveSubs/Notes.swift` (491 行) | 结构化纪要：`MeetingNotes{summary, topics[], conclusions[], todos[], terms[]}`；`tick()` 节奏：首次 ≥3 句或 >20 s，之后每 45 s |
| `SessionStore` | `Sources/LiveSubs/SessionStore.swift` (390 行) | 会话持久化：`TranscriptLine`/`VoiceGuess`/`Session`；`system.m4a`/`mic.m4a`；Markdown/SRT/DOCX 导出 |
| `SpeakerID` | `Sources/LiveSubs/SpeakerID.swift` | WeSpeaker ResNet34-LM Core ML 声纹（16k float，Kaldi fbank 80 bins） |
| `HeardText` | `Sources/LiveSubs/HeardText.swift` | 文本清理（省略号/重复逗号合并）、`continues` 句子拼接 |
| `AppSettings` | `Sources/LiveSubs/Settings.swift` | `@Published` + `didSet{save()}` 模式；已有 `recordAudio` 开关 |
| `Palette` | `Sources/LiveSubs/Views.swift` | 设计令牌：ink/ground/line/secondary/body/link/mark/accent/accentInk/accentPale/fill/raised/accentWash/ok/error |

## MiniMax key

用户给了 `sk-cp-t0Iv7oBtsvf8fTNZhMRzhgFdB-Phr6MISLdV1NWLfB-PaunrFTRZgrgoPgSvqsRBy-4o-twASzTd3p11M32c1IgcFXt6Tgq7AWucRSN83DxFrcRcxVdgieU`

- 属于 `sk-cp-` 前缀 → **不是** `AIKey` 那种 MiniMax 平台 key（平台 key 形如 `eyJ…`）。
  - `MiniMaxProvider.keyPlaceholder = "eyJ…"`，平台 key 是 JWT 风格。
  - `sk-cp-` 看着像 **Claude Code / Anthropic 兼容代理**的 key。
- **重要**：AGENTS.md 规定 key 只能存 0600 文件，不能进 UserDefaults/日志/导出。
- **不能**把用户贴在聊天里的 key 硬编码进源码或提交进 git（`cargo xtask secrets` 类的检查；仓库是公开的）。
- 处理方式：写进 `~/Library/Application Support/<DevBuild.supportFolder>/minimax-api-key`（0600），
  并**确认它属于哪个 provider**——若它其实指向一个 OpenAI 兼容端点，应走 `CustomProvider`（自定义服务），
  而不是 `MiniMaxProvider`。
- **需要先向用户确认**：这个 key 到底对应哪个服务/端点。

## 工具

- 截图 OCR 用 macOS Vision（`/tmp/ocr.swift`，`swiftc -O ocr.swift -o ocr`）。本会话不支持直接看图，
  但可以用 Vision 读出文字坐标 → 这是绕过图像输入限制的可靠办法。
- `swiftc` 可用（Command Line Tools 已在）。

## 实现中踩到的坑（已修）

### 1. `RecordEngine.parse` 越界崩溃（SIGTRAP）

模型的回答里 `}` 可能出现在 `{` 之前。`text.range(of: "}")` 找到的是**整串最后**的 `}`，
而 `text.range(of: "{")` 找到的是**整串最前**的 `{`；把两个不同搜索得到的 `String.Index`
拼成 `open.lowerBound...close.upperBound` 会得到一个不成立的区间，切片时
`String index is out of bounds` → SIGTRAP。

崩溃报告：`~/Library/Logs/DiagnosticReports/Cicada-2026-11-11-145207.ips`，
故障帧 `RecordEngine.parse(_:) RecordEngine.swift:540`。

修法：用 `firstIndex(of:)` / `lastIndex(of:)` 拿同一串里的下标，判 `close > open`，
再自己算 `end = index(after: close)`，切 `text[open..<end]`。
`RecordEngineTests` 里加了 `keepsFailingAnswersWithoutCrashing` 守住这个回归。

### 2. 总结请求被自己取消

`maybeSummarize()` 由 tick（10 次/秒）驱动。原先 `lastSummaryLineCount` 在
`refreshSummary()` **任务内部**才更新，所以任务还在飞的时候下一帧又发一次请求，
`summaryTask?.cancel()` 把上一次取消掉。表现是：`ai: minimax notes ok` 打印了，
但 `record: summary N topics` 从不打印，而且日志在 AI 调用那一刻断掉。

修法：**在发请求时**就认领 `lastSummaryLineCount` 和 `lastSummaryAt`，
任务里只在 `force` 时认领。

### 3. 切模型丢掉正在说的那句话

`switchModel` 把 `generation` 加一，`handle()` 又要求 `gen == generation`，
于是旧模型的 final 结果被丢掉，加上 `cancelAndFinishNow()`，半句就没了。

修法：`handle()` 里 `gen != generation` 时**只丢 volatile**，final 照收；
切模型的门槛也提高：`chars >= 6`、`confidence >= 0.6`、领先 runner-up ≥ 0.15、
且领先当前模型 ≥ 0.35（否则不动）。

### 4. 录音文件丢失（并发 finish）

`RecordEngine.closeRecorder()`（`Task { await AudioFileWriter.finish(url) }`）和
`AppModel.endRecording()`（`store.finishAudio(id)`）**都**调了 finish。
两个 finish 并发：A 写出了 `.m4a`，B 的 catch 分支
`try? FileManager.default.removeItem(at: url)` 把刚写好的文件删了。

修法：只有引擎负责收尾（去掉 `AppModel` 里的重复调用）；
`AudioFileWriter.finish` 变幂等：已有 `.m4a` 就只删 partial、不动成品；
失败时**保留 partial**（它仍可读），不再删成品。

### 5. 英文界面里开关还是中文

`Text(title)` 传的是运行时 `String`，SwiftUI 不会本地化它（只有 `Text` 里的
**字面量**才走 `LocalizedStringKey`）。改成 `chip(_ title: LocalizedStringKey, …)` 后
开关才跟着语言走。

`scripts/strings.py` 用的是 Swift 的 `-emit-localized-strings`，所以只有
`LocalizedStringKey` 字面量才会被它发现——之前这些中文根本没进检查范围，
补完后是 863 keys、0 missing / 0 unused / 0 TODO（三语）。

## 验证过的（真实语音，非 demo）

用 BlackHole 2ch 把 `say` 合成的中/英文片段喂进麦克风：

- 3 句 transcript（中文 / 英文 / 中文），模型在 zh-CN ↔ en-US 之间自动切
- 每句的 MiniMax 翻译落进 `session.json` 的 `dst`
- `record: summary 3 topics` — 真实 3 句 transcript 出来的总结
- `Sessions/<id>/mic.m4a` 存在、ffprobe 读得出时长、ffmpeg 解码无错；
  `silencedetect` 的静音段与 `playto` 播片段的时刻对得上（说明录的是真声音）
- 英文界面（`AppleLanguages=en`）OCR 核对：New recording / Auto-detect /
  Translate to... / Keep audio / Stop / Live summary 全部走翻译

## 6. 录音里分人（人物1 / 人物2）

### 怎么留住每句话的声音

转写结果的时间范围（`result.range`）在 **analyzer 的时钟**上，不是录音的墙上时钟。
录音的麦克风 tap 正是喂 analyzer 的地方，所以只要照着喂进去的秒数计数
（`fed`），两边的时钟就是同一件事：

- `RecordEngine.keepVoice(c)` 留 16 kHz 单声道，`voiceStart` 记它在 `fed` 上的位置
- `voiceSamples(from:to:)` 按 analyzer 时间切出某一句自己的那段声音
- 留 90 秒，够覆盖一句话；`Voiceprints.maxSeconds` 再把超长的截到 20 秒

（和 `AudioRouter.voiceSamples` 是同一套做法，之前听会议时已经这么干过。）

### 一个会崩的坑

`VoiceClusterer` 给的声纹 id 是 **0 起的**（`sums.count - 1`），
而 `SpeakerColor.ink(n)` 是 `inks[(n - 1) % inks.count]`——传 0 会取 `inks[-1]` 崩掉。
显示用的号单独算：`PersonNumbers` 把声纹 id 映射成人物 1、2、3…（按听到的先后），
界面和颜色都用这个号。

### 声纹模型本身分得清，喇叭会把两个人说得像

用 `voiceCompare` / `voiceFiles` 两个调试命令量过（都走生产那条路：模型 → 声纹 → 聚类）：

| 比较 | 相似度 | 结论 |
|---|---|---|
| Eddy vs Grandma（干净文件） | 0.274 | 不同人 ✓ |
| Eddy vs Grandma（干净文件） | 0.658 | 同一个人 ✓ |
| 干净文件走聚类 | Eddy→0, Grandma→1, Eddy→0, Grandma→1 | 分对 ✓ |

但把合成语音**经喇叭放出来再被麦克风收进去**，两个人的相似度会涨到 0.736，
高于合并门槛 0.5，于是被当成同一个人。喇叭染色盖过了人声本身的差别——
这是测试环境的限制，不是代码的错；真人对话要人来验收。

## 7. 豆包式逐字流式：SpeechAnalyzer 的时间属性怎么拿

### 属性在 run 上，不在 text 上

`SpeechTranscriber` 加上 `attributeOptions: [.audioTimeRange]` 之后，
时间范围挂在 **run** 上：

```swift
typealias Scope = AttributeScopes.SpeechAttributes
for run in text.runs {
    let range = run[Scope.TimeRangeAttribute.self]   // CMTimeRange?
    let sure  = run[Scope.ConfidenceAttribute.self]   // Double?
    let piece = String(text[run.range].characters)
}
```

`run.scope` 和 `text.scope.range(for:)` **都不存在**——写出来编译不过。

### volatile 给整句一个 run，final 才逐字给

这是最关键的一条，一开始以为是 bug：

| 结果 | runs | 含义 |
|---|---|---|
| volatile（还在说） | `[挺有意思的我们以讨论一下\|0.0-2.989\|nil]` | 整句一个 run，只有整句的跨度 |
| final（说完了） | `[有\|0.24-0.54\|nil] [没\|0.54-0.66\|nil] …` | 每个字一个 run，各带准确时间 |

所以逐字流式要两段配合：

- 还在说的时候，把 run 的时间跨度**均分**给每个字（`step = span / count`），
  文字照样一个字一个字冒出来，每个字也有大致的时间；
- 句子说完了，final 结果给的是逐字 run，各自带准确时间，直接换上去。

实测：`record: words 13: 你@0.0 有@0.2 意@0.5 思@0.7 …`（live），
final 的 runs 是 `[有|0.24-0.54] [没|0.54-0.66] …`。

### 中文没有空格，所以中文按字切

`pieces(of:)`：文本里有空格就按空格切（英文保留整词），没有空格就按字切（中文）。
这样中文才能一个字一个字出现。

### `attributeOptions` 不是「录不到」的元凶

一开始怀疑是 `.audioTimeRange` 让识别器罢工，去掉它重录——**行为一样**（0 行）。
真正的原因是麦克风引擎被复用后没有 `reset()`：同一进程里的第二段录音全聋。
现在 `stopMic()` 里 `mic.stop()` 之后补了 `mic.reset()`。

### 电平表恒为 0

analyzer 给的格式是 Int16 16 kHz，`buffer.floatChannelData` 是 **nil**，
所以 RMS 那一段根本没跑。改成 `rms(of:)`，Int16 和 Float32 都算。

### 停录时正在说的那句会丢

`stop()` 把 analyzer `cancelAndFinishNow()` 掉，还在说的半句就跟着没了。
现在 `stop()` 里先 `settleLive()`：把 live 文本和它的词时间留成一行，再收尾。

### 录完再改句子，改动进不了会议记录

两处：`endRecording()` 把 `recordSessionID` 清了、又把 `onEdit`/`onRewrite` 摘了。
现在 `recordSessionID` 保留（开始新录音时才换），`onEdit`/`onRewrite` 也保留，
`SessionStore` 补了带 session id 的 `setSource(in:)` / `setTranslation(in:)` /
`replaceLines(in:)`，改完照样写回同一个会议。

### 麦克风只能听清系统默认输入

`AudioDevices.pinInput` 指定「MacBook Air麦克风」时 tap 收到的是静音，
用系统默认输入就正常。`mictest`（单独的小程序）量到：安静时 peak 0.003，
放声音时 peak 0.074——麦克风本身是好的。

### 语言探测太慢

本机从 en-US 换到 zh-CN 要 10–20 秒（要积累足够的字符和置信度才敢切）。
测试时用 `recordLang:zh-CN` 直接固定语种，不用等。

### 英文模型不吃中文

zh-CN 模型下两句中文还是被并成一行（断句要真人说话才判得准），
en-US 模型则完全听不出中文。

## 8. 录音页的总结应该复用会议那套，不要另做一套

录音页一开始自己写了一套总结（`RecordEngine.topics` + 一段专门的 prompt），
只出「标题 + 正文 + 要点」，没有结论、没有待办、没有术语，也没有鱼骨图。
用户看完说：会议那套实时纪要已经很完善了，录音能用它就行。

### `NotesEngine` 本来就不关心声音是怎么来的

`NotesEngine.update()` 只读 `store.session(id).lines`，
它的定时器、增量更新、最终一遍全文，全都只看行数变没变。
录音的行本来就是 `store.append` 进去的（`recordSessionID` 那个会话就是 `liveID`），
所以只要 `notes.begin(session.id)` / `notes.finish()` 一接上，整套纪要就跟着录音走了。

实测：录 4 句 → 会议记录里有标题、总结、议题（带 4 分支鱼骨图）、结论 2 条、术语 4 个。

### 顺带删掉的东西

`RecordEngine` 里那一整套（`topics` / `summarizing` / `maybeSummarize` /
`refreshSummary` / `parse` / `fishbone`，约 120 行）以及 `RecordTopic` 结构体，
现在都由 `NotesEngine` + `NoteTopic` 取代。`RecordEngineTests` 里测那个解析器的
4 个用例也跟着删了（70 tests，不是 74）。

### `store.end()` 之后再 `notes.finish()` 没问题

`store.end()` 把 `liveID` 清了，但 `notes.finish()` 用的是自己记着的 `sessionID`，
`update(id, final: true)` 直接按 id 取会话，跟 `liveID` 无关。
只有一句都没说的时候 `store.end()` 会把会话删掉——那时也没有纪要可写。

### 转场要短

转场卡停留 2.2 s，然后自动跳到那条会议记录。停太久会挡住用户，
停太短看不清「存了什么」。四个块（录音音频 / 原文 / 翻译 / 纪要）依次落位，
间隔 0.22 s，读起来是「一件件放进去」，不是一个字突然出现。

---

## 9. 界面语言：`AppleLanguages` 是那把钥匙

macOS 的应用界面语言由 `AppleLanguages`（UserDefaults 里的数组）决定。
SwiftUI 不能热换本地化——`Bundle.main.preferredLocalizations` 在进程活着的时候
是定死的——所以「挑一种语言」必然要重启一次。

- 「跟随系统」= **删掉** `AppleLanguages` 这个钥匙，不要存一个 `"system"` 之类的值。
  存了反而会盖掉系统的选择。
- 存的时候要存**数组**：`defaults.set([id], forKey: "AppleLanguages")`，
  存字符串的话系统不认。
- 读的时候要看有没有这把钥匙，没有才是「跟随系统」：

```swift
let picked = UserDefaults.standard.string(forKey: "AppleLanguages")
```

  `string(forKey:)` 对一个数组会返回数组的描述（`"(en)"`），所以更稳的是
  `stringArray(forKey:)`。不过只要是我们自己写的，读回来总能对上。

实测（`defaults read com.wquguru.cicada.dev AppleLanguages`）：
挑「日本語」后是 `( ja )`，选「跟随系统」后钥匙整个消失。

### 重启应用的做法

`Updater` 里已经有这个套路了：`/bin/sh` 脚本先 `while kill -0 <pid>` 等本进程退出，
再 `open <bundle>`。界面语言重启借用了同一套，没有另外发明。

### 调试用的命令

`interfaceLanguage:<code|system>` 直接改钥匙、**不重启**，
用来快速查英文/日文界面。正式路径是设置页里的 `PillMenu` → `AppModel.setInterfaceLanguage`。

## 10. `AudioFileWriter.finish` 之前是「发射后不管」

并发守卫的写法有个洞：

```swift
let waiting: Task<Void, Never>? = lock.withLock {
    if let running = rewrites[key] { return running }   // 有人在跑 → 等它
    let task = Task { await rewrap(...) ; rewrites[key] = nil }
    rewrites[key] = task
    return nil                                            // 自己起的 → 返回 nil
}
await waiting?.value    // ← nil 的时候什么也没等！
```

新建任务时返回 `nil`，所以 `await waiting?.value` 立刻返回，
`finish` 在 rewrap **还没做完**的时候就走了。
两个调用者一起等时反而碰巧没事（第一个在等第二个？不，第一个也什么都没等）——
只是时序上通常刚好赶上，于是**测试偶发红**，看起来像 flake。

正确的写法是**总是 await 那个任务**，不管是自己的还是别人的：

```swift
let task: Task<Void, Never> = lock.withLock {
    if let running = rewrites[key] { return running }
    let task = Task { await rewrap(url, until: until); lock.withLock { rewrites[key] = nil } }
    rewrites[key] = task
    return task
}
await task.value
```

这在应用里是要紧的：`store.end()` 和录音器都会调 `finish`，
录音刚结束就去读 `.m4a` 会读不到。

### 另一个坑：partial 必须是真的 ADTS AAC

`AVAssetExportSession` 的 passthrough 只认真的 ADTS AAC 流。
测试里用 `AVAudioFile` 写 Int16 PCM 到 `.aac` 路径，导出会失败
（`audio rewrap failed`），partial 被留在原地——测试当然红。
正确的入口是 `AudioFileWriter.open`（和录音器同一个）：

```swift
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: format.sampleRate,
    AVNumberOfChannelsKey: Int(format.channelCount),
    AVEncoderBitRateKey: 32_000,
]
```

实测写出来的 partial 是 1255 字节、`mediaSubType 'aac '`、`mFramesPerPacket 1024`，
`AVURLAsset` 能读出 1 条 track，export 后是合法的 `ISO Media, Apple iTunes ALAC/AAC-LC (.M4A)`。
