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

---

# 项目结构详细分析

> 项目路径：`~/cicada`  
> 项目名：`LiveSubs`（Package 名） / **Cicada 知了**（产品名，原名 Live Subs）  
> 类型：macOS 菜单栏 App（Swift 5，SwiftPM，无 `.xcodeproj`，无第三方依赖）

## 1. 顶层总览

```text
~/cicada/
├── .build/                         # SwiftPM 构建产物与索引缓存
├── .git/                           # Git 仓库元数据
├── .githooks/                      # Git hooks（pre-commit）
├── .github/                        # GitHub 配置（CI/发布说明）
├── .vscode/                        # VS Code 调试配置
├── build/                          # 本地打包/网站构建输出目录
├── docs/                           # 设计文档、路线图、对比分析、素材图片
├── Resources/                      # App 资源（本地化、模型、示例音频、DMG 素材）
├── scripts/                        # 构建/测试/打包/发布/网站/文案同步脚本
├── site/                           # 官网静态站点源码（cicada.indaloop.app）
├── Sources/                        # Swift 源码（主 App + 图标生成器）
├── Tests/                          # 单元测试
├── tools/                          # 开发/调试辅助工具（lsctl 等）
├── .DS_Store
├── .gitignore
├── 2026-11-05-doubao-record-comparison.md   # 豆包录音对比文档（根目录副本/工作稿）
├── agentmemory-guide.md            # 项目内存/上下文指引
├── AGENTS.md                       # 项目约束与开发规范（脚本强校验）
├── ARCHITECTURE.md                 # 架构图与数据流说明
├── CHANGELOG.md                    # 版本更新记录
├── CLAUDE.md                       # 指向 CLAUDE 相关说明的入口（内容极简）
├── findings.md                     # 调研/分析发现记录（工作文档）
├── LICENSE                         # Apache-2.0
├── Package.swift                   # Swift Package 定义
├── README.md                       # 中文 README（默认）
├── README.en.md                    # 英文 README
├── task_plan.md                    # 任务规划文档（工作文档）
└── 记录于 2026-11-04 12-29-05 下午.txt  # 本地记录文件
```

## 2. 根目录关键文件

| 文件 | 作用 |
|------|------|
| `Package.swift` | SwiftPM 配置：包名 `LiveSubs`，平台 `macOS 26.0`，`swiftLanguageModes: .v5`；两个可执行目标 `LiveSubs`、`LiveSubsIcon`，一个测试目标 `LiveSubsTests` |
| `AGENTS.md` | 项目硬规则与约定（权限/密钥/AI 调用路径/UI 约束/本地化/构建验证流程）；`scripts/check-agents.py` 与 pre-commit/CI 会校验 |
| `ARCHITECTURE.md` | Mermaid 架构图、分层职责、关键数据流、听/录双采集管线设计说明 |
| `README.md` / `README.en.md` | 产品介绍、功能、隐私、模型、安装、路线图、开发方式（中/英双语） |
| `CHANGELOG.md` | 发布版本变更历史 |
| `LICENSE` | Apache-2.0（BlackHole 驱动 GPL，安装时从官方地址下载，不随包分发） |
| `findings.md` / `task_plan.md` | 开发过程中的调研结论与任务拆解（含豆包对比、未落地设计等） |
| `2026-11-05-doubao-record-comparison.md` | 与豆包录音体验的对比与分期计划 |
| `agentmemory-guide.md` | 项目上下文/记忆整理指引 |
| `CLAUDE.md` | Claude 相关提示入口（当前仅占位性内容） |

## 3. 源码结构（`Sources/`）

```text
Sources/
├── LiveSubs/          # 主应用（65 个 Swift 文件）
└── LiveSubsIcon/      # 图标生成器可执行目标（1 个 Swift 文件）
    └── main.swift
```

### 3.1 `Sources/LiveSubs/` — 按职责分类（65 文件）

#### A. 应用入口与总控
| 文件 | 职责 |
|------|------|
| `AppModel.swift` | `@MainActor` 核心总线：协调 UI、引擎、存储、设置、调试命令；持有 `listen`/`recorder`/`notes` 等状态与生命周期 |
| `AppMenu.swift` | 菜单栏菜单与快捷入口 |
| `LoginItem.swift` | 登录项管理 |
| `DevBuild.swift` | 开发构建标识/行为差异 |
| `Diagnostics.swift` | 本地诊断信息记录（耗时/次数等，不上报） |

