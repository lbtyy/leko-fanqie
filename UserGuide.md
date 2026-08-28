# 使用指南（leko-plus）

本文档面向 leko-plus 0.15.49-plus 全部用户：番茄新用户、leko 老用户、首次安装用户。

## 一、菜单总览

启动 Leko 书架后顶栏菜单（从上到下）：

| 顺序 | 条目 | 说明 |
|---|---|---|
| 1 | 查找书籍 | 在线搜索（需先导入书源） |
| 2 | 搜索设置 | 每条书源结果数上限 |
| 3 | 导出设置 | 导出目录配置 |
| 4 | 导入本地书籍 | TXT 导入 |
| 5 | 书源 | 已导入书源管理（启停 / 排序 / 备份） |
| 6 | **番茄小说** | 番茄最简入口：开启源 / 扫码登录 / 同步书架 / 退出登录 |
| 7 | **番茄账号设置** | 完整设置（仅 leko-plus）：三源状态、同步开关、配置重载 |
| 8 | **番茄诊断** | Provider 健康度面板（合规 / 登录 / 限流 / pending / 能力） |
| 9 | 存储与缓存 | leko Storage 统计与清理 |
| 10 | 新手帮助 | 首次使用提示 |
| 11 | 关于 Leko | 版本号 |

6 号、7 号、8 号三个条目为 leko-plus 扩展；条目 7、8 为 T09/T10 阶段⑤成果。

## 二、番茄功能（PRD §3.1）

### 1. 首次开启

菜单 → 番茄小说 → "开启番茄源" → 弹免责声明（个人学习研究用途、账号与内容归属番茄平台、用户自担风险）→ 确认 → 状态切换至"番茄源：已开启"。

未确认状态下，**番茄域名请求在代码路径上不可达**（G6）：`ProviderRegistry:get("fanqie:*")` 一律返回 nil。

### 2. 扫码登录

菜单 → 番茄小说 → "扫码登录番茄账号" → 弹 QRLoginView → 用番茄 App 扫码 → 子进程走 302 重定向 + 手动逐跳跟随（防 Set-Cookie 丢失） → 登录成功 Cookie 数组落盘 `data/leko/providers/fanqie/account.lua`。

### 3. 同步书架

菜单 → 番茄小说 → "同步番茄书架" → 后台走 AsyncProviderTask:run 经 ProcessBudget 调度 → 子进程拉取官方接口 → FanqieShelfService.mergeIntoBookshelf 写入 leko 统一书架 → 番茄书带"〔番〕"角标。

### 4. 退出登录

菜单 → 番茄小说 → "退出番茄登录" → 确认 → 清账户文件但保留章节缓存。

### 5. 完整设置（菜单 → 番茄账号设置）

进入完整分区后可见：
- **账号**卡片：登录态显示昵称 + 临期预警；登录按钮切换至"退出登录"
- **内容源**卡片：三源（官方 / 大灰狼 / 晴天）状态点（可用 / 需配置 / 停用）。
  聚合源服务器地址不在 GUI 中预填（合规姿态）——通过 config.lua 自填
- **云端进度同步**卡片：拉取上传开关两个 + 重载 config.lua 按钮

切换同步开关会立即写入 `data/leko/providers/fanqie/gui-config.lua`；
点重载按钮仅重读 `leko.koplugin/config.lua`，**不覆盖 GUI override**。

### 6. 诊断面板（菜单 → 番茄诊断）

显示：
- 合规门禁状态（已确认 / 未确认）
- 登录态（已登录 / 未登录 / 临期预警）
- 三源限流窗口（剩余可用 / 等待秒数）
- pending 队列长度（失败的进度同步条目）
- Provider 能力矩阵（shelf / toc / content / progress / review / login / probe）

## 三、段评（PRD §3.2）

### 1. 段落标记

打开番茄书（仅 Provider 声明段评且章节有评论时）：
- 每段首个有评论的段落行首出现小圆点（●）
- 段落起始位置绘制 14 px 标记位

未开启段评开关 / Provider 不支持段评 / 段评索引未命中时不显示标记。

### 2. 点击段评

