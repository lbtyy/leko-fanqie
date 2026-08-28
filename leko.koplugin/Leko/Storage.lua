local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local Util = require("Leko/Util")
local BuiltinSources = require("Leko/BuiltinSources")
local WelcomeGuide = require("Leko/WelcomeGuide")
local Version = require("Leko/Version")
local Http = require("Leko/Http")

local Storage = {
    root_dir = Util.joinPath(DataStorage:getDataDir(), "leko"),
    -- Leko owns all of its persistent state. Keep it below the plugin data
    -- directory instead of scattering several LuaSettings files in KOReader's
    -- global settings directory.
    settings_path = nil,
    source_settings_path = nil,
    source_health_path = nil,
    source_overrides_path = nil,
    source_catalog_path = nil,
    _settings = nil,
    _source_settings = nil,
    _source_health_settings = nil,
    _source_override_settings = nil,
    _source_health_cache = nil,
    _source_health_dirty = false,
    _source_catalog_cache = nil,
    _source_catalog_map = nil,
    _runtime_source_signatures = {},
}

-- Cover files are referenced from both book.lua and the lightweight bookshelf
-- summary. Older versions could update one side and leave the other stale;
-- source switching or a restart then made a valid cover appear to disappear.
-- Keep a small explicit cover timestamp so a deliberate clear wins over an
-- older summary, while legacy records without that field still retain any
-- existing non-empty cover path.
local COVER_STATE_FIELDS = {
    "cover", "content_cover", "cover_path", "manual_cover", "selected_cover_url",
    "cover_source_id", "cover_source_name", "cover_source_record", "cover_book_url",
    "cover_variables", "cover_updated_at",
}

local BOOK_PRESENTATION_FIELDS = { "cover", "content_cover", "selected_cover_url", "intro" }
local PRESENTATION_TEXT_LIMIT = tonumber(Util.PRESENTATION_TEXT_LIMIT or 500) or 500
local COVER_DESCRIPTOR_LIMIT = tonumber(Util.COVER_DESCRIPTOR_LIMIT or (16 * 1024)) or (16 * 1024)
local READER_LAYOUT_VERSION = 2

-- A detail response can be both the book-info page and the first TOC/content
-- page.  Keep its raw bytes outside book.lua and the shelf summary.  The
-- lifetime is deliberately short: this is a hand-off between production
-- stages, not a second long-term HTTP cache.
local INLINE_RESPONSE_VERSION = 1
local INLINE_RESPONSE_TTL = 24 * 60 * 60
local INLINE_RESPONSE_MAX_BYTES = type(Http.getMaxResponseBytes) == "function"
    and Http:getMaxResponseBytes() or (8 * 1024 * 1024)

local function truncatePresentation(value)
    if type(Util.truncateUtf8) == "function" then
        return Util.truncateUtf8(value, PRESENTATION_TEXT_LIMIT)
    end
    value = tostring(value or "")
    if #value <= PRESENTATION_TEXT_LIMIT then return value end
    return value:sub(1, math.max(0, PRESENTATION_TEXT_LIMIT - 3)) .. "…"
end

local function safeCoverDescriptor(value)
    if type(Util.safeCoverDescriptor) == "function" then return Util.safeCoverDescriptor(value) end
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or #value > COVER_DESCRIPTOR_LIMIT then return nil end
    return value
end

local function sanitizeBookPresentation(book)
    if type(book) ~= "table" then return false end
    local changed = false
    local intro = truncatePresentation(book.intro)
    if book.intro ~= intro then book.intro = intro; changed = true end
    for _, field in ipairs({ "cover", "content_cover", "selected_cover_url" }) do
        local safe = safeCoverDescriptor(book[field])
        if book[field] ~= safe then book[field] = safe; changed = true end
    end
    return changed
end

local function hasCoverPath(value)
    return type(value) == "table" and tostring(value.cover_path or "") ~= ""
end

local function copyCoverState(target, source)
    local changed = false
    for _, field in ipairs(COVER_STATE_FIELDS) do
        if target[field] ~= source[field] then changed = true end
        target[field] = source[field]
    end
    return changed
end

