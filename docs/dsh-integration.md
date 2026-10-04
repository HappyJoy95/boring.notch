# DSH 接入

插件源码位于 `Integrations/DSHDesktop`，当前版本为 0.3.0。通过公开的 `sessionController.list/page/prompt/cancel` 和 `workspaceController.follow` 实现置顶会话读取、历史分页、文字发送和当前轮次打断。

桥接只绑定本机回环地址，配置写入 `~/Library/Application Support/Boring Notch/DSH/bridge-config.json`，使用随机 bearer token 和当前用户专用权限。XPC 辅助进程读取此配置，不读取 DSH 日志。发送和打断使用 POST，限制请求大小、最新置顶状态和非子代理身份；不会改变 DSH 审批和权限。发送采用 queue 模式，打断保留 pending inbox。

发送回执为 queued，停止回执为 submitted；均只表示操作被接受。超时或回执异常显示结果未确认，不自动重试。旧插件缺少控制能力时明确要求更新到 0.3.0。

在灵动岛「设置 → AI Agent → DSH 插件」点击「一键安装 / 更新」，辅助进程解压内置包并调用 DSH 自带 generation 安装器，安装、替换本插件旧版本并启用；完成后重启 DSH。旧版使用普通目录安装且 DSH 仍运行时，提示退出后重试，避免移动运行中的插件目录。安装器持有 DSH registry 锁，保留其他插件的选择，发布失败恢复原选择。没有直接自行改写 DSH profile。保留「在访达中显示安装包」作为手动入口，可在 DSH 插件管理器添加解压后的文件夹。插件包随灵动岛发布，可在其他电脑安装，不包含本机令牌或配置。

验证：`node --test Tests/DSHBridge/*.test.mjs` 覆盖发送、重复与并发请求、停止、取消置顶、子代理限制、未知回执、HTTP 鉴权和大小限制。原生端通过 Xcode 编译验证；用户安装新插件后仍需验证实际 DSH 会话的发送和打断。

一键安装验证：10 项安装与桥接测试通过；使用本机 DSH 自带 Node 和安装器，在隔离 DSH_HOME 真实安装、重复更新并检查启用及版本均成功；Debug 构建通过。正式签名应用的按钮操作仍需用户验证。

DSH Desktop 的数据目录是 ~/Library/Application Support/dsh-desktop/harness（由 Desktop 包名 dsh-desktop 决定），不要写入独立 CLI 使用的 ~/.dsh。安装器检查 profiles/web/package.json 后再执行，避免误建一个不可见的 profile。
