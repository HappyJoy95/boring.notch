# QQ 音乐正在播放功能实现计划

> **供智能体执行：** Codex 快照协议稳定后，按本计划逐项执行。不得访问 QQ 音乐账户文件或凭据。

**目标：** 尽可能复用现有 macOS“正在播放”数据通路，在 Boring Notch 的常驻焦点活动中显示 macOS 版 QQ 音乐。

**架构：** 首选现有的 `NowPlayingController`。只有实际播放验证表明 QQ 音乐未提供所需元数据或全局媒体命令时，才添加 QQ 专用适配器。

**技术栈：** Swift、AppKit、Combine、MediaRemote，以及 Boring Notch 现有音乐界面。

---

## 文件

- Review `boringNotch/MediaControllers/NowPlayingController.swift` and `boringNotch/managers/MusicManager.swift` before changes.
- Only if live QQ playback fails through Now Playing, create `boringNotch/MediaControllers/QQMusicController.swift` and add it to the Xcode project’s synchronized source group.
- Only if the source selection needs a visible option, modify `boringNotch/components/Onboarding/MusicControllerSelectionView.swift` and its localized strings.
- Add a focused Swift harness under `Tests/QQMusicNowPlaying/` for metadata selection and controller routing.

## 任务

### 任务 1：确认现有数据源行为

- [ ] 检查 `NowPlayingController.processJSONStream()`，确认它会保留当前的 `bundleIdentifier`、标题、歌手、封面、时长、已播放时间和播放速率。
- [ ] 确认 `MusicManager.updateFromPlaybackState(_:)` 接受任意当前 bundle ID，不会将更新来源限制为 Apple Music 或 Spotify。
- [ ] 在本地验证记录中记下已安装 QQ 音乐的 bundle ID（`com.tencent.QQMusicMac`）和版本（`11.10.0`）；不要自动启动应用。
- [ ] 除非下一项任务证实存在缺失能力，否则不要创建 QQ 专用控制器。

### 任务 2：使用实际播放曲目验证 QQ 音乐

- [ ] 请用户在 Boring Notch 运行时用 QQ 音乐播放一首曲目；根据应用显示的歌曲、歌手、封面、时长、进度和 `bundleIdentifier` 验证现有适配器。
- [ ] 如果元数据正常，分别验证暂停/播放、下一首、上一首和跳转；不支持的控制项应标记为不可用，不要尝试猜测命令。
- [ ] 如果用户尚未开始播放曲目，请将此步骤保持为待处理状态，不要检查 QQ 音乐私有数据。
- [ ] 记录具体缺少哪些公开的系统媒体字段；不能根据已暂停或空闲的播放器推断功能失效。

### 任务 3：仅针对已确认的缺失能力添加最小适配器

- [ ] 修改生产代码前，为每个实际观察到缺失的字段或命令添加一个固定样例测试。
- [ ] 运行对应的 Swift 测试，并确认缺失行为会导致测试失败。
- [ ] 只实现已证实缺失的 QQ 专用 MediaRemote 通知或命令映射；不得抓取数据库、缓存、Cookie 或账户令牌。
- [ ] 重新运行测试，确认新增行为通过。
- [ ] 如果 QQ 没有提供可用的系统元数据或命令，请保留现有空状态/不支持界面并记录限制，不要通过读取私有数据绕过。

## 实现进度（2026-10-03）

- [x] 已通过静态检查确认：通用“正在播放”控制器会传递当前 bundle identifier 和元数据，`MusicManager` 接收播放状态时也没有 QQ 专用的允许列表。
- [ ] 未启动 QQ 音乐，也未播放曲目，因此真实元数据、封面、进度和控制能力均未验证。由于没有证据表明存在能力缺失，未添加 QQ 专用代码。
