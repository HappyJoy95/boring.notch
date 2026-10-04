<h1 align="center">
  <br>
  <a href="http://theboring.name"><img src="https://framerusercontent.com/images/RFK4vs0kn8pRMuOO58JeyoemXA.png?scale-down-to=256" alt="Boring Notch" width="150"></a>
  <br>
  Boring Notch
  <br>
</h1>

<p align="center">
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/boring-notch"><img src="https://badges.crowdin.net/boring-notch/localized.svg"></a>
  <img src="https://github.com/TheBoredTeam/boring.notch/actions/workflows/cicd.yml/badge.svg" alt="TheBoringNotch 构建与测试" style="margin-right: 10px;" />
  <a href="https://discord.gg/c8JXA7qrPm"><img src="https://dcbadge.limes.pink/api/server/https://discord.gg/c8JXA7qrPm?style=flat" alt="Discord 徽章" /></a>
  <a href="https://www.ko-fi.com/alexander5015"><img src="https://srv-cdn.himpfen.io/badges/kofi/kofi-flat.svg" alt="Ko-fi" /></a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/14815?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-14815" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/14815" alt="TheBoredTeam%2Fboring.notch | 趋势" width="250" height="55"/></a>
</p>

**Boring Notch** 让 MacBook 的灵动岛成为屏幕上的焦点。它将灵动岛变成动态音乐控制中心，提供生动的可视化效果和常用音乐控制功能。此外还支持日历、带隔空投送功能的文件暂存区、自定义 macOS HUD 等。

<p align="center"><img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="演示动画" /></p>

---

## 安装

**系统要求：**
- macOS **14 Sonoma** 或更高版本
- Apple 芯片或 Intel Mac

### 方式一：手动下载并安装

<a href="https://github.com/TheBoredTeam/boring.notch/releases/latest/download/boringNotch.dmg" target="_self"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="下载 macOS 版本" /></a>

下载后打开 `.dmg`，将 **Boring Notch** 拖入 `/Applications` 文件夹。

> [!IMPORTANT]
> 目前我们还没有 Apple 开发者账号，因此首次启动时，macOS 会提示 Boring Notch 来自身份不明的开发者。这是预期行为。首次打开前需要绕过此限制，只需操作一次。

#### 推荐方式：终端（始终有效）

这是最快捷的方式，只需运行一条命令。将 Boring Notch 移入“应用程序”文件夹后运行：

```bash
xattr -dr com.apple.quarantine "/Applications/Boring Notch.app"
```

然后正常打开应用即可。

#### 备用方式：系统设置

> [!NOTE]
> 此方式并非对所有用户都有效。如果操作失败，请使用上面的终端方式。

1. 尝试打开应用，此时会出现安全警告。
2. 点击 **好** 关闭警告。
3. 打开 **系统设置** > **隐私与安全性**。
4. 滚动到页面底部，在 Boring Notch 的提示旁点击 **仍要打开**。
5. 如出现确认提示，请确认操作。

### 方式二：通过 Homebrew 安装

也可以使用 [Homebrew](https://brew.sh) 安装。Homebrew 安装时会自动绕过上述 macOS 安全警告。

```bash
brew install --cask TheBoredTeam/boring-notch/boring-notch
```

## 使用方法

- 启动应用，灵动岛便会出现在屏幕上。
- 将指针悬停在灵动岛上，即可展开并查看功能。
- 使用控制项管理音乐播放。
- 点击菜单栏中的星形图标，可自定义灵动岛。

## 🗺️ 开发路线图

- [x] 音乐播放实时动态 🎧
- [x] 日历集成 📆
- [x] 提醒事项集成 ☑️
- [x] 镜像 📷
- [x] 充电指示和当前电量 🔋
- [x] 可自定义手势控制 👆🏻
- [x] 支持隔空投送的暂存区 📚
- [x] 灵动岛尺寸自定义，适配不同显示器 🖥️
- [x] 系统 HUD 替换（音量、亮度、键盘背光）🎚️💡⌨️
- [ ] 蓝牙实时动态（蓝牙设备连接/断开）
- [ ] 天气集成 ⛅️
- [ ] 可自定义布局 🛠️
- [ ] 锁定屏幕小组件 🔒
- [ ] 扩展系统 🧩
- [ ] 通知（正在评估）🔔

## 从源代码构建

### 前置条件

- **macOS 15.6 或更高版本**
- **Xcode 26 或更高版本**

### 步骤

1. **克隆仓库：**
   ```bash
   git clone https://github.com/TheBoredTeam/boring.notch.git
   cd boring.notch
   ```
2. **在 Xcode 中打开项目：**
   ```bash
   open boringNotch.xcodeproj
   ```
3. **构建并运行：**点击“运行”按钮，或按 `Cmd + R`。

## 🤝 参与贡献

欢迎贡献代码和建议！请阅读[贡献指南](CONTRIBUTING.md)，了解如何参与。

## 加入 Discord 社区

<a href="https://discord.gg/GvYcYpAKTu" target="_blank"><img src="https://iili.io/28m3GHv.png" alt="加入 Boring 社区！" style="height: 60px !important;width: 217px !important;" ></a>

## Star 历史

 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-dark.svg">
   <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-light.svg">
   <img src="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-light.svg" alt="TheBoredTeam/boring.notch GitHub Star 历史" />
 </picture>

## 在 Ko-fi 上支持我们

<a href="https://www.ko-fi.com/alexander5015" target="_blank"><img src="https://github.com/user-attachments/assets//a76175ef-7e93-475a-8b67-4922ba5964c2" alt="在 Ko-fi 上支持我们" style="height: 70px !important;width: 346px !important;" ></a>

## 🎉 致谢

感谢所有为本项目提供支持的开源项目作者和维护者。

### 值得关注的项目
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)**：开源项目，让 macOS 15.4 及更高版本可以使用“正在播放”媒体来源。
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)**：在开发 Boring Notch 首版“暂存区”功能时提供了重要帮助。

完整许可和致谢信息请参阅[第三方许可](./THIRD_PARTY_LICENSES.md)。

### 图标鸣谢：[ @maxtron95](https://github.com/maxtron95)
### 网站鸣谢：[ @himanshhhhuv](https://github.com/himanshhhhuv)

- **SwiftUI**：感谢它让界面开发更轻松。
- **你**：感谢你关注 **Boring Notch**！
