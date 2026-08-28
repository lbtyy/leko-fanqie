-- Narrow, explicit Legado Java compatibility layer.
--
-- This module is deliberately independent of QuickJS.  QuickJS owns the
-- JavaScript facade and forwards opaque object calls here; this module owns
-- the small Java/Legado semantics that can be reproduced safely on KOReader.
-- It is not a JVM and the registry is intentionally closed.
local CompressionCompat = require("Leko/CompressionCompat")

local JavaHostCompat = {}

local MAX_BYTES = 8 * 1024 * 1024
local MAX_GZIP_INPUT = 8 * 1024 * 1024
local MAX_GZIP_OUTPUT = 8 * 1024 * 1024
local MAX_GZIP_RATIO = 100

local PACKAGE_CLASSES = {
    ["java.lang"] = { String = true },
    ["java.io"] = {
        ByteArrayInputStream = true,
        ByteArrayOutputStream = true,
    },
    ["java.util"] = { Base64 = true },
    ["java.util.zip"] = { GZIPInputStream = true },
}

local KNOWN_PACKAGES = {
    java = true,
    ["java.lang"] = true,
    ["java.io"] = true,
    ["java.util"] = true,
    ["java.util.zip"] = true,
}

local function hostError(category, message)
    category = tostring(category or "HOST_API_UNSUPPORTED")
    if category == "HOST_API_UNSUPPORTED" then
        error(category .. ": host-unsupported: " .. tostring(message or "unsupported Java host operation"))
    end
    error(category .. ": " .. tostring(message or "unsupported Java host operation"))
end

local function normalizeEncoding(value)
    value = tostring(value or "UTF-8"):upper():gsub("[_%s%-]", "")
    if value == "UTF8" then return "UTF-8" end
    if value == "ISO88591" or value == "LATIN1" then return "ISO-8859-1" end
    hostError("HOST_API_UNSUPPORTED", "unsupported byte/string encoding " .. value)
end

local function bytesFrom(value, label)
    label = label or "byte array"
    if type(value) == "string" then
        if #value > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
        return value
    end
    if type(value) ~= "table" then hostError("HOST_API_INVALID", label .. " is not a byte array") end
    local marker = rawget(value, "kind")
    if marker == "java_byte_array" then
        local bytes = rawget(value, "bytes") or ""
        if #bytes > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
        return bytes
    end
    local count = #value
    if count > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
    local output = {}
    for index = 1, count do
        local number = tonumber(value[index])
        if not number or number ~= number or number % 1 ~= 0 or number < 0 or number > 255 then
            hostError("HOST_API_INVALID", label .. " contains an invalid byte at " .. tostring(index - 1))
        end
        output[index] = string.char(number)
    end
    return table.concat(output)
end

local function byteArray(value)
    return { kind = "java_byte_array", bytes = bytesFrom(value) }
end

local function byteArrayRange(value, offset, length)
    local bytes = bytesFrom(value)
    offset = tonumber(offset or 0)
    length = tonumber(length)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative byte-array offset") end
    if length == nil then length = #bytes - offset end
    if length % 1 ~= 0 or length < 0 or offset + length > #bytes then
        hostError("HOST_API_INVALID", "byte-array range is outside its bounds")
    end
    return bytes, offset, length
end

local function writeBytes(target, offset, value, value_offset, length)
    if target.closed then hostError("HOST_API_STATE", "stream is closed") end
    local source, source_offset, source_length = byteArrayRange(value, value_offset, length)
    offset = tonumber(offset or 0)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative output offset") end
    local old = target.bytes or ""
    if offset > #old then old = old .. string.rep("\0", offset - #old) end
    local end_at = offset + source_length
    if end_at > MAX_BYTES then hostError("HOST_API_LIMIT", "byte-array output exceeds safety limit") end
    local prefix = old:sub(1, offset)
    local suffix = old:sub(end_at + 1)
    target.bytes = prefix .. source:sub(source_offset + 1, source_offset + source_length) .. suffix
end

local function inputRead(stream)
    if stream.closed then hostError("HOST_API_STATE", "stream is closed") end
    local remaining = #stream.bytes - stream.position
    if remaining <= 0 then return -1 end
    stream.position = stream.position + 1
    return string.byte(stream.bytes, stream.position)
end