#### B. 音频采集与路由（底层）
| 文件 | 职责 |
|------|------|
| `SystemAudioTap.swift` | 系统声音进程音频抓取（Core Audio process tap） |
| `AudioRouter.swift` | 音频回调缓冲与队列分发（UI/引擎线程边界） |
| `SystemMic.swift` | 系统麦克风设备与权限/选择管理 |
| `VirtualMic.swift` | BlackHole 2ch 虚拟麦克风安装、切换与输出管理 |
| `MicUsers.swift` / `MicUsersView.swift` | 占用/使用麦克风的应用检测与展示 |
| `RecordGate.swift` | 录音前置条件/门控判断 |
| `RecordScope.swift` | 录音范围/模式控制 |

#### C. 识别与采集引擎
| 文件 | 职责 |
|------|------|
| `ListenEngine.swift` | 系统音频监听管线：tap → 语言检测/语音识别 → 字幕与会话文本 |
| `RecordEngine.swift` | 麦克风录音识别：录音状态机、逐字/逐句结果、编辑/合并/拆分、回放、保存 |
| `SpeakEngine.swift` | 同声传译：按键说话 → 识别/翻译 → 合成语音 → 虚拟麦克风输出 |
| `SpeakTest.swift` / `SpeakTestView.swift` | 同声传译/发声测试流程与 UI |
| `CaptureClock.swift` | 听/录共用计时器（暂停时冻结时长，恢复续走） |
| `CaptureSource.swift` | 统一采集数据源 `CaptureFeed`（文本、电平、波形、来源状态）供 UI 读取 |
| `AudioFileWriter.swift`* | 音频落盘（ADTS AAC 片段转 `.m4a`，在架构中提及；具体实现位于录音链路相关文件） |

> *注：`AudioFileWriter` 在 `ARCHITECTURE.md` 中作为独立组件描述；实际代码分布以 `RecordEngine.swift` / 存储链路为准。*

#### D. 语言、翻译与文本处理
| 文件 | 职责 |
|------|------|
| `LanguageDetector.swift` | 语言识别 |
| `Languages.swift` | 语言枚举/映射与展示信息 |
| `LanguageSettings.swift` | 语言相关设置项 |
| `Translator.swift` | 翻译服务封装（Google 翻译、Apple Translation 回退等） |
| `Localization.swift` | `L("…")` 等本地化辅助 |
| `InterfaceLanguage.swift` | 界面语言切换（`AppleLanguages`） |
| `HeardText.swift` | 听写/识别文本模型与处理 |
| `Corrector.swift` | 录音后自动纠错（同音字/标点等） |

#### E. AI 服务与配置
| 文件 | 职责 |
|------|------|
| `AIClient.swift` | 统一 AI 调用入口：限流、优先级、系统提示、错误处理 |
| `AIProvider.swift` | Provider 协议与通用抽象 |
| `LingProvider.swift` | Ling / Ming 服务实现 |
| `MiniMaxProvider.swift` | MiniMax 服务实现 |
| `CustomProvider.swift` | OpenAI 兼容自定义接口实现 |
| `AISettings.swift` | AI 服务设置模型/密钥状态逻辑 |
| `VoicePicker.swift` / `Voices.swift` | 语音/音色选择与目录 |

#### F. 纪要与会话智能
| 文件 | 职责 |
|------|------|
| `Notes.swift` | `NotesEngine`：实时纪要、总结、议题、结论/待办、鱼骨图、人名术语归一等 |
| `SessionStore.swift` | 会话持久化：双语记录、纪要、原始录音、导出数据源 |
| `SpeakerID.swift` | 实验性说话人识别（WeSpeaker Core ML 声纹，命名/编号能力） |
| `MeetingEnd.swift` | 会议自动结束/暂停策略（静默检测、处理方式） |

#### G. UI — 主界面与窗口
| 文件 | 职责 |
|------|------|
| `Views.swift` | 主窗口与通用视图 |
| `CaptureViews.swift` | 实时识别页（听/录双流展示、控制条、波形、电平、模式切换） |
| `NotesWindow.swift` | 纪要窗口（AI 视图/文字总结、目录跳转、非激活面板、屏幕共享可见性控制） |
| `NotesViews.swift` | 纪要内容渲染组件 |
| `MindMapView.swift` | 鱼骨图/思维导图视图 |
| `FishboneImage.swift` | 鱼骨图图像生成/导出辅助 |
| `Overlay.swift` | 字幕条（悬浮字幕、鼠标悬停透明） |
| `ListenPill.swift` | 菜单栏/状态胶囊 UI |
| `FloatingPillWindow.swift` | 独立浮动胶囊窗口（无标题栏、可拖拽、置顶） |
| `PillButtonRegions.swift` | 胶囊按钮命中区域与交互分区 |
| `ScreenAnchor.swift` | 窗口/浮层定位辅助 |
| `AboutPanel.swift` | 关于面板 |

