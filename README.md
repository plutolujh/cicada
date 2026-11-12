<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="知了图标">
</p>

<h1 align="center">知了 · Cicada</h1>

<p align="center">
  任何会议、任何直播，没有语言障碍。<br>
  听得懂，说得出，记得住。Mac 上的实时纪要、双语文字记录、字幕与同声传译。
</p>

<p align="center">
  <a href="https://cicada.indaloop.app"><img src="https://img.shields.io/badge/官网-cicada.indaloop.app-E8552B?style=for-the-badge" alt="官网 cicada.indaloop.app" height="36"></a>
  &nbsp;
  <a href="https://github.com/wquguru/cicada/releases/latest"><img src="https://img.shields.io/badge/下载-macOS 版-15171C?style=for-the-badge&logo=apple&logoColor=white" alt="下载 macOS 版" height="36"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20silicon-only-black" alt="Apple 芯片">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0">
</p>

<p align="center"><a href="README.md">简体中文</a> · <a href="README.en.md">English</a></p>

无论是用 Zoom、飞书、腾讯会议开会，还是听 X Spaces 和 YouTube 直播，知了都能实时给出双语字幕、边听边写结构化纪要。遇到需要发言的时候，按住键盘右边的 `⌥` 键开口，对方就能在会里直接听到翻译好的语音。这一切都靠直接读取 Mac 系统声音并在本机识别来完成，声音不出电脑，不用往会里塞机器人，对方更是完全无感。

<p align="center">
  <img src="docs/demo.gif" width="800" alt="YouTube 播着 Bloomberg 英文直播，右边是知了实时整理的中文纪要、议题与鱼骨图，底部是双语字幕">
</p>

## 主要功能

### 实时纪要与双语文字记录

开会时纪要窗口边听边整理总结、议题要点、结论、待办、鱼骨图和人名术语表，点一下结论或待办就能跳回双语文字记录里的原话。纪要会统一文中人名和术语的写法并记下听错的变体，按 `⌘F` 搜索时能连同识别错的写法一起搜出来。

### 实时字幕与语言识别

对方开口几秒钟就能在本地自动认出语言并翻成你的系统语言，按 `⌃⌥S` 可以在纪要窗口、字幕条和不显示之间切换。字幕条只在有人说话时出现，鼠标划过时自动变透明，不会挡住底下的按钮。

### 同声传译

按住键盘右边的 `⌥` 键说话，对方在会议软件里就能直接听到翻译后的语音，打开同声传译时知了会自动把系统麦克风切到一键安装的虚拟驱动 BlackHole 2ch。填了 Ling API key 后可以用自然人声或用 8 到 30 秒录音克隆你自己的声音，不填也能用 Mac 自带语音。

<p align="center">
  <img src="docs/interpreting.png" width="640" alt="同声传译设置页，包含按住右 Option 键说话、目标语言、Ming 声音试听与本机声音选择">
</p>

### 会议记录

