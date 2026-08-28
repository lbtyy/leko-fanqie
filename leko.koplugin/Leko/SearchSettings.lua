local Storage = require("Leko/Storage")

local SearchSettings = {
    DEFAULT_LIMIT = 10,
    MIN_LIMIT = 1,
    MAX_LIMIT = 50,
    LIMIT_CHOICES = { 5, 10, 20, 50 },
}

function SearchSettings:normalizeLimit(value)
    value = math.floor(tonumber(value) or self.DEFAULT_LIMIT)
    if value < self.MIN_LIMIT then return self.MIN_LIMIT end
    if value > self.MAX_LIMIT then return self.MAX_LIMIT end
    return value
end

function SearchSettings:getLimit()
    if not Storage or type(Storage.getSettings) ~= "function" then return self.DEFAULT_LIMIT end
    local ok, value = pcall(function()
        return Storage:getSettings():readSetting("search_candidate_inspect_limit")
    end)
    return self:normalizeLimit(ok and value or nil)
end

function SearchSettings:setLimit(value)
    local limit = self:normalizeLimit(value)
    local settings = Storage:getSettings()
    settings:saveSetting("search_candidate_inspect_limit", limit)
    settings:flush()
    return limit
end

return SearchSettings
