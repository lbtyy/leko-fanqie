local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local koreader_util = require("util")
local logger = require("logger")
local VERSION = require("Leko/Version").version

local Http = {
    default_timeout = 12,
    default_maxtime = 40,
    default_max_bytes = 8 * 1024 * 1024,
    default_user_agent = "Mozilla/5.0 (Linux; Kindle) AppleWebKit/537.36 Leko/" .. VERSION .. " KOReader",
}

-- Storage sidecars that retain an already accepted response must use exactly
-- the same ceiling as the transport.  Keeping this accessor on the transport
-- module prevents a second, silently smaller HTML limit from changing the
-- semantics of a valid response.
function Http:getMaxResponseBytes()
    return tonumber(self.default_max_bytes) or (8 * 1024 * 1024)
end

local function lowerHeaders(input)
    local output = {}
    for key, value in pairs(input or {}) do
        output[tostring(key):lower()] = value
    end
    return output
end

local function mergeHeaders(base, extra)
    local result = lowerHeaders(base)
    for key, value in pairs(extra or {}) do result[tostring(key):lower()] = value end
    return result
end

local function uriScheme(value)
    return tostring(value or ""):match("^([%a][%w+%.%-]*):")
end

local function normalizeUrl(value)
    value = tostring(value or "")
    local parsed = socket_url.parse(value)
    if parsed then
        if parsed.path then parsed.path = koreader_util.urlEncode(parsed.path, "/%%") end
        if parsed.query then parsed.query = koreader_util.urlEncode(parsed.query, "=&%%+;,:@/?") end
        value = socket_url.build(parsed)
    end
    return value
end

