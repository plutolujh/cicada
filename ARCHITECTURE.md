# Cicada (知了) 功能架构图

```mermaid
flowchart TD
    %% ===== 用户界面层 =====
    subgraph UI [用户界面层]
        direction TB
        MB[菜单栏面板<br/>AboutPanel / AppMenu]:::ui
        SC[字幕条<br/>Overlay]:::ui
        MW[主窗口<br/>会议记录 / 实时识别<br/>Views + CaptureViews]:::ui
        NW[纪要窗口<br/>NotesWindow]:::ui
        ST[设置窗口<br/>SettingsWindow]:::ui
        OB[新手引导<br/>Onboarding]:::ui
    end

    %% ===== 控制/协调层 =====
    subgraph CTRL [控制层 - AppModel]
        AM[AppModel<br/>@MainActor 总线]:::ctrl
        AM -->|驱动| UI
    end

    %% ===== 引擎层 =====
    subgraph ENG [引擎层]
        direction TB
        LE[ListenEngine<br/>系统音频识别<br/>本地 Speech]:::eng
        SE[SpeakEngine<br/>同声传译 / 扬声器输出]:::eng
        RE[RecordEngine<br/>麦克风录音识别]:::eng
        NE[NotesEngine<br/>实时纪要 / 鱼骨图 / 总结]:::eng
        TS[TranslationService<br/>Google 翻译<br/>原文→译文]:::eng
    end

    %% ===== 音频/底层层 =====
    subgraph AUDIO [音频采集与写入层]
        direction TB
        SAT[SystemAudioTap<br/>系统声音进程抓取]:::audio
        SM[SystemMic<br/>系统麦克风管理]:::audio
        VM[VirtualMic<br/>BlackHole 虚拟麦克风]:::audio
        AFW[AudioFileWriter<br/>ADTS AAC 片段<br/>→ .m4a 转码]:::audio
    end

    %% ===== AI 服务层 =====
    subgraph AI [AI 服务层]
        direction TB
        AC[AIClient<br/>频率限制 / 优先级 / 系统提示词]:::ai
        AP[AIProvider 接口]:::ai
        LP[LingProvider<br/>蚂蚁 Ling]:::ai
        MP[MiniMaxProvider<br/>MiniMax]:::ai
        CP[CustomProvider<br/>OpenAI 兼容]:::ai
    end

    %% ===== 存储层 =====
    subgraph STORE [存储层]
        SS[SessionStore<br/>会话 / 原文 / 纪要 / 音频]:::store
    end

    %% ===== 外部 =====
    subgraph EXT [外部]
        OS[macOS 系统<br/>语言 / 权限 / 本地化]:::ext
        SV[云端 AI 服务<br/>Ling / MiniMax / 自定义]:::ext
        LOC[本地化资源<br/>zh-Hans / en / ja / ko]:::ext
    end

    %% ===== 控制流 =====
    UI --> AM
    AM --> LE
    AM --> SE
    AM --> RE
    AM --> NE
    AM --> TS

    %% 听（系统声音）
    LE --> SAT
    LE --> SM
    SAT --> VM
    SM --> VM

    %% 录音（麦克风）
    RE --> VM
    RE --> AFW
    AFW --> SS

    %% 纪要（复用录音与会议数据）
    RE -->|lines| NE
    LE -->|lines| NE
    NE --> SS

    %% 同传
    SE --> AC
    SE --> VM

    %% AI 调用全部走 AIClient
    TS --> AC
    NE -->|总结/鱼骨/翻译| AC
    RE -->|翻译| AC

    AC --> AP
    AP --> LP
    AP --> MP
    AP --> CP

    %% 本地化 + 系统
    AM -->|AppleLanguages| OS
    UI --> LOC
    SS --> OS

    %% 外部服务
    LP --> SV
    MP --> SV
    CP --> SV

    %% ===== 样式 =====
    classDef ui fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px;
    classDef ctrl fill:#fff3e0,stroke:#ef6c00,stroke-width:2px;
    classDef eng fill:#e3f2fd,stroke:#1565c0,stroke-width:2px;
    classDef audio fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px;
    classDef ai fill:#ffebee,stroke:#c62828,stroke-width:2px;
    classDef store fill:#eceff1,stroke:#37474f,stroke-width:2px;
    classDef ext fill:#eeeeee,stroke:#616161,stroke-width:2px;

    linkStyle default stroke-width:1.5px,fill:none,stroke:#90a4ae;
```

