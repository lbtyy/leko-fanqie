-- Charset detection and conversion through glibc/libiconv via LuaJIT FFI.
local Charset = {}
local ffi_ok, ffi = pcall(require, "ffi")
local iconv_lib

if ffi_ok then
    pcall(function()
        ffi.cdef[[
            typedef void *iconv_t;
            iconv_t iconv_open(const char *tocode, const char *fromcode);
            size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
                char **outbuf, size_t *outbytesleft);
            int iconv_close(iconv_t cd);
        ]]
        -- On Kindle's glibc toolchain iconv is normally exported by libc.
        local candidates = { ffi.C, "iconv", "libiconv.so.2", "libc.so.6" }
        for _, candidate in ipairs(candidates) do
            local lib = candidate
            if type(candidate) == "string" then
                local ok, loaded = pcall(ffi.load, candidate)
                if ok then lib = loaded else lib = nil end
            end
            if lib then
                local ok = pcall(function() return lib.iconv_open end)
                if ok then iconv_lib = lib break end
            end
        end
    end)
end

local aliases = {
    ["utf8"] = "UTF-8", ["utf-8"] = "UTF-8",
    ["gbk"] = "GBK", ["cp936"] = "CP936",
    ["gb2312"] = "GB2312", ["gb_2312-80"] = "GB2312",
    ["gb18030"] = "GB18030",
    ["big5"] = "BIG5", ["big5-hkscs"] = "BIG5-HKSCS",
    ["shift_jis"] = "SHIFT_JIS", ["shift-jis"] = "SHIFT_JIS",
    ["sjis"] = "SHIFT_JIS", ["euc-jp"] = "EUC-JP",
    ["iso-8859-1"] = "ISO-8859-1", ["latin1"] = "ISO-8859-1",
}

local legacy_cn_candidates = {
    ["GB18030"] = { "GB18030", "GBK", "CP936", "GB2312" },
    ["GBK"] = { "GBK", "CP936", "GB18030", "GB2312" },
    ["CP936"] = { "CP936", "GBK", "GB18030", "GB2312" },
    ["GB2312"] = { "GB2312", "GBK", "CP936", "GB18030" },
}

local module_dir = ((debug.getinfo(1, "S") or {}).source or ""):gsub("^@", ""):match("^(.*[/\\])") or ""
local gbk_map, gb18030_ranges
local reverse_cache = {}

local function loadLegacyCnData()
    if gbk_map ~= nil then return gbk_map ~= false end
    local handle = io.open(module_dir .. "gbk-unicode.bin", "rb")
    if not handle then gbk_map = false; return false end
    gbk_map = handle:read("*a") or false
    handle:close()
    if type(gbk_map) ~= "string" or #gbk_map < 71820 then gbk_map = false; return false end
    local ok, ranges = pcall(require, "Leko/GB18030Ranges")
    gb18030_ranges = ok and type(ranges) == "table" and ranges or {}
    return true
end

local function utf8Char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function utf8Codes(text)
    local index, length = 1, #text
    return function()
        if index > length then return nil end
        local start = index
        local b1 = text:byte(index); index = index + 1
        if b1 < 0x80 then return start, b1 end
        local needed, code
        if b1 >= 0xC2 and b1 <= 0xDF then needed, code = 1, b1 - 0xC0
        elseif b1 >= 0xE0 and b1 <= 0xEF then needed, code = 2, b1 - 0xE0
        elseif b1 >= 0xF0 and b1 <= 0xF4 then needed, code = 3, b1 - 0xF0
        else return start, nil, "invalid UTF-8" end
        for _ = 1, needed do
            local b = text:byte(index)
            if not b or b < 0x80 or b > 0xBF then return start, nil, "invalid UTF-8" end
            code = code * 0x40 + (b - 0x80); index = index + 1
        end
        return start, code
    end
end

local function gbkCodepoint(b1, b2)
    if not loadLegacyCnData() then return nil end
    if b1 < 0x81 or b1 > 0xFE or b2 < 0x40 or b2 > 0xFE or b2 == 0x7F then return nil end
    local trail = b2 <= 0x7E and (b2 - 0x40) or (b2 - 0x41)
    local slot = (b1 - 0x81) * 190 + trail
    local offset = slot * 3 + 1
    local a, b, c = gbk_map:byte(offset, offset + 2)
    local cp = a and (a * 65536 + b * 256 + c) or 0
    return cp ~= 0 and cp or nil