每场会议的双语文字记录、纪要和原始录音都保存在本机，打开实验性的说话人识别后还能区分对方不同的说话人并在有 key 时填上名字。会议软件挂断或 10 分钟没人说话时会自动结束并截掉空白，会后随时可以补生成纪要，或导出成 Markdown、Word 和 SRT 字幕。目前记录里的你只包含按住说话键说的话，会上直接开口的部分见[路线图](#路线图)。

<p align="center">
  <img src="docs/records.png" width="640" alt="会议记录窗口，显示识别出的说话人名字和逐句英中双语文字记录">
</p>

### 录音转写

主窗口里有一个「麦克风录音」：对着麦克风说话，左边一行行转出你说了什么，右边是会议那套「实时纪要」——一边讲一边写出总结、议题、结论、待办和用到的人名术语，议题讲的是「为什么」时还会画成鱼骨图。语言自己认，不用先选，中英文混着说也行，说到一半换语言也不会丢掉那句话。转写可以顺手翻成你读得懂的语言：点「翻译成」选一种，中文翻英文、英文翻中文都行，也可以选「不翻译」。几个人一起聊也分得开：每句话前面标着人物 1、人物 2，谁换了人就换标签，纪要也会写清楚是谁说的。识别全程在这台 Mac 上完成，声音不会上传；只有翻译和纪要会用到你的 AI 服务。

录完不会就这样断掉：知了会告诉你录了什么进去——录音、原文、翻译、纪要，一件件落位——然后直接翻到那条会议记录里，接着能看、能搜、能导出。控制条上有一条波形示波器，看得出麦克风收到多响，旁边是这次录音的总时长。

字是一个一个出现的：边说边写，最新的那个字是橙色的，不用等整句话说完。写错了点旁边的铅笔改掉，嫌两句太碎可以合并，觉得一句太长可以拆开，改完的版本一样存进会议记录。每句话旁边还有播放键，点一下就从那句话开始放录音。录音页上方可以切换原文、译文或双语，右上角能导出成 Markdown、Word 或 SRT 字幕。

## 隐私与权限

声音采集、语言识别、语音识别（Apple SpeechAnalyzer）和会议录音全部在本机完成。会离开电脑的只有识别出来的文字（发去做翻译和生成纪要），以及填了 Ling API key 并按住说话键用同声传译时你说的那几句语音。不填 API key 时，实时字幕、翻译（走 Google 或退回 Apple 本机翻译）、会议记录和同声传译都能正常用。实时纪要需要你自己的 API key，可以是 Ling（蚂蚁集团的大模型服务）、MiniMax 或任何 OpenAI 兼容的接口（配置方法见[下文](#配置-ai-服务)），开一小时会大约花 0.15 到 1 元人民币，Ling 每月赠送 10 元额度，约够 10 到 50 小时会议。

知了只在用到某项功能时才请求对应的权限，拒绝后其他功能照常可用。

| 权限 | 用来做什么 | 什么时候问 | 不给的话 |
|---|---|---|---|
| 录制系统声音（屏幕与系统录音） | 听 Mac 正在播放的声音来出字幕，不录屏幕，也不听知了自己的声音 | 新手引导第一步，或第一次开始听 | 字幕和纪要都用不了 |
| 麦克风 | 录一段话转成文字（录音页），以及你按住说话键时录音做同声传译 | 打开同声传译或第一次开始录音时 | 只是不能说话翻译和录音转写 |
| 输入监控 | 只用来判断右 `⌥` 是否被单独按下（只监听、不拦截、不记录别的按键） | 第一次用右 `⌥` 说话时 | 在设置里改成 `⌃`/`⌘` 组合键，就不需要这个权限 |
| 管理员密码 | 安装虚拟麦克风 BlackHole 2ch，并重启系统音频服务 | 在引导或设置里点“安装”时，只问一次 | 不能让对方听到翻译，其余照常 |

- **联网与虚拟麦克风**。只有翻译（`translate.googleapis.com`）、填了 key 后所选的服务（Ling / Ming 为 `api.ant-ling.com`，MiniMax 为 `api.minimaxi.com`）、下载 BlackHole 驱动和每天去 GitHub 检查一次新版本会联网。BlackHole 从官方下载已经过苹果公证的安装包，安装前会核对代码里写死的 SHA-256。
- **没有统计和自建服务器**。应用没有统计、没有埋点，也没有我们自己的服务器，诊断功能只把耗时和次数记在本机会议文件夹里。
- **本机数据位置**。会议记录、录音和纪要存在 `~/Library/Application Support/LiveSubs`。各家的 key 和你录的声音样本只对当前系统账户可读，不进 Time Machine 备份，也不写进日志和导出文件。
- **共享屏幕看不到纪要窗口**。屏幕共享、录屏和截图都拍不到它，要录演示时可以打开“共享屏幕时让对方看到”。

## 用的模型

知了可以接三家 AI 服务：Ling、MiniMax，以及任何 OpenAI 兼容的接口。在“设置 › AI 服务”里换一家，实时纪要、整句翻译和同声传译就跟着换过去，各家的 key 分别存在这台 Mac 上，互不覆盖。

不填 key 时全部由 Apple 本机模型加 Google 翻译完成，填了 key 后由所选的服务负责并支持失败自动退回。

| 功能 | 填了 key | 不填 key / 退回 |
|---|---|---|
| 语音识别、语言识别 | Apple `SpeechAnalyzer` / `SpeechTranscriber`（本机） | 同左 |
| 整句翻译 | 所选服务的模型（Ling 默认 `Ling-3.1-flash`，MiniMax 默认 `MiniMax-M2`） | Google 翻译 → Apple `Translation`（本机） |
| 正在说的半句话的翻译 | Google 翻译（不占所选服务的频率额度） | Apple `Translation`（本机） |
| 实时纪要、会后完整版 | 所选服务的模型（同上设置） | 不可用 |
| 检查 key 是否有效 | 一个最便宜的请求（Ling 用 `Ling-3.0-tiny`，只花一个 token） | — |
| 同声传译：听懂并翻译你说的话 | Ling 用 Ming `Ming-3.0-audio-flash` 一步完成；MiniMax 和自定义接口没有音频模型，先在本机转写再翻译 | Apple 本机识别，再走上面的翻译链 |
| 同声传译：对方听到的声音 | Ling 用 Ming `Ming-3.0-tts-0.5B`，MiniMax 用 `speech-02-turbo` | Mac 自带语音（`AVSpeechSynthesizer`） |
| 声音克隆 | 只有 Ling 可以（8 到 30 秒录音） | 不可用 |
| 说话人识别（实验功能，默认关闭） | WeSpeaker ResNet34-LM 声纹模型，随 app 附带，本机运行（Core ML） | 同左 |

## 配置 AI 服务

在“设置 › AI 服务”里选一家，各家的 key 分别存在这台 Mac 上，随时切回来另一个还在。

**Ling（默认）**

1. 打开 [Ling 开放平台](https://chat.ant-ling.com/platform/api)，注册或登录。
2. 点创建令牌，复制以 `sk-` 开头的那串 key。
3. 粘贴后点保存并检查，也可以直接粘贴到纪要窗口顶部的提示框里。知了会发一个只用一个 token 的请求确认 key 可用。
4. 同一页面可以选模型（默认 `Ling-3.1-flash`），每种语言用哪个 Ming 声音在同声传译设置里选。想移除 key，在同一页面点移除即可。

**MiniMax**

1. 打开 [MiniMax 开放平台](https://platform.minimaxi.com/user-center/basic-information/interface-key)，创建 API Key 并复制。
2. 把服务换成 MiniMax，粘贴 key 后点保存并检查。
3. 模型默认 `MiniMax-M2`，可以在同一页改。用国际版接口的话，选“自定义”并把地址填成 `https://api.minimax.io/v1`。

**自定义（任何 OpenAI 兼容的接口）**

1. 把服务选成“自定义”，填上服务商的接口地址和模型名。
2. 填它的 API key，保存并检查。
3. 不认识的接口不做语音合成，同声传译继续用 Mac 自带的声音。

## 系统要求与安装

需要 macOS 26 或更新版本、Apple 芯片的 Mac。界面有中文、英文、日文和韩文，默认跟随系统语言；在知了的「设置 › 语言 › 界面语言」里可以随时改，改完重启一次即可。

从 [Releases 页面](https://github.com/wquguru/cicada/releases/latest) 或 [官网](https://cicada.indaloop.app) 下载 `Cicada-<版本>-macOS-AppleSilicon.dmg`，打开后把知了拖进应用程序文件夹。应用目前是本地签名，还没有苹果公证（见[路线图](#路线图)），第一次打开被拦下时，去系统设置的隐私与安全性里点仍要打开。下载页同时提供 `checksums.txt`，可以用 `shasum -a 256 Cicada-*.dmg` 核对。有疑问可以去 X 找作者 [@wquguru](https://x.com/wquguru)。

打开后跟着首次引导开一个权限、听一段双人示例会议直接看字幕效果、接上 AI 服务的 key（也可以先跳过），要用同声传译时再装虚拟麦克风。之后有新版本时菜单栏图标会出现橙点，点一下就能更新，权限不会丢。

<p align="center">
  <img src="docs/onboarding.png" width="640" alt="首次引导第二步，播放双人示例会议并实时显示双语字幕">
</p>

## 路线图

按先后排，想要哪一项欢迎在 Issues 里说。

- **记录我的发言**，开会时持续听麦克风并做回声消除，把你直接开口说的话也记进文字记录和纪要。
- **支持更早的 macOS（14.4 起）**，在旧系统上改用较早的系统语音识别与翻译接口。
- **正式签名与公证**，首次打开不再需要点仍要打开，AI key 也能放回系统钥匙串。
- **声纹识别**，在现有的说话人识别基础上，在本机记住常一起开会的人的声音，下次开会也能自动认出。
- **不用 key 也有纪要**，在支持的 Mac 上用 Apple 本机模型整理纪要，以及**自选 AI 服务**接入其他兼容 OpenAI 接口的服务。
- **Windows 和 Android**，共用纪要与会议记录格式，iPhone 和 iPad 因系统限制暂不计划。

每项的细节和取舍见 [docs/ROADMAP.zh-CN.md](docs/ROADMAP.zh-CN.md)。

## 卸载

退出知了，去应用程序文件夹里把它拖进废纸篓即可。会议记录和录音都在 `~/Library/Application Support/LiveSubs` 文件夹里，不需要的话可以手动删掉。想清除软件设置可以运行：

```bash
defaults delete com.wquguru.cicada
```

## 开发

从源码构建只需要安装 Xcode Command Line Tools（`xcode-select --install`），项目没有任何第三方依赖。

```bash
scripts/build.sh            # 编译开发版 → build/Cicada.app（名为 Cicada Dev，可与正式版同时运行）
open build/Cicada.app
scripts/package.sh          # 打包正式版 DMG、zip 和 SHA-256 校验值
```

代码架构等说明写在 [AGENTS.md](AGENTS.md) 里。官网源码放在 `site/` 目录，由 `scripts/site.py` 生成。历次更新记录见 [CHANGELOG.md](CHANGELOG.md) 或官网的[更新日志页](https://cicada.indaloop.app/changelog/)。

## 开源协议

本项目采用 [Apache-2.0](LICENSE) 协议开源。同声传译用到的虚拟麦克风驱动 BlackHole 2ch 采用 GPL 协议，知了安装包里不打包它，在你点安装时直接从它的官方发布地址下载。随 app 附带的声纹模型是 [WeSpeaker](https://github.com/wenet-e2e/wespeaker) 在 VoxCeleb 上训练的 ResNet34-LM，采用 CC BY 4.0 协议，由 `scripts/convert-voiceprint.py` 转成 Core ML。
