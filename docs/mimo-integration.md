# MiMo Desktop

在「设置 → AI Agent → 来源」中启用 MiMo Desktop，然后在 Xiaomi MiMo 中置顶会话。灵动岛按设置中的会话刷新间隔读取置顶列表，支持最近回复和「加载更早消息」，共用会话字号设置。置顶和历史读取无需插件；发送、打断和实时状态需要安装下述接入组件。其他 Mac 可在设置中安装内置组件。

在「MiMo 接入组件」中点击「安装 / 更新接入组件」，然后重启 MiMo 并点击「检查连接」。连接后可从会话窗口发送消息和打断当前会话，运行状态从 MiMo 的实时状态与事件同步。正在运行或等待确认时先打断，再发送下一条消息；权限和问题仍在 MiMo 内处理。

发送只表示引擎接收了消息。发送结果未确认时，窗口会暂停下一次发送，重启灵动岛后仍保留保护；先在 MiMo 中核对，再点击「已在 MiMo 核对，允许发送下一条」。组件未连接时仍可读取本地会话，状态显示待命，不推断执行完成。精确跳转暂未开放。

## 数据范围

- 默认读取 `~/Library/Application Support/Xiaomi MiMo/Local Storage/leveldb` 中 `app://-` 的 `mimo.pinned` 键。
- 会话数据库为 `~/.local/share/mimocode/mimocode.db`；如果运行环境设置了绝对路径 `XDG_DATA_HOME`，遵循该路径。
- 仅查询置顶的根会话，排除已归档会话和子会话。每次最多 32 个置顶会话，历史每页最多 32 条，只展示主会话用户与助手的正文。
- 不读取账户令牌、工具输出或推理正文。插件只使用宿主 SDK，发送、打断经引擎接口执行，不直接写会话数据库，也不修改 MiMo 安装包。桥接只监听本机回环地址，配对令牌由灵动岛单独生成并保存在仅当前用户可读的文件中。

存储读取使用当前 MANIFEST 和日志序号，支持压缩、删除记录与校验，避免读出已取消置顶的旧值。格式变化或读取失败时，由现有服务保留上次成功列表；确认无置顶会话后清空该来源。

格式实现参考 [LevelDB 表格式](https://github.com/google/leveldb/blob/main/doc/table_format.md) 与 [日志格式](https://github.com/google/leveldb/blob/main/doc/log_format.md)。未来 Xiaomi MiMo 更新存储方式时可能需要调整适配器。

## 验证

`bash Tests/MiMo/run.sh` 使用合成的 LevelDB 与 SQLite 数据，覆盖置顶更新与删除、压缩、日志分片、校验失败、分页、重复时间戳及正文隔离。`bash Tests/AgentProviders/run.sh` 覆盖来源 ID、开关、刷新与历史隔离。

本机真实存储读取成功，当前置顶数量为 0。另用临时置顶记录对真实数据库验证，成功读取 1 个会话和 19 条历史消息，未改变 MiMo 的实际置顶列表。Debug 编译和打包接口检查通过；实际置顶会话在灵动岛中的显示仍需重新编译运行、置顶后确认。

## 组件文件与验证

内置组件版本为 0.1.0。安装位置是 `~/.mimocode/plugins/boring-notch.js` 和 `~/.mimocode/boring-notch-bridge/`。安装不会替换其他插件文件，更新保留本地配对信息；每次首次安装或更新后重启 MiMo。CLI 加载同一全局插件时只返回空钩子，避免占用桌面版连接。

实现依据已安装 MiMo Desktop 26.929.292248 的宿主插件加载器、SDK、prompt_async、abort 和状态/权限事件；接口可能随 MiMo 更新而变化。公开实现可参考 [MiMo Code 插件源码](https://github.com/XiaomiMiMo/MiMo-Code/blob/main/packages/opencode/src/plugin/index.ts)。

`bash Tests/MiMoBridge/run.sh` 验证范围与目录、请求去重、结果未知保护、忙碌状态、等待确认、停止后状态核对、跨运行状态重置、HTTP 请求校验和安装文件保留。测试使用模拟宿主客户端，不代表实际 MiMo 已成功发送或打断；首次安装后的真实连接和会话操作需重启 MiMo 后验证。

本机组件 0.1.0 已安装，当前检查为未连接，需重启 MiMo。内置资源与安装文件一致，Debug 构建通过；真实发送和打断尚未实机验证。
