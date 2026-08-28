-- Lightweight image header inspection used before KOReader allocates a decoded bitmap.
-- This module deliberately has no KOReader dependencies so it can be unit-tested off-device.
local ImageInfo = {}

local function u16be(data, pos)
    local a, b = data:byte(pos, pos + 1)
    if not b then return nil end
    return a * 256 + b
end

local function u16le(data, pos)
    local a, b = data:byte(pos, pos + 1)
    if not b then return nil end
    return a + b * 256
end

local function u24le(data, pos)
    local a, b, c = data:byte(pos, pos + 2)
    if not c then return nil end
    return a + b * 256 + c * 65536
end

local function u32be(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u32le(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local JPEG_SOF = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true,
    [0xC9] = true, [0xCA] = true, [0xCB] = true,
    [0xCD] = true, [0xCE] = true, [0xCF] = true,
}

local function inspectJpeg(data)
    local info = { format = "jpg", complete = false }
    local pos = 3
    while pos <= #data do
        while pos <= #data and data:byte(pos) ~= 0xFF do pos = pos + 1 end
        if pos > #data then break end
        while pos <= #data and data:byte(pos) == 0xFF do pos = pos + 1 end
        local marker = data:byte(pos)
        if not marker then break end
        pos = pos + 1
        if marker == 0xD9 then
            info.complete = true
            break
        elseif marker == 0xDA then
            -- Entropy-coded data follows SOS. Search for EOI near the tail without
            -- trying to parse byte-stuffing and restart markers here.
            local tail_start = math.max(pos, #data - 1024)
            if data:find("\255\217", tail_start, true) then info.complete = true end
            break
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
            -- Standalone marker, no segment length.
        else
            local segment_length = u16be(data, pos)
            if not segment_length or segment_length < 2 or pos + segment_length - 1 > #data then
                info.truncated = true
                break
            end
            if JPEG_SOF[marker] and segment_length >= 7 then
                info.height = u16be(data, pos + 3)
                info.width = u16be(data, pos + 5)
                info.components = data:byte(pos + 7)
                info.four_component = info.components == 4
                info.progressive = marker == 0xC2 or marker == 0xC6 or marker == 0xCA or marker == 0xCE
                info.sof_marker = marker
            elseif marker == 0xEE and data:sub(pos + 2, pos + 6) == "Adobe" then
                info.adobe = true
            end
            pos = pos + segment_length
        end
    end
    if info.width and info.height then info.pixels = info.width * info.height end
    if not info.complete and data:find("\255\217", math.max(1, #data - 1024), true) then info.complete = true end
    return info
end

local function inspectPng(data)
    if #data < 24 or data:sub(13, 16) ~= "IHDR" then return { format = "png", truncated = true } end
    local width, height = u32be(data, 17), u32be(data, 21)
    return { format = "png", width = width, height = height, pixels = width and height and width * height or nil, complete = #data >= 33 }
end

local function inspectGif(data)
    local width, height = u16le(data, 7), u16le(data, 9)
    return { format = "gif", width = width, height = height, pixels = width and height and width * height or nil, complete = data:sub(-1) == ";" }
end

local function inspectWebp(data)
    local info = { format = "webp", complete = #data >= 20 }
    local chunk = data:sub(13, 16)
    if chunk == "VP8X" and #data >= 30 then
        info.width = (u24le(data, 25) or -1) + 1
        info.height = (u24le(data, 28) or -1) + 1
    elseif chunk == "VP8 " and #data >= 30 then
        local payload = 21
        if data:sub(payload + 3, payload + 5) == "\157\001\042" then
            local raw_w, raw_h = u16le(data, payload + 6), u16le(data, payload + 8)
            if raw_w and raw_h then
                info.width, info.height = raw_w % 16384, raw_h % 16384
            end
        end
    elseif chunk == "VP8L" and #data >= 25 and data:byte(21) == 0x2F then
        local b1, b2, b3, b4 = data:byte(22, 25)
        info.width = 1 + b1 + (b2 % 64) * 256
        info.height = 1 + math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024
    end
    if info.width and info.height then info.pixels = info.width * info.height end
    return info
end

local function inspectSvg(data)
    local head = data:sub(1, 8192)
    local function numberAttribute(name)
        local value = head:match(name .. "%s*=%s*['\"]%s*([%d%.]+)")
        return tonumber(value)
    end
    local width, height = numberAttribute("width"), numberAttribute("height")
    if not width or not height then
        local _, _, vw, vh = head:match("viewBox%s*=%s*['\"]%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
        width, height = width or tonumber(vw), height or tonumber(vh)
    end
    return { format = "svg", width = width, height = height, pixels = width and height and width * height or nil, complete = head:find("<svg", 1, true) ~= nil }
end

local function inspectTiff(data)
    local little = data:sub(1, 2) == "II"
    local big = data:sub(1, 2) == "MM"
    if not little and not big then return { format = "tiff", truncated = true } end
    local u16 = little and u16le or u16be
    local u32 = little and u32le or u32be
    local ifd_offset = u32(data, 5)
    if not ifd_offset then return { format = "tiff", truncated = true } end
    local pos = ifd_offset + 1
    local count = u16(data, pos)
    if not count or count > 4096 then return { format = "tiff", truncated = true } end
    local width, height
    for index = 0, count - 1 do
        local entry = pos + 2 + index * 12
        if entry + 11 > #data then break end
        local tag, kind, n = u16(data, entry), u16(data, entry + 2), u32(data, entry + 4)
        if (tag == 256 or tag == 257) and n == 1 then
            local value
            if kind == 3 then value = u16(data, entry + 8)
            elseif kind == 4 then value = u32(data, entry + 8) end
            if tag == 256 then width = value elseif tag == 257 then height = value end
        end
    end
    return { format = "tiff", width = width, height = height, pixels = width and height and width * height or nil, complete = width ~= nil and height ~= nil }
end

function ImageInfo:detect(data)
    data = type(data) == "string" and data or ""
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 2) == "\255\216" then return "jpg" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return "gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 4) == "II*\0" or data:sub(1, 4) == "MM\0*" then return "tiff" end
    local head = data:sub(1, 2048):gsub("^%s+", ""):lower()
    if head:find("<svg", 1, true) or head:find("<?xml", 1, true) then return "svg" end
    return nil
end

function ImageInfo:inspect(data)
    local format = self:detect(data)
    if format == "jpg" then return inspectJpeg(data)
    elseif format == "png" then return inspectPng(data)
    elseif format == "gif" then return inspectGif(data)
    elseif format == "webp" then return inspectWebp(data)
    elseif format == "svg" then return inspectSvg(data)
    elseif format == "tiff" then return inspectTiff(data) end
    return nil, "未知图片格式"
end

function ImageInfo:fitWithin(info, max_width, max_height)
    max_width = math.max(1, math.floor(tonumber(max_width or 1) or 1))
    max_height = math.max(1, math.floor(tonumber(max_height or 1) or 1))
    local width = tonumber(info and info.width)
    local height = tonumber(info and info.height)
    if not width or not height or width <= 0 or height <= 0 then return max_width, max_height end
    local ratio = math.min(max_width / width, max_height / height)
    return math.max(1, math.floor(width * ratio + 0.5)),
        math.max(1, math.floor(height * ratio + 0.5))
end

function ImageInfo:checkPolicy(info, byte_count, policy)
    policy = policy or {}
    byte_count = tonumber(byte_count or 0) or 0
    if byte_count <= 0 then return nil, "图片为空" end
    if policy.max_bytes and byte_count > policy.max_bytes then
        return nil, string.format("图片文件过大：%.2f MiB（上限 %.2f MiB）", byte_count / 1048576, policy.max_bytes / 1048576)
    end
    if not info or not info.format then return nil, "无法识别图片格式" end
    if info.format == "jpg" and policy.require_complete_jpeg ~= false and not info.complete then
        return nil, "JPEG 数据不完整（缺少结束标记，可能是下载截断或伪装文件）"
    end
    if info.truncated then return nil, "图片头部数据不完整" end
    if not info.width or not info.height or info.width <= 0 or info.height <= 0 then
        if policy.require_dimensions ~= false then return nil, "无法在解码前读取图片尺寸" end
        return true
    end
    if policy.max_side and math.max(info.width, info.height) > policy.max_side then
        return nil, string.format("图片边长过大：%d×%d（单边上限 %d）", info.width, info.height, policy.max_side)
    end
    if policy.max_pixels and info.width * info.height > policy.max_pixels then
        return nil, string.format("图片像素过大：%d×%d，共 %.2f 百万像素（上限 %.2f）",
            info.width, info.height, info.width * info.height / 1000000, policy.max_pixels / 1000000)
    end
    return true
end

return ImageInfo
