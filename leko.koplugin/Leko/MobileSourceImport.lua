local socket = require("socket")
local Device = require("device")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local Http = require("Leko/Http")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local MobileSourceImport = {
    socket = socket,
    device = Device,
    execute = os.execute,
    ui_manager = UIManager,
    poll_interval = 0.35,
    active_poll_interval = 0.05,
    session_timeout = 5 * 60,
    request_timeout = 30,
    read_chunk_bytes = 32 * 1024,
    read_budget_bytes = 256 * 1024,
    max_header_bytes = 32 * 1024,
    max_body_bytes = 8 * 1024 * 1024,
    active = nil,
}

local function now()
    if socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.time()
end

local function trim(value)
    value = tostring(value or "")
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isIPv4(value)
    local a, b, c, d = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, item in ipairs({ a, b, c, d }) do
        local number = tonumber(item)
        if not number or number < 0 or number > 255 then return false end
    end
    return a ~= "0" and a ~= "127" and a ~= "255"
end

local function closeSocket(value)
    if value and type(value.close) == "function" then pcall(value.close, value) end
end

local function commandSucceeded(executed, result)
    return executed and (result == true or result == 0)
end

local function firewallCommand(action, chain, port_flag, port, state)
    return string.format(
        "iptables %s %s -p tcp %s %d -m conntrack --ctstate %s -j ACCEPT",
        action, chain, port_flag, port, state
    )
end

local function randomToken()
    local file = io.open("/dev/urandom", "rb")
    local bytes = file and file:read(12) or nil
    if file then file:close() end
    if not bytes or #bytes < 12 then
        math.randomseed(os.time() + math.floor((now() % 1) * 1000000))
        local generated = {}
        for index = 1, 12 do generated[index] = string.char(math.random(0, 255)) end
        bytes = table.concat(generated)
    end
    local output = {}
    for index = 1, #bytes do output[index] = string.format("%02x", bytes:byte(index)) end
    return table.concat(output)
end

local function htmlEscape(value)
    return tostring(value or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&#39;")
end

local function page(title, content)
    return [[<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>]] .. htmlEscape(title) .. [[</title>
<style>
:root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#f5f5f5;color:#171717;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:560px;margin:0 auto;padding:24px 16px 40px}h1{font-size:25px;margin:0 0 8px}p{line-height:1.55;margin:8px 0 16px}.card{background:#fff;border:1px solid #ddd;border-radius:12px;padding:16px;margin:14px 0}h2{font-size:18px;margin:0 0 10px}label{display:block;font-size:14px;color:#555;margin-bottom:7px}input[type=url],textarea{display:block;width:100%;font:inherit;border:1px solid #bbb;border-radius:8px;padding:10px;background:#fff}textarea{min-height:150px;resize:vertical}input[type=file]{display:block;width:100%;font-size:15px;margin:10px 0}button{border:0;border-radius:8px;background:#111;color:#fff;font:inherit;padding:10px 16px;margin-top:10px}button:active{opacity:.75}.notice{background:#eef6ee;border:1px solid #b7d7b7;border-radius:8px;padding:12px}.hint{font-size:13px;color:#666;margin:8px 0 0}
</style></head><body><main>]] .. content .. [[</main></body></html>]]
end

local function importPage(route, notice)
    local action = htmlEscape(route)
    local message = notice and ([[<p class="notice">]] .. htmlEscape(notice) .. [[</p>]]) or ""
    return page("发送书源到 Leko", [[
<h1>发送书源到 Leko</h1>
<p>请选择一种方式，把书源发送到 Kindle。</p>]] .. message .. [[
<section class="card"><h2>粘贴书源网址</h2>
<form method="post" action="]] .. action .. [[" accept-charset="UTF-8">
<label for="source-url">书源网址</label><input id="source-url" type="url" name="url" placeholder="https://…/sources.json" autocomplete="off" required>
<button type="submit">发送网址</button></form></section>
<section class="card"><h2>粘贴书源 JSON 内容</h2>
<form method="post" action="]] .. action .. [[" accept-charset="UTF-8">
<label for="source-json">书源 JSON</label><textarea id="source-json" name="json" placeholder="把书源 JSON 粘贴到这里" spellcheck="false" required></textarea>
<button type="submit">发送 JSON</button></form></section>
<section class="card"><h2>上传书源文件</h2>
<form method="post" action="]] .. action .. [[" enctype="multipart/form-data">
<label for="source-file">本地 .json 文件</label><input id="source-file" type="file" name="file" accept=".json,application/json" required>
<button type="submit">上传文件</button></form></section>
<p class="hint">发送后请回到 Kindle 查看导入结果。</p>]])
end

local function simplePage(title, message, route)
    local back = route and ([[<p><a href="]] .. htmlEscape(route) .. [[">返回发送页面</a></p>]]) or ""
    return page(title, [[<h1>]] .. htmlEscape(title) .. [[</h1><p>]]
        .. htmlEscape(message) .. [[</p>]] .. back)
end

local function busyPage(route)
    return page("Kindle 正在导入", [[
<h1>Kindle 正在导入</h1>
<p>请等待 Kindle 上的进度完成，再继续发送下一份书源。</p>
<p><a href="]] .. htmlEscape(route) .. [[">检查是否可以继续</a></p>]])
end

local function response(status, reason, body)
    body = tostring(body or "")
    return string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s",
        status, reason, #body, body
    )
