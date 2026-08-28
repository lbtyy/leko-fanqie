local rapidjson = require("rapidjson")
local logger = require("logger")

local Http = require("Leko/Http")
local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")

-- Leko/Fanqie/FanqieDahuilangProvider.lua
--
-- 大灰狼聚合源 Provider（fanqie:dahuilang）。
-- 设计依据：docs/DESIGN-leko-plus.md §T08 + fanqie/client.lua:1173-1691。
-- 全部方法经 AsyncProviderTask 在子进程内执行；不维护登录态 UI，
-- 服务器地址与登录 token 由用户在 config.lua 自填（PRD §1.2 合规姿态）。
--
-- 适配点：
--   1. 不复制 fanqie 的 settings/settings 状态机；token/device_id 从
--      FanqieConfig:get("dahuilang", ...) 读取（GUI 不预填，服务器地址
--      也仅来自 config.lua）；
--   2. 与 FanqieQingtianProvider 共享 RateLimiter（5/30s，
--      FanqieConfig:dahuilang.rate_limit 覆盖）；
--   3. 段评为该源核心能力（review=true），其他源 false；
--   4. supplyFanqieContent (沿用 fanqie/client.lua:1412+) 抽离为 content op；
--   5. review_index 从 review=1 mode 抓出的 <comment count="N"> 标签中
--      抽取段索引（移植 client.lua:1516-1588 的提取逻辑）。

local DahuilangProvider = {
    id = "fanqie:dahuilang",
    name = "番茄·大灰狼",
    capabilities = {
        shelf = false,
        toc = false,
        content = true,
        progress = false,
        review = true,
        login = false,      -- config 自管
        probe = true,       -- 多线路检测
    },
}

local MOBILE_UA = "Mozilla/5.0 (Linux; Android 12; KOReader-Aggregation) "
    .. "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

local function aggregationDomain()
    return "fanqie"   -- 与 fanqie:official 共用同一 RateLimiter 文件夹
end

local function rateLimiter()
    return require("Leko/providers/RateLimiter")
end

local function fanqieConfig()
    return require("Leko/Fanqie/FanqieConfig")
end

local function rateLimit()
    local cfg = fanqieConfig():get("dahuilang", "rate_limit") or {}
    return tonumber(cfg.max_requests) or 5, tonumber(cfg.window_seconds) or 30
end

local function trimSlash(url)
    return tostring(url or ""):gsub("/+$", "")
end

local function serverUrl()
    local url = trimSlash(fanqieConfig():get("dahuilang", "server_url"))
    if url == "" then return nil, "大灰狼服务器地址未配置（请在 config.lua 中设置 dahuilang.server_url）" end
    return url
end

local function authCreds()
    local token = tostring(fanqieConfig():get("dahuilang", "token") or "")
    local device_id = tostring(fanqieConfig():get("dahuilang", "device_id") or "")
    return token, device_id
end