-- The buffer writer is kept separate from inputRead so it can mutate an
-- opaque Java byte-array object without exposing Lua tables to JavaScript.
local function fillInputBuffer(stream, buffer, offset, length)
    if stream.closed then hostError("HOST_API_STATE", "stream is closed") end
    if type(buffer) ~= "table" or rawget(buffer, "kind") ~= "java_byte_array" then
        hostError("HOST_API_INVALID", "read(buffer) requires a Java byte array")
    end
    offset = tonumber(offset or 0)
    length = tonumber(length)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative read offset") end
    local current = buffer.bytes or ""
    if length == nil then length = #current - offset end
    if length % 1 ~= 0 or length < 0 or offset + length > #current then
        hostError("HOST_API_INVALID", "read buffer range is outside its bounds")
    end
    local remaining = #stream.bytes - stream.position
    if remaining <= 0 then return -1 end
    local count = math.min(remaining, length)
    buffer.bytes = current:sub(1, offset) .. stream.bytes:sub(stream.position + 1, stream.position + count)
        .. current:sub(offset + count + 1)
    stream.position = stream.position + count
    return count
end

local function decodeString(bytes, encoding)
    encoding = normalizeEncoding(encoding)
    if encoding == "UTF-8" then return bytes end
    local output = {}
    for index = 1, #bytes do output[index] = string.char(string.byte(bytes, index)) end
    return table.concat(output)
end

local function textFrom(value)
    if type(value) == "table" then
        local kind = rawget(value, "kind")
        if kind == "JavaString" then return tostring(rawget(value, "value") or "") end
        if kind == "java_byte_array" then return decodeString(rawget(value, "bytes") or "", "UTF-8") end
    end
    return tostring(value or "")
end

function JavaHostCompat:isKnownPackage(path)
    return KNOWN_PACKAGES[tostring(path or "")] == true
end

function JavaHostCompat:resolve(path)
    path = tostring(path or ""):gsub("^Packages\\.", "")
    if KNOWN_PACKAGES[path] then return { kind = "package", name = path } end
    local package_name, class_name = path:match("^(.*)%.([^.]+)$")
    if package_name and PACKAGE_CLASSES[package_name] and PACKAGE_CLASSES[package_name][class_name] then
        return { kind = "class", name = path }
    end
    hostError("HOST_API_UNSUPPORTED", "Java package/class is not allowlisted: " .. path)
end

