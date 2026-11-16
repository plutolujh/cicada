# 现场声音：把麦克风变成会议的第二个来源

日期：2026-11-05
状态：待批准（写完先给用户过目，再出实施计划）

## 为什么要做

现在知了只听**这台 Mac 播放出来的声音**（Core Audio process tap）。教室里从旁边设备、或者从空气里传进来的声音（老师的讲课、旁边人的说话），系统根本没送到 App 手上 —— 既录不到，也识别不了，更进不了会议记录。

用户试过用「保存会议录音」来解决：那个开关存的是 tap 那条音频，所以课堂声照样不在里面。用户要的是：**把从笔记本麦克风进来的人声识别出来、翻译成中文、写进会议记录**。

这是路线图里 “Recording what you say” 那一项的扩大版：路线图设想的是录「我自己说的话」，这里要录的是「房间里所有人的话」。机制一样（整场开着麦克风），落地位置不同。

## 已经定下来的（用户逐条确认过）

| 决定 | 内容 |
|---|---|
| 采集 | 麦克风整场开着，抓从外面进来的人声（老师、房间里的人、旁边设备的声音） |
| 语言 | 麦克风有**自己**的语言设置（自动识别 / 指定语言），跟电脑里那路各认各的 |
| 实时 | 现场的话实时进字幕条和纪要窗口，翻译成中文 |
| 记录 | 会议记录里**单独一节**「现场听到的」，不跟电脑里放的那路混在一起 |
| 说话人 | 复用现有 Core ML 声纹模型认人，但**单独编号**（跟「对方」那路各数各的），可在记录里改名 |
| 回声 | 不做。用户会避免麦克风和电脑同时出声 |
| 同声传译 | 共存：同声传译会把系统默认麦克风切成虚拟麦克风，麦克风这一路必须钉在真实麦克风上 |

## 目标 / 不做 / 反目标

**目标**

1. 麦克风作为一个独立的「来源」，整场采集、识别、翻译，进实时字幕条和纪要窗口。
2. 会议记录里这些行归到单独一节，导出（markdown / srt / docx）也分开。
3. 现场那路能认人、编号独立、可改名。
4. 麦克风录到的声音存进这场会议的录音文件。
5. 用户能立刻看出「麦克风到底听没听到声音」—— 现在这个需求的痛点就是「开了却没反应」。

**不做**

- 回声消除、去重（用户保证不会两边同时出声）。
- 说话人跨来源合并（用户选了分开编号）。
- 说话人跨会议记忆（路线图里的下一项，不在这次范围）。
- 换掉现有的系统音频通路 —— 麦克风是**多出来**的一个源。

**反目标（做成什么样算失败）**

- 开着麦克风后，同声传译变哑了 / 房间听不到译文。
- 麦克风这一路把虚拟麦克风（自己的译文）当成现场声音识别出来 —— 自我循环。
- 会议记录里两节内容混在一起，或者说话人编号串了。
- 麦克风开着时明显吃 CPU、掉帧、影响系统音频那路的识别。

## 约束

- 无第三方依赖，无 `.xcodeproj`，Command Line Tools only。
- UI 与引擎状态 `@MainActor`；音频回调把 buffer 交给队列处理。
- 中文是本地化 key；新文案走 `L("…")`，改完跑 `python3 scripts/strings.py`。
- 麦克风开着时 macOS 会亮麦克风指示灯 —— 这是系统行为，文案里要说清楚。
- 硬规则不变：key 只在 0600 文件里；每个 AI 调用走 `AIClient`；不把未翻译的原文说进房间。

## 方案

### 一、把「一个来源」抽出来（ListenEngine 重构）

现在的 `ListenEngine`（`Sources/LiveSubs/ListenEngine.swift`）是一套机器：采集 → `AudioRouter` → `SpeechAnalyzer` + `SpeechTranscriber` → 切句 → 翻译 → 上报。里面几处逻辑很细，不能复制两份：

