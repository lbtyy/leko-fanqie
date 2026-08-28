local DataStorage = require("datastorage")
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Util = require("Leko/Util")

-- Leko/providers/RateLimiter.lua
--
-- 滑动窗口限流器（Provider 通用）。
-- 移植自 fanqie/sources.lua:46-118，适配点：
--   1. 模块级状态收进实例 table（self.timestamps），接口改为方法调用；
--   2. 时间戳按"<域>"落盘到 data/leko/providers/<域>/rate_limit.json，
--      记录一律使用数组形式 [{source_id=..., ts=...}]——rapidjson 会把
--      纯字符串 key 的 hash table 丢成空表（fanqie/async.lua:41-44 的教训）；
--   3. 子进程 fork 出的副本里 check() 记录的时间戳随子进程退出丢失，
--      由调用方把 recorded_ts 经任务结果带回父进程，调 merge() 合并
--      （移植 sources.lua:75 merge_rate_limit_timestamps 语义）。

local RateLimiter = {
    window_seconds = 30,
    timestamps = {},        -- source_id -> { ts, ... }
    _loaded_domains = {},   -- domain -> true
    _dirty = false,
    _last_save = 0,
    save_debounce_seconds = 5,
}

local function domainOf(source_id)
    return tostring(source_id or ""):match("^([^:]+):") or "default"
end

-- 与 Storage:getProviderDataDir(domain) 相同的定位公式（保持同步）。
local function domainDir(domain)
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", tostring(domain))
end

local function rateLimitPath(domain)
    return Util.joinPath(domainDir(domain), "rate_limit.json")
end

function RateLimiter:_loadDomain(domain)
    if self._loaded_domains[domain] then return end
    self._loaded_domains[domain] = true
    local path = rateLimitPath(domain)
    if lfs.attributes(path, "mode") ~= "file" then return end
    local raw = Util.readFile(path, true)
    if not raw then return end
    local ok, data = pcall(rapidjson.decode, raw)
    if not ok or type(data) ~= "table" or type(data.records) ~= "table" then return end
    local now = os.time()
    for _, entry in ipairs(data.records) do
        if type(entry) == "table" and entry.source_id and tonumber(entry.ts) then
            local ts = tonumber(entry.ts)
            -- 只恢复仍在窗口内的时间戳；窗口外的本来就会被裁剪
            if now - ts < math.max(self.window_seconds, 3600) then
                local stamps = self.timestamps[entry.source_id] or {}
                stamps[#stamps + 1] = ts
                self.timestamps[entry.source_id] = stamps
            end
        end
    end
end

function RateLimiter:_saveDomain(domain)
    local records = {}
    local now = os.time()
    local prefix = tostring(domain) .. ":"
    for source_id, stamps in pairs(self.timestamps) do
        if source_id:sub(1, #prefix) == prefix then
            for _, ts in ipairs(stamps) do
                if now - ts < math.max(self.window_seconds, 3600) then
                    records[#records + 1] = { source_id = source_id, ts = ts }
                end
            end
        end
    end
    Util.mkdirp(domainDir(domain))
    local ok, encoded = pcall(rapidjson.encode, { version = 1, saved_at = now, records = records })
    if not ok then return false, tostring(encoded) end
    return Util.writeFile(rateLimitPath(domain), encoded, true)
end

function RateLimiter:_markDirty(source_id)
    self._dirty = true
    local now = os.time()
    if now - self._last_save >= self.save_debounce_seconds then
        self._last_save = now
        self._dirty = false
        local ok, err = self:_saveDomain(domainOf(source_id))
        if not ok then logger.err("Leko RateLimiter: save failed:", tostring(err)) end
    end
end

local function validStamps(self, source_id, window_seconds)
    self:_loadDomain(domainOf(source_id))
    local now = os.time()
    local valid = {}
    for _, ts in ipairs(self.timestamps[source_id] or {}) do
        if now - ts < window_seconds then valid[#valid + 1] = ts end
    end
    table.sort(valid)
    return valid, now
end

--- 检查（并记录）一次请求。
-- 移植自 fanqie/sources.lua:46-68 rate_limit_check。
-- @param max_requests number 窗口内最大请求数；nil/<=0 表示不限流
-- @return ok boolean, wait number, recorded_ts number|nil
function RateLimiter:check(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then return true, 0, nil end
    window_seconds = tonumber(window_seconds) or self.window_seconds
    local valid, now = validStamps(self, source_id, window_seconds)
    if #valid >= max_requests then
        local wait = window_seconds - (now - valid[1])
        return false, (wait > 0 and wait or 0), nil
    end
    valid[#valid + 1] = now
    self.timestamps[source_id] = valid
    self:_markDirty(source_id)
    return true, 0, now
end

--- 只查询不记录。
-- 移植自 fanqie/sources.lua:97-113 rate_limit_peek。
-- @return would_ok boolean, wait number
function RateLimiter:peek(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then return true, 0 end
    window_seconds = tonumber(window_seconds) or self.window_seconds
    local valid, now = validStamps(self, source_id, window_seconds)
    if #valid >= max_requests then
        local wait = window_seconds - (now - valid[1])
        return false, (wait > 0 and wait or 0)
    end
    return true, 0
end

--- 合并子进程带回的时间戳（去重）。
-- 移植自 fanqie/sources.lua:75-91 merge_rate_limit_timestamps。
-- @param recorded table 数组 [{ source_id = string, ts = number }, ...]
function RateLimiter:merge(recorded)
    if type(recorded) ~= "table" then return end
    local dirty_domain
    for _, entry in ipairs(recorded) do
        if type(entry) == "table" and entry.source_id and tonumber(entry.ts) then
            local stamps = self.timestamps[entry.source_id] or {}
            local found = false
            for _, ts in ipairs(stamps) do
                if ts == entry.ts then found = true break end
            end
            if not found then
                stamps[#stamps + 1] = entry.ts
                self.timestamps[entry.source_id] = stamps
                dirty_domain = domainOf(entry.source_id)
            end
        end
    end
    if dirty_domain then
        self._dirty = true
        self:_saveDomain(dirty_domain)
    end
end

--- 重置某个源的限流状态（登出/配置变更后调用）。
-- 移植自 fanqie/sources.lua:116-118 rate_limit_reset。
function RateLimiter:reset(source_id)
    self.timestamps[source_id] = nil
    self:_saveDomain(domainOf(source_id))
end

--- 强制落盘（挂起/退出前调用）。
function RateLimiter:flush()
    if not self._dirty then return true end
    self._dirty = false
    local domains = {}
    for source_id, _ in pairs(self.timestamps) do domains[domainOf(source_id)] = true end
    for domain, _ in pairs(domains) do self:_saveDomain(domain) end
    return true
end

return RateLimiter
