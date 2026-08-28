local lfs = require("libs/libkoreader-lfs")
local koreader_util = require("util")
local bit = require("bit")

local Util = {}

-- Presentation values are bounded at the UI/storage boundary so a malformed
-- detail rule cannot turn a shelf row or detail page into a full directory dump.
Util.PRESENTATION_TEXT_LIMIT = 500
Util.COVER_DESCRIPTOR_LIMIT = 16 * 1024

function Util.trim(value)
    if value == nil then return "" end
    value = tostring(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.collapseSpaces(value)
    value = Util.trim(value)
    value = value:gsub("[\r\n\t]+", " ")
    value = value:gsub("%s%s+", " ")
    return value
end

function Util.splitPlain(value, separator)
    local result = {}
    if value == nil or value == "" then return result end
    separator = separator or ","
    local start = 1
    while true do
        local first, last = value:find(separator, start, true)
        if not first then
            table.insert(result, value:sub(start))
            break
        end
        table.insert(result, value:sub(start, first - 1))
        start = last + 1
    end
    return result
end

function Util.utf8Chars(value)
    value = value or ""
    return koreader_util.splitToChars(value)
end

function Util.utf8Sub(value, first_index, last_index)
    local chars = Util.utf8Chars(value)
    first_index = math.max(1, first_index or 1)
    last_index = math.min(#chars, last_index or #chars)
    if first_index > last_index then return "" end
    return table.concat(chars, "", first_index, last_index)
end

function Util.truncateUtf8(value, max_chars, suffix)
    value = tostring(value or "")
    max_chars = math.max(0, tonumber(max_chars or Util.PRESENTATION_TEXT_LIMIT) or Util.PRESENTATION_TEXT_LIMIT)
    if Util.utf8Length(value) <= max_chars then return value, false end
    suffix = tostring(suffix or "…")
    local suffix_length = Util.utf8Length(suffix)
    if suffix_length >= max_chars then
        return Util.utf8Sub(suffix, 1, max_chars), true
    end
    return Util.utf8Sub(value, 1, max_chars - suffix_length) .. suffix, true
end

function Util.safeCoverDescriptor(value)
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or #value > Util.COVER_DESCRIPTOR_LIMIT then return nil end
    return value
end

local function utf8ByteLength(byte)
    if not byte then return 0 end
    if byte < 0x80 then return 1 end
    if byte < 0xC0 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    if byte < 0xF8 then return 4 end
    -- Invalid leading bytes are consumed one byte at a time so malformed source
    -- text cannot trap the paginator in a zero-progress loop.
    return 1
end

function Util.utf8Length(value)
    value = value or ""
    local byte_index, count, length = 1, 0, #value
    while byte_index <= length do
        byte_index = byte_index + utf8ByteLength(value:byte(byte_index))
        count = count + 1
    end
    return count
end

-- Return a bounded UTF-8 window without first splitting the entire paragraph
-- into a Lua table. `first_index` is a 1-based character position. The optional
-- hint describes a previously known character/byte boundary and makes forward
-- page turns through a very long single-line chapter linear instead of O(n^2).
function Util.utf8Window(value, first_index, max_chars, hint_char, hint_byte)
    value = value or ""
    first_index = math.max(1, tonumber(first_index or 1) or 1)
    max_chars = math.max(1, tonumber(max_chars or 1) or 1)
    local length = #value
    local char_index = 1
    local byte_index = 1
    hint_char = tonumber(hint_char)
    hint_byte = tonumber(hint_byte)
    if hint_char and hint_byte and hint_char >= 1 and hint_char <= first_index
            and hint_byte >= 1 and hint_byte <= length + 1 then
        char_index = hint_char
        byte_index = hint_byte
    end
    while char_index < first_index and byte_index <= length do
        byte_index = byte_index + utf8ByteLength(value:byte(byte_index))
        char_index = char_index + 1
    end
    if byte_index > length then return "", 0, false, length + 1 end
    local start_byte = byte_index
    local count = 0
    while count < max_chars and byte_index <= length do
        byte_index = byte_index + utf8ByteLength(value:byte(byte_index))
        count = count + 1
    end
    return value:sub(start_byte, byte_index - 1), count, byte_index <= length, byte_index
end

function Util.basename(path)
    if not path then return "" end
    local clean = path:gsub("/+$", "")
    return clean:match("([^/]+)$") or clean
end

function Util.dirname(path)
    if not path then return "." end
    local dir = path:match("^(.*)/[^/]*$")
    if not dir or dir == "" then return "." end
    return dir
end

function Util.splitext(filename)
    local stem, extension = filename:match("^(.*)%.([^%.]+)$")
    if not stem then return filename, "" end
    return stem, extension:lower()
end

function Util.joinPath(...)
    local parts = { ... }
    local path = ""
    for _, part in ipairs(parts) do
        if part and part ~= "" then
            part = tostring(part)
            if path == "" then
                path = part:gsub("/+$", "")
            else
                path = path:gsub("/+$", "") .. "/" .. part:gsub("^/+", ""):gsub("/+$", "")
            end
        end
    end
    return path
end

function Util.mkdirp(path)
    if not path or path == "" then return false, "empty path" end
    if lfs.attributes(path, "mode") == "directory" then return true end

    local prefix = path:sub(1, 1) == "/" and "/" or ""
    for component in path:gmatch("[^/]+") do
        if prefix == "" or prefix == "/" then
            prefix = prefix .. component
        else
            prefix = prefix .. "/" .. component
        end
        local mode = lfs.attributes(prefix, "mode")
        if not mode then
            local ok, err = lfs.mkdir(prefix)
            if not ok and lfs.attributes(prefix, "mode") ~= "directory" then
                return false, err
            end
        elseif mode ~= "directory" then
            return false, prefix .. " is not a directory"
        end
    end
    return true
end

function Util.readFile(path, binary)
    local file, err = io.open(path, binary and "rb" or "r")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

function Util.writeFile(path, content, binary)
    local ok, err = Util.mkdirp(Util.dirname(path))
    if not ok then return false, err end
    local temp_path = path .. ".tmp"
    local file, open_err = io.open(temp_path, binary and "wb" or "w")
    if not file then return false, open_err end
    file:write(content or "")
    file:flush()
    file:close()
    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        return false, rename_err
    end
    return true
end

function Util.removeTree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return true end
    if mode == "file" or mode == "link" then
        return os.remove(path)
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            Util.removeTree(Util.joinPath(path, entry))
        end
    end
    return lfs.rmdir(path)
end

function Util.slug(value)
    value = Util.trim(value):lower()
    value = value:gsub("[^%w%-%._]", "-")
    value = value:gsub("%-+", "-")
    value = value:gsub("^%-", ""):gsub("%-$", "")
    if value == "" then value = tostring(os.time()) end
    return value
end

-- Deterministic, non-cryptographic identifier suitable for filenames.
function Util.hashId(value)
    value = tostring(value or "")
    local hash = 2166136261
    for index = 1, #value do
        hash = bit.bxor(hash, value:byte(index))
        hash = bit.tobit(hash * 16777619)
    end
    if hash < 0 then hash = hash + 4294967296 end
    return string.format("%08x", hash)
end

function Util.copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do
        result[Util.copyTable(key)] = Util.copyTable(item)
    end
    return result
end

local function encodeUtf8(code)
    if code <= 0x7F then
        return string.char(code)
    elseif code <= 0x7FF then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    elseif code <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(code / 0x40000),
            0x80 + (math.floor(code / 0x1000) % 0x40),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end
    return ""
end

function Util.htmlEntityDecode(value)
    if not value then return "" end
    local entities = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
        ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’", hellip = "…",
        mdash = "—", ndash = "–", middot = "·",
    }
    value = value:gsub("&#x([0-9a-fA-F]+);", function(hex)
        local code = tonumber(hex, 16)
        if not code or code > 0x10FFFF then return "" end
        return encodeUtf8(code)
    end)
    value = value:gsub("&#([0-9]+);", function(number)
        local code = tonumber(number)
        if not code or code > 0x10FFFF then return "" end
        return encodeUtf8(code)
    end)
    value = value:gsub("&([%a]+);", function(name)
        return entities[name:lower()] or "&" .. name .. ";"
    end)
    return value
end

function Util.stripHtml(value)
    if not value then return "" end
    value = value:gsub("<[Bb][Rr]%s*/?>", "\n")
    value = value:gsub("</[Pp]%s*>", "\n")
    value = value:gsub("</[Dd][Ii][Vv]%s*>", "\n")
    value = value:gsub("<[Ll][Ii][^>]*>", "\n")
    value = value:gsub("<script.-</script>", "")
    value = value:gsub("<style.-</style>", "")
    value = value:gsub("<[^>]+>", "")
    value = Util.htmlEntityDecode(value)
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    value = value:gsub("[ \t]+\n", "\n")
    value = value:gsub("\n[ \t]+", "\n")
    value = value:gsub("\n\n\n+", "\n\n")
    return Util.trim(value)
end

function Util.normalizeText(value)
    value = value or ""
    value = value:gsub("^\239\187\191", "") -- UTF-8 BOM
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    value = value:gsub("\194\160", " ") -- UTF-8 NBSP
    value = value:gsub("[ \t]+$", "")
    value = value:gsub("\n[ \t]+", "\n")
    value = value:gsub("\n\n\n+", "\n\n")
    return Util.trim(value)
end

function Util.splitParagraphs(value)
    value = Util.normalizeText(value)
    local paragraphs = {}
    if value == "" then return paragraphs end

    if value:find("\n%s*\n") then
        for block in (value .. "\n\n"):gmatch("(.-)\n%s*\n") do
            local paragraph = Util.collapseSpaces(block)
            if paragraph ~= "" then table.insert(paragraphs, paragraph) end
        end
    else
        for line in (value .. "\n"):gmatch("(.-)\n") do
            local paragraph = Util.collapseSpaces(line)
            if paragraph ~= "" then table.insert(paragraphs, paragraph) end
        end
    end

    if #paragraphs == 0 then table.insert(paragraphs, value) end
    return paragraphs
end

function Util.looksLikeChapterTitle(line)
    line = Util.trim(line)
    if line == "" or #line > 180 then return false end
    local first = line:sub(1, 3)
    if first == "第" then
        local markers = { "章", "节", "卷", "回", "部", "篇", "集" }
        for _, marker in ipairs(markers) do
            local position = line:find(marker, 4, true)
            if position and position <= 72 then return true end
        end
    end
    local lower = line:lower()
    if lower:match("^chapter%s+[%divxlcdm]+[%s%p]") or lower:match("^chapter%s+[%divxlcdm]+$") then
        return true
    end
    if lower:match("^ch%.?%s*%d+") then return true end
    return false
end

function Util.splitTextIntoChapters(content, fallback_title)
    content = Util.normalizeText(content)
    local chapters = {}
    local current_title = fallback_title or "正文"
    local current_lines = {}
    local found_heading = false

    local function flush()
        local body = Util.normalizeText(table.concat(current_lines, "\n"))
        if body ~= "" then
            table.insert(chapters, { title = current_title, content = body })
        end
        current_lines = {}
    end

    for line in (content .. "\n"):gmatch("(.-)\n") do
        local trimmed = Util.trim(line)
        if Util.looksLikeChapterTitle(trimmed) then
            found_heading = true
            flush()
            current_title = trimmed
        else
            table.insert(current_lines, line)
        end
    end
    flush()

    if not found_heading then
        return {{ title = fallback_title or "正文", content = content }}
    end
    return chapters
end

local function naturalPieces(value)
    local pieces = {}
    value = tostring(value or ""):lower()
    local index = 1
    while index <= #value do
        local first, last, number = value:find("(%d+)", index)
        if not first then
            table.insert(pieces, value:sub(index))
            break
        end
        if first > index then table.insert(pieces, value:sub(index, first - 1)) end
        table.insert(pieces, tonumber(number))
        index = last + 1
    end
    return pieces
end

function Util.naturalLess(left, right)
    local a = naturalPieces(left)
    local b = naturalPieces(right)
    local count = math.max(#a, #b)
    for index = 1, count do
        if a[index] == nil then return true end
        if b[index] == nil then return false end
        if a[index] ~= b[index] then
            if type(a[index]) == type(b[index]) then return a[index] < b[index] end
            return tostring(a[index]) < tostring(b[index])
        end
    end
    return tostring(left) < tostring(right)
end

function Util.positionCopy(position)
    return {
        chapter = tonumber(position and position.chapter) or 1,
        chapter_id = position and position.chapter_id or nil,
        paragraph = tonumber(position and position.paragraph) or 1,
        char = tonumber(position and position.char) or 1,
    }
end

function Util.positionEqual(a, b)
    if not a or not b then return false end
    return a.chapter == b.chapter and a.paragraph == b.paragraph and a.char == b.char
end

function Util.positionLess(a, b)
    if a.chapter ~= b.chapter then return a.chapter < b.chapter end
    if a.paragraph ~= b.paragraph then return a.paragraph < b.paragraph end
    return a.char < b.char
end

function Util.safeCall(callback, ...)
    local ok, result_a, result_b, result_c = pcall(callback, ...)
    if not ok then return false, tostring(result_a) end
    return true, result_a, result_b, result_c
end

return Util
