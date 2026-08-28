local BookSnapshot = {}

local SOURCE_FIELDS = {
    "source_id", "source_name", "source_record", "book_url", "toc_url",
    "detail_resolved", "variables", "content_cover", "cover", "chapters", "position",
    "content_source_profiles", "updated_at", "chapter_count", "toc_ready",
    "cover_path", "manual_cover", "selected_cover_url", "cover_source_id",
    "cover_source_name", "cover_source_record", "cover_book_url", "cover_variables",
    "cover_updated_at",
}

local function clone(value, depth, seen)
    if type(value) ~= "table" then return value end
    depth = tonumber(depth or 0) or 0
    if depth > 8 then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do copy[clone(key, depth + 1, seen)] = clone(item, depth + 1, seen) end
    return copy
end

function BookSnapshot:capture(book, fields)
    local selected = fields or SOURCE_FIELDS
    local snapshot = { _fields = {} }
    for _, field in ipairs(selected) do
        snapshot._fields[#snapshot._fields + 1] = field
        snapshot[field] = clone(book[field])
    end
    snapshot._toc_dirty = book._toc_dirty
    return snapshot
end

function BookSnapshot:restore(book, snapshot)
    if not book or not snapshot then return book end
    for _, field in ipairs(snapshot._fields or SOURCE_FIELDS) do
        book[field] = clone(snapshot[field])
    end
    book._toc_dirty = snapshot._toc_dirty
    return book
end

function BookSnapshot:apply(book, candidate)
    for _, field in ipairs(SOURCE_FIELDS) do
        if candidate[field] ~= nil then book[field] = clone(candidate[field]) end
    end
    return book
end

return BookSnapshot
