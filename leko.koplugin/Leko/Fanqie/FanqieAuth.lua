local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Util = require("Leko/Util")

-- Leko/Fanqie/FanqieAuth.lua
--
-- 番茄账号态：扫码登录编排 + Cookie 持久化 + 过期预警。
-- 移植自 fanqie/qrlogin.lua:216-521 的登录流程与 fanqie/cookie.lua:3-101
-- 的 Cookie 处理，适配点：
--   1. 网络全部改走 AsyncProviderTask 子进程 op（qr_create/qr_poll/qr_finish），
--      UI 线程只做状态编排与持久化；
--   2. Cookie 一律以数组形式 {{name=, value=}} 存储与跨进程传递——
--      rapidjson 会把纯字符串 key 的 hash table 丢成空表
--      （fanqie/async.lua:41-44 的教训，设计文档共享知识 4）；
--   3. 持久化改为 LuaSettings：data/leko/providers/fanqie/account.lua；
--   4. config.lua 的 cookie_string/cookies 仅作未扫码时的保底 fallback
--      （移植 fanqie/settings.lua:440-468 的优先级语义）。

local ACCOUNT_VERSION = 1
local EXPIRING_SOON_DAYS = 50   -- Cookie 有效期约 60 天，>50 天提示重登（P0-2④）

local FanqieAuth = {
    _settings = nil,
    _account = nil,
    _qr = nil,   -- 进行中的扫码会话 { generation, token, csrf, cookies(array), started }
}

-- 与 Storage:getProviderDataDir("fanqie") 相同的定位公式（保持同步）。
local function fanqieDataDir()
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", "fanqie")
end

local function accountPath()
    return Util.joinPath(fanqieDataDir(), "account.lua")
end

-- ---------------------------------------------------------------------------
-- Cookie 数组 <-> map 转换（数组是持久化/IPC 形式，map 是运算形式）
-- ---------------------------------------------------------------------------

local function arrayToMap(array)
    local map = {}
    for _, entry in ipairs(array or {}) do
        if type(entry) == "table" and entry.name and entry.name ~= "" and entry.value ~= nil then
            map[tostring(entry.name)] = tostring(entry.value)
        end
    end
    return map
end