local function sameCoverValue(left, right, seen)
    if left == right then return true end
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return false end
    seen = seen or {}
    seen[left] = seen[left] or {}
    if seen[left][right] then return true end
    seen[left][right] = true
    for key, value in pairs(left) do
        if not sameCoverValue(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function coverStateDiffers(left, right)
    for _, field in ipairs({
        "cover", "content_cover", "cover_path", "manual_cover", "selected_cover_url",
        "cover_source_id", "cover_source_name", "cover_book_url", "cover_updated_at",
    }) do
        if not sameCoverValue(left[field], right[field]) then return true end
    end
    return false
end

local function writeCoverState(path, book)
    if not path or type(book) ~= "table" then return false end
    local settings = LuaSettings:open(path)
    local data = settings.data or {}
    local changed = false
    for _, field in ipairs(COVER_STATE_FIELDS) do
        if not sameCoverValue(data[field], book[field]) then
            data[field] = book[field]
            changed = true
        end
    end
    if changed then
        settings.data = data
        settings:flush()
    end
    return changed
end

local function shouldUseCoverState(target, secondary, prefer_secondary_on_equal)
    local left_stamp = tonumber(target.cover_updated_at)
    local right_stamp = tonumber(secondary.cover_updated_at)
    if right_stamp then
        if not left_stamp or right_stamp > left_stamp then return true end
        if right_stamp == left_stamp and prefer_secondary_on_equal then return true end
        return false
    end
    if left_stamp then return false end

    -- Legacy records have no explicit cover timestamp. Never let an empty
    -- legacy side erase a non-empty path on the other side.
    if not hasCoverPath(target) and hasCoverPath(secondary) then return true end
    if hasCoverPath(target) and not hasCoverPath(secondary) then return false end
    return prefer_secondary_on_equal and (secondary.cover_path ~= nil
        or secondary.selected_cover_url ~= nil)
end

local function reconcileCoverState(target, secondary, prefer_secondary_on_equal)
    if type(target) ~= "table" or type(secondary) ~= "table" then return false end
    if not shouldUseCoverState(target, secondary, prefer_secondary_on_equal == true) then return false end
    return copyCoverState(target, secondary)
end

local SOURCE_CATALOG_VERSION = tonumber(Version.catalog_version or 5) or 5

local function stableStateSignature(value, seen)
    local kind = type(value)
    if kind ~= "table" then return kind .. ":" .. tostring(value) end
    seen = seen or {}
    if seen[value] then return "table:<cycle>" end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { "table{" }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = stableStateSignature(key, seen)
        parts[#parts + 1] = "="
        parts[#parts + 1] = stableStateSignature(value[key], seen)
        parts[#parts + 1] = ";"
    end
    parts[#parts + 1] = "}"
    seen[value] = nil
    return table.concat(parts)
end

local function sourceRuntimePayload(source)
    return {
        cookies = type(source.cookies) == "table" and source.cookies or {},
        variables = type(source.variables) == "table" and source.variables or {},
        -- Legado JS may call source.putLoginHeader() during search and consume
        -- it in ruleBookInfo/ruleToc. It is runtime state just like Cookie and
        -- source variables, so subprocess boundaries must preserve it.
        login_header = source.login_header,
    }
end

function Storage:init()
    Util.mkdirp(self.root_dir)
    self.settings_path = self.settings_path or Util.joinPath(self.root_dir, "settings.lua")
    self.source_settings_path = self.source_settings_path or Util.joinPath(self.root_dir, "sources.lua")
    self.source_health_path = self.source_health_path or Util.joinPath(self.root_dir, "source-health.lua")
    self.source_overrides_path = self.source_overrides_path or Util.joinPath(self.root_dir, "source-overrides.lua")
    if not self._settings then self._settings = LuaSettings:open(self.settings_path) end
    Util.mkdirp(self:getBooksDir())
    Util.mkdirp(self:getCoversDir())
    Util.mkdirp(self:getImportsDir())
    Util.mkdirp(self:getExportDir())
    Util.mkdirp(self:getSourcesDir())
    Util.mkdirp(self:getImportedSourcesDir())
    Util.mkdirp(self:getBuiltinSourcesDir())
    Util.mkdirp(self:getRuntimeSourcesDir())
    Util.mkdirp(self:getSourceIndexDir())
    self.source_catalog_path = self.source_catalog_path
        or Util.joinPath(self:getSourceIndexDir(), "catalog.lua")
    Util.mkdirp(self:getCacheDir())
    for _, kind in ipairs({ "http", "search", "bookinfo", "toc", "images", "tmp" }) do
        Util.mkdirp(self:getCacheDir(kind))
    end
    Util.mkdirp(self:getLogsDir())
    if not self._source_health_settings then self._source_health_settings = LuaSettings:open(self.source_health_path) end
    if not self._source_override_settings then self._source_override_settings = LuaSettings:open(self.source_overrides_path) end

    local main_dirty, override_dirty = false, false
    if not self._settings:has("library") then
        self._settings:saveSetting("library", {})
        main_dirty = true
    end

    if not self._source_health_settings:has("health") then
        self._source_health_settings:saveSetting("health", {})
        self._source_health_settings:flush()
    end
    if not self._source_override_settings:has("overrides") then
        self._source_override_settings:saveSetting("overrides", {})
        override_dirty = true
    end
    self._source_health_cache = self._source_health_settings:readSetting("health") or {}
    self._source_health_dirty = false
    if not self._settings:has("reader_style") then
        self._settings:saveSetting("reader_style", self:getDefaultReaderStyle())
        main_dirty = true
    end
    if override_dirty then self._source_override_settings:flush() end
    if main_dirty then self._settings:flush() end
    return self
end

function Storage:getSettings()
    if not self._settings then self:init() end
    return self._settings
end

function Storage:getSourceSettings()
    if not self._source_settings then
        self._source_settings = LuaSettings:open(self.source_settings_path)
        if not self._source_settings:has("sources") then
            self._source_settings:saveSetting("sources", {})
            self._source_settings:flush()
        end
    end
    return self._source_settings
end

function Storage:releaseSourceSettings()
    self._source_settings = nil
end

function Storage:getSourceHealthSettings()
    if not self._source_health_settings then
        self._source_health_settings = LuaSettings:open(self.source_health_path)
        if not self._source_health_settings:has("health") then
            self._source_health_settings:saveSetting("health", {})
            self._source_health_settings:flush()
        end
    end
    return self._source_health_settings
end

function Storage:_ensureSourceHealthCache()
    if not self._source_health_cache then
        self._source_health_cache = self:getSourceHealthSettings():readSetting("health") or {}
        self._source_health_dirty = false
    end
    return self._source_health_cache
end

function Storage:releaseSourceHealthSettings()
    -- The small health map deliberately remains resident. Releasing the LuaSettings
    -- wrapper must not discard dirty in-memory results or force an unexpected write.
    self._source_health_settings = nil
end

function Storage:listSourceHealth()
    return self:_ensureSourceHealthCache()
end

function Storage:getSourceHealth(source_id)
    if not source_id then return nil end
    return self:_ensureSourceHealthCache()[tostring(source_id)]
end

local function normalizedHealthRecord(source_id, record)
    local copy = {}
    for key, value in pairs(record or {}) do copy[key] = value end
    copy.source_id = tostring(source_id)
    copy.checked_at = tonumber(copy.checked_at or os.time()) or os.time()
    return copy
end

function Storage:setSourceHealth(source_id, record)
    if not source_id or type(record) ~= "table" then return false, "invalid source health" end
    local health = self:_ensureSourceHealthCache()
    health[tostring(source_id)] = normalizedHealthRecord(source_id, record)
    self._source_health_dirty = true
    return true
end

function Storage:setSourceHealthBatch(records)
    if type(records) ~= "table" or #records == 0 then return true end
    local health = self:_ensureSourceHealthCache()
    local changed = false
    for _, record in ipairs(records) do
        local source_id = type(record) == "table" and tostring(record.source_id or "") or ""
        if source_id ~= "" then
            health[source_id] = normalizedHealthRecord(source_id, record)
            changed = true
        end
    end
    if changed then self._source_health_dirty = true end
    return true
end

function Storage:flushSourceHealth(force)
    if not force and not self._source_health_dirty then return true end
    local settings = self:getSourceHealthSettings()
    settings:saveSetting("health", self:_ensureSourceHealthCache())
    settings:flush()
    self._source_health_dirty = false
    return true
end

function Storage:removeSourceHealth(source_id, flush_now)
    if not source_id then return end
    local health = self:_ensureSourceHealthCache()
    health[tostring(source_id)] = nil
    self._source_health_dirty = true
    if flush_now then self:flushSourceHealth() end
end

function Storage:clearSourceHealth()
    self._source_health_cache = {}
    self._source_health_dirty = true
    return self:flushSourceHealth(true)
end

function Storage:getSourceOverrideSettings()
    if not self._source_override_settings then
        self._source_override_settings = LuaSettings:open(self.source_overrides_path)
        if not self._source_override_settings:has("overrides") then
            self._source_override_settings:saveSetting("overrides", {})
            self._source_override_settings:flush()
        end
    end
    return self._source_override_settings
end

function Storage:releaseSourceOverrideSettings()
    self._source_override_settings = nil
end

function Storage:listSourceOverrides()
    return self:getSourceOverrideSettings():readSetting("overrides") or {}
end

local function shallowCopy(value)
    local out = {}
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

function Storage:applySourceOverride(source, overrides)
    if type(source) ~= "table" then return nil end
    local copy = shallowCopy(source)
    local override = (overrides or self:listSourceOverrides())[tostring(copy.id or "")]
    if type(override) == "table" then
        if override.deleted == true then return nil end
        if override.enabled ~= nil then copy.enabled = override.enabled == true end
    end
    return copy
end

function Storage:setSourceOverride(source_id, patch)
    source_id = tostring(source_id or "")
    if source_id == "" then return false, "source_id is required" end
    local settings = self:getSourceOverrideSettings()
    local overrides = settings:readSetting("overrides") or {}
    local current = shallowCopy(overrides[source_id])
    for key, value in pairs(patch or {}) do current[key] = value end
    current.updated_at = os.time()
    overrides[source_id] = current
    settings:saveSetting("overrides", overrides)
    settings:flush()
    return true
end

function Storage:getBooksDir()
    return Util.joinPath(self.root_dir, "books")
end

-- leko-plus：Native Provider 数据子树（番茄账号/限流/段评缓存等）。
-- 全部落在老用户兼容根路径之下（data/leko/providers/<域>/）。
function Storage:getProviderDataDir(domain)
    local root = Util.joinPath(self.root_dir, "providers")
    if domain and domain ~= "" then return Util.joinPath(root, tostring(domain)) end
    return root
end

function Storage:getCoversDir()
    return Util.joinPath(self.root_dir, "covers")
end

function Storage:getImportsDir()
    return Util.joinPath(self.root_dir, "imports")
end

function Storage:getExportDirectorySetting()
    local saved = self:getSettings():readSetting("export_directory")
    if type(saved) == "table" and saved.mode then return saved end
    if lfs.attributes("/mnt/us/documents", "mode") == "directory" then
        return { mode = "kindle_documents" }
    end
    return { mode = "leko_data" }
end

function Storage:setExportDirectory(mode, custom_path)
    mode = tostring(mode or "")
    if mode ~= "kindle_documents" and mode ~= "kindle_leko"
            and mode ~= "leko_data" and mode ~= "custom" then
        return false, "不支持的导出目录"
    end
    custom_path = tostring(custom_path or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if mode == "custom" then
        local absolute = custom_path:sub(1, 1) == "/" or custom_path:match("^%a:[/\\]")
        if custom_path == "" or not absolute or custom_path:find("%c") then
            return false, "自定义目录必须是绝对路径"
        end
    else
        custom_path = nil
    end
    local settings = self:getSettings()
    settings:saveSetting("export_directory", { mode = mode, path = custom_path })
    settings:flush()
    return true
end

function Storage:getExportDir()
    local saved = self:getExportDirectorySetting()
    if saved.mode == "kindle_documents" then return "/mnt/us/documents" end
    if saved.mode == "kindle_leko" then return "/mnt/us/documents/Leko" end
    if saved.mode == "custom" and tostring(saved.path or "") ~= "" then return saved.path end
    return Util.joinPath(self.root_dir, "exports")
end

function Storage:getExportDirectoryLabel()
    local saved = self:getExportDirectorySetting()
    if saved.mode == "kindle_documents" then return "Kindle documents 根目录" end
    if saved.mode == "kindle_leko" then return "documents/Leko" end
    if saved.mode == "custom" then return tostring(saved.path or "自定义目录") end
    return "Leko 数据目录"
end


function Storage:getSourcesDir()
    return Util.joinPath(self.root_dir, "sources")
end

function Storage:getImportedSourcesDir()
    return Util.joinPath(self:getSourcesDir(), "imported")
end

function Storage:getBuiltinSourcesDir()
    return Util.joinPath(self:getSourcesDir(), "builtin")
end

function Storage:getRuntimeSourcesDir()
    return Util.joinPath(self:getSourcesDir(), "runtime")
end

function Storage:getSourceIndexDir()
    return Util.joinPath(self:getSourcesDir(), "index")
end

function Storage:getSourceIndexPath(source_id)
    return Util.joinPath(self:getSourceIndexDir(), Util.hashId(tostring(source_id or "")) .. ".lua")
end

function Storage:getSourceCatalogPath()
    self.source_catalog_path = self.source_catalog_path
        or Util.joinPath(self:getSourceIndexDir(), "catalog.lua")
    return self.source_catalog_path
end

function Storage:releaseSourceCatalogCache()
    self._source_catalog_cache = nil
    self._source_catalog_map = nil
end

function Storage:invalidateSourceCatalog()
    self:releaseSourceCatalogCache()
    os.remove(self:getSourceCatalogPath())
end

local MAX_SOURCE_CATALOG_BYTES = 4 * 1024 * 1024
local MAX_SOURCE_RECORD_BYTES = 512 * 1024

local function buildSourceCatalogMap(data)
    local map = {}
    for _, summary in ipairs(type(data) == "table" and data.sources or {}) do
        local id = tostring(summary and summary.id or "")
        if id ~= "" then map[id] = summary end
    end
    return map
end

local function sourceSummary(source, offset, length)
    return {
        id = source.id,
        name = source.name,
        capability_profile = source.compatibility_label or "基础规则",
        capability_score = ({ A = 600, B = 300, C = 0, D = -100 })[source.compatibility_grade] or 0,
        enabled = source.enabled ~= false,
        supported = source.supported ~= false and source.searchable ~= false,
        searchable = source.searchable ~= false,
        has_search_url = source.search_url ~= nil and tostring(source.search_url) ~= "",
        cover_supported = source.cover_supported ~= false,
        weight = tonumber(source.weight or (source.raw and source.raw.weight) or 0) or 0,
        custom_order = tonumber(source.custom_order or (source.raw and source.raw.customOrder) or 999999) or 999999,
        record_offset = offset,
        record_length = length,
    }
end

local function sortSourceSummaries(result)
    table.sort(result, function(a, b)
        local ar = tonumber(a.capability_score or 0) or 0
        local br = tonumber(b.capability_score or 0) or 0
        if ar ~= br then return ar > br end
        local aw, bw = tonumber(a.weight or 0) or 0, tonumber(b.weight or 0) or 0
        if aw ~= bw then return aw > bw end
        local ao, bo = tonumber(a.custom_order or 999999) or 999999,
            tonumber(b.custom_order or 999999) or 999999
        if ao ~= bo then return ao < bo end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return result
end

function Storage:isSourceCatalogReady()
    local cached = self._source_catalog_cache
    if type(cached) == "table" and tonumber(cached.version or 0) == SOURCE_CATALOG_VERSION
            and type(cached.sources) == "table" and cached.records_file then
        local cached_records = Util.joinPath(self:getSourceIndexDir(), tostring(cached.records_file))
        if lfs.attributes(cached_records, "mode") == "file" then return true end
        self._source_catalog_cache = nil
        self._source_catalog_map = nil
    end
    local path = self:getSourceCatalogPath()
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (tonumber(attr.size or 0) or 0) > MAX_SOURCE_CATALOG_BYTES then
        return false
    end
    local ok, data = pcall(function() return LuaSettings:open(path).data end)
    local records_path = ok and type(data) == "table" and data.records_file
        and Util.joinPath(self:getSourceIndexDir(), tostring(data.records_file)) or nil
    local ready = ok and type(data) == "table" and tonumber(data.version or 0) == SOURCE_CATALOG_VERSION
        and type(data.sources) == "table" and records_path
        and lfs.attributes(records_path, "mode") == "file"
    if ready then
        self._source_catalog_cache = data
        self._source_catalog_map = buildSourceCatalogMap(data)
    end
    return ready and true or false
end

function Storage:rebuildSourceCatalog()
    Util.mkdirp(self:getSourceIndexDir())
    local source_settings = self:getSourceSettings()
    local sources = source_settings:readSetting("sources") or {}
    local compatibility_version = tonumber(source_settings:readSetting("source_compatibility_version") or 0) or 0
    local builtin_sources_version = tonumber(source_settings:readSetting("builtin_sources_version") or 0) or 0
    local overrides = self:listSourceOverrides()
    local summaries = {}
    local generation = Util.hashId(tostring(os.time()) .. ":" .. tostring(sources))
    local records_name = "records-" .. generation .. ".jsonl"
    local records_path = Util.joinPath(self:getSourceIndexDir(), records_name)
    local temp_path = records_path .. ".tmp"
    local records_file, open_err = io.open(temp_path, "wb")
    if not records_file then return nil, "无法创建书源记录文件：" .. tostring(open_err) end
    local written = 0
    for source_id, source in pairs(sources) do
        if type(source) == "table" then
            source.id = source.id or source_id
            local resolved = self:applySourceOverride(source, overrides)
            if resolved then
                local encoded_ok, encoded = pcall(rapidjson.encode, source)
                if encoded_ok and type(encoded) == "string" and #encoded <= MAX_SOURCE_RECORD_BYTES then
                    local offset = records_file:seek()
                    records_file:write(encoded, "\n")
                    summaries[#summaries + 1] = sourceSummary(resolved, offset, #encoded)
                    written = written + 1
                end
            end
        end
    end
    records_file:flush()
    records_file:close()
    local renamed, rename_err = os.rename(temp_path, records_path)
    if not renamed then
        os.remove(temp_path)
        return nil, "无法提交书源记录文件：" .. tostring(rename_err)
    end
    sortSourceSummaries(summaries)
    local previous
    if lfs.attributes(self:getSourceCatalogPath(), "mode") == "file" then
        local ok, data = pcall(function() return LuaSettings:open(self:getSourceCatalogPath()).data end)
        if ok and type(data) == "table" then previous = data.records_file end
    end
    local settings = LuaSettings:open(self:getSourceCatalogPath())
    settings.data = {
        version = SOURCE_CATALOG_VERSION,
        generated_at = os.time(),
        records_file = records_name,
        source_compatibility_version = compatibility_version,
        builtin_sources_version = builtin_sources_version,
        sources = summaries,
    }
    settings:flush()
    self._source_catalog_cache = settings.data
    self._source_catalog_map = buildSourceCatalogMap(settings.data)
    if previous and previous ~= records_name then
        os.remove(Util.joinPath(self:getSourceIndexDir(), tostring(previous)))
    end
    local cleaned = 0
    for name in lfs.dir(self:getSourceIndexDir()) do
        if cleaned >= 6 then break end
        local stale_tmp = name:match("^records%-.*%.jsonl%.tmp$")
        local stale_record = name:match("^records%-.*%.jsonl$") and name ~= records_name
        if stale_tmp or stale_record then
            os.remove(Util.joinPath(self:getSourceIndexDir(), name))
            cleaned = cleaned + 1
        end
    end
    self:releaseSourceSettings()
    self:releaseSourceOverrideSettings()
    return #summaries, written
end

function Storage:listSourceSummaries()
    if not self._source_catalog_cache then
        local path = self:getSourceCatalogPath()
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "file" then return nil, "书源列表尚未准备好" end
        if (tonumber(attr.size or 0) or 0) > MAX_SOURCE_CATALOG_BYTES then return nil, "书源列表数据异常过大" end
        local ok, data = pcall(function() return LuaSettings:open(path).data end)
        if not ok or type(data) ~= "table" or tonumber(data.version or 0) ~= SOURCE_CATALOG_VERSION
                or type(data.sources) ~= "table" then
            return nil, "书源列表数据损坏"
        end
        self._source_catalog_cache = data
        self._source_catalog_map = buildSourceCatalogMap(data)
    end
    local overrides = self:listSourceOverrides()
    local result = {}
    for _, summary in ipairs(self._source_catalog_cache.sources or {}) do
        local resolved = self:applySourceOverride(summary, overrides)
        if resolved then result[#result + 1] = resolved end
    end
    return sortSourceSummaries(result)
end


function Storage:getSourceSummary(source_id)
    source_id = tostring(source_id or "")
    if source_id == "" then return nil end
    if not self._source_catalog_cache or not self._source_catalog_map then
        local summaries, err = self:listSourceSummaries()
        if not summaries then return nil, err end
    end
    local summary = self._source_catalog_map and self._source_catalog_map[source_id]
    if not summary then return nil, "书源列表中找不到这条书源" end
    return self:applySourceOverride(summary, self:listSourceOverrides())
end


function Storage:getSourceCatalogRecordsPath()
    if not self._source_catalog_cache then
        local path = self:getSourceCatalogPath()
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "file" then return nil, "书源列表尚未准备好" end
        if (tonumber(attr.size or 0) or 0) > MAX_SOURCE_CATALOG_BYTES then return nil, "书源列表数据异常过大" end
        local ok, data = pcall(function() return LuaSettings:open(path).data end)
        if not ok or type(data) ~= "table" or tonumber(data.version or 0) ~= 4 then
            return nil, "书源列表数据损坏"
        end
        self._source_catalog_cache = data
        self._source_catalog_map = buildSourceCatalogMap(data)
    end
    local records_file = self._source_catalog_cache and self._source_catalog_cache.records_file
    if not records_file then return nil, "书源记录文件缺失" end
    local records_path = Util.joinPath(self:getSourceIndexDir(), tostring(records_file))
    if lfs.attributes(records_path, "mode") ~= "file" then return nil, "书源记录文件不存在" end
    return records_path
end

function Storage:readSourceRecord(records_path, offset, length, source_id, hydrate_runtime)
    if not records_path or lfs.attributes(records_path, "mode") ~= "file" then
        return nil, "书源记录文件不存在"
    end
    local record_offset = tonumber(offset or 0) or 0
    local record_length = tonumber(length or 0) or 0
    if record_offset < 0 or record_length <= 0 or record_length > MAX_SOURCE_RECORD_BYTES then
        return nil, "书源记录长度异常"
    end
    local file, open_err = io.open(records_path, "rb")
    if not file then return nil, tostring(open_err or "无法打开书源记录文件") end
    local seek_ok, seek_err = file:seek("set", record_offset)
    if not seek_ok then file:close(); return nil, tostring(seek_err or "无法定位书源记录") end
    local raw = file:read(record_length)
    file:close()
    local ok, source = pcall(rapidjson.decode, raw or "")
    if not ok or type(source) ~= "table" then return nil, "书源记录损坏" end
    source.id = source.id or source_id
    if hydrate_runtime ~= false then self:hydrateSourceRuntime(source) end
    return source
end

function Storage:saveSourceIndex(source)
    if not source or not source.id then return false end
    Util.mkdirp(self:getSourceIndexDir())
    local settings = LuaSettings:open(self:getSourceIndexPath(source.id))
    settings.data = source
    settings:flush()
    return true
end

function Storage:getSourceRuntimePath(source_id)
    return Util.joinPath(self:getRuntimeSourcesDir(), Util.hashId(tostring(source_id)) .. ".lua")
end

function Storage:getCacheDir(kind)
    local root = Util.joinPath(self.root_dir, "cache")
    if kind and kind ~= "" then return Util.joinPath(root, tostring(kind)) end
    return root
end

function Storage:getLogsDir()
    return Util.joinPath(self.root_dir, "logs")
end

function Storage:getCachePath(kind, key)
    return Util.joinPath(self:getCacheDir(kind), Util.hashId(tostring(key or "")) .. ".json")
end

function Storage:writeCache(kind, key, value)
    local ok, payload = pcall(rapidjson.encode, {
        created_at = os.time(),
        value = value,
    })
    if not ok then return false, payload end
    return Util.writeFile(self:getCachePath(kind, key), payload)
end

function Storage:readCache(kind, key, ttl_seconds)
    local raw = Util.readFile(self:getCachePath(kind, key))
    if not raw then return nil end
    local ok, payload = pcall(rapidjson.decode, raw)
    if not ok or type(payload) ~= "table" then return nil end
    local created_at = tonumber(payload.created_at or 0) or 0
    local ttl = tonumber(ttl_seconds or 0) or 0
    if ttl > 0 and os.time() - created_at > ttl then
        os.remove(self:getCachePath(kind, key))
        return nil
    end
    return payload.value, created_at
end

function Storage:clearCache(kind)
    local target = self:getCacheDir(kind)
    Util.removeTree(target)
    Util.mkdirp(target)
    if not kind then
        for _, name in ipairs({ "http", "search", "bookinfo", "toc", "images", "tmp" }) do
            Util.mkdirp(self:getCacheDir(name))
        end
    end
    return true
end

function Storage:pruneCacheKind(kind, limits)
    limits = limits or {}
    local dir = self:getCacheDir(kind)
    if lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    local now_time = os.time()
    local items, total, removed = {}, 0, 0
    -- Maintenance must yield to foreground interaction. Bound deletions per pass
    -- so a large stale cache cannot create a long flash-I/O burst.
    local max_remove = math.max(1, tonumber(limits.max_remove or 8) or 8)
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = Util.joinPath(dir, name)
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                local age = math.max(0, now_time - (tonumber(attr.modification or 0) or 0))
                if limits.max_age and age > limits.max_age and removed < max_remove then
                    os.remove(path)
                    removed = removed + 1
                else
                    local size = tonumber(attr.size or 0) or 0
                    total = total + size
                    items[#items + 1] = { path = path, size = size, modified = tonumber(attr.modification or 0) or 0 }
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.modified < b.modified end)
    local max_files = tonumber(limits.max_files or math.huge) or math.huge
    local max_bytes = tonumber(limits.max_bytes or math.huge) or math.huge
    while (#items > max_files or total > max_bytes) and removed < max_remove do
        local item = table.remove(items, 1)
        if not item then break end
        total = math.max(0, total - item.size)
        os.remove(item.path)
        removed = removed + 1
    end
    return removed
end

function Storage:pruneCaches()
    local removed = 0
    removed = removed + self:pruneCacheKind("http", { max_files = 256, max_bytes = 8 * 1024 * 1024, max_age = 2 * 24 * 60 * 60, max_remove = 4 })
    removed = removed + self:pruneCacheKind("search", { max_files = 600, max_bytes = 6 * 1024 * 1024, max_age = 24 * 60 * 60, max_remove = 4 })
    removed = removed + self:pruneCacheKind("bookinfo", { max_files = 300, max_bytes = 4 * 1024 * 1024, max_age = 3 * 24 * 60 * 60, max_remove = 4 })
    removed = removed + self:pruneCacheKind("toc", { max_files = 80, max_bytes = 20 * 1024 * 1024, max_age = 3 * 24 * 60 * 60, max_remove = 4 })
    -- Never clear the whole temporary directory while a newly opened page may
    -- already own live worker files. Only reap abandoned files older than one hour.
    removed = removed + self:pruneCacheKind("tmp", {
        max_files = 256, max_bytes = 2 * 1024 * 1024, max_age = 60 * 60, max_remove = 4,
    })
    return removed
end

local function pathSize(path)
    local attrs = lfs.attributes(path)
    if not attrs then return 0 end
    if attrs.mode == "file" then return tonumber(attrs.size or 0) or 0 end
    if attrs.mode ~= "directory" then return 0 end
    local total = 0
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            total = total + pathSize(Util.joinPath(path, entry))
        end
    end
    return total
end

local function directoryBreakdown(path)
    local result, total = {}, 0
    if lfs.attributes(path, "mode") ~= "directory" then return result, total end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local size = pathSize(Util.joinPath(path, entry))
            result[entry] = size
            total = total + size
        end
    end
    return result, total
end

function Storage:getPathSize(path)
    return pathSize(path)
end

function Storage:formatBytes(bytes)
    bytes = tonumber(bytes or 0) or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
end

function Storage:getStorageStats()
    local cache_kinds, temp_cache = directoryBreakdown(self:getCacheDir())
    local books = self:getPathSize(self:getBooksDir())
    local covers = self:getPathSize(self:getCoversDir())
    local sources = self:getPathSize(self:getSourcesDir())
    local source_stats = self:getSourceStats()
    return {
        cache = temp_cache,
        cache_search = tonumber(cache_kinds.search or 0) or 0,
        cache_bookinfo = tonumber(cache_kinds.bookinfo or 0) or 0,
        cache_toc = tonumber(cache_kinds.toc or 0) or 0,
        cache_images = tonumber(cache_kinds.images or 0) or 0,
        cache_tmp = tonumber(cache_kinds.tmp or 0) or 0,
        cache_http = tonumber(cache_kinds.http or 0) or 0,
        books = books,
        covers = covers,
        sources = sources,
        backup_count = #self:listSourceBackups(),
        source_count = source_stats.total or 0,
        source_enabled = source_stats.enabled or 0,
        source_supported = source_stats.supported or 0,
        source_unsupported = source_stats.unsupported or 0,
        total = temp_cache + books + covers + sources,
        updated_at = os.time(),
    }
end

local STORAGE_STATS_FIELDS = {
    "cache", "cache_search", "cache_bookinfo", "cache_toc", "cache_images",
    "cache_tmp", "cache_http", "books", "covers", "sources", "backup_count",
    "source_count", "source_enabled", "source_supported", "source_unsupported", "total",
}

local function normalizedStorageStats(stats)
    if type(stats) ~= "table" then return nil end
    local result = { updated_at = tonumber(stats.updated_at or os.time()) or os.time() }
    for _, field in ipairs(STORAGE_STATS_FIELDS) do
        local value = tonumber(stats[field] or 0)
        if not value or value < 0 then return nil end
        result[field] = math.floor(value)
    end
    return result
end

function Storage:getCachedStorageStats()
    if self._storage_stats_cache then return self._storage_stats_cache end
    local cached = normalizedStorageStats(self:getSettings():readSetting("storage_stats_cache"))
    self._storage_stats_cache = cached
    return cached
end

function Storage:saveCachedStorageStats(stats)
    local normalized = normalizedStorageStats(stats)
    if not normalized then return false, "invalid storage stats" end
    local previous = self:getCachedStorageStats()
    local changed = not previous
    if not changed then
        for _, field in ipairs(STORAGE_STATS_FIELDS) do
            if previous[field] ~= normalized[field] then changed = true; break end
        end
    end
    self._storage_stats_cache = normalized
    if changed then
        local settings = self:getSettings()
        settings:saveSetting("storage_stats_cache", normalized)
        settings:flush()
    end
    return true
end

function Storage:clearCachedStorageStats()
    self._storage_stats_cache = nil
    local settings = self:getSettings()
    settings:delSetting("storage_stats_cache")
    settings:flush()
end

function Storage:backupImportedSources(raw, original_name)
    if not raw or raw == "" then return nil, "empty source data" end
    local stem = Util.splitext(Util.basename(original_name or "sources.json"))
    stem = Util.slug(stem)
    local filename = string.format("%s-%s.json", stem, os.date("%Y%m%d-%H%M%S"))
    local path = Util.joinPath(self:getImportedSourcesDir(), filename)
    local ok, err = Util.writeFile(path, raw)
    if not ok then return nil, err end
    return path
end

function Storage:listSourceBackups()
    local directory = self:getImportedSourcesDir()
    local result = {}
    if lfs.attributes(directory, "mode") ~= "directory" then return result end
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." and name:lower():match("%.json$") then
            local path = Util.joinPath(directory, name)
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                result[#result + 1] = {
                    name = name,
                    path = path,
                    size = tonumber(attr.size or 0) or 0,
                    modified = tonumber(attr.modification or 0) or 0,
                }
            end
        end
    end
    table.sort(result, function(left, right)
        if left.modified ~= right.modified then return left.modified > right.modified end
        return tostring(left.name) > tostring(right.name)
    end)
    return result
end

function Storage:getBookDir(book_id)
    return Util.joinPath(self:getBooksDir(), tostring(book_id))
end

function Storage:getBookSettingsPath(book_id)
    return Util.joinPath(self:getBookDir(book_id), "book.lua")
end

function Storage:getInlineResponseBodyPath(book_id)
    return Util.joinPath(self:getBookDir(book_id), "detail-response.body")
end

function Storage:getInlineResponseMetaPath(book_id)
    return Util.joinPath(self:getBookDir(book_id), "detail-response.lua")
end

local function inlineResponseIdentityMatches(meta, book)
    if type(meta) ~= "table" or type(book) ~= "table" then return false end
    if tonumber(meta.version or 0) ~= INLINE_RESPONSE_VERSION then return false end
    if tostring(meta.source_id or "") ~= tostring(book.source_id or "") then return false end
    if tostring(meta.book_url or "") ~= tostring(book.book_url or "") then return false end
    if tostring(meta.response_url or "") == "" or tostring(meta.request_base_url or "") == "" then return false end
    local stored_at = tonumber(meta.stored_at or 0) or 0
    if stored_at <= 0 or os.time() - stored_at > INLINE_RESPONSE_TTL then return false end
    local body_bytes = tonumber(meta.body_bytes or -1) or -1
    return body_bytes > 0 and body_bytes <= INLINE_RESPONSE_MAX_BYTES
end

-- Store only response metadata in LuaSettings and the exact accepted response
-- bytes in a binary sidecar.  This avoids both LuaSettings escaping/encoding
-- changes and accidental propagation into book.lua or the bookshelf summary.
function Storage:saveInlineBookResponse(book, payload)
    if type(book) ~= "table" or not book.id then return false, "book.id is required" end
    payload = payload or {}
    local body = payload.body
    if type(body) ~= "string" or body == "" then return false, "inline response body is empty" end
    if #body > INLINE_RESPONSE_MAX_BYTES then return false, "inline response exceeds HTTP response limit" end
    local source_id = tostring(payload.source_id or book.source_id or "")
    local book_url = tostring(payload.book_url or book.book_url or "")
    local response_url = tostring(payload.response_url or "")
    local request_base_url = tostring(payload.request_base_url or "")
    if source_id == "" or book_url == "" or response_url == "" or request_base_url == "" then
        return false, "inline response identity is incomplete"
    end
    local body_path = self:getInlineResponseBodyPath(book.id)
    local meta_path = self:getInlineResponseMetaPath(book.id)
    local ok, err = Util.writeFile(body_path, body, true)
    if not ok then return false, err end
    local settings = LuaSettings:open(meta_path)
    settings.data = {
        version = INLINE_RESPONSE_VERSION,
        source_id = source_id,
        book_url = book_url,
        response_url = response_url,
        request_base_url = request_base_url,
        content_type = tostring(payload.content_type or "text/html"),
        code = tonumber(payload.code or 200) or 200,
        status = tonumber(payload.status or payload.code or 200) or 200,
        body_bytes = #body,
        stored_at = os.time(),
    }
    local flushed, flush_err = pcall(settings.flush, settings)
    if not flushed then
        os.remove(body_path)
        return false, tostring(flush_err)
    end
    return true
end

function Storage:loadInlineBookResponse(book)
    if type(book) ~= "table" or not book.id then return nil end
    local meta_path = self:getInlineResponseMetaPath(book.id)
    local body_path = self:getInlineResponseBodyPath(book.id)
    if lfs.attributes(meta_path, "mode") ~= "file" or lfs.attributes(body_path, "mode") ~= "file" then
        return nil
    end
    local ok, meta = pcall(function() return LuaSettings:open(meta_path).data end)
    if not ok or not inlineResponseIdentityMatches(meta, book) then
        os.remove(meta_path)
        os.remove(body_path)
        return nil
    end
    local attr = lfs.attributes(body_path)
    if not attr or attr.mode ~= "file" or (tonumber(attr.size or -1) or -1) ~= tonumber(meta.body_bytes) then
        os.remove(meta_path)
        os.remove(body_path)
        return nil
    end
    local body = Util.readFile(body_path, true)
    if type(body) ~= "string" or #body ~= tonumber(meta.body_bytes) or #body > INLINE_RESPONSE_MAX_BYTES then
        os.remove(meta_path)
        os.remove(body_path)
        return nil
    end
    return {
        body = body,
        response_url = tostring(meta.response_url),
        request_base_url = tostring(meta.request_base_url),
        content_type = tostring(meta.content_type or "text/html"),
        code = tonumber(meta.code or 200) or 200,
        status = tonumber(meta.status or meta.code or 200) or 200,
        body_bytes = #body,
    }
end

function Storage:clearInlineBookResponse(book_id)
    if not book_id then return true end
    os.remove(self:getInlineResponseMetaPath(book_id))
    os.remove(self:getInlineResponseBodyPath(book_id))
    return true
end

function Storage:getBookProgressPath(book_id)
    return Util.joinPath(self:getBookDir(book_id), "progress.lua")
end

function Storage:getBookTocPath(book_id)
    return Util.joinPath(self:getBookDir(book_id), "toc.lua")
end

function Storage:getBookProfileTocDir(book_id)
    return Util.joinPath(self:getBookDir(book_id), "source-tocs")
end

function Storage:getBookProfileTocPath(book_id, profile_key)
    return Util.joinPath(self:getBookProfileTocDir(book_id), Util.hashId(tostring(profile_key or "")) .. ".lua")
end

function Storage:getChapterDir(book_id)
    return Util.joinPath(self:getBookDir(book_id), "chapters")
end

function Storage:getChapterPath(book_id, chapter_index, chapter_id)
    local filename
    if chapter_id ~= nil and tostring(chapter_id) ~= "" then
        filename = Util.hashId(tostring(chapter_id)) .. ".txt"
    else
        filename = string.format("%06d.txt", chapter_index)
    end
    return Util.joinPath(self:getChapterDir(book_id), filename)
end

function Storage:getDefaultReaderStyle()
    return {
        body_font = "cfont",
        body_font_index = nil,
        body_font_display_name = "系统默认（简体中文优先）",
        body_font_size = 27,
        title_font = "cfont",
        title_font_index = nil,
        title_font_display_name = "系统默认（简体中文优先）",
        title_font_size = 34,
        title_bold = true,
        -- These values are legacy-compatible style fields. Paginator derives
        -- the final opening gaps from screen height, while the version marker
        -- lets existing installations leave the old 44/54 opening behind.
        title_margin_top = 66,
        title_margin_bottom = 150,
        layout_version = READER_LAYOUT_VERSION,
        margin_left = 28,
        margin_right = 28,
        -- Legacy fields retained for settings compatibility. Paginator owns
        -- the vertical chrome gaps; only margin_left/margin_right are used as
        -- user-facing reading margins.
        margin_top = 14,
        margin_bottom = 12,
        line_spacing = 0.28,
        paragraph_spacing = 10,
        indent = true,
        show_header = true,
        show_footer = true,
        chapter_new_page = true,
        -- The visual page transition is optional. ReaderView does not add a
        -- separate full-surface clearing pass after a page transition.
        page_transition_enabled = true,
        -- Cross-chapter cleanup is deliberately opt-in: it uses several
        -- scoped UI submissions and is slower than the ordinary page swipe.
        -- Keep the key name for compatibility with existing .44 settings.
        chapter_clean_wave_enabled = false,
    }
end

function Storage:getReaderStyle()
    local saved = self:getSettings():readSetting("reader_style") or {}
    local style = self:getDefaultReaderStyle()
    for key, value in pairs(saved) do style[key] = value end
    -- 0.15.19 persisted the old fixed 44/54 chapter-opening gaps. Migrate
    -- only those title fields; never touch the user's font, horizontal
    -- reading margins, line spacing or indentation preference.
    if (tonumber(saved.layout_version or 0) or 0) < READER_LAYOUT_VERSION then
        style.title_margin_top = self:getDefaultReaderStyle().title_margin_top
        style.title_margin_bottom = self:getDefaultReaderStyle().title_margin_bottom
        style.layout_version = READER_LAYOUT_VERSION
        self:getSettings():saveSetting("reader_style", style)
        self:getSettings():flush()
    end
    return style
end

function Storage:saveReaderStyle(style)
    self:getSettings():saveSetting("reader_style", style)
    self:getSettings():flush()
end

function Storage:saveBookProgress(book)
    if not book or not book.id then return false, "book.id is required" end
    Util.mkdirp(self:getBookDir(book.id))
    local progress_settings = LuaSettings:open(self:getBookProgressPath(book.id))
    local position = Util.positionCopy(book.position)
    progress_settings.data = {
        -- Keep the nested shape used by 0.15.39, while mirroring the cursor
        -- fields at the top level for recovery from early progress files.
        format_version = 2,
        position = position,
        chapter = position.chapter,
        chapter_id = position.chapter_id,
        paragraph = position.paragraph,
        char = position.char,
        last_read_at = tonumber(book.last_read_at or os.time()) or os.time(),
    }
    progress_settings:flush()
    return true
end

function Storage:loadBookProgress(book_id)
    local path = self:getBookProgressPath(book_id)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local settings = LuaSettings:open(path)
    local data = settings.data
    if type(data) ~= "table" then return nil end
    local raw_position = data.position
    if type(raw_position) ~= "table" then raw_position = data end
    if type(raw_position) ~= "table"
            or (raw_position.chapter == nil and raw_position.chapter_index == nil
                and raw_position.paragraph == nil and raw_position.paragraph_index == nil
                and raw_position.char == nil and raw_position.char_index == nil) then
        return nil
    end
    local position = {
        chapter = raw_position.chapter or raw_position.chapter_index,
        chapter_id = raw_position.chapter_id or raw_position.chapterId,
        paragraph = raw_position.paragraph or raw_position.paragraph_index,
        char = raw_position.char or raw_position.char_index,
    }
    return {
        position = Util.positionCopy(position),
        last_read_at = tonumber(data.last_read_at or 0) or 0,
    }
end

function Storage:saveBookToc(book)
    if not book or not book.id then return false, "book.id is required" end
    Util.mkdirp(self:getBookDir(book.id))
    local chapters = book.chapters or {}
    local settings = LuaSettings:open(self:getBookTocPath(book.id))
    settings.data = { chapters = chapters, updated_at = os.time() }
    settings:flush()
    book.chapter_count = #chapters
    book.toc_ready = #chapters > 0
    book._toc_dirty = false
    return true
end

function Storage:loadBookToc(book_id)
    local path = self:getBookTocPath(book_id)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local data = LuaSettings:open(path).data or {}
    return type(data.chapters) == "table" and data.chapters or nil
end

function Storage:saveBookProfileToc(book_id, profile_key, chapters)
    if not book_id or not profile_key or type(chapters) ~= "table" then return false end
    Util.mkdirp(self:getBookProfileTocDir(book_id))
    local settings = LuaSettings:open(self:getBookProfileTocPath(book_id, profile_key))
    settings.data = { chapters = chapters, updated_at = os.time() }
    settings:flush()
    return true
end

function Storage:loadBookProfileToc(book_id, profile_key)
    local path = self:getBookProfileTocPath(book_id, profile_key)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local data = LuaSettings:open(path).data or {}
    return type(data.chapters) == "table" and data.chapters or nil
end

function Storage:listBooks()
    local settings = self:getSettings()
    local library = settings:readSetting("library") or {}
    local books = {}
    local repaired_summary = false
    for _, summary in pairs(library) do
        local item = {}
        for key, value in pairs(summary) do item[key] = value end
        local metadata_path = item.id and self:getBookSettingsPath(item.id) or nil
        if metadata_path and lfs.attributes(metadata_path, "mode") == "file" then
            local metadata = LuaSettings:open(metadata_path).data or {}
            if reconcileCoverState(item, metadata, true) then
                for _, field in ipairs(COVER_STATE_FIELDS) do summary[field] = item[field] end
                repaired_summary = true
            elseif coverStateDiffers(summary, metadata) then
                -- The shelf summary is newer (most commonly a deliberate
                -- clear). Keep the book metadata from resurrecting that old
                -- cover on the next restart.
                writeCoverState(metadata_path, item)
            end
        end
        local progress = item.id and self:loadBookProgress(item.id) or nil
        if progress then
            item.position = progress.position
            item.last_read_at = progress.last_read_at
        end
        if sanitizeBookPresentation(item) then
            for _, field in ipairs(BOOK_PRESENTATION_FIELDS) do summary[field] = item[field] end
            repaired_summary = true
        end
        table.insert(books, item)
    end
    if repaired_summary then
        settings:saveSetting("library", library)
        settings:flush()
    end
    table.sort(books, function(a, b)
        local a_time = tonumber(a.last_read_at or a.updated_at or 0)
        local b_time = tonumber(b.last_read_at or b.updated_at or 0)
        if a_time == b_time then return tostring(a.title) < tostring(b.title) end
        return a_time > b_time
    end)
    return books
end

function Storage:getBookSummary(book_id)
    local library = self:getSettings():readSetting("library") or {}
    local summary = library[book_id]
    if summary then sanitizeBookPresentation(summary) end
    return summary
end

function Storage:makeBookSummary(book)
    local intro = truncatePresentation(book.intro)
    return {
        id = book.id,
        title = book.title or "未命名",
        author = book.author or "",
        source_id = book.source_id,
        source_name = book.source_name,
        -- leko-plus：番茄书标识透传（普通书为 nil，语义不变）
        provider = book.provider,
        provider_book_id = book.provider_book_id,
        provider_source = book.provider_source,
        cover = safeCoverDescriptor(book.cover),
        content_cover = safeCoverDescriptor(book.content_cover),
        cover_path = book.cover_path,
        manual_cover = book.manual_cover,
        selected_cover_url = safeCoverDescriptor(book.selected_cover_url),
        cover_source_id = book.cover_source_id,
        cover_source_name = book.cover_source_name,
        cover_source_record = book.cover_source_record,
        cover_book_url = book.cover_book_url,
        cover_variables = book.cover_variables,
        cover_updated_at = book.cover_updated_at,
        intro = intro,
        chapter_count = tonumber(book.chapter_count) or #(book.chapters or {}),
        position = Util.positionCopy(book.position),
        updated_at = book.updated_at or os.time(),
        last_read_at = book.last_read_at or 0,
        toc_checked_at = tonumber(book.toc_checked_at or 0) or 0,
        toc_check_attempted_at = tonumber(book.toc_check_attempted_at or 0) or 0,
        toc_update_count = tonumber(book.toc_update_count or 0) or 0,
        toc_update_latest_title = book.toc_update_latest_title,
        toc_check_status = book.toc_check_status,
        toc_check_error = book.toc_check_error,
    }
end

function Storage:saveBookSummary(book)
    local settings = self:getSettings()
    local library = settings:readSetting("library") or {}
    library[book.id] = self:makeBookSummary(book)
    settings:saveSetting("library", library)
    settings:flush()
end

function Storage:isInLibrary(book_id)
    return self:getBookSummary(book_id) ~= nil
end

function Storage:addBookToLibrary(book)
    if not book or not book.id then return nil, "invalid book" end
    book.in_library = true
    book.not_shelf = false
    book.added_at = book.added_at or os.time()
    book.updated_at = os.time()
    self:saveBook(book, { force_summary = true })
    return book
end

function Storage:removeBookFromLibrary(book_id, keep_files)
    local settings = self:getSettings()
    local library = settings:readSetting("library") or {}
    library[book_id] = nil
    settings:saveSetting("library", library)
    settings:flush()
    if keep_files then
        local book = self:loadBook(book_id)
        if book then
            book.in_library = false
            book.not_shelf = true
            self:saveBook(book)
        end
        return true
    end
    return self:deleteBook(book_id)
end

function Storage:saveBook(book, options)
    assert(type(book) == "table" and book.id, "book.id is required")
    options = options or {}
    local existing_summary = self:getBookSummary(book.id)
    if existing_summary then
        -- Preserve a cover that only exists in the summary while an older
        -- book.lua is being rewritten by a source/content operation.
        reconcileCoverState(book, existing_summary, false)
    end
    sanitizeBookPresentation(book)
    Util.mkdirp(self:getBookDir(book.id))
    Util.mkdirp(self:getChapterDir(book.id))

    local toc_path = self:getBookTocPath(book.id)
    if options.save_toc ~= false and (options.force_toc or book._toc_dirty == true or lfs.attributes(toc_path, "mode") ~= "file") then
        self:saveBookToc(book)
    end

    -- Keep book.lua lightweight. Large chapter arrays live in toc.lua; cached
    -- source profiles keep only a small toc_ref and use source-tocs/ when needed.
    local payload = {}
    for key, value in pairs(book) do
        -- Response bodies are stage hand-off data, never book metadata.  The
        -- dedicated binary sidecar above is the only persistent home for
        -- detail/toc HTML and its response identity.
        if key ~= "chapters" and key ~= "_toc_dirty" and key ~= "_transient_trial"
                and key ~= "toc_html" and key ~= "info_html"
                and key ~= "_detail_response_url" and key ~= "_detail_request_base_url"
                and key ~= "_detail_base_url" and key ~= "_detail_content_type"
                and key ~= "_detail_code" and key ~= "_detail_status"
                and key ~= "_toc_html_response_url" and key ~= "_toc_html_request_base_url"
                and key ~= "_toc_html_content_type" then
            payload[key] = value
        end
    end
    local chapter_count = #(book.chapters or {})
    if chapter_count > 0 then
        payload.chapter_count = chapter_count
        payload.toc_ready = true
    else
        payload.chapter_count = tonumber(payload.chapter_count or 0) or 0
    end
    if type(payload.content_source_profiles) == "table" then
        local profiles = {}
        for profile_key, profile in pairs(payload.content_source_profiles) do
            if type(profile) == "table" then
                local compact = {}
                for key, value in pairs(profile) do
                    if key ~= "chapters" then compact[key] = value end
                end
                compact.toc_ref = compact.toc_ref or tostring(profile_key)
                profiles[profile_key] = compact
                if options.save_toc ~= false and type(profile.chapters) == "table" then
                    self:saveBookProfileToc(book.id, profile_key, profile.chapters)
                    profile.chapters = nil
                    profile.toc_ref = compact.toc_ref
                end
            end
        end
        payload.content_source_profiles = profiles
    end

    local book_settings = LuaSettings:open(self:getBookSettingsPath(book.id))
    book_settings.data = payload
    book_settings:flush()
    if options.save_progress ~= false then self:saveBookProgress(book) end
    if not options.skip_summary and (options.force_summary or (book.in_library ~= false and book.not_shelf ~= true)) then
        book.in_library = true
        book.not_shelf = false
        self:saveBookSummary(book)
    end
    return true
end

function Storage:loadBook(book_id, options)
    options = options or {}
    local path = self:getBookSettingsPath(book_id)
    if lfs.attributes(path, "mode") ~= "file" then return nil, "book metadata not found" end
    local settings = LuaSettings:open(path)
    local book = settings.data or {}
    if not book.id then return nil, "invalid book metadata" end
    local summary = self:getBookSummary(book_id)
    if summary then
        local metadata_before = {}
        for _, field in ipairs(COVER_STATE_FIELDS) do metadata_before[field] = book[field] end
        reconcileCoverState(book, summary, false)
        local summary_is_authoritative = coverStateDiffers(metadata_before, book)
        if summary_is_authoritative then
            -- The summary was newer. Repair book.lua so future content/source
            -- saves cannot reintroduce the stale cover state.
            writeCoverState(path, book)
        elseif coverStateDiffers(summary, book) then
            -- book.lua was newer. Repair the shelf row before any UI rebuild.
            pcall(self.saveBookSummary, self, book)
        end
    end
    if options.load_toc == false then
        -- Detail/list pages need only lightweight metadata. Avoid materialising a
        -- multi-thousand-chapter TOC in the KOReader UI process until the user
        -- explicitly opens the TOC or starts reading.
        book.chapters = {}
        book.chapter_count = tonumber(book.chapter_count or 0) or 0
    else
        book.chapters = self:loadBookToc(book_id) or {}
        book.chapter_count = #book.chapters
        book.toc_ready = #book.chapters > 0
    end
    local progress = self:loadBookProgress(book_id)
    if progress then
        book.position = progress.position
        book.last_read_at = progress.last_read_at
    else
        book.position = Util.positionCopy(book.position)
    end
    sanitizeBookPresentation(book)
    return book
end

function Storage:deleteBook(book_id)
    local book = self:loadBook(book_id)
    self:clearInlineBookResponse(book_id)
    local settings = self:getSettings()
    local library = settings:readSetting("library") or {}
    library[book_id] = nil
    settings:saveSetting("library", library)
    settings:flush()
    if book and book.cover_path then os.remove(book.cover_path) end
    return Util.removeTree(self:getBookDir(book_id))
end

function Storage:getCoverPath(book_id, extension)
    extension = tostring(extension or "jpg"):lower():gsub("[^%w]", "")
    if extension == "jpeg" then extension = "jpg" end
    if extension == "" then extension = "jpg" end
    return Util.joinPath(self:getCoversDir(), tostring(book_id) .. "." .. extension)
end

function Storage:cleanupTrials(max_age)
    max_age = tonumber(max_age) or (7 * 24 * 60 * 60)
    local now = os.time()
    local library = self:getSettings():readSetting("library") or {}
    local root = self:getBooksDir()
    if lfs.attributes(root, "mode") ~= "directory" then return 0 end
    local removed = 0
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." and not library[entry] then
            local book = self:loadBook(entry)
            if book and (book.not_shelf == true or book.in_library == false) then
                local created = tonumber(book.trial_created_at or book.updated_at or book.created_at or 0) or 0
                if created > 0 and now - created > max_age then
                    self:deleteBook(entry)
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

function Storage:saveChapter(book, chapter_index, content, options)
    options = options or {}
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return false, "chapter not found" end
    local path = self:getChapterPath(book.id, chapter_index, chapter.id)
    local previous_content = Util.readFile(path, true)
    local ok, err = Util.writeFile(path, Util.normalizeText(content))
    if not ok then
        -- Keep a usable old chapter if a replacement write fails midway.
        if previous_content ~= nil then pcall(Util.writeFile, path, previous_content, true) end
        return false, err
    end
    chapter.path = path
    chapter.downloaded = true
    chapter.updated_at = os.time()
    book.updated_at = os.time()
    -- The deterministic chapter file is the source of truth for download state.
    -- Do not rewrite book.lua/toc.lua after every chapter download.
    if options.persist_metadata == true then
        self:saveBook(book, { skip_summary = true, save_progress = false, save_toc = false })
    end
    return true, path
end

function Storage:loadChapter(book, chapter_index)
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "chapter not found" end
    local path = chapter.path or self:getChapterPath(book.id, chapter_index, chapter.id)
    local content, err = Util.readFile(path)
    if not content then return nil, err end
    return Util.normalizeText(content)
end

function Storage:listSources()
    local sources = self:getSourceSettings():readSetting("sources") or {}
    local overrides = self:listSourceOverrides()
    local result = {}
    for _, source in pairs(sources) do
        local resolved = self:applySourceOverride(source, overrides)
        if resolved then table.insert(result, resolved) end
    end
    table.sort(result, function(a, b)
        local ar = tonumber(a.capability_score or 0) or 0
        local br = tonumber(b.capability_score or 0) or 0
        if ar ~= br then return ar > br end
        local aw, bw = tonumber(a.weight or (a.raw and a.raw.weight) or 0) or 0, tonumber(b.weight or (b.raw and b.raw.weight) or 0) or 0
        if aw ~= bw then return aw > bw end
        local ao, bo = tonumber(a.custom_order or (a.raw and a.raw.customOrder) or 999999) or 999999, tonumber(b.custom_order or (b.raw and b.raw.customOrder) or 999999) or 999999
        if ao ~= bo then return ao < bo end
        return tostring(a.name) < tostring(b.name)
    end)
    return result
end

function Storage:getSourceCount()
    if not self:isSourceCatalogReady() then return 0 end
    local overrides = self:listSourceOverrides()
    local count = 0
    for _, source in ipairs(self._source_catalog_cache.sources or {}) do
        local override = overrides[tostring(source.id or "")]
        if type(override) ~= "table" or override.deleted ~= true then count = count + 1 end
    end
    return count
end

function Storage:getSourceStats()
    local stats = { total = 0, enabled = 0, supported = 0, unsupported = 0, capabilities = {} }
    if not self:isSourceCatalogReady() then return stats end
    local overrides = self:listSourceOverrides()
    for _, source in ipairs(self._source_catalog_cache.sources or {}) do
        local override = overrides[tostring(source.id or "")]
        if type(override) ~= "table" or override.deleted ~= true then
            stats.total = stats.total + 1
            local enabled = type(override) == "table" and override.enabled or nil
            if enabled == nil then enabled = source.enabled ~= false end
            if enabled == true then stats.enabled = stats.enabled + 1 end
            if source.searchable ~= false and source.supported ~= false then
                stats.supported = stats.supported + 1
            else
                stats.unsupported = stats.unsupported + 1
            end
            local capability = source.capability_profile or "基础规则"
            stats.capabilities[capability] = (stats.capabilities[capability] or 0) + 1
        end
    end
    return stats
end

local function restoreRuntimeRulesFromBackups(storage, sources, LegadoSource)
    local directory = storage:getImportedSourcesDir()
    if lfs.attributes(directory, "mode") ~= "directory" then return 0 end
    local files = {}
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." and name:lower():match("%.json$") then
            local path = Util.joinPath(directory, name)
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then files[#files + 1] = { path = path, modified = tonumber(attr.modification or 0) or 0, size = tonumber(attr.size or 0) or 0 } end
        end
    end
    table.sort(files, function(a, b) return a.modified > b.modified end)
    local restored, inspected_bytes = 0, 0
    for index = 1, math.min(#files, 6) do
        local file = files[index]
        if file.size <= 12 * 1024 * 1024 and inspected_bytes + file.size <= 24 * 1024 * 1024 then
            inspected_bytes = inspected_bytes + file.size
            local raw = Util.readFile(file.path)
            local ok, decoded = pcall(rapidjson.decode, tostring(raw or ""):gsub("^\239\187\191", ""))
            if ok and type(decoded) == "table" then
                if decoded.bookSourceName or decoded.searchUrl then decoded = { decoded } end
                for _, item in ipairs(decoded) do
                    if type(item) == "table" then
                        local normalized = LegadoSource:normalize(item)
                        local previous = normalized and sources[normalized.id]
                        if type(previous) == "table" then
                            normalized.enabled = previous.enabled ~= false
                            normalized.cookies = previous.cookies or normalized.cookies
                            normalized.variables = previous.variables or normalized.variables
                            normalized.login_header = previous.login_header
                            normalized.login_info = previous.login_info
                            sources[normalized.id] = normalized
                            restored = restored + 1
                        end
                    end
                end
            end
        end
    end
    return restored
end

function Storage:refreshSourceCompatibility(force)
    local LegadoSource = require("Leko/LegadoSource")
    if not force and self:isSourceCatalogReady() then
        local catalog = self._source_catalog_cache
        if not catalog then
            local ok, data = pcall(function() return LuaSettings:open(self:getSourceCatalogPath()).data end)
            if ok and type(data) == "table" then catalog = data end
        end
        if tonumber(catalog and catalog.source_compatibility_version or 0) >= (Version.compatibility_version or 6) then return 0 end
    end
    local settings = self:getSourceSettings()
    local version = tonumber(settings:readSetting("source_compatibility_version") or 0) or 0
    if not force and version >= (Version.compatibility_version or 6) then return 0 end
    local sources = settings:readSetting("sources") or {}
    local changed = restoreRuntimeRulesFromBackups(self, sources, LegadoSource)
    for source_id, source in pairs(sources) do
        if type(source) == "table" then
            source.id = source.id or source_id
            source.enabled = source.enabled ~= false
            sources[source_id] = LegadoSource:refreshCompatibility(source)
            changed = changed + 1
        end
    end
    settings:saveSetting("sources", sources)
    settings:saveSetting("source_compatibility_version", Version.compatibility_version or 6)
    settings:flush()
    self:invalidateSourceCatalog()
    return changed
end

function Storage:hydrateSourceRuntime(source)
    if not source or not source.id then return source end
    local path = self:getSourceRuntimePath(source.id)
    if lfs.attributes(path, "mode") ~= "file" then return source end
    local runtime = LuaSettings:open(path).data or {}
    if type(runtime.cookies) == "table" then source.cookies = runtime.cookies end
    if type(runtime.variables) == "table" then source.variables = runtime.variables end
    if runtime.login_header ~= nil then source.login_header = runtime.login_header end
    local payload = sourceRuntimePayload(source)
    self._runtime_source_signatures[tostring(source.id)] = stableStateSignature(payload)
    return source
end

function Storage:saveSourceRuntime(source)
    if not source or not source.id then return false, "source.id is required" end
    local source_id = tostring(source.id)
    local payload = sourceRuntimePayload(source)
    local signature = stableStateSignature(payload)
    if self._runtime_source_signatures[source_id] == signature then return true end
    Util.mkdirp(self:getRuntimeSourcesDir())
    local settings = LuaSettings:open(self:getSourceRuntimePath(source.id))
    payload.updated_at = os.time()
    settings.data = payload
    settings:flush()
    self._runtime_source_signatures[source_id] = signature
    return true
end

function Storage:getSource(source_id)
    source_id = tostring(source_id or "")
    if source_id == "" then return nil end
    local source
    if self:isSourceCatalogReady() then
        if not self._source_catalog_cache then
            local ok, data = pcall(function() return LuaSettings:open(self:getSourceCatalogPath()).data end)
            if ok and type(data) == "table" then
                self._source_catalog_cache = data
                self._source_catalog_map = buildSourceCatalogMap(data)
            end
        end
        local summary = self._source_catalog_map and self._source_catalog_map[source_id]
        if summary then
            local records_path = self:getSourceCatalogRecordsPath()
            if records_path then
                source = self:readSourceRecord(records_path, summary.record_offset,
                    summary.record_length, source_id, false)
            end
        end
    end
    if type(source) ~= "table" or not source.id then
        local sources = self:getSourceSettings():readSetting("sources") or {}
        source = sources[source_id]
    end
    source = self:applySourceOverride(source)
    return self:hydrateSourceRuntime(source)
end

function Storage:saveSources(source_list)
    local settings = self:getSourceSettings()
    local sources = settings:readSetting("sources") or {}
    for _, source in ipairs(source_list or {}) do
        if source and source.id then
            local existing = sources[source.id]
            if existing and existing.enabled == false then source.enabled = false end
            sources[source.id] = source
        end
    end
    settings:saveSetting("sources", sources)
    settings:saveSetting("source_compatibility_version", Version.compatibility_version or 6)
    settings:flush()
    self:invalidateSourceCatalog()
    local overrides = self:listSourceOverrides()
    local changed = false
    for _, source in ipairs(source_list or {}) do
        local id = source and tostring(source.id or "") or ""
        if id ~= "" and type(overrides[id]) == "table" and overrides[id].deleted == true then
            overrides[id].deleted = nil
            changed = true
        end
    end
    if changed then
        local override_settings = self:getSourceOverrideSettings()
        override_settings:saveSetting("overrides", overrides)
        override_settings:flush()
    end
    return #(source_list or {})
end

function Storage:saveSource(source)
    return self:saveSources({ source })
end

function Storage:deleteSource(source_id)
    source_id = tostring(source_id or "")
    if source_id == "" then return false end
    local source = self:getSource(source_id)
    self:setSourceOverride(source_id, { deleted = true })
    os.remove(self:getSourceRuntimePath(source_id))
    self:removeSourceHealth(source_id, false)
    -- User ordering is keyed by both the current id and the stable source URL.
    -- Clear both forms when a source is explicitly deleted; an import/update
    -- with the same URL otherwise leaves a stale judgement behind forever.
    local ok, SourcePreference = pcall(require, "Leko/SourcePreference")
    if ok and SourcePreference then
        if source then pcall(SourcePreference.remove, SourcePreference, source) end
        pcall(SourcePreference.remove, SourcePreference, { id = source_id })
    end
    return true
end

function Storage:toggleSource(source_id)
    source_id = tostring(source_id or "")
    local source = self:getSource(source_id)
    if not source then return nil end
    local enabled = source.enabled == false and true or false
    self:setSourceOverride(source_id, { enabled = enabled, deleted = false })
    return enabled
end

function Storage:seedBuiltinSources(force)
    local LegadoSource = require("Leko/LegadoSource")
    if not force and self:isSourceCatalogReady() then
        local catalog = self._source_catalog_cache
        if not catalog then
            local ok, data = pcall(function() return LuaSettings:open(self:getSourceCatalogPath()).data end)
            if ok and type(data) == "table" then catalog = data end
        end
        if tonumber(catalog and catalog.builtin_sources_version or 0) >= tonumber(BuiltinSources.version or 0) then
            return 0, #(BuiltinSources.sources or {})
        end
    end
    local settings = self:getSourceSettings()
    local current_version = tonumber(settings:readSetting("builtin_sources_version") or 0) or 0
    if not force and current_version >= tonumber(BuiltinSources.version or 0) then
        return 0, #(BuiltinSources.sources or {})
    end
    local sources = settings:readSetting("sources") or {}
    local refresh_builtins = force or current_version < tonumber(BuiltinSources.version or 0)
    local added = 0
    for _, raw_source in ipairs(BuiltinSources.sources or {}) do
        raw_source.builtin = true
        local normalized = LegadoSource:normalize(raw_source)
        local existing = sources[normalized.id]
        if refresh_builtins or not existing then
            if existing and existing.enabled ~= nil then normalized.enabled = existing.enabled end
            sources[normalized.id] = normalized
            added = added + 1
        end
    end
    if added > 0 or current_version ~= tonumber(BuiltinSources.version or 0) then
        settings:saveSetting("sources", sources)
        settings:saveSetting("builtin_sources_version", BuiltinSources.version)
        settings:flush()
        self:invalidateSourceCatalog()
    end
    return added, #(BuiltinSources.sources or {})
end

function Storage:getLastImportPath()
    return self:getSettings():readSetting("last_import_path") or DataStorage:getDataDir()
end

function Storage:setLastImportPath(path)
    self:getSettings():saveSetting("last_import_path", path)
    self:getSettings():flush()
end

function Storage:seedDemoBook(force)
    local settings = self:getSettings()
    if not force and tonumber(settings:readSetting("welcome_guide_version") or 0) >= WelcomeGuide.version then
        return false
    end
    local book_id = WelcomeGuide.id
    local existing = self:loadBook(book_id)
    local now = os.time()
    local book = {
        id = book_id,
        title = WelcomeGuide.title,
        author = WelcomeGuide.author,
        intro = WelcomeGuide.intro,
        created_at = existing and existing.created_at or now,
        updated_at = now,
        last_read_at = existing and existing.last_read_at or 0,
        in_library = true,
        not_shelf = false,
        position = existing and existing.position or { chapter = 1, paragraph = 1, char = 1 },
        chapters = {},
    }
    for index, chapter in ipairs(WelcomeGuide.chapters) do
        book.chapters[index] = { id = "guide-" .. index, title = chapter.title, downloaded = true }
    end
    self:saveBook(book)
    for index, chapter in ipairs(WelcomeGuide.chapters) do self:saveChapter(book, index, chapter.text) end
    settings:makeTrue("demo_seeded")
    settings:saveSetting("welcome_guide_version", WelcomeGuide.version)
    settings:flush()
    return true
end

return Storage