## 架构概览

| 层 | 职责 | 核心文件 |
|---|---|---|
| **UI** | 菜单栏、字幕条、主窗口（会议记录 / 实时识别）、纪要窗口、设置、新手引导 | `AboutPanel.swift`、`Overlay.swift`、`Views.swift`、`CaptureViews.swift`、`NotesWindow.swift`、`SettingsWindow.swift`、`Onboarding.swift`、`ListenPill.swift` |
| **控制** | 所有引擎、UI、存储的总线与生命周期协调（`@MainActor`）；两条采集流共用的计时 `CaptureClock` | `AppModel.swift`、`CaptureClock.swift`、`CaptureSource.swift` |
| **引擎** | `ListenEngine` 系统声音识别；`SpeakEngine` 同声传译输出；`RecordEngine` 麦克风录音识别；`NotesEngine` 实时纪要（鱼骨图/总结/议题）；`TranslationService` Google 原文→译文 | `ListenEngine.swift`、`SpeakEngine.swift`、`RecordEngine.swift`、`Notes.swift`、`Translator.swift` |
| **音频** | `SystemAudioTap` 进程音频抓取；`SystemMic`/`VirtualMic` 麦克风管理；`AudioFileWriter` ADTS AAC 片段 → `.m4a` 转码 | `AudioRouter.swift`、`SystemMic.swift`、`VirtualMic.swift` |
| **AI** | `AIClient` 统一入口（频率限制、优先级、系统提示词）；`AIProvider` 接口由 `LingProvider`/`MiniMaxProvider`/`CustomProvider` 实现 | `AIClient.swift`、`AIProvider.swift`、`LingProvider.swift`、`MiniMaxProvider.swift`、`CustomProvider.swift` |
| **存储** | 会话、原文、纪要、音频的本地持久化与导出 | `SessionStore.swift` |
| **外部** | macOS 系统语言/权限；云端 AI 服务；多语言本地化资源 | `InterfaceLanguage.swift`、`Localization.swift`、`Resources/*.lproj` |

## 关键数据流

1. **听（系统声音）**：`SystemAudioTap` → `ListenEngine` → 实时字幕 + 会议纪要（原文 + Google 翻译）
2. **录（麦克风）**：`VirtualMic` → `RecordEngine` → `NotesEngine`（复用会议纪要管线） → `SessionStore`（保存原文、总结、鱼骨图、`.m4a` 音频）
3. **说（同声传译）**：麦克风 → `SpeakEngine` → AI 语音模型 → `VirtualMic` 输出到房间，绝不说未翻译的文本
4. **AI 调用**：全部走 `AIClient`，服务端差异封装在各自的 `AIProvider` 中，密钥仅存在 `0600` 的 `<service>-api-key` 文件，不进 `UserDefaults`/日志/导出
5. **界面语言**：`InterfaceLanguage.swift` 读写 `AppleLanguages`，跟随系统或用户指定（zh-Hans / en / ja / ko），改后需重启生效

## 两条采集流程：听（系统声音）与 录（麦克风）

上游采集是**两条独立管线**，下游纪要与存储则**复用同一套**。两者都从同一个 `CaptureFeed`
读，所以主窗口一个「实时识别」界面就能同时显示两条流。

