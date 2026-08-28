# NOTICE — leko-plus 融合版

## 项目归属

leko-plus 由两个独立开源项目融合而成：

1. **Leko Reader**（基座，v0.15.49，AGPL-3.0-or-later）
   - 提供书架、搜索、目录、自绘阅读器、缓存与导出等全部主体功能。
   - 完整许可证文本见 `leko.koplugin/LICENSE`。

2. **fanqie.koplugin**（番茄小说插件，MIT License）
   - 以下能力以其源码为移植来源（保留溯源注释 `-- 移植自 fanqie/<file>.lua:<行号>`）：
     - 番茄扫码登录流程（`fanqie/qrlogin.lua`）
     - Set-Cookie 合并与 Cookie 头序列化（`fanqie/cookie.lua`）
     - 滑动窗口限流与跨子进程时间戳合并（`fanqie/sources.lua`）
     - 番茄官方 API 书架/目录/正文/进度接口（`fanqie/client.lua`、`fanqie/fanqie.lua`）
     - 正文清洗、PUA 私用区解码表（`fanqie/content.lua`）
     - config.lua 通道合并语义（`fanqie/settings.lua`）
   - MIT 许可证要求保留版权声明；fanqie.koplugin 原始仓库的 LICENSE 适用于上述移植片段。

## 合规口径（与 README「使用与版权声明」一致并扩展）

- 本项目**不提供、不分发任何书源与内容**。番茄功能仅通过官方公开接口访问**用户自己账号**的数据。
- 聚合源（晴天/大灰狼）服务器地址**只能来自用户自己的 `config.lua`**，插件不内置、不预填、不推荐任何第三方聚合服务。
- 首次开启番茄功能前，用户必须在应用内确认免责声明（`FanqieCompliance` 门禁，未确认时番茄网络请求在代码路径上不可达）。
- 登录凭证仅保存在本机 `koreader/data/leko/providers/fanqie/` 目录，不会上传至任何第三方服务器。
