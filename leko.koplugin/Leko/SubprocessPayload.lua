local rapidjson = require("rapidjson")
local socket = require("socket")
local ffiutil = require("ffi/util")
local util_ok, Util = pcall(require, "Leko/Util")
if not util_ok or type(Util) ~= "table" then Util = nil end

-- Pipes are control channels. The parent normally waits for the child to exit
-- before draining the pipe, so a large pipe write can deadlock when the kernel
-- buffer fills. Small results stay inline; larger business payloads use an
-- atomic temporary file and the pipe carries only a readiness/error envelope.
local SubprocessPayload = {
    default_max_bytes = 2 * 1024 * 1024,
    inline_max_bytes = 3 * 1024,
    envelope_max_bytes = 2048,
}

local counter = 0

local function encodeEnvelope(envelope)
    local ok, encoded = pcall(rapidjson.encode, envelope)
    if ok and #encoded <= SubprocessPayload.envelope_max_bytes then return encoded end
    return '{"version":1,"stored":false,"error":"后台任务结果无法保存"}'
end

local function atomicWrite(path, content)
    if Util and type(Util.writeFile) == "function" then
        return Util.writeFile(path, content, true)
    end
    local temp_path = path .. ".tmp"
    local file, open_err = io.open(temp_path, "wb")
    if not file then return false, open_err end
    local wrote, write_err = file:write(content or "")
    if wrote then file:flush() end
    file:close()
    if not wrote then os.remove(temp_path); return false, write_err end
    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then os.remove(temp_path); return false, rename_err end
    return true
end

local function readFile(path)
    if Util and type(Util.readFile) == "function" then
        local data, read_err = Util.readFile(path, true)
        return data, read_err, data and #data or 0
    end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, open_err end
    local size = file:seek("end") or 0
    file:seek("set", 0)
    local data = file:read("*a")
    file:close()
    return data, nil, size
end

function SubprocessPayload:newPath(label, directory)
    counter = counter + 1
    directory = tostring(directory or "/tmp"):gsub("/+$", "")
    label = tostring(label or "payload"):gsub("[^%w%._%-]", "-"):sub(1, 48)
    local stamp = math.floor((tonumber(socket.gettime()) or os.time()) * 1000000)
    return string.format("%s/leko-ipc-%s-%d-%d.json", directory, label, stamp, counter)
end

function SubprocessPayload:cleanup(path)
    if not path then return end
    os.remove(path)
    os.remove(path .. ".tmp")
end

function SubprocessPayload:write(write_fd, path, payload, options)
    options = options or {}
    local max_bytes = math.max(4096,
        tonumber(options.max_bytes or self.default_max_bytes) or self.default_max_bytes)
    local inline_max = math.max(512, math.min(self.inline_max_bytes,
        tonumber(options.inline_max_bytes or self.inline_max_bytes) or self.inline_max_bytes))
    local ok, encoded = pcall(rapidjson.encode, payload)
    if not ok then
        local envelope = { version = 1, stored = false,
            error = "后台任务结果无法完整保存：" .. tostring(encoded) }
        ffiutil.writeToFD(write_fd, "E" .. encodeEnvelope(envelope), true)
        return false, envelope.error
    end
    if #encoded > max_bytes then
        local envelope = {
            version = 1, stored = false, bytes = #encoded,
            error = string.format(
                "后台任务返回的数据异常大（%d 字节，上限 %d 字节），任务已停止",
                #encoded, max_bytes),
        }
        ffiutil.writeToFD(write_fd, "E" .. encodeEnvelope(envelope), true)
        return false, envelope.error
    end
    if #encoded <= inline_max then
        self:cleanup(path)
        ffiutil.writeToFD(write_fd, "I" .. encoded, true)
        return true
    end

    local wrote, write_err = atomicWrite(path, encoded)
    local envelope = { version = 1, stored = wrote == true, bytes = #encoded }
    if not wrote then envelope.error = "后台任务结果写入失败：" .. tostring(write_err) end
    ffiutil.writeToFD(write_fd, (wrote and "F" or "E") .. encodeEnvelope(envelope), true)
    return wrote == true, envelope.error
end

local function readControl(result_fd)
    if not result_fd then return nil, nil, "后台任务没有结果管道" end
    local ok, raw = pcall(ffiutil.readAllFromFD, result_fd)
    if not ok then return nil, nil, tostring(raw or "后台任务结果管道读取失败") end
    if not raw or raw == "" then return nil, nil, "后台任务没有返回控制信封" end
    local mode, body = raw:sub(1, 1), raw:sub(2)
    if mode == "I" then
        local decoded_ok, payload = pcall(rapidjson.decode, body)
        if decoded_ok and type(payload) == "table" then return payload, { inline = true } end
        return nil, nil, "后台任务内联结果损坏"
    end
    if mode == "F" or mode == "E" then
        local decoded_ok, envelope = pcall(rapidjson.decode, body)
        if decoded_ok and type(envelope) == "table" then return nil, envelope end
        return nil, nil, "后台任务控制信封损坏"
    end
    -- Compatibility for older direct-JSON workers during mixed-directory
    -- upgrades. New workers always emit an explicit mode prefix.
    local decoded_ok, payload = pcall(rapidjson.decode, raw)
    if decoded_ok and type(payload) == "table" then return payload, { legacy_inline = true } end
    return nil, nil, "后台任务控制信封损坏"
end

function SubprocessPayload:read(result_fd, path, options)
    options = options or {}
    local max_bytes = math.max(4096,
        tonumber(options.max_bytes or self.default_max_bytes) or self.default_max_bytes)
    local inline_payload, envelope, control_err = readControl(result_fd)
    if inline_payload then
        self:cleanup(path)
        return inline_payload, nil, envelope
    end

    -- The file is authoritative. If the child completed the atomic rename but
    -- died before writing its tiny envelope, the complete result remains usable.
    local encoded, read_err, size = readFile(path)
    if not encoded then
        self:cleanup(path)
        return nil, envelope and tostring(envelope.error or "后台任务结果文件不存在")
            or tostring(control_err or read_err or "后台任务结果文件不存在")
    end
    size = tonumber(size or #encoded) or #encoded
    if size <= 0 or size > max_bytes then
        self:cleanup(path)
        return nil, string.format("后台任务结果文件大小异常（%d 字节）", size)
    end
    self:cleanup(path)
    local ok, payload = pcall(rapidjson.decode, encoded)
    if not ok or type(payload) ~= "table" then return nil, "后台任务完整结果损坏" end
    return payload, nil, envelope
end

return SubprocessPayload
