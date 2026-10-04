# 灵动岛三级活动层级实现计划

> **供智能体执行：** 在 Codex 和 QQ 数据快照接口稳定后执行。灵动岛收起状态下的 Codex 卡片必须保持只读。

**目标：** 将持续焦点活动、临时 Codex 状态事件和置顶 Codex 任务预览整合到 Boring Notch 灵动岛及其展开菜单中。

**架构：** 由纯活动仲裁器决定灵动岛收起时显示的焦点卡片；Codex 事件会临时覆盖该卡片，并在安静 5 秒后结束。展开菜单单独列出置顶任务和最新回复，因此列表内容不会与收起状态下的焦点卡片争用位置。

**技术栈：** Swift 6、Foundation、SwiftUI，以及现有的 `MusicManager`、`BoringViewCoordinator` 和 `ContentView`。

---

## 文件

- Create `boringNotch/models/ActivityArbiter.swift` for priority and expiry rules.
- Create `boringNotch/components/Notch/CodexPinnedTasksView.swift` for read-only pinned task cards.
- Modify `boringNotch/ContentView.swift` to route the closed-notch transient Codex card ahead of persistent music when active.
- Modify `boringNotch/components/Notch/NotchHomeView.swift` to include the Codex pinned-task list in the expanded home content.
- Add `Tests/ActivityArbiter/main.swift` as a Foundation-only assertion harness compiled by `swiftc`.
- Modify `boringNotch.xcodeproj/project.pbxproj` only if filesystem-synchronized groups do not discover the new Swift files.

## 任务

### 任务 1：定义纯仲裁模型

- [ ] 添加失败断言，覆盖音乐作为焦点、Codex 临时覆盖、5 秒后过期、第二个事件重置过期计时，以及取消置顶后不再显示 Codex 覆盖。
- [ ] 运行 `swiftc boringNotch/models/ActivityArbiter.swift Tests/ActivityArbiter/main.swift -o /tmp/activity-arbiter-tests`，确认每项尚未实现的行为都会导致断言失败。
- [ ] 实现只依赖 Foundation 的 `ActivityArbiter`，接收最新焦点状态、置顶任务状态事件和注入的 `Date`；不读取全局状态，只返回 `.codexStatus` 或 `.focus`。
- [ ] 重新运行相同命令，并确认所有断言通过。

### 任务 2：接入灵动岛收起状态下的优先级

- [ ] 添加一个失败用例：Codex 覆盖显示期间 QQ 音乐切换曲目；断言覆盖结束后恢复显示新曲目，而非先前的快照。
- [ ] 更新 `ContentView.NotchLayout()`：只有仲裁器选中 Codex 状态时才显示 Codex 卡片；保留 `MusicLiveActivity()` 作为焦点活动视图。
- [ ] 添加 SwiftUI Codex 状态卡片，显示标题和简短状态，并可点击打开 Codex；不要加入编辑框、发送、批准、拒绝或继续等控件。
- [ ] 重新运行纯仲裁测试，并检查视图分支顺序，确认音乐活动能作为回退展示。

### 任务 3：在展开菜单中添加只读 Codex 内容

- [ ] 添加包含两个置顶任务和一个未置顶任务的模型样例；断言展开列表只接收置顶任务。
- [ ] 添加包含较长最新回复的样例；断言任务行显示有长度限制的预览，展开菜单中显示可滚动的只读文本。
- [ ] 构建 `CodexPinnedTasksView`，显示标题、状态、最新回复，并提供 `Open in Codex` 点击入口；所有文本由 SwiftUI 转义，且不添加操作按钮。
- [ ] 将此视图放入现有展开的 `NotchHomeView` 内容中，不改变现有音乐控件或日历的显示逻辑。
- [ ] 重新运行活动测试，并检查视图树，确认没有 Codex 写操作。

### 任务 4：验证三级活动行为

- [ ] 在 QQ 音乐播放曲目时触发 Codex 状态事件，确认它会临时替换收起状态卡片，并在 5 秒后恢复显示当前歌曲。
- [ ] 展开灵动岛，确认即使当前没有状态提示，置顶任务回复仍保持可见。
- [ ] 取消任务置顶，确认对应行消失且回复从内存中清除。
- [ ] 断开 Codex，确认音乐和 Boring Notch 现有功能仍可使用。
- [ ] 使用 Xcode 构建完整应用，并在用户的 Mac 上检查界面；如果无法使用 Xcode，应说明完整应用尚未完成编译验证，并提供准确的手动构建命令。

## 实现进度（2026-10-03）

- [x] 已添加 5 秒活动仲裁机制，并将临时状态事件限定为置顶任务。
- [x] 已在灵动岛收起视图中添加只读 Codex 活动卡片，并在展开主页中添加最新回复卡片。
- [x] 仅在灵动岛展开且存在 Codex 置顶任务时增加高度；没有置顶任务时保持原有高度。
- [ ] 实际界面间距、灵动岛动画、各任务深链和播放优先级仍需通过 Xcode 构建，并在 Mac 上手动验证。