end

local function gb18030Codepoint(b1, b2, b3, b4)
    if not loadLegacyCnData() then return nil end
    if b1 < 0x81 or b1 > 0xFE or b2 < 0x30 or b2 > 0x39
            or b3 < 0x81 or b3 > 0xFE or b4 < 0x30 or b4 > 0x39 then return nil end
    local encoded = (((b1 - 0x81) * 10 + (b2 - 0x30)) * 126 + (b3 - 0x81)) * 10 + (b4 - 0x30)
    local lo, hi = 1, #gb18030_ranges
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2); local range = gb18030_ranges[mid]
        if encoded < range[1] then hi = mid - 1
        elseif encoded > range[2] then lo = mid + 1
        else return range[3] + (encoded - range[1]) end
    end
    return nil
end

local function decodeLegacyCn(value, charset)
    if not loadLegacyCnData() then return nil, "legacy Chinese mapping unavailable" end
    local out, index = {}, 1
    while index <= #value do
        local b1 = value:byte(index)
        if b1 < 0x80 then out[#out + 1] = string.char(b1); index = index + 1
        else
            local b2 = value:byte(index + 1)
            if charset == "GB18030" and b2 and b2 >= 0x30 and b2 <= 0x39 then
                local b3, b4 = value:byte(index + 2), value:byte(index + 3)
                local cp = b3 and b4 and gb18030Codepoint(b1, b2, b3, b4)
                if not cp then return nil, "invalid GB18030 sequence at byte " .. tostring(index) end
                out[#out + 1] = utf8Char(cp); index = index + 4
            else
                local cp = b2 and gbkCodepoint(b1, b2)
                if not cp then return nil, "invalid " .. tostring(charset) .. " sequence at byte " .. tostring(index) end
                out[#out + 1] = utf8Char(cp); index = index + 2
            end
        end
    end
    return table.concat(out)
end

local function gbkBytesForCodepoint(cp, charset)
    local cache_key = tostring(charset) .. ":" .. tostring(cp)
    if reverse_cache[cache_key] ~= nil then return reverse_cache[cache_key] or nil end
    if not loadLegacyCnData() then return nil end
    for lead = 0x81, 0xFE do
        if charset ~= "GB2312" or (lead >= 0xA1 and lead <= 0xF7) then
            for trail = 0x40, 0xFE do
                if trail ~= 0x7F and (charset ~= "GB2312" or trail >= 0xA1)
                        and gbkCodepoint(lead, trail) == cp then
                    local encoded = string.char(lead, trail)
                    reverse_cache[cache_key] = encoded
                    return encoded
                end
            end
        end
    end
    reverse_cache[cache_key] = false
    return nil
end

local function gb18030BytesForCodepoint(cp)
    if not loadLegacyCnData() then return nil end
    local lo, hi = 1, #gb18030_ranges
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2); local range = gb18030_ranges[mid]
        local cp_last = range[3] + (range[2] - range[1])
        if cp < range[3] then hi = mid - 1
        elseif cp > cp_last then lo = mid + 1
        else
            local encoded = range[1] + (cp - range[3])
            local b4 = 0x30 + encoded % 10; encoded = math.floor(encoded / 10)
            local b3 = 0x81 + encoded % 126; encoded = math.floor(encoded / 126)
            local b2 = 0x30 + encoded % 10; encoded = math.floor(encoded / 10)
            local b1 = 0x81 + encoded
            return string.char(b1, b2, b3, b4)
        end
    end
    return nil
end

local function encodeLegacyCn(value, charset)
    if not loadLegacyCnData() then return nil, "legacy Chinese mapping unavailable" end
    local out = {}
    for position, cp, err in utf8Codes(value) do
        if err then return nil, err .. " at byte " .. tostring(position) end
        if cp < 0x80 then out[#out + 1] = string.char(cp)
        else
            local encoded = gbkBytesForCodepoint(cp, charset)
            if not encoded and charset == "GB18030" then encoded = gb18030BytesForCodepoint(cp) end
            if not encoded then return nil, "character U+" .. string.format("%04X", cp) .. " is not representable in " .. charset end
            out[#out + 1] = encoded
        end
    end
    return table.concat(out)
end

local function legacyCnConvert(value, from_charset, to_charset)
    local from_cn = legacy_cn_candidates[from_charset] ~= nil
    local to_cn = legacy_cn_candidates[to_charset] ~= nil
    if from_cn and to_charset == "UTF-8" then return decodeLegacyCn(value, from_charset) end
    if from_charset == "UTF-8" and to_cn then return encodeLegacyCn(value, to_charset) end
    return nil, "unsupported legacy fallback direction"
end

function Charset:normalize(name)
    name = tostring(name or ""):lower():gsub("[\"']", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return aliases[name] or name:upper()
end

function Charset:candidates(name)
    local normalized = self:normalize(name)
    local family = legacy_cn_candidates[normalized]
    if not family then return { normalized } end
    local output, seen = {}, {}
    for _, candidate in ipairs(family) do
        if candidate ~= "" and not seen[candidate] then
            seen[candidate] = true
            output[#output + 1] = candidate
        end
    end
    return output
end

function Charset:isAvailable()
    return iconv_lib ~= nil or loadLegacyCnData()
end

function Charset:detect(body, content_type, requested)
    if requested and tostring(requested) ~= "" then return self:normalize(requested) end
    local header = tostring(content_type or ""):match("[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*[\"']?([%w_%-]+)")
    if header then return self:normalize(header) end
    body = tostring(body or "")
    if body:sub(1, 3) == "\239\187\191" then return "UTF-8" end
    local head = body:sub(1, 4096)
    local meta = head:match("[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*[\"']?([%w_%-]+)")
    if meta then return self:normalize(meta) end
    return "UTF-8"
end

local function isBadDescriptor(cd)
    return cd == nil or cd == ffi.cast("void *", -1)
end

local function convertWithDescriptor(value, to_charset, from_charset)
    local cd = iconv_lib.iconv_open(to_charset, from_charset)
    if isBadDescriptor(cd) then return nil, "unsupported" end
    local out_capacity = math.max(64, #value * 8 + 32)
    local out = ffi.new("char[?]", out_capacity)
    local in_storage = ffi.new("char[?]", #value + 1)
    ffi.copy(in_storage, value, #value)
    local in_ptr = ffi.new("char *[1]", in_storage)
    local out_ptr = ffi.new("char *[1]", out)
    local in_left = ffi.new("size_t[1]", #value)
    local out_left = ffi.new("size_t[1]", out_capacity)
    local result = iconv_lib.iconv(cd, in_ptr, in_left, out_ptr, out_left)
    iconv_lib.iconv_close(cd)
    local iconv_error = ffi.cast("size_t", -1)
    if result == iconv_error and tonumber(in_left[0]) > 0 then
        return nil, "conversion failed"
    end
    return ffi.string(out, out_capacity - tonumber(out_left[0]))
end

function Charset:convert(value, from_charset, to_charset)
    value = tostring(value or "")
    local from_normalized = self:normalize(from_charset)
    local to_normalized = self:normalize(to_charset)
    if value == "" or from_normalized == to_normalized then return value end

    -- Use the bundled deterministic decoder for the GB family even when the
    -- host advertises iconv.  Kindle variants differ in which aliases exist,
    -- and some FFI/libc combinations expose iconv_open but not a safely usable
    -- descriptor ABI.  The compact mapping is both portable and bounded.
    if legacy_cn_candidates[from_normalized] or legacy_cn_candidates[to_normalized] then
        return legacyCnConvert(value, from_normalized, to_normalized)
    end

    if not iconv_lib then return nil, "iconv unavailable" end
    local attempted = {}
    for _, from_name in ipairs(self:candidates(from_charset)) do
        for _, to_name in ipairs(self:candidates(to_charset)) do
            local key = from_name .. "->" .. to_name
            if not attempted[key] then
                attempted[key] = true
                local converted, err = convertWithDescriptor(value, to_name, from_name)
                if converted ~= nil then return converted end
                if err ~= "unsupported" then return nil, "charset conversion failed" end
            end
        end
    end
    return nil, "unsupported charset " .. from_normalized
end

function Charset:decode(value, charset)
    local normalized = self:normalize(charset)
    if normalized == "UTF-8" or normalized == "" then
        return tostring(value or ""):gsub("^\239\187\191", "")
    end
    return self:convert(value, charset, "UTF-8")
end

function Charset:encode(value, charset)
    local normalized = self:normalize(charset)
    if normalized == "UTF-8" or normalized == "" then return tostring(value or "") end
    return self:convert(value, "UTF-8", charset)
end

return Charset
