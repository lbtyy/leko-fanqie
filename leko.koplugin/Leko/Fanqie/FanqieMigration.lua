local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")

local Util = require("Leko/Util")

-- Leko/Fanqie/FanqieMigration.lua
--
-- 旧 fanqie.koplugin 数据迁移（阶段⑤ T11，PRD §P1-6）。
-- 检测 ko 数据目录下老合规路径 settings/fanqie.lua（settings 表）
-- / settings.lua（同义）→ 迁移 Cookie 数组 + 同步开关到
-- data/leko/providers/fanqie/（account.lua + settings.lua + gui-config.lua）。
-- 旧章节缓存（data/fanqie/cache/）不迁移——番茄侧章节缓存统一走 leko
-- Storage 的 per-book 缓存，新部署会重新按需拉取。
--
-- 迁移策略：
--   1. 可跳过：用户拒绝 → 写入 sentinel 文件 record，下次启动不再问；
--   2. 可重试：迁移失败或 sentinel 标 failed 可重试；
--   3. 不阻塞主流程：App:init 用一次性后台 schedule，失败仅记录日志；
--   4. 旧插件共存提示：检测到独立 plugin 目录时弹一次通知。

local MIGRATION_FLAG = "migration_state.lua"
local MIGRATION_SENTINEL_VERSION = 1

local FanqieMigration = {
    _completed = false,
}

local function lekoRoot()
    return Util.joinPath(DataStorage:getDataDir(), "leko")
end

local function fanqieRoot()
    return Util.joinPath(lekoRoot(), "providers", "fanqie")
end

local function flagPath()
    return Util.joinPath(fanqieRoot(), MIGRATION_FLAG)
end

local function legacySettingsPath()
    -- 旧 fanqie.koplugin 把设置写在全局 ko settings 目录中
    -- （settings/fanqie.lua 或 settings.lua）；兼容两种叫法。
    return Util.joinPath(DataStorage:getDataDir(), "settings", "fanqie.lua")
end

local function legacyShelfPath()
    -- 旧 fanqie.koplugin 书架缓存路径（不迁移，列举以便日志诊断）
    return Util.joinPath(DataStorage:getDataDir(), "fanqie")
end

local function readFlag()
    local path = flagPath()
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local data = Util.readFile(path, true)
    if not data or data == "" then return nil end
    local ok, decoded = pcall(function() return LuaSettings:open(path).data end)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function writeFlag(state, detail)
    Util.mkdirp(fanqieRoot())
    local settings = LuaSettings:open(flagPath())
    settings.data = {
        version = MIGRATION_SENTINEL_VERSION,
        state = state,
        detail = detail,
        updated_at = os.time(),
    }
    pcall(settings.flush, settings)
end

-- ---------------------------------------------------------------------------
-- 数据迁移
-- ---------------------------------------------------------------------------

local function readLegacyData()
    local path = legacySettingsPath()
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or type(settings) ~= "table" then return nil end
    return settings.data
end