function JavaHostCompat:importPackage(path)
    path = tostring(path or "")
    if not KNOWN_PACKAGES[path] then
        hostError("HOST_API_UNSUPPORTED", "Java package is not allowlisted: " .. path)
    end
    local classes = {}
    for class_name in pairs(PACKAGE_CLASSES[path] or {}) do classes[#classes + 1] = class_name end
    table.sort(classes)
    return classes
end

function JavaHostCompat:construct(class_name, args)
    class_name = tostring(class_name or "")
    args = args or {}
    if class_name == "java.io.ByteArrayInputStream" then
        local bytes = bytesFrom(args[1], "ByteArrayInputStream input")
        return { kind = "ByteArrayInputStream", bytes = bytes, position = 0, closed = false }
    elseif class_name == "java.io.ByteArrayOutputStream" then
        local size = tonumber(args[1] or 0) or 0
        if size < 0 or size > MAX_BYTES then hostError("HOST_API_LIMIT", "ByteArrayOutputStream initial size exceeds limit") end
        return { kind = "ByteArrayOutputStream", bytes = "", closed = false }
    elseif class_name == "java.util.zip.GZIPInputStream" then
        local input = args[1]
        if type(input) ~= "table" or rawget(input, "kind") ~= "ByteArrayInputStream" then
            hostError("HOST_API_INVALID", "GZIPInputStream requires ByteArrayInputStream")
        end
        if input.closed then hostError("HOST_API_STATE", "input stream is closed") end
        local compressed = input.bytes:sub(input.position + 1)
        if #compressed > MAX_GZIP_INPUT then hostError("HOST_API_LIMIT", "gzip input exceeds safety limit") end
        local output, err = CompressionCompat:gunzip(compressed, {
            max_input = MAX_GZIP_INPUT,
            max_output = MAX_GZIP_OUTPUT,
            max_ratio = MAX_GZIP_RATIO,
        })
        if not output then hostError("GZIP_DATA_ERROR", err or "invalid gzip data") end
        input.position = #input.bytes
        return { kind = "GZIPInputStream", bytes = output, position = 0, closed = false }
    elseif class_name == "java.lang.String" then
        local value = args[1]
        if type(value) == "table" and rawget(value, "kind") == "java_byte_array" then
            value = decodeString(value.bytes or "", args[2])
        else
            value = tostring(value or "")
        end
        return { kind = "JavaString", value = value, closed = false }
    elseif class_name == "java.util.Base64" then
        hostError("HOST_API_INVALID", "Base64 is a static utility and cannot be constructed")
    end
    hostError("HOST_API_UNSUPPORTED", "Java constructor is not allowlisted: " .. class_name)
end

function JavaHostCompat:static(class_name, method, args)
    class_name, method, args = tostring(class_name or ""), tostring(method or ""), args or {}
    if class_name == "java.util.Base64" and method == "getDecoder" then
        return { kind = "Base64Decoder", closed = false }
    end
    hostError("HOST_API_UNSUPPORTED", "Java static method is not allowlisted: " .. class_name .. "." .. method)
end

function JavaHostCompat:method(object, method, args)
    method, args = tostring(method or ""), args or {}
    local kind = type(object) == "table" and rawget(object, "kind") or ""
    if kind == "ByteArrayInputStream" or kind == "GZIPInputStream" then
        if method == "read" then
            if #args == 0 then return inputRead(object) end
            return fillInputBuffer(object, args[1], args[2], args[3])
        elseif method == "available" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return math.max(0, #object.bytes - object.position)
        elseif method == "close" then
            -- ByteArrayInputStream.close() is specified as a no-op in the
            -- JDK; GZIPInputStream.close() really closes its stream.
            if kind == "GZIPInputStream" then object.closed = true end
            return nil
        elseif method == "toString" then
            return "java.io.InputStream"
        end
    elseif kind == "ByteArrayOutputStream" then
        if method == "write" then
            if #args == 0 then hostError("HOST_API_INVALID", "write requires bytes") end
            if #args == 1 and type(args[1]) == "number" then
                if object.closed then hostError("HOST_API_STATE", "stream is closed") end
                local number = tonumber(args[1])
                if number < 0 or number > 255 or number % 1 ~= 0 then hostError("HOST_API_INVALID", "write byte is outside 0..255") end
                if #(object.bytes or "") >= MAX_BYTES then hostError("HOST_API_LIMIT", "byte-array output exceeds safety limit") end
                object.bytes = (object.bytes or "") .. string.char(number)
            else
                -- OutputStream.write(byte[], off, len) appends to the output;
                -- the offset/length belong to the input byte array.
                writeBytes(object, #(object.bytes or ""), args[1], args[2], args[3])
            end
            return nil
        elseif method == "toByteArray" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return byteArray(object.bytes or "")
        elseif method == "toString" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return decodeString(object.bytes or "", args[1])
        elseif method == "size" then
            return #(object.bytes or "")
        elseif method == "close" then
            -- ByteArrayOutputStream.close() is also a no-op in Java.  Rules
            -- commonly close it before calling toString()/toByteArray().
            return nil
        end
    elseif kind == "Base64Decoder" then
        if method == "decode" then
            local Crypto = require("Leko/CryptoCompat")
            -- In an imported `with (javaImport)` scope, `String(value)` is
            -- the allowlisted Java String constructor, not JavaScript's
            -- native String function.  Legado's Base64 decoder accepts that
            -- Java String directly, so unwrap it at this host boundary.
            local text = textFrom(args[1])
            if #text > MAX_BYTES * 2 then hostError("HOST_API_LIMIT", "Base64 input exceeds safety limit") end
            local ok, decoded = pcall(Crypto.base64Decode, text)
            if not ok or type(decoded) ~= "string" then hostError("HOST_API_INVALID", "invalid Base64 input") end
            return byteArray(decoded)
        end
    elseif kind == "JavaString" then
        if method == "getBytes" then
            normalizeEncoding(args[1])
            return byteArray(object.value or "")
        elseif method == "toString" then return object.value or "" end
    end
    hostError("HOST_API_UNSUPPORTED", "Java object method is not allowlisted: " .. kind .. "." .. method)
end

function JavaHostCompat:handleProperty(object, property)
    local kind = type(object) == "table" and rawget(object, "kind") or ""
    property = tostring(property or "")
    if kind == "java_byte_array" then
        if property == "length" then return #(object.bytes or "") end
        local index = tonumber(property)
        if index and index % 1 == 0 then
            index = index + 1
            return index >= 1 and index <= #(object.bytes or "") and string.byte(object.bytes, index) or nil
        end
    end
    return nil
end

function JavaHostCompat:limits()
    return {
        max_bytes = MAX_BYTES,
        max_gzip_input = MAX_GZIP_INPUT,
        max_gzip_output = MAX_GZIP_OUTPUT,
        max_gzip_ratio = MAX_GZIP_RATIO,
    }
end

return JavaHostCompat
