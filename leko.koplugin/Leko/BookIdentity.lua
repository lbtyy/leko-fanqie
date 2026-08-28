local BookIdentity = {}

-- Remove presentation/edition metadata only. Semantic title continuations such
-- as 续、前传、后传、番外、第二部 are deliberately retained.
local TITLE_SUFFIXES = {
    "最新章节列表", "最新章节目录", "最新章节", "章节目录", "全文免费阅读", "全文阅读",
    "小说在线阅读", "免费在线阅读", "在线阅读", "无弹窗全文阅读", "无弹窗", "完整版",
    "全集", "完结", "精校版", "校对版", "修订版", "无错版", "精校", "校对", "修订",
    "txt全集下载", "txt下载", "电子书下载", "电子书",
}

local SITE_SUFFIXES = {
    "笔趣阁", "顶点小说", "顶点中文", "69书吧", "小说网", "小说阅读网", "书库", "阅读网",
}

local SEMANTIC_CONTINUATIONS = {
    "续", "续集", "前传", "后传", "番外", "外传", "第二部", "第2部", "二部", "2部",
    "第三部", "第3部", "三部", "3部",
}

local BRACKET_PAIRS = {
    { "（", "）" }, { "(", ")" }, { "【", "】" }, { "[", "]" },
}

local PUNCTUATION = {
    "·", "•", "，", "。", "！", "？", "；", "：", "、", "｜", "|", "—", "–", "－", "_",
    "《", "》", "〈", "〉", "「", "」", "『", "』", "【", "】", "〔", "〕", "（", "）",
    "“", "”", "‘", "’", "…", "～", "~", "﹣", "＋", "+",
}

local OPEN_WRAPPERS = { "《", "〈", "「", "『", "【", "〔", "[" }
local CLOSE_WRAPPERS = { "》", "〉", "」", "』", "】", "〕", "]" }

