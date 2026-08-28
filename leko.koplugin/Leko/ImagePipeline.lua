local mime = require("mime")
local RenderImage = require("ui/renderimage")
local ImageInfo = require("Leko/ImageInfo")
local Util = require("Leko/Util")

local ImagePipeline = {
    search_policy = {
        max_bytes = 1536 * 1024,
        max_pixels = 900000,
        max_side = 1400,
        require_dimensions = true,
        require_complete_jpeg = true,
    },
    saved_policy = {
        max_bytes = 8 * 1024 * 1024,
        max_pixels = 12000000,
        max_side = 6000,
        require_dimensions = true,
        require_complete_jpeg = true,
    },
}

local EXT_BY_TYPE = {
    ["image/jpeg"] = "jpg", ["image/jpg"] = "jpg", ["image/pjpeg"] = "jpg",
    ["image/png"] = "png", ["image/gif"] = "gif", ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg", ["image/tiff"] = "tiff", ["image/x-tiff"] = "tiff",
}

local function normalizedContentType(value)
    return tostring(value or ""):lower():match("^%s*([^;]+)") or ""
end

local function obviousTextResponse(body)
    local head = tostring(body or ""):sub(1, 2048):gsub("^\239\187\191", ""):gsub("^%s+", ""):lower()
    if head:find("<!doctype html", 1, true) or head:find("<html", 1, true)
            or head:find("<head", 1, true) or head:find("<script", 1, true) then
        return "HTML 页面"
    end
    if head:sub(1, 1) == "{" or head:sub(1, 1) == "[" then return "JSON/文本响应" end
    return nil
end

local function firstBytesHex(body, count)
    local parts = {}
    for index = 1, math.min(#body, count or 12) do parts[#parts + 1] = string.format("%02X", body:byte(index)) end
    return #parts > 0 and table.concat(parts, " ") or "空"
end

local function freeImage(image)
    if image and image.free then pcall(image.free, image) end
end

local function addCandidate(candidates, seen, body, reason)
    if type(body) ~= "string" or body == "" or seen[body] then return end
    seen[body] = true
    candidates[#candidates + 1] = { body = body, reason = reason }
end

function ImagePipeline:decodeDataUri(value)
    local media_type, encoded = tostring(value or ""):match("^data:(image/[%w%+%.%-]+);base64,(.+)$")
    if not media_type then return nil end
    local ok, body = pcall(mime.unb64, encoded)
    if not ok or not body then return nil, "封面 data URI 解码失败" end
    return { body = body, content_type = media_type, url = "data:" }
end

function ImagePipeline:prepare(body, content_type, options)
    options = options or {}
    local policy = options.policy or self.search_policy
    body = type(body) == "string" and body or ""
    if body == "" then return nil, "封面响应为空" end

    local text_kind = obviousTextResponse(body)
    if text_kind then
        return nil, "封面服务器返回了" .. text_kind .. "（" .. tostring(#body)
            .. " 字节；头部 " .. firstBytesHex(body) .. "）"
    end

    local candidates, seen = {}, {}
    addCandidate(candidates, seen, body, "原始响应")
    if body:sub(1, 3) == "\239\187\191" then addCandidate(candidates, seen, body:sub(4), "移除 BOM") end
    for _, signature in ipairs({ "\255\216", "\137PNG\r\n\26\n", "GIF8", "RIFF", "<svg", "<?xml" }) do
        local pos = body:find(signature, 1, true)
        if pos and pos > 1 and pos <= 64 then addCandidate(candidates, seen, body:sub(pos), "移除前导字节") end
    end

    local data_media, data_encoded = body:match("^%s*data:(image/[%w%+%.%-]+);base64,(.+)$")
    if data_media and data_encoded then
        local ok, decoded = pcall(mime.unb64, data_encoded)
        if ok and decoded then addCandidate(candidates, seen, decoded, "解码 data URI") end
    end
    if #body >= 32 and #body <= 3 * 1024 * 1024 and body:match("^[A-Za-z0-9+/=\r\n%s]+$") then
        local compact = body:gsub("%s+", "")
        if #compact % 4 == 0 then
            local ok, decoded = pcall(mime.unb64, compact)
            if ok and decoded then addCandidate(candidates, seen, decoded, "解码 Base64 响应") end
        end
    end

    local last_error, last_info
    for _, candidate in ipairs(candidates) do
        local info, inspect_err = ImageInfo:inspect(candidate.body)
        if not info then
            last_error = inspect_err
        else
            last_info = info
            local allowed, policy_err = ImageInfo:checkPolicy(info, #candidate.body, policy)
            if not allowed then
                last_error = policy_err
            else
                local image
                if options.decode ~= false then
                    local target_w = math.max(1, math.floor(options.width or 360))
                    local target_h = math.max(1, math.floor(options.height or 520))
                    -- KOReader's RenderImage scales to the exact requested dimensions.
                    -- Fit the header dimensions ourselves first so covers are not stretched.
                    target_w, target_h = ImageInfo:fitWithin(info, target_w, target_h)
                    local ok
                    ok, image = pcall(RenderImage.renderImageData, RenderImage, candidate.body, #candidate.body, false, target_w, target_h)
                    if not ok or not image then
                        image = nil
                        last_error = "KOReader 无法解码该图片"
                    end
                end
                if options.decode == false or image then
                    if image and not options.keep_image then freeImage(image); image = nil end
                    local render_width, render_height
                    if image and image.getWidth then
                        local dim_ok, value = pcall(image.getWidth, image)
                        if dim_ok then render_width = value end
                    end
                    if image and image.getHeight then
                        local dim_ok, value = pcall(image.getHeight, image)
                        if dim_ok then render_height = value end
                    end
                    return {
                        body = candidate.body,
                        ext = info.format or EXT_BY_TYPE[normalizedContentType(content_type)] or "img",
                        content_type = normalizedContentType(content_type),
                        note = candidate.reason,
                        info = info,
                        image = image,
                        render_width = render_width,
                        render_height = render_height,
                        estimated_decoded_bytes = info.pixels and info.pixels * 4 or nil,
                    }
                end
            end
        end
    end
    return nil, tostring(last_error or "KOReader 无法解码封面")
        .. "（Content-Type: " .. tostring(content_type or "未知")
        .. "；" .. tostring(#body) .. " 字节；头部 " .. firstBytesHex(body) .. "）", last_info
end

function ImagePipeline:validateFile(path, policy, width, height)
    local body, err = Util.readFile(path, true)
    if not body then return nil, err or "封面文件不存在" end
    local prepared, prepare_err = self:prepare(body, nil, {
        policy = policy or self.saved_policy,
        width = width or 360,
        height = height or 520,
        keep_image = false,
    })
    if not prepared then return nil, prepare_err end
    return true, prepared.info
end

-- Encode only an already bounded RenderImage/BlitBuffer. Callers own the
-- image lifetime and must release it with freeImage after this returns.
function ImagePipeline:encodeImage(image, path, format, quality)
    if not image or type(image.writeToFile) ~= "function" then
        return nil, "KOReader 不支持封面格式转换"
    end
    local ok, written = pcall(image.writeToFile, image, path, format or "png", quality or 90, false)
    if not ok or written == false then
        return nil, "KOReader 封面格式转换失败"
    end
    local body, read_err = Util.readFile(path, true)
    if type(body) ~= "string" or body == "" then
        return nil, read_err or "封面格式转换后文件为空"
    end
    return body
end

function ImagePipeline:freeImage(image) freeImage(image) end

return ImagePipeline