end

local function parseHeaders(raw)
    local lines = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    local request_line = lines[1]
    if not request_line then return nil, "请求不完整" end
    local method, target, major, minor = request_line:match("^(%S+)%s+(%S+)%s+HTTP/(%d+)%.(%d+)$")
    if not method or not target or #target > 2048 or tonumber(major) ~= 1 then
        return nil, "请求格式不受支持"
    end
    local headers = {}
    for index = 2, #lines do
        local key, value = lines[index]:match("^([^:]+):%s*(.*)$")
        if not key or key:find("[%c]") then return nil, "请求头无效" end
        key = key:lower()
        if headers[key] ~= nil and headers[key] ~= value then return nil, "请求头重复" end
        headers[key] = value
    end
    local content_length = headers["content-length"]
    if content_length ~= nil then
        if not content_length:match("^%d+$") then return nil, "请求大小无效" end
        content_length = tonumber(content_length)
        if not content_length or content_length > MobileSourceImport.max_body_bytes then
            return nil, "请求内容过大"
        end
    end
    if headers["transfer-encoding"] and headers["transfer-encoding"]:lower() ~= "identity" then
        return nil, "请求传输方式不受支持"
    end
    return {
        method = method:upper(),
        target = target,
        headers = headers,
        content_length = content_length,
    }
end

local function hexByte(value)
    return tonumber(value, 16)
end