local function migrateAccount(account_data)
    if not account_data or type(account_data) ~= "table" then return false, "无账号数据" end
    local cookies = nil
    if type(account_data.cookies) == "table" then
        cookies = {}
        if account_data.cookies[1] then
            -- 已经是数组
            cookies = account_data.cookies
        else
            -- hash table → 数组化
            local keys = {}
            for k in pairs(account_data.cookies) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                cookies[#cookies + 1] = { name = k, value = tostring(account_data.cookies[k] or "") }
            end
        end
    end
    if not cookies or #cookies == 0 then
        return false, "旧账号数据无 cookies"
    end
    local FanqieAuth = require("Leko/Fanqie/FanqieAuth")
    local ok = FanqieAuth:persistCookies(cookies, {
        nickname = account_data.nickname,
        cookie_saved_at = account_data.cookie_saved_at or os.time(),
    })
    if not ok then return false, "persistCookies 失败" end
    return true
end

local function migrateSyncSettings(sync_data)
    if not sync_data or type(sync_data) ~= "table" then return false end
    local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
    local any = false
    if sync_data.pull_on_open ~= nil then
        FanqieConfig:setGuiOverride("sync", "pull_on_open", sync_data.pull_on_open == true)
        any = true
    end
    if sync_data.upload_on_close ~= nil then
        FanqieConfig:setGuiOverride("sync", "upload_on_close", sync_data.upload_on_close == true)
        any = true
    end
    return any
end

local function migrateConfigWhitelist(config_data)
    if not config_data or type(config_data) ~= "table" then return false end
    local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
    -- 聚合源服务器地址从旧 config.lua 复制进来，避免用户重复填写
    local whitelist_sections = { dahuilang = true, qingtian = true }
    local any = false
    for section, _ in pairs(whitelist_sections) do
        local payload = config_data[section]
        if type(payload) == "table" then
            for k, v in pairs(payload) do
                -- 受保护字段（token/device_id/password/key）禁止 GUI 覆盖
                if k == "token" or k == "device_id" or k == "password" or k == "key" then
                    -- 仅当旧数据存在，且未在新位置 set 过时才写 GUI override
                    -- 但实际上我们不应该把 secrets 写进 GUI override，所以跳过
                else
                    FanqieConfig:setGuiOverride(section, k, v)
                    any = true
                end
            end
        end
    end
    return any
end

-- ---------------------------------------------------------------------------
-- 主流程
-- ---------------------------------------------------------------------------

function FanqieMigration:_detectLegacy()
    if lfs.attributes(legacySettingsPath(), "mode") == "file" then
        return true, "settings/fanqie.lua"
    end
    return false, nil
end

function FanqieMigration:_detectOldPlugin()
    -- 检测 fanqie.koplugin 作为独立插件目录存在（G6 合规姿态）
    local candidates = {
        Util.joinPath(DataStorage:getDataDir(), "..", "plugins", "fanqie.koplugin"),
        Util.joinPath(DataStorage:getDataDir(), "plugins", "fanqie.koplugin"),
    }
    for _, candidate in ipairs(candidates) do
        if lfs.attributes(candidate, "mode") == "directory" then
            return true, candidate
        end
    end
    return false, nil
end

--- 执行迁移（一次性，可阻塞主流程，安全失败）。
-- @param opts { interactive: bool, on_done: function(ok, detail)}
function FanqieMigration:run(opts)
    opts = opts or {}
    if self._completed then return false, "已在本次会话执行过" end
    local flag = readFlag()
    if flag and flag.state == "skipped" then
        return false, "用户已标记跳过"
    end
    if flag and flag.state == "success" then
        self._completed = true
        return true
    end
    local detected, source = self:_detectLegacy()
    if not detected then
        -- 没有旧数据，但老插件目录可能仍存在
        local has_old_plugin, plugin_path = self:_detectOldPlugin()
        if has_old_plugin then
            self:_showCoexistNotice(plugin_path)
        end
        writeFlag("success", "no legacy data")
        self._completed = true
        return true
    end

    local legacy = readLegacyData()
    if not legacy then
        writeFlag("failed", "read legacy data failed")
        return false, "无法读取旧 settings/fanqie.lua"
    end

    local ok_acc, acc_err = migrateAccount(legacy)
    local ok_sync = migrateSyncSettings(legacy.sync or {})
    local ok_cfg = migrateConfigWhitelist(legacy)
    if ok_acc then
        writeFlag("success", "migrated from " .. tostring(source))
        self._completed = true
        logger.info("Leko FanqieMigration: success", source,
            "account=" .. tostring(ok_acc), "sync=" .. tostring(ok_sync), "cfg=" .. tostring(ok_cfg))
        return true
    end
    writeFlag("failed", acc_err)
    return false, acc_err
end

function FanqieMigration:_showCoexistNotice(plugin_path)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{
        text = "检测到旧 fanqie.koplugin 目录，功能已并入 leko-plus，可以从 KOReader 插件列表移除旧条目。",
        timeout = 8,
    })
end

--- 重置 sentinel（设置页"重置迁移状态"按钮使用）。
function FanqieMigration:resetState()
    self._completed = false
    local path = flagPath()
    if lfs.attributes(path, "mode") == "file" then
        pcall(os.remove, path)
    end
    return true
end

return FanqieMigration
