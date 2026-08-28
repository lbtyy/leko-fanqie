local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Util = require("Leko/Util")

-- Leko/Fanqie/FanqieConfig.lua
--
-- 番茄 config.lua 通道：加载 leko.koplugin/config.lua（dofile），
-- 仅接受白名单键；GUI 设置页改动持久化为 override。
--
-- 移植自 fanqie/settings.lua:421-617 apply_config 的合并语义，适配点：
--   1. 不再接管 reading/layout/notification/debug/experimental 键
--      （leko 自身设置体系负责）；白名单：cookie_string/cookies、
--      qingtian{...}、dahuilang{...}、sync{...}、cache{...}、review{...}；
--   2. 合并优先级：gui_overrides > file_config > 内置默认值
--      （对应 fanqie 的 nil-only 语义：用户改过的项不被文件重载覆盖）；
--   3. token/device_id 保护：config.lua 永远不覆盖已存在的登录态字段
--      （移植 apply_config:544-549 的保护规则）；
--   4. 聚合源服务器地址仅来自 config.lua，GUI 不预填（合规，PRD §1.2）。

local PROTECTED_KEYS = { token = true, device_id = true }

local WHITELIST = {
    cookie_string = true,
    cookies = true,
    qingtian = true,
    dahuilang = true,
    sync = true,
    cache = true,
    review = true,
}

local DEFAULTS = {
    cookie_string = "",
    cookies = {},
    qingtian = {
        server_url = "", servers = {}, username = "", password = "",
        token = "", device_id = "", auto_login = true,
        rate_limit = { max_requests = 5, window_seconds = 30 },
    },
    dahuilang = {
        server_url = "", servers = {}, username = "", password = "", key = "",
        token = "", device_id = "", auto_login = true, source = "番茄",
        rate_limit = { max_requests = 5, window_seconds = 30 },
    },
    sync = { pull_on_open = true, upload_on_close = true },
    cache = { pre_download_chapters = 3 },
    review = { enabled = true, marker_style = "dot" },
}

local FanqieConfig = {
    file_config = nil,     -- config.lua 的白名单子集
    gui_overrides = nil,   -- 设置页持久化 override（LuaSettings）
    _settings = nil,
    _loaded = false,
}

-- 与 Storage:getProviderDataDir("fanqie") 相同的定位公式（保持同步）。
local function fanqieDataDir()
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", "fanqie")
end

-- leko.koplugin 插件目录：本文件位于 <plugin>/Leko/Fanqie/FanqieConfig.lua。
local function pluginDir()
    local source = debug.getinfo(1, "S").source
    if type(source) == "string" and source:sub(1, 1) == "@" then
        local path = source:sub(2):gsub("\\", "/")
        return Util.dirname(Util.dirname(Util.dirname(path)))
    end
    return "."
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = deepCopy(item) end
    return out
end

-- nil-only 深合并：dst 已有值（含 false）不覆盖；受保护键永不覆盖。
local function mergeNilOnly(dst, src, protect)
    if type(src) ~= "table" then return end
    for key, value in pairs(src) do
        if type(value) == "table" and type(dst[key]) == "table" then
            mergeNilOnly(dst[key], value, protect)
        elseif not (protect and PROTECTED_KEYS[key] and dst[key] ~= nil and dst[key] ~= "") then
            if dst[key] == nil then dst[key] = deepCopy(value) end
        end
    end
end

-- override 深合并：GUI 覆盖项总是生效；受保护键同样受保护。
local function mergeOverride(dst, src)
    if type(src) ~= "table" then return end
    for key, value in pairs(src) do
        if type(value) == "table" and type(dst[key]) == "table" then
            mergeOverride(dst[key], value)
        elseif not (PROTECTED_KEYS[key] and value ~= nil and value == "") then
            dst[key] = deepCopy(value)
        end
    end
end

function FanqieConfig:_loadFile()
    local config = {}
    local path = Util.joinPath(pluginDir(), "config.lua")
    local chunk = loadfile(path)
    if chunk then
        local ok, result = pcall(chunk)
        if ok and type(result) == "table" then
            for key, value in pairs(result) do
                if WHITELIST[key] then config[key] = value
                else logger.dbg("Leko FanqieConfig: 忽略非白名单键", tostring(key)) end
            end
        elseif not ok then
            logger.err("Leko FanqieConfig: config.lua 执行失败:", tostring(result))
        end
    end
    self.file_config = config
    return config
end

function FanqieConfig:_loadOverrides()
    if not self._settings then
        Util.mkdirp(fanqieDataDir())
        self._settings = LuaSettings:open(Util.joinPath(fanqieDataDir(), "gui-config.lua"))
    end
    local data = self._settings.data
    self.gui_overrides = (type(data) == "table" and type(data.overrides) == "table")
        and data.overrides or {}
    return self.gui_overrides
end

function FanqieConfig:load()
    self:_loadFile()
    self:_loadOverrides()
    self._loaded = true
    return self:effective()
end

--- 重载 config.lua（设置页「重载配置文件」按钮）。
-- 只重读文件，不动 GUI override——用户改过的项不被覆盖（P1-3②）。
function FanqieConfig:reload()
    self:_loadFile()
    return self:effective()
end

--- 生效配置 = 默认值 ←（nil-only）config.lua ←（override）GUI 覆盖。
function FanqieConfig:effective()
    if not self._loaded then self:load() end
    local merged = deepCopy(DEFAULTS)
    mergeNilOnly(merged, self.file_config or {}, true)
    mergeOverride(merged, self.gui_overrides or {})
    return merged
end

--- 读取单个键：get("sync") 返回整个 section 的生效表；
-- get("sync", "pull_on_open") 返回叶子值。
function FanqieConfig:get(section, key)
    local effective = self:effective()
    local value = effective[section]
    if key == nil then return value end
    if type(value) ~= "table" then return nil end
    return value[key]
end

--- 记录 GUI 覆盖并持久化。
function FanqieConfig:setGuiOverride(section, key, value)
    if not WHITELIST[section] then return false, "非白名单配置段：" .. tostring(section) end
    if PROTECTED_KEYS[key] then return false, "登录态字段不允许 GUI 覆盖：" .. tostring(key) end
    self:_loadOverrides()
    self.gui_overrides[section] = self.gui_overrides[section] or {}
    if key == nil then
        self.gui_overrides[section] = deepCopy(value)
    else
        self.gui_overrides[section][key] = deepCopy(value)
    end
    Util.mkdirp(fanqieDataDir())
    self._settings.data = { version = 1, overrides = self.gui_overrides }
    local ok, err = pcall(self._settings.flush, self._settings)
    if not ok then return false, tostring(err) end
    return true
end

--- 清除某个 section 的 GUI 覆盖（恢复 config.lua/默认值）。
function FanqieConfig:clearGuiOverride(section)
    self:_loadOverrides()
    self.gui_overrides[section] = nil
    self._settings.data = { version = 1, overrides = self.gui_overrides }
    local ok, err = pcall(self._settings.flush, self._settings)
    if not ok then return false, tostring(err) end
    return true
end

return FanqieConfig
