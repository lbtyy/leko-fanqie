# 更新日志

## 0.15.49-plus

> 在 Leko Reader 0.15.49 基座上融合 fanqie.koplugin（MIT）的番茄能力。
> 所有番茄/聚合源域名访问都仅在用户确认免责声明之后才会发起；
> 未确认前 ProviderRegistry:get() 对 fanqie:* 一律返回 nil，
> 番茄域名请求在代码路径上不可达。

### 阶段① Provider 基础设施 + 官方源最小闭环 + 合规（T01-T04）
- 版本号升级到 0.15.49-plus（main.lua / _meta.lua / Version.lua 三处同步）
- LICENSE 改为 AGPL-3.0-or-later；NOTICE.md 登记 fanqie.koplugin（MIT）的并入与原始版权
- 全新 `Leko/providers/` 抽象层：Provider / ProviderRegistry / RateLimiter
- `Leko/Fanqie/` 新增 9 个领域模块：Compliance / Config / Auth / Content /
  ShelfService / OfficialProvider / AsyncProviderTask / ProgressSync / QRLoginView
- 合规门禁 + 番茄默认零网络请求（G6）；扫码登录 + 番茄官方书闭环

### 阶段② 云端进度同步（T05）
- ProgressSync：pullProgress（开书拉取）/ scheduleUpload（30 秒节流）/
  flushOnExit（退出强制）/ _retryPending（启动重试）/ 冲突转 progress_backup 书签 + 一次性通知
- 3 处 seam：ReadingCoordinator → pullOnOpen；BookService:savePosition → scheduleUpload；
  ReaderView:onClose → flushOnExit

### 阶段③ 段评（T06-T07）
- FanqieReviewService 数据层：段评索引/详情缓存（7 天 TTL + LRU 50 本书），
  落盘 data/leko/providers/fanqie/reviews/<book_id>/<item_id>.json
- ReaderView 段落标记渲染（行首小圆点）；段落命中区域 + 点击分派
- ReviewDialog：复用 leko 对话框组件，居中半屏，触底加载下一页，关闭回原位不重排
- Dahuilang / Qingtian 聚合源接入段评数据源（PRD P0-4）

### 阶段④ 聚合源 + 限流（T08）
- FanqieDahuilangProvider + FanqieQingtianProvider：共享 RateLimiter 5/30s
- 不维护登录态 UI（PRD §1.2 合规姿态）：服务器地址与 token 由 config.lua 自填
- Fallback：番茄书在官方源失败时可在大灰狼/晴天之间回退（仅 book.provider 内）

### 阶段⑤ 设置/诊断/迁移/导出/多平台构建（T09-T13）
- FanqieSettingsView：菜单新分区"番茄账号设置"（账号/三源/同步开关/重载配置）
- FanqieDiagnostics：菜单"番茄诊断"分区（合规/登录/限流/pending/Provider 能力，PRD P2-1）
- FanqieMigration：检测 settings/fanqie.lua → 迁移 Cookie + 同步开关 + 聚合源配置
  到 data/leko/providers/fanqie/；旧插件共存提示一次
- ProgressSync 同步开关接入 FanqieConfig:sync.* （I-2 修复）
- BookInfoView 详情页追加"云端进度 + 段评"两行状态（I-1 修复）
- QuickJS 多平台构建：
  native/bridge/build-kobo-armv7.sh（hard-fp）/ build-linux-x86_64.sh /
  build-windows-x86_64.sh（实验性 mingw） / verify-multiplatform-abi.sh
- scripts/package.ps1 纳入 Fanqie/ 与 providers/ + 多平台 .so 产物
- 本更新日志 + 完整文档同步

## 0.15.49

- 精确保存并恢复章节内阅读位置，减少退出、重排版和换源后的跳读。
- 修复缓存进度条在排版、跳转等弹窗关闭后消失的问题。
- 补齐 Kindle 实体翻页键映射。
- 优化换源后的返回与续读流程，直接回到当前章节。
- 优化手动优先书源的搜索调度与超时重试顺序。
- 修复已有阅读器中从书籍详情点击"继续阅读"可能导致 KOReader 闪退的问题。
