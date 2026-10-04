# Agent 标签页与主页 Codex 配额实现计划

> **供智能体执行：** 必须使用子技能 `superpowers:executing-plans`，按任务逐项执行本计划。步骤使用复选框（`- [ ]`）跟踪进度。

**目标：** 增加 Agent 标签页以显示已置顶的 Codex 任务，并在主页加入紧凑、按需加载的 Codex 配额栏。

**架构：** 添加只读额度与置顶任务服务，在 Home 或 Agent 出现时通过现有未沙盒化 XPC helper 查询本地 Codex CLI App Server。Home 只读取 `account/rateLimits/read` 的 `codex` 5 小时和 7 天窗口；Agent 只读取原生置顶任务及最新最终回复。将现有置顶任务列表移入专属 Agent 页面，保留现有状态弹出面板行为，并根据当前页面计算灵动岛高度，避免内容被裁切。

**技术栈：** Swift 6、SwiftUI、Foundation `Process`/`Pipe`、Codex App Server JSON Lines RPC、XPC、Xcode 项目文件。

---

## 文件与职责

- Create `boringNotch/models/CodexQuota.swift`: immutable quota-window and snapshot values plus safe decoding of `account/rateLimits/read` fields.
- Create `boringNotch/services/CodexQuotaService.swift`: shared observable state, XPC quota request, cached-value fallback.
- Create `BoringNotchXPCHelper/CodexQuotaReader.swift`: bounded JSON-RPC subprocess request and allowlisted quota response fields.
- Create `boringNotch/services/CodexPinnedTasksService.swift` and `BoringNotchXPCHelper/CodexPinnedTasksReader.swift`: read native pinned tasks and latest final replies through XPC.
- Modify both XPC protocol declarations, `BoringNotchXPCHelper/BoringNotchXPCHelper.swift`, and `boringNotch/XPCHelperClient/XPCHelperClient.swift` to route the read-only quota request through the existing unsandboxed helper.
- Create `boringNotch/components/Notch/CodexQuotaStrip.swift`: compact Home quota display and loading/unavailable states.
- Create `boringNotch/components/Notch/AgentTasksView.swift`: Agent page for pinned tasks and empty state.
- Modify `boringNotch/components/Notch/NotchHomeView.swift`: place the narrowed player on the left and quota strip on the right; move optional calendar/camera below the player; remove the pinned task list from Home; refresh quota on appearance.
- Modify `boringNotch/components/Notch/NotchHomeView.swift`: extract the existing pinned task card view from `private` visibility so the Agent page can reuse it without changing task rendering semantics.
- Modify `boringNotch/enums/generic.swift`: add `.agent` to `NotchViews`.
- Modify `boringNotch/components/Tabs/TabSelectionView.swift`: add the Agent tab and sparkles icon.
- Modify `boringNotch/ContentView.swift`: render `AgentTasksView` for `.agent` and update expanded height as the selected tab and task count change.
- Modify `boringNotch/models/BoringViewModel.swift` and `boringNotch/sizing/matters.swift`: keep startup/open sizing consistent with the selected tab and content.
- Modify `boringNotch.xcodeproj/project.pbxproj`: register the new Swift source files in the app target.
- Add Chinese Simplified translations for the new Agent and quota labels in `boringNotch/Localizable.xcstrings`.

## 任务 1：添加有界的只读配额查询

### 步骤 1：定义配额数据并安全解码响应

创建包含 `remainingPercent`、`windowDurationMins` 和 `resetsAt` 的 `CodexQuotaWindow`，并将显示百分比限制在 `0...100`。创建包含 `primary`、`secondary` 和 `fetchedAt` 的 `CodexQuotaSnapshot`。只解析 `codex` 条目中的 `primary.usedPercent`、`secondary.usedPercent`、窗口时长和重置时间戳。忽略响应中的其他字段。

解码器必须拒绝缺失或负数的窗口时长、缺失的重置时间戳、格式错误的 JSON-RPC 响应，以及不含 `codex` 配额项的响应。将有效的 `usedPercent` 转换为 `100 - usedPercent`，并将 `resetsAt` 从 Unix 秒转换为 `Date`。

### 步骤 2：通过未沙盒化 XPC helper 查询 Codex App Server

创建 `CodexQuotaService.shared`，使其成为 `@MainActor ObservableObject`，并发布 `snapshot`、`isRefreshing`、`lastError` 和 `lastUpdatedAt` 状态。`refresh()` 必须合并重叠调用，通过 XPC helper 发起请求，并在主线程上更新已发布属性。不要在启用 App Sandbox 的主应用进程里启动 CLI。

