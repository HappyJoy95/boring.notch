<h1 align="center">
  <br>
  <img src="boringNotch/Assets.xcassets/logo2.imageset/BoringNotch%20icon.png" alt="Boring Notch" width="150">
  <br>
  Boring Notch
  <br>
</h1>

<p align="center">
  <a href="https://github.com/HappyJoy95/boring.notch/releases">HappyJoy95 Releases</a>
  ·
  <a href="https://github.com/HappyJoy95/boring.notch/actions">GitHub Actions</a>
  ·
  <a href="https://github.com/TheBoredTeam/boring.notch">原始项目</a>
</p>

**Boring Notch** 将 MacBook 灵动岛变成动态音乐控制中心，并集成日历、提醒事项、文件暂存区、镜像、系统 HUD 和 AI Agent 会话等功能。

<p align="center"><img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="Boring Notch 功能演示" /></p>

## 独立维护版本

本项目是 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 的独立维护 Fork，增加了 AI Agent 集成、音乐控制和歌词等功能。本项目与原团队没有官方隶属关系；应用标识、发行版本和下载由 HappyJoy95 独立维护。上游作者与贡献者的版权信息和许可证继续保留。

本 Fork 当前基于上游 `v2.7.3`，独立版本号采用 `v2.7.3-hj.1`、`v2.7.3-hj.2` 的格式。上游升级后，以新的上游版本为基线，例如 `v2.8.0-hj.1`。

## 功能

- **音乐与实时动态**：展示正在播放的曲目、封面和可视化效果，并提供播放控制。
- **系统集成**：日历、提醒事项、镜像、充电状态、电量、手势控制、文件暂存区，以及音量、亮度和键盘背光 HUD。
- **灵动岛外观**：可调整尺寸以适配不同显示器。
- **多来源 AI Agent 会话**：接入 Codex、WorkBuddy、DSH 和 MiMo Desktop，查看置顶会话、运行状态及最近回复；可分别启用来源，并调整刷新间隔、会话窗口字号和卡片排序。
- **会话交互**：Codex、DSH 和 MiMo 支持发送消息与打断；WorkBuddy 支持发送消息。DSH、MiMo 和 WorkBuddy 的接入组件提供安装或配对入口。
- **新消息跟随**：会话窗口原本位于底部时跟随新消息；查看较早内容时保留当前位置。
- **动画优化**：优化图标状态切换和悬停反馈，让控制项更快响应。
- **歌词显示**：按播放器选择歌词来源，改进 QQ 音乐的歌名、歌手、专辑和时长匹配；无歌词时不显示无效占位内容。
- **QQ 音乐和网易云音乐控制**：识别实际媒体来源，支持喜欢歌曲及随机、单曲循环、列表循环切换。相关控制需要 macOS 辅助功能权限。
- **来源图标**：MiMo Desktop 显示小米汽车标识，DSH 显示 DeepSeek 标识。

接入说明：[多来源 AI Agent](docs/agent-providers.md)、[DSH](docs/dsh-integration.md)、[MiMo Desktop](docs/mimo-integration.md)和[WorkBuddy](docs/workbuddy-integration.md)。

## 安装与更新

**系统要求：** macOS 14 Sonoma 或更高版本，支持 Apple 芯片和 Intel Mac。

正式版发布后，请从[本仓库的 Releases 页面](https://github.com/HappyJoy95/boring.notch/releases)下载 `boringNotch.dmg`，将 **Boring Notch (HappyJoy95).app** 拖入“应用程序”文件夹。首版计划版本为 `v2.7.3-hj.1`；发布前 Releases 页面可能还没有安装包。此版本不在 App Store 上架。

安装后，应用通过 Sparkle 每日自动检查 HappyJoy95 GitHub Releases 中的签名更新 feed，并默认在后台下载更新；也可以在菜单栏或“设置 → 关于”中手动检查，并在“设置 → 关于”调整自动检查和下载选项。更新包使用独立 EdDSA 密钥签名，来源只指向本仓库，不经过 App Store。当前官方 Homebrew Cask 安装的是上游官方版本，不包含本 Fork 的功能；本仓库暂未提供自己的 Homebrew Cask。

## 构建与发布

在 GitHub Actions 中运行 **Fork Manual Build** 可构建 App、DMG 和 Sparkle 更新 ZIP，并下载 Actions Artifact；运行 **Fork Release** 可发布正式版本。Release 版本必须使用 `上游版本-hj.序号` 格式，并与 Xcode 项目中的 `MARKETING_VERSION` 完全一致。构建号单独递增。工作流会从本次选中的 `main` 提交构建，创建指向同一提交的 Git Tag，并附上 DMG、签名 appcast、更新 ZIP 和 SHA-256 校验文件。

目前没有 Apple Developer ID 签名或公证。首次打开时，macOS 可能显示安全提示。

## 从源代码构建

### 前置条件

- macOS 15.6 或更高版本
- Xcode 26 或更高版本

### 步骤

```bash
git clone https://github.com/HappyJoy95/boring.notch.git
cd boring.notch
open boringNotch.xcodeproj
```

在 Xcode 中选择 `boringNotch` scheme，点击运行或按 `Cmd + R`。

## 同步上游

仓库保留完整 Git 历史及 `upstream` 关系。常规同步方式：

```bash
git remote add upstream https://github.com/TheBoredTeam/boring.notch.git
git fetch upstream
git checkout main
git merge upstream/main
```

同步后应构建并检查 AI Agent、音乐控制、歌词、XPC、设置迁移和登录启动功能，再创建保留上游历史的合并提交。

## 来源与许可证

原始项目：[TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)。本项目遵循仓库中的 **GNU GPL-3.0**；请同时查看 [`LICENSE`](LICENSE) 和[第三方许可](THIRD_PARTY_LICENSES.md)。每个公开 DMG 都会对应到可获取的 Git Tag 源码。
