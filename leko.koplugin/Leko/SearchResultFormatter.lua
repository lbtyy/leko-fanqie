local SearchResultFormatter = {}
local preference_ok, SourcePreference = pcall(require, "Leko/SourcePreference")

local function authorText(result, fallback)
    local author = result and result.author
    if author and tostring(author) ~= "" then return tostring(author) end
    if fallback and tostring(fallback) ~= "" then return tostring(fallback) end
    return "佚名"
end

local function utf8LeadLength(byte)
    if not byte then return 0 end
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    if byte < 0xF8 then return 4 end
    return 1
end

local function boundedSourceName(value, max_chars)
    value = tostring(value or "未命名书源")
    max_chars = math.max(4, tonumber(max_chars or 12) or 12)
    local byte_index, chars, length = 1, 0, #value
    while byte_index <= length and chars < max_chars do
        byte_index = byte_index + utf8LeadLength(value:byte(byte_index))
        chars = chars + 1
    end
    if byte_index <= length then
        return value:sub(1, byte_index - 1) .. "…"
    end
    return value
end

function SearchResultFormatter:bookItem(result, options)
    options = options or {}
    local title = tostring(result and result.title or options.fallback_title or "未命名")
    local author = authorText(result, options.fallback_author)
    local source = boundedSourceName(result and result.source_name, options.source_name_chars or 12)
    if preference_ok and SourcePreference then
        source = SourcePreference:label(result) .. " " .. source
    end

    -- The result row should answer only two user questions: which book is this,
    -- and which source found it. KOReader reserves the entire `mandatory` width
    -- before laying out the main text, so the source label is bounded to keep a
    -- positive left-text width even on 600 px Kindles. Matching heuristics and
    -- gesture instructions are implementation details and never belong here.
    return {
        text = title .. " · " .. author,
        mandatory = source,
    }
end

function SearchResultFormatter:progressText(scanned, total, count)
    return string.format("正在搜索 %d/%d · 已找到 %d 个书源",
        tonumber(scanned or 0) or 0,
        tonumber(total or 0) or 0,
        tonumber(count or 0) or 0)
end

function SearchResultFormatter:completionText(count, error_count, mode)
    local noun = mode == "content" and "内容源" or "书源"
    local summary = string.format("搜索完成 · 找到 %d 个%s", tonumber(count or 0) or 0, noun)
    local errors = tonumber(error_count or 0) or 0
    if errors > 0 then summary = summary .. " · " .. tostring(errors) .. " 个源失败" end
    return summary
end

return SearchResultFormatter
