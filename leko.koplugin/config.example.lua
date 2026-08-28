-- leko-plus 番茄 config.lua 通道示例
-- 改写自 fanqie.koplugin/config.example.lua（裁剪版）
--
-- 使用方法：复制本文件为 leko.koplugin/config.lua 并按需修改。
-- 仅下列白名单键会被 FanqieConfig 接受；fanqie 原有的
-- reading/layout/notification/debug/experimental 键由 leko 自身设置体系接管，不再读取。
--
-- 合并优先级：GUI 设置（设置页覆盖项） > config.lua > 内置默认值。
-- 聚合源服务器地址只能来自本文件，GUI 不预填（合规要求）。

return {
    -- Cookie 保底配置（可选）：扫码登录优先，以下字段仅在未扫码时作为 fallback。
    -- 正常使用无需填写，菜单 → 番茄小说 → 扫码登录即可自动获取并持久化 Cookie。
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
    },

    -- 晴天聚合服务器配置（阶段④启用；仅用于获取正文与段评，目录和书架仍使用官方API）
    qingtian = {
        server_url = "",
        servers = {},
        username = "",
        password = "",
        token = "",
        device_id = "",
        auto_login = true,
        rate_limit = {
            max_requests = 5,
            window_seconds = 30,
        },
    },

    -- 大灰狼聚合服务器配置（阶段④启用）
    dahuilang = {
        server_url = "",
        servers = {},
        username = "",
        password = "",
        key = "",
        token = "",
        device_id = "",
        auto_login = true,
        source = "番茄",
        rate_limit = {
            max_requests = 5,
            window_seconds = 30,
        },
    },

    -- 云端进度同步开关（阶段②启用；GUI 开关优先于本文件）
    sync = {
        pull_on_open = true,
        upload_on_close = true,
    },

    -- 缓存策略
    cache = {
        pre_download_chapters = 3,
    },

    -- 段评（阶段③启用）
    review = {
        enabled = true,
        marker_style = "dot",   -- "dot"（行首小圆点，默认）| "underline"（下划线，候选样式）
    },
}
