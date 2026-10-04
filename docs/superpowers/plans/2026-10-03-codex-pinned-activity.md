# Codex 置顶任务活动实现计划

> **供智能体执行：** 按任务顺序逐项执行本计划。Codex 集成必须保持只读，不得绕过 Codex 对钩子信任的审核。

**目标：** 仅将 Codex 原生“置顶”任务、任务生命周期状态及最新助手回复同步到 Boring Notch。

**架构：** Codex 插件伴随进程通过 App Server 读取置顶会话分区和最新回合，官方生命周期钩子负责报告运行状态。伴随进程通过经过身份验证的本机回环连接，向 Boring Notch 接收端发送有大小限制的快照；接收端不提供任何写回方法。

**技术栈：** Node.js 内置模块、Codex App Server JSONL、Codex 插件清单和钩子、Swift/Network.framework、SwiftUI。

---

## 文件

- Create `Integrations/CodexActivity/.codex-plugin/plugin.json` and `.mcp.json` for the local Codex plugin package.
- Create `Integrations/CodexActivity/hooks/hooks.json` and `hooks/codex-lifecycle.mjs` for status-only lifecycle events.
- Create `Integrations/CodexActivity/mcp/server.mjs` for the read-only App Server client and snapshot relay.
- Create `Integrations/CodexActivity/mcp/protocol.mjs` for pin filtering, latest assistant reply extraction, and hook status normalization.
- Create `Integrations/CodexActivity/test/protocol.test.mjs` for built-in Node tests.
- Create `boringNotch/services/CodexActivityReceiver.swift` for loopback listener, bounded JSON decoding, pairing, and state publication.
- Create `boringNotch/models/CodexActivityModels.swift` for Codable task snapshots and lifecycle states.
- Modify `boringNotch.xcodeproj/project.pbxproj` only if the synchronized source groups do not include new files automatically.
- Modify `boringNotch/boringNotchApp.swift` to start and stop the receiver with app lifecycle.
- Modify `boringNotch/components/Settings/SettingsView.swift` to expose connect/disconnect and pairing state.

## 任务

### 任务 1：定义并测试 Codex 快照协议

- [ ] 添加固定样例测试，覆盖原生 `section.name == "Pinned"`、忽略未置顶会话以及忽略已归档会话。
- [ ] 添加固定样例测试：只选取最新回合中的 `agentMessage.text`，并丢弃 `userMessage`、`commandExecution`、`reasoning` 和非最终进度消息。
- [ ] 添加固定样例测试，将 `UserPromptSubmit`、`PermissionRequest`、`Stop`、`Interrupt` 和 `SessionEnd` 映射为仅用于显示的状态。
- [ ] 运行 `node --test Integrations/CodexActivity/test/protocol.test.mjs`，确认缺少函数时会触发预期断言失败。
- [ ] 在 `protocol.mjs` 中实现 `filterPinnedThreads`、`latestAssistantReply` 和 `statusFromHook`。
- [ ] 重新运行对应的 Node 测试文件，并确认所有断言通过。

### 任务 2：实现只读 App Server 伴随进程

- [ ] 为 JSONL 的 initialize/initialized、带 `useStateDbOnly: true` 的 `thread/list`，以及带 `limit: 1` 的 `thread/turns/list` 编写集成固定样例。
- [ ] 使用同时包含置顶和未置顶任务的样例进行测试；快照中只能出现 `Pinned` 分区的任务。
- [ ] 测试同时包含用户消息、工具、推理、进度和最终答案的助手回合；序列化内容中只能保留助手最终文本。
- [ ] 在 `mcp/server.mjs` 中实现 JSONL 请求客户端；按显式环境变量、`PATH`、已安装的 Codex 应用包这一顺序查找 Codex 可执行文件。
- [ ] 每 5 秒轮询一次置顶元数据；每个置顶任务只获取最新一个回合；快照最多包含 64 个任务，每条显示的回复最多 4,000 个 Unicode 字符。
- [ ] 不得使用 `thread/resume`、`turn/start`、`turn/steer`、审批方法、对话记录文件或数据库文件。
- [ ] 运行 `node --test Integrations/CodexActivity/test/protocol.test.mjs` 和本机模拟 App Server 进程测试；确认断开连接时伴随进程能正常退出。

