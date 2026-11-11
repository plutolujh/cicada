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

## 待办 / 已知缺口

- **翻译语言没有选择器**：`recordTarget` 只能在「不翻译」和「我的语言」之间切，
  没有明确的语言列表可选。
- **真人验收**：麦克风授权、真人音色、BlackHole 安装仍需一个人来测。
  合成语音经喇叭再被麦克风收进来，声纹会被「喇叭染色」盖过，
  两个人的声音会变得像（实测 0.736，高于合并门槛 0.5），
  所以真人对话的验收还是要人来。