local function decodeFormComponent(value)
    value = tostring(value or ""):gsub("+", " ")
    local output, index = {}, 1
    while index <= #value do
        local character = value:sub(index, index)
        if character == "%" then
            local decoded = hexByte(value:sub(index + 1, index + 2))
            if not decoded then return nil, "表单内容无效" end
            output[#output + 1] = string.char(decoded)
            index = index + 3
        else
            output[#output + 1] = character
            index = index + 1
        end
    end
    return table.concat(output)
end

local function parseUrlEncoded(body)
    local fields = {}
    if body == "" then return fields end
    for pair in tostring(body):gmatch("[^&]+") do
        local key, value = pair:match("^([^=]*)=(.*)$")
        if key == nil then key, value = pair, "" end
        local decoded_key, key_err = decodeFormComponent(key)
        local decoded_value, value_err = decodeFormComponent(value)
        if not decoded_key or not decoded_value then return nil, key_err or value_err end
        if decoded_key == "url" or decoded_key == "json" then fields[decoded_key] = decoded_value end
    end
    return fields
end

local function parsePartHeaders(raw)
    local headers = {}
    for line in tostring(raw or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key then headers[key:lower()] = value end
    end
    return headers
end

local function parseMultipart(body, content_type)
    local boundary = content_type:match('[;]%s*boundary="([^"]+)"')
        or content_type:match("[;]%s*boundary=([^;,%s]+)")
    if not boundary or #boundary == 0 or #boundary > 200 or boundary:find("[%c]", 1, true) then
        return nil, "上传格式无效"
    end
    local delimiter = "--" .. boundary
    if body:sub(1, #delimiter) ~= delimiter then return nil, "上传格式无效" end
    local fields = {}
    local position = 1
    while position <= #body do
        local start = body:find(delimiter, position, true)
        if not start then return nil, "上传格式不完整" end
        local after = start + #delimiter
        if body:sub(after, after + 1) == "--" then break end
        if body:sub(after, after + 1) ~= "\r\n" then return nil, "上传格式无效" end
        local header_start = after + 2
        local header_end = body:find("\r\n\r\n", header_start, true)
        if not header_end then return nil, "上传格式不完整" end
        local part_headers = parsePartHeaders(body:sub(header_start, header_end - 1))
        local disposition = part_headers["content-disposition"] or ""
        local name = disposition:match(';[%s]*name="([^"]*)"')
        if not name then return nil, "上传字段无效" end
        local data_start = header_end + 4
        local next_boundary = body:find("\r\n" .. delimiter, data_start, true)
        if not next_boundary then return nil, "上传格式不完整" end
        local data = body:sub(data_start, next_boundary - 1)
        if name == "url" or name == "json" then
            fields[name] = { value = data }
        elseif name == "file" then
            fields.file = {
                value = data,
                filename = disposition:match(';[%s]*filename="([^"]*)"') or "",
            }
        end
        position = next_boundary + 2
    end
    return fields
end

local function isRouteTarget(target, route)
    local path = tostring(target or ""):match("^([^?]*)") or ""
    return path == route
end

local function networkIsConnected()
    if type(NetworkMgr.isConnected) ~= "function" then return true end
    local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
    return ok and connected == true
end

local function getInterfaceName()
    if NetworkMgr.interface and NetworkMgr.interface ~= "" then return NetworkMgr.interface end
    if type(NetworkMgr.getNetworkInterfaceName) == "function" then
        local ok, name = pcall(NetworkMgr.getNetworkInterfaceName, NetworkMgr)
        if ok and name and name ~= "" then return name end
    end
    return "wlan0"
end

local function getIPv4FromIfAddrs()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end
    local ok_posix = pcall(require, "ffi/posix_h")
    if not ok_posix then return nil end
    local C = ffi.C
    local ok, value = pcall(function()
        local ifaddr = ffi.new("struct ifaddrs *[1]")
        if C.getifaddrs(ifaddr) == -1 then return nil end
        local interface = getInterfaceName()
        local current = ifaddr[0]
        local address
        while current ~= nil do
            if current.ifa_addr ~= nil and C.strcmp(current.ifa_name, interface) == 0
                    and current.ifa_addr.sa_family == C.AF_INET then
                local host = ffi.new("char[?]", C.NI_MAXHOST)
                local result = C.getnameinfo(
                    current.ifa_addr,
                    ffi.sizeof("struct sockaddr_in"),
                    host, C.NI_MAXHOST, nil, 0, C.NI_NUMERICHOST
                )
                if result == 0 then address = ffi.string(host); break end
            end
            current = current.ifa_next
        end
        C.freeifaddrs(ifaddr[0])
        return address
    end)
    return ok and isIPv4(value) and value or nil
end

local function getIPv4FromRoute()
    local udp, err = socket.udp()
    if not udp then return nil, err end
    pcall(udp.settimeout, udp, 0)
    local connected = udp:setpeername("203.0.113.1", 53)
    if not connected then connected = udp:setpeername("192.0.2.1", 9) end
    local address = connected and select(1, udp:getsockname()) or nil
    closeSocket(udp)
    return isIPv4(address) and address or nil
end

function MobileSourceImport:getLocalIPv4()
    -- Prefer LuaSocket's routing result. It is enough to identify the address
    -- used for the phone connection and avoids entering native FFI on ordinary
    -- Kindle Wi-Fi setups.
    local address = getIPv4FromRoute()
    if address then return address end
    return getIPv4FromIfAddrs()
end

function MobileSourceImport:removeTempFile(path)
    path = tostring(path or "")
    local tmp_dir = Util.joinPath(Storage:getCacheDir("tmp"), "")
    local tmp_prefix = tmp_dir:gsub("/+$", "") .. "/"
    if path == "" or path:find("%.%.", 1, true) or path:sub(1, #tmp_prefix) ~= tmp_prefix then return false end
    os.remove(path)
    os.remove(path .. ".tmp")
    return true
end

function MobileSourceImport:_writeTempFile(session, content)
    local path = Util.joinPath(Storage:getCacheDir("tmp"), "mobile-source-" .. randomToken() .. ".json")
    local ok, err = Util.writeFile(path, content, true)
    if not ok then return nil, err end
    session.pending_temp_path = path
    return path
end

function MobileSourceImport:parseFormSubmission(content_type, body, session)
    local lowered = tostring(content_type or ""):lower()
    local fields, err
    if lowered:match("^application/x%-www%-form%-urlencoded") then
        fields, err = parseUrlEncoded(body)
    elseif lowered:match("^multipart/form%-data") then
        fields, err = parseMultipart(body, content_type)
    else
        return nil, "请使用手机页面中的发送按钮提交。"
    end
    if not fields then return nil, err or "提交内容无效" end

    local url = trim(fields.url and (fields.url.value or fields.url) or "")
    local json = tostring(fields.json and (fields.json.value or fields.json) or "")
    local file = fields.file
    local has_url, has_json, has_file = url ~= "", json ~= "", file and true or false
    local count = (has_url and 1 or 0) + (has_json and 1 or 0) + (has_file and 1 or 0)
    if count == 0 then return nil, "请选择一种发送方式。" end
    if count > 1 then return nil, "请只选择一种发送方式。" end

    if has_url then
        local valid = type(Http.isHttpUrl) == "function" and Http:isHttpUrl(url)
        if not valid then return nil, "书源网址无效，请检查后重试。" end
        return { kind = "url", url = url }
    end
    if has_json then
        local path, write_err = self:_writeTempFile(session, json)
        if not path then return nil, "Kindle 暂时无法保存这份书源，请重试。" end
        return { kind = "file", path = path }
    end

    local filename = tostring(file.filename or "")
    if filename ~= "" and not filename:lower():match("%.json$") then
        return nil, "请选择 .json 书源文件。"
    end
    if tostring(file.value or "") == "" then return nil, "上传的书源文件为空。" end
    local path, write_err = self:_writeTempFile(session, file.value)
    if not path then return nil, "Kindle 暂时无法保存这份书源，请重试。" end
    return { kind = "file", path = path }
end

function MobileSourceImport:_closeClient(session)
    if session.client then closeSocket(session.client); session.client = nil end
    session.sending = nil
end

function MobileSourceImport:_isKindle()
    local device = self.device
    if not device or type(device.isKindle) ~= "function" then return false end
    local ok, value = pcall(device.isKindle, device)
    return ok and value == true
end

function MobileSourceImport:_runFirewallCommand(command)
    if type(self.execute) ~= "function" then return false end
    local executed, result = pcall(self.execute, command)
    return commandSucceeded(executed, result)
end

function MobileSourceImport:_closeKindleFirewall(session)
    if not session then return true end
    local port = tonumber(session.port)
    if not port then return false end

    local ok = true
    if session.firewall_input_added then
        local removed = self:_runFirewallCommand(firewallCommand(
            "-D", "INPUT", "--dport", port, "NEW,ESTABLISHED"
        ))
        session.firewall_input_added = false
        ok = removed and ok
    end
    if session.firewall_output_added then
        local removed = self:_runFirewallCommand(firewallCommand(
            "-D", "OUTPUT", "--sport", port, "ESTABLISHED"
        ))
        session.firewall_output_added = false
        ok = removed and ok
    end
    if not ok then
        logger.warn("[Leko] Unable to remove one or more temporary mobile-import firewall rules")
    end
    return ok
end

function MobileSourceImport:_openKindleFirewall(session)
    if not self:_isKindle() then return true end
    local port = tonumber(session and session.port)
    if not port then return false end

    if not self:_runFirewallCommand(firewallCommand(
        "-A", "INPUT", "--dport", port, "NEW,ESTABLISHED"
    )) then
        logger.warn("[Leko] Unable to add the temporary mobile-import INPUT firewall rule")
        return false
    end
    session.firewall_input_added = true

    if not self:_runFirewallCommand(firewallCommand(
        "-A", "OUTPUT", "--sport", port, "ESTABLISHED"
    )) then
        logger.warn("[Leko] Unable to add the temporary mobile-import OUTPUT firewall rule")
        self:_closeKindleFirewall(session)
        return false
    end
    session.firewall_output_added = true
    return true
end

function MobileSourceImport:_queueResponse(session, status, reason, body, after)
    local client = session.client
    if not client then
        if after then pcall(after) end
        return
    end
    session.sending = {
        data = response(status, reason, body),
        offset = 1,
        started_at = now(),
        after = after,
    }
    self:_flushResponse(session)
end

function MobileSourceImport:_flushResponse(session)
    local pending = session.sending
    if not pending or not session.client then return end
    local ok, sent, err, last = pcall(session.client.send, session.client, pending.data, pending.offset)
    if not ok then sent, err, last = nil, "closed", nil end
    if sent == true then
        pending.offset = #pending.data + 1
    elseif type(sent) == "number" then
        local absolute = sent >= pending.offset and sent or pending.offset + sent - 1
        pending.offset = absolute + 1
    elseif type(last) == "number" then
        local absolute = last >= pending.offset and last or pending.offset + last - 1
        pending.offset = absolute + 1
    elseif err and err ~= "timeout" then
        pending.offset = #pending.data + 1
    end
    if pending.offset > #pending.data or now() - pending.started_at > 5 then
        local after = pending.after
        self:_closeClient(session)
        if after then pcall(after) end
    end
end

function MobileSourceImport:_reject(session, status, reason, message, keep_open)
    local route = keep_open and ("/" .. session.token) or nil
    self:_queueResponse(session, status, reason, simplePage("发送失败", message, route), function()
        if not keep_open then self:stop(session, "request-rejected", false) end
    end)
end

function MobileSourceImport:_handleRequest(session, request, body)
    local route = "/" .. session.token
    if not isRouteTarget(request.target, route) then
        self:_reject(session, 404, "Not Found", "请使用 Kindle 屏幕上的地址打开此页面。", true)
        return
    end
    if session.accepted then
        if request.method == "GET" then
            self:_queueResponse(session, 409, "Conflict", busyPage(route), nil)
        else
            self:_reject(session, 409, "Conflict", "Kindle 正在导入上一份书源，请完成后再发送。", true)
        end
        return
    end
    if request.method == "GET" then
        if request.content_length and request.content_length ~= 0 then
            self:_reject(session, 400, "Bad Request", "请求内容无效。", true)
            return
        end
        self:_queueResponse(session, 200, "OK", importPage(route), nil)
        return
    end
    if request.method ~= "POST" then
        self:_reject(session, 405, "Method Not Allowed", "请使用手机页面中的发送按钮提交。", true)
        return
    end

    local content_type = request.headers["content-type"] or ""
    local spec, parse_err = self:parseFormSubmission(content_type, body, session)
    if not spec then
        if session.pending_temp_path then self:removeTempFile(session.pending_temp_path); session.pending_temp_path = nil end
        self:_reject(session, 400, "Bad Request", parse_err or "提交内容无效。", true)
        return
    end
    local callback_ok, accepted, callback_err = pcall(session.on_submit, spec, session)
    if not callback_ok or accepted ~= true then
        if spec.path then self:removeTempFile(spec.path) end
        session.pending_temp_path = nil
        self:_reject(session, 500, "Internal Server Error", "Kindle 当前无法接收这份书源，请返回重试。", true)
        return
    end
    session.accepted = true
    session.submission_count = (tonumber(session.submission_count or 0) or 0) + 1
    session.deadline = now() + session.timeout_seconds
    session.pending_temp_path = nil
    self:_queueResponse(session, 200, "OK", simplePage(
        "发送成功",
        "已发送到 Kindle。导入完成后，可以返回这里继续发送另一份书源。",
        route
    ), nil)
end

function MobileSourceImport:allowNextSubmission(session)
    session = session or self.active
    if not session or session.closed or self.active ~= session then return false end
    session.accepted = false
    session.pending_temp_path = nil
    session.deadline = now() + session.timeout_seconds
    return true
end

function MobileSourceImport:_parseClientBuffer(session)
    if not session.header_end then
        local header_end, separator_length = session.buffer:find("\r\n\r\n", 1, true), 4
        if not header_end then header_end, separator_length = session.buffer:find("\n\n", 1, true), 2 end
        if not header_end then
            if #session.buffer > self.max_header_bytes then
                self:_reject(session, 431, "Request Header Fields Too Large", "请求头过大。", false)
            end
            return
        end
        if header_end > self.max_header_bytes then
            self:_reject(session, 431, "Request Header Fields Too Large", "请求头过大。", false)
            return
        end
        local request, err = parseHeaders(session.buffer:sub(1, header_end - 1))
        session.buffer = session.buffer:sub(header_end + separator_length)
        if not request then
            local status = err == "请求内容过大" and 413 or 400
            self:_reject(session, status, status == 413 and "Payload Too Large" or "Bad Request", err, false)
            return
        end
        if request.method == "POST" and request.content_length == nil then
            self:_reject(session, 411, "Length Required", "请求大小不明确。", false)
            return
        end
        if request.method == "GET" and request.content_length and request.content_length > 0 then
            self:_reject(session, 400, "Bad Request", "请求内容无效。", true)
            return
        end
        session.request = request
        session.body_chunks = {}
        session.body_bytes = 0
        if session.buffer ~= "" then
            session.body_chunks[1] = session.buffer
            session.body_bytes = #session.buffer
        end
        session.buffer = ""
        session.header_end = true
    end

    local request = session.request
    if not request then return end
    if session.body_bytes > (request.content_length or 0) then
        self:_reject(session, 400, "Bad Request", "请求内容无效。", false)
        return
    end
    if session.body_bytes >= (request.content_length or 0) then
        local body = table.concat(session.body_chunks)
        session.body_chunks = nil
        self:_handleRequest(session, request, body)
    end
end

function MobileSourceImport:_readClient(session)
    if session.sending then
        self:_flushResponse(session)
        return
    end
    local consumed = 0
    while consumed < self.read_budget_bytes and session.client and not session.sending do
        local requested = math.min(self.read_chunk_bytes, self.read_budget_bytes - consumed)
        if session.header_end and session.request then
            local remaining = (session.request.content_length or 0) - session.body_bytes
            if remaining <= 0 then
                self:_parseClientBuffer(session)
                return
            end
            requested = math.min(requested, remaining + 1)
        end
        local ok, chunk, err, partial = pcall(session.client.receive, session.client, requested)
        if not ok then chunk, err, partial = nil, "closed", nil end
        local piece = chunk or partial
        if piece and piece ~= "" then
            consumed = consumed + #piece
            session.last_activity = now()
            if session.header_end then
                session.body_chunks[#session.body_chunks + 1] = piece
                session.body_bytes = session.body_bytes + #piece
            else
                session.buffer = session.buffer .. piece
            end
            self:_parseClientBuffer(session)
        end
        if err and err ~= "timeout" then
            self:_closeClient(session)
            return
        end
        if err == "timeout" or not piece or piece == "" then break end
    end
    if session.client and not session.sending and now() - session.last_activity > self.request_timeout then
        self:_closeClient(session)
    end
end

function MobileSourceImport:_acceptClient(session)
    local ok, client, err = pcall(session.server.accept, session.server)
    if not ok then client, err = nil, "closed" end
    if client then
        if session.client then
            closeSocket(client)
            return
        end
        pcall(client.settimeout, client, 0)
        session.client = client
        session.started_at = now()
        session.last_activity = session.started_at
        session.buffer = ""
        session.body_chunks = nil
        session.body_bytes = 0
        session.header_end = false
        session.request = nil
        if type(session.on_client) == "function" then pcall(session.on_client, session) end
    elseif err and err ~= "timeout" and err ~= "would block" then
        self:stop(session, "service-error", true)
    end
end

function MobileSourceImport:_schedule(session)
    if session.closed then return end
    session.poll_fn = function() self:_poll(session) end
    local interval = session.client and self.active_poll_interval or self.poll_interval
    self.ui_manager:scheduleIn(interval, session.poll_fn)
end

function MobileSourceImport:_poll(session)
    if not session or session.closed or self.active ~= session then return end
    local current = now()
    if current >= session.deadline then
        self:stop(session, "timeout", true)
        return
    end
    if not session.client then self:_acceptClient(session) else self:_readClient(session) end
    self:_schedule(session)
end

function MobileSourceImport:stop(session, reason, notify)
    session = session or self.active
    if not session or session.closed then return true end
    session.closed = true
    if session.poll_fn then pcall(self.ui_manager.unschedule, self.ui_manager, session.poll_fn) end
    self:_closeClient(session)
    closeSocket(session.server)
    session.server = nil
    self:_closeKindleFirewall(session)
    if session.pending_temp_path and not session.accepted then
        self:removeTempFile(session.pending_temp_path)
        session.pending_temp_path = nil
    end
    if self.active == session then self.active = nil end
    if notify and type(session.on_closed) == "function" then
        pcall(session.on_closed, reason)
    end
    return true
end

function MobileSourceImport:closeActive(reason)
    return self:stop(self.active, reason or "closed", true)
end

function MobileSourceImport:notifySuspend()
    return self:closeActive("suspend")
end

function MobileSourceImport:start(options)
    options = options or {}
    if self.active and not self.active.closed then return nil, "已有手机导入正在等待" end
    if not networkIsConnected() and not options.host then return nil, "请先连接 Wi-Fi。" end

    local host = options.host
    if not host then host = self:getLocalIPv4() end
    if not isIPv4(host) then return nil, "无法取得 Kindle 的局域网地址，请检查 Wi-Fi。" end

    local socket_api = options.socket or self.socket
    local ok, server, bind_err = pcall(socket_api.bind, options.bind_host or "*", tonumber(options.port) or 0)
    if not ok or not server then return nil, "无法开启手机连接，请稍后重试。" end
    local configured = pcall(server.settimeout, server, 0)
    if not configured then closeSocket(server); return nil, "无法开启手机连接，请稍后重试。" end
    local got_name, bound_host, bound_port = pcall(server.getsockname, server)
    if not got_name or not tonumber(bound_port) or tonumber(bound_port) <= 0 then
        closeSocket(server)
        return nil, "无法开启手机连接，请稍后重试。"
    end

    local session = {
        owner = self,
        server = server,
        host = host,
        port = tonumber(bound_port),
        token = options.token or randomToken(),
        started_at = now(),
        deadline = now() + (tonumber(options.timeout or self.session_timeout) or self.session_timeout),
        timeout_seconds = tonumber(options.timeout or self.session_timeout) or self.session_timeout,
        on_submit = options.on_submit,
        on_client = options.on_client,
        on_closed = options.on_closed,
        closed = false,
        accepted = false,
        submission_count = 0,
    }
    if type(session.on_submit) ~= "function" then
        closeSocket(server)
        return nil, "手机导入暂时不可用，请稍后重试。"
    end
    if not self:_openKindleFirewall(session) then
        closeSocket(server)
        return nil, "Kindle 无法开放手机连接端口，请重启 KOReader 后再试。"
    end
    session.url = "http://" .. host .. ":" .. tostring(session.port) .. "/" .. session.token
    self.active = session
    local scheduled = pcall(self._schedule, self, session)
    if not scheduled then
        self:stop(session, "schedule-error", false)
        return nil, "手机导入暂时不可用，请稍后重试。"
    end
    return session
end

return MobileSourceImport
