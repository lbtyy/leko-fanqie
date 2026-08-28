local rapidjson = require("rapidjson")
local logger = require("logger")

local Http = require("Leko/Http")
local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")

-- Leko/Fanqie/FanqieQingtianProvider.lua
--
-- 晴天聚合源 Provider（fanqie:qingtian）。
-- 设计依据：docs/DESIGN-leko-plus.md §T08 + fanqie/client.lua:338-849。
-- 全部方法经 AsyncProviderTask 在子进程内执行；不维护登录态 UI，
-- 服务器地址与 token 由用户在 config.lua 自填（PRD §1.2 合规姿态）。
--
-- 适配点（与 FanqieDahuilangProvider 对称）：
--   1. login_supported=false；服务端鉴权直接用 cookie（qttoken+deviceId）；
--   2. 段评端点使用 /api/fanqie/comment/paragraph/list（移植 client.lua:760-849）；
--   3. 共享 RateLimiter fanqie domain（fanqie:qingtian）；
--   4. content POST /content 与大灰狼格式不同：直接用 bookId/item_id
--      字段名（移植 client.lua:559 qingtian_get_content）。

local QingtianProvider = {
    id = "fanqie:qingtian",
    name = "番茄·晴天",
    capabilities = {
        shelf = false,
        toc = false,
        content = true,
        progress = false,
        review = true,
        login = false,
        probe = true,
    },
}

local MOBILE_UA = "Mozilla/5.0 (Linux; Android 12; KOReader-Aggregation) "
    .. "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

local function rateLimiter()
    return require("Leko/providers/RateLimiter")
end

local function fanqieConfig()
    return require("Leko/Fanqie/FanqieConfig")
end

local function rateLimit()
    local cfg = fanqieConfig():get("qingtian", "rate_limit") or {}
    return tonumber(cfg.max_requests) or 5, tonumber(cfg.window_seconds) or 30
end

local function trimSlash(url)
    return tostring(url or ""):gsub("/+$", "")
end

local function serverUrl()
    local url = trimSlash(fanqieConfig():get("qingtian", "server_url"))
    if url == "" then return nil, "晴天服务器地址未配置（请在 config.lua 中设置 qingtian.server_url）" end
    return url
end

local function authCreds()
    local token = tostring(fanqieConfig():get("qingtian", "token") or "")
    local device_id = tostring(fanqieConfig():get("qingtian", "device_id") or "")
    return token, device_id
end