local function buildCookie(token, device_id)
    local parts = {}
    if token ~= "" then parts[#parts + 1] = "qttoken=" .. token end
    if device_id ~= "" then parts[#parts + 1] = "deviceId=" .. device_id end
    return table.concat(parts, "; ")
end

local function ensureRate()
    local max, window = rateLimit()
    local ok, wait = rateLimiter():check("fanqie:dahuilang", max, window)
    if not ok then return nil, string.format("大灰狼限流：需等待 %.1fs", wait or 0) end
    return true
end

-- ---------------------------------------------------------------------------
-- 通用 POST 错误检查
-- ---------------------------------------------------------------------------

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
-- content op —— 移植 fanqie/client.lua:1412+ dahuilang_get_content 核心逻辑
-- ---------------------------------------------------------------------------

local function opContent(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "大灰狼未配置 token（请在 config.lua 的 dahuilang.token 填写）" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "content 参数不完整" end
    local source = tostring(fanqieConfig():get("dahuilang", "source") or "番茄")
    local tab = tostring(fanqieConfig():get("dahuilang", "tab") or "小说")

    local headers = {
        ["User-Agent"] = MOBILE_UA,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = buildCookie(token, device_id),
    }
    local body = rapidjson.encode({
        book_id = book_id,
        item_id = item_id,
        source = source,
        tab = tab,
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
    if not data then return nil, "大灰狼 content 响应非 JSON" end
    local content = tostring(data.content or data.data or "")
    if #content < 50 then
        return nil, string.format("大灰狼正文过短: itemId=%s len=%s", item_id, tostring(#content))
    end
    local FanqieContent = require("Leko/Fanqie/FanqieContent")
    local cleaned = FanqieContent:clean(content, tostring(data.title or ""))
    if cleaned == "" then return nil, "大灰狼正文清洗后为空" end
    return {
        content = cleaned,
        title = tostring(data.title or ""),
        author = tostring(data.author or ""),
    }, nil
end

-- ---------------------------------------------------------------------------
-- review_index / review_page op —— 移植 client.lua:1516-1588 + 1601-1691
-- ---------------------------------------------------------------------------

local function extractParaIndex(content)
    -- 移植 content.lua:1532-1554：抽取 <comment count="N"> 段索引
    local out = {}
    if type(content) ~= "string" or content == "" then return out end
    for ident, count in content:gmatch([[<param%s+name=%"comment_.-ident%=%"([^%\"]+)%.%.ident%.%.%d+%.%.([^\"]+)%.%.%d+%.%.(%d+)%.%.([^\"]+)%.%.(%d+)%.%.([^\"]+)\"[^>]*count=\"([^\"]+)\"]])
        do
            -- 简化：保留 ident+count
            out[#out + 1] = { ident = ident, count = tonumber(count) or 0 }
        end
    -- 退化解析：识别任意 comment 标签
    if #out == 0 then
        for raw in content:gmatch([[<comment[^>]*>]]) do
            local ident = raw:match([[ident=([^%s>]+)]])
            local count = raw:match([[count="(%d+)"]])
            if ident then
                out[#out + 1] = { ident = ident, count = tonumber(count) or 0 }
            end
        end
    end
    return out
end

local function opReviewIndex(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "大灰狼未配置 token" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "review_index 参数不完整" end
    local source = tostring(fanqieConfig():get("dahuilang", "source") or "番茄")

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
            book_id = book_id,
            item_id = item_id,
            source = source,
            tab = "小说",
            review = 1,
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
    local content = tostring(data.content or "")
    local extracted = extractParaIndex(content)
    -- 索引按 1-based para 归一化（+1 起点）
    local index_map = {}
    for i, entry in ipairs(extracted) do
        index_map[tostring(i)] = entry.count or 0
    end
    return { index = index_map, source = "remote" }, nil
end

local function opReviewPage(payload)
    local ok, rl_err = ensureRate()
    if not ok then return nil, rl_err end
    local base, srv_err = serverUrl()
    if not base then return nil, srv_err end
    local token, device_id = authCreds()
    if token == "" then return nil, "大灰狼未配置 token" end
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    local para_index = math.max(1, tonumber(payload.para_index) or 1)
    local page = math.max(1, tonumber(payload.page) or 1)
    if book_id == "" or item_id == "" then return nil, "review_page 参数不完整" end
    local cursor = tostring(payload.cursor or "")
    if cursor == "" and page > 1 then cursor = "page=" .. page end

    local headers = {
        ["User-Agent"] = MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = buildCookie(token, device_id),
    }
    local query = string.format("?book_id=%s&item_id=%s&para=%d&cursor=%s",
        book_id, item_id, para_index, cursor)
    local response, err = Http:request({
        url = base .. "/para_review" .. query,
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
    local comments = type(data.comments) == "table" and data.comments or {}
    local items = {}
    for _, c in ipairs(comments) do
        items[#items + 1] = {
            floor = tonumber(c.floor) or (#items + 1),
            nick = tostring(c.nick or c.user_name or ""),
            time = tostring(c.time or c.created_at or ""),
            text = tostring(c.text or c.content or ""),
        }
    end
    return {
        items = items,
        has_more = data.has_more == true,
        total = tonumber(data.total) or #items,
    }, nil
end

-- ---------------------------------------------------------------------------
-- probe op —— 线路可达性检测（移植 client.lua:309 check_servers）
-- ---------------------------------------------------------------------------

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

function DahuilangProvider:isEnabled()
    if not FanqieCompliance:isEnabled() then return false end
    local ok, url = pcall(serverUrl)
    return ok and url ~= nil
end

function DahuilangProvider:childOp(op, payload)
    if not self:isEnabled() then
        return nil, "大灰狼源未启用（合规门禁未确认或服务器地址未配置）"
    end
    local handler = OPS[tostring(op or "")]
    if not handler then return nil, "未知大灰狼操作：" .. tostring(op) end
    return handler(payload or {})
end

function DahuilangProvider:logout()
    return true
end

-- 把 login_supported 显式置 false（设计文档：聚合源不在 UI 提供登录入口）
function DahuilangProvider:loginSupported()
    return false
end

-- 标记聚合域分类，供 ProviderRegistry/限流器共用同一文件夹
function DahuilangProvider:aggregationDomain()
    return aggregationDomain()
end

return DahuilangProvider