- 点击段落左侧 24 px 宽标记热区 → 弹段评弹窗
- 弹窗点击该源不支持段评 → 弹"该源不支持段评"明确提示（不会出现静默点击）
- 弹窗加载中显示 spinner；列表触底自动加载下一页
- 关闭弹窗回原阅读位置（不触发重排与全刷）

### 3. 缓存与离线

段评索引/详情按 (book_id, item_id) 缓存到 `data/leko/providers/fanqie/reviews/`：
- 7 天 TTL：过期时下次进入章节自动重拉
- LRU 50 本：超过时按 lru_touch 升序淘汰整本书
- 随本书缓存清理一起清理：`FanqieReviewService:clearForBook(provider_book_id)`

## 四、云端进度同步（PRD §3.3）

### 1. 三处 seam

- **打开书时拉取**：ReadingCoordinator → `pullOnOpen`
  - 受 `FanqieConfig:sync.pull_on_open` 开关控制（默认 true）
  - 拉到云端 → `toLekoPosition(cloud, chapters)` 转换 → 与本地比对
  - 一致 / 差异 ≤ 容差 → 采用云端
  - 冲突（主理人裁决 #1：云端为准）→ 本地自动转 progress_backup 书签 + 一次性通知

- **翻页保存时上传**：BookService:savePosition → `scheduleUpload`
  - 30 秒节流（`UPLOAD_DEBOUNCE_SECONDS`）
  - 受 `FanqieConfig:sync.upload_on_close` 开关控制（默认 true）
  - 失败 → 入 `pending_progress.lua` 队列（按 provider_book_id 唯一性去重）

- **退出阅读强制上传**：ReaderView:onClose → `flushOnExit`
  - 异步，不阻塞退出

### 2. 弱网 / 离线恢复

启动时（`ProgressSync:start`）5 秒后调度 `_retryPending`：逐条推 queue → 成功出队 → AUTH_EXPIRED 直接清空 → 其他失败重试（指数退避在 `_retryPending` 中）。

### 3. 一次性冲突通知

`fanqie.progress_conflict_notified` sentinel：每次冲突只在产品生命周期内提示一次，避免反复打断阅读。

## 五、聚合源（fanqie:dahuilang / fanqie:qingtian）

### 1. 配置（config.lua）

`leko.koplugin/config.lua` 随包分发示例；用户在 `koreader/plugins/leko.koplugin/config.lua` 中填：

```lua
return {
    dahuilang = {
        server_url = "https://your-dahuilang-server.example",
        token = "your-token",
        device_id = "optional-device-id",
        source = "番茄",
        rate_limit = { max_requests = 5, window_seconds = 30 },
    },
    qingtian = {
        server_url = "https://your-qingtian-server.example",
        token = "your-token",
        device_id = "optional-device-id",
        rate_limit = { max_requests = 5, window_seconds = 30 },
    },
}
```

白名单读取逻辑：`gui_overrides > file_config > 内置默认值`；GUI 重载按钮不覆盖用户改过的键；token/device_id 等敏感字段不允许 GUI 覆盖。

### 2. 线路检测

子进程 `op = "probe"` 调 `<server_url>/ping`：返回 200-499 即视为可达。各源的限流窗口在诊断面板可见。

### 3. 跨源回退

Provider 字段（`book.provider_source`）记录当前内容来源；番茄书在三源之间回退（番茄官方 → 大灰狼 → 晴天）。番茄书不进入 Legado 规则源候选，普通 Legado 书不进番茄回退。

## 六、QuickJS 多平台

`native/bridge/` 下四个脚本：

| 脚本 | 目标 | 状态 |
|---|---|---|
| `build-kindle-armv7.sh` | Kindle ARMv7 softfp | 既有 |
| `build-kobo-armv7.sh` | Kobo ARMv7 hard-fp | 新增 |
| `build-linux-x86_64.sh` | 桌面 Linux x86_64 | 新增 |
| `build-windows-x86_64.sh` | Windows x86_64 mingw | 实验性 |
| `verify-multiplatform-abi.sh` | 各平台 ABI 验证 | 新增 |

`scripts/package.ps1` 会自动收纳 `build/<platform>/liblekoqjs.so` 或 `.dll` 产物。无 so 平台由 `Leko/QuickJSRuntimeCheck.lua` 走桌面回退路径，不崩溃。
