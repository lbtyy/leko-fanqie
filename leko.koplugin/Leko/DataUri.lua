local DataUri = {}

local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_MAP = {}
for index = 1, #BASE64_CHARS do BASE64_MAP[BASE64_CHARS:sub(index, index)] = index - 1 end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function percentDecode(value)
    value = tostring(value or "")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function base64Decode(value)
    value = tostring(value or ""):gsub("%s+", ""):gsub("[^%w%+/%=]", "")
    local output, buffer, bits = {}, 0, 0
    for index = 1, #value do
        local char = value:sub(index, index)
        if char == "=" then break end
        local code = BASE64_MAP[char]
        if code ~= nil then
            buffer = buffer * 64 + code
            bits = bits + 6
            while bits >= 8 do
                bits = bits - 8
                local byte = math.floor(buffer / (2 ^ bits)) % 256
                output[#output + 1] = string.char(byte)
                buffer = buffer % (2 ^ bits)
            end
        end
    end
    return table.concat(output)
end

function DataUri:is(value)
    return tostring(value or ""):lower():match("^data:") ~= nil
end

function DataUri:decode(value, options)
    options = options or {}
    value = trim(value)
    local metadata, payload = value:match("^[Dd][Aa][Tt][Aa]:([^,]*),(.*)$")
    if metadata == nil then return nil, "无效 data URI" end
    local is_base64 = metadata:lower():find(";base64", 1, true) ~= nil
    local media_type = metadata:match("^([^;]+)") or "text/plain"
    if media_type == "" or not media_type:find("/", 1, true) then media_type = "text/plain" end
    local body = is_base64 and base64Decode(payload) or percentDecode(payload)
    local max_bytes = tonumber(options.max_bytes) or (8 * 1024 * 1024)
    if #body > max_bytes then return nil, "data URI 内容过大" end
    return {
        body = body,
        content_type = media_type,
        metadata = metadata,
        base64 = is_base64,
    }
end

DataUri.percentDecode = percentDecode
DataUri.base64Decode = base64Decode

return DataUri
