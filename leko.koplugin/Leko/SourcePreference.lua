-- User-owned source ordering.  This is deliberately separate from the
-- imported Legado source record: updating/re-importing a source must not erase
-- a reader's judgement about that source.

local Storage = require("Leko/Storage")

local SourcePreference = {
    KEY = "source_preferences_v1",
    AUTO = 0,
    PRIORITY = 1,
    LAST = -1,
}

local cache

local function clean(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function settingsObject()
    if not Storage or type(Storage.getSettings) ~= "function" then return nil end
    local settings = Storage:getSettings()
    if not settings or type(settings.readSetting) ~= "function"
        or type(settings.saveSetting) ~= "function" then
        return nil
    end
    return settings
end

local function keys(source)
    if type(source) ~= "table" then return {} end
    local result = {}
    local id = clean(source.id or source.source_id)
    local url = clean(source.source_key or source.book_source_url
        or source.bookSourceUrl or source.base_url)
    if id ~= "" then result[#result + 1] = "id:" .. id end
    if url ~= "" then result[#result + 1] = "url:" .. url:lower() end
    return result
end

local function normalize(value)
    value = tonumber(value)
    if value == SourcePreference.PRIORITY then return SourcePreference.PRIORITY end
    if value == SourcePreference.LAST then return SourcePreference.LAST end
    return SourcePreference.AUTO
end

function SourcePreference:_load()
    if cache then return cache end
    cache = {}
    local settings = settingsObject()
    if not settings then return cache end
    local saved = settings:readSetting(self.KEY)
    if type(saved) == "table" then
        for key, value in pairs(saved) do
            if type(key) == "string" and key ~= "" then
                local tier = normalize(value)
                if tier ~= self.AUTO then cache[key] = tier end
            end
        end
    end
    return cache
end

function SourcePreference:get(source)
    local saved = self:_load()
    for _, key in ipairs(keys(source)) do
        local value = saved[key]
        if value ~= nil then return normalize(value) end
    end
    return self.AUTO
end

function SourcePreference:label(source)
    local value = self:get(source)
    if value == self.PRIORITY then return string.char(0xE2, 0x86, 0x91) end
    if value == self.LAST then return string.char(0xE2, 0x86, 0x93) end
    return string.char(0xC2, 0xB7)
end

function SourcePreference:name(source)
    local value = self:get(source)
    if value == self.PRIORITY then return "Priority search" end
    if value == self.LAST then return "Last search" end
    return "Automatic order"
end

function SourcePreference:set(source, value)
    local tier = normalize(value)
    local saved = self:_load()
    for _, key in ipairs(keys(source)) do
        if tier == self.AUTO then saved[key] = nil else saved[key] = tier end
    end
    local settings = settingsObject()
    if settings then
        settings:saveSetting(self.KEY, saved)
        if type(settings.flush) == "function" then settings:flush() end
    end
    return tier
end

function SourcePreference:clear(source)
    return self:set(source, self.AUTO)
end

function SourcePreference:remove(source)
    local saved = self:_load()
    for _, key in ipairs(keys(source)) do saved[key] = nil end
    local settings = settingsObject()
    if settings then
        settings:saveSetting(self.KEY, saved)
        if type(settings.flush) == "function" then settings:flush() end
    end
    return true
end

local function tierGroup(tier)
    if tier == SourcePreference.PRIORITY then return 0 end
    if tier == SourcePreference.LAST then return 2 end
    return 1
end

function SourcePreference:sort(list)
    local output = {}
    for index, source in ipairs(list or {}) do
        output[#output + 1] = { source = source, index = index, tier = self:get(source) }
    end
    table.sort(output, function(left, right)
        local left_group, right_group = tierGroup(left.tier), tierGroup(right.tier)
        if left_group ~= right_group then return left_group < right_group end
        return left.index < right.index
    end)
    local result = {}
    for index, item in ipairs(output) do
        result[index] = item.source
        if type(item.source) == "table" then
            item.source.user_source_priority = item.tier
        end
    end
    return result
end

function SourcePreference:sortSummaries(list)
    return self:sort(list)
end

return SourcePreference
