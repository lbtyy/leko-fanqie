local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local socket = require("socket")
local ImagePipeline = require("Leko/ImagePipeline")
local LegadoSource = require("Leko/LegadoSource")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local CoverService = {
    max_memory_entries = 1,
    max_memory_bytes = 1280 * 1024,
    max_disk_files = 36,
    max_disk_bytes = 12 * 1024 * 1024,
    disk_prune_every = 8,
    _disk_writes_since_prune = 0,
    max_diagnostics_bytes = 512 * 1024,
    _memory = {},
    _memory_order = {},
    _memory_bytes = 0,
    _runtime_sources = {},
    _diagnostic_rows = {},
    max_diagnostic_rows = 32,
    _persistent_stats_dirty = false,
    _stats = {
        requests = 0, network = 0, memory_hits = 0, disk_hits = 0,
        stored = 0, rejected = 0, decode_failed = 0, bytes = 0,
    },
}

local function safeCoverDescriptor(value)
    if type(Util.safeCoverDescriptor) == "function" then return Util.safeCoverDescriptor(value) end
    local limit = tonumber(Util.COVER_DESCRIPTOR_LIMIT or (16 * 1024)) or (16 * 1024)
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or #value > limit then return nil end
    return value
end

local function now()
    return socket.gettime and socket.gettime() or os.time()
end