local function buildCookie(token, device_id, extra)
    local parts = {}
    if token ~= "" then parts[#parts + 1] = "qttoken=" .. token end
    if device_id ~= "" then parts[#parts + 1] = "deviceId=" .. device_id end
    parts[#parts + 1] = "fqpara=on"
    return table.concat(parts, "; ")
end

local function ensureRate()
    local max, window = rateLimit()
    local ok, wait = rateLimiter():check("fanqie:qingtian", max, window)
    if not ok then return nil, string.format("晴天限流：需等待 %.1fs", wait or 0) end
    return true
end

local function parseJson(text)
    if not text or text == "" then return nil end
    local ok, data = pcall(rapidjson.decode, text)
    if ok and type(data) == "table" then return data end
    return nil
end

local function responseError(code, body)
    return string.format("HTTP %s: %s", tostring(code), tostring(body or ""):sub(1, 200))
end

-- ---------------------------------------------------------------------------
-- content op —— 移植 client.lua:559 qingtian_get_content 核心请求
-- ---------------------------------------------------------------------------

local function opContent(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "晴天未配置 token（请在 config.lua 的 qingtian.token 填写）" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "content 参数不完整" end

    local headers = {
        ["User-Agent"] = MOBILE_UA,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = buildCookie(token, device_id),
    }
    local body = rapidjson.encode({
        bookId = book_id,
        item_id = item_id,
    })
    local response, err = Http:request({
        url = base .. "/content?review=1",
        method = "POST",
        headers = headers,
        body = body,
        allow_http_errors = true,
        retries = 1,
    })
    if not response then return nil, tostring(err) end
    if response.code < 200 or response.code >= 300 then
        return nil, responseError(response.code, response.body)
    end
    local data = parseJson(response.body)
    if not data then return nil, "晴天 content 响应非 JSON" end
    local content = tostring(data.content or "")
    if #content < 50 then
        return nil, string.format("晴天正文过短: itemId=%s len=%s", item_id, tostring(#content))
    end
    local FanqieContent = require("Leko/Fanqie/FanqieContent")
    local cleaned = FanqieContent:clean(content, tostring(data.title or ""))
    if cleaned == "" then return nil, "晴天正文清洗后为空" end
    return {
        content = cleaned,
        title = tostring(data.title or ""),
        author = tostring(data.author or ""),
    }, nil
end

-- ---------------------------------------------------------------------------
-- review_index / review_page op —— 移植 client.lua:760-849 + 1516-1588
-- ---------------------------------------------------------------------------

local function opReviewIndex(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "晴天未配置 token" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "review_index 参数不完整" end

    local headers = {
        ["User-Agent"] = MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = buildCookie(token, device_id),
    }
    local response, err = Http:request({
        url = base .. "/content",
        method = "POST",
        headers = headers,
        body = rapidjson.encode({
            bookId = book_id,
            item_id = item_id,
        }),
        allow_http_errors = true,
        retries = 1,
    })
    if not response then return nil, tostring(err) end
    if response.code < 200 or response.code >= 300 then
        return nil, responseError(response.code, response.body)
    end
    local data = parseJson(response.body)
    if not data then return nil, "review_index 响应非 JSON" end
    -- 晴天返回 data_list 嵌套结构：data.data_list[].comment.stat.reply_count
    local index_map = {}
    local data_list = type(data.data) == "table" and type(data.data.data_list) == "table"
        and data.data.data_list or nil
    if data_list then
        for i, item in ipairs(data_list) do
            local count = 0
            if type(item) == "table" then
                if type(item.comment) == "table" then
                    count = tonumber(item.comment.reply_count or item.comment.count)
                        or 0
                end
                if count == 0 and type(item.common) == "table" then
                    count = tonumber(item.common.reply_count or item.common.comment_count) or 0
                end
            end
            if count == 0 and type(item) == "table" and item.stat then
                count = tonumber(item.stat.reply_count) or 0
            end
            index_map[tostring(i)] = count
        end
    end
    return { index = index_map, source = "remote" }, nil
end

local function opReviewPage(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "晴天未配置 token" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    local para_index = math.max(1, tonumber(payload.para_index) or 1)
    local cursor = tostring(payload.cursor or "")

    local headers = {
        ["User-Agent"] = MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = buildCookie(token, device_id),
    }
    local url = string.format("%s/api/fanqie/comment/paragraph/list?book_id=%s&item_id=%s&para_index=%d&cursor=%s",
        base, book_id, item_id, para_index, cursor)
    local response, err = Http:request({
        url = url,
        method = "GET",
        headers = headers,
        allow_http_errors = true,
        retries = 1,
    })
    if not response then return nil, tostring(err) end
    if response.code < 200 or response.code >= 300 then
        return nil, responseError(response.code, response.body)
    end
    local data = parseJson(response.body)
    if not data then return nil, "review_page 响应非 JSON" end
    local data_list = type(data.data) == "table"
        and type(data.data.data_list) == "table" and data.data.data_list or {}
    local items = {}
    for _, item in ipairs(data_list) do
        local comment = type(item) == "table" and item.comment or nil
        if type(comment) == "table" then
            items[#items + 1] = {
                floor = tonumber(comment.floor) or (#items + 1),
                nick = tostring((type(comment.user) == "table" and comment.user.nick)
                    or comment.nick or ""),
                time = tostring(comment.create_time or comment.time or ""),
                text = tostring(comment.content or comment.text or ""),
            }
        end
    end
    local total = tonumber(data.data and data.data.total) or 0
    return {
        items = items,
        has_more = data.data and data.data.has_more == true,
        total = total,
    }, nil
end

local function opProbe(_payload)
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local response, err = Http:request({
        url = base .. "/ping",
        method = "GET",
        timeout = 6,
        allow_http_errors = true,
        retries = 0,
    })
    if response and response.code >= 200 and response.code < 500 then
        return { reachable = true, code = response.code }, nil
    end
    return { reachable = false, code = response and response.code or 0, error = tostring(err) }, nil
end

local OPS = {
    content = opContent,
    review_index = opReviewIndex,
    review_page = opReviewPage,
    probe = opProbe,
}

function QingtianProvider:isEnabled()
    if not FanqieCompliance:isEnabled() then return false end
    local ok, url = pcall(serverUrl)
    return ok and url ~= nil
end

function QingtianProvider:childOp(op, payload)
    if not self:isEnabled() then
        return nil, "晴天源未启用（合规门禁未确认或服务器地址未配置）"
    end
    local handler = OPS[tostring(op or "")]
    if not handler then return nil, "未知晴天操作：" .. tostring(op) end
    return handler(payload or {})
end

function QingtianProvider:logout()
    return true
end

function QingtianProvider:loginSupported()
    return false
end

return QingtianProvider
