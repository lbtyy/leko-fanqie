local socket = require("socket")
local socket_url = require("socket.url")
local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager then UIManager = {} end

local Http = require("Leko/Http")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local SourceHealth = {
    online_ttl = 6 * 60 * 60,
    offline_ttl = 15 * 60,
    probe_timeout = 2,
    probe_maxtime = 3,
    flush_delay = 20,
    _flush_callback = nil,
}

local function isTransportReachable(record)
    if type(record) ~= "table" then return false end
    if record.transport_state then return record.transport_state == "reachable" end
    return record.status == "online"
end

local function copy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

local function httpUrl(value)
    value = Util.trim(tostring(value or ""))
    local found = value:match("(https?://[^%s%}%]%\"']+)")
    if found then value = found end
    if not value:match("^https?://") then return nil end
    return value
end

function SourceHealth:probeUrl(source)
    if not source then return nil end
    -- Prefer the actual search endpoint host. Some imported rules use a
    -- homepage on one host and an API/search endpoint on another.
    local search = source.search_url
    if type(search) == "table" then search = search.url or search[1] end
    search = httpUrl(search)
    if search then
        local parsed = socket_url.parse(search)
        if parsed and parsed.scheme and parsed.host then
            local authority = parsed.host
            if parsed.port then authority = authority .. ":" .. tostring(parsed.port) end
            return parsed.scheme .. "://" .. authority .. "/"
        end
        return search
    end
    return httpUrl(source.base_url)
end

function SourceHealth:get(source_id)
    return Storage:getSourceHealth(source_id)
end

function SourceHealth:age(record, now)
    if type(record) ~= "table" then return math.huge end
    now = tonumber(now or os.time()) or os.time()
    return math.max(0, now - (tonumber(record.checked_at or 0) or 0))
end

function SourceHealth:cachedDecision(source, now, health_map)
    if not source or not source.id then return nil, nil end
    local record = health_map and health_map[tostring(source.id)] or self:get(source.id)
    if type(record) ~= "table" then return nil, nil end
    local ttl = isTransportReachable(record) and self.online_ttl or self.offline_ttl
    if self:age(record, now) > ttl then return nil, record end
    return isTransportReachable(record), record
end

function SourceHealth:isNetworkError(err)
    local text = tostring(err or ""):lower()
    if text == "" then return false end
    local markers = {
        "timeout", "timed out", "network", "resolve", "dns", "host not found",
        "connection", "connect failed", "ssl", "handshake", "closed", "unreachable",
        "refused", "reset by peer", "no route", "temporary failure",
        "超时", "网络", "解析", "连接", "无法访问", "不可达",
    }
    for _, marker in ipairs(markers) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

function SourceHealth:record(source, status, latency_ms, code, err, probe_url)
    local numeric_code = tonumber(code)
    local transport_state = numeric_code and numeric_code >= 400
        and "http_rejected" or (status == "online" and "reachable" or "failed")
    return {
        source_id = source and tostring(source.id or "") or "",
        source_name = source and tostring(source.name or "") or "",
        status = status == "online" and "online" or "offline",
        latency_ms = latency_ms and math.max(0, math.floor(tonumber(latency_ms) or 0)) or nil,
        http_code = numeric_code,
        transport_state = transport_state,
        error = err and tostring(err) or nil,
        probe_url = tostring(probe_url or self:probeUrl(source) or ""),
        checked_at = os.time(),
    }
end


local activity_keys = {
    "search_attempts", "search_hits", "exact_hits", "search_failures",
    "selected_count", "last_hit_at", "last_selected_at",
}

function SourceHealth:withSearchActivity(record, previous, activity)
    local merged = copy(record or previous or {})
    previous = previous or {}
    activity = activity or {}
    for _, key in ipairs(activity_keys) do
        if merged[key] == nil and previous[key] ~= nil then merged[key] = previous[key] end
    end
    if activity.attempted then
        merged.search_attempts = (tonumber(merged.search_attempts or 0) or 0) + 1
        if activity.hit then
            merged.search_hits = (tonumber(merged.search_hits or 0) or 0) + 1
            merged.last_hit_at = os.time()
            if activity.exact then
                merged.exact_hits = (tonumber(merged.exact_hits or 0) or 0) + 1
            end
        elseif activity.failed then
            merged.search_failures = (tonumber(merged.search_failures or 0) or 0) + 1
        end
    end
    return merged
end

function SourceHealth:scheduleFlush(delay)
    if self._flush_callback then
        pcall(UIManager.unschedule, UIManager, self._flush_callback)
        self._flush_callback = nil
    end
    local callback
    callback = function()
        if self._flush_callback ~= callback then return end
        self._flush_callback = nil
        pcall(Storage.flushSourceHealth, Storage)
    end
    self._flush_callback = callback
    if type(UIManager.scheduleIn) == "function" then
        UIManager:scheduleIn(math.max(1, tonumber(delay or self.flush_delay) or self.flush_delay), callback)
    else
        callback()
    end
    return true
end

function SourceHealth:flushNow()
    if self._flush_callback then
        pcall(UIManager.unschedule, UIManager, self._flush_callback)
        self._flush_callback = nil
    end
    return Storage:flushSourceHealth()
end

function SourceHealth:markSelected(source_id, source_name)
    source_id = tostring(source_id or "")
    if source_id == "" then return false, "missing source id" end
    local record = copy(Storage:getSourceHealth(source_id) or {})
    record.source_id = source_id
    record.source_name = tostring(source_name or record.source_name or "")
    record.selected_count = (tonumber(record.selected_count or 0) or 0) + 1
    record.last_selected_at = os.time()
    -- A selection event must not make an old connectivity result look fresh.
    if record.checked_at == nil then record.checked_at = 0 end
    local ok, err = Storage:setSourceHealth(source_id, record)
    if not ok then return ok, err end
    self:scheduleFlush(12)
    return true