local function compactSpec(value)
    value = tostring(value or "")
    if value:match("^data:image/") then return value:match("^(data:image/[^;,]+)") .. ";base64,<" .. tostring(#value) .. " chars>" end
    if #value > 512 then return value:sub(1, 480) .. "…<" .. tostring(#value) .. " chars>" end
    return value
end

local function csv(value)
    value = tostring(value or ""):gsub('"', '""'):gsub("[\r\n]+", " ")
    return '"' .. value .. '"'
end

function CoverService:getDiagnosticsPath()
    return Util.joinPath(Storage:getLogsDir(), "cover-diagnostics.csv")
end

function CoverService:getPersistentStatsPath()
    return Util.joinPath(Storage:getLogsDir(), "cover-stats.json")
end

function CoverService:getFailureDir()
    local path = Util.joinPath(Storage:getLogsDir(), "cover-failures")
    Util.mkdirp(path)
    return path
end

function CoverService:_loadPersistentStats()
    if self._persistent_stats then return self._persistent_stats end
    local stats = { samples = 0, success = 0, rejected = 0, formats = {}, statuses = {},
        bytes = { small = 0, medium = 0, large = 0, very_large = 0 },
        pixels = { small = 0, medium = 0, large = 0, near_limit = 0, over_limit = 0 },
        jpeg = { progressive = 0, adobe = 0, four_component = 0 },
        max_bytes = 0, max_pixels = 0, max_width = 0, max_height = 0 }
    local raw = Util.readFile(self:getPersistentStatsPath())
    if raw then
        local ok, decoded = pcall(rapidjson.decode, raw)
        if ok and type(decoded) == "table" then stats = decoded end
    end
    stats.formats, stats.statuses = stats.formats or {}, stats.statuses or {}
    stats.bytes = stats.bytes or { small = 0, medium = 0, large = 0, very_large = 0 }
    stats.pixels = stats.pixels or { small = 0, medium = 0, large = 0, near_limit = 0, over_limit = 0 }
    stats.jpeg = stats.jpeg or { progressive = 0, adobe = 0, four_component = 0 }
    self._persistent_stats = stats
    return stats
end

function CoverService:_updatePersistentStats(status, prepared, byte_count)
    local stats = self:_loadPersistentStats()
    local info = prepared and prepared.info or {}
    byte_count = tonumber(byte_count or 0) or 0
    -- Persistent distribution statistics are intentionally limited to actual
    -- response bodies. Cache hits and transport failures stay in the CSV only,
    -- avoiding a settings write on every cached cover view.
    if status ~= "ok" and status ~= "rejected" then return end
    stats.statuses[status] = (tonumber(stats.statuses[status] or 0) or 0) + 1
    stats.samples = (tonumber(stats.samples or 0) or 0) + 1
    if status == "ok" then stats.success = (tonumber(stats.success or 0) or 0) + 1
    else stats.rejected = (tonumber(stats.rejected or 0) or 0) + 1 end
    if info.format then stats.formats[info.format] = (tonumber(stats.formats[info.format] or 0) or 0) + 1 end
    if info.format == "jpg" then
        if info.progressive then stats.jpeg.progressive = (tonumber(stats.jpeg.progressive or 0) or 0) + 1 end
        if info.adobe then stats.jpeg.adobe = (tonumber(stats.jpeg.adobe or 0) or 0) + 1 end
        if info.four_component then stats.jpeg.four_component = (tonumber(stats.jpeg.four_component or 0) or 0) + 1 end
    end
    if byte_count < 100 * 1024 then stats.bytes.small = (stats.bytes.small or 0) + 1
    elseif byte_count < 300 * 1024 then stats.bytes.medium = (stats.bytes.medium or 0) + 1
    elseif byte_count < 1024 * 1024 then stats.bytes.large = (stats.bytes.large or 0) + 1
    else stats.bytes.very_large = (stats.bytes.very_large or 0) + 1 end
    local pixels = tonumber(info.pixels or 0) or 0
    if pixels > 0 then
        if pixels < 250000 then stats.pixels.small = (stats.pixels.small or 0) + 1
        elseif pixels < 500000 then stats.pixels.medium = (stats.pixels.medium or 0) + 1
        elseif pixels < 750000 then stats.pixels.large = (stats.pixels.large or 0) + 1
        elseif pixels <= ImagePipeline.search_policy.max_pixels then stats.pixels.near_limit = (stats.pixels.near_limit or 0) + 1
        else stats.pixels.over_limit = (stats.pixels.over_limit or 0) + 1 end
    end
    stats.max_bytes = math.max(tonumber(stats.max_bytes or 0) or 0, byte_count)
    stats.max_pixels = math.max(tonumber(stats.max_pixels or 0) or 0, pixels)
    stats.max_width = math.max(tonumber(stats.max_width or 0) or 0, tonumber(info.width or 0) or 0)
    stats.max_height = math.max(tonumber(stats.max_height or 0) or 0, tonumber(info.height or 0) or 0)
    self._persistent_stats_dirty = true
end

function CoverService:_saveFailure(result, response, detail, info)
    local body = response and response.body or ""
    local content_type = tostring(response and response.content_type or ""):lower()
    detail = tostring(detail or "")
    if not detail:find("JPEG 数据不完整", 1, true) and not detail:find("无法解码", 1, true) then return end
    if body:sub(1, 2) ~= "\255\216" and not content_type:find("image/jpeg", 1, true) then return end
    local dir = self:getFailureDir()
    local files = {}
    for name in lfs.dir(dir) do
        if name:match("%.jpg$") then
            local path = Util.joinPath(dir, name)
            local attr = lfs.attributes(path)
            files[#files + 1] = { path = path, meta = path .. ".txt", modified = attr and attr.modification or 0 }
        end
    end
    table.sort(files, function(a, b) return a.modified < b.modified end)
    while #files >= 3 do
        local old = table.remove(files, 1); os.remove(old.path); os.remove(old.meta)
    end
    local stem = os.date("%Y%m%d-%H%M%S") .. "-" .. Util.hashId(tostring(result and result.cover or "") .. tostring(#body))
    local path = Util.joinPath(dir, stem .. ".jpg")
    if Util.writeFile(path, body, true) then
        Util.writeFile(path .. ".txt", "title=" .. tostring(result and result.title or "")
            .. "\nsource=" .. tostring(result and result.source_name or "")
            .. "\nrule_url=" .. compactSpec(result and result.cover)
            .. "\nfinal_url=" .. tostring(response and response.url or "")
            .. "\ncontent_type=" .. tostring(response and response.content_type or "")
            .. "\nbytes=" .. tostring(#body)
            .. "\nformat=" .. tostring(info and info.format or "")
            .. "\nwidth=" .. tostring(info and info.width or "")
            .. "\nheight=" .. tostring(info and info.height or "")
            .. "\nprogressive=" .. tostring(info and info.progressive or false)
            .. "\ncomponents=" .. tostring(info and info.components or "")
            .. "\nadobe=" .. tostring(info and info.adobe or false)
            .. "\ncomplete=" .. tostring(info and info.complete or false)
            .. "\ntrailing_bytes=" .. tostring(info and info.trailing_bytes or 0)
            .. "\nerror=" .. tostring(detail or ""))
    end
end

function CoverService:_rotateDiagnostics()
    local path = self:getDiagnosticsPath()
    local attr = lfs.attributes(path)
    if not attr or (tonumber(attr.size or 0) or 0) <= self.max_diagnostics_bytes then return end
    local previous = path:gsub("%.csv$", ".previous.csv")
    os.remove(previous)
    os.rename(path, previous)
end

function CoverService:_log(result, status, detail, prepared, byte_count, elapsed)
    local info = prepared and prepared.info or {}
    detail = tostring(detail or "")
    if info.format == "jpg" then
        detail = detail .. string.format(" [JPEG progressive=%s components=%s adobe=%s trailing=%s]",
            tostring(info.progressive == true), tostring(info.components or ""),
            tostring(info.adobe == true), tostring(info.trailing_bytes or 0))
    end
    local row = table.concat({
        csv(os.date("!%Y-%m-%dT%H:%M:%SZ")), csv(status), csv(result and result.title),
        csv(result and result.source_name), csv(compactSpec(result and result.cover)), tostring(byte_count or 0),
        csv(info.format), tostring(info.width or ""), tostring(info.height or ""),
        tostring(info.pixels or ""), tostring(math.floor((elapsed or 0) * 1000 + 0.5)), csv(detail),
    }, ",")
    self._diagnostic_rows[#self._diagnostic_rows + 1] = row
    while #self._diagnostic_rows > self.max_diagnostic_rows do table.remove(self._diagnostic_rows, 1) end
    self:_updatePersistentStats(status, prepared, byte_count)
end

function CoverService:flushDiagnostics()
    local rows = self._diagnostic_rows or {}
    if #rows > 0 then
        self:_rotateDiagnostics()
        local path = self:getDiagnosticsPath()
        local first = lfs.attributes(path, "mode") ~= "file"
        local file = io.open(path, "a")
        if file then
            if first then
                file:write("time,status,title,source,url,bytes,format,width,height,pixels,elapsed_ms,detail\n")
            end
            file:write(table.concat(rows, "\n"), "\n")
            file:close()
            self._diagnostic_rows = {}
        end
    end
    if self._persistent_stats_dirty and self._persistent_stats then
        local ok, encoded = pcall(rapidjson.encode, self._persistent_stats)
        if ok and Util.writeFile(self:getPersistentStatsPath(), encoded) then
            self._persistent_stats_dirty = false
        end
    end
    return true
end

function CoverService:keyFor(result, width, height)
    return table.concat({
        tostring(result and result.source_id or ""), tostring(result and result.book_url or ""),
        tostring(safeCoverDescriptor(result and result.cover) or ""),
        tostring(width or 0), tostring(height or 0),
    }, "\n")
end

function CoverService:_diskBase(result)
    local identity = table.concat({ tostring(result.source_id or ""), tostring(result.book_url or ""),
        tostring(safeCoverDescriptor(result.cover) or "") }, "\n")
    return Util.joinPath(Storage:getCacheDir("images"), "cover-" .. Util.hashId(identity))
end

function CoverService:getDiskBase(result)
    return self:_diskBase(result or {})
end

function CoverService:hasDisk(result)
    local base = self:_diskBase(result or {})
    return lfs.attributes(base .. ".img", "mode") == "file"
end

-- Return the already validated compressed response kept by the cover cache.
-- The UI-process memory LRU deliberately drops response bytes, so callers
-- that need to promote a successfully displayed source cover to a persistent
-- book cover must read this bounded disk cache instead of retaining another
-- copy in the decoded-image entry.
function CoverService:getCachedBody(result)
    local base = self:_diskBase(result or {})
    local path = base .. ".img"
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil, "cover cache is missing" end
    local max_bytes = tonumber(ImagePipeline.search_policy.max_bytes or 0) or 0
    if max_bytes > 0 and tonumber(attr.size or 0) > max_bytes then
        return nil, "cover cache exceeds the search response limit"
    end
    local body = Util.readFile(path, true)
    if type(body) ~= "string" or body == "" then return nil, "cover cache is empty" end
    local content_type
    local meta_raw = Util.readFile(base .. ".json")
    if meta_raw then
        local ok, meta = pcall(rapidjson.decode, meta_raw)
        if ok and type(meta) == "table" then content_type = meta.content_type end
    end
    return body, content_type
end

function CoverService:_touchMemory(key)
    for index = #self._memory_order, 1, -1 do
        if self._memory_order[index] == key then table.remove(self._memory_order, index) end
    end
    self._memory_order[#self._memory_order + 1] = key
end

function CoverService:_evictMemory()
    while #self._memory_order > self.max_memory_entries or self._memory_bytes > self.max_memory_bytes do
        local key = table.remove(self._memory_order, 1)
        local entry = self._memory[key]
        if entry then
            self._memory[key] = nil
            self._memory_bytes = math.max(0, self._memory_bytes - (entry.bytes or 0))
            ImagePipeline:freeImage(entry.image)
        end
    end
end

function CoverService:_putMemory(key, image, width, height, prepared)
    local old = self._memory[key]
    if old then
        self._memory_bytes = math.max(0, self._memory_bytes - (old.bytes or 0))
        if old.image ~= image then ImagePipeline:freeImage(old.image) end
    end
    local actual_w, actual_h = width, height
    if image and image.getWidth then
        local ok, value = pcall(image.getWidth, image)
        if ok and value then actual_w = value end
    end
    if image and image.getHeight then
        local ok, value = pcall(image.getHeight, image)
        if ok and value then actual_h = value end
    end
    -- Four bytes/pixel is a conservative ceiling across KOReader BB formats.
    local estimate = math.max(1, math.floor(actual_w or 1)) * math.max(1, math.floor(actual_h or 1)) * 4
    -- Never retain the compressed response body in the UI-process LRU. The old
    -- entry stored the whole `prepared` table, keeping both the decoded image and
    -- up to several MiB of JPEG/PNG bytes alive after display.
    local compact_prepared
    if type(prepared) == "table" then
        compact_prepared = {
            content_type = prepared.content_type,
            note = prepared.note,
            info = prepared.info,
            render_width = prepared.render_width,
            render_height = prepared.render_height,
            estimated_decoded_bytes = prepared.estimated_decoded_bytes,
        }
    end
    self._memory[key] = { image = image, bytes = estimate, prepared = compact_prepared }
    self._memory_bytes = self._memory_bytes + estimate
    self:_touchMemory(key)
    self:_evictMemory()
    return image
end

function CoverService:getMemory(result, width, height)
    local key = self:keyFor(result, width, height)
    local entry = self._memory[key]
    if not entry then return nil end
    self:_touchMemory(key)
    return entry.image, entry.prepared
end

function CoverService:clearMemory()
    for _, entry in pairs(self._memory) do ImagePipeline:freeImage(entry.image) end
    self._memory, self._memory_order, self._memory_bytes = {}, {}, 0
end

function CoverService:_readDisk(result, width, height)
    local base = self:_diskBase(result)
    local body = Util.readFile(base .. ".img", true)
    if not body then return nil end
    local meta_raw = Util.readFile(base .. ".json")
    local meta = {}
    if meta_raw then pcall(function() meta = rapidjson.decode(meta_raw) or {} end) end
    local prepared, err = ImagePipeline:prepare(body, meta.content_type, {
        policy = ImagePipeline.search_policy, width = width, height = height, keep_image = true,
    })
    if not prepared then
        os.remove(base .. ".img"); os.remove(base .. ".json")
        return nil, err
    end
    return prepared
end

function CoverService:_writeDisk(result, prepared)
    local base = self:_diskBase(result)
    local ok = Util.writeFile(base .. ".img", prepared.body, true)
    if not ok then return false end
    local meta_ok, meta = pcall(rapidjson.encode, {
        content_type = prepared.content_type, format = prepared.info and prepared.info.format,
        width = prepared.info and prepared.info.width, height = prepared.info and prepared.info.height,
        saved_at = os.time(),
    })
    if not meta_ok then
        os.remove(base .. ".img")
        os.remove(base .. ".json")
        return false
    end
    local meta_written = Util.writeFile(base .. ".json", meta)
    if not meta_written then
        os.remove(base .. ".img")
        os.remove(base .. ".json")
        return false
    end
    self._stats.stored = self._stats.stored + 1
    self:_maybePruneDisk()
    return true
end

-- Download and validate a cover without decoding it into a KOReader BlitBuffer.
-- This is intended for a low-priority subprocess: only the compact response body
-- is written to the shared disk cache. The UI process decodes the selected cover
-- later from a local file, so network latency never blocks page interaction.
function CoverService:prefetch(result, width, height, source_override, temp_suffix, options)
    options = options or {}
    local force = options.force == true
    width, height = math.max(1, math.floor(width or 180)), math.max(1, math.floor(height or 260))
    local base = self:_diskBase(result or {})
    if not force then
        local cached_body = Util.readFile(base .. ".img", true)
        if cached_body then
        local meta_raw = Util.readFile(base .. ".json")
        local meta = {}
        if meta_raw then pcall(function() meta = rapidjson.decode(meta_raw) or {} end) end
        local cached = ImagePipeline:prepare(cached_body, meta.content_type, {
            policy = ImagePipeline.search_policy, width = width, height = height, decode = false,
        })
            if cached then
                    return true, "disk"
            end
            os.remove(base .. ".img")
            os.remove(base .. ".json")
        end
    else
        self:invalidate(result)
    end

    local cover_spec = safeCoverDescriptor(result and result.cover)
    if not cover_spec then return nil, "封面地址为空或过长" end
    local response, err = ImagePipeline:decodeDataUri(cover_spec)
    if not response then
        local source = source_override or self:_sourceFor(result)
        if not source then return nil, "找不到封面所属书源" end
        response, err = LegadoSource:requestBinary(source, cover_spec, {
            book = result, base_url = result.book_url or source.base_url,
            referer = result.book_url or source.base_url, variables = result.variables,
        }, {
            max_bytes = ImagePipeline.search_policy.max_bytes,
            retries = 0,
            timeout = 4,
            maxtime = 8,
            headers = force and { ["cache-control"] = "no-cache", pragma = "no-cache" } or nil,
        })
    end
    if not response then return nil, err or "封面请求失败" end

    local prepared, prepare_err = ImagePipeline:prepare(response.body, response.content_type, {
        policy = ImagePipeline.search_policy, width = width, height = height, decode = false,
    })
    if not prepared then return nil, prepare_err end

    local write_base = temp_suffix and (base .. tostring(temp_suffix)) or base
    local ok, write_err = Util.writeFile(write_base .. ".img", prepared.body, true)
    if not ok then return nil, write_err end
    local meta_ok, meta = pcall(rapidjson.encode, {
        content_type = prepared.content_type, format = prepared.info and prepared.info.format,
        width = prepared.info and prepared.info.width, height = prepared.info and prepared.info.height,
        saved_at = os.time(),
    })
    if meta_ok then
        local meta_written, meta_err = Util.writeFile(write_base .. ".json", meta)
        if not meta_written then
            os.remove(write_base .. ".img")
            return nil, meta_err
        end
    end

    if temp_suffix then
        os.remove(base .. ".img")
        local renamed, rename_err = os.rename(write_base .. ".img", base .. ".img")
        if not renamed then
            os.remove(write_base .. ".img")
            os.remove(write_base .. ".json")
            return nil, rename_err or "无法提交封面缓存"
        end
        if lfs.attributes(write_base .. ".json", "mode") == "file" then
            os.remove(base .. ".json")
            os.rename(write_base .. ".json", base .. ".json")
        end
    end
    self:_maybePruneDisk()
    return true, "network"
end

function CoverService:_maybePruneDisk(force)
    self._disk_writes_since_prune = (tonumber(self._disk_writes_since_prune or 0) or 0) + 1
    if not force and self._disk_writes_since_prune < self.disk_prune_every then return end
    self._disk_writes_since_prune = 0
    self:pruneDisk()
end

function CoverService:pruneDisk()
    local dir = Storage:getCacheDir("images")
    local items, total = {}, 0
    for name in lfs.dir(dir) do
        if name:match("^cover%-.+%.img$") then
            local path = Util.joinPath(dir, name)
            local attr = lfs.attributes(path)
            if attr then
                local size = tonumber(attr.size or 0) or 0
                total = total + size
                items[#items + 1] = { path = path, meta = path:gsub("%.img$", ".json"), size = size, modified = tonumber(attr.modification or 0) or 0 }
            end
        end
    end
    table.sort(items, function(a, b) return a.modified < b.modified end)
    while #items > self.max_disk_files or total > self.max_disk_bytes do
        local item = table.remove(items, 1)
        total = math.max(0, total - item.size)
        os.remove(item.path); os.remove(item.meta)
    end
end

function CoverService:_sourceFor(result, source_override)
    if source_override then return source_override end
    local id = tostring(result.source_id or "")
    local source = self._runtime_sources[id]
    if source then return source end
    source = Storage:getSource(result.source_id)
    if source then
        Storage:hydrateSourceRuntime(source)
        self._runtime_sources[id] = source
        Storage:releaseSourceSettings()
    end
    return source
end

function CoverService:fetch(result, width, height, source_override, options)
    options = options or {}
    local force = options.force == true
    width, height = math.max(1, math.floor(width or 180)), math.max(1, math.floor(height or 260))
    self._stats.requests = self._stats.requests + 1
    if force then self:invalidate(result) end
    local key = self:keyFor(result, width, height)
    local cached = self._memory[key]
    if cached then
        self._stats.memory_hits = self._stats.memory_hits + 1
        self:_touchMemory(key)
        return cached.image, cached.prepared, "memory"
    end

    local started = now()
    local prepared, disk_err = self:_readDisk(result, width, height)
    if prepared then
        self._stats.disk_hits = self._stats.disk_hits + 1
        self:_putMemory(key, prepared.image, width, height, prepared)
        self:_log(result, "disk_hit", "", prepared, #prepared.body, now() - started)
        return prepared.image, prepared, "disk"
    end

    local cover_spec = safeCoverDescriptor(result and result.cover)
    if not cover_spec then return nil, nil, "封面地址为空或过长" end
    local response, err = ImagePipeline:decodeDataUri(cover_spec)
    if not response then
        local source = self:_sourceFor(result, source_override)
        if not source then return nil, nil, "找不到封面所属书源" end
        response, err = LegadoSource:requestBinary(source, cover_spec, {
            book = result, base_url = result.book_url or source.base_url,
            referer = result.book_url or source.base_url, variables = result.variables,
        }, {
            max_bytes = ImagePipeline.search_policy.max_bytes,
            retries = 0,
            timeout = 4,
            maxtime = 8,
            headers = force and { ["cache-control"] = "no-cache", pragma = "no-cache" } or nil,
        })
        self._stats.network = self._stats.network + 1
    end
    if not response then
        self._stats.rejected = self._stats.rejected + 1
        self:_log(result, "request_failed", err or disk_err, nil, 0, now() - started)
        return nil, nil, err or disk_err or "封面请求失败"
    end

    self._stats.bytes = self._stats.bytes + #(response.body or "")
    local rejected_info
    prepared, err, rejected_info = ImagePipeline:prepare(response.body, response.content_type, {
        policy = ImagePipeline.search_policy, width = width, height = height, keep_image = true,
    })
    if not prepared then
        self._stats.rejected = self._stats.rejected + 1
        if tostring(err):find("无法解码", 1, true) then self._stats.decode_failed = self._stats.decode_failed + 1 end
        self:_saveFailure(result, response, err, rejected_info)
        self:_log(result, "rejected", err, rejected_info and { info = rejected_info } or nil, #(response.body or ""), now() - started)
        return nil, nil, err
    end

    self:_writeDisk(result, prepared)
    self:_putMemory(key, prepared.image, width, height, prepared)
    self:_log(result, "ok", prepared.note, prepared, #prepared.body, now() - started)
    return prepared.image, prepared, "network"
end

-- Invalidate every decoded and disk entry for a cover identity. The URL is
-- deliberately part of the identity, while force refresh removes the old
-- entry before the request so a changed response at the same URL is visible.
function CoverService:invalidate(result, width, height)
    result = result or {}
    local identity = table.concat({ tostring(result.source_id or ""), tostring(result.book_url or ""),
        tostring(safeCoverDescriptor(result.cover) or "") }, "\n")
    local prefix = identity .. "\n"
    for key, entry in pairs(self._memory) do
        if key:sub(1, #prefix) == prefix and (not width or key:find("\n" .. tostring(width) .. "\n", 1, true)) then
            self._memory[key] = nil
            self._memory_bytes = math.max(0, self._memory_bytes - (entry.bytes or 0))
            ImagePipeline:freeImage(entry.image)
            for index = #self._memory_order, 1, -1 do
                if self._memory_order[index] == key then table.remove(self._memory_order, index) end
            end
        end
    end
    local base = self:_diskBase(result)
    os.remove(base .. ".img")
    os.remove(base .. ".json")
    return true
end

function CoverService:releaseRuntimeSources()
    self._runtime_sources = {}
    Storage:releaseSourceSettings()
end

function CoverService:getMemoryStats()
    return { entries = #self._memory_order, bytes = self._memory_bytes }
end

function CoverService:getStats()
    local result = {}
    for key, value in pairs(self._stats) do result[key] = value end
    result.memory = self:getMemoryStats()
    result.disk_bytes = Storage:getPathSize(Storage:getCacheDir("images"))
    return result
end

function CoverService:getStatsText()
    local s = self:getStats()
    local p = self:_loadPersistentStats()
    local format_parts = {}
    for format, count in pairs(p.formats or {}) do format_parts[#format_parts + 1] = tostring(format) .. "=" .. tostring(count) end
    table.sort(format_parts)
    return "安全阈值：1.5 MiB / 0.9MP / 单边 1400 px"
        .. "\n内存缩略图：" .. tostring(s.memory.entries) .. "/" .. tostring(self.max_memory_entries)
        .. "，估算 " .. Storage:formatBytes(s.memory.bytes)
        .. "\n磁盘封面缓存：" .. Storage:formatBytes(s.disk_bytes) .. " / " .. Storage:formatBytes(self.max_disk_bytes)
        .. "\n请求：" .. tostring(s.requests) .. "；网络：" .. tostring(s.network)
        .. "；内存命中：" .. tostring(s.memory_hits) .. "；磁盘命中：" .. tostring(s.disk_hits)
        .. "\n拒绝：" .. tostring(s.rejected) .. "；解码失败：" .. tostring(s.decode_failed)
        .. "\n\n累计历史真实样本（跨会话）：" .. tostring(p.samples or 0) .. "；下载并验证成功 " .. tostring(p.success or 0)
        .. "；拒绝 " .. tostring(p.rejected or 0)
        .. "\n注意：这里统计的是以往所有图片下载，不只包含当前这次封面换源。"
        .. "\n格式：" .. (#format_parts > 0 and table.concat(format_parts, "，") or "尚无")
        .. "\nJPEG 特征：渐进式 " .. tostring((p.jpeg or {}).progressive or 0)
        .. "；Adobe 标记 " .. tostring((p.jpeg or {}).adobe or 0)
        .. "；四分量 " .. tostring((p.jpeg or {}).four_component or 0)
        .. "\n文件分布：<100K " .. tostring(p.bytes.small or 0)
        .. "；100-300K " .. tostring(p.bytes.medium or 0)
        .. "；300K-1M " .. tostring(p.bytes.large or 0)
        .. "；≥1M " .. tostring(p.bytes.very_large or 0)
        .. "\n像素分布：<0.25MP " .. tostring(p.pixels.small or 0)
        .. "；0.25-0.5MP " .. tostring(p.pixels.medium or 0)
        .. "；0.5-0.75MP " .. tostring(p.pixels.large or 0)
        .. "；0.75-0.9MP " .. tostring(p.pixels.near_limit or 0)
        .. "；超限 " .. tostring(p.pixels.over_limit or 0)
        .. "\n最大文件：" .. Storage:formatBytes(p.max_bytes or 0)
        .. "；最大尺寸：" .. tostring(p.max_width or 0) .. "×" .. tostring(p.max_height or 0)
        .. "；最大像素：" .. string.format("%.2fMP", (tonumber(p.max_pixels or 0) or 0) / 1000000)
        .. "\n详细记录：\n" .. self:getDiagnosticsPath()
        .. "\n失败 JPG 样本：\n" .. self:getFailureDir()
end

return CoverService
