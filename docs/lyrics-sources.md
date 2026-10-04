# QQ 音乐与网易云歌词

根据系统播放信息中的应用标识自动选源：QQ 音乐优先 QQ 歌词，网易云优先网易云歌词，其他播放器保持通用歌词源。平台未找到匹配歌曲或接口失败时回退 LRCLIB。

这是按播放器提供的歌曲信息从平台重新获取歌词，不是读取播放器窗口中的当前歌词。采用匿名请求，不读取播放器账号、Cookie 或本地数据库。

匹配时核对歌名、歌手，已知双方时长差超过 3 秒则排除；专辑一致的候选优先。保留 Live 等版本标识，避免用现场版代替录音室版。成功结果保留最多 128 条内存缓存。换歌或切换来源时取消旧任务，并通过请求标识拦截旧结果。

LRC 支持 1 至 3 位小数、重复时间标签、offset 和空白间奏。第一句时间之前不提前显示歌词。折叠歌词区区分加载中、无歌词与无逐句歌词，不把整首纯文本塞成一行。

## 验证

在项目目录执行：

```sh
swiftc -parse-as-library boringNotch/services/LyricsService.swift Tests/Lyrics/main.swift -o /tmp/boring-lyrics-tests
/tmp/boring-lyrics-tests
```

添加 `--live` 可进行两个平台的匿名联网验证。正常离线测试涵盖选源、歌曲版本、歌手别名、时间解析、接口异常回退、缓存和已取消任务。

2026-10-04 验证：QQ《晴天》、网易云《起风了》均返回平台同步歌词，Debug 构建通过。播放器 UI 中切歌、暂停、跳转进度仍需运行新版验证。

## 接口依据与限制

- [QQ 接口实现参考](https://github.com/Yyyangshenghao/simple-music/blob/master/server/lib/qq-client.ts)
- [网易云搜索与歌词接口参考](https://github.com/u3u/NeteaseCloudMusicApi)
- [LRCLIB 文档](https://lrclib.net/docs)

平台接口并非承诺兼容的桌面歌词接口，后续改版可能失效。歌曲信息缺失或版本不一致时宁可显示无歌词，不强行采用搜索第一条。逐字高亮和翻译歌词暂未实现。
