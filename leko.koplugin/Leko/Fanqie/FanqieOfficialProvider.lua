local rapidjson = require("rapidjson")
local koreader_util = require("util")
local logger = require("logger")

local Http = require("Leko/Http")
local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")

-- Leko/Fanqie/FanqieOfficialProvider.lua
--
-- 番茄官方源 Provider：shelf / toc / content / progress 四阶段 + 扫码登录三 op。
-- 全部方法经 AsyncProviderTask 在子进程内执行（childOp 为唯一入口）。
-- 移植自 fanqie/client.lua:908-1164（get_json/fetch_shelf_detail/
-- fetch_chapter_directory/official_get_content/update_read_progress）、
-- fanqie/fanqie.lua:5-64（URL 构造）、fanqie/qrlogin.lua:122-490（登录 HTTP）、
-- fanqie/content.lua:889-1002（目录规范化），适配点：
--   1. HTTP 改走 leko Http.lua（含 follow_redirects=false 支持，
--      check_qrconnect 的 302 Set-Cookie 不再丢失）；
--   2. Cookie 读写改走 FanqieAuth（数组形式），子进程内不持久化，
--      登录成功由 UI 线程统一落盘；
--   3. 鉴权失败统一映射 AUTH_EXPIRED（移植 client.lua:52-82 is_auth_error），
--      UI 侧提示重新扫码而非静默。

local BASE_URL = "https://fanqienovel.com"
local FANQIE_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
-- 移植 qrlogin.lua:67-68
local FANQIE_LOGIN_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"

-- 移植 qrlogin.lua:64-66
local LOGIN_PAGE = BASE_URL .. "/main/writer/login"
local GET_QRCODE_URL = BASE_URL .. "/passport/web/get_qrcode/"
local CHECK_QR_URL = BASE_URL .. "/passport/web/check_qrconnect/"

-- 移植 qrlogin.lua:73-79
local COMMON_PARAMS = {
    passport_jssdk_version = "3.0.16",
    passport_jssdk_type = "normal",
    aid = "2503",
    language = "zh",
    account_sdk_source = "web",
}

-- 移植 fanqie/fanqie.lua:29-36 make_shelf_params
local function makeShelfParams()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

-- 移植 fanqie/fanqie.lua:38-60 的 URL 构造器
local function shelfUrl() return BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/" end
local function bookshelfMultidetailUrl() return BASE_URL .. "/api/bookshelf/multidetail" end
local function progressUrl() return BASE_URL .. "/api/reader/book/progress" end
local function updateProgressUrl() return BASE_URL .. "/api/reader/book/update_progress" end
local function directoryUrl(book_id)
    return BASE_URL .. "/api/reader/directory/detail?bookId=" .. koreader_util.urlEncode(tostring(book_id))
end
local function chapterContentUrl(book_id, item_id)
    return BASE_URL .. "/api/reader/chapter/content?book_id=" .. koreader_util.urlEncode(tostring(book_id))
        .. "&item_id=" .. koreader_util.urlEncode(tostring(item_id))
end
-- 移植 fanqie/fanqie.lua:62-64 reader_url
local function readerUrl(item_id) return BASE_URL .. "/reader/" .. tostring(item_id) end

local function urlEncode(value)
    return koreader_util.urlEncode(tostring(value))
end