end

function SourceHealth:activityLabel(record)
    if type(record) ~= "table" then return nil end
    local selected = tonumber(record.selected_count or 0) or 0
    local hits = tonumber(record.search_hits or 0) or 0
    local attempts = tonumber(record.search_attempts or 0) or 0
    if selected > 0 then return "常用 " .. tostring(selected) .. "次" end
    if attempts > 0 then return "命中 " .. tostring(hits) .. "/" .. tostring(attempts) end
    return nil
end

function SourceHealth:probe(source, options)
    options = options or {}
    local target = self:probeUrl(source)
    if not target then
        return self:record(source, "offline", nil, nil, "没有可探测的 HTTP 地址", "")
    end

    local started = socket.gettime and socket.gettime() or os.time()
    local timeout = tonumber(options.timeout or self.probe_timeout) or self.probe_timeout
    local maxtime = tonumber(options.maxtime or self.probe_maxtime) or self.probe_maxtime
    local headers = copy(source and source.header)
    headers["range"] = headers["range"] or "bytes=0-0"
    headers["accept"] = headers["accept"] or "*/*"

    -- HEAD is cheap when supported. A server returning any HTTP status is reachable,
    -- even if it rejects HEAD with 403/405. Only transport-level failure falls back to GET.
    local response, err = Http:request{
        url = target,
        method = "HEAD",
        headers = headers,
        timeout = timeout,
        maxtime = maxtime,
        retries = 0,
        max_redirects = 2,
        max_bytes = 4096,
        discard_body = true,
        allow_http_errors = true,
    }
    if not response or tonumber(response.code or 0) >= 500 then
        response, err = Http:request{
            url = target,
            method = "GET",
            headers = headers,
            timeout = timeout,
            maxtime = maxtime,
            retries = 0,
            max_redirects = 2,
            max_bytes = 32 * 1024,
            discard_body = true,
            allow_http_errors = true,
        }
    end
    local finished = socket.gettime and socket.gettime() or os.time()
    local latency = math.floor(math.max(0, finished - started) * 1000 + 0.5)
    if response then
        local code = tonumber(response.code or 0) or 0
        if code >= 500 then
            return self:record(source, "offline", latency, code,
                "HTTP " .. tostring(code) .. "（服务暂不可用）", target)
        end
        local detail
        if code >= 400 then detail = "HTTP " .. tostring(code) .. "（服务器可连接）" end
        return self:record(source, "online", latency, code, detail, target)
    end
    return self:record(source, "offline", latency, nil, tostring(err or "连接失败"), target)
end

function SourceHealth:ensure(source, options)
    options = options or {}
    if not options.force then
        local decision, record = self:cachedDecision(source, options.now, options.health_map)
        if decision ~= nil then return decision, record, false end
    end
    local record = self:probe(source, options)
    return isTransportReachable(record), record, true
end

function SourceHealth:save(record)
    if type(record) ~= "table" or tostring(record.source_id or "") == "" then return false end
    return Storage:setSourceHealth(record.source_id, record)
end

function SourceHealth:saveBatch(records)
    if type(records) ~= "table" then return false end
    if Storage.setSourceHealthBatch then return Storage:setSourceHealthBatch(records) end
    for _, record in ipairs(records) do self:save(record) end
    return true
end

function SourceHealth:shortLabel(record, now)
    if type(record) ~= "table" then return "未测试" end
    local stale = self:age(record, now) > (record.status == "online" and self.online_ttl or self.offline_ttl)
    local prefix = stale and "旧·" or ""
    if record.transport_state == "http_rejected" then
        local code = tonumber(record.http_code)
        return prefix .. "HTTP 拒绝" .. (code and (" " .. tostring(code)) or "")
    end
    if record.status == "online" then
        local ms = tonumber(record.latency_ms)
        if ms then return prefix .. "请求成功 " .. tostring(ms) .. "ms" end
        return prefix .. "请求成功"
    end
    local err = tostring(record.error or "离线")
    local lower = err:lower()
    if lower:find("timeout", 1, true) or err:find("超时", 1, true) then return prefix .. "超时" end
    if lower:find("resolve", 1, true) or lower:find("dns", 1, true) or err:find("解析", 1, true) then
        return prefix .. "找不到网站"
    end
    return prefix .. "不可连接"
end

function SourceHealth:detailText(record)
    if type(record) ~= "table" then return "尚未测试连通性" end
    local lines = {}
    local transport = record.transport_state == "http_rejected" and "网站拒绝访问或要求验证"
        or (record.status == "online" and "请求成功" or "连接失败")
    lines[#lines + 1] = "连接结果：" .. transport
    if record.latency_ms then lines[#lines + 1] = "耗时：" .. tostring(record.latency_ms) .. " ms" end
    if record.http_code then lines[#lines + 1] = "HTTP：" .. tostring(record.http_code) end
    if record.error then lines[#lines + 1] = "说明：" .. tostring(record.error) end
    if record.probe_url and record.probe_url ~= "" then
        lines[#lines + 1] = "检查地址：" .. tostring(record.probe_url)
    end
    lines[#lines + 1] = "检测时间：" .. os.date("%Y-%m-%d %H:%M:%S", tonumber(record.checked_at or 0) or 0)
    return table.concat(lines, "\n")
end

return SourceHealth
