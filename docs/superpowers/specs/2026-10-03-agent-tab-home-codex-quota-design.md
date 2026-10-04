# Agent 标签页与 Home Codex 额度设计

日期：2026-10-03
状态：用户已确认
工作树：`/Users/ashui/vibe-coding/boring.notch.git`，分支 `codex/notch-three-level-activities`

## 1. 目标

为 Boring Notch 增加 Agent 标签页，专门查看 Codex 置顶任务；在 Home 放置紧凑的 Codex 额度卡，并在用户切到 Home 时刷新。

## 2. 已确认需求

- 顶部导航增加 `Agent`，与 Home、Shelf 并列。
- Codex 置顶任务从 Home 移到 Agent；Agent 出现时直接从 Codex App Server 只读读取已置顶任务，显示标题、状态、最新最终回复，可滚动；没有置顶任务时显示空状态。
- Home 保持原窗口宽度，播放器收窄靠左，紧凑额度卡靠右；用两个圆环显示 5 小时额度和 7 天额度，环下仅显示重置日期和时间。
- 圆环显示剩余百分比，下方只显示下次重置日期和时间。
- 每次显示/切换到 Home 时读取一次额度，不使用后台轮询。并发 Home 激活合并为一个请求。
- 读取失败时保留本次应用运行期间最近一次成功数据并显示更新时间；本次运行尚无成功值时显示暂不可用。
- Codex 短暂状态事件继续按原设计出现在主刘海；Agent 页中的任务卡不增加发送消息、批准、拒绝等写操作。

## 3. 数据来源与处理

- 使用 Codex 桌面 CLI App Server 的 `account/rateLimits/read` 查询额度，并用 `thread/list` 与 `thread/turns/list` 查询置顶任务。
- 只选 `limitId == "codex"` 的 `primary` 与 `secondary` 窗口；本机当前分别为 300 分钟与 10080 分钟窗口。
- 从 API 的 `usedPercent` 计算显示值 `100 - usedPercent`，并将 `resetsAt` 转换为本地重置时间/倒计时。
- 只解析并保留两个窗口的使用百分比、窗口长度、重置时间和本机读取时间；忽略 account ID、credits、其他限额和 API 原始 JSON。
- 通过现有未沙盒化 XPC helper 启动本机 Codex CLI 的 `app-server`，主应用只接收 `codex` 配额窗口数据，或置顶任务必要显示字段。使用 JSON Lines 初始化后请求一次 rate limits，再终止子进程。查找顺序使用已知 ChatGPT.app 内置 CLI 路径、用户 Applications 下的内置 CLI、最后回退 PATH 上的 `codex`。
- 请求异步运行并有超时；CLI 不存在、登录态不可用、接口报错或响应结构异常时不阻塞 UI。

## 4. UI 与状态

- `NotchViews` 增加 Agent case；TabSelectionView 增加 Sparkles 图标标签。
- `ContentView` 根据选中标签分别渲染 Home、Shelf、Agent。
- Home 保持原窗口宽度，左侧显示收窄后的播放器/可选日历相机，右侧显示紧凑双圆环额度卡；移除现有置顶任务列表。
- Agent 直接读取 Codex 原生置顶任务，并复用现有置顶任务卡片与状态/回复格式。
- 按当前标签与内容更新展开刘海高度，Home 的额度条和 Agent 的任务列表都不能被窗口裁切；Agent 任务过多时在内容区滚动。
- 用量读取中展示轻量加载状态；已有成功值时失败后继续展示旧值并标记其更新时间；首次失败时显示不可用提示。

## 5. 隐私与边界

- 额度和置顶任务查询只在本机 XPC helper 调用 Codex CLI App Server；Boring Notch 不解析或保存 Codex 凭据，不将数据发到网络或任务桥接服务。helper 只回传 `codex` 配额窗口或置顶任务的必要显示字段。
- 不持久化额度缓存，避免在设备上留下账户使用数据。
- 读取/解析路径不记录原始响应、账号标识、credit 信息或任务回复。
- 不修改 Codex MCP 插件或 Pinland；现有只读置顶任务 hook/本机桥接协议保持原样。

## 6. 验收标准

- 顶部显示 Home、Shelf、Agent 三个标签；Agent 只列 Codex 原生置顶任务。
- Agent 的任务标题、状态和最新最终回复正确显示，空列表与长列表状态可用。
- Home 保持原宽度，播放器靠左，两个额度圆环靠右；环下只显示重置日期和时间。
- 每次进入 Home 触发一次刷新；请求过程中 UI 仍可操作，并发进入只产生一个查询。
- 读取失败时能正确保留本次进程内缓存或显示无缓存错误状态。
- 错误/缺省/异常字段不会造成崩溃、越界百分比或错误时长；时间按本机时区显示。
- 选择标签和任务数变化时展开窗口高度匹配内容，不裁切额度/任务列表。
- 原有 Codex 状态短暂弹出和音乐焦点活动不受影响。

## 7. 本期不做

- 永久在线轮询、后台定时刷新、额度提醒和用量历史图表。
- 将 Codex 额度发送给其他 App、网络服务或 Pinland。
- 显示 Codex 账户 ID、credits、模型额度细目或非 Codex 限额。
- 调整现有 Hook 信任、安装或 Pinland 设置。