local function mapToArray(map)
    local array = {}
    for name, value in pairs(map or {}) do
        array[#array + 1] = { name = name, value = value }
    end
    table.sort(array, function(a, b) return a.name < b.name end)
    return array
end

-- 移植自 fanqie/cookie.lua:33-40 to_header，适配点：输入为 map（内部形式）。
local function mapToHeader(map)
    local parts = {}
    for key, value in pairs(map or {}) do
        parts[#parts + 1] = key .. "=" .. value
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

-- 移植自 fanqie/cookie.lua:46-51 SET_COOKIE_ATTRS，适配点：无。
local SET_COOKIE_ATTRS = {
    ["path"] = true, ["domain"] = true, ["expires"] = true, ["max-age"] = true,
    ["secure"] = true, ["httponly"] = true, ["samesite"] = true,
    ["priority"] = true, ["partitioned"] = true, ["comment"] = true,
    ["version"] = true, ["discard"] = true,
}

-- 移植自 fanqie/cookie.lua:53-91 merge_set_cookie，适配点：无（map 进 map 出）。
local function mergeSetCookieMap(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then return cookies end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            mergeSetCookieMap(cookies, value)
        end
        return cookies
    end
    local sc = tostring(set_cookie)
    -- LuaSocket 会把多个 Set-Cookie 用 ", " 合并；Expires 值里合法含逗号，
    -- 先用占位符保护 "Expires=值," 中的逗号再切分。
    local PLACEHOLDER = "\x01"
    sc = sc:gsub("([Ee][Xx][Pp][Ii][Rr][Ee][Ss]=[^,;]-)%,", "%1" .. PLACEHOLDER)
    for seg in sc:gmatch("[^,\r\n]+") do
        seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
        seg = seg:gsub(PLACEHOLDER, ",")
        if seg ~= "" then
            local cookie_name, cookie_value = seg:match("^([^=%s;]+)=([^;]*)")
            if cookie_name and cookie_value and not SET_COOKIE_ATTRS[cookie_name:lower()] then
                cookies[cookie_name] = cookie_value
            end
        end
    end
    return cookies
end

-- 移植自 fanqie/cookie.lua:3-16 parse_cookie_header，适配点：无。
local function parseCookieHeader(header)
    local cookies = {}
    if not header or header == "" then return cookies end
    header = header:gsub("^%s*[Cc]ookie:%s*", "")
    for part in header:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then cookies[key] = value end
    end
    return cookies
end

-- ---------------------------------------------------------------------------
-- 账号存取
-- ---------------------------------------------------------------------------

function FanqieAuth:reload()
    Util.mkdirp(fanqieDataDir())
    self._settings = LuaSettings:open(accountPath())
    local data = self._settings.data
    self._account = type(data) == "table" and data or {}
    return self._account
end

function FanqieAuth:_load()
    if not self._account then self:reload() end
    return self._account
end

--- @return table 账号记录 { login_method, nickname, cookies(array), cookie_saved_at }
function FanqieAuth:getAccount()
    return self:_load()
end

--- 有效 Cookie（数组形式）：扫码结果优先，config.lua 保底。
-- 移植自 fanqie/settings.lua:440-468 的 cookie 优先级语义。
function FanqieAuth:getCookiesArray()
    local account = self:_load()
    if type(account.cookies) == "table" and #account.cookies > 0 then
        return account.cookies, "qr"
    end
    -- config.lua fallback（过滤空值：模板里的占位不算有效 cookie）
    local ok, FanqieConfig = pcall(require, "Leko/Fanqie/FanqieConfig")
    if ok and FanqieConfig then
        local map = {}
        local cookie_string = FanqieConfig:get("cookie_string")
        if type(cookie_string) == "string" and cookie_string ~= "" then
            map = parseCookieHeader(cookie_string)
        else
            local config_cookies = FanqieConfig:get("cookies")
            if type(config_cookies) == "table" then
                for key, value in pairs(config_cookies) do
                    if value and value ~= "" then map[key] = value end
                end
            end
        end
        -- 过滤空值
        for key, value in pairs(map) do
            if not value or value == "" then map[key] = nil end
        end
        if next(map) ~= nil then return mapToArray(map), "config" end
    end
    return {}, nil
end

function FanqieAuth:getCookieMap()
    local array = self:getCookiesArray()
    return arrayToMap(array)
end

function FanqieAuth:isLoggedIn()
    local map = self:getCookieMap()
    return type(map.sessionid) == "string" and #map.sessionid >= 8
end

--- Cookie 请求头（"k=v; k2=v2"）。
function FanqieAuth:cookieHeader()
    return mapToHeader(self:getCookieMap())
end

--- 持久化扫码得到的 Cookie（UI 线程调用）。
-- @param cookies_array table {{name=, value=}, ...}
-- @param meta table|nil { nickname = string }
function FanqieAuth:persistCookies(cookies_array, meta)
    if type(cookies_array) ~= "table" or #cookies_array == 0 then
        return false, "cookie 为空"
    end
    local account = self:_load()
    account.version = ACCOUNT_VERSION
    account.login_method = "qr"
    account.nickname = meta and meta.nickname or account.nickname
    account.cookies = cookies_array
    account.cookie_saved_at = os.time()
    Util.mkdirp(fanqieDataDir())
    self._settings = LuaSettings:open(accountPath())
    self._settings.data = account
    local ok, err = pcall(self._settings.flush, self._settings)
    if not ok then return false, tostring(err) end
    logger.info("Leko FanqieAuth: persisted", #cookies_array, "cookies")
    return true
end

--- 登出：清空账号记录与扫码会话。
function FanqieAuth:logout()
    self._qr = nil
    self._account = { version = ACCOUNT_VERSION, cookies = {} }
    Util.mkdirp(fanqieDataDir())
    self._settings = LuaSettings:open(accountPath())
    self._settings.data = self._account
    pcall(self._settings.flush, self._settings)
    logger.info("Leko FanqieAuth: logged out")
    return true
end

--- Cookie 临期预警（保存时间超过 50 天）。
function FanqieAuth:isExpiringSoon()
    local account = self:_load()
    local saved_at = tonumber(account.cookie_saved_at or 0) or 0
    if saved_at <= 0 then return false end
    return (os.time() - saved_at) > EXPIRING_SOON_DAYS * 24 * 3600
end

-- ---------------------------------------------------------------------------
-- 扫码登录编排（UI 线程；网络经 AsyncProviderTask 子进程 op）
-- 移植自 fanqie/qrlogin.lua:216-521，适配点见模块头注释。
-- ---------------------------------------------------------------------------

local function asyncProviderTask()
    return require("Leko/Fanqie/AsyncProviderTask")
end

local POLL_INTERVAL = 2      -- 移植 qrlogin.lua:70
local QR_TIMEOUT = 300       -- 移植 qrlogin.lua:71

function FanqieAuth:cancelQrLogin()
    if self._qr then
        self._qr.generation = self._qr.generation + 1
        self._qr = nil
    end
end

--- 启动扫码登录。
-- @param view table QRLoginView，需提供 showQr(qr_url)/setStatus(text)/
--             showRetry(message)/closeSuccess() 四个方法
function FanqieAuth:startQrLogin(view)
    self:cancelQrLogin()
    self._qr = {
        generation = 1,
        started = os.time(),
        token = nil,
        csrf = "",
        cookies = {},   -- 数组形式
        poll_failures = 0,
    }
    local gen = self._qr.generation
    view:setStatus("正在获取二维码……")
    asyncProviderTask():run("fanqie:official", "qr_create", {}, function(ok, err, result)
        local session = self._qr
        if not session or session.generation ~= gen then return end
        if not ok or type(result) ~= "table" then
            view:showRetry("获取二维码失败：\n" .. tostring(err or "未知错误"))
            return
        end
        session.token = result.token
        session.csrf = result.csrf or ""
        session.cookies = type(result.cookies) == "table" and result.cookies or {}
        session.expire_time = tonumber(result.expire_time or 0) or 0
        view:showQr(result.qr_url)
        self:_scheduleQrPoll(view, gen)
    end, { lane = "foreground", label = "fanqie:qr_create", timeout_seconds = 25 })
end

-- 移植自 fanqie/qrlogin.lua:301-419 _schedule 的轮询语义。
function FanqieAuth:_scheduleQrPoll(view, gen)
    local session = self._qr
    if not session or session.generation ~= gen then return end
    if os.time() - session.started > QR_TIMEOUT then
        view:showRetry("二维码已过期")
        return
    end
    if session.expire_time and session.expire_time > 0 and os.time() > session.expire_time then
        view:showRetry("二维码已过期")
        return
    end
    asyncProviderTask():run("fanqie:official", "qr_poll", {
        token = session.token,
        csrf = session.csrf,
        cookies = session.cookies,
    }, function(ok, err, result)
        local current = self._qr
        if not current or current.generation ~= gen then return end
        if not ok or type(result) ~= "table" then
            -- 网络错误：稍后重试，不立即判定失败（移植 _schedule 的错误分支）
            current.poll_failures = current.poll_failures + 1
            UIManager:scheduleIn(POLL_INTERVAL, function() self:_scheduleQrPoll(view, gen) end)
            return
        end
        current.poll_failures = 0
        if type(result.cookies) == "table" then current.cookies = result.cookies end

        if result.has_sessionid == true then
            self:_finishQrLoginSuccess(view, gen)
            return
        end
        local status = tostring(result.status or "")
        if status == "success" or status == "confirmed" then
            if type(result.redirect_url) == "string" and result.redirect_url ~= "" then
                self:_finishQrWithRedirect(view, gen, result.redirect_url)
            else
                self:_finishQrLoginSuccess(view, gen)
            end
        elseif status == "expired" then
            view:showRetry("二维码已过期")
        else
            -- new / scanned / redirect 等非终态：继续轮询
            view:setStatus(status == "scanned" and "已扫码，请在手机上确认……" or "等待手机扫码……")
            UIManager:scheduleIn(POLL_INTERVAL, function() self:_scheduleQrPoll(view, gen) end)
        end
    end, { lane = "foreground", label = "fanqie:qr_poll", timeout_seconds = 20 })
end

-- 移植自 fanqie/qrlogin.lua:425-490 _finish_with_redirect。
function FanqieAuth:_finishQrWithRedirect(view, gen, redirect_url)
    local session = self._qr
    if not session or session.generation ~= gen then return end
    view:setStatus("正在完成登录……")
    asyncProviderTask():run("fanqie:official", "qr_finish", {
        redirect_url = redirect_url,
        csrf = session.csrf,
        cookies = session.cookies,
    }, function(ok, err, result)
        local current = self._qr
        if not current or current.generation ~= gen then return end
        if not ok or type(result) ~= "table" then
            view:showRetry("完成登录失败：\n" .. tostring(err or "未知错误"))
            return
        end
        if type(result.cookies) == "table" then current.cookies = result.cookies end
        if result.has_sessionid == true then
            self:_finishQrLoginSuccess(view, gen)
        else
            view:showRetry("登录失败：未获取到 sessionid")
        end
    end, { lane = "foreground", label = "fanqie:qr_finish", timeout_seconds = 25 })
end

-- 移植自 fanqie/qrlogin.lua:494-519 _finish_login_success，适配点：
-- 持久化改为 account.lua（数组 cookie），不再写 fanqie settings。
function FanqieAuth:_finishQrLoginSuccess(view, gen)
    local session = self._qr
    if not session or session.generation ~= gen then return end
    local cookies = session.cookies
    self._qr = nil
    local saved, save_err = self:persistCookies(cookies)
    if not saved then
        view:showRetry("登录成功但保存失败：\n" .. tostring(save_err))
        return
    end
    view:closeSuccess()
end

return FanqieAuth