### 任务 3：添加仅报告状态的插件钩子

- [ ] 为包含 `session_id` 和 `hook_event_name` 的钩子负载添加固定样例测试，并覆盖 ID 缺失和 JSON 格式错误的情况。
- [ ] 实现 `hooks/codex-lifecycle.mjs`，只向伴随进程发送会话 ID、事件名称和标准化状态；绝不转发提示词、对话记录路径、工具输入/输出或原始钩子 JSON。
- [ ] 在 `hooks/hooks.json` 中配置 `UserPromptSubmit`、`PermissionRequest`、`Stop`、`Interrupt`、`SessionStart` 和 `SessionEnd`，使用较短超时，且不作任何阻塞性决策。
- [ ] 确认伴随进程不可用时，所有命令都会安全地直接结束，并且绝不返回审批决定。
- [ ] 运行钩子固定样例测试，并检查序列化输出，确认其中不包含原始文本字段。

### 任务 4：实现经过身份验证的回环接收端

- [ ] 为接收端编写测试，覆盖有效配对、拒绝无效令牌、负载大小限制、格式错误的 JSON、未知任务状态和断开后的清理。
- [ ] 使用 `NWListener` 实现 `CodexActivityReceiver`，且只绑定 IPv4 回环地址；生成随机的一次性配对码，以恒定时间比较，并在配对后轮换配对码。
- [ ] 只接受 `POST /v1/snapshot` 和 `POST /v1/status`；不提供包含任务数据的 GET 端点，也不提供 Codex 命令端点。
- [ ] 验证每个 JSON 字段的长度和任务数量；当前快照只保存在内存中，并立即清除已移除或取消置顶的任务。
- [ ] 将接收端生命周期接入 `AppDelegate`，并在设置中显示连接/断开状态。
- [ ] 使用 Swift 6.2 运行接收端单元测试，并确认未授权及格式错误的负载会被拒绝。

### 任务 5：验证 Codex 桌面端的实际行为

- [ ] 通过 Codex 支持的插件流程安装本地插件，并按正常流程完成信任审核；绝不直接写入 `~/.codex` 来绕过用户审核。
- [ ] 在 Codex 中置顶一个测试任务，确认快照中只出现该任务；取消置顶后确认该任务立即移除。
- [ ] 运行一个简短任务并确认状态会变化；中断另一个任务后确认它不再显示为运行中。
- [ ] 确认最新显示的回复不包含提示词、推理、命令、工具输出或之前的回合。
- [ ] 确认关闭 Boring Notch 或断开桥接服务不会阻塞 Codex 任务。
- [ ] 确认点击后能通过受支持的深链打开对应 Codex 任务；若无深链，则打开 Codex 主窗口。

## 实现进度（2026-10-03）

- [x] 已添加协议筛选：识别原生 `Pinned` 分区、排除已归档任务、只提取最终答案，并映射钩子状态。
- [x] 已添加受信任钩子插件包；它通过 App Server 读取数据，不会恢复会话或打开对话记录文件。
- [x] 已在 Boring Notch 中添加仅限回环连接、受令牌保护的快照接收端和内存任务存储。
- [x] 已在设置中添加查看、复制和轮换桥接令牌的控件，并显示最近一次成功同步时间。
- [ ] 通过 Codex 界面安装并信任本地插件，在钩子命令中配置已复制的令牌，并确认真实的置顶任务同步。此集成步骤仍需用户审核；没有自动修改 Codex 配置。
- [ ] 取得插件信任后，根据当前主机验证 Codex App Server 的响应结构。