- 切长句 `maybeCutSentence()`（ListenEngine.swift:566）：麦克风那头老师讲话往往一长串，没有这个，实时字幕会一直停在半句上。
- 半句翻译 `translateVolatile()`（:603）：字幕条要跟得上。
- 语言判定与「确认之前先扣着」`flushUnconfirmed()`（:476）：句子要先知道是什么语言才进记录。
- 声纹取样 `router.voiceSamples(from:to:)`（AudioRouter.swift:82）。
- 落盘录音 `AudioRouter.record()`（:163）。

所以：**把上面这一整套按「来源」参数化**，抽成一个类，两份实例：

- `ListenSource`（新文件 `Sources/LiveSubs/ListenSource.swift`）：拥有自己的 router / analyzer / transcriber / 语言设置 / 切句状态机，对外报 `onFinal` / `onTranslated` / `onSubtitle` / `onTiming` / `onStateChange`。
- `ListenEngine` 变成持有者：`system`（tap 来的）和 `mic`（麦克风来的）两个 `ListenSource`，并负责对外合并。

对外回调要带上「是哪一路」，否则 AppModel 分不清哪句是电脑里的、哪句是现场的。给 `Segment` 加一个 `origin` 字段（`.system` / `.mic`），回调签名相应带上来源。

`ListenSource` 需要能换采集方式，所以把「采集」抽成一个协议：

```swift
protocol AudioSourceCapture {
    /// 设备的原生格式，采集开始前问一次
    var format: AVAudioFormat { get }
    /// 开始把音频交出来
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}
```

- `SystemAudioTapCapture`：包现有的 `SystemAudioTap`（已经是这个形状：`onAudio` 回调 + 自己的 mono 格式）。
- `MicCapture`：新的，`AVAudioEngine` + `installTap`，把 pin 到真实麦克风那套搬过来。

### 二、麦克风这一路怎么采

- **设备**：`systemMic.recordingDevice`（`SystemMic.swift:112`）——它算出来的永远是**真实**麦克风，不会是虚拟麦克风。这条已经验证过：同声传译把系统默认麦克风切成 BlackHole 2ch 之后，`pinInput` 照样把引擎钉在真实麦克风上，识别正常（实测 `mic: recording from MacBook Air麦克风 status=0`）。
  - 钉不住（没有真实麦克风 / 只有虚拟麦克风）就**不启动**，并告诉用户「没有可用的麦克风」。宁可不开，也不能让它跟着系统默认跑到虚拟麦克风上去（那会把自己的译文当成现场的话，形成自我循环）。
- **格式**：麦克风原生 48 kHz，用现成的 `PCMConverter`（AudioRouter.swift:11）转到 analyzer 要的 16 kHz 单声道。
- **权限**：麦克风权限同声传译已经要过；没有权限时开关给出提示，不静默失败。
- **反馈**：开关旁边放一个电平条（`VoiceRecorder` 已经有现成的做法：Voices.swift:270-273）。用户这次的痛点就是「开了却没反应」，必须一眼看出有没有听到声音。

### 三、语言

麦克风有自己的语言设置：

- 「自动识别」：走现有的 `LanguageDetector.rank`（用麦克风自己的 clip）。
- 「指定语言」：用户选一个，麦克风这路直接用它。

跟系统音频那路各自独立，互不影响 —— 这就是用户选 A 的原因（电脑里放中文课件、现场讲英文，只有独立设置装得下）。

一个来源的自动识别需要**两个以上**已装模型才有得选；只有一个模型时那个语言就是唯一的可能 —— 这正是刚修掉的 `RecordGate` 那个坑（`Sources/LiveSubs/RecordGate.swift`），两个来源共用这条规则。

### 四、说话人

复用 `SpeakerID.swift` 现有的声纹模型（`SpeakerTagger` / `VoiceClusterer` / `SpeakerLabels`），但**两路各一套编号**：