local function copyTable(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function diagnosticUrl(value)
    local parsed = socket_url.parse(tostring(value or "")) or {}
    local scheme = parsed.scheme or "http"
    local host = parsed.host or tostring(value or ""):match("^https?://([^/%?#]+)") or "unknown-host"
    local port = parsed.port
    if port and not tostring(host):find(":" .. tostring(port), 1, true) then
        host = tostring(host) .. ":" .. tostring(port)
    end
    local path = parsed.path or "/"
    if path == "" then path = "/" end
    return tostring(scheme) .. "://" .. tostring(host) .. tostring(path)
end

local function responseExcerpt(body, full)
    local text = tostring(body or "")
    if full then return text end
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #text > 240 then text = text:sub(1, 240) .. "…" end
    return text
end

local function httpError(response, method, target_url, full_error_body, suppress_sensitive)
    local status = response and response.status
    if status == nil or tostring(status) == "" then
        status = "HTTP " .. tostring(response and response.code or "error")
    end
    status = tostring(status)
    local message = status .. " · " .. tostring(method or "GET")
    if not suppress_sensitive then message = message .. " " .. diagnosticUrl(target_url) end
    local excerpt = responseExcerpt(response and response.body, full_error_body == true)
    if excerpt ~= "" then message = message .. " · 响应：" .. excerpt end
    return message
end

function Http:absolute(base_url, value)
    value = value and tostring(value) or ""
    if value == "" then return "" end
    -- Opaque Legado hand-off URLs such as data:bookId;base64,... are already
    -- absolute even though they do not contain //; resolving them against the
    -- source host produces the historical "invalid host nil" failure.
    if uriScheme(value) then return value end
    if value:match("^//") then
        local scheme = tostring(base_url or ""):match("^(https?):") or "https"
        return scheme .. ":" .. value
    end
    if not base_url or base_url == "" then return value end
    return socket_url.absolute(base_url, value)
end

function Http:normalizeUrl(value)
    return normalizeUrl(value)
end

local function responseSink(chunks, max_bytes)
    local total = 0
    return function(chunk, err)
        if chunk then
            total = total + #chunk
            if total > max_bytes then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
end

local function shouldRetry(code, status)
    code = tonumber(code)
    if code and (code == 408 or code == 425 or code == 429 or code >= 500) then return true end
    local value = tostring(status or code or ""):lower()
    return value:find("timeout", 1, true) ~= nil
        or value:find("temporarily", 1, true) ~= nil
        or value:find("closed", 1, true) ~= nil
end

function Http:_requestOnce(options)
    local method = tostring(options.method or "GET"):upper()
    local target_url = normalizeUrl(assert(options.url, "request url required"))
    local body = tostring(options.body or "")
    local chunks = {}
    local headers = mergeHeaders({
        ["user-agent"] = options.user_agent or self.default_user_agent,
        ["accept"] = options.accept or "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
        ["accept-encoding"] = "identity",
        ["connection"] = "close",
    }, options.headers)

    if method ~= "GET" and method ~= "HEAD" then
        headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
        headers["content-length"] = tostring(#body)
    end

    socketutil:set_timeout(options.timeout or self.default_timeout, options.maxtime or self.default_maxtime)
    local request = {
        url = target_url,
        method = method,
        headers = headers,
        sink = options.discard_body and function() return 1 end
            or responseSink(chunks, tonumber(options.max_bytes) or self.default_max_bytes),
    }
    if method ~= "GET" and method ~= "HEAD" then request.source = ltn12.source.string(body) end

    if not options.suppress_sensitive_log then
        logger.dbg("Leko HTTP", method, target_url)
    end
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then return nil, tostring(code), nil, target_url end
    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, tostring(status or code), code, target_url
    end
    response_headers = lowerHeaders(response_headers)
    if not next(response_headers) then return nil, tostring(status or code or "network unavailable"), code, target_url end

    code = tonumber(code) or 0
    local content = table.concat(chunks)
    local expected = tonumber(response_headers["content-length"])
    if expected and expected ~= #content and method ~= "HEAD" and not options.discard_body then
        return nil, "incomplete response", code, target_url
    end

    return {
        url = target_url,
        code = code,
        headers = response_headers,
        content_type = tostring(response_headers["content-type"] or ""),
        body = content,
        status = status,
    }, nil, code, target_url
end

function Http:request(options)
    options = copyTable(options or {})
    options.headers = copyTable(options.headers)
    local retries = tonumber(options.retries)
    if retries == nil then retries = 1 end
    local attempt = 0

    while true do
        local response, err, code, target_url = self:_requestOnce(options)
        if response then
            if response.code >= 300 and response.code < 400 and response.headers.location
                    and options.follow_redirects ~= false then
                local redirects = tonumber(options.redirects) or 0
                if redirects >= (tonumber(options.max_redirects) or 5) then return nil, "too many redirects" end
                options.url = self:absolute(target_url, response.headers.location)
                options.redirects = redirects + 1
                if response.code == 303 or ((response.code == 301 or response.code == 302) and tostring(options.method or "GET"):upper() == "POST") then
                    options.method, options.body = "GET", ""
                    options.headers["content-length"] = nil
                    options.headers["content-type"] = nil
                end
            elseif response.code >= 200 and response.code < 300 then
                return response
            elseif options.allow_http_errors then
                return response
            elseif attempt < retries and shouldRetry(response.code, response.status) then
                attempt = attempt + 1
            else
                return nil, httpError(response, options.method, target_url, options.full_error_body,
                    options.suppress_sensitive_log == true)
            end
        elseif attempt < retries and shouldRetry(code, err) then
            attempt = attempt + 1
        else
            return nil, tostring(err or "request failed")
        end
    end
end

function Http:scheme(value) return uriScheme(value) end

function Http:isHttpUrl(value)
    local scheme = uriScheme(value)
    if scheme ~= "http" and scheme ~= "https" then return false end
    local parsed = socket_url.parse(tostring(value or ""))
    return parsed ~= nil and tostring(parsed.host or "") ~= ""
end

function Http:diagnosticUrl(value) return diagnosticUrl(value) end

function Http:get(url, headers)
    return self:request({ url = url, method = "GET", headers = headers })
end

function Http:post(url, body, headers)
    return self:request({ url = url, method = "POST", body = body, headers = headers })
end

return Http
