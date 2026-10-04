# Boring Notch 的 Codex 活动插件

这个本地 Codex 插件只会将原生 Codex 中已置顶任务的状态同步到 Boring Notch。插件通过 `useStateDbOnly: true` 读取 Codex App Server，不会恢复任务，也不会读取对话记录文件。发送到灵动岛的内容仅包括每个已置顶任务的标题、状态和最新的最终版助手回复。

## 配对与信任

1. 启动 Boring Notch，打开 **设置 → Codex**，复制桥接令牌。
2. 在已安装插件的 `hooks/hooks.json` 中，为每条 `node .../sync.mjs` 命令添加前缀 `BORING_NOTCH_TOKEN='<复制的令牌>'`。请将已安装的插件保存在此源代码仓库之外，也不要提交令牌。修改钩子会改变其信任哈希，因此请在 Codex 中重新检查并信任更新后的钩子。
3. 使用 Codex 支持的本地插件安装流程安装此插件，然后在 Codex 中检查并信任其钩子。Codex 要求完成钩子信任步骤，本插件不会绕过此要求。
4. 在 Codex 中置顶需要显示的任务。插件会在任务开始、提交提示、等待权限、任务完成和中断时同步状态。

接收服务只绑定到 `127.0.0.1:57321`，要求提供 bearer 令牌，只接受 `POST /v1/snapshot` 请求，并限制请求大小和任务字段长度。回复文本仅保留在内存中。在 Boring Notch 设置里轮换令牌，可使已复制的旧令牌失效。

如果 Codex CLI 不在 `PATH` 中，请将 `CODEX_APP_SERVER_EXECUTABLE` 设置为 Codex CLI 可执行文件的路径。钩子以异步方式运行，且始终不返回决策，因此无法发送消息、继续任务、批准或拒绝操作，也不会阻止任务。
