local rapidjson = require("rapidjson")
local koreader_util = require("util")
local Charset = require("Leko/Charset")
local DataUri = require("Leko/DataUri")
local BuiltinSources = require("Leko/BuiltinSources")
local BookIdentity = require("Leko/BookIdentity")
local CookieJar = require("Leko/CookieJar")
local Http = require("Leko/Http")
local QuickJS = require("Leko/QuickJS")
local ExecutionTrace = require("Leko/ExecutionTrace")
local Regex = require("Leko/Regex")
local RuleEngine = require("Leko/RuleEngine")
local StageError = require("Leko/StageError")
local Util = require("Leko/Util")

local storage_ok, Storage = pcall(require, "Leko/Storage")
local unpack = table.unpack or unpack

local LegadoSource = {
    max_toc_pages = 30,
    max_content_pages = 20,
}

local function stageError(code, source, message)
    if StageError:is(message) then return tostring(message) end
    return StageError:format(code, source, message)
end

local function diagnosticParseMeta(source, response, rule)
    if not (source and source._diagnostic_full_errors == true) then return "" end
    local body = response and response.body or ""
    local preview = tostring(rule or ""):gsub("[\r\n]+", " ")
    local rule_bytes = #preview
    if #preview > 500 then preview = preview:sub(1, 500) .. "…" end
    return table.concat({
        "response_url=" .. tostring(response and response.url or ""),
        "content_type=" .. tostring(response and response.content_type or ""),
        "response_bytes=" .. tostring(type(body) == "string" and #body or 0),
        "rule_bytes=" .. tostring(rule_bytes),
        "rule_preview=" .. preview,
    }, " · ")
end

local function diagnosticRuleType(rule)
    local value = Util.trim(tostring(rule or ""))
    local lower = value:lower()
    if value == "" then return "empty" end
    if lower:match("^@?js:") or lower:match("^<js>") then return "js" end
    if lower:match("^@?json:") or value:match("^%$") then return "jsonpath" end
    if lower:match("^@?xpath:") or value:match("^//") then return "xpath" end
    if lower:match("^regex:") then return "regex" end
    if lower:match("^class%.") or lower:match("^id%.") or lower:match("^tag%.") or value:find("@", 1, true) then return "legacy" end
    return "css-or-text"
end

local function diagnosticPreview(value, limit)
    value = tostring(value or ""):gsub("[\r\n]+", " ")
    limit = tonumber(limit) or 240
    return #value > limit and value:sub(1, limit) .. "..." or value
end

local function setSearchDiagnostic(source, response, list_rule, nodes)
    if not source then return end
    local body = response and response.body or ""
    source._last_search_diagnostic = {
        response_url = tostring(response and response.url or ""),
        response_status = tostring(response and (response.status or response.code or "") or ""),
        response_code = tostring(response and (response.code or response.status or "") or ""),
        content_type = tostring(response and response.content_type or ""),
        response_bytes = type(body) == "string" and #body or 0,
        book_list_rule = tostring(list_rule or ""),
        book_list_rule_type = diagnosticRuleType(list_rule),
        book_list_nodes = tonumber(nodes or 0) or 0,
        response_preview = diagnosticPreview(body),
    }
end

local function tableOrEmpty(value)
    return type(value) == "table" and value or {}
end

local function copyTable(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

-- Legado keeps variables on the current rule data object and resolves reads
-- through chapter -> book -> source.  A chapter must stay empty until a rule
-- writes to it; copying book variables into every chapter changes the
-- observable state even though lookups still appear to work.
local function variableScope(primary, fallback)
    primary = type(primary) == "table" and primary or {}
    fallback = type(fallback) == "table" and fallback or nil
    if fallback and fallback ~= primary then
        local metatable = getmetatable(primary)
        if not metatable then
            metatable = {}
            setmetatable(primary, metatable)
        end
        if metatable.__index == nil then metatable.__index = fallback end
    end
    return primary
end

local function retainJsonNodeFields(target, node)
    if type(target) ~= "table" or type(node) ~= "table"
            or (RuleEngine and RuleEngine.isNode and RuleEngine:isNode(node)) then return end
    -- SearchBook is extensible in Legado.  Keep scalar/object fields from a
    -- JSON result node so later detail/TOC templates can still see IDs such
    -- as book_id even when the detail response omits them.  Do not retain
    -- camelCase field aliases beside the canonical SearchBook fields: the
    -- QuickJS state snapshot exposes both names, and a stale node.name or
    -- node.bookUrl can otherwise overwrite a newer JS-computed title or URL
    -- when the state is merged back after evaluation.
    local canonical_aliases = {
        name = true, bookName = true, author = true, writer = true,
        kind = true, wordCount = true, word_count = true,
        lastChapter = true, latestChapter = true, latestChapterTitle = true,
        coverUrl = true, cover = true, image = true,
        bookUrl = true, book_url = true, url = true,
        tocUrl = true, toc_url = true, catalogUrl = true,
    }
    for key, value in pairs(node) do
        if type(key) == "string" and key:sub(1, 2) ~= "__"
                and not canonical_aliases[key]
                and target[key] == nil and type(value) ~= "function" and type(value) ~= "table"
                and tostring(value) ~= "null" and tostring(value) ~= "nil"
                and not tostring(value):match("^table:%s*") then
            target[key] = value
        end
    end
end


local function nonEmptyScalar(value)
    if value == nil or type(value) == "table" then return false end
    local text = Util.trim(tostring(value))
    return text ~= "" and text ~= "null" and text ~= "nil" and not text:match("^table:%s*")
end


local function searchLikeResponseUrl(response_url)
    local lower = tostring(response_url or ""):lower()
    return lower:find("/search", 1, true) ~= nil
        or lower:find("search?", 1, true) ~= nil
        or lower:find("search_", 1, true) ~= nil
        or lower:find("/bsearch", 1, true) ~= nil
        or lower:find("/cse/", 1, true) ~= nil
        or lower:find("/tags/", 1, true) ~= nil
        or lower:find("/serch", 1, true) ~= nil
        or lower:find("?q=", 1, true) ~= nil
        or lower:find("&q=", 1, true) ~= nil
        or lower:find("?kw=", 1, true) ~= nil
        or lower:find("?keyword=", 1, true) ~= nil
end

local function classifySearchResponse(response)
    local body = tostring(response and response.body or "")
    if body == "" then return "response_empty" end
    local lower = body:lower()
    local content_type = tostring(response and response.content_type or ""):lower()
    local trimmed = Util.trim(body)
    local is_json = content_type:find("json", 1, true) ~= nil
        or trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "["

    if is_json then
        local ok, decoded = pcall(rapidjson.decode, trimmed)
        if ok and type(decoded) == "table" then
            local payload = type(decoded.data) == "table" and decoded.data or decoded
            if payload.hasResult == false or tonumber(payload.totalCount) == 0
                    or (type(payload.posts) == "table" and #payload.posts == 0) then
                return "json_empty_result"
            end
            local message = tostring(decoded.msg or decoded.message or decoded.errmsg or decoded.error or "")
            if message ~= "" then
                local message_lower = message:lower()
                if message_lower:find("keyword", 1, true) or message:find("关键字", 1, true)
                        or message:find("关键词", 1, true) then
                    return "json_request_rejected"
                end
                if message_lower:find("empty app", 1, true) or message_lower:find("app id", 1, true) then
                    return "json_configuration_error"
                end
                return "json_api_error"
            end
        end
        if trimmed == "[]" or lower:find('"posts"%s*:%s*%[%s*%]', 1) then
            return "json_empty_result"
        end
        if lower:find('"booklist"', 1, true) and lower:find('"title"%s*:%s*null', 1)
                and lower:find('"bookid"%s*:%s*null', 1) then
            return "json_placeholder"
        end
    end

    local login_page = lower:find("需要登录", 1, true)
        or lower:find("请先登录", 1, true)
        or lower:find("请登录", 1, true)
        or lower:find("<title>登录", 1, true)
        or lower:find("<title>登入", 1, true)
    if login_page or lower:find("challenge", 1, true)
            or lower:find("验证页", 1, true) then
        return "login_or_challenge"
    end
    if lower:find("请输入要搜索", 1, true) or lower:find("仅支持通过搜索框", 1, true)
            or lower:find("不能太长", 1, true) then
        return "request_rejected"
    end
    if lower:find("没有找到相关", 1, true) or lower:find("没有搜索到", 1, true)
            or lower:find("没有找到包含", 1, true) or lower:find("无相关", 1, true)
            or lower:find("共0条", 1, true) or lower:find("共0本", 1, true)
            or lower:find("0%s*条", 1) or lower:find("0%s*项", 1)
            or lower:find("0%s*本小说", 1)
            or lower:find('class="ser%-ret[^"]*"%s*></ul>', 1)
            or lower:find("搜索结果为空", 1, true) then
        return "html_empty_result"
    end
    -- A search URL returning a document whose canonical URL is the bare site
    -- root is a server-side home-page fallback, not a selector miss.
    if searchLikeResponseUrl(response and response.url or "")
            and lower:find("rel=[\"']canonical[\"']", 1)
            and (lower:find("href=[\"']https://[^\"']+/[\"']", 1)
                or lower:find("href=[\"']http://[^\"']+/[\"']", 1)) then
        return "homepage_response"
    end
    if lower:find("thread%-%d+%-%d+%-%d+%.html", 1) then
        return "non_book_search_results"
    end
    return "selector_no_candidate"
end



-- bookSourceUrl is both a network base and a user-defined source key. Community
-- packs commonly append #author or ##annotation to distinguish duplicate hosts.
-- Fragments are never sent over HTTP, so retain the original key for scripts but
-- derive a clean network base for relative URL resolution.
local function sourceNetworkBase(value)
    value = Util.trim(tostring(value or ""))
    if not value:match("^https?://") and not value:match("^leko://") then return "" end
    value = value:gsub("##.*$", "")
    value = value:gsub("#.*$", "")
    -- Several imported Android source packs use a full-width hash as a
    -- human-readable source suffix (for example `＃妍希`).  It is not a URL
    -- fragment delimiter and Node's URL parser correctly rejects it.  Keep
    -- source_key untouched for identity, but remove the suffix from the
    -- network base used by every real request.
    value = value:gsub("＃.*$", "")
    return Util.trim(value)
end

local function isHttpUrl(value)
    if type(Http.isHttpUrl) == "function" then return Http:isHttpUrl(value) end
    return tostring(value or ""):match("^https?://") ~= nil
end

local function urlOrigin(value)
    value = tostring(value or "")
    return value:match("^(https?://[^/%?#]+)") or ""
end

local function normalizeLooseJson(value)
    local output, i, quote = {}, 1, nil
    while i <= #value do
        local char = value:sub(i, i)
        if not quote then
            if char == "'" then quote = "'"; output[#output + 1] = '"'
            else output[#output + 1] = char end
        else
            if char == "\\" then
                local next_char = value:sub(i + 1, i + 1)
                if next_char == "'" then output[#output + 1] = "'"; i = i + 1
                elseif next_char == '"' then output[#output + 1] = '\\"'; i = i + 1
                else output[#output + 1] = char end
            elseif char == "'" then quote = nil; output[#output + 1] = '"'
            elseif char == '"' then output[#output + 1] = '\\"'
            else output[#output + 1] = char end
        end
        i = i + 1
    end
    local normalized = table.concat(output)
    normalized = normalized:gsub("([,{]%s*)([%a_$][%w_$%-]*)%s*:", '%1"%2":')
    normalized = normalized:gsub(",%s*([}%]])", "%1")
    return normalized
end

local function decodeLooseObject(value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" or Util.trim(value) == "" then return nil end
    local ok, decoded = pcall(rapidjson.decode, value)
    if ok and type(decoded) == "table" then return decoded end
    ok, decoded = pcall(rapidjson.decode, normalizeLooseJson(value))
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function parseHeaders(value)
    local headers = decodeLooseObject(value)
    local output = {}
    if type(headers) == "table" then
        for key, item in pairs(headers) do output[tostring(key):lower()] = tostring(item or "") end
        return output
    end
    -- source.putLoginHeader() is not required to return JSON. Community
    -- sources also use ordinary RFC-style lines such as "Authorization: ...".
    -- Preserve those runtime headers instead of silently discarding them after
    -- the search subprocess hands the selected candidate to the open task.
    for line in tostring(value or ""):gmatch("[^\r\n]+") do
        local key, item = line:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
        if key and item then output[tostring(key):lower()] = tostring(item) end
    end
    return output
end

local function mergeRuntimeHeaders(target, source)
    for key, value in pairs(source or {}) do
        key = tostring(key):lower()
        if target[key] == nil or target[key] == "" then
            target[key] = tostring(value or "")
        end
    end
end

local function jsLibraryEntries(value, output, label)
    output = output or {}
    label = label or "jsLib"
    if type(value) == "string" then
        local text = Util.trim(value)
        if text ~= "" then
            output[#output + 1] = { value = text, label = label }
        end
        return output
    end
    if type(value) ~= "table" then return output end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local item = value[key]
        local item_label = label .. "." .. tostring(key)
        if type(item) == "table" then
            jsLibraryEntries(item, output, item_label)
        elseif item ~= nil then
            jsLibraryEntries(tostring(item), output, item_label)
        end
    end
    return output
end

local function fetchJsLibrary(source, value)
    local requested = Util.trim(tostring(value or ""))
    local url = Http:absolute(source.base_url or source.source_key or "", requested)
    if not isHttpUrl(url) then
        return nil, "jsLib only supports HTTP(S) URLs: " .. requested
    end
    local headers = copyTable(source.header)
    mergeRuntimeHeaders(headers, parseHeaders(source.login_header))
    local cookie = CookieJar:header(source, url)
    if cookie ~= "" and not headers.cookie then headers.cookie = cookie end
    local response, err = Http:request({
        url = url,
        method = "GET",
        headers = headers,
        retries = 0,
        max_bytes = 2 * 1024 * 1024,
    })
    if not response then return nil, tostring(err or "request failed") end
    local response_url = response.url or url
    if CookieJar:addFromHeaders(source, response_url, response.headers) and storage_ok
            and Storage and Storage.saveSourceRuntime and not source._suppress_runtime_persist then
        pcall(Storage.saveSourceRuntime, Storage, source)
    end
    local body = tostring(response.body or "")
    if body == "" then return nil, "jsLib response is empty: " .. url end
    local charset = Charset:detect(body, response.content_type)
    local decoded, decode_err = Charset:decode(body, charset)
    if not decoded then
        return nil, "jsLib charset decode failed (" .. tostring(charset) .. "): " .. tostring(decode_err)
    end
    return decoded
end

local function jsLibraryValueIsUrl(value)
    local text = Util.trim(tostring(value or ""))
    if text == "" then return false end
    if isHttpUrl(text) then return true end
    -- A jsLib entry may be a relative script URL.  Do not run arbitrary
    -- source code through Http:absolute: ordinary inline libraries such as
    -- `t=Date.now().toString()` are valid Legado scripts, not URL paths.
    return text:match("^//") ~= nil
        or text:match("^/") ~= nil
        or text:match("^%.%.?/") ~= nil
end

local function sourceJsLibraryScript(source)
    source = source or {}
    local raw = source.js_lib
    local signature = type(raw) == "string" and raw or tostring(raw or "")
    source.variables = source.variables or {}
    if source.variables.__refresh_jslib then
        source.variables.__refresh_jslib = nil
        if type(QuickJS.closeSession) == "function" then QuickJS:closeSession(source) end
        source._js_lib_script, source._js_lib_error = nil, nil
    end
    if source._js_lib_signature ~= nil and source._js_lib_signature ~= signature then
        if type(QuickJS.closeSession) == "function" then QuickJS:closeSession(source) end
        source._js_lib_script, source._js_lib_error = nil, nil
    end
    source._js_lib_signature = signature
    if source._js_lib_error then return nil, source._js_lib_error end
    if source._js_lib_script ~= nil then return source._js_lib_script end
    if Util.trim(signature) == "" then
        source._js_lib_script = ""
        return source._js_lib_script
    end

    local decoded = decodeLooseObject(raw)
    local entries = jsLibraryEntries(decoded or raw)
    local scripts = {}
    for _, entry in ipairs(entries) do
        local value = entry.value
        local script, err
        if jsLibraryValueIsUrl(value) then
            script, err = fetchJsLibrary(source, value)
        else
            script = value
        end
        if not script then
            source._js_lib_error = "jsLib load failed (" .. tostring(entry.label) .. "): " .. tostring(err)
            return nil, source._js_lib_error
        end
        scripts[#scripts + 1] = script
    end
    local result = table.concat(scripts, "\n")
    if #result > 4 * 1024 * 1024 then
        source._js_lib_error = "jsLib is too large"
        return nil, source._js_lib_error
    end
    source._js_lib_script = result
    return result
end

local function prepareJsLibrary(source, env)
    env = env or {}
    local script, load_err = sourceJsLibraryScript(source)
    env.__js_lib = script or ""
    if load_err then
        env.__js_lib_error = load_err
        env.last_js_error = load_err
        return nil, load_err
    end
    if env.__js_lib == "" then return true end
    if type(QuickJS.installLibrary) ~= "function" then
        local err = "QuickJS library installer unavailable"
        env.__js_lib_error, env.last_js_error = err, err
        return nil, err
    end
    local target = type(source) == "table" and (source.raw or source) or nil
    local session = type(target) == "table" and rawget(target, "__quickjs_session") or nil
    if not session or session.closed then
        local trace = ExecutionTrace:get(source)
        if trace then
            local library_field = trace.stage == "content" and "content.content" or (trace.stage or "unknown")
            local library_base = trace.stage == "content" and source._js_library_base_url_override
                or env.base_url
            ExecutionTrace:setRule(source, env, library_field, env.__js_lib, library_base)
        end
        local _, install_err = QuickJS:installLibrary(env.__js_lib, env)
        if install_err then
            env.__js_lib_error = "jsLib evaluation failed: " .. tostring(install_err)
            env.last_js_error = env.__js_lib_error
            return nil, env.__js_lib_error
        end
    end
    return true
end

local function firstRule(rule_table, ...)
    for _, name in ipairs({ ... }) do
        if rule_table and rule_table[name] ~= nil and rule_table[name] ~= "" then return rule_table[name] end
    end
    return nil
end

local function flattenStrings(value, output)
    output = output or {}
    if type(value) == "table" then
        for _, item in pairs(value) do flattenStrings(item, output) end
    elseif value ~= nil then output[#output + 1] = tostring(value) end
    return output
end

local function activeRuleStrings(source)
    -- Only the fields executed by search -> detail -> toc -> text content are
    -- core. Login UI, explore buttons, imageDecode/imageStyle and payAction are
    -- separate capabilities and must not make an otherwise readable text source
    -- fail static compatibility analysis.
    local values = { source.search_url, source.source_regex, source.header_rule }
    local groups = {
        { source.rule_search, {
            "init", "bookList", "book_list", "list", "name", "bookName", "title",
            "author", "writer", "bookUrl", "book_url", "url", "coverUrl", "cover", "image",
            "intro", "kind", "lastChapter", "wordCount", "tocUrl", "toc_url", "catalogUrl",
        } },
        { source.rule_book_info, {
            "init", "name", "bookName", "title", "author", "writer", "coverUrl", "cover", "image",
            "intro", "description", "kind", "lastChapter", "wordCount", "tocUrl", "toc_url", "catalogUrl",
        } },
        { source.rule_toc, {
            "preUpdateJs", "pre_update_js", "chapterList", "chapter_list", "list",
            "chapterName", "name", "title", "chapterUrl", "url", "href",
            "nextTocUrl", "nextUrl", "nextPage", "isVolume", "is_volume", "isVip", "is_vip",
            "isPay", "is_pay", "updateTime", "update_time", "info", "formatJs", "format_js",
        } },
        { source.rule_content, {
            "content", "body", "text", "replaceRegex", "replace_regex",
            "nextContentUrl", "nextUrl", "nextPage",
        } },
    }
    for _, group in ipairs(groups) do
        local rules, keys = group[1] or {}, group[2]
        for _, key in ipairs(keys) do if rules[key] ~= nil then values[#values + 1] = rules[key] end end
    end
    return flattenStrings(values)
end

local function inferMediaKind(source)
    local raw = source.raw or {}
    local source_type = tonumber(raw.bookSourceType or raw.sourceType or 0) or 0
    local label = (tostring(source.name or "") .. " " .. tostring(source.group or "")):lower()
    local markers = {
        { "漫画", "comic" }, { "图片", "image" }, { "图集", "image" },
        { "听书", "audio" }, { "音频", "audio" }, { "有声", "audio" },
        { "视频", "video" }, { "短剧", "video" }, { "影视", "video" },
        { "音乐", "music" }, { "游戏", "game" },
    }
    for _, marker in ipairs(markers) do
        if label:find(marker[1], 1, true) then return marker[2] end
    end
    if source_type ~= 0 then return "non_text" end
    return "text"
end

local function structurallyExecutable(source)
    return inferMediaKind(source) == "text"
        and source.search_url ~= nil and Util.trim(source.search_url) ~= ""
        and firstRule(source.rule_search, "bookList", "book_list", "list") ~= nil
        and (source.single_chapter == true
            or firstRule(source.rule_toc, "chapterList", "chapter_list", "list") ~= nil)
end

local function analysisCodeSurface(value)
    value = tostring(value or "")
    local out, i, quote, escape, line_comment, block_comment = {}, 1, nil, false, false, false
    while i <= #value do
        local c, n = value:sub(i, i), value:sub(i + 1, i + 1)
        if line_comment then
            if c == "\n" then line_comment = false; out[#out + 1] = c else out[#out + 1] = " " end
        elseif block_comment then
            if c == "*" and n == "/" then out[#out + 1], out[#out + 2] = " ", " "; i = i + 1; block_comment = false
            else out[#out + 1] = c == "\n" and c or " " end
        elseif quote then
            if escape then escape = false
            elseif c == "\\" then escape = true
            elseif c == quote then quote = nil end
            out[#out + 1] = c == "\n" and c or " "
        elseif c == "/" and n == "/" then
            out[#out + 1], out[#out + 2] = " ", " "; i = i + 1; line_comment = true
        elseif c == "/" and n == "*" then
            out[#out + 1], out[#out + 2] = " ", " "; i = i + 1; block_comment = true
        elseif c == "'" or c == '"' or c == "`" then
            quote = c; out[#out + 1] = " "
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

local function analyzeCompatibility(source)
    local reasons, seen = {}, {}
    local grade = "A"
    local severity = { A = 1, B = 2, C = 3, D = 4 }
    local function add(reason, target_grade)
        target_grade = target_grade or "B"
        if reason and not seen[reason] then reasons[#reasons + 1], seen[reason] = reason, true end
        if severity[target_grade] > severity[grade] then grade = target_grade end
    end

    local media_kind = inferMediaKind(source)
    if media_kind ~= "text" then add("Leko 当前阅读链仅处理纯文本小说源（识别为 " .. media_kind .. "）", "D") end
    if not source.search_url or source.search_url == "" then add("缺少搜索地址", "D") end
    if not firstRule(source.rule_search, "bookList", "book_list", "list") then add("缺少搜索列表规则", "D") end
    if not source.single_chapter and not firstRule(source.rule_toc, "chapterList", "chapter_list", "list") then add("缺少目录列表规则", "C") end
    -- WebBook.getContentAwait has a production branch for an empty content
    -- rule: it returns the chapter URL.  Do not reject such a text source at
    -- the structural gate; the runtime must observe and compare that branch.

    local raw = source.raw or {}
    local js_lib = source.js_lib or raw.jsLib or raw.js_lib or ""
    if js_lib ~= "" then add("使用 jsLib；按实际调用加载命名函数、箭头函数与常量", "B") end
    if raw.hasInjectJs or Util.trim(source.inject_js or raw.injectJs or "") ~= "" then
        add("网页注入脚本不属于无浏览器阅读链", "C")
    end
    if raw.hasLogin or Util.trim(source.login_url or raw.loginUrl or "") ~= ""
        or Util.trim(source.login_ui or raw.loginUi or "") ~= "" then
        add("包含可选登录功能；匿名阅读链与登录能力分开判定", "B")
    end

    local supported_java = {
        getString=true,getElement=true,getElements=true,ajax=true,ajaxAll=true,ajaxTestAll=true,
        connect=true,post=true,head=true,get=true,put=true,getCookie=true,setContent=true,
        base64Encode=true,base64Decode=true,base64DecodeToByteArray=true,hexDecodeToString=true,
        hexEncodeToString=true,bytesToStr=true,md5Encode=true,md5Encode16=true,digestHex=true,
        HMacHex=true,HMacBase64=true,randomUUID=true,createSymmetricCrypto=true,aesBase64DecodeToString=true,
        desEncodeToBase64String=true,toNumChapter=true,encodeURI=true,urlEncode=true,urlDecode=true,
        getWebViewUA=true,getUserAgent=true,androidId=true,s2t=true,t2s=true,removeCookie=true,
        getStrResponse=true,refreshTocUrl=true,
        refreshContent=true,refreshBookUrl=true,refreshBookInfo=true,refreshExplore=true,
        log=true,getStringList=true,
        timeFormat=true,timeFormatUTC=true,htmlFormat=true,initUrl=true,searchBook=true,upLoginData=true,
    }
    local interactive_java = {
        webView=true, webview=true, startBrowser=true, startBrowserAwait=true,
        getVerificationCode=true, showBrowser=true, toast=true, longToast=true,
    }
    local allowed_constructor = {
        RegExp=true, Date=true, Array=true, Set=true, Map=true, Error=true, Uint8Array=true,
        JavaImporter=true, ByteArrayInputStream=true, ByteArrayOutputStream=true,
        GZIPInputStream=true, String=true,
    }

    local saw_js, saw_xpath, saw_charset, saw_paging, saw_bridge = false, false, false, false, false
    local unknown_methods = {}
    for _, value in ipairs(activeRuleStrings(source)) do
        local raw_lower = value:lower()
        local surface = analysisCodeSurface(value)
        local lower = surface:lower()
        for method in surface:gmatch("java%.([A-Za-z_$][%w_$]*)%s*%(") do
            if interactive_java[method] then
                add("包含条件式 WebView、浏览器或验证码分支；仅实际执行该分支时需要交互（java." .. method .. "）", "B")
            elseif not supported_java[method] and not unknown_methods[method] then
                unknown_methods[method] = true
                add("核心规则调用尚未实现的 java." .. method, "C")
            end
        end
        if lower:find("promise", 1, true) or lower:match("%f[%a]async%f[%A]") or lower:match("%f[%a]await%f[%A]") then
            add("核心规则依赖异步 Promise/async JavaScript", "C")
        end
        if lower:find("x509encodedkeyspec", 1, true) or lower:find("rsapublickeyspec", 1, true)
            or lower:match("rsa%s*/%s*(ecb|none)") then
            add("核心规则依赖尚未桥接的 RSA 公钥加解密", "C")
        end
        for constructor in surface:gmatch("new%s+([A-Za-z_$][%w_$]*)%s*%(") do
            if not allowed_constructor[constructor] and constructor ~= "Request" then
                add("核心规则使用尚未实现的构造器 new " .. constructor, "C")
            end
        end
        if lower:find("javaimporter", 1, true) or lower:find("packages.", 1, true)
            or lower:find("okhttpclient", 1, true) or lower:find("gzipinputstream", 1, true)
            or lower:find("aes", 1, true) or lower:find("des", 1, true) then saw_bridge = true end
        if raw_lower:find("cache.", 1, true) or raw_lower:find("source.getvariable", 1, true)
            or raw_lower:find("book.getvariable", 1, true) or raw_lower:find("chapter.", 1, true) then
            add("使用书源、书籍或章节状态运行时", "B")
        end

        local snippets = {}
        if raw_lower:find("@js:", 1, true) or raw_lower:find("<js>", 1, true) then
            saw_js = true
            if lower:match("^%s*@js:") or lower:match("^%s*<js>") then snippets[#snippets + 1] = value end
            for script in value:gmatch("<js>([%s%S]-)</js>") do snippets[#snippets + 1] = script end
        end
        for script in value:gmatch("{{([%s%S]-)}}") do
            script = Util.trim(script)
            if script:sub(1, 2) ~= "@@" and script ~= "key" and script ~= "searchKey" and script ~= "page" then
                saw_js = true; snippets[#snippets + 1] = script
            end
        end
        for _, script in ipairs(snippets) do
            local ok, why = QuickJS:canEvaluate(script)
            if not ok then add("核心规则含当前运行时无法执行的 JavaScript（" .. tostring(why) .. "）", "C") end
        end
        if raw_lower:find("@xpath:", 1, true) or value:match("^%s*//") then saw_xpath = true end
        if raw_lower:find("gbk", 1, true) or raw_lower:find("gb2312", 1, true) or raw_lower:find("gb18030", 1, true) then saw_charset = true end
        if raw_lower:find("nexttocurl", 1, true) or raw_lower:find("nextcontenturl", 1, true) then saw_paging = true end
    end
    if saw_bridge then add("使用 JavaImporter/加密/压缩/OkHttp 兼容桥", "B") end
    if saw_js and grade == "A" then add("使用内置 JavaScript 兼容运行时", "B") end
    if saw_xpath then add("XPath 使用常用轴、属性与索引子集", "B") end
    if saw_paging then add("包含目录或正文分页规则", "B") end
    if saw_charset then
        if Charset:isAvailable() then add("使用 GBK/GB18030 转码", "B")
        else add("设备缺少 iconv，无法转码 GBK/GB18030", "C") end
    end

    local labels = {
        A = "标准规则",
        B = "兼容运行时",
        C = "存在未实现能力",
        D = "不适用",
    }
    return grade, reasons, media_kind, labels[grade]
end

local function compactRaw(raw)
    raw = raw or {}
    -- The original JSON is backed up separately. Keep only runtime metadata here
    -- to avoid duplicating multi-megabyte rule packs inside leko.lua.
    return {
        bookSourceUrl = raw.bookSourceUrl or raw.baseUrl or raw.base_url or raw.url,
        sourceKey = raw.sourceKey or raw.source_key or raw.bookSourceUrl or raw.baseUrl or raw.base_url or raw.url,
        bookSourceName = raw.bookSourceName or raw.name,
        bookSourceGroup = raw.bookSourceGroup or raw.group,
        bookSourceType = raw.bookSourceType or raw.sourceType or 0,
        -- Keep the source's own diagnostic keyword after compacting.  It is
        -- metadata, not a rule body, but losing it makes the desktop and
        -- device diagnostics probe every source with the same unrelated title.
        checkKeyWord = raw.checkKeyWord or raw.checkKeyword,
        replaceRegex = raw.replaceRegex,
        bookUrlPattern = raw.bookUrlPattern or raw.book_url_pattern,
        enabledCookieJar = raw.enabledCookieJar,
        customOrder = raw.customOrder,
        weight = raw.weight,
        coverDecodeJs = raw.coverDecodeJs or raw.cover_decode_js,
        hasJsLib = raw.hasJsLib or (raw.jsLib ~= nil and raw.jsLib ~= ""),
        hasInjectJs = raw.hasInjectJs or (raw.injectJs ~= nil and raw.injectJs ~= ""),
        hasLogin = raw.hasLogin or ((raw.loginUrl and raw.loginUrl ~= "")
            or (raw.loginUi and raw.loginUi ~= "") or (raw.loginCheckJs and raw.loginCheckJs ~= "")),
    }
end

function LegadoSource:normalize(raw)
    raw = raw or {}
    local source_key = raw.bookSourceUrl or raw.baseUrl or raw.base_url or raw.url or ""
    local base_url = sourceNetworkBase(source_key)
    local name = raw.bookSourceName or raw.name or source_key or "未命名书源"
    local source = {
        id = Util.hashId(source_key .. "\n" .. name),
        name = name,
        group = raw.bookSourceGroup or raw.group or "",
        source_key = source_key,
        base_url = base_url,
        custom_order = tonumber(raw.customOrder or raw.custom_order) or 999999,
        weight = tonumber(raw.weight) or 0,
        check_keyword = raw.checkKeyWord or raw.checkKeyword or "",
        enabled = raw.enabled ~= false and raw.enable ~= false,
        enabled_cookie_jar = raw.enabledCookieJar ~= false,
        search_url = raw.searchUrl or raw.search_url,
        book_url_pattern = raw.bookUrlPattern or raw.book_url_pattern or "",
        header = parseHeaders(raw.header),
        -- Legado stores sourceRegex on ruleContent and passes it to the
        -- WebView resource filter. It is not an HTTP response replacement.
        source_regex = (type(raw.ruleContent) == "table" and (raw.ruleContent.sourceRegex or raw.ruleContent.source_regex))
            or (type(raw.rule_content) == "table" and (raw.rule_content.sourceRegex or raw.rule_content.source_regex)),
        cover_decode_js = raw.coverDecodeJs or raw.cover_decode_js or "",
        js_lib = raw.jsLib or raw.js_lib or "",
        inject_js = raw.injectJs or raw.inject_js or "",
        login_url = raw.loginUrl or raw.login_url or "",
        login_ui = raw.loginUi or raw.login_ui or "",
        login_check_js = raw.loginCheckJs or raw.login_check_js or "",
        header_rule = type(raw.header) == "string" and raw.header or "",
        cover_supported = Util.trim(raw.coverDecodeJs or raw.cover_decode_js or "") == "",
        rule_search = tableOrEmpty(raw.ruleSearch or raw.rule_search),
        rule_book_info = tableOrEmpty(raw.ruleBookInfo or raw.rule_book_info),
        rule_toc = tableOrEmpty(raw.ruleToc or raw.rule_toc),
        rule_content = tableOrEmpty(raw.ruleContent or raw.rule_content),
        cookies = type(raw.cookies) == "table" and raw.cookies or {},
        variables = type(raw.variables) == "table" and raw.variables or {},
        single_chapter = raw.singleChapter == true or raw.single_chapter == true,
        single_chapter_title = raw.singleChapterTitle or raw.single_chapter_title or "全文",
        builtin = raw.builtin == true,
        raw = raw,
        imported_at = os.time(),
    }
    source.compatibility_grade, source.compatibility_reasons, source.media_kind, source.compatibility_label = analyzeCompatibility(source)
    source.raw = compactRaw(raw)
    local legacy = { A = "full", B = "partial", C = "extension", D = "unsupported" }
    source.compatibility = legacy[source.compatibility_grade] or "unsupported"
    -- Grades describe how much of Legado semantics the source exercises; they
    -- are not permission to delete its rules. C sources are now executed by the
    -- bounded compatibility runtime and fail at the exact unsupported operation.
    source.supported = structurallyExecutable(source)
    source.searchable = source.supported
    source.unsupported_reason = not source.supported and table.concat(source.compatibility_reasons or {}, "；") or nil
    source.archived_only = false
    return source
end

function LegadoSource:refreshCompatibility(source)
    source = source or {}
    -- A refreshed/imported source is a new JavaScript shared-scope boundary.
    -- Release the old native context before replacing the source metadata so
    -- repeated source reloads cannot retain callbacks or stale jsLib globals.
    if type(QuickJS.closeSession) == "function" then QuickJS:closeSession(source) end
    local raw = source.raw or source
    source.cover_decode_js = source.cover_decode_js or raw.coverDecodeJs or raw.cover_decode_js or ""
    source.js_lib = source.js_lib or raw.jsLib or raw.js_lib or ""
    source.inject_js = source.inject_js or raw.injectJs or raw.inject_js or ""
    source.login_url = source.login_url or raw.loginUrl or raw.login_url or ""
    source.login_ui = source.login_ui or raw.loginUi or raw.login_ui or ""
    source.login_check_js = source.login_check_js or raw.loginCheckJs or raw.login_check_js or ""
    source.header_rule = source.header_rule or (type(raw.header) == "string" and raw.header or "")
    source.cover_supported = Util.trim(source.cover_decode_js or "") == ""
    source.compatibility_grade, source.compatibility_reasons, source.media_kind, source.compatibility_label = analyzeCompatibility(source)
    local legacy = { A = "full", B = "partial", C = "extension", D = "unsupported" }
    source.compatibility = legacy[source.compatibility_grade] or "unsupported"
    source.source_key = source.source_key or raw.sourceKey or raw.source_key or raw.bookSourceUrl or source.base_url
    source.base_url = sourceNetworkBase(Util.trim(source.base_url or "") ~= "" and source.base_url or source.source_key)
    source.supported = structurallyExecutable(source)
    source.searchable = source.supported
    source.unsupported_reason = not source.supported and table.concat(source.compatibility_reasons or {}, "；") or nil
    source.raw = compactRaw(source.raw or source)
    source.archived_only = false
    return source
end

function LegadoSource:closeRuntime(source)
    if type(QuickJS.closeSession) ~= "function" then return false end
    return QuickJS:closeSession(source)
end

local function percentEncode(value)
    return koreader_util.urlEncode(tostring(value or ""))
end

local function encodeKeyword(keyword, charset)
    charset = Charset:normalize(charset or "UTF-8")
    if charset == "" then charset = "UTF-8" end
    if charset == "UTF-8" then return percentEncode(keyword) end
    local encoded = Charset:encode(keyword, charset)
    return percentEncode(encoded or keyword)
end

local function variableProxy(input, backing, default_key, aliases)
    input = input or {}
    backing = backing or {}
    aliases = aliases or {}
    local proxy = {}
    local function targetKey(key) return aliases[key] or key end
    setmetatable(proxy, {
        __index = function(_, key)
            local mapped = targetKey(key)
            local value = input[mapped]
            if value == nil and mapped ~= key then value = input[key] end
            return value
        end,
        __newindex = function(_, key, value)
            input[targetKey(key)] = value
        end,
        __pairs = function()
            return pairs(input)
        end,
    })
    rawset(proxy, "__target", input)
    rawset(proxy, "getVariable", function(_, key)
        key = tostring(key or default_key or "default")
        return backing[key] or ""
    end)
    rawset(proxy, "setVariable", function(_, value) backing[default_key or "default"] = value; return value end)
    rawset(proxy, "putVariable", function(_, key, value) backing[tostring(key or default_key or "default")] = value; return value end)
    rawset(proxy, "putCustomVariable", proxy.putVariable)
    rawset(proxy, "setReverseToc", function(_, value) backing.__reverse_toc = value ~= false; return value end)
    rawset(proxy, "setUseReplaceRule", function(_, value) backing.__use_replace_rule = value ~= false; return value end)
    return proxy
end

local BOOK_PROXY_ALIASES = {
    bookUrl = "book_url", tocUrl = "toc_url", coverUrl = "cover",
    name = "title", kind = "kind", wordCount = "word_count",
    lastChapter = "last_chapter", latestChapterTitle = "last_chapter",
    canUpdate = "can_update",
}

local function bindBookEnvironment(env, source, book)
    if type(book) ~= "table" then env.book = nil; return nil end
    book.variables = book.variables or {}
    env.book = variableProxy(book, book.variables, "custom", BOOK_PROXY_ALIASES)
    if book.origin == nil or book.origin == "" then
        book.origin = urlOrigin(book.book_url or book.toc_url or source.base_url)
    end
    return env.book
end

local function jsEnvironment(source, context)
    context = context or {}
    local env = copyTable(context)
    source.variables = source.variables or {}
    local source_proxy = variableProxy(source.raw or source, source.variables, "source", {
        bookSourceUrl = "bookSourceUrl", bookSourceName = "bookSourceName",
        bookSourceGroup = "bookSourceGroup",
    })
    source_proxy.bookSourceUrl = source_proxy.bookSourceUrl or source.source_key or source.base_url
    source_proxy.key = source_proxy.key or source.source_key or source_proxy.bookSourceUrl
    source_proxy.getLoginHeader = function() return source.login_header or "" end
    source_proxy.putLoginHeader = function(_, value) source.login_header = value; return value end
    source_proxy.removeLoginHeader = function() source.login_header = ""; return true end
    source_proxy.put = function(_, key, value)
        ExecutionTrace:sideEffect(source, "source", "put", key)
        source.variables["source:" .. tostring(key)] = value; return value
    end
    source_proxy.get = function(_, key)
        ExecutionTrace:sideEffect(source, "source", "get", key)
        return source.variables["source:" .. tostring(key)] or ""
    end
    source_proxy.putLoginInfo = function(_, key, value)
        source.login_info = source.login_info or {}
        if value == nil and type(key) == "table" then source.login_info = copyTable(key)
        else source.login_info[tostring(key)] = value end
        return value or key
    end
    source_proxy.getLoginInfoMap = function()
        local map = copyTable(source.login_info or {})
        map.get = function(self, key) return self[tostring(key)] end
        return map
    end
    source_proxy.getLoginInfo = function() return source.login_info or {} end
    source_proxy.getKey = function() return source.source_key or source.base_url or "" end
    source_proxy.refreshExplore = function()
        ExecutionTrace:extension(source, "refreshExplore")
        source.variables.__refresh_explore = true; return true
    end
    source_proxy.refreshJSLib = function()
        ExecutionTrace:extension(source, "refreshJSLib")
        source.variables.__refresh_jslib = true; return true
    end
    source_proxy.getVariable = function(_, key) return source.variables[tostring(key or "source")] or "" end
    source_proxy.setVariable = function(_, value) source.variables.source = value; return value end
    source_proxy.putVariable = function(_, key, value)
        ExecutionTrace:sideEffect(source, "source", "putVariable", key)
        source.variables[tostring(key or "source")] = value; return value
    end
    source_proxy.getLoginHeaderMap = function()
        local map = parseHeaders(source.login_header)
        map.get = function(self, key) return self[tostring(key):lower()] or self[key] end
        return map
    end
    env.source = source_proxy
    local trace = ExecutionTrace:get(source)
    if trace then
        rawset(env, "__diagnostic_trace", trace)
        rawset(env, "__diagnostic_stage", trace.stage or source._diagnostic_stage or "source")
        rawset(env, "__diagnostic_rule_field", "environment")
    end
    if context.book then bindBookEnvironment(env, source, context.book) end
    if context.chapter then
        context.chapter.variables = context.chapter.variables or {}
        env.chapter = variableProxy(context.chapter, context.chapter.variables, "custom", {
            chapterUrl = "url", name = "title", isVipValue = "is_vip", isPayValue = "is_pay",
        })
        rawset(env.chapter, "isVip", function() return context.chapter.is_vip == true or context.chapter.isVip == true end)
        rawset(env.chapter, "isPay", function() return context.chapter.is_pay == true or context.chapter.isPay == true end)
    end
    env.key = context.keyword or context.key or ""
    env.searchKey = env.key
    env.page = tonumber(context.page) or 1
    env.variables = type(context.variables) == "table" and context.variables or source.variables
    env.baseUrl, env.base_url = context.base_url or source.base_url, context.base_url or source.base_url
    env.cookie = {
        getCookie = function(_, url) return CookieJar:header(source, url or source.base_url) end,
        getKey = function(_, url, key)
            local header = ";" .. tostring(CookieJar:header(source, url or source.base_url) or "")
            local escaped = tostring(key or ""):gsub("([^%w])", "%%%1")
            return header:match(";%s*" .. escaped .. "%s*=([^;]*)") or ""
        end,
        setCookie = function(_, url, value)
            ExecutionTrace:sideEffect(source, "cookie", "set", url)
            source.cookies = source.cookies or {}; source.cookies[tostring(url or source.base_url)] = tostring(value or ""); return true
        end,
        setWebCookie = function(_, url, value)
            ExecutionTrace:sideEffect(source, "cookie", "setWeb", url)
            source.cookies = source.cookies or {}; source.cookies[tostring(url or source.base_url)] = tostring(value or ""); return true
        end,
        removeCookie = function(_, url)
            ExecutionTrace:sideEffect(source, "cookie", "remove", url)
            if url then source.cookies[tostring(url)] = nil else source.cookies = {} end
            -- Android CookieManager-style removal is a side effect.  Returning
            -- true here leaked the word "true" into Legado {{...}} request
            -- templates (e.g. `truehttps://...`).
            return nil
        end,
    }
    source.cache_memory = source.cache_memory or {}
    local cache_prefix = tostring(source.id or source.source_key or source.name or "source") .. ":"
    env.cache = {
        get = function(_, key)
            ExecutionTrace:sideEffect(source, "cache", "get", key)
            return source.variables["cache:" .. tostring(key)]
        end,
        put = function(_, key, value)
            ExecutionTrace:sideEffect(source, "cache", "put", key)
            source.variables["cache:" .. tostring(key)] = value; return value
        end,
        delete = function(_, key)
            ExecutionTrace:sideEffect(source, "cache", "delete", key)
            source.variables["cache:" .. tostring(key)] = nil; return true
        end,
        remove = function(_, key)
            ExecutionTrace:sideEffect(source, "cache", "remove", key)
            source.variables["cache:" .. tostring(key)] = nil; return true
        end,
        getFromMemory = function(_, key) return source.cache_memory[tostring(key)] end,
        putMemory = function(_, key, value) source.cache_memory[tostring(key)] = value; return value end,
        deleteMemory = function(_, key) source.cache_memory[tostring(key)] = nil; return true end,
        getFile = function(_, key)
            if storage_ok and Storage and Storage.readCache then return Storage:readCache("source-js", cache_prefix .. tostring(key)) end
            return source.variables["file:" .. tostring(key)]
        end,
        putFile = function(_, key, value)
            if storage_ok and Storage and Storage.writeCache then
                Util.mkdirp(Storage:getCacheDir("source-js")); Storage:writeCache("source-js", cache_prefix .. tostring(key), value)
            else source.variables["file:" .. tostring(key)] = value end
            return value
        end,
    }
    if trace and env.__js_lib and env.__js_lib ~= "" then
        -- The library is installed before the first rule at a stage.  Seed
        -- the same stage/base context that the production AnalyzeRule scope
        -- carries; otherwise the install event is reported as an anonymous
        -- environment evaluation with an empty base URL.
        local library_field = trace.stage == "content" and "content.content" or (trace.stage or "unknown")
        ExecutionTrace:setRule(source, env, library_field, env.__js_lib, env.base_url)
    end
    prepareJsLibrary(source, env)
    return env
end

local function traceRule(source, env, field, rule)
    local base_url = env and (env.base_url or env.baseUrl or env.current_url) or nil
    local stage = env and rawget(env, "__diagnostic_stage") or nil
    -- AnalyzeUrl and the WebBook stage establish the production rule field;
    -- internal request/field labels are Leko implementation names.  Preserve
    -- explicit login/content fields, while mapping URL construction and the
    -- ordinary search/detail/toc JS fields to the stage-level field used by
    -- the Legado harness.
    if stage and stage ~= "unknown" then
        if field == "request.urlJs" or field == "request.inlineJs" or field == "request.descriptorJs" then
            field = stage == "content" and "content.content" or stage
        elseif stage ~= "content" and (field:match("^search%.") or field:match("^bookInfo%.") or field:match("^toc%.")) then
            field = stage
        end
    end
    ExecutionTrace:setRule(source, env, field, rule, base_url)
end

local function evaluateEmbedded(value, env)
    value = tostring(value or "")
    value = value:gsub("<js>([%s%S]-)</js>", function(script)
        local source = env and env.source and rawget(env.source, "__target") or nil
        traceRule(source, env, "request.embeddedJs", script)
        local result = QuickJS:eval(script, env)
        return result ~= nil and tostring(result) or ""
    end)
    value = value:gsub("{{([%s%S]-)}}", function(expression)
        expression = Util.trim(expression)
        if expression:sub(1, 2) == "@@" then return "{{" .. expression .. "}}" end
        if expression == "key" or expression == "searchKey" or expression == "page" then return "{{" .. expression .. "}}" end
        local source = env and env.source and rawget(env.source, "__target") or nil
        traceRule(source, env, "request.templateJs", expression)
        local result = QuickJS:eval(expression, env)
        return result ~= nil and tostring(result) or ""
    end)
    return value
end

local function renderTemplate(value, keyword, page, charset, env)
    value = evaluateEmbedded(value, env)
    local encoded = encodeKeyword(keyword or "", charset)
    value = value:gsub("{{%s*key%s*}}", function() return encoded end)
    value = value:gsub("{{%s*searchKey%s*}}", function() return encoded end)
    value = value:gsub("<key>", function() return encoded end)
    value = value:gsub("{{%s*page%s*}}", function() return tostring(page or 1) end)
    return value
end

-- AnalyzeUrl keeps a body literal when the descriptor already supplies a
-- Content-Type.  Only the legacy form branch (with no explicit type) applies
-- charset-aware URL encoding to each field.
local function renderLiteralTemplate(value, keyword, page, env)
    value = evaluateEmbedded(value, env)
    value = value:gsub("{{%s*key%s*}}", function() return tostring(keyword or "") end)
    value = value:gsub("{{%s*searchKey%s*}}", function() return tostring(keyword or "") end)
    value = value:gsub("<key>", function() return tostring(keyword or "") end)
    value = value:gsub("{{%s*page%s*}}", function() return tostring(page or 1) end)
    return value
end

-- JSON request bodies carry the keyword as a JSON value, not as a URL query
-- component.  Percent-encoding it here produces valid JSON with the wrong
-- value (for example, the server receives "%E5%89%91%E6%9D%A5" and quite
-- correctly reports that the keyword is empty).  Keep this separate from the
-- URL/form renderer because those two encodings have different contracts.
local function jsonEscapeString(value)
    value = tostring(value or "")
    return (value:gsub("[\\\"\b\f\n\r\t]", function(char)
        return ({
            ["\\"] = "\\\\", ["\""] = "\\\"", ["\b"] = "\\b",
            ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
        })[char]
    end):gsub("[%z\1-\31]", function(char)
        return string.format("\\u%04x", char:byte())
    end))
end

local function renderJsonTemplate(value, keyword, page, env)
    value = evaluateEmbedded(value, env)
    local raw_keyword = jsonEscapeString(keyword or "")
    value = value:gsub("{{%s*key%s*}}", function() return raw_keyword end)
    value = value:gsub("{{%s*searchKey%s*}}", function() return raw_keyword end)
    value = value:gsub("<key>", function() return raw_keyword end)
    value = value:gsub("{{%s*page%s*}}", function() return tostring(page or 1) end)
    return value
end

local function normalizeLegacyRequestMarkers(value)
    -- A number of older source packs used `<,&` and a trailing `>` as a
    -- visual placeholder around query separators.  They are not part of the
    -- request syntax and must not reach the server as literal keyword bytes.
    value = tostring(value or "")
    value = value:gsub("<,&", "&")
    value = value:gsub(">(%s*[&,])", "%1")
    value = value:gsub(">%s*$", "")
    return value
end

local function splitRequestOptions(spec)
    local best_pos, delimiter
    for _, marker in ipairs({ "##", "," }) do
        local start = 1
        while true do
            local pos = spec:find(marker, start, true)
            if not pos then break end
            local tail = Util.trim(spec:sub(pos + #marker))
            if tail:sub(1, 1) == "{" and tail:sub(-1) == "}" then best_pos, delimiter = pos, marker end
            start = pos + #marker
        end
    end
    if not best_pos then return spec, nil, nil end
    return spec:sub(1, best_pos - 1), spec:sub(best_pos + #delimiter), delimiter
end

local function splitRequestScript(spec)
    spec = tostring(spec or "")
    -- Legado request rules commonly use `url\n@js:`.  The script is a
    -- request-descriptor transformer: `result` starts as the URL on the
    -- first line and the script returns `url,{...options...}`.  Treating the
    -- entire string as a URL sends the JavaScript source to the server and is
    -- the direct cause of a large class of URI/parser failures.
    local lower = spec:lower()
    local position = lower:find("\n%s*@js:") or lower:find("\r%s*@js:")
    if not position then return nil end
    local line_end = position
    while line_end <= #spec and (spec:sub(line_end, line_end) == "\r" or spec:sub(line_end, line_end) == "\n"
            or spec:sub(line_end, line_end):match("%s")) do
        line_end = line_end + 1
    end
    local marker = lower:find("@js:", line_end, true)
    if not marker then return nil end
    return Util.trim(spec:sub(1, position - 1)), spec:sub(marker)
end

local function requestUrlPart(value)
    if type(value) == "table" then value = value.url or value[1] end
    local url_text = select(1, splitRequestOptions(tostring(value or "")))
    local legacy_url = url_text:match("^(.-)@post%-%>")
    return Util.trim(legacy_url or url_text)
end

local function firstNetworkBase(...)
    for index = 1, select("#", ...) do
        local candidate = requestUrlPart(select(index, ...))
        if isHttpUrl(candidate) or BuiltinSources:isFixtureUrl(candidate) then return candidate end
    end
    return ""
end

-- A virtual/data response may carry the real network base separately.  It is
-- valid for the response body to be decoded from an opaque hand-off while its
-- relative links still belong to the originating HTTP page.  Never use the
-- opaque URI as the CSS/JSON/URL rule base; ordinary HTTP responses keep their
-- final (possibly redirected) URL.
local function responseRuleUrl(response)
    local url = requestUrlPart(response and response.url or "")
    if isHttpUrl(url) or BuiltinSources:isFixtureUrl(url) then return url end
    local network_base = firstNetworkBase(response and response.request_base_url)
    return network_base ~= "" and network_base or url
end

local function absolutizeRequestSpec(spec, base_url)
    base_url = requestUrlPart(base_url)
    if type(spec) == "table" then
        local output = copyTable(spec)
        output.url = Http:absolute(base_url, output.url or output[1] or "")
        return output
    end
    local text = tostring(spec or "")
    local url_text, options_text, delimiter = splitRequestOptions(text)
    local legacy_url, legacy_body = url_text:match("^(.-)@post%-%>(.*)$")
    if legacy_url then
        return Http:absolute(base_url, legacy_url) .. "@post->" .. tostring(legacy_body or "")
    end
    local resolved = Http:absolute(base_url, url_text)
    if options_text then return resolved .. tostring(delimiter or ",") .. options_text end
    return resolved
end

local function resolveRuleRequest(value, response_url, request_base)
    value = tostring(value or "")
    if Util.trim(value) == "" then return "" end
    return absolutizeRequestSpec(value, firstNetworkBase(response_url, request_base))
end

local responseProxy, makeRuleEnv

-- Legado exposes a small host-owned `util` object to imported source
-- scripts.  The source pack serializes this object through java.get("util")
-- and revives its function members with JSON.parse's reviver.  Keeping the
-- bridge here makes those scripts portable without copying a source-specific
-- parser or altering the source rules themselves.
local function legadoUtilityJson()
    local utility = {
        environment = { IS_LEGADO = true, IS_SOURCEREAD = false, IS_LEKO = true },
        settings = {
            SEARCH_AUTHOR = false,
            CONVERT_CHINESE = true,
            QUALITY_REGULAR = false,
            SHOW_ORIGINAL_LINK = true,
        },
        -- These methods are intentionally list-preserving.  Field normalization
        -- is performed by the Lua SearchBook hand-off below, where the source
        -- rule and its own URL helpers are still available.  Keeping the host
        -- utility free of source-specific JavaScript avoids changing the
        -- semantics of imported functions that call it as a pure combiner.
        combineNovels = "function(list){return list||[];}",
        handNovels = "function(list){return list||[];}",
        formatNovels = [[function(list){return list||[];}]],
        handIllusts = [[function(list){return list||[];}]],
        formatIllusts = [[function(list){return list||[];}]],
        getIllustRes = "function(value){return value;}",
        debugFunc = "function(fn){try{return fn&&fn();}catch(e){return null;}}",
        removeCookie = "function(){return true;}",
        login = "function(){return false;}",
    }
    local ok, encoded = pcall(rapidjson.encode, utility)
    return ok and encoded or "{}"
end

local function renderBody(value, keyword, page, charset, env, preserveLiteral)
    local body_is_json = type(value) == "table"
    if not body_is_json and type(value) == "string" and Util.trim(value) ~= "" then
        -- Some imported Legado descriptors wrap a JSON request body in a
        -- string (`body: '{...}'`) instead of using an object value.  Detect
        -- that structural form before rendering templates; form bodies such
        -- as `a=1&b=2` do not decode as JSON and keep their URL encoding.
        local decoded_ok, decoded = pcall(rapidjson.decode, value)
        body_is_json = decoded_ok and type(decoded) == "table"
    end
    if body_is_json then
        if type(value) == "table" then
            local ok, encoded = pcall(rapidjson.encode, value)
            value = ok and encoded or ""
        end
    end
    if body_is_json then
        return renderJsonTemplate(value or "", keyword, page, env), true
    end
    if preserveLiteral then
        return renderLiteralTemplate(value or "", keyword, page, env), false
    end
    return renderTemplate(value or "", keyword, page, charset, env), false
end

local function hasContentType(headers)
    headers = headers or {}
    local value = headers["content-type"] or headers["Content-Type"]
    return value ~= nil and tostring(value) ~= ""
end

local function installRequestNetworkBridge(self, source, env, context)
    context = context or {}
    env.java = env.java or {}
    local function optionalToast(_, message)
        env.__host_warnings = env.__host_warnings or {}
        env.__host_warnings[#env.__host_warnings + 1] =
            "java.longToast unavailable on KOReader: " .. tostring(message or "")
        return nil
    end
    -- Request-rule environments may already contain the generic host methods
    -- installed by QuickJS.  Replace them here: a request script that asks
    -- for a browser or verification prompt must become an explicit
    -- interaction result, not an uncaught host-denied exception.
    env.java.toast = optionalToast
    env.java.longToast = optionalToast
    local function requireInteraction(_, url)
        env.__interaction_required = "INTERACTION_REQUIRED: browser verification: " .. tostring(url or "")
        env.last_js_error = env.__interaction_required
        local trace = ExecutionTrace:get(source)
        if trace then trace.interaction_required = true end
        return ""
    end
    env.java.startBrowser = requireInteraction
    env.java.startBrowserAwait = requireInteraction
    env.java.webView = requireInteraction
    env.java.webview = requireInteraction
    env.java.showBrowser = requireInteraction
    env.java.getVerificationCode = requireInteraction
    local network_base = firstNetworkBase(context.network_base, context.base_url,
        context.book and context.book.book_url, source.base_url, source.source_key)
    local function markBrowserChallenge(response, request_spec)
        local body = tostring(response and response.body or "")
        local lower = body:lower()
        -- Cloudflare's interstitial is the concrete response checked by the
        -- Some source rules require browser interaction. Mark that condition
        -- at the transport boundary as well:
        -- this keeps the request result explicit even when a host string
        -- wrapper changes the observable behavior of String.match.
        if lower:find("<title>just a moment", 1, true)
            or lower:find("cf_chl_opt", 1, true)
            or lower:find("challenges.cloudflare.com", 1, true) then
            local url = requestUrlPart(response and (response.url or response.request_url) or "")
            if url == "" then url = requestUrlPart(request_spec) end
            env.__interaction_required = "INTERACTION_REQUIRED: browser verification: "
                .. tostring(url or network_base or "")
            env.last_js_error = env.__interaction_required
            local trace = ExecutionTrace:get(source)
            if trace then trace.interaction_required = true end
        end
    end
    local function nested(spec, method, body, headers, follow_redirects)
        local request_spec = spec
        if method then request_spec = { url = spec, method = method, body = body or "", headers = headers or {} } end
        local response, err = self:request(source, request_spec, env.keyword, env.page, {
            -- AnalyzeRule.ajax constructs AnalyzeUrl(url) with the default
            -- empty baseUrl.  Keep that logical context observable while the
            -- transport still falls back to the source origin for an
            -- absolute URL.
            base_url = "", network_base = "", referer = network_base,
            book = context.book, chapter = context.chapter, variables = context.variables,
        }, {
            skip_login_check = true,
            allow_http_errors = true,
            follow_redirects = follow_redirects ~= false,
            retries = 0,
        })
        if not response then env.last_js_error = tostring(err or "nested request failed"); return nil end
        markBrowserChallenge(response, request_spec)
        return response
    end
    env.ajax = function(spec)
        local response = nested(spec, nil, nil, nil, true)
        return response and response.body or ""
    end
    env.java.ajax = function(_, spec) return env.ajax(spec) end
    env.java.connect = function(_, spec) return responseProxy(nested(spec, nil, nil, nil, true)) end
    -- Several Legado request rules intentionally inspect a POST redirect's
    -- Location header.  Keep java.post's immediate response observable while
    -- ordinary plugin requests continue to follow redirects normally.
    env.java.post = function(_, url, body, headers)
        return responseProxy(nested(url, "POST", body, headers, false))
    end
    env.java.head = function(_, url, headers)
        return responseProxy(nested(url, "HEAD", "", headers, false))
    end
    return env
end

local function parseRequestSpec(self, spec, source, keyword, page, context)
    local env = jsEnvironment(source, context)
    env.keyword, env.key, env.searchKey, env.page = keyword or "", keyword or "", keyword or "", page or 1
    installRequestNetworkBridge(self, source, env, context)
    local function interactionFailure()
        if env.__interaction_required then
            return StageError:format("INTERACTION_REQUIRED", source, env.__interaction_required)
        end
        return nil
    end
    if type(spec) == "table" then
        local charset = spec.charset or spec.encoding
        local option_headers = parseHeaders(spec.headers or spec.header)
        local preserve_literal = hasContentType(option_headers) or hasContentType(parseHeaders(source and source.header))
        local body, body_is_json = renderBody(spec.body or "", keyword, page, charset, env, preserve_literal)
        local interaction_err = interactionFailure()
        if interaction_err then return nil, interaction_err end
        return {
            -- Legado request templates often begin with side-effect blocks on
            -- their own line.  Once those blocks evaluate to an empty string,
            -- the remaining URL may retain CR/LF indentation.  Treat URL
            -- whitespace as syntax, not as a relative-path byte sequence.
            url = Util.trim(renderTemplate(spec.url or spec[1], keyword, page, charset, env)),
            method = tostring(spec.method or "GET"):upper(),
            body = body,
            body_is_json = body_is_json,
            headers = option_headers,
            charset = charset,
            type = spec.type,
            web_view = spec.webView == true or spec.web_view == true,
            web_js = spec.webJs or spec.web_js,
        }
    end

    spec = tostring(spec or "")
    -- `<js>...</js>` request rules may synthesize an entire Legado request
    -- descriptor (`url,{...}`), not merely a URL fragment.  Execute embedded
    -- JS before looking for the descriptor delimiter so the generated method,
    -- body, headers and charset remain structural request options instead of
    -- becoming percent-encoded path text.  Keep {{...}} evaluation in the
    -- later render phase so charset-aware keyword expansion still sees the
    -- decoded request options first.
    if spec:find("<js>", 1, true) then
        spec = spec:gsub("<js>([%s%S]-)</js>", function(script)
            traceRule(source, env, "request.inlineJs", script)
            local result = QuickJS:eval(script, env)
            return result ~= nil and tostring(result) or ""
        end)
        local interaction_err = interactionFailure()
        if interaction_err then return nil, interaction_err end
    end
    local request_prefix, request_script = splitRequestScript(spec)
    if request_script then
        local rendered_prefix = Util.trim(renderTemplate(request_prefix, keyword, page, nil, env))
        env.result = rendered_prefix
        traceRule(source, env, "request.descriptorJs", request_script)
        local generated, err = QuickJS:eval(request_script, env)
        local interaction_err = interactionFailure()
        if interaction_err then return nil, interaction_err end
        if generated == nil then
            return nil, err or env.last_js_error or "request script did not return a request descriptor"
        end
        spec = tostring(generated)
    end
    if Util.trim(spec):lower():match("^@js:") then
        -- AnalyzeUrl.analyzeJs starts with result == the raw rule URL.  This
        -- is observable by scripts and is distinct from the later generated
        -- URL returned by the script.
        env.result = spec
        traceRule(source, env, "request.urlJs", spec)
        local result, err = QuickJS:eval(spec, env)
        local interaction_err = interactionFailure()
        if interaction_err then return nil, interaction_err end
        if result == nil then
            return nil, err or env.last_js_error or "请求脚本执行完成，但没有返回请求地址"
        end
        if type(result) == "table" then
            return parseRequestSpec(self, result, source, keyword, page, context)
        end
        spec = tostring(result)
    end
    spec = normalizeLegacyRequestMarkers(spec)
    local url_text, options_text = splitRequestOptions(spec)
    local options = decodeLooseObject(options_text) or {}
    local legacy_url, legacy_body = url_text:match("^(.-)@post%-%>(.*)$")
    if legacy_url then
        url_text, options.method, options.body = legacy_url, "POST", options.body or legacy_body
    end
    local charset = options.charset or options.encoding
    local option_headers = parseHeaders(options.headers or options.header)
    local preserve_literal = hasContentType(option_headers) or hasContentType(parseHeaders(source and source.header))
    local body, body_is_json = renderBody(options.body or "", keyword, page, charset, env, preserve_literal)
    local interaction_err = interactionFailure()
    if interaction_err then return nil, interaction_err end
    return {
        url = Util.trim(renderTemplate(url_text, keyword, page, charset, env)),
        method = tostring(options.method or "GET"):upper(),
        body = body,
        body_is_json = body_is_json,
        headers = option_headers,
        charset = charset,
        type = options.type,
        retry = options.retry,
        web_view = options.webView == true or options.web_view == true,
        web_js = options.webJs or options.web_js,
    }
end

local function mergeHeaders(target, source)
    for key, value in pairs(source or {}) do
        key = tostring(key):lower()
        if target[key] == nil or target[key] == "" then target[key] = tostring(value or "") end
    end
end

function LegadoSource:_saveRuntimeSource(source)
    if source and source._suppress_runtime_persist then return end
    -- Cookies and source variables change during ordinary requests. Persist only
    -- that tiny runtime state; never rewrite the full imported source pack.
    if storage_ok and Storage and Storage.saveSourceRuntime then
        pcall(Storage.saveSourceRuntime, Storage, source)
    end
end

function LegadoSource:_prepareRequest(source, spec, keyword, page, context)
    context = context or {}
    local logical_base = context.network_base ~= nil and context.network_base
        or (context.base_url ~= nil and context.base_url or source.base_url)
    local logical_url
    if type(spec) == "table" then
        logical_url = spec.url or spec[1] or ""
    else
        logical_url = spec
    end
    ExecutionTrace:urlContext(source, logical_url, logical_base)
    local request, parse_err = parseRequestSpec(self, spec, source, keyword, page, context)
    if not request then return nil, stageError("REQUEST_RULE_FAILED", source, parse_err) end
    request.headers = request.headers or {}
    local dynamic_header = source.header_rule
    if type(dynamic_header) == "string" and Util.trim(dynamic_header) ~= "" then
        local header_env = jsEnvironment(source, context)
        local rendered = dynamic_header
        if Util.trim(rendered):lower():match("^@js:") then
            traceRule(source, header_env, "request.headerJs", rendered)
            local evaluated = QuickJS:eval(rendered, header_env)
            if evaluated ~= nil then rendered = evaluated end
        else
            rendered = renderTemplate(rendered, keyword, page, nil, header_env)
        end
        mergeHeaders(request.headers, parseHeaders(rendered))
    end
    mergeHeaders(request.headers, source.header)
    -- Legado login headers are runtime request state. Search may succeed without
    -- them while detail/catalog endpoints reject the next request with HTTP 400.
    mergeHeaders(request.headers, parseHeaders(source.login_header))
    for key, value in pairs(copyTable(request.headers)) do
        local rendered = renderTemplate(value, keyword, page, request.charset, jsEnvironment(source, context))
        if rendered == "" then request.headers[key] = nil else request.headers[key] = rendered end
    end
    if (request.body_is_json or request.type and tostring(request.type):lower() == "json")
            and not request.headers["content-type"] then
        request.headers["content-type"] = "application/json"
    end
    local has_explicit_base = type(context) == "table"
        and (context.network_base ~= nil or context.base_url ~= nil)
    local supplied_base = type(context) == "table"
        and (context.network_base ~= nil and context.network_base or context.base_url)
        or nil
    local base_url = requestUrlPart(supplied_base ~= nil and supplied_base or source.base_url)
    if (not has_explicit_base or base_url ~= "")
            and not isHttpUrl(base_url) and not BuiltinSources:isFixtureUrl(base_url) then
        base_url = sourceNetworkBase(source.base_url or source.source_key)
    end
    -- An explicit empty baseUrl is a real Legado value for pagination.  Use a
    -- transport fallback only to resolve an accidentally relative descriptor;
    -- retain the empty logical resolution base in the trace.
    local transport_base = base_url ~= "" and base_url or source.base_url
    request.url = Http:absolute(transport_base, Util.trim(request.url))
    -- The prepared request is also the evidence boundary.  Normalize path and
    -- query bytes here, before validation and diagnostics, so a legitimate
    -- source URL containing spaces or non-ASCII query text is represented by
    -- the exact percent-encoded URL sent to the transport bridge.
    if type(Http.normalizeUrl) == "function" then request.url = Http:normalizeUrl(request.url) end
    request.resolution_base = base_url
    request.base_url = base_url
    local referer = requestUrlPart(context and (context.referer or context.network_base or context.base_url) or source.base_url)
    -- Never send a Legado request descriptor (URL + JSON options) as Referer.
    -- Some servers reject that malformed header as HTTP 400.
    if not request.headers.referer and referer:match("^https?://") then
        request.headers.referer = referer
    end
    if request.url == "" then
        return nil, StageError:format("REQUEST_URL_EMPTY", source, "规则没有生成地址")
    end
    local valid_scheme = isHttpUrl(request.url) or DataUri:is(request.url)
        or BuiltinSources:isFixtureUrl(request.url)
    if not valid_scheme then
        return nil, StageError:format("REQUEST_URL_INVALID", source,
            "无法解析为 HTTP、data 或内置地址：" .. tostring(request.url):sub(1, 180))
    end
    local cookie = isHttpUrl(request.url) and CookieJar:header(source, request.url) or ""
    if cookie ~= "" and not request.headers.cookie then request.headers.cookie = cookie end
    request.retries = tonumber(request.retry) or 1
    return request
end

local function virtualResponse(request, max_bytes)
    if not DataUri:is(request and request.url) then return nil end
    local decoded, decode_err = DataUri:decode(request.url, { max_bytes = max_bytes })
    if not decoded then return false, decode_err end
    return {
        url = request.url,
        request_base_url = request.resolution_base,
        code = 200,
        headers = { ["content-type"] = decoded.content_type },
        content_type = decoded.content_type,
        body = decoded.body,
        status = "200 data URI",
        virtual = true,
        data_metadata = decoded.metadata,
        request_type = request.type,
    }
end

function LegadoSource:requestBinary(source, spec, context, options)
    options = options or {}
    local request, prepare_err = self:_prepareRequest(source, spec, nil, 1, context)
    if not request then return nil, prepare_err end
    local trace_request = ExecutionTrace:requestStart(source, request)
    if BuiltinSources:isFixtureUrl(request.url) then
        local fixture, fixture_err = BuiltinSources:request(request.url)
        ExecutionTrace:requestEnd(source, trace_request, fixture, fixture_err)
        return fixture, fixture_err
    end
    local virtual, virtual_err = virtualResponse(request, options.max_bytes or (4 * 1024 * 1024))
    if virtual == false then
        ExecutionTrace:requestEnd(source, trace_request, nil, virtual_err)
        return nil, StageError:format("DATA_URI_INVALID", source, virtual_err)
    end
    if virtual then
        ExecutionTrace:requestEnd(source, trace_request, virtual)
        return virtual
    end
    request.accept = options.accept or "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    if type(options.headers) == "table" then
        request.headers = request.headers or {}
        for name, value in pairs(options.headers) do request.headers[name] = value end
    end
    request.max_bytes = options.max_bytes or (4 * 1024 * 1024)
    request.retries = options.retries == nil and 0 or options.retries
    request.timeout = options.timeout or request.timeout
    request.maxtime = options.maxtime or request.maxtime
    request.max_redirects = options.max_redirects or request.max_redirects
    local response, err = Http:request(request)
    if not response then
        ExecutionTrace:requestEnd(source, trace_request, nil, err)
        return nil, tostring(source.name or "书源") .. "：" .. tostring(err or "请求失败")
    end
    ExecutionTrace:requestEnd(source, trace_request, response)
    if Util.trim(tostring(response.request_url or "")) == "" then response.request_url = request.url end
    if Util.trim(tostring(response.request_base_url or "")) == "" then response.request_base_url = request.resolution_base end
    if Util.trim(tostring(response.url or "")) == "" then response.url = request.url end
    ExecutionTrace:requestEnd(source, trace_request, response)
    if CookieJar:addFromHeaders(source, response.url, response.headers) then
        ExecutionTrace:sideEffect(source, "cookie", "response", response.url)
        self:_saveRuntimeSource(source)
    end
    return response
end

function LegadoSource:request(source, spec, keyword, page, context, request_options)
    local request, prepare_err = self:_prepareRequest(source, spec, keyword, page, context)
    if not request then return nil, prepare_err end
    local trace_request = ExecutionTrace:requestStart(source, request)
    if BuiltinSources:isFixtureUrl(request.url) then
        local fixture, fixture_err = BuiltinSources:request(request.url)
        ExecutionTrace:requestEnd(source, trace_request, fixture, fixture_err)
        return fixture, fixture_err
    end
    request_options = request_options or {}
    local virtual, virtual_err = virtualResponse(request, request_options.max_bytes or (8 * 1024 * 1024))
    if virtual == false then
        ExecutionTrace:requestEnd(source, trace_request, nil, virtual_err)
        return nil, StageError:format("DATA_URI_INVALID", source, virtual_err)
    end
    if virtual then
        ExecutionTrace:requestEnd(source, trace_request, virtual)
        return virtual
    end
    if request_options.timeout ~= nil then request.timeout = request_options.timeout end
    if request_options.maxtime ~= nil then request.maxtime = request_options.maxtime end
    if request_options.retries ~= nil then request.retries = request_options.retries end
    if request_options.max_bytes ~= nil then request.max_bytes = request_options.max_bytes end
    if request_options.max_redirects ~= nil then request.max_redirects = request_options.max_redirects end
    if request_options.follow_redirects ~= nil then request.follow_redirects = request_options.follow_redirects end
    if request_options.allow_http_errors ~= nil then request.allow_http_errors = request_options.allow_http_errors end
    if request_options.discard_body ~= nil then request.discard_body = request_options.discard_body end
    -- Full HTTP bodies are far too noisy for normal UI errors, but the explicit
    -- compatibility diagnostic must be lossless. The diagnostic runs in an
    -- isolated child and writes its own append-only log, so keep the raw body.
    if source._diagnostic_full_errors == true or request_options.full_error_body == true then
        request.full_error_body = true
    end

    -- AnalyzeUrl enters its WebView branch only when the URL descriptor asks
    -- for webView=true.  In ordinary HTTP mode, webJs/sourceRegex are still
    -- passed as transport options but are not evaluated or applied by
    -- AnalyzeUrl; preserving that distinction is observable in the request
    -- count and in the returned body.
    if request.web_view == true then
        if request_options.web_js and Util.trim(tostring(request_options.web_js)) ~= "" then
            ExecutionTrace:branch(source, "webjs-webview-boundary", "content", "ruleContent.webJs", {
                value = request_options.web_js,
            })
        end
        if request_options.source_regex and Util.trim(tostring(request_options.source_regex)) ~= "" then
            ExecutionTrace:branch(source, "source-regex-webview-boundary", "content", "ruleContent.sourceRegex", {
                value = request_options.source_regex,
            })
        end
        local webview_err = stageError("WEBVIEW_REQUIRED", source,
            "AnalyzeUrl WebView transport requires browser DOM capability; this text-only host does not execute it")
        ExecutionTrace:requestEnd(source, trace_request, nil, webview_err)
        return nil, webview_err
    end
    if request_options.web_js and Util.trim(tostring(request_options.web_js)) ~= "" then
        ExecutionTrace:branch(source, "webjs-transport-option", "content", "ruleContent.webJs", {
            value = request_options.web_js,
        })
    end

    local response, err = Http:request(request)
    if not response then
        ExecutionTrace:requestEnd(source, trace_request, nil, err)
        return nil, tostring(source.name or "书源") .. "：" .. tostring(err or "请求失败")
    end
    ExecutionTrace:requestEnd(source, trace_request, response)
    if Util.trim(tostring(response.request_url or "")) == "" then response.request_url = request.url end
    if Util.trim(tostring(response.request_base_url or "")) == "" then response.request_base_url = request.resolution_base end
    if Util.trim(tostring(response.url or "")) == "" then response.url = request.url end
    ExecutionTrace:requestEnd(source, trace_request, response)
    if CookieJar:addFromHeaders(source, response.url, response.headers) then
        ExecutionTrace:sideEffect(source, "cookie", "response", response.url)
        self:_saveRuntimeSource(source)
    end

    if type(response.body) == "string" then
        local detected = Charset:detect(response.body, response.content_type, request.charset)
        local decoded, decode_err = Charset:decode(response.body, detected)
        if not decoded then return nil, stageError("CHARSET_FAILED", source, tostring(detected) .. "：" .. tostring(decode_err)) end
        response.body, response.charset = decoded, detected
    end
    -- Legado runs loginCheckJs on the actual response.  Do not reject the
    -- entire source merely because an interactive branch exists: execute it,
    -- and fail explicitly only when that branch is actually taken.
    if not request_options.skip_login_check and source.login_check_js and source.login_check_js ~= "" then
        ExecutionTrace:branch(source, "login-check-js", ExecutionTrace:get(source) and ExecutionTrace:get(source).stage,
            "request.loginCheckJs", { value = source.login_check_js })
        local login_url = tostring(response.url or response.request_url or response.request_base_url or "")
        local login_base_url = login_url:match("^(https?://[^/%?#]+)") or tostring(response.request_base_url or login_url)
        local login_env = makeRuleEnv(self, source, response, {
            keyword = keyword, key = keyword, page = page,
            book = context and context.book, chapter = context and context.chapter,
            variables = context and context.variables or source.variables,
            base_url = login_base_url, request_base_url = login_base_url,
            network_base = login_base_url, referer = login_url,
            __in_login_check = true,
        })
        login_env.base_url, login_env.baseUrl = login_base_url, login_base_url
        login_env.result = responseProxy(response)
        login_env.__in_login_check = true
        traceRule(source, login_env, "request.loginCheckJs", source.login_check_js)
        local checked, login_err = QuickJS:eval(source.login_check_js, login_env)
        if login_env.__interaction_required then
            return nil, StageError:format("INTERACTION_REQUIRED", source, login_env.__interaction_required)
        end
        if login_err then
            return nil, StageError:format("LOGIN_CHECK_FAILED", source, login_err)
        end
        if type(checked) == "string" and checked ~= "" then response.body = checked end
    end
    return response
end

responseProxy = function(response)
    response = response or { body = "", url = "", headers = {} }
    local proxy = {}
    local function headerValue(name)
        name = tostring(name or ""):lower()
        for key, value in pairs(response.headers or {}) do
            if tostring(key):lower() == name then return value end
        end
        return nil
    end
    proxy.body = function() return response.body or "" end
    proxy.url = function() return response.url or response.request_url or response.request_base_url or "" end
    proxy.code = function() return response.code or 0 end
    proxy.statusCode = proxy.code
    proxy.isSuccessful = function()
        local code = tonumber(response.code) or 0
        return code >= 200 and code < 300
    end
    proxy.cookies = function() return headerValue("set-cookie") or "" end
    proxy.header = function(_, name) return headerValue(name) or "" end
    proxy.headers = function()
        local headers = copyTable(response.headers or {})
        headers.get = function(self, key)
            key = tostring(key or ""):lower()
            for name, value in pairs(self) do if tostring(name):lower() == key then return value end end
        end
        headers.names = function(self)
            local result = {}; for name in pairs(self) do if type(name) == "string" then result[#result + 1] = name end end
            return result
        end
        return headers
    end
    proxy.request = function()
        return { url = function() return response.url or response.request_url or response.request_base_url or "" end }
    end
    proxy.raw = function() return proxy end
    proxy.toString = function() return tostring(response.body or "") end
    return proxy
end

makeRuleEnv = function(self, source, response, extra)
    local env = jsEnvironment(source, extra)
    local trace = ExecutionTrace:get(source)
    if trace then
        rawset(env, "__diagnostic_trace", trace)
        rawset(env, "__diagnostic_stage", trace.stage or source._diagnostic_stage or "source")
    end
    local rule_url = responseRuleUrl(response)
    env.base_url, env.baseUrl = rule_url, rule_url
    -- Preserve the exact response body for pure `@js:` rules.  The parsed
    -- document remains the selector context, but Legado scripts such as
    -- `JSON.parse(result).data` must see the original JSON/text payload.
    env.__raw_response_body = type(response.body) == "string" and response.body or tostring(response.body or "")
    env.currentResponse = responseProxy(response)
    env.parseHtml = function(value) return RuleEngine:parseDocument(tostring(value or "")) end
    local function jsoupCollection(values, owner, owner_first, owner_last)
        values = type(values) == "table" and values or { values }
        local collection = { __values = values }
        local function firstNode() return values[1] end
        local function wrap(items) return jsoupCollection(items) end
        collection.select = function(_, selector)
            local selected = {}
            for _, item in ipairs(values) do
                for _, node in ipairs(RuleEngine:select(item, tostring(selector or ""), env)) do selected[#selected + 1] = node end
            end
            return wrap(selected)
        end
        collection.selectFirst = function(self, selector) return self:select(selector):first() end
        collection.text = function()
            local output = {}
            for _, item in ipairs(values) do
                local text = RuleEngine:extract(item, "text", response.url, " ", env)
                if text == "" then text = Util.stripHtml(RuleEngine:toSource(item)) end
                if text ~= "" then output[#output + 1] = text end
            end
            return table.concat(output, " ")
        end
        collection.eachText = function()
            local output = {}; for _, item in ipairs(values) do output[#output + 1] = wrap({ item }):text() end
            return output
        end
        collection.html = function()
            local output = {}; for _, item in ipairs(values) do output[#output + 1] = RuleEngine:toSource(item) end
            return table.concat(output, "\n")
        end
        collection.outerHtml = function()
            local output = {}
            for _, item in ipairs(values) do
                output[#output + 1] = RuleEngine:toOuterSource(item)
            end
            return table.concat(output, "\n")
        end
        collection.attr = function(_, name)
            local item = firstNode(); if not item then return "" end
            return RuleEngine:extract(item, "@" .. tostring(name or ""), response.url, "", env)
        end
        collection.hasClass = function(self, name)
            local classes = " " .. tostring(self:attr("class") or "") .. " "
            return classes:find(" " .. tostring(name or "") .. " ", 1, true) ~= nil
        end
        collection.toArray = function()
            local output = {}; for _, item in ipairs(values) do output[#output + 1] = wrap({ item }) end
            return output
        end
        collection.first = function() return firstNode() and wrap({ firstNode() }) or wrap({}) end
        collection.get = function(_, index)
            index = tonumber(index) or 0; return values[index + 1] and wrap({ values[index + 1] }) or nil
        end
        collection.size = function() return #values end
        collection.parent = function()
            local item = firstNode(); return item and item.parent and wrap({ item.parent }) or wrap({})
        end
        collection.parents = function()
            local output, item = {}, firstNode()
            item = item and item.parent
            while item do output[#output + 1] = item; item = item.parent end
            return wrap(output)
        end
        collection.contains = function(_, other)
            local target = type(other) == "table" and other.__values and other.__values[1] or other
            local item = target
            while item do
                for _, candidate in ipairs(values) do if item == candidate then return true end end
                item = type(item) == "table" and item.parent or nil
            end
            return false
        end
        collection.remove = function(_, index)
            if index ~= nil then table.remove(values, (tonumber(index) or 0) + 1); return collection end
            for _, item in ipairs(values) do
                if type(item) == "table" and item.parent and type(item.parent.nodes) == "table" then
                    for pos = #item.parent.nodes, 1, -1 do if item.parent.nodes[pos] == item then table.remove(item.parent.nodes, pos) end end
                end
            end
            for pos = #values, 1, -1 do values[pos] = nil end
            return collection
        end
        collection.subList = function(_, first, last)
            first, last = tonumber(first) or 0, tonumber(last) or #values
            local subset = {}; for index = first + 1, math.min(last, #values) do subset[#subset + 1] = values[index] end
            return jsoupCollection(subset, values, first + 1, math.min(last, #values))
        end
        collection.clear = function()
            if owner then for index = owner_last, owner_first, -1 do table.remove(owner, index) end end
            for index = #values, 1, -1 do values[index] = nil end
            return nil
        end
        collection.toString = collection.outerHtml
        return collection
    end
    env.jsoupParse = function(value)
        local parsed = RuleEngine:parseDocument(tostring(value or ""))
        return jsoupCollection({ parsed })
    end
    local function connect(spec, method, body, headers)
        local request_spec = spec
        if method then request_spec = { url = spec, method = method, body = body or "", headers = headers or {} } end
        local nested = self:request(source, request_spec, env.keyword, env.page, {
            -- AnalyzeRule.ajax/connect constructs AnalyzeUrl(url) without a
            -- baseUrl.  Keep the empty logical base even though the request
            -- transport needs the source origin to resolve an absolute URL.
            base_url = "",
            network_base = "",
            referer = isHttpUrl(response.url) and response.url or response.request_base_url,
            book = env.book, chapter = env.chapter,
        }, { skip_login_check = env.__in_login_check == true })
        return nested
    end
    env.ajax = function(spec)
        local nested = connect(spec)
        return nested and nested.body or ""
    end
    env.ajaxAll = function(specs)
        local output = {}
        for _, spec in ipairs(type(specs) == "table" and specs or {}) do
            local nested = connect(spec)
            output[#output + 1] = responseProxy(nested)
        end
        return output
    end
    local utility_json = legadoUtilityJson()
    env.java = {
        ajax = function(_, spec) return env.ajax(spec) end,
        ajaxAll = function(_, specs) return env.ajaxAll(specs) end,
        ajaxTestAll = function(_, specs) return env.ajaxAll(specs) end,
        connect = function(_, spec) return responseProxy(connect(spec)) end,
        post = function(_, url, body, headers) return responseProxy(connect(url, "POST", body, headers)) end,
        head = function(_, url, headers) return responseProxy(connect(url, "HEAD", "", headers)) end,
        get = function(_, key, headers)
            key = tostring(key or "")
            if key:match("^https?://") or key:sub(1, 1) == "/" then return responseProxy(connect(key, "GET", "", headers)) end
            if key == "util" then return utility_json end
            return env.variables[key] or ""
        end,
        put = function(_, key, value) env.variables[tostring(key)] = value; return value end,
        refreshTocUrl = function() env.__refresh_toc = true; return true end,
        refreshContent = function() env.__refresh_content = true; return true end,
        refreshBookUrl = function() env.__refresh_book_url = true; return true end,
        refreshBookInfo = function() env.__refresh_book_info = true; return true end,
        refreshExplore = function() env.__refresh_explore = true; return true end,
        getStrResponse = function() return env.currentResponse end,
        initUrl = function() return response.url or "" end,
        searchBook = function(_, key, group) env.__search_book = { key = key, group = group }; return true end,
        upLoginData = function(_, value) env.__login_data = value; return true end,
        startBrowser = function(_, url) env.__interaction_required = "INTERACTION_REQUIRED: 浏览器：" .. tostring(url or ""); env.last_js_error = env.__interaction_required; return "" end,
        startBrowserAwait = function(_, url) env.__interaction_required = "INTERACTION_REQUIRED: 浏览器验证：" .. tostring(url or ""); env.last_js_error = env.__interaction_required; return "" end,
        webView = function(_, url) env.__interaction_required = "INTERACTION_REQUIRED: WebView：" .. tostring(url or ""); env.last_js_error = env.__interaction_required; return "" end,
        webview = function(_, url) env.__interaction_required = "INTERACTION_REQUIRED: WebView：" .. tostring(url or ""); env.last_js_error = env.__interaction_required; return "" end,
        showBrowser = function(_, url) env.__interaction_required = "INTERACTION_REQUIRED: 浏览器：" .. tostring(url or ""); env.last_js_error = env.__interaction_required; return "" end,
        getVerificationCode = function() env.__interaction_required = "INTERACTION_REQUIRED: 验证码"; env.last_js_error = env.__interaction_required; return "" end,
    }
    env.java.toast = function(_, message)
        env.__host_warnings = env.__host_warnings or {}
        env.__host_warnings[#env.__host_warnings + 1] =
            "java.toast unavailable on KOReader: " .. tostring(message or "")
        return nil
    end
    env.java.longToast = function(_, message)
        env.__host_warnings = env.__host_warnings or {}
        env.__host_warnings[#env.__host_warnings + 1] =
            "java.longToast unavailable on KOReader: " .. tostring(message or "")
        return nil
    end
    env.java.ruleUrl = rule_url or ""
    return env
end

local CACHE_TTL = {
    search = 24 * 60 * 60,
    bookinfo = 24 * 60 * 60,
    toc = 6 * 60 * 60,
}

local function cacheRead(kind, key)
    if not storage_ok or not Storage or not Storage.readCache then return nil end
    return Storage:readCache(kind, key, CACHE_TTL[kind])
end

local function cacheWrite(kind, key, value)
    if storage_ok and Storage and Storage.writeCache then
        Storage:writeCache(kind, key, value)
    end
end

local function checkSupported(source)
    if source.supported == false or not structurallyExecutable(source) then
        return nil, StageError:format("SOURCE_UNSUPPORTED", source,
            source.unsupported_reason or table.concat(source.compatibility_reasons or {}, "；"))
    end
    return true
end

local function parsePage(response)
    return RuleEngine:parseDocument(response.body, response.content_type)
end

local function initializedContext(document, rules, env)
    local init_rule = firstRule(rules, "init", "initial", "root")
    if not init_rule then return document end
    local values = RuleEngine:select(document, init_rule, env)
    if #values > 0 then return values[1] end
    local extracted = RuleEngine:extractAll(document, init_rule, env and env.base_url, env)
    return #extracted > 0 and extracted[1] or document
end

local normalizeCoverCandidate

local function parseBookInfoResponse(self, source, seed, response, options)
    options = options or {}
    local response_url = responseRuleUrl(response)
    local document = parsePage(response)
    local rules = source.rule_book_info
    local info = copyTable(seed or {})
    info.variables = copyTable((seed and seed.variables) or source.variables)
    if options.refresh_cover then info.cover = nil end
    local env = makeRuleEnv(self, source, response, { book = info, variables = info.variables })
    local context = initializedContext(document, rules, env)
    local mappings = {
        { "title", { "name", "bookName", "title" } },
        { "author", { "author", "writer" } },
        { "kind", { "kind" } },
        { "word_count", { "wordCount", "word_count" } },
        { "intro", { "intro", "description" } },
        { "cover", { "coverUrl", "cover", "image" } },
        { "last_chapter", { "lastChapter", "latestChapter", "latestChapterTitle" } },
    }
    -- BookInfo exposes scalar fields as stable empty strings when a source
    -- omits an optional rule.  Keep the structured production result aligned
    -- with Legado without placing any response HTML in the persisted book.
    for _, mapping in ipairs(mappings) do
        if info[mapping[1]] == nil then info[mapping[1]] = "" end
    end
    for _, mapping in ipairs(mappings) do
        local field, names = mapping[1], mapping[2]
        local rule = firstRule(rules, unpack(names))
        traceRule(source, env, "bookInfo." .. field, rule)
        local value = field == "cover" and RuleEngine:extractUrl(context, rule, response_url, env)
            or RuleEngine:extract(context, rule, response_url, "", env)
        if field == "cover" then value = normalizeCoverCandidate(value, response_url) end
        if nonEmptyScalar(value) then
            info[field] = field == "cover" and value or Util.collapseSpaces(value)
        end
    end
    local toc_rule = firstRule(rules, "tocUrl", "toc_url", "catalogUrl")
    traceRule(source, env, "bookInfo.tocUrl", toc_rule)
    local toc_url = RuleEngine:extractUrl(context, toc_rule, response_url, env)
    if toc_rule and toc_url == "" and env.last_js_error then
        return nil, env.last_js_error
    end
    if toc_url == "" then toc_url = tostring(info.toc_url or "") end
    if toc_url == "" then toc_url = response_url end
    info.toc_url = resolveRuleRequest(toc_url, response_url, response.request_base_url)
    info._detail_base_url = response_url
    info._detail_response_url = tostring(response.url or response_url or "")
    info._detail_request_base_url = tostring(response.request_base_url or response_url or "")
    info._detail_content_type = response.content_type or "text/html"
    info._detail_code = response.code or response.status or 200
    info._detail_status = response.status or response.code or 200
    -- Legado keeps the detail response as tocHtml when the empty tocUrl
    -- fallback resolves to the same book URL.  The TOC/content stages must be
    -- able to consume that exact response without issuing a second request.
    info.info_html = response.body
    if tostring(info.toc_url or "") == tostring(info.book_url or "")
            or tostring(info.toc_url or "") == tostring(response_url or "") then
        info.toc_html = response.body
    end
    info.variables = copyTable(env.variables)
    -- The second return value is an execution environment, not an error.
    -- The direct-detail search path only needs the error slot to be non-nil
    -- when parsing actually failed; returning env here made every response
    -- without a search list look like `DETAIL_PARSE_FAILED: table: 0x...`.
    -- Keep the environment available as an optional third result for focused
    -- diagnostics without changing the normal `(info, err)` contract.
    return info, nil, env
end


normalizeCoverCandidate = function(value, base_url)
    if type(value) == "table" then return "" end
    value = Util.trim(Util.htmlEntityDecode(tostring(value or "")))
    if value == "" then return "" end
    local lower = value:lower()
    if lower == "" or lower == "null" or lower == "nil" or lower:match("^table:%s*")
            or lower:match("^javascript:") or lower:match("^about:") then return "" end
    -- A rule may intentionally return a data URI or a Legado request descriptor;
    -- both are opaque values until the request layer handles them.
    if lower:match("^data:image/") or value:find(",%s*{") then return value end
    return Http:absolute(base_url, value)
end

function LegadoSource:search(source, keyword, page, options)
    options = options or {}
    local ok, support_err = checkSupported(source)
    if not ok then return nil, support_err end
    source._last_search_diagnostic = nil
    page = page or 1
    local cache_key = table.concat({ tostring(source.id), tostring(keyword or ""), tostring(page) }, "\n")
    local cached = options.cache_read ~= false and cacheRead("search", cache_key) or nil
    if type(cached) == "table" then
        local limit = tonumber(options.max_results)
        if not limit or #cached <= limit then return cached end
        local bounded = {}
        for index = 1, math.max(1, math.floor(limit)) do bounded[index] = cached[index] end
        return bounded
    end
    local suppress_runtime = options.save_runtime == false
    local previous_runtime_suppression = source._suppress_runtime_persist
    if suppress_runtime then source._suppress_runtime_persist = true end
    local function restoreRuntimeSuppression()
        if suppress_runtime then source._suppress_runtime_persist = previous_runtime_suppression end
    end
    local response, err = self:request(source, source.search_url, keyword, page,
        { keyword = keyword, page = page }, options.request_options)
    if not response then
        restoreRuntimeSuppression()
        return nil, stageError("SEARCH_REQUEST_FAILED", source, err)
    end
    local response_url = responseRuleUrl(response)
    local document = parsePage(response)
    local rules, env = source.rule_search, makeRuleEnv(self, source, response, { keyword = keyword, page = page or 1 })
    local context = initializedContext(document, rules, env)
    local list_rule = firstRule(rules, "bookList", "book_list", "list")
    traceRule(source, env, "search.bookList", list_rule)
    local nodes = RuleEngine:select(context, list_rule, env)
    local book_url_pattern = Util.trim(tostring(source.book_url_pattern or ""))
    local detail_url_match = false
    if book_url_pattern ~= "" then
        local pattern_ok, pattern_result = pcall(function()
            return Regex:test(response_url, "^(?:" .. book_url_pattern .. ")$")
        end)
        detail_url_match = pattern_ok and pattern_result == true
    end
    if detail_url_match or (book_url_pattern == "" and #nodes == 0) then
        local seed = {
            source_id = source.id,
            variables = copyTable(source.variables),
            _search_base_url = response_url,
            book_url = response_url,
        }
        local info, detail_err = parseBookInfoResponse(self, source, seed, response, {})
        if detail_err then
            restoreRuntimeSuppression()
            return nil, stageError("DETAIL_PARSE_FAILED", source, detail_err)
        end
        if info and nonEmptyScalar(info.title) then
            info.info_html = response.body
            restoreRuntimeSuppression()
            if options.save_runtime ~= false then self:_saveRuntimeSource(source) end
            if options.cache_write ~= false then
                local cached_info = copyTable(info)
                cached_info.toc_html = nil
                cached_info.info_html = nil
                cacheWrite("search", cache_key, { cached_info })
            end
            return { info }
        end
        restoreRuntimeSuppression()
        return {}
    end
    setSearchDiagnostic(source, response, list_rule, #nodes)
    if source._last_search_diagnostic then
        if #nodes == 0 and not env.last_js_error then
            source._last_search_diagnostic.response_class = classifySearchResponse(response)
        end
        source._last_search_diagnostic.parser_outcome = env.last_js_error and "script_error"
            or (#nodes == 0 and "empty_list_selection" or "list_nodes_found")
    end
    if #nodes == 0 and env.last_js_error then
        restoreRuntimeSuppression()
        return nil, stageError("SCRIPT_UNSUPPORTED", source, env.last_js_error)
    end
    local results = {}
    local max_results = math.max(1, tonumber(options.max_results or math.huge) or math.huge)
    for _, node in ipairs(nodes) do
        -- SearchBook is mutable while rules are evaluated.  Real Legado rules
        -- commonly populate kind/wordCount/lastChapter first and reference
        -- those fields from a later bookUrl script.  Keeping one shared env
        -- without a bound book silently loses IDs such as book.kind.
        local candidate = {
            source_id = source.id,
            variables = copyTable(source.variables),
            _search_base_url = response_url,
        }
        retainJsonNodeFields(candidate, node)
        env.variables = candidate.variables
        bindBookEnvironment(env, source, candidate)

        local function textField(field, names)
            local rule = firstRule(rules, unpack(names))
            traceRule(source, env, "search." .. field, rule)
            local value = RuleEngine:extract(node, rule, response_url, "", env)
            if nonEmptyScalar(value) then candidate[field] = Util.collapseSpaces(value) end
            return candidate[field] or ""
        end
        textField("title", { "name", "bookName", "title" })
        textField("author", { "author", "writer" })
        textField("kind", { "kind" })
        textField("word_count", { "wordCount", "word_count" })
        textField("intro", { "intro", "description" })
        textField("last_chapter", { "lastChapter", "latestChapter", "latestChapterTitle" })

        local cover_rule = firstRule(rules, "coverUrl", "cover", "image")
        traceRule(source, env, "search.cover", cover_rule)
        local cover = normalizeCoverCandidate(RuleEngine:extractUrl(node, cover_rule, response_url, env), response_url)
        -- Field scripts may assign `book.coverUrl/book.bookUrl/book.tocUrl` as
        -- their primary side effect and intentionally return nothing.  Those
        -- assignments already landed on the mutable SearchBook proxy; never
        -- erase them merely because the scalar rule result is empty.
        if cover == "" then cover = normalizeCoverCandidate(candidate.cover or "", response_url) end
        candidate.cover = cover

        local book_url_rule = firstRule(rules, "bookUrl", "book_url", "url")
        traceRule(source, env, "search.bookUrl", book_url_rule)
        local book_url = RuleEngine:extractUrl(node, book_url_rule, response_url, env)
        if not nonEmptyScalar(book_url) then book_url = "" end
        if book_url == "" then
            -- Only an explicit JS assignment to the mutable SearchBook proxy
            -- may supply a value here.  Do not promote an arbitrary JSON
            -- `detailedUrl` field when the declared Legado bookUrl rule is
            -- empty; the fixed BookList contract falls back directly to the
            -- search response base URL.
            book_url = tostring(candidate.book_url or "")
        end
        if book_url == "" then book_url = response_url or "" end
        candidate.book_url = resolveRuleRequest(book_url, response_url, response.request_base_url)

        local toc_rule = firstRule(rules, "tocUrl", "toc_url", "catalogUrl")
        traceRule(source, env, "search.tocUrl", toc_rule)
        local toc_value = RuleEngine:extractUrl(node, toc_rule, response_url, env)
        if not nonEmptyScalar(toc_value) then toc_value = "" end
        if toc_value == "" then toc_value = tostring(candidate.toc_url or "") end
        candidate.toc_url = toc_value ~= "" and resolveRuleRequest(toc_value, response_url, response.request_base_url) or nil
        candidate.variables = copyTable(env.variables)

        if tostring(candidate.title or "") ~= "" and tostring(candidate.book_url or "") ~= "" then
            results[#results + 1] = candidate
            local exact_query = options.exact_title_query
            if nonEmptyScalar(exact_query) then
                local score = BookIdentity:searchScore(exact_query, candidate.title, candidate.author)
                if score == 1000 then break end
            end
            if #results >= max_results then break end
        end
    end
    if #nodes > 0 and #results == 0 then
        restoreRuntimeSuppression()
        if source._last_search_diagnostic then source._last_search_diagnostic.parser_outcome = "candidate_fields_empty" end
        local message = env.last_js_error or "找到了列表节点，但书名或详情地址均为空"
        if source._diagnostic_full_errors == true then
            local name_rule = firstRule(rules, "name", "bookName", "title")
            local url_rule = firstRule(rules, "bookUrl", "book_url", "url")
            message = message .. " · nodes=" .. tostring(#nodes)
                .. " · name{" .. diagnosticParseMeta(source, response, name_rule) .. "}"
                .. " · bookUrl{" .. diagnosticParseMeta(source, response, url_rule) .. "}"
        end
        return nil, stageError("SEARCH_PARSE_EMPTY", source, message)
    end
    restoreRuntimeSuppression()
    if options.save_runtime ~= false then self:_saveRuntimeSource(source) end
    if options.cache_write ~= false then cacheWrite("search", cache_key, results) end
    return results
end

function LegadoSource:getBookInfo(source, result, options)
    options = options or {}
    local ok, support_err = checkSupported(source)
    if not ok then return nil, support_err end
    local cache_key = tostring(source.id) .. "\n" .. tostring(result.book_url or "")
    local cached = options.cache_read ~= false and cacheRead("bookinfo", cache_key) or nil
    if type(cached) == "table" then
        local cached_cover = tostring(cached.cover or "")
        -- A compact metadata cache is not a substitute for the original
        -- response: WebBook may reuse that exact response as tocHtml/content
        -- input.  Only a bounded cached body may take this fast path.
        local cached_body = cached.toc_html or cached.info_html
        if type(cached_body) == "string" and #cached_body <= (8 * 1024 * 1024)
                and not options.refresh_cover and (not options.require_cover or cached_cover ~= "") then
            return cached
        end
        -- An earlier cache may contain an empty, inherited or stale cover. An explicit
        -- cover-resolution request must re-read the detail page instead.
    end
    -- WebBook.getBookInfoAwait reuses SearchBook.infoHtml when it is already
    -- present.  Otherwise AnalyzeUrl(book.bookUrl) uses bookSourceUrl as its
    -- network base; the search response URL is not the detail rule base.
    local response, err
    if tostring(result.info_html or "") ~= "" then
        response = {
            url = result.book_url, request_url = result.book_url,
            request_base_url = result.book_url, body = result.info_html,
            headers = {}, code = 200, status = 200, content_type = "text/html",
        }
        ExecutionTrace:branch(source, "info-html-reuse", "detail", "book.infoHtml", {
            value = result.info_html,
        })
    else
        local detail_base = source.base_url
        response, err = self:request(source, result.book_url, nil, 1, {
            book = result,
            base_url = detail_base,
            referer = detail_base,
        })
    end
    if not response then return nil, stageError("DETAIL_REQUEST_FAILED", source, err) end
    local response_url = responseRuleUrl(response)
    local document = parsePage(response)
    local rules = source.rule_book_info
    local info = copyTable(result)
    info.variables = copyTable(result.variables or source.variables)
    if options.refresh_cover then info.cover = nil end
    local env = makeRuleEnv(self, source, response, { book = info, variables = info.variables })
    local context = initializedContext(document, rules, env)
    local mappings = {
        { "title", { "name", "bookName", "title" } },
        { "author", { "author", "writer" } },
        { "kind", { "kind" } },
        { "word_count", { "wordCount", "word_count" } },
        { "intro", { "intro", "description" } },
        { "cover", { "coverUrl", "cover", "image" } },
        { "last_chapter", { "lastChapter", "latestChapter", "latestChapterTitle" } },
    }
    for _, mapping in ipairs(mappings) do
        if info[mapping[1]] == nil then info[mapping[1]] = "" end
    end
    for _, mapping in ipairs(mappings) do
        local field, names = mapping[1], mapping[2]
        local rule = firstRule(rules, unpack(names))
        traceRule(source, env, "bookInfo." .. field, rule)
        local value = field == "cover" and RuleEngine:extractUrl(context, rule, response_url, env)
            or RuleEngine:extract(context, rule, response_url, "", env)
        if field == "cover" then value = normalizeCoverCandidate(value, response_url) end
        if nonEmptyScalar(value) then
            info[field] = field == "cover" and value or Util.collapseSpaces(value)
        end
    end
    local toc_rule = firstRule(rules, "tocUrl", "toc_url", "catalogUrl")
    traceRule(source, env, "bookInfo.tocUrl", toc_rule)
    local toc_url = RuleEngine:extractUrl(context, toc_rule, response_url, env)
    if toc_rule and toc_url == "" and env.last_js_error then
        return nil, stageError("DETAIL_PARSE_FAILED", source, env.last_js_error)
    end
    -- `init` and tocUrl scripts are allowed to assign book.tocUrl directly.
    -- Preserve that mutable BookInfo state when the rule has no scalar return.
    if toc_url == "" then toc_url = tostring(info.toc_url or "") end
    info.toc_url = toc_url ~= "" and resolveRuleRequest(toc_url, response_url, response.request_base_url) or response_url
    info._detail_base_url = response_url
    info._detail_response_url = tostring(response.url or response_url or "")
    info._detail_request_base_url = tostring(response.request_base_url or response_url or "")
    info._detail_content_type = response.content_type or "text/html"
    info._detail_code = response.code or response.status or 200
    info._detail_status = response.status or response.code or 200
    info.info_html = response.body
    if tostring(info.toc_url or "") == tostring(info.book_url or "")
            or tostring(info.toc_url or "") == tostring(response_url or "") then
        info.toc_html = response.body
    end
    info.variables = copyTable(env.variables)
    if options.save_runtime ~= false then self:_saveRuntimeSource(source) end
    -- Do not persist a new negative cover result during an explicit cover
    -- resolution pass; it would suppress later retries for a full day.
    if options.cache_write ~= false
            and (not options.require_cover or tostring(info.cover or "") ~= "") then
        -- The raw detail body is handed to BookService's bounded binary
        -- sidecar.  Keep the parsed metadata cache compact and body-free so a
        -- restart cannot recreate an unbounded book.lua/shelf payload.
        local cache_info = copyTable(info)
        cache_info.toc_html = nil
        cache_info.info_html = nil
        cacheWrite("bookinfo", cache_key, cache_info)
    end
    return info
end

local function ruleFlag(context, rule, response, env)
    if rule == nil or rule == "" then return false end
    local value = RuleEngine:extract(context, rule, responseRuleUrl(response), "", env)
    if type(value) == "boolean" then return value end
    value = Util.trim(tostring(value or "")):lower()
    return value ~= "" and value ~= "0" and value ~= "false" and value ~= "null" and value ~= "nil"
end

local function addChapters(chapters, seen, nodes, rules, response, env)
    local response_url = responseRuleUrl(response)
    local current_volume = nil
    for index, node in ipairs(nodes) do
        -- BookChapterList creates a fresh BookChapter for every TOC node.
        -- Bind that empty chapter while evaluating the node so @put targets
        -- the same object as AnalyzeRule.put, while reads fall back to the
        -- book variables.
        local current_book = type(env.book) == "table" and rawget(env.book, "__target") or nil
        local chapter_context = { variables = {}, book_url = type(current_book) == "table"
            and current_book.book_url or "" }
        env.chapter = variableProxy(chapter_context, chapter_context.variables, "custom", {
            chapterUrl = "url", name = "title", isVipValue = "is_vip", isPayValue = "is_pay",
        })
        local book_target = current_book
        local source_target = type(env.source) == "table" and rawget(env.source, "__target") or nil
        local book_variables = type(book_target) == "table" and book_target.variables or nil
        local source_variables = type(source_target) == "table" and source_target.variables or nil
        env.variables = variableScope(chapter_context.variables,
            variableScope(book_variables or {}, source_variables))
        local title_rule = firstRule(rules, "chapterName", "name", "title")
        traceRule(env.source and rawget(env.source, "__target") or nil, env, "toc.chapterName", title_rule)
        local title = RuleEngine:extract(node, title_rule, response_url, "", env)
        local format_js = firstRule(rules, "formatJs", "format_js")
        if title ~= "" and format_js and format_js ~= "" then
            traceRule(env.source and rawget(env.source, "__target") or nil, env, "toc.formatJs", format_js)
            local format_env = copyTable(env)
            format_env.result, format_env.src = title, title
            local formatted, format_err = QuickJS:eval(format_js, format_env)
            if format_err then env.last_js_error = format_err
            elseif formatted ~= nil then title = tostring(formatted) end
        end
        local volume_rule = firstRule(rules, "isVolume", "is_volume")
        traceRule(env.source and rawget(env.source, "__target") or nil, env, "toc.isVolume", volume_rule)
        local is_volume = ruleFlag(node, volume_rule, response, env)
        local chapter_url_rule = firstRule(rules, "chapterUrl", "url", "href")
        traceRule(env.source and rawget(env.source, "__target") or nil, env, "toc.chapterUrl", chapter_url_rule)
        -- BookChapterList stores the selector result as-is.  URL resolution is
        -- deferred to BookChapter.getAbsoluteURL(), so the production content
        -- reuse check can distinguish a relative chapter URL from the
        -- absolute Book.bookUrl.  Keep both representations for ordinary
        -- chapters: the public URL is request-ready for the desktop host,
        -- while the raw value preserves the WebBook branch predicate.
        local raw_chapter_url = RuleEngine:extract(node, chapter_url_rule, nil, "", env)
        local volume_url_fallback = false
        if not nonEmptyScalar(raw_chapter_url) then
            if is_volume then
                -- WebBook uses a title+index marker for a volume without an
                -- href.  It remains the stored BookChapter.url value; it is
                -- not a request URL and must not be replaced by a guessed
                -- response address.
                raw_chapter_url = tostring(title) .. tostring(index)
                volume_url_fallback = true
            else
                raw_chapter_url = response_url or ""
            end
        end
        -- Legado stores the title+index marker internally for a volume, but
        -- BookChapter.getAbsoluteURL() exposes the current TOC response URL.
        -- Keep the marker in _raw_url for the special-volume content branch
        -- and expose the same request-ready URL that the production model
        -- returns to callers.
        local chapter_url = volume_url_fallback
            and (response_url or raw_chapter_url)
            or resolveRuleRequest(raw_chapter_url, response_url, response.request_base_url)
        local normalized_title = Util.collapseSpaces(title)
        local seen_key = tostring(raw_chapter_url or "")
        if title ~= "" and chapter_url ~= "" and not seen[seen_key] then
            seen[seen_key] = true
            local update_value = RuleEngine:extract(node, firstRule(rules, "updateTime", "update_time", "info"), response_url, "", env)
            chapters[#chapters + 1] = {
                id = Util.hashId(seen_key), title = normalized_title, url = chapter_url,
                index = #chapters + 1, downloaded = false,
                is_volume = is_volume,
                volume = is_volume and normalized_title or current_volume,
                is_vip = ruleFlag(node, firstRule(rules, "isVip", "is_vip"), response, env),
                is_pay = ruleFlag(node, firstRule(rules, "isPay", "is_pay"), response, env),
                tag = update_value,
                update_time = update_value,
                variables = copyTable(chapter_context.variables),
                _request_base_url = firstNetworkBase(responseRuleUrl(response), response.request_base_url),
                _raw_url = tostring(raw_chapter_url or ""),
            }
        end
        if is_volume and title ~= "" then current_volume = normalized_title end
    end
end

function LegadoSource:getToc(source, book, options)
    options = options or {}
    local ok, support_err = checkSupported(source)
    if not ok then return nil, support_err end
    local cache_key = tostring(source.id) .. "\n" .. tostring(book.toc_url or book.book_url or "")
    local cached = options.cache_read ~= false and cacheRead("toc", cache_key) or nil
    if type(cached) == "table" and #cached > 0 then return cached end
    if source.single_chapter then
        local chapter_url = book.toc_url or book.book_url
        if not chapter_url or chapter_url == "" then return nil, "单章书源缺少正文地址" end
        local single = {{
            id = Util.hashId(chapter_url),
            title = source.single_chapter_title or book.title or "全文",
            url = chapter_url,
            index = 1,
            downloaded = false,
            variables = {},
        }}
        if options.cache_write ~= false then cacheWrite("toc", cache_key, single) end
        return single
    end
    local rules = source.rule_toc
    local list_rule = firstRule(rules, "chapterList", "chapter_list", "list")
    if not list_rule then return nil, "缺少 ruleToc.chapterList" end

    local pre_update = firstRule(rules, "preUpdateJs", "pre_update_js")
    -- WebBook.getChapterListAwait only runs this branch when its runPerJs
    -- argument is true.  Keeping the opt-in explicit prevents a normal TOC
    -- refresh from inventing a pre-update side effect.
    if options.run_per_js == true and pre_update and pre_update ~= "" then
        local initial_url = book.toc_url or book.book_url or source.base_url
        local pre_env = makeRuleEnv(self, source, {
            url = initial_url, request_base_url = firstNetworkBase(initial_url, book.book_url, source.base_url),
            body = "", headers = {}, code = 200,
        }, { book = book, page = 1, variables = book.variables or source.variables })
        -- WebBook constructs AnalyzeRule(book, bookSource, true) for this
        -- production-only hook.  It has no response body, so the harness
        -- stage context remains book.bookUrl rather than the eventual toc
        -- response URL.  Preserve that observable baseUrl for JS/Host
        -- evidence instead of deriving it from the synthetic empty response.
        local pre_base = book.book_url or initial_url
        pre_env.base_url, pre_env.baseUrl = pre_base, pre_base
        traceRule(source, pre_env, "toc.preUpdateJs", pre_update)
        local _, pre_err = QuickJS:eval(pre_update, pre_env)
        if pre_err then pre_env.last_js_error = pre_err end
        ExecutionTrace:branch(source, "pre-update-js", "toc", "ruleToc.preUpdateJs", {
            value = pre_update,
        })
        if pre_env.__refresh_toc and book.book_url and options.refresh_toc_url ~= false then
            local refreshed = self:getBookInfo(source, book, {
                cache_read = false, cache_write = false, save_runtime = false,
            })
            if type(refreshed) == "table" then
                book.toc_url = refreshed.toc_url or book.toc_url
                book.variables = refreshed.variables or book.variables
                book.book_url = refreshed.book_url or book.book_url
            end
        end
    end

    local current_url, pages, chapters, seen_pages, seen_chapters, last_env, last_response = book.toc_url or book.book_url, 0, {}, {}, {}, nil, nil
    local inline_response
    local inline_body = tostring(book.toc_html or "")
    local inline_detail_url = tostring(book._toc_html_response_url or book._detail_response_url
        or book._detail_base_url or book.book_url or "")
    -- This is the fixed Legado WebBook branch: a detail response is reused
    -- only when the resolved TOC URL is that same detail/book URL (including
    -- the final URL recorded after a redirect), never as a generic parse
    -- fallback for an unrelated page.
    if inline_body ~= "" and (tostring(current_url or "") == tostring(book.book_url or "")
            or tostring(current_url or "") == inline_detail_url) then
        ExecutionTrace:branch(source, "toc-html-reuse", "toc", "book.tocHtml", {
            value = inline_body,
        })
        inline_response = {
            url = inline_detail_url ~= "" and inline_detail_url or current_url,
            request_url = current_url,
            request_base_url = tostring(book._toc_html_request_base_url or book._detail_request_base_url
                or book._detail_base_url or inline_detail_url or current_url),
            body = inline_body,
            headers = {}, code = 200, status = 200, content_type = "text/html",
        }
    end
    while current_url and current_url ~= "" and pages < self.max_toc_pages and not seen_pages[current_url] do
        seen_pages[current_url], pages = true, pages + 1
        -- BookChapterList creates AnalyzeUrl(nextUrl) without a baseUrl for
        -- pagination.  Keep the production distinction: only the first TOC
        -- request is based on book.bookUrl.
        local request_base = pages == 1
            and (book.book_url or source.base_url)
            or ""
        local response, err
        if pages == 1 and inline_response then
            response = inline_response
        else
            response, err = self:request(source, current_url, nil, pages, {
                book = book, page = pages, base_url = request_base, referer = request_base,
            })
        end
        if not response then
            return nil, stageError("TOC_REQUEST_FAILED", source, err or ("第 " .. tostring(pages) .. " 页失败"))
        end
        last_response = response
        local response_url = responseRuleUrl(response)
        local document = parsePage(response)
        local env = makeRuleEnv(self, source, response, { book = book, page = pages, variables = book.variables or source.variables })
        last_env = env
        local context = initializedContext(document, rules, env)
        traceRule(source, env, "toc.chapterList", list_rule)
        addChapters(chapters, seen_chapters, RuleEngine:select(context, list_rule, env), rules, response, env)
        local next_rule = firstRule(rules, "nextTocUrl", "nextUrl", "nextPage")
        traceRule(source, env, "toc.nextTocUrl", next_rule)
        local next_url = next_rule and RuleEngine:extractUrl(context, next_rule, response_url, env) or ""
        current_url = next_url ~= "" and resolveRuleRequest(next_url, response_url, response.request_base_url) or nil
    end
    if (book.variables and book.variables.__reverse_toc) or source.variables.__reverse_toc then
        local reversed = {}
        for index = #chapters, 1, -1 do
            local chapter = chapters[index]; chapter.index = #reversed + 1; reversed[#reversed + 1] = chapter
        end
        chapters = reversed
    else
        for index, chapter in ipairs(chapters) do chapter.index = index end
    end
    if #chapters == 0 then
        local message = last_env and last_env.last_js_error or "目录规则返回空内容"
        if not (last_env and last_env.last_js_error) then
            local meta = diagnosticParseMeta(source, last_response, list_rule)
            if meta ~= "" then message = message .. " · " .. meta end
        end
        return nil, stageError(last_env and last_env.last_js_error and "SCRIPT_UNSUPPORTED" or "TOC_PARSE_EMPTY", source, message)
    end
    if options.save_runtime ~= false then self:_saveRuntimeSource(source) end
    if options.cache_write ~= false then cacheWrite("toc", cache_key, chapters) end
    return chapters
end

function LegadoSource:getContent(source, book, chapter)
    local ok, support_err = checkSupported(source)
    if not ok then return nil, support_err, false end
    local rules = source.rule_content
    local content_rule = firstRule(rules, "content", "body", "text")
    -- WebBook.getContentAwait returns the chapter URL when no content rule is
    -- declared.  It is a real production branch, not a parser failure.
    if not content_rule then
        ExecutionTrace:branch(source, "empty-content-rule", "content", "ruleContent.content", {
            value = chapter._raw_url or chapter.url,
        })
        -- WebBook returns BookChapter.url as stored by the TOC rule.  Leko
        -- keeps the resolved URL in chapter.url for the host, so use the raw
        -- value here to preserve the production no-rule branch.
        return tostring(chapter._raw_url or chapter.url or ""), nil, false
    end
    -- SharedJsScope is cached by jsLib and held weakly by Legado.  Do not close
    -- the source-owned QuickJS session merely because content begins: that
    -- would erase legitimate library state and make the observed call count
    -- depend on a synthetic stage boundary.  Explicit source/task teardown
    -- still calls QuickJS.closeSession through the normal lifecycle path.
    if Util.trim(tostring(source.js_lib or "")) ~= "" then
        source._js_library_base_url_override = chapter.url
    end
    local raw_chapter_url = tostring(chapter._raw_url or chapter.url or "")
    if chapter.is_volume == true and raw_chapter_url:sub(1, #tostring(chapter.title or ""))
            == tostring(chapter.title or "") then
        ExecutionTrace:branch(source, "special-volume-content", "content", "bookChapter.isVolume", {
            value = chapter.tag or "",
        })
        return tostring(chapter.tag or ""), nil, false
    end
    local current_url, pages, seen_pages, pieces, last_env, last_response = chapter.url, 0, {}, {}, nil, nil
    local inline_response
    -- BookService must know whether the content parser actually selected the
    -- bounded detail response before deleting its sidecar.
    local inline_response_consumed = false
    local inline_body = tostring(book.toc_html or "")
    local inline_detail_url = tostring(book._toc_html_response_url or book._detail_response_url
        or book._detail_base_url or book.book_url or "")
    -- BookContent has the same narrowly-scoped reuse branch as BookChapterList:
    -- only a chapter whose URL is the resolved book/detail URL can consume the
    -- retained detail HTML.
    if inline_body ~= "" and (tostring(chapter._raw_url or chapter.url or "") == tostring(book.book_url or "")
            or tostring(chapter._raw_url or chapter.url or "") == inline_detail_url) then
        ExecutionTrace:branch(source, "content-toc-html-reuse", "content", "book.tocHtml", {
            value = inline_body,
        })
        inline_response = {
            url = inline_detail_url ~= "" and inline_detail_url or current_url,
            request_url = current_url,
            request_base_url = tostring(book._toc_html_request_base_url or book._detail_request_base_url
                or book._detail_base_url or inline_detail_url or current_url),
            body = inline_body,
            headers = {}, code = 200, status = 200, content_type = "text/html",
        }
    end
    if source.source_regex and Util.trim(tostring(source.source_regex)) ~= "" then
        ExecutionTrace:branch(source, "source-regex", "content", "sourceRegex", {
            value = source.source_regex,
        })
    end
    while current_url and current_url ~= "" and pages < self.max_content_pages and not seen_pages[current_url] do
        seen_pages[current_url], pages = true, pages + 1
        -- BookContent creates AnalyzeUrl(nextUrl) without a baseUrl for
        -- content pagination.  Only the first content request uses book.tocUrl.
        local request_base = pages == 1
            and (book.toc_url or book.book_url or source.base_url)
            or ""
        local response, err
        if pages == 1 and inline_response then
            response = inline_response
            inline_response_consumed = true
        else
            response, err = self:request(source, current_url, nil, pages, {
                book = book, chapter = chapter, page = pages,
                base_url = request_base, referer = request_base,
            }, {
                -- AnalyzeUrl.getStrResponseAwait(jsStr = ruleContent.webJs)
                -- is a transport option, not a rule-environment field.
                web_js = firstRule(rules, "webJs", "web_js"),
                source_regex = pages == 1 and source.source_regex or nil,
            })
        end
        if not response then
            return nil, stageError("CONTENT_REQUEST_FAILED", source, err or ("第 " .. tostring(pages) .. " 页失败"))
        end
        last_response = response
        local response_url = responseRuleUrl(response)
        if response_url == "" then
            response_url = requestUrlPart(response and (response.url or response.request_url) or current_url)
        end
        local document = parsePage(response)
        local chapter_variables = type(chapter.variables) == "table" and chapter.variables or {}
        local book_variables = type(book.variables) == "table" and book.variables or {}
        local variables = variableScope(chapter_variables, variableScope(book_variables, source.variables))
        local env = makeRuleEnv(self, source, response, {
            book = book, chapter = chapter, page = pages, variables = variables,
            base_url = response_url,
        })
        -- Keep the rule JS base tied to the actual chapter response even when
        -- a transport adapter omits its normalized URL field.
        env.base_url, env.baseUrl = response_url, response_url
        last_env = env
        local context = initializedContext(document, rules, env)
        traceRule(source, env, "content.content", content_rule)
        local content = RuleEngine:extract(context, content_rule, response_url, "\n", env)
        content = RuleEngine:applyReplaceRules(content, firstRule(rules, "replaceRegex", "replace_regex"))
        content = RuleEngine:applyReplaceRules(content, source.raw and source.raw.replaceRegex)
        local formatted_content, media_contract = RuleEngine:formatContent(content, response_url)
        content = formatted_content
        ExecutionTrace:contentMedia(source, media_contract)
        if content ~= "" then pieces[#pieces + 1] = content end
        local next_rule = firstRule(rules, "nextContentUrl", "nextUrl", "nextPage")
        traceRule(source, env, "content.nextContentUrl", next_rule)
        local next_url = next_rule and RuleEngine:extractUrl(context, next_rule, response_url, env) or ""
        current_url = next_url ~= "" and resolveRuleRequest(next_url, response_url, response.request_base_url) or nil
    end
    -- Legado appends successive content pages with one line break. A blank
    -- line here changes the chapter body and is observable in the oracle.
    local output = Util.normalizeText(table.concat(pieces, "\n"))
    if output == "" then
        local pay_action = firstRule(rules, "payAction", "pay_action")
        if pay_action and Util.trim(tostring(pay_action)) ~= "" then
            -- Legado payAction may borrow a book, unlock an ad chapter, or spend
            -- account balance. Leko never performs a potentially paid remote
            -- mutation implicitly. Surface the exact boundary instead of calling
            -- it or misreporting an empty-content parser error.
            return nil, stageError("PAY_ACTION_REQUIRED", source,
                "该章节配置了 payAction；为避免自动借阅或消费，插件未执行该操作")
        end
        local message = last_env and last_env.last_js_error or "正文规则返回空内容"
        if not (last_env and last_env.last_js_error) then
            local meta = diagnosticParseMeta(source, last_response, content_rule)
            if meta ~= "" then message = message .. " · " .. meta end
        end
        return nil, stageError(last_env and last_env.last_js_error and "SCRIPT_UNSUPPORTED" or "CONTENT_PARSE_EMPTY", source, message)
    end
    self:_saveRuntimeSource(source)
    return output, nil, inline_response_consumed
end

function LegadoSource:validateChain(source, keyword, options)
    options = options or {}
    local report = {
        source_id = source and source.id,
        source_name = source and source.name,
        keyword = keyword,
        stage = "source",
        supported = false,
        checked_at = os.time(),
    }
    local function fail(stage, err)
        report.stage = stage
        report.error = tostring(err or "未知错误")
        report.code = StageError:code(report.error) or ({
            search = "SEARCH_PARSE_EMPTY", detail = "DETAIL_PARSE_FAILED",
            toc = "TOC_PARSE_EMPTY", content = "CONTENT_PARSE_EMPTY",
        })[stage] or "RULE_UNSUPPORTED"
        return nil, report.error, report
    end
    local ok, support_err = checkSupported(source)
    if not ok then return fail("source", support_err) end
    keyword = Util.trim(keyword or source.check_keyword
        or firstRule(source.rule_search, "checkKeyWord", "checkKeyword")
        or source.raw and (source.raw.checkKeyWord or source.raw.checkKeyword) or "")
    report.keyword = keyword
    if keyword == "" then return fail("search", "缺少完整兼容性测试关键词") end

    report.stage = "search"
    local found, search_err = self:search(source, keyword, 1, {
        cache_read = false, cache_write = false, save_runtime = false,
        max_results = tonumber(options.max_results) or 5,
        request_options = options.request_options,
    })
    if not found or #found == 0 then return fail("search", search_err or "搜索无结果") end
    report.search_results = #found

    report.stage = "detail"
    local info, detail_err = self:getBookInfo(source, found[1], {
        cache_read = false, cache_write = false, save_runtime = false,
    })
    if not info then return fail("detail", detail_err) end
    report.book_title = info.title or found[1].title

    report.stage = "toc"
    local chapters, toc_err = self:getToc(source, info, {
        cache_read = false, cache_write = false, save_runtime = false,
        run_per_js = options.run_per_js == true,
    })
    if not chapters or #chapters == 0 then return fail("toc", toc_err or "目录为空") end
    report.chapter_count = #chapters

    report.stage = "content"
    local content, content_err = self:getContent(source, info, chapters[1])
    local minimum = math.max(1, tonumber(options.minimum_content_chars) or 1)
    if not content or #Util.trim(content) < minimum then
        return fail("content", content_err or ("正文不足 " .. tostring(minimum) .. " 字符"))
    end
    report.content_chars = #content
    report.stage, report.code, report.supported = "complete", "OK", true
    return report
end

function LegadoSource:resolveCandidateRequest(source, spec, base_url)
    local resolved = absolutizeRequestSpec(spec, base_url or source and source.base_url)
    local url = requestUrlPart(resolved)
    if not url:match("^https?://") then return nil, "这条结果没有可直接访问的网页地址" end
    return resolved
end

LegadoSource.decodeLooseObject = decodeLooseObject
LegadoSource.parseHeaders = parseHeaders
LegadoSource.prepareJsLibrary = prepareJsLibrary
LegadoSource.requestUrlPart = requestUrlPart
LegadoSource.absolutizeRequestSpec = absolutizeRequestSpec
LegadoSource.firstNetworkBase = firstNetworkBase
LegadoSource.analyzeCompatibility = analyzeCompatibility

return LegadoSource
