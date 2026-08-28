-- PCRE-backed regular-expression helpers for KOReader/LuaJIT.
-- Falls back to a conservative Lua-pattern adapter in desktop tests.
local Regex = {}

local ffi_ok, ffi = pcall(require, "ffi")
local pcre
if ffi_ok then
    pcall(function()
        ffi.cdef[[
            typedef struct real_pcre pcre;
            typedef struct pcre_extra pcre_extra;
            pcre *pcre_compile(const char *pattern, int options,
                const char **errptr, int *erroffset,
                const unsigned char *tableptr);
            int pcre_exec(const pcre *code, const pcre_extra *extra,
                const char *subject, int length, int startoffset,
                int options, int *ovector, int ovecsize);
            int pcre_get_stringnumber(const pcre *code, const char *name);
            extern void (*pcre_free)(void *);
        ]]
        for _, name in ipairs({ "pcre", "libpcre.so.1", "libpcre.so" }) do
            local ok, lib = pcall(ffi.load, name)
            if ok and lib then pcre = lib break end
        end
    end)
end

local OPT = {
    i = 0x00000001, -- PCRE_CASELESS
    m = 0x00000002, -- PCRE_MULTILINE
    s = 0x00000004, -- PCRE_DOTALL
    x = 0x00000008, -- PCRE_EXTENDED
    U = 0x00000200, -- PCRE_UNGREEDY
    u = 0x00000800, -- PCRE_UTF8
}
local PCRE_UCP = 0x20000000

local function optionBits(flags)
    flags = tostring(flags or "")
    local bits = 0
    for char in flags:gmatch(".") do bits = bits + (OPT[char] or 0) end
    -- Source rules are overwhelmingly UTF-8. UCP makes \w/\b Unicode-aware.
    if not flags:find("u", 1, true) then bits = bits + OPT.u end
    return bits + PCRE_UCP
end