| | 系统声音识别 | 麦克风录音识别 |
|---|---|---|
| **引擎** | `ListenEngine` | `RecordEngine` |
| **音频源** | `SystemAudioTap`（进程音频抓取） | `VirtualMic` / 真实麦克风设备 |
| **识别方式** | 本机 Apple `Speech`（on-device） | 本机 Apple `Speech`（on-device） |
| **结果去向** | 写入 `CaptureFeed` / `SessionStore` 同一会话的 `lines` | 写入 `CaptureFeed` / `SessionStore` 同一会话的 `lines` |
| **音频文件** | 不保留系统声音音频 | `AudioFileWriter` 存成 `mic.m4a`（ADTS AAC → m4a 转码） |
| **驱动纪要** | 同一个 `NotesEngine` | 同一个 `NotesEngine` |
| **控制面** | `AppModel.listen` / `AppModel.start()` | `AppModel.recorder` / `AppModel.startRecording()` |

四点要点：

1. **采集层分离** — `AppModel` 持有两个独立实例：`lazy var listen = ListenEngine(settings:)` 与
   `lazy var recorder = RecordEngine()`。系统声音走 `SystemAudioTap` 抓其他进程的输出；
   麦克风走音频设备输入，两者互不干扰。
2. **识别层分别运行** — 各有自己的 `SpeechRecognizer` 实例，分别断句、分别产出
   `RecordLine` / 字幕行。
3. **下游合并** — 两者都只把识别出的文本行写进同一个 `SessionStore` 会话，再都驱动同一个
   `NotesEngine`（`notes.begin(session.id)` / `notes.finish()`）。`NotesEngine` 只读
   `store.session(id).lines`，**不关心声音是从系统还是麦克风进来的**——这正是「录音直接复用
   会议那套实时纪要界面」的设计基础。
4. **一个界面读两条流** — `CaptureFeed`（`CaptureSource.swift`）是 `AppModel` 持有的
   `ObservableObject`，两条流的文本、电平、计时都写到它上面：系统声音由
   `listen.onSubtitle` / `listen.onTranslated` / `appendHeard` / `join` 写入，
   麦克风由 `recorder.lines` / `recorder.elapsed` / `recorder.level` 写入。
   `CaptureView`（`CaptureViews.swift`）按 `feed.source` 渲染左栏，右栏永远是
   `NotesContentView`。切换来源时，正在跑的那条先停，再换来源并 reset feed。

### 录音的状态机

`RecordEngine.State` 五态：`idle` → `preparing` → `recording` → `paused` → `stopping` → `idle`。

- `pause()`：状态转 `paused`，`generation += 1` 让进行中的半句不再往前写，但麦克风不关
  （电平表照样动），`elapsed` / `lines` / `live` 都冻住。
- `resume()`：状态转 `recording`，新句子照常转录，时钟继续走。
- `stop()`：接受 `recording` / `preparing` / `paused` 三种入口，走 `stopping` → 收尾 → `idle`。

### 两条路都能暂停：暂停期间时钟停住

「听」和「录」各有一个引擎，但**暂停的语义完全一样**，所以规则只写一份：
`CaptureClock`（`CaptureClock.swift`）管计时——暂停时时钟停住，暂停时长不算进会议时长，
恢复后从停住的地方接着走。`RecordEngine`（`recorder.clock`）与 `AppModel`
（`listenClock`）都用它。

暂停时**音频输入不关**：麦克风还开着、系统声音的 tap 还开着，电平表照样动。区别只在
「写不写进去」：

| | 听（`ListenEngine`） | 录（`RecordEngine`） |
|---|---|---|
| 暂停 | `router.setPaused(true)`：音频照收，但不喂给识别器 | `generation += 1`：进行中的半句不再往前写 |
| 半句 | 丢掉（暂停前后是两件事，不该接成一句） | 同上 |
| 恢复 | `router.setPaused(false)`，识别器还在 | 新句子照常转录 |

`AppModel.pauseListening()` / `resumeListening()` 是「听」这条路对外的两个动作，
`AppModel.pauseRecording()` 那一侧直接用 `recorder.pause()` / `recorder.resume()`。

### 工具栏胶囊和页面按钮读同一组数字

菜单栏 pill（`ListenPill.swift`）与主窗口「实时识别」页（`CaptureViews.swift`）是两处
独立的视图，要显示成同一个样子，靠的是**都从同一处取数**，不是各记一份：