- 现场那路有自己的一套 voice 编号（现场说话人 1、2…），跟「对方」那路各数各的。
- 存进记录的行要能区分来自哪一路，所以 `TranscriptLine` 加一个**可选**字段：

  ```swift
  /// 这一行来自哪一路：nil / "them" = 电脑里放的，"mic" = 现场听到的
  var origin: String? = nil
  ```

  可选字段对旧记录是兼容的（`SessionStore.load()` 用的是合成 `Decodable`，缺字段解出来就是 nil；注意**非可选**的新字段会让旧文件解不开）。

- `SpeakerLabels.numbers(_:)`（SpeakerID.swift:207）现在按 `voice` 编号；两路各有一套 1、2 会撞车，所以那里要按 `(origin, voice)` 分组，分别编号。
- 改名：`SpeakerStrip` / `SpeakerEditor`（SpeakerID.swift:497-627）已经能改名，改名表 `Session.voiceNames` 是 `[String: String]`，键是 voice 编号 —— 两路编号撞车的话，改名也会互相覆盖。键要改成带来源（例如 `"mic:3"`），旧键照旧能用。

### 五、记录、纪要、导出、界面

- **实时**：两路的文字都进字幕条（`Overlay.setSubtitle`）和纪要窗口的实时行。哪一路后说话，字幕条显示哪一路。
- **纪要**：`NotesEngine.update`（Notes.swift:205）读的是 `store.session(id).lines` —— 现场的行进了记录，纪要自然就带上，不用改这块。但 prompt 里的说话人标签（Notes.swift:329 附近）要认得「现场」，不然 AI 会把老师的话当成对方说的。
- **会议记录界面**：`Views.swift` 的 `transcript(_:)`（:1032）和 `quotes(_:)`（:963）现在是一列平铺的行；要把「现场听到的」分成另一节。
- **导出**：`TranscriptExport` 的 markdown（SessionStore.swift:316）、srt（:329）、docx（:345）三处都要分节，markdown 里加一个「## 现场听到的」小标题。
- **设置**：设置 › 录音（`SettingsWindow.swift:712` 那一节）加两行：
  - 「录下现场的声音」开关 + 电平条 + 一行说明（「从麦克风收房间里和旁边设备的声音；开着时 macOS 会亮麦克风指示灯」）。
  - 「现场声音的语言」：自动识别 / 各语言。

### 六、录音文件

麦克风这一路采到的音频存进这场会议 —— 现在 `mic.m4a` 是同声传译按住说话键时的话筒音。麦克风开着的时候它采到的已经包含那些话了，所以：**麦克风这一路开着时，`mic.m4a` 归它写，同声传译不再往同一个文件里写**（两个 writer 写同一个文件会打架）。

## 风险 / 要先验证的

1. **两个引擎同时开同一个麦克风**（麦克风这一路整场开着 + 同声传译每次按下也开）—— macOS 一般允许多个客户端开同一个输入设备，但要实测；不行的话就让同声传译复用麦克风这一路的数据。
2. **性能**：多一路 analyzer + transcriber，会不会拖累系统音频那路的识别（CPU、实时率）。要实测长会议的识别延迟。
3. **自我循环**：麦克风这一路必须钉在真实麦克风上；任何时候钉不上就宁可不启动。
4. **会议记录里两节会不会重复**：同声传译说的话（`recordSaid`，speaker "me"）和现场那路采到的同一段声音，会各记一遍 —— 这是两件不同的事（我说的 vs 房间里听到的），但用户看到可能觉得重复。要在界面上说清楚。

## 留给实施的人

- 「现场」这一路在界面上的中文措辞（现在暂定「现场听到的」「现场说话人 N」）要跟用户确认。
- 设置里开关的最终位置和电平条的样子。
- 界面改动要同步 `Resources/{en,ja,ko}.lproj/Localizable.strings` 与 `zh-Hans`（跑 `python3 scripts/strings.py`）。
- `AGENTS.md` 的 Scope 一行要补上「麦克风作为第二个来源」。
- 用户可见的改动要写进 `site/changelog.json`（中文）。
