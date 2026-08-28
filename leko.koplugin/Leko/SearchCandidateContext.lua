local rapidjson = require("rapidjson")
local socket = require("socket")

local MemoryGuard = require("Leko/MemoryGuard")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

-- Search rows should stay cheap. Legado rules may attach large variables,
-- cookies or login state to a candidate; keeping dozens of those tables in
-- KOReader's UI process is unnecessary on a 256 MiB Kindle. Spill only the
-- executable context to a temporary sidecar and hydrate a short-lived copy
-- when the user actually opens/switches to that candidate.
local SearchCandidateContext = {
    low_ram_spill_threshold = 1024,
    normal_spill_threshold = 8 * 1024,
    max_context_bytes = 2 * 1024 * 1024,
    _counter = 0,
}

local CONTEXT_KEYS = {
    "variables",
    "_source_runtime",
    "_cover_source",
}

local function shallowCopy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

local function contextPayload(result)
    local payload, has_value = {}, false
    for _, key in ipairs(CONTEXT_KEYS) do
        if result[key] ~= nil then
            payload[key] = result[key]
            has_value = true
        end
    end
    return has_value and payload or nil
end

function SearchCandidateContext:_threshold()
    local low_ram = false
    if type(MemoryGuard.isLowRam) == "function" then low_ram = MemoryGuard:isLowRam() == true end
    return low_ram and self.low_ram_spill_threshold or self.normal_spill_threshold
end

function SearchCandidateContext:_newPath(result)
    self._counter = self._counter + 1
    local stamp = math.floor((tonumber(socket.gettime()) or os.time()) * 1000000)
    local identity = tostring(result and result.source_id or "") .. "\n"
        .. tostring(result and result.book_url or "") .. "\n" .. tostring(stamp) .. "\n" .. tostring(self._counter)
    local dir = Storage:getCacheDir("tmp")
    Util.mkdirp(dir)
    return Util.joinPath(dir, "candidate-context-" .. Util.hashId(identity) .. ".json")
end

function SearchCandidateContext:spill(result, force)
    if type(result) ~= "table" or result._candidate_context_path then return result end
    local payload = contextPayload(result)
    if not payload then return result end
    local ok, encoded = pcall(rapidjson.encode, payload)
    if not ok or type(encoded) ~= "string" then
        return result, "无法保存这条搜索结果"
    end
    if #encoded > self.max_context_bytes then
        result._candidate_context_oversize = #encoded
        return result, "这条搜索结果包含的数据过多"
    end
    if not force and #encoded <= self:_threshold() then return result end
    local path = self:_newPath(result)
    local wrote = Util.writeFile(path, encoded, true)
    if not wrote then return result, "无法暂存这条搜索结果" end
    for _, key in ipairs(CONTEXT_KEYS) do result[key] = nil end
    result._candidate_context_path = path
    result._candidate_context_bytes = #encoded
    return result
end

function SearchCandidateContext:spillBatch(batch)
    for _, result in ipairs(batch or {}) do self:spill(result, false) end
    return batch
end

function SearchCandidateContext:hydrate(result)
    if type(result) ~= "table" then return nil, "搜索结果不存在" end
    local copy = shallowCopy(result)
    local path = result._candidate_context_path
    if not path or path == "" then return copy end
    local raw, read_err = Util.readFile(path, true)
    if not raw then return nil, "搜索结果的临时数据已丢失：" .. tostring(read_err or path) end
    if #raw > self.max_context_bytes then return nil, "搜索结果的临时数据异常过大" end
    local ok, payload = pcall(rapidjson.decode, raw)
    if not ok or type(payload) ~= "table" then return nil, "搜索结果的临时数据损坏" end
    for _, key in ipairs(CONTEXT_KEYS) do
        if payload[key] ~= nil then copy[key] = payload[key] end
    end
    return copy
end

function SearchCandidateContext:cleanup(result)
    if type(result) ~= "table" then return end
    local path = result._candidate_context_path
    if path and path ~= "" then
        os.remove(path)
        os.remove(path .. ".tmp")
    end
    result._candidate_context_path = nil
    result._candidate_context_bytes = nil
end

function SearchCandidateContext:cleanupBatch(results)
    for _, result in ipairs(results or {}) do self:cleanup(result) end
end

return SearchCandidateContext