按以下顺序查找可执行文件：`/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`、`~/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`，最后从 PATH 查找 `codex`。启动 `app-server`，并分别为 stdin、stdout 和 stderr 创建管道。发送带请求 ID 的 JSON Lines `initialize` 请求，等待匹配的响应后发送 `initialized` 通知，再使用请求 ID 2、方法 `account/rateLimits/read` 和空参数发送请求。忽略无关通知和响应。设置 5 秒截止时间；如果超时、响应格式错误、进程启动失败或 RPC 未成功，则终止子进程并抛出对应类型的错误。不要记录 stdout、stderr、原始负载或标识符。

刷新失败时，保留最近一次成功的内存快照，并设置错误状态以提示数据已过期。如果没有快照，则发布不可用状态。绝不读取、存储或返回 Codex 凭据、账户 ID、额度或其他限制信息。

### 步骤 3：在 Xcode 应用目标中注册模型和服务

在 `boringNotch.xcodeproj/project.pbxproj` 中为每个新文件添加文件引用和构建文件条目。将文件放入对应的 models/services 分组以及主应用 Sources 阶段。

## 任务 2：将置顶任务移至 Agent，并添加主页配额界面

### 步骤 1：添加 Agent 导航页面

在 `NotchViews` 中添加 `.agent`，添加 `TabModel(label: "Agent", icon: "sparkles", view: .agent)`，并在 `ContentView` 中添加 `.agent` 分支以显示 `AgentTasksView`。

创建 `AgentTasksView`，显示标题、任务数量和现有置顶任务行。沿用当前行样式及打开 Codex 的行为。保留现有滚动逻辑，并将最终回复截断为两行。没有置顶任务时，显示紧凑空状态，说明置顶 Codex 任务后会在此处显示。

### 步骤 2：在主页放置配额栏并移除任务列表

创建 `CodexQuotaStrip`，使用一个深色圆角面板并排显示两个等宽区域。每个区域显示 `5 hr` 或 `7 day`、剩余百分比、进度条和重置倒计时。成功获取快照后显示较小的更新时间。首次查询时显示简洁的加载提示；刷新失败后保留上次的数据并标明已过期；没有缓存值时显示不可用状态。不要添加定时轮询。

在 `NotchHomeView.mainContent` 中，将圆环配额栏放在播放器右侧并收窄播放器区域；可选日历/相机排在播放器下方。配额视图出现时启动一个 task，调用 `CodexQuotaService.shared.refresh()`；Agent 页面出现时调用 `CodexPinnedTasksService.shared.refresh()`。从 `mainContent` 移除置顶任务分区，并移动或开放现有置顶任务列表视图供 Agent 页面复用。不要改动 `CodexStatusActivityView` 或紧凑模式下的 Codex 事件仲裁。

## 任务 3：按所选页面调整展开后的灵动岛尺寸并完成集成

### 步骤 1：更新页面高度计算

在 `sizing/matters.swift` 中添加主页配额视图对应的高度。Agent 页面继续使用现有任务页高度。在 `ContentView` 中，当 `currentView` 或置顶任务数量变化时更新展开高度。在 `BoringViewModel.open()` 中，默认选择主页配额视图高度；仅当选中 Agent 时使用 Agent 页面高度，并保留暂存区现有行为。所有高度不得超过现有 `windowSize` 上限，Agent 页面中的任务行应在内容区域内滚动。

### 步骤 2：构建应用并检查界面

运行以下命令：

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -destination 'platform=macOS' -derivedDataPath /Users/ashui/Library/Developer/Xcode/DerivedData/boringNotch-epdvsyuiuccrpqbbgkpkbaurioov build
```

预期结果为 `** BUILD SUCCEEDED **`。启动构建后的应用，确认主页显示紧凑配额栏，Agent 页面只显示置顶任务；选择主页时会刷新配额且灵动岛不会卡顿，切换页面不会裁切内容。还需确认现有音乐活动和 Codex 临时活动仍正常显示。

## 实现边界

- 不要修改 `Localizable.xcstrings`，以免与用户并行进行的本地化工作冲突。
- 不要修改 Codex 插件市场/令牌相关文案，也不要修改任何 Pinland 文件。
- 不要持久化配额值；缓存回退只在当前 Boring Notch 进程运行期间有效。
- 不要提交与本任务无关的工作区改动。