#### H. UI — 设置、引导与导出
| 文件 | 职责 |
|------|------|
| `Settings.swift` | `AppSettings` 与各类设置键定义 |
| `SettingsWindow.swift` | 设置窗口 UI（AI 服务、权限、同传、录音、语言等） |
| `Onboarding.swift` | 四步新手引导（系统音频、示例会议、AI key、同传/虚拟麦克风） |
| `OnboardingKey.swift` | 引导流程中的 key 输入/校验组件 |
| `ExportSheet.swift` | 导出面板（AI 视图/文字总结/原始记录，Markdown/Word/PDF/SRT） |
| `RecordSaving.swift` / `RecordSavingView.swift` | 录音保存/落盘进度与状态 UI |
| `UpdateViews.swift` / `Updates.swift` / `UpdateChecker.swift` / `Updater.swift` | 更新检查、提示与安装流程 |
| `Shortcuts.swift` | 快捷键定义与处理 |
| `DMGBackground.swift` | DMG 背景生成相关（构建/打包辅助） |

#### I. 其他
| 文件 | 职责 |
|------|------|
| `InterfaceLanguage.swift` 等与本地化/系统集成辅助散布于上述分组 |

> 注：部分文件职责有交叉（如 `CaptureViews.swift` 同时承担录音/听写 UI 与控制）；分类以主要职责为准。

## 4. 资源结构（`Resources/`）

```text
Resources/
├── dmg/
│   └── DS_Store                    # DMG 窗口布局元数据
├── en.lproj/
│   ├── InfoPlist.strings
│   ├── Localizable.strings
│   └── Localizable.stringsdict
├── ja.lproj/
│   ├── InfoPlist.strings
│   └── Localizable.strings
├── ko.lproj/
│   ├── InfoPlist.strings
│   └── Localizable.strings
├── zh-Hans.lproj/
│   ├── InfoPlist.strings
│   └── Localizable.strings
├── models/
│   └── SpeakerEmbedding.mlpackage/ # 说话人声纹模型（WeSpeaker ResNet34-LM, Core ML）
│       ├── Data/com.apple.CoreML/model.mlmodel
│       ├── Data/com.apple.CoreML/weights/weight.bin
│       └── Manifest.json
├── sample/
│   └── sample.m4a                  # 示例会议音频（引导/测试）
└── Info.plist                      # App Info.plist 模板/资源
```

## 5. 测试结构（`Tests/`）

```text
Tests/
└── LiveSubsTests/                  # 16 个单元测试文件（纯逻辑/引擎行为）
    ├── AudioFileTests.swift
    ├── CaptureClockTests.swift
    ├── CorrectorTests.swift
    ├── ExportTests.swift
    ├── HeardTextTests.swift
    ├── InterfaceLanguageTests.swift
    ├── LanguageTests.swift
    ├── MeetingEndTests.swift
    ├── MicUsersTests.swift
    ├── PillDoubleClickTests.swift
    ├── RecordEngineTests.swift
    ├── RecordGateTests.swift
    ├── SpeakerTests.swift
    ├── SpeakScoreTests.swift
    ├── SystemMicTests.swift
    └── UpdateTests.swift
```

**特点**：聚焦纯逻辑与可单测组件（时钟、文本处理、导出、状态机、更新判断等）；涉及真实权限/音频设备/BlackHole 安装的流程需人工验证（见 `AGENTS.md`）。

## 6. 脚本（`scripts/`）

| 文件 | 作用 |
|------|------|
| `build.sh` | 编译 App（开发版/`RELEASE=1` 正式版），产出 `build/Cicada.app` |
| `test.sh` | 运行 `AGENTS.md` 校验 + 单元测试 |
| `package.sh` | 打包 DMG/zip 与 SHA-256 校验值 |
| `release.sh` | 按提交生成 changelog 段并驱动发布流程（CI 发 tag） |
| `release_notes.sh` | 发布说明辅助 |
| `changelog.py` | 从 commit 生成/处理 changelog 内容 |
| `check-agents.py` | 校验 `AGENTS.md` 结构与大小约束 |
| `strings.py` | 本地化字符串同步（UI 文案变更后 `--write` 补 TODO） |
| `site.py` | 官网静态站点生成器（读取模板/i18n/changelog 数据） |
| `site-images.sh` | 官网/图标相关图片资源生成 |
| `site-og.html` | OG 图生成模板 |
| `deploy-site.sh` | 构建并部署官网到 Cloudflare Worker（`cicada-site`） |
| `make-sample.sh` | 生成示例音频素材 |
| `dmg-template.sh` | DMG 模板处理 |
| `convert-voiceprint.py` | 将 WeSpeaker 声纹模型转换为 Core ML（`SpeakerEmbedding.mlpackage`） |