local function luaPattern(pattern, flags)
    pattern = tostring(pattern or "")
    -- Java/PCRE `.` does not cross CR/LF unless the `s` flag is present;
    -- Lua's `.` does.  Translate unescaped dots outside character classes so
    -- HTML cleanup rules cannot consume whole multi-line documents on the
    -- desktop/embedded fallback path.
    do
        local output, index, in_class = {}, 1, false
        while index <= #pattern do
            local char = pattern:sub(index, index)
            if char == "\\" and index < #pattern then
                output[#output + 1] = char .. pattern:sub(index + 1, index + 1)
                index = index + 2
            else
                if char == "[" then in_class = true elseif char == "]" then in_class = false end
                if char == "." and not in_class and not tostring(flags or ""):find("s", 1, true) then
                    output[#output + 1] = "[^\r\n]"
                elseif char == "-" and not in_class then
                    -- '-' is literal outside a Java/PCRE character class but
                    -- a repetition operator in Lua patterns.
                    output[#output + 1] = "%-"
                else
                    output[#output + 1] = char
                end
                index = index + 1
            end
        end
        pattern = table.concat(output)
    end
    -- Lua patterns spell the non-greedy repetition operator as `-`, while
    -- Java/PCRE rules use `*?` (and commonly `+?`).  Without this bridge a
    -- capture such as /word=(.*?)\&/ can match an empty string in the desktop
    -- runtime, which in turn erases synthetic search candidate fields.
    pattern = pattern:gsub("%*%?", "-"):gsub("%+%?", "-")
    pattern = pattern:gsub("\\s", "%%s")
    pattern = pattern:gsub("\\d", "%%d")
    pattern = pattern:gsub("\\w", "%%w")
    pattern = pattern:gsub("\\n", "\n")
    pattern = pattern:gsub("\\r", "\r")
    pattern = pattern:gsub("\\t", "\t")
    -- Java/JS regular expressions routinely escape '/' because the original
    -- syntax is /pattern/.  '/' has no special meaning in Lua patterns;
    -- leaving the backslash in place makes rules such as `\\/0\\/`
    -- silently fail whenever PCRE is unavailable on an embedded build.
    pattern = pattern:gsub("\\/", "/")
    -- Preserve the most common escaped regex punctuation in the conservative
    -- fallback.  Lua uses '%' rather than '\\' to quote its magic chars.
    local lua_magic = { ["."]=true, ["+"]=true, ["-"]=true, ["*"]=true,
        ["?"]=true, ["^"]=true, ["$"]=true, ["("]=true, [")"]=true,
        ["["]=true, ["]"]=true, ["%"]=true }
    pattern = pattern:gsub("\\(.)", function(ch)
        if lua_magic[ch] then return "%" .. ch end
        return ch
    end)
    pattern = pattern:gsub("%(%?:", "(")
    return pattern
end

local function compile(pattern, flags)
    if not pcre then return nil, "PCRE unavailable" end
    local errptr = ffi.new("const char *[1]")
    local erroffset = ffi.new("int[1]")
    local code = pcre.pcre_compile(tostring(pattern or ""), optionBits(flags), errptr, erroffset, nil)
    if code == nil then
        local message = errptr[0] ~= nil and ffi.string(errptr[0]) or "invalid regex"
        return nil, message .. " at " .. tostring(erroffset[0])
    end
    return code
end

local function release(code)
    if pcre and code ~= nil then
        pcall(function()
            if pcre.pcre_free ~= nil then pcre.pcre_free(code) end
        end)
    end
end

local function run(code, subject, start_offset)
    subject = tostring(subject or "")
    local ovec = ffi.new("int[?]", 96)
    local rc = pcre.pcre_exec(code, nil, subject, #subject, start_offset or 0, 0, ovec, 96)
    if rc < 0 then return nil end
    -- rc==0 means the vector was too small; we still have the first 32 captures.
    local count = rc == 0 and 32 or rc
    local match = { start_byte = tonumber(ovec[0]), end_byte = tonumber(ovec[1]), captures = {} }
    for i = 0, count - 1 do
        local a, b = tonumber(ovec[i * 2]), tonumber(ovec[i * 2 + 1])
        if a and b and a >= 0 and b >= a then
            match.captures[i] = subject:sub(a + 1, b)
            match.ranges = match.ranges or {}
            match.ranges[i] = { a, b }
        else
            match.captures[i] = nil
        end
    end
    return match
end

function Regex:isNative()
    return pcre ~= nil
end

function Regex:find(subject, pattern, flags, start_offset)
    subject = tostring(subject or "")
    if pcre then
        local code, err = compile(pattern, flags)
        if not code then return nil, err end
        local match = run(code, subject, start_offset or 0)
        release(code)
        return match
    end
    local lp = luaPattern(pattern, flags)
    local values = { subject:find(lp, (start_offset or 0) + 1) }
    if not values[1] then return nil end
    local match = { start_byte = values[1] - 1, end_byte = values[2], captures = {}, ranges = {} }
    match.captures[0] = subject:sub(values[1], values[2])
    match.ranges[0] = { values[1] - 1, values[2] }
    for i = 3, #values do match.captures[i - 2] = values[i] end
    return match
end

function Regex:test(subject, pattern, flags)
    return self:find(subject, pattern, flags) ~= nil
end

function Regex:captures(subject, pattern, flags)
    local match, err = self:find(subject, pattern, flags)
    if not match then return nil, err end
    return match.captures
end

local function expandReplacement(template, match)
    template = tostring(template or "")
    template = template:gsub("%$%$", "\1")
    template = template:gsub("%${(%d+)}", function(index)
        return match.captures[tonumber(index)] or ""
    end)
    template = template:gsub("%$(%d+)", function(index)
        return match.captures[tonumber(index)] or ""
    end)
    template = template:gsub("\\(%d+)", function(index)
        return match.captures[tonumber(index)] or ""
    end)
    local result = template:gsub("\1", "$")
    return result
end

function Regex:replace(subject, pattern, replacement, flags, limit)
    subject = tostring(subject or "")
    replacement = tostring(replacement or "")
    limit = tonumber(limit)
    local global = tostring(flags or ""):find("g", 1, true) ~= nil
    if not global and not limit then limit = 1 end

    if not pcre then
        local lua_repl = replacement:gsub("%$(%d+)", "%%%1")
        local ok, value
        if limit then
            ok, value = pcall(string.gsub, subject, luaPattern(pattern, flags), lua_repl, limit)
        else
            ok, value = pcall(string.gsub, subject, luaPattern(pattern, flags), lua_repl)
        end
        return ok and value or subject
    end

    local code, err = compile(pattern, flags)
    if not code then return subject, err end
    local pieces, cursor, count = {}, 0, 0
    while cursor <= #subject do
        if limit and count >= limit then break end
        local match = run(code, subject, cursor)
        if not match then break end
        table.insert(pieces, subject:sub(cursor + 1, match.start_byte))
        table.insert(pieces, expandReplacement(replacement, match))
        count = count + 1
        if match.end_byte <= cursor then
            if cursor < #subject then
                table.insert(pieces, subject:sub(cursor + 1, cursor + 1))
            end
            cursor = cursor + 1
        else
            cursor = match.end_byte
        end
        if not global and not limit then break end
    end
    table.insert(pieces, subject:sub(cursor + 1))
    release(code)
    return table.concat(pieces)
end

function Regex:findAll(subject, pattern, flags, max_results)
    subject = tostring(subject or "")
    max_results = tonumber(max_results) or 10000
    local results = {}
    if not pcre then
        local cursor = 0
        while #results < max_results do
            local m = self:find(subject, pattern, flags, cursor)
            if not m then break end
            table.insert(results, m)
            cursor = m.end_byte > cursor and m.end_byte or cursor + 1
        end
        return results
    end
    local code, err = compile(pattern, flags)
    if not code then return results, err end
    local cursor = 0
    while cursor <= #subject and #results < max_results do
        local match = run(code, subject, cursor)
        if not match then break end
        table.insert(results, match)
        cursor = match.end_byte > cursor and match.end_byte or cursor + 1
    end
    release(code)
    return results
end

return Regex