local function trim(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function utf8Length(value)
    value = tostring(value or "")
    local _, continuation = value:gsub("[\128-\191]", "")
    return #value - continuation
end

local function removePlain(value, needle)
    if needle == "" then return value end
    while true do
        local first, last = value:find(needle, 1, true)
        if not first then return value end
        value = value:sub(1, first - 1) .. value:sub(last + 1)
    end
end

local function lastPlain(value, needle)
    local start, found
    while true do
        local index = value:find(needle, start or 1, true)
        if not index then return found end
        found = index
        start = index + #needle
    end
end

local function stripOuterWrappers(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        for _, wrapper in ipairs(OPEN_WRAPPERS) do
            if value:sub(1, #wrapper) == wrapper then
                value = value:sub(#wrapper + 1)
                changed = true
                break
            end
        end
        value = trim(value)
        for _, wrapper in ipairs(CLOSE_WRAPPERS) do
            if #value >= #wrapper and value:sub(-#wrapper) == wrapper then
                value = value:sub(1, #value - #wrapper)
                changed = true
                break
            end
        end
    end
    return trim(value)
end

local function isPresentationSuffix(value)
    value = trim(value):lower():gsub("[%s%p%c]", "")
    for _, suffix in ipairs(TITLE_SUFFIXES) do
        local normalized = suffix:lower():gsub("[%s%p%c]", "")
        if value == normalized or value:find(normalized, 1, true) then return true end
    end
    for _, suffix in ipairs(SITE_SUFFIXES) do
        if value == suffix or value:find(suffix, 1, true) then return true end
    end
    return false
end

local function stripTrailingBrackets(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        for _, pair in ipairs(BRACKET_PAIRS) do
            local open, close = pair[1], pair[2]
            if #value >= #close and value:sub(-#close) == close then
                local open_pos = lastPlain(value, open)
                if open_pos then
                    local inside = value:sub(open_pos + #open, #value - #close)
                    if isPresentationSuffix(inside) then
                        value = value:sub(1, open_pos - 1)
                        changed = true
                        break
                    end
                end
            end
        end
    end
    return trim(value)
end

local function stripKnownSuffixes(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        local lower = value:lower()
        for _, suffix in ipairs(TITLE_SUFFIXES) do
            local needle = suffix:lower()
            if #lower >= #needle and lower:sub(-#needle) == needle then
                value = value:sub(1, #value - #suffix)
                changed = true
                break
            end
        end
    end
    return trim(value)
end

local function stripSiteSuffix(value)
    value = trim(value)
    local lower = value:lower()
    for _, suffix in ipairs(SITE_SUFFIXES) do
        local needle = suffix:lower()
        if #lower > #needle and lower:sub(-#needle) == needle then
            local prefix = trim(value:sub(1, #value - #suffix))
            -- These are unambiguous site labels. Remove an optional separator
            -- before them, but never remove semantic continuation words.
            prefix = prefix:gsub("[%s%-%_|·—–－]+$", "")
            return trim(prefix)
        end
    end
    return value
end

local function removePunctuation(value)
    value = value:gsub("[%s%p%c]", "")
    for _, token in ipairs(PUNCTUATION) do value = removePlain(value, token) end
    return value
end

local function hasSemanticContinuation(extra)
    extra = tostring(extra or "")
    for _, marker in ipairs(SEMANTIC_CONTINUATIONS) do
        if extra:sub(1, #marker) == marker then return true end
    end
    return false
end

function BookIdentity:normalizeTitle(value)
    value = trim(value):lower():gsub("　", " ")
    value = value:gsub("^%s*书名%s*[：:]?%s*", "")
    local author_pos = value:find("作者：", 1, true) or value:find("作者:", 1, true)
    if author_pos then value = value:sub(1, author_pos - 1) end
    value = stripOuterWrappers(value)
    value = stripTrailingBrackets(value)
    value = stripKnownSuffixes(value)
    value = stripSiteSuffix(value)
    value = stripOuterWrappers(value)
    return removePunctuation(value)
end

function BookIdentity:sameTitle(left, right)
    local a = self:normalizeTitle(left)
    local b = self:normalizeTitle(right)
    return a ~= "" and b ~= "" and a == b
end

function BookIdentity:normalizeAuthor(value)
    value = trim(value):lower():gsub("　", " ")
    value = value:gsub("^%s*作者%s*[：:]?%s*", "")
    value = value:gsub("^%s*author%s*[：:]?%s*", "")
    value = value:gsub("^%s*by%s+", "")
    value = value:gsub("%s*[著着]%s*$", "")
    value = value:gsub("%s*作品%s*$", "")
    return removePunctuation(value)
end

function BookIdentity:authorDiffers(left, right)
    local a = self:normalizeAuthor(left)
    local b = self:normalizeAuthor(right)
    return a ~= "" and b ~= "" and a ~= b
end

-- Ordinary search classification. Source/cover switching never uses fuzzy
-- matching: those modes require sameTitle() after normalization.
function BookIdentity:searchMatch(keyword, title, author)
    local title_query = self:normalizeTitle(keyword)
    local author_query = self:normalizeAuthor(keyword)
    local normalized_title = self:normalizeTitle(title)
    local normalized_author = self:normalizeAuthor(author)

    if title_query ~= "" and normalized_title ~= "" and normalized_title == title_query then
        return 1000, "exact-title"
    end
    if author_query ~= "" and normalized_author ~= "" then
        if normalized_author == author_query then return 920, "author" end
        if utf8Length(author_query) >= 2 and normalized_author:find(author_query, 1, true) then
            return 760, "author"
        end
    end
    if title_query ~= "" and normalized_title ~= "" then
        local query_length = utf8Length(title_query)
        -- A query long enough to look like a complete Chinese book title must
        -- match exactly after presentation suffixes are removed. This avoids
        -- accepting sequels, similarly named books, or noisy prefix matches.
        -- One- and two-character input is treated as an intentional partial
        -- search and may return clearly labelled related titles.
        if query_length <= 2 and query_length >= 1 then
            if normalized_title:find(title_query, 1, true) then
                return normalized_title:sub(1, #title_query) == title_query
                    and 700 or 620, "related-title"
            end
        end
    end
    return nil
end

function BookIdentity:searchScore(keyword, title, author)
    local score = self:searchMatch(keyword, title, author)
    return score
end

function BookIdentity:bestSearchResult(results, keyword)
    local best, best_score, best_kind, best_order
    for index, item in ipairs(type(results) == "table" and results or {}) do
        local score, kind = self:searchMatch(keyword, item and item.title, item and item.author)
        if score and (not best_score or score > best_score or score == best_score and index < best_order) then
            best, best_score, best_kind, best_order = item, score, kind, index
        end
    end
    return best, best_score, best_kind
end

function BookIdentity:bestExactTitle(results, wanted_title, wanted_author, prefer_cover)
    local best, best_score
    for _, item in ipairs(type(results) == "table" and results or {}) do
        if self:sameTitle(wanted_title, item and item.title) then
            local score = 100
            if trim(item.title) == trim(wanted_title) then score = score + 20 end
            -- Author is a tie-breaker only. A different author never rejects a
            -- same-title source, because imported sources frequently rename it.
            if not self:authorDiffers(wanted_author, item and item.author) then score = score + 8 end
            if tostring(item and item.book_url or "") ~= "" then score = score + 4 end
            if prefer_cover and tostring(item and item.cover or "") ~= "" then score = score + 3 end
            if not best_score or score > best_score then best, best_score = item, score end
        end
    end
    return best, best_score
end

return BookIdentity