## 7. 开发工具（`tools/`）

| 文件 | 作用 |
|------|------|
| `lsctl` | 已编译的 CLI 工具（驱动 dev build，执行 `AppModel.debugCommand`） |
| `lsctl.swift` | `lsctl` 源码 |
| `README.md` | 工具使用说明与测试技巧（命令真值以 `AppModel.debugCommand` 为准） |
| `key.swift` / `toggle-key.swift` | 按键模拟/切换辅助 |
| `mouse` / `mouse.swift` | 鼠标操作辅助 |
| `winall` / `winall.swift` | 窗口操作辅助 |
| `transcribe.swift` | 转写相关辅助脚本/工具 |
| `ccswitch-minimax-claude.py` | AI 服务/配置切换辅助脚本 |

## 8. 文档与设计资料（`docs/`）

```text
docs/
├── demo.gif
├── icon.png
├── interpreting.png
├── onboarding.png
├── records.png
├── ROADMAP.md
├── ROADMAP.zh-CN.md
└── superpowers/specs/
    ├── 2026-11-05-doubao-record-comparison.md
    ├── 2026-11-05-mic-capture-design.md
    ├── 2026-11-12-doubao-mic-ui-analysis.md
    └── 2026-11-14-record-transcript-autocorrect-design.md
```

- **顶层图片/GIF**：README 与官网展示素材
- **ROADMAP**：中英文路线图
- **specs/**：功能对比、麦克风采集设计、UI 分析、转写自动纠错设计等方案文档

## 9. 官网（`site/`）

```text
site/
├── audio/
│   ├── meeting-zh.m4a
│   ├── speak-en.m4a
│   └── speak-zh.m4a
├── i18n/
│   ├── en.json
│   ├── ja.json
│   ├── ko.json
│   └── zh.json
├── img/
│   ├── hero.jpg
│   └── start/
│       ├── en-key.jpg
│       ├── en-permissions.jpg
│       ├── ja-key.jpg
│       ├── ja-permissions.jpg
│       ├── ko-key.jpg
│       ├── ko-permissions.jpg
│       ├── zh-key.jpg
│       └── zh-permissions.jpg
├── changelog.html
├── changelog.json
├── footer.html
├── header.html
├── icon.png
├── icon.svg
├── index.html
├── og.png
├── start.html
└── style.css
```

- **多语言**：中文 `/`，英文/日文/韩文对应 `/en/` `/ja/` `/ko/`（由 `scripts/site.py` 生成到 `build/site` 或部署产物）
- **内容源**：`i18n/*.json` 提供 `{{t.key}}` 文案；`changelog.json` 为官网更新日志数据
- **素材**：产品截图、引导步骤图、音频示例、OG 图与图标

## 10. 构建与工程辅助目录

| 目录/文件 | 说明 |
|-----------|------|
| `.build/` | SwiftPM 构建缓存（`debug`/`release` 软链、`index-build/`、`manifest.pif`、`workspace-state.json` 等） |
| `build/` | 本地构建输出：`Cicada.app`、`AppIcon.iconset`、`site/`（生成的静态站点） |
| `.github/workflows/build.yml` | CI 构建流程 |
| `.github/workflows/release.yml` | CI 发布流程 |
| `.github/release-notes.md` | 发布说明模板/内容 |
| `.githooks/pre-commit` | 提交前检查（含 `AGENTS.md` 约束相关校验） |
| `.vscode/launch.json` | VS Code 调试配置 |

## 11. 结构性特征总结

1. **单包多目标**：`LiveSubs`（主 App）+ `LiveSubsIcon`（图标工具）+ `LiveSubsTests`，无外部依赖。
2. **源码按“单文件单关注点”组织**：`Sources/LiveSubs/` 内 65 个 Swift 文件覆盖引擎、AI、UI、存储、系统集成，`AppModel.swift` 为最大协调中心（~132K）。
3. **双采集管线、单纪要引擎**：系统音频（`ListenEngine`）与麦克风录音（`RecordEngine`）独立采集，统一写入 `CaptureFeed`/`SessionStore`，共享 `NotesEngine`。
4. **AI 抽象清晰**：`AIClient` 统一治理，`AIProvider` 协议隔离 `Ling`/`MiniMax`/`Custom` 差异；密钥文件化（`0600`）且按服务分离。
5. **产品化配套完整**：含引导、设置、导出、更新、诊断、网站、脚本化构建发布与本地化资源（zh/en/ja/ko）。
6. **文档与演进痕迹丰富**：`AGENTS.md`/`ARCHITECTURE.md`/`docs/superpowers/specs/*`/`findings.md`/`task_plan.md` 记录了设计决策、对标分析与未落地方案。