- 状态：`AppModel.running` / `AppModel.listeningPaused`（系统声音）、`recorder.state`（麦克风）。
- 时长：都读 `CaptureClock.elapsed()`（经 `AppModel.listenElapsed` 或 `recorder.elapsed`）。
- 电平：`LevelMeter` 带 `source` 参数，录的时候读 `recorder.level`，听的时候读
  `listen.router.takeLevel()`——各读各的源，但都映射成同一个 0…1。

`AppModel.tickCapture()` 每 0.1 秒把当前那条流的时长、电平、波形写进 `CaptureFeed`，
页面的示波器和时钟都从 `feed` 读。录音暂停时 `tickCapture()` 仍走麦克风分支，
`capture.running` 保持 true。

页面的来源开关还**跟着正在跑的那条流走**（`CaptureView.source`）：在工具栏开始录音，
实时识别页立刻切到麦克风那一栏，按钮也跟着变成「暂停 / 停止」。

> 注：`docs/superpowers/specs/2026-11-05-mic-capture-design.md` 提出的 `ListenSource` /
> `AudioSourceCapture` 抽象类方案**尚未落地**。当前仍是两套独立实现，只是下游复用。

## 豆包录音功能的经验来源与落地情况

### 来源：公开产品形态，不是豆包的代码

`docs/superpowers/specs/2026-11-05-doubao-record-comparison.md` 开篇写明：

> ## 1. 豆包录音转录的核心体验（**基于公开产品形态推断**）

也就是说，这是一份**按豆包的用户可见体验反推的差距清单**，不是逆向豆包二进制得到的实现细节。
文档含 9 项差距、3 期路线图（Phase 1 核心体验对齐 / Phase 2 会话管理与总结增强 / Phase 3 打磨）。

### 落地情况（逐项核实代码）

| 豆包体验 | 计划 | 现状 |
|---|---|---|
| 逐字流式转写 | Phase 1.1 | ✅ `RecordEngine.liveWords: [LiveWord]`；`RecordEngine.words(of:)` 把 `AttributedString` 拆成带时间戳的词 |
| 句子可编辑 | Phase 1.2 | ✅ `RecordEngine.edit(_:text:)` + `RecordViews.editor(_:)`（TextField 改写） |
| 合并 / 拆分 | Phase 1.2 | ✅ `RecordEngine.merge(_:with:)` / `split(_:at:)` |
| 音频回放 | Phase 1.3 | ✅ `AVAudioPlayer` + `play(from:)` + `PlaybackDelegate` |
| 原文/译文/双语三态 | Phase 1.4 | ✅ `RecordViews` 的 `displayMode`（`.original` / `.translation` / `.bilingual`） |
| 导出 MD / Word / SRT | Phase 1.5 | ✅ `model.exportRecording(kind:)` 三种格式 |
| 说话人编号 | Phase 2 | ✅ `PersonNumbers`（人物 1、人物 2…，先听到的人永远占那个号） |
| 录音落盘 + 列表 | Phase 2.1 | ✅ 存进 `SessionStore`，与会议记录同一套 |
| 总结增强（结论/待办/鱼骨图） | Phase 2.3 | ✅ 但**换了做法**——删掉 `RecordEngine` 那套并行总结，改成复用会议的 `NotesEngine` |
| 说话人重命名 UI | Phase 2.4 | ⚠️ `SpeakerID` 有改名能力（`voiceNames`），但**录音页未接这个入口** |

### 没有学到的：豆包侧无法静态确定的问题

`findings.md` 记了三个**静态分析回答不了**的开放问题：

1. protobuf 每帧的运行时 `appkey` / `namespace` / `version`
2. 哪个服务器事件带 `utterances[]`
3. HTTP `AudioASR` 的调用点与 `scene` / `language` 参数

这些**需要带远程调试端口跑豆包**才能回答。

### 另一份独立设计（非豆包来源）

`docs/superpowers/specs/2026-11-05-mic-capture-design.md`（麦克风作为会议第二个来源）
是**独立设计**，不是从豆包学的：它要的是把房间里/旁边设备的声音也收进来，与「录自己说的话」
是两件事。其 `ListenSource` 抽类方案未落地（见上）。
