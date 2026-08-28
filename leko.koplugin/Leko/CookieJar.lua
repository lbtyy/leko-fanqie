-- Small persistent cookie jar stored inside each normalized source record.
local CookieJar = {}

local function lower(value) return tostring(value or ""):lower() end
local function hostOf(url)
    return lower(tostring(url or ""):match("^https?://([^/%?:]+)") or "")
end
local function pathOf(url)
    local path = tostring(url or ""):match("^https?://[^/]+(/[^%?#]*)") or "/"
    return path ~= "" and path or "/"
end
local function defaultPath(url)
    local path = pathOf(url)
    if path == "/" then return "/" end
    local parent = path:match("^(.*)/")
    return parent and parent ~= "" and parent or "/"
end
local function domainMatches(host, domain)
    domain = lower(domain):gsub("^%.", "")
    return host == domain or host:sub(-#domain - 1) == "." .. domain
end

local function parseSetCookie(value, request_url)
    local first, rest = tostring(value or ""):match("^%s*([^;]+)%s*;?(.*)$")
    if not first then return nil end
    local name, cookie_value = first:match("^%s*([^=]+)%s*=%s*(.*)$")
    if not name then return nil end
    local cookie = {
        name = name,
        value = cookie_value or "",
        domain = hostOf(request_url),
        path = defaultPath(request_url),
        secure = false,
        host_only = true,
    }
    for attribute in tostring(rest or ""):gmatch("[^;]+") do
        local key, val = attribute:match("^%s*([^=]+)%s*=?%s*(.-)%s*$")
        key = lower(key)
        if key == "domain" and val ~= "" then
            cookie.domain = lower(val):gsub("^%.", "")
            cookie.host_only = false
        elseif key == "path" and val ~= "" then cookie.path = val
        elseif key == "secure" then cookie.secure = true
        elseif key == "max-age" then
            local seconds = tonumber(val)
            if seconds then cookie.expires = os.time() + seconds end
        end
    end
    return cookie
end

function CookieJar:add(source, request_url, set_cookie)
    if not source or source.enabled_cookie_jar == false or not set_cookie then return false end
    source.cookies = source.cookies or {}
    local values = type(set_cookie) == "table" and set_cookie or { set_cookie }
    local changed = false
    for _, raw in ipairs(values) do
        local cookie = parseSetCookie(raw, request_url)
        if cookie then
            local key = cookie.domain .. "\t" .. cookie.path .. "\t" .. cookie.name
            if cookie.value == "" or (cookie.expires and cookie.expires <= os.time()) then
                source.cookies[key] = nil
            else
                source.cookies[key] = cookie
            end
            changed = true
        end
    end
    return changed
end

function CookieJar:addFromHeaders(source, request_url, headers)
    if type(headers) ~= "table" then return false end
    return self:add(source, request_url, headers["set-cookie"] or headers["Set-Cookie"])
end

function CookieJar:header(source, request_url)
    if not source or source.enabled_cookie_jar == false then return "" end
    local host, path = hostOf(request_url), pathOf(request_url)
    local secure = tostring(request_url or ""):match("^https://") ~= nil
    local values = {}
    for key, cookie in pairs(source.cookies or {}) do
        if cookie.expires and cookie.expires <= os.time() then
            source.cookies[key] = nil
        elseif (not cookie.secure or secure)
            and (cookie.host_only and host == cookie.domain or (not cookie.host_only and domainMatches(host, cookie.domain)))
            and path:sub(1, #cookie.path) == cookie.path then
            table.insert(values, cookie.name .. "=" .. cookie.value)
        end
    end
    table.sort(values)
    return table.concat(values, "; ")
end

return CookieJar
