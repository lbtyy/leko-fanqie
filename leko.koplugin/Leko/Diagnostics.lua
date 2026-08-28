local logger_ok, logger = pcall(require, "logger")
if not logger_ok or type(logger) ~= "table" then logger = { err = function() end } end

local Diagnostics = {}

local function loadStorage()
    local ok, module = pcall(require, "Leko/Storage")
    return ok and type(module) == "table" and module or nil
end

local function loadUtil()
    local ok, module = pcall(require, "Leko/Util")
    return ok and type(module) == "table" and module or nil
end

function Diagnostics:getPath()
    local Storage = loadStorage()
    local dir = Storage and type(Storage.getLogsDir) == "function" and Storage:getLogsDir() or "/tmp"
    return tostring(dir):gsub("/+$", "") .. "/last-error.log"
end

local function fallbackWrite(path, body)
    local file = io.open(path, "wb")
    if not file then return false end
    local wrote = file:write(body)
    if wrote then file:flush() end
    file:close()
    return wrote ~= nil
end

function Diagnostics:record(label, detail)
    label = tostring(label or "operation")
    detail = tostring(detail or "unknown error")
    logger.err("Leko", label, detail)
    local path = self:getPath()
    local body = os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. label .. "\n\n" .. detail .. "\n"
    local Util = loadUtil()
    local ok
    if Util then
        local dir = path:match("^(.*)/[^/]+$")
        if dir and type(Util.mkdirp) == "function" then pcall(Util.mkdirp, dir) end
        if type(Util.writeFile) == "function" then ok = Util.writeFile(path, body, true) end
    end
    if ok ~= true then ok = fallbackWrite(path, body) end
    return ok and path or nil
end

function Diagnostics:readLast()
    local path = self:getPath()
    local Util = loadUtil()
    local data
    if Util and type(Util.readFile) == "function" then data = Util.readFile(path, true) end
    if not data then
        local file = io.open(path, "rb")
        if file then data = file:read("*a"); file:close() end
    end
    if not data or data == "" then return nil, path end
    return data, path
end

-- ---------------------------------------------------------------------------
-- [seam] leko-plus（阶段⑤ T10，P2-1）：番茄 Provider 诊断面板分区。
-- 返回 diagnosis 表：合规状态 / 登录态 / 限流窗口 / pending 队列 /
-- Provider 能力。本方法纯数据采集；UI 侧由 MainMenuView/Diagnostics 页
-- 调用 buildFanqiePanel 方法渲染。失败字段置 nil 不抛错。
-- ---------------------------------------------------------------------------

local function safeRequire(path)
    local ok, module = pcall(require, path)
    if not ok or type(module) ~= "table" then return nil end
    return module
end

function Diagnostics:ensureFanqiePanel()
    local out = {}
    local compliance = safeRequire("Leko/Fanqie/FanqieCompliance")
    out.compliance_enabled = compliance and type(compliance.isEnabled) == "function"
        and compliance:isEnabled() or false

    local auth = safeRequire("Leko/Fanqie/FanqieAuth")
    if auth then
        out.logged_in = type(auth.isLoggedIn) == "function" and auth:isLoggedIn() or false
        out.expiring_soon = type(auth.isExpiringSoon) == "function"
            and auth:isExpiringSoon() or false
        local ok_acct, account = pcall(function() return auth:getAccount() end)
        if ok_acct and type(account) == "table" then
            out.nickname = account.nickname
            out.cookie_saved_at = account.cookie_saved_at
        end
    end

    local rate = safeRequire("Leko/providers/RateLimiter")
    if rate and type(rate.peek) == "function" then
        -- 列示 fanqie 域三方源的当前窗口
        local sources = { "fanqie:official", "fanqie:dahuilang", "fanqie:qingtian" }
        out.rate_limits = {}
        for _, source in ipairs(sources) do
            local ok, would_ok, wait = pcall(rate.peek, rate, source, 5, 30)
            out.rate_limits[source] = {
                would_ok = ok and would_ok,
                wait_seconds = ok and wait or 0,
            }
        end
    end

    local progress = safeRequire("Leko/Fanqie/ProgressSync")
    if progress then
        -- pending_progress 队列长度 + 重试状态（不暴露内容）
        local pending = progress._pending
        out.pending_count = type(pending) == "table" and #pending or 0
        out.sync_pull_enabled = type(progress.syncPullEnabled) == "function"
            and progress:syncPullEnabled() or true
        out.sync_upload_enabled = type(progress.syncUploadEnabled) == "function"
            and progress:syncUploadEnabled() or true
    end

    -- Provider 三方源能力探测
    local registry = safeRequire("Leko/providers/ProviderRegistry")
    out.providers = {}
    if registry then
        for _, id in ipairs({ "fanqie:official", "fanqie:dahuilang", "fanqie:qingtian" }) do
            local caps = registry:capabilitiesOf(id)
            out.providers[id] = caps
        end
    end

    return out
end

return Diagnostics