-- 移植 qrlogin.lua:102-109 build_query
local function buildQuery(params)
    local parts = {}
    for key, value in pairs(params) do
        parts[#parts + 1] = tostring(key) .. "=" .. urlEncode(value)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

-- 移植 fanqie/content.lua:889-901 to_precise_id，适配点：无。
-- JSON 大整数（19 位 book_id）经 rapidjson 解码为 double 后有精度风险，
-- 统一用 %.0f 格式化，避免 tostring 产生科学计数法。
local function toPreciseId(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    if type(value) == "number" then
        return string.format("%.0f", value)
    end
    return tostring(value)
end

local FanqieOfficialProvider = {
    id = "fanqie:official",
    name = "番茄·官方",
    capabilities = {
        shelf = true,
        toc = true,
        content = true,
        progress = true,
        review = false,
        login = true,
        probe = false,
    },
}

function FanqieOfficialProvider:isEnabled()
    return FanqieCompliance:isEnabled()
end

-- ---------------------------------------------------------------------------
-- Cookie 工具（数组形式贯穿，规避 rapidjson 丢字符串 key）
-- ---------------------------------------------------------------------------

local function arrayToMap(array)
    local map = {}
    for _, entry in ipairs(array or {}) do
        if type(entry) == "table" and entry.name and entry.value ~= nil then
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

-- 移植 fanqie/cookie.lua:33-40 to_header
local function mapToHeader(map)
    local parts = {}
    for key, value in pairs(map or {}) do
        parts[#parts + 1] = key .. "=" .. value
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

-- 移植 fanqie/cookie.lua:46-51 SET_COOKIE_ATTRS
local SET_COOKIE_ATTRS = {
    ["path"] = true, ["domain"] = true, ["expires"] = true, ["max-age"] = true,
    ["secure"] = true, ["httponly"] = true, ["samesite"] = true,
    ["priority"] = true, ["partitioned"] = true, ["comment"] = true,
    ["version"] = true, ["discard"] = true,
}

-- 移植 fanqie/cookie.lua:53-91 merge_set_cookie
local function mergeSetCookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then return cookies end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            mergeSetCookie(cookies, value)
        end
        return cookies
    end
    local sc = tostring(set_cookie)
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

-- 移植 qrlogin.lua:112-117 extract_csrf
local function extractCsrf(map)
    local value = map and map["passport_csrf_token"]
    if value and value ~= "" then return value end
    return ""
end

local function authModule()
    return require("Leko/Fanqie/FanqieAuth")
end

-- ---------------------------------------------------------------------------
-- 鉴权错误识别（移植 fanqie/client.lua:52-82 is_auth_error / AUTH_ERROR_CODES）
-- ---------------------------------------------------------------------------

local AUTH_ERROR_CODES = {
    [-2012] = true,
    [-2041] = true,
}

local function isAuthError(code, text, headers)
    if code == 401 or code == 403 then return true end
    text = tostring(text or "")
    local content_type = tostring(headers and headers["content-type"] or "unknown")
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(rapidjson.decode, text)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            if AUTH_ERROR_CODES[err_code] then return true end
            local err_message = data.errMsg or data.errmsg or data.message or data.msg or ""
            if tostring(err_message):find("登录", 1, true) then return true end
        end
    end
    return false
end

-- 移植 fanqie/client.lua:84-115 http_error
local function httpError(code, text, headers)
    text = tostring(text or "")
    local parts = {
        "HTTP " .. tostring(code),
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = text:match("^%s*{") ~= nil or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(rapidjson.decode, text)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then parts[#parts + 1] = "error_code=" .. tostring(err_code) end
            if err_message ~= nil then
                parts[#parts + 1] = "error_message=" .. tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function authExpired(message)
    return nil, { code = "AUTH_EXPIRED", message = "番茄登录态已过期，请重新扫码登录（" .. tostring(message) .. "）" }
end

-- ---------------------------------------------------------------------------
-- HTTP 封装（子进程内执行；leko Http 统一传输层）
-- ---------------------------------------------------------------------------

-- 登录流程专用 GET（移植 qrlogin.lua:122-163 http_get）。
-- opts.no_redirect = true 时 2xx/3xx 都视为有效响应（保留 302 的 Set-Cookie）。
local function loginHttpGet(url, cookie_map, csrf, opts)
    opts = opts or {}
    local headers = {
        ["user-agent"] = FANQIE_LOGIN_UA,
        ["accept"] = "application/json, text/javascript, text/html, */*",
        ["accept-language"] = "zh-CN,zh;q=0.9",
        ["referer"] = LOGIN_PAGE,
        ["sec-fetch-dest"] = "empty",
        ["sec-fetch-mode"] = "cors",
        ["sec-fetch-site"] = "same-origin",
    }
    if cookie_map and next(cookie_map) ~= nil then
        headers["cookie"] = mapToHeader(cookie_map)
    end
    if csrf and csrf ~= "" then
        headers["x-tt-passport-csrf-token"] = csrf
    end
    local response, err = Http:request({
        url = url,
        method = "GET",
        headers = headers,
        timeout = 15,
        follow_redirects = opts.no_redirect and false or nil,
        allow_http_errors = opts.no_redirect == true,
        retries = 0,
    })
    if not response then return nil, tostring(err or "网络请求失败") end
    if opts.no_redirect then
        if response.code < 200 or response.code >= 400 then
            return nil, "HTTP " .. tostring(response.code)
        end
    end
    return response, nil
end

-- 业务 API GET JSON（移植 fanqie/client.lua:908-945 get_json）。
-- cookie_map 由调用方提供（扫码会话或 FanqieAuth 持久化账号）。
-- 返回 json_table, err；并带回合并 Set-Cookie 后的新 cookie_map。
local function apiGetJson(url, cookie_map)
    local headers = {
        ["user-agent"] = FANQIE_UA,
        ["accept"] = "application/json, text/plain, */*",
        ["referer"] = BASE_URL .. "/",
    }
    if cookie_map and next(cookie_map) ~= nil then
        headers["cookie"] = mapToHeader(cookie_map)
    end
    local response, err = Http:request({
        url = url,
        method = "GET",
        headers = headers,
        allow_http_errors = true,
        retries = 1,
    })
    if not response then return nil, tostring(err or "网络请求失败"), cookie_map end
    local new_map = mergeSetCookie(cookie_map, response.headers and response.headers["set-cookie"])
    if response.code < 200 or response.code >= 300 then
        local detail = httpError(response.code, response.body, response.headers)
        if isAuthError(response.code, response.body, response.headers) then
            local _, auth_err = authExpired(detail)
            return nil, auth_err, new_map
        end
        return nil, "GET 失败：" .. detail, new_map
    end
    local ok, data = pcall(rapidjson.decode, response.body or "")
    if not ok or type(data) ~= "table" then
        return nil, "响应非 JSON：" .. tostring(response.body or ""):sub(1, 200), new_map
    end
    return data, nil, new_map
end

-- 业务 API POST JSON（移植 fanqie/client.lua:865-906 post_json 语义）。
local function apiPostJson(url, body_table, cookie_map)
    local headers = {
        ["user-agent"] = FANQIE_UA,
        ["accept"] = "application/json, text/plain, */*",
        ["referer"] = BASE_URL .. "/",
        ["content-type"] = "application/json",
    }
    if cookie_map and next(cookie_map) ~= nil then
        headers["cookie"] = mapToHeader(cookie_map)
    end
    local body = rapidjson.encode(body_table or {})
    local response, err = Http:request({
        url = url,
        method = "POST",
        headers = headers,
        body = body,
        allow_http_errors = true,
        retries = 1,
    })
    if not response then return nil, tostring(err or "网络请求失败"), cookie_map end
    local new_map = mergeSetCookie(cookie_map, response.headers and response.headers["set-cookie"])
    if response.code < 200 or response.code >= 300 then
        local detail = httpError(response.code, response.body, response.headers)
        if isAuthError(response.code, response.body, response.headers) then
            local _, auth_err = authExpired(detail)
            return nil, auth_err, new_map
        end
        return nil, "POST 失败：" .. detail, new_map
    end
    local ok, data = pcall(rapidjson.decode, response.body or "")
    if not ok or type(data) ~= "table" then
        return nil, "响应非 JSON：" .. tostring(response.body or ""):sub(1, 200), new_map
    end
    return data, nil, new_map
end

-- ---------------------------------------------------------------------------
-- 扫码登录三 op（移植 fanqie/qrlogin.lua:221-490 的子进程部分）
-- ---------------------------------------------------------------------------

-- 移植 qrlogin.lua:221-262 _begin 的子进程部分（预热 cookie + get_qrcode）。
local function opQrCreate()
    local response, err = loginHttpGet(LOGIN_PAGE, nil, nil)
    if not response then return nil, "登录页预热失败：" .. tostring(err) end
    local jar = mergeSetCookie({}, response.headers and response.headers["set-cookie"])
    local csrf = extractCsrf(jar)

    local params = {}
    for key, value in pairs(COMMON_PARAMS) do params[key] = value end
    params["need_logo"] = "true"
    params["next"] = LOGIN_PAGE
    local qr_url = GET_QRCODE_URL .. "?" .. buildQuery(params)
    local qr_response, qr_err = loginHttpGet(qr_url, jar, csrf)
    if not qr_response then return nil, "获取二维码失败：" .. tostring(qr_err) end
    jar = mergeSetCookie(jar, qr_response.headers and qr_response.headers["set-cookie"])
    csrf = extractCsrf(jar)

    local ok, data = pcall(rapidjson.decode, qr_response.body or "")
    if not ok or type(data) ~= "table" then return nil, "二维码响应非 JSON" end
    if data.message ~= "success" then
        return nil, "接口返回: " .. tostring(data.message)
    end
    local d = data.data or {}
    local token = d.token or ""
    local qr_index_url = d.qrcode_index_url or ""
    if token == "" or qr_index_url == "" then
        return nil, "二维码数据不完整"
    end
    return {
        token = token,
        qr_url = qr_index_url,
        cookies = mapToArray(jar),
        csrf = csrf,
        expire_time = tonumber(d.expire_time) or 0,
    }, nil
end

-- 移植 qrlogin.lua:301-370 _schedule 的子进程部分。
-- 关键：禁用自动重定向——check_qrconnect 确认后返回 302 + Set-Cookie(sessionid)，
-- 跟随重定向会丢弃 302 的 Set-Cookie（对应 Python 后端的 allow_redirects=False）。
local function opQrPoll(payload)
    local jar = arrayToMap(payload.cookies)
    local csrf = tostring(payload.csrf or "")
    local params = {}
    for key, value in pairs(COMMON_PARAMS) do params[key] = value end
    params["token"] = tostring(payload.token or "")
    params["next"] = "/"
    local url = CHECK_QR_URL .. "?" .. buildQuery(params)
    local response, err = loginHttpGet(url, jar, csrf, { no_redirect = true })
    if not response then return nil, tostring(err) end
    local new_jar = mergeSetCookie(jar, response.headers and response.headers["set-cookie"])
    local has_sessionid = new_jar.sessionid and new_jar.sessionid ~= ""

    -- 响应已带回 sessionid：直接成功，无需解析 JSON
    if has_sessionid then
        return {
            status = "success",
            cookies = mapToArray(new_jar),
            has_sessionid = true,
            redirect_url = "",
        }, nil
    end

    local data
    local text = response.body or ""
    if #text > 0 then
        local ok, parsed = pcall(rapidjson.decode, text)
        if ok and type(parsed) == "table" then data = parsed end
    end
    if not data then
        -- 3xx 重定向但无 sessionid：中间跳转，记录 location 继续轮询
        return {
            status = "redirect",
            cookies = mapToArray(new_jar),
            has_sessionid = false,
            redirect_url = tostring(response.headers and response.headers.location or ""),
        }, nil
    end
    local d = data.data or {}
    return {
        status = tostring(d.status or ""),
        error_code = d.error_code,
        cookies = mapToArray(new_jar),
        has_sessionid = false,
        redirect_url = tostring(d.redirect_url or ""),
    }, nil
end

-- 移植 qrlogin.lua:425-470 _finish_with_redirect 的子进程部分。
-- 手动逐跳跟随重定向：socket.http 自动重定向不传递 Cookie 也不合并中间
-- Set-Cookie，必须手动处理才能在任意一跳拿到 sessionid。
local function opQrFinish(payload)
    local jar = arrayToMap(payload.cookies)
    local csrf = tostring(payload.csrf or "")
    local url = tostring(payload.redirect_url or "")
    if url == "" then return nil, "redirect_url 为空" end
    local max_redirects = 5

    for _ = 1, max_redirects + 1 do
        local response, err = loginHttpGet(url, jar, csrf, { no_redirect = true })
        if not response then return nil, tostring(err) end
        jar = mergeSetCookie(jar, response.headers and response.headers["set-cookie"])
        if jar.sessionid and jar.sessionid ~= "" then
            return { cookies = mapToArray(jar), has_sessionid = true }, nil
        end
        local location = response.headers and response.headers.location
        if not location or location == "" then
            local has_sid = jar.sessionid and jar.sessionid ~= ""
            return { cookies = mapToArray(jar), has_sessionid = has_sid == true }, nil
        end
        -- 处理相对路径 location
        if not location:match("^https?://") then
            local scheme, host = url:match("^(https?)://([^/]+)")
            if scheme then
                if location:sub(1, 1) == "/" then
                    location = scheme .. "://" .. host .. location
                else
                    local prefix = url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
                    location = prefix .. location
                end
            end
        end
        url = location
    end
    return nil, "重定向次数超限(" .. max_redirects .. ")，未获取到 sessionid"
end

-- ---------------------------------------------------------------------------
-- 业务四阶段（移植 fanqie/client.lua:1018-1164）
-- ---------------------------------------------------------------------------

-- 移植 client.lua:1018-1026 fetch_shelf_info
local function fetchShelfInfo(cookie_map)
    local params = makeShelfParams()
    local parts = {}
    for key, value in pairs(params) do
        parts[#parts + 1] = key .. "=" .. urlEncode(value)
    end
    return apiGetJson(shelfUrl() .. "?" .. table.concat(parts, "&"), cookie_map)
end

-- 移植 client.lua:1109-1111 fetch_read_progress
local function fetchReadProgress(cookie_map)
    return apiGetJson(progressUrl(), cookie_map)
end

-- 移植 client.lua:1041-1107 fetch_shelf_detail，适配点：
-- fanqie 的 SHELF_CACHE 内存短缓存不移植（每次同步都拉新；两层缓存语义
-- 由 FanqieShelfService + leko per-book 存储承担）；id 统一 toPreciseId。
local function opShelf()
    local cookie_map = authModule():getCookieMap()
    local shelf_info, err, new_map = fetchShelfInfo(cookie_map)
    if not shelf_info then return nil, err end
    cookie_map = new_map or cookie_map
    if type(shelf_info) ~= "table" or type(shelf_info.data) ~= "table" then
        return { books = {}, cookies = mapToArray(cookie_map) }, nil
    end
    local book_shelf_info = shelf_info.data.book_shelf_info
        or shelf_info.data.bookShelfInfo or shelf_info.data
    if type(book_shelf_info) ~= "table" or #book_shelf_info == 0 then
        return { books = {}, cookies = mapToArray(cookie_map) }, nil
    end

    local shelf_book_ids = {}
    for _, item in ipairs(book_shelf_info) do
        local book_id = toPreciseId(item.book_id)
        if book_id then shelf_book_ids[#shelf_book_ids + 1] = book_id end
    end

    local progress_result, progress_err, progress_map_cookies = fetchReadProgress(cookie_map)
    if progress_map_cookies then cookie_map = progress_map_cookies end
    local progress_map = {}
    if progress_result and type(progress_result.data) == "table" then
        for _, item in ipairs(progress_result.data) do
            local book_id = toPreciseId(item.book_id)
            if book_id then
                progress_map[book_id] = {
                    read_progress = item.read_progress,
                    index = item.index,
                    item_id = toPreciseId(item.item_id),
                }
            end
        end
    else
        logger.dbg("Leko FanqieOfficial: progress fetch failed:", tostring(progress_err))
    end

    local books_arg = {}
    for _, book_id in ipairs(shelf_book_ids) do
        local progress = progress_map[book_id]
        books_arg[#books_arg + 1] = {
            book_id = book_id,
            item_id = (progress and progress.item_id) or "0",
        }
    end
    local detail_result, detail_err, detail_cookies =
        apiPostJson(bookshelfMultidetailUrl(), { books = books_arg }, cookie_map)
    if detail_cookies then cookie_map = detail_cookies end
    if not detail_result then return nil, detail_err end

    local books = {}
    local detail_list = detail_result.data and detail_result.data.detail_list or {}
    for _, item in ipairs(detail_list) do
        -- 移植 fanqie/bookshelf.lua:323-333 的字段选择
        local book_id = toPreciseId(item.book_id or item.bookId or item.id)
        if book_id then
            local progress = progress_map[book_id]
            books[#books + 1] = {
                provider_book_id = book_id,
                title = tostring(item.book_name or item.title or item.name or "未知"),
                author = tostring(item.author_name or item.author or ""),
                cover_url = item.thumb_url or item.coverUrl or item.cover or item.cover_url,
                abstract = tostring(item.description or item.desc or item.abstract or ""),
                last_chapter = tonumber(item.serial_count or item.total_chapters or 0) or 0,
                last_read_ts = tonumber(item.last_read_ts or 0) or 0,
                item_id = progress and progress.item_id or nil,
                read_progress = progress and progress.read_progress or nil,
            }
        end
    end
    return { books = books, cookies = mapToArray(cookie_map) }, nil
end

-- 移植 fanqie/content.lua:904-920 fix_chapter_ids（依赖 to_precise_id）
local function fixChapterIds(chapter)
    if type(chapter) ~= "table" then return chapter end
    local fixed = {}
    for key, value in pairs(chapter) do
        if key == "itemId" or key == "item_id" or key == "bookId" or key == "book_id" then
            fixed[key] = toPreciseId(value) or value
        else
            fixed[key] = value
        end
    end
    return fixed
end

-- 移植 fanqie/content.lua:922-984 normalize_chapters，适配点：无。
local function normalizeChapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then return {} end
    -- 官方 API 的 chapterListWithVolume 是二维数组：[[ch1, ch2, ...], [ch101, ...]]
    if type(records.chapterListWithVolume) == "table" then
        local flattened = {}
        for _, volume in ipairs(records.chapterListWithVolume) do
            if type(volume) == "table" then
                for _, chapter in ipairs(volume) do
                    if type(chapter) == "table" and chapter.itemId then
                        flattened[#flattened + 1] = fixChapterIds(chapter)
                    end
                end
            end
        end
        if #flattened > 0 then return flattened end
    end
    if type(records.chapterList) == "table" then
        local out = {}
        for _, chapter in ipairs(records.chapterList) do
            out[#out + 1] = fixChapterIds(chapter)
        end
        return out
    end
    if type(records.allItemIds) == "table" and #records.allItemIds > 0 then
        local chapters = {}
        for index, item_id in ipairs(records.allItemIds) do
            chapters[#chapters + 1] = {
                itemId = toPreciseId(item_id) or tostring(item_id),
                title = "第" .. tostring(index) .. "章",
                index = index - 1,
            }
        end
        return chapters
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            local list = record.updated or record.chapterInfos or record.chapters
                or record.item_list or record.list or record.chapterList or {}
            local out = {}
            for _, chapter in ipairs(list) do
                out[#out + 1] = fixChapterIds(chapter)
            end
            return out
        end
    end
    return records
end

-- 移植 fanqie/content.lua:994-1002 readable_chapters（跳过"封面"伪章节）
local function readableChapters(chapters)
    local out = {}
    for _, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            out[#out + 1] = chapter
        end
    end
    return out
end

-- 移植 client.lua:1124-1139 fetch_chapter_directory + content.lua 目录规范化。
-- 输出与 leko book.chapters 同构：{ id=item_id, title, url=reader_url }
local function opToc(payload)
    local book_id = tostring(payload.provider_book_id or "")
    if book_id == "" then return nil, "provider_book_id 为空" end
    local cookie_map = authModule():getCookieMap()
    local result, err = apiGetJson(directoryUrl(book_id), cookie_map)
    if not result then return nil, err end
    if result.code ~= 0 or not result.data then
        return nil, "官方 API 获取目录失败: code=" .. tostring(result.code)
            .. " message=" .. tostring(result.message or "")
    end
    local normalized = readableChapters(normalizeChapters(result, book_id))
    local chapters = {}
    for _, chapter in ipairs(normalized) do
        local item_id = toPreciseId(chapter.itemId or chapter.item_id)
        if item_id then
            chapters[#chapters + 1] = {
                id = item_id,
                title = tostring(chapter.title or ("第" .. tostring(#chapters + 1) .. "章")),
                url = readerUrl(item_id),
            }
        end
    end
    if #chapters == 0 then return nil, "目录为空" end
    return { chapters = chapters }, nil
end

-- 移植 client.lua:1143-1164 official_get_content + FanqieContent 清洗。
local function opContent(payload)
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "正文参数不完整" end
    local cookie_map = authModule():getCookieMap()
    local result, err = apiGetJson(chapterContentUrl(book_id, item_id), cookie_map)
    if not result then return nil, err end
    if type(result) ~= "table" or type(result.data) ~= "table" then
        return nil, "官方API响应格式异常: itemId=" .. item_id
    end
    local raw = result.data.content or ""
    if #raw <= 50 then
        return nil, string.format("官方API返回内容过短: itemId=%s, 长度=%s", item_id, tostring(#raw))
    end
    local FanqieContent = require("Leko/Fanqie/FanqieContent")
    local cleaned = FanqieContent:clean(raw, result.data.title or payload.chapter_title or "")
    if cleaned == "" then
        return nil, "正文清洗后为空: itemId=" .. item_id
    end
    return {
        content = cleaned,
        title = tostring(result.data.title or payload.chapter_title or ""),
        author = tostring(result.data.author or ""),
    }, nil
end

-- 移植 client.lua:1109-1111（单书进度提取）。
local function opProgress(payload)
    local book_id = tostring(payload.provider_book_id or "")
    local cookie_map = authModule():getCookieMap()
    local result, err = fetchReadProgress(cookie_map)
    if not result then return nil, err end
    if type(result.data) ~= "table" then return nil, "进度响应格式异常" end
    for _, item in ipairs(result.data) do
        if toPreciseId(item.book_id) == book_id then
            return {
                progress = {
                    item_id = toPreciseId(item.item_id),
                    index = tonumber(item.index) or 0,
                    read_progress = tonumber(item.read_progress) or 0,
                },
            }, nil
        end
    end
    return { progress = nil }, nil
end

-- 移植 client.lua:1113-1122 update_read_progress。
local function opPushProgress(payload)
    local book_id = tostring(payload.provider_book_id or "")
    local item_id = tostring(payload.item_id or "")
    if book_id == "" or item_id == "" then return nil, "进度参数不完整" end
    local cookie_map = authModule():getCookieMap()
    local result, err = apiPostJson(updateProgressUrl(), {
        book_id = book_id,
        item_id = item_id,
        read_progress = tonumber(payload.fraction) or 0,
        index = tonumber(payload.index) or 0,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    }, cookie_map)
    if not result then return nil, err end
    return { pushed = true }, nil
end

-- ---------------------------------------------------------------------------
-- childOp 分发（AsyncProviderTask 唯一入口，子进程内执行）
-- ---------------------------------------------------------------------------

local OPS = {
    qr_create = opQrCreate,
    qr_poll = opQrPoll,
    qr_finish = opQrFinish,
    shelf = opShelf,
    toc = opToc,
    content = opContent,
    progress = opProgress,
    push_progress = opPushProgress,
}

function FanqieOfficialProvider:childOp(op, payload)
    if not self:isEnabled() then
        return nil, "番茄源未开启（免责声明未确认）"
    end
    local handler = OPS[tostring(op or "")]
    if not handler then
        return nil, "未知 Provider 操作：" .. tostring(op)
    end
    -- 子进程从磁盘重读账号，拿到最新登录态（fork 继承的内存可能过期）。
    pcall(function() authModule():reload() end)
    return handler(payload or {})
end

function FanqieOfficialProvider:logout()
    return authModule():logout()
end

return FanqieOfficialProvider
