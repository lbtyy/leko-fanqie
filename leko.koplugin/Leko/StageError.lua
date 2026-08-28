local StageError = {}

local LABELS = {
    SOURCE_UNSUPPORTED = "书源不适用",
    REQUEST_RULE_FAILED = "请求规则失败",
    REQUEST_URL_EMPTY = "请求地址为空",
    REQUEST_URL_INVALID = "请求地址无效",
    SEARCH_REQUEST_FAILED = "搜索请求失败",
    SEARCH_PARSE_EMPTY = "搜索规则未返回结果",
    DETAIL_REQUEST_FAILED = "详情请求失败",
    DETAIL_PARSE_FAILED = "详情规则解析失败",
    TOC_REQUEST_FAILED = "目录请求失败",
    TOC_PARSE_EMPTY = "目录规则返回空内容",
    CONTENT_REQUEST_FAILED = "正文请求失败",
    CONTENT_PARSE_EMPTY = "正文规则返回空内容",
    RULE_UNSUPPORTED = "规则暂不支持",
    SCRIPT_UNSUPPORTED = "脚本暂不支持",
    CHARSET_FAILED = "字符集转换失败",
    DATA_URI_INVALID = "虚拟数据地址无效",
    INTERACTION_REQUIRED = "需要浏览器或验证码交互",
    WEBVIEW_REQUIRED = "需要 WebView 浏览器能力",
    LOGIN_CHECK_FAILED = "登录状态检查脚本失败",
    PAY_ACTION_REQUIRED = "章节需要授权、借阅或购买操作",
}

local function sanitize(value, limit, preserve_newlines)
    value = tostring(value or "")
    if preserve_newlines then
        value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    else
        value = value:gsub("[\r\n]+", " "):gsub("%s+", " ")
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if limit and #value > limit then value = value:sub(1, limit) .. "…" end
    return value
end

function StageError:new(code, source, message, details)
    code = tostring(code or "RULE_UNSUPPORTED")
    local full_diagnostic = source and source._diagnostic_full_errors == true
    local item = {
        code = code,
        label = LABELS[code] or code,
        source = sanitize(source and (source.name or source.bookSourceName) or "", 600, false),
        -- Normal UI errors stay concise. Compatibility diagnostics are lossless:
        -- they may carry the complete HTTP response or interpreter error into
        -- the child-owned append-only log.
        message = full_diagnostic and sanitize(message, nil, true) or sanitize(message, 600, false),
        details = details,
    }
    return setmetatable(item, {
        __tostring = function(value)
            local parts = { "[" .. value.code .. "]" }
            if value.source ~= "" then parts[#parts + 1] = value.source end
            parts[#parts + 1] = value.label
            if value.message ~= "" and value.message ~= value.label then parts[#parts + 1] = value.message end
            return table.concat(parts, " · ")
        end,
    })
end

function StageError:format(code, source, message, details)
    return tostring(self:new(code, source, message, details))
end

function StageError:code(value)
    return tostring(value or ""):match("^%[([A-Z0-9_]+)%]")
end

function StageError:is(value, code)
    local found = self:code(value)
    if code ~= nil then return found == code end
    return found ~= nil
end

StageError.labels = LABELS

return StageError
