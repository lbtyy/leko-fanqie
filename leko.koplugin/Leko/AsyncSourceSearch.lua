local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local AsyncSourceCatalog = require("Leko/AsyncSourceCatalog")
local BookIdentity = require("Leko/BookIdentity")
local LegadoSource = require("Leko/LegadoSource")
local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local SearchCandidateContext = require("Leko/SearchCandidateContext")
local SearchSettings = require("Leko/SearchSettings")
local SourceHealth = require("Leko/SourceHealth")
local SourcePreference = require("Leko/SourcePreference")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")

local AsyncSourceSearch = {}
AsyncSourceSearch.__index = AsyncSourceSearch

local POLL_INTERVAL = 0.18
local REAP_INTERVAL = 0.18
local SOURCE_BATCH_YIELD = 0.08
local MAX_PARALLEL_WORKERS = 2
local SOURCE_DEADLINE = 14
local FAST_SOURCE_DEADLINE = 5
local DEFAULT_RESULT_LIMIT = nil
local LOW_RAM_WAVE_SIZE = 8
local LOW_RAM_WAVE_REST = 0.35
local MAX_ERRORS = 8
local MAX_SOURCE_RESULTS_TO_INSPECT = SearchSettings.MAX_LIMIT
local RESULT_PAYLOAD_LIMIT = 2 * 1024 * 1024
local GLOBAL_SEARCH_PRIORITY = 35
local SWITCH_SEARCH_PRIORITY = 55
local HISTORY_EXPLORATION_INTERVAL = 4
local FAST_PHASE_TARGET = 16
local FAST_KNOWN_TARGET = 10
local FAST_EXPLORE_TARGET = 6
local IMMEDIATE_INITIAL_PROGRESS = 8

local function sourceDeadline(entry)
    return entry and entry.fast_phase and not entry.fast_retry_done
        and FAST_SOURCE_DEADLINE or SOURCE_DEADLINE
end

local function clamp(value, low, high)
    value = tonumber(value or 0) or 0
    if value < low then return low end
    if value > high then return high end
    return value
end

local function sourcePriorityScore(entry, now)
    local health = entry and entry.health or nil
    local score = tonumber(entry and entry.capability_score)
    if not score then
        local grade = tostring(entry and entry.compatibility_grade or "")
        score = grade == "A" and 600 or (grade == "B" and 300 or 0)
    end
    score = score + clamp(entry and entry.weight, -100, 100) * 4
    local custom_order = tonumber(entry and entry.custom_order or 999999) or 999999
    if custom_order < 1000 then score = score + math.max(0, 160 - custom_order * 0.16) end
    if type(health) ~= "table" then return score end

    now = tonumber(now or os.time()) or os.time()
    local checked_at = tonumber(health.checked_at or 0) or 0
    local checked_age = checked_at > 0 and math.max(0, now - checked_at) or math.huge
    if health.status == "online" and checked_age <= 30 * 24 * 60 * 60 then
        local freshness = checked_age <= 6 * 60 * 60 and 1
            or (checked_age <= 7 * 24 * 60 * 60 and 0.55 or 0.2)
        score = score + 350 * freshness
        local latency = tonumber(health.latency_ms)
        if latency then score = score + math.max(0, 260 - latency / 8) * freshness end
    end
    local attempts = tonumber(health.search_attempts or 0) or 0
    local hits = tonumber(health.search_hits or 0) or 0
    local exact_hits = tonumber(health.exact_hits or 0) or 0
    local failures = tonumber(health.search_failures or 0) or 0
    local selected = tonumber(health.selected_count or 0) or 0
    score = score + math.min(selected, 12) * 650
    score = score + math.min(exact_hits, 20) * 70
    if attempts > 0 then
        score = score + math.min(1, hits / attempts) * 800
        score = score - math.min(1, failures / attempts) * 320
    end
    local selected_age = now - (tonumber(health.last_selected_at or 0) or 0)
    if selected_age >= 0 and selected_age <= 30 * 24 * 60 * 60 then score = score + 700 end
    local hit_age = now - (tonumber(health.last_hit_at or 0) or 0)
    if hit_age >= 0 and hit_age <= 7 * 24 * 60 * 60 then score = score + 320 end
    return score
end

local function hasUsefulHistory(entry)
    local health = entry and entry.health
    if type(health) ~= "table" then return false end
    local checked_at = tonumber(health.checked_at or 0) or 0
    local recent_ping = health.status == "online" and tonumber(health.latency_ms) ~= nil
        and checked_at > 0 and os.time() - checked_at <= 7 * 24 * 60 * 60
    return (tonumber(health.selected_count or 0) or 0) > 0
        or (tonumber(health.exact_hits or 0) or 0) > 0
        or (tonumber(health.search_attempts or 0) or 0) >= 2
        or recent_ping
end

local function explorationSeeds(explore, wanted)
    local selected, used = {}, {}
    local total = #explore
    wanted = math.min(math.max(0, wanted or 0), total)
    local front = math.min(3, wanted)
    for index = 1, front do
        selected[#selected + 1] = explore[index]
        used[index] = true
    end
    local remaining = wanted - #selected
    for slot = 1, remaining do
        local ratio = slot / math.max(1, remaining)
        local index = math.max(front + 1, math.min(total, math.floor(front + ratio * (total - front) + 0.5)))
        while index <= total and used[index] do index = index + 1 end
        if index > total then
            index = front + 1
            while index <= total and used[index] do index = index + 1 end
        end
        if index <= total and not used[index] then
            selected[#selected + 1] = explore[index]
            used[index] = true
        end
    end
    return selected, used
end

local function adaptiveQueueOrder(queue)
    -- Manual reader judgements are an outer scheduling contract.  A preferred
    -- source gets one interleaved front-of-queue attempt; a miss/timeout is
    -- retried from the tail of that insertion queue so one slow source cannot
    -- block the other preferred sources or the main scan.
    -- Keep the learned/stratified ordering inside the automatic band, and
    -- always leave the "last" band in the queue so it is still fully scanned.
    local preferred, automatic, deferred = {}, {}, {}
    for index, entry in ipairs(queue or {}) do
        entry.base_order = index
        local tier = SourcePreference:get(entry)
        if tier == SourcePreference.PRIORITY then
            entry.manual_priority = true
            entry.fast_phase = false
            preferred[#preferred + 1] = entry
        elseif tier == SourcePreference.LAST then
            entry.manual_priority = false
            entry.fast_phase = false
            deferred[#deferred + 1] = entry
        else
            entry.manual_priority = false
            automatic[#automatic + 1] = entry
        end
    end
    if #preferred > 0 or #deferred > 0 then
        local automatic_order, automatic_fast = adaptiveQueueOrder(automatic)
        local function originalOrder(left, right)
            return tonumber(left.base_order or 0) < tonumber(right.base_order or 0)
        end
        table.sort(preferred, originalOrder)
        table.sort(deferred, originalOrder)
        local ordered = {}
        local preferred_index, automatic_index = 1, 1
        while preferred_index <= #preferred or automatic_index <= #automatic_order do
            if automatic_index <= #automatic_order then
                ordered[#ordered + 1] = automatic_order[automatic_index]
                automatic_index = automatic_index + 1
            end
            if preferred_index <= #preferred then
                ordered[#ordered + 1] = preferred[preferred_index]
                preferred_index = preferred_index + 1
            end
        end
        for _, entry in ipairs(deferred) do ordered[#ordered + 1] = entry end
        return ordered, automatic_fast or 0
    end
    local known, explore = {}, {}
    local now = os.time()
    for index, entry in ipairs(queue or {}) do
        entry.base_order = index
        entry.priority_score = sourcePriorityScore(entry, now)
        if hasUsefulHistory(entry) then known[#known + 1] = entry else explore[#explore + 1] = entry end
    end
    local function better(left, right)
        local ls, rs = tonumber(left.priority_score or 0) or 0, tonumber(right.priority_score or 0) or 0
        if ls ~= rs then return ls > rs end
        return tonumber(left.base_order or 0) < tonumber(right.base_order or 0)
    end
    table.sort(known, better)
    table.sort(explore, better)

    -- Phase 1 is deliberately small: proven/selected sources run first, but a
    -- stratified sample of unknown sources is mixed in so a newly imported good
    -- source near the end of a large pack can still be discovered early.
    local known_fast_count = math.min(#known, FAST_KNOWN_TARGET)
    -- Always try to fill the 16-source fast phase. With mature history this is
    -- normally 10 proven sources + 6 exploratory sources. On first use, when
    -- there is no reliable history yet, stratify up to all 16 across the pack
    -- instead of testing only its first handful of entries.
    local explore_fast_count = math.min(#explore,
        math.max(FAST_EXPLORE_TARGET, FAST_PHASE_TARGET - known_fast_count))
    local explore_fast, explore_used = explorationSeeds(explore, explore_fast_count)
    local ordered, known_used = {}, {}
    local ki, ei = 1, 1
    while ki <= known_fast_count or ei <= #explore_fast do
        for _ = 1, 2 do
            if ki > known_fast_count then break end
            local entry = known[ki]
            entry.fast_phase = true
            ordered[#ordered + 1] = entry
            known_used[ki] = true
            ki = ki + 1
        end
        if ei <= #explore_fast then
            local entry = explore_fast[ei]
            entry.fast_phase = true
            ordered[#ordered + 1] = entry
            ei = ei + 1
        end
    end
    local fast_count = #ordered

    local known_rest, explore_rest = {}, {}
    for index, entry in ipairs(known) do if not known_used[index] then known_rest[#known_rest + 1] = entry end end
    for index, entry in ipairs(explore) do if not explore_used[index] then explore_rest[#explore_rest + 1] = entry end end
    ki, ei = 1, 1
    while ki <= #known_rest or ei <= #explore_rest do
        for _ = 1, HISTORY_EXPLORATION_INTERVAL do
            if ki > #known_rest then break end
            ordered[#ordered + 1] = known_rest[ki]
            ki = ki + 1
        end
        if ei <= #explore_rest then
            ordered[#ordered + 1] = explore_rest[ei]
            ei = ei + 1
        elseif ki > #known_rest then
            break
        end
    end
    return ordered, fast_count
end

local function manualQueueOrder(queue)
    local preferred, automatic, deferred = {}, {}, {}
    for index, entry in ipairs(queue or {}) do
        local item = { entry = entry, index = index }
        local tier = SourcePreference:get(entry)
        if tier == SourcePreference.PRIORITY then
            entry.manual_priority = true
            entry.fast_phase = false
            preferred[#preferred + 1] = item
        elseif tier == SourcePreference.LAST then
            entry.manual_priority = false
            entry.fast_phase = false
            deferred[#deferred + 1] = item
        else
            entry.manual_priority = false
            automatic[#automatic + 1] = item
        end
    end
    local function stable(left, right) return left.index < right.index end
    table.sort(preferred, stable)
    table.sort(automatic, stable)
    table.sort(deferred, stable)
    local ordered = {}
    local preferred_index, automatic_index = 1, 1
    while preferred_index <= #preferred or automatic_index <= #automatic do
        if automatic_index <= #automatic then
            ordered[#ordered + 1] = automatic[automatic_index].entry
            automatic_index = automatic_index + 1
        end
        if preferred_index <= #preferred then
            ordered[#ordered + 1] = preferred[preferred_index].entry
            preferred_index = preferred_index + 1
        end
    end
    for _, item in ipairs(deferred) do
        ordered[#ordered + 1] = item.entry
    end
    return ordered
end

local function compactResult(result, source, include_cover_context)
    local compact = {
        title = tostring(result and result.title or ""),
        author = tostring(result and result.author or ""),
        intro = tostring(result and result.intro or ""):sub(1, 512),
        book_url = result and result.book_url or nil,
        toc_url = result and result.toc_url or nil,
        cover = result and result.cover or nil,
        source_id = source and source.id or (result and result.source_id),
        source_name = source and source.name or (result and result.source_name),
        -- ruleSearch variables are executable request context, not optional UI
        -- metadata. They are moved to a child-side sidecar before IPC.
        variables = result and result.variables or nil,
        _search_base_url = result and result._search_base_url or nil,
    }
    if include_cover_context and source then
        compact._cover_source = {
            id = source.id,
            name = source.name,
            base_url = source.base_url,
            header = source.header,
            cookies = source.cookies,
            variables = source.variables,
            enabled_cookie_jar = source.enabled_cookie_jar,
        }
    end
    return compact
end

local function compactRuntime(source)
    return {
        cookies = source and source.cookies or nil,
        variables = source and source.variables or nil,
        login_header = source and source.login_header or nil,
    }
end

local function resultKey(result)
    return tostring(result and result.source_id or "") .. "\n" .. tostring(result and result.book_url or "")
end

local function closeResultPipe(worker)
    if not worker then return nil end
    local raw
    if worker.result_fd then
        local fd = worker.result_fd
        worker.result_fd = nil
        local ok, value = pcall(ffiutil.readAllFromFD, fd)
        if ok then raw = value end
    end
    SubprocessPayload:cleanup(worker.payload_path)
    worker.payload_path = nil
    return raw
end

local function readResultPayload(worker)
    if not worker then return nil, "单源搜索任务不存在" end
    local fd = worker.result_fd
    worker.result_fd = nil
    local path = worker.payload_path
    worker.payload_path = nil
    return SubprocessPayload:read(fd, path, { max_bytes = RESULT_PAYLOAD_LIMIT })
end

local function executeSourceJob(job)
    local payload = { results = {} }
    local ok, err = xpcall(function()
        local source, source_err
        if job.records_path and job.record_offset ~= nil and job.record_length ~= nil then
            source, source_err = Storage:readSourceRecord(job.records_path, job.record_offset,
                job.record_length, job.source_id, true)
        else
            source = Storage:getSource(job.source_id)
        end
        if not source then error(tostring(source_err or "找不到书源定义")) end
        local health_map = {}
        if type(job.cached_health) == "table" then health_map[tostring(job.source_id)] = job.cached_health end
        local cached_decision, cached_health = SourceHealth:cachedDecision(source, nil, health_map)
        payload.health = cached_health
        -- Automatic sources may honor a recent explicit offline result. A
        -- manually preferred source is deliberately still tried once; the
        -- reader's choice must not be silently defeated by stale health.
        if cached_decision == false and job.manual_priority ~= true then
            payload.skipped = true
            payload.error = cached_health and cached_health.error or "书源近期不可连接"
        else
            local search_started = socket.gettime()
            local inspect_limit = math.max(1, math.min(MAX_SOURCE_RESULTS_TO_INSPECT,
                tonumber(job.inspect_limit or MAX_SOURCE_RESULTS_TO_INSPECT) or MAX_SOURCE_RESULTS_TO_INSPECT))
            local found, search_err = LegadoSource:search(source, job.keyword, 1, {
                cache_read = false,
                cache_write = false,
                save_runtime = false,
                max_results = inspect_limit,
                -- An exact normalized title scores 1000, the global search
                -- ceiling. Once such a complete candidate has been parsed,
                -- later rows cannot improve the selected result.
                exact_title_query = job.mode == "global" and job.keyword or nil,
                request_options = {
                    timeout = 8,
                    maxtime = 12,
                    retries = 0,
                    max_bytes = 2 * 1024 * 1024,
                },
            })
            if type(found) == "table" then
                local elapsed_ms = math.floor(math.max(0, socket.gettime() - search_started) * 1000 + 0.5)
                payload.health = SourceHealth:record(source, "online", elapsed_ms, nil, nil)
                if job.mode == "global" then
                    local limited = {}
                    for index = 1, math.min(#found, inspect_limit) do
                        limited[index] = found[index]
                    end
                    -- One source contributes at most its single best result. This
                    -- prevents noisy imported sources from flooding the list with
                    -- loosely related books while still checking later rows when
                    -- the first row is wrong.
                    local item, score, kind = BookIdentity:bestSearchResult(limited, job.keyword)
                    if item then
                        local candidate = compactResult(item, source, false)
                        candidate.match_score = score
                        candidate.match_kind = kind
                        payload.results[1] = candidate
                    elseif #found > 0 then
                        payload.query_mismatch = true
                    end
                else
                    local limited = {}
                    for index = 1, math.min(#found, inspect_limit) do
                        limited[index] = found[index]
                    end
                    local item = BookIdentity:bestExactTitle(limited, job.book_title, job.book_author,
                        job.mode == "cover")
                    if item then
                        local candidate = compactResult(item, source, false)
                        candidate.author_mismatch = BookIdentity:authorDiffers(job.book_author, item.author)
                        if job.mode == "cover" and tostring(candidate.cover or "") == "" then
                            candidate.needs_cover_detail = true
                        end
                        payload.results[1] = candidate
                    elseif #found > 0 then
                        payload.no_same_title = true
                    end
                end
            elseif search_err then
                payload.error = tostring(search_err)
                if SourceHealth:isNetworkError(search_err) then
                    payload.health = SourceHealth:record(source, "offline", nil, nil,
                        "搜索请求失败：" .. tostring(search_err))
                end
            end
            for _, candidate in ipairs(payload.results) do
                candidate._source_record = {
                    records_path = job.records_path,
                    record_offset = job.record_offset,
                    record_length = job.record_length,
                }
            end
            if #payload.results > 0 then
                -- Keep the full executable search context inside the source child.
                -- The child writes it to a sidecar before exiting; the KOReader UI
                -- process receives only a tiny row + sidecar path, so it never has
                -- to decode and re-encode large variables/Cookie/runtime tables.
                local runtime = compactRuntime(source)
                for _, candidate in ipairs(payload.results) do
                    candidate._source_runtime = runtime
                    local _, spill_err = SearchCandidateContext:spill(candidate, true)
                    if spill_err or not candidate._candidate_context_path then
                        error("无法保存这条搜索结果：" .. tostring(spill_err or "临时数据未生成"))
                    end
                end
            end
            local first = payload.results[1]
            payload.health = SourceHealth:withSearchActivity(payload.health, job.cached_health, {
                attempted = true,
                hit = first ~= nil,
                exact = first ~= nil and (job.mode ~= "global" or first.match_kind == "exact-title"),
                failed = payload.error ~= nil,
            })
        end
        Storage:releaseSourceSettings()
        Storage:releaseSourceOverrideSettings()
    end, debug.traceback)
    if not ok then
        payload.error = tostring(err)
        payload.results = {}
        payload.health = SourceHealth:withSearchActivity(payload.health or {
            source_id = tostring(job.source_id or ""),
            source_name = tostring(job.source_name or ""),
            checked_at = 0,
        }, job.cached_health, { attempted = true, failed = true })
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
    end
    return payload
end

function AsyncSourceSearch:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.book = options.book or {}
    instance.mode = options.mode == "cover" and "cover"
        or (options.mode == "global" and "global" or "content")
    instance.keyword = tostring(options.keyword or (options.book and options.book.title) or "")
    local low_ram = type(MemoryGuard.isLowRam) ~= "function" or MemoryGuard:isLowRam() == true
    instance.low_ram = low_ram
    local requested_limit = tonumber(options.max_results or DEFAULT_RESULT_LIMIT)
    instance.max_results = requested_limit and requested_limit > 0 and math.floor(requested_limit) or nil
    instance.requested_parallel_workers = math.max(1,
        math.min(MAX_PARALLEL_WORKERS, tonumber(options.max_parallel_workers or MAX_PARALLEL_WORKERS) or MAX_PARALLEL_WORKERS))
    local memory_workers = MemoryGuard:recommendedBackgroundWorkers()
    instance.max_parallel_workers = math.min(instance.requested_parallel_workers,
        math.max(1, tonumber(memory_workers or 1) or 1))
    instance.on_batch = options.on_batch
    instance.on_progress = options.on_progress
    instance.on_done = options.on_done
    instance.completed_sources = 0
    instance.total_sources = 0
    instance.result_count = 0
    instance.discovered_count = 0
    instance.overflow_count = 0
    instance.skipped_sources = 0
    instance.resource_skipped_sources = 0
    instance.errors = {}
    instance.seen = {}
    instance.queue = nil
    instance.queue_index = 0
    instance.manual_priority_queue = {}
    instance.manual_insert_next = false
    instance.retry_queue = {}
    instance.deferred_retry_queue = {}
    instance.fast_attempted_count = 0
    instance.workers = {}
    instance.pending = {}
    instance.reaping_count = 0
    instance.catalog_ticket = nil
    instance.cancelled = false
    instance.finished = false
    instance.paused = false
    instance.pause_reason = nil
    instance.fast_phase_count = 0
    instance.process_priority = tonumber(options.process_priority)
        or (instance.mode == "global" and GLOBAL_SEARCH_PRIORITY or SWITCH_SEARCH_PRIORITY)
    instance._last_progress_at = 0
    instance._fill_callback = nil
    return instance
end

function AsyncSourceSearch:_addError(source_name, err)
    if #self.errors >= MAX_ERRORS then return end
    self.errors[#self.errors + 1] = tostring(source_name or "书源") .. ": " .. tostring(err or "失败")
end

function AsyncSourceSearch:_acceptCandidate(candidate, entry)
    if type(candidate) ~= "table" then return nil end
    candidate.source_id = tostring(entry and entry.id or candidate.source_id or "")
    candidate.source_name = tostring(entry and entry.name or candidate.source_name or "")
    candidate.source_priority_score = tonumber(entry and entry.priority_score or candidate.source_priority_score or 0) or 0
    if candidate.source_id == "" or tostring(candidate.book_url or "") == "" then return nil end
    if self.mode == "global" then
        local score, kind = BookIdentity:searchMatch(self.keyword, candidate.title, candidate.author)
        if not score then return nil end
        candidate.match_score = tonumber(candidate.match_score or score) or score
        candidate.match_kind = candidate.match_kind or kind
    elseif not BookIdentity:sameTitle(self.book and self.book.title, candidate.title) then
        return nil
    else
        candidate.author_mismatch = BookIdentity:authorDiffers(self.book and self.book.author, candidate.author)
    end
    return candidate
end

function AsyncSourceSearch:_emit(results, entry)
    local batch = {}
    for _, raw in ipairs(results or {}) do
        local result = self:_acceptCandidate(raw, entry)
        local key = result and resultKey(result) or "\n"
        if key ~= "\n" and not self.seen[key] then
            self.seen[key] = true
            self.discovered_count = self.discovered_count + 1
            if not self.max_results or self.result_count < self.max_results then
                self.result_count = self.result_count + 1
                batch[#batch + 1] = result
            else
                self.overflow_count = self.overflow_count + 1
                SearchCandidateContext:cleanup(result)
            end
        else
            -- The child may already have created a sidecar. If the parent rejects
            -- or deduplicates the row, remove it immediately instead of leaking
            -- one temp file per discarded candidate.
            SearchCandidateContext:cleanup(raw)
        end
    end
    -- Do not reorder a batch by match score. Results are appended as the
    -- source workers report them; the list must remain stable while later
    -- sources finish.
    if #batch > 0 and self.on_batch and not self.cancelled then pcall(self.on_batch, batch, self) end
    return #batch > 0
end

function AsyncSourceSearch:_notifyProgress(stage, force)
    if self.cancelled or self.finished and not force then return end
    self.last_stage = stage or self.last_stage or "后台搜索中"
    local now = socket.gettime()
    -- Source switching is judged by time-to-first-useful-result. Report every
    -- completion in its first wave so the e-ink UI never appears stuck at 0;
    -- later no-result progress remains throttled. Candidate emission and final
    -- state already pass force=true and therefore stay immediate at any point.
    local initial_source_switch = self.mode == "content"
        and self.completed_sources <= IMMEDIATE_INITIAL_PROGRESS
    if not force and not initial_source_switch
            and now - (self._last_progress_at or 0) < 0.8 then return end
    self._last_progress_at = now
    if self.on_progress then
        pcall(self.on_progress, self.completed_sources, self.total_sources, self.last_stage, self)
    end
end

function AsyncSourceSearch:_activeCount()
    local count = 0
    for _ in pairs(self.workers) do count = count + 1 end
    return count
end

function AsyncSourceSearch:_pendingCount()
    local count = 0
    for _ in pairs(self.pending) do count = count + 1 end
    return count
end

function AsyncSourceSearch:_hasRemainingEntries()
    return #self.retry_queue > 0
        or self.queue and self.queue_index < #self.queue
        or #self.manual_priority_queue > 0
        or #self.deferred_retry_queue > 0
end

function AsyncSourceSearch:_nextEntry()
    if #self.retry_queue > 0 then return table.remove(self.retry_queue, 1) end

    local main_available = self.queue and self.queue_index < #self.queue
    local preferred_available = #self.manual_priority_queue > 0
    if main_available and preferred_available then
        if self.manual_insert_next then
            self.manual_insert_next = false
            return table.remove(self.manual_priority_queue, 1)
        end
        self.queue_index = self.queue_index + 1
        self.manual_insert_next = true
        return self.queue[self.queue_index]
    end
    if main_available then
        self.queue_index = self.queue_index + 1
        self.manual_insert_next = true
        return self.queue[self.queue_index]
    end
    if preferred_available then
        self.manual_insert_next = false
        return table.remove(self.manual_priority_queue, 1)
    end
    if #self.deferred_retry_queue > 0 then return table.remove(self.deferred_retry_queue, 1) end
    return nil
end

function AsyncSourceSearch:_returnEntry(entry)
    if entry and not self.cancelled and not self.finished then
        table.insert(self.retry_queue, 1, entry)
    end
end

function AsyncSourceSearch:_deferEntry(entry)
    if entry and not self.cancelled and not self.finished then
        self.deferred_retry_queue[#self.deferred_retry_queue + 1] = entry
    end
end

function AsyncSourceSearch:_deferManualPriority(entry)
    if self.cancelled or self.finished
            or not entry or entry.manual_priority ~= true or entry.manual_priority_retry_done then
        return false
    end
    entry.manual_priority_retry_done = true
    self.total_sources = self.total_sources + 1
    self.manual_priority_queue[#self.manual_priority_queue + 1] = entry
    return true
end

function AsyncSourceSearch:_markFastAttempt(entry)
    if entry and entry.fast_phase and not entry._fast_attempt_counted then
        entry._fast_attempt_counted = true
        self.fast_attempted_count = self.fast_attempted_count + 1
    end
end

function AsyncSourceSearch:_finishIfIdle()
    if self.cancelled or self.finished then return true end
    if self:_hasRemainingEntries() or self:_activeCount() > 0 or self:_pendingCount() > 0
            or self.reaping_count > 0 then return false end
    local stage = "搜索完成；找到 " .. tostring(self.discovered_count) .. " 个结果"
    if self.skipped_sources > 0 then
        stage = stage .. "，跳过 " .. tostring(self.skipped_sources) .. " 个近期不可连接/异常书源"
    end
    if self.resource_skipped_sources > 0 then
        stage = stage .. "；内存保护跳过 " .. tostring(self.resource_skipped_sources) .. " 个高负载书源"
    end
    if self.overflow_count > 0 then
        stage = stage .. "；仅保留前 " .. tostring(self.max_results)
            .. " 个结果，另有 " .. tostring(self.overflow_count) .. " 个没有显示"
    end
    self.last_stage = stage
    self.finished = true
    pcall(SourceHealth.scheduleFlush, SourceHealth, 20)
    self.queue = nil
    self.manual_priority_queue = {}
    self.retry_queue = {}
    self.deferred_retry_queue = {}
    self:_notifyProgress(stage, true)
    if self.on_done then pcall(self.on_done, self.errors, self) end
    return true
end

function AsyncSourceSearch:_prepareQueue()
    local summaries, list_err = Storage:listSourceSummaries()
    if not summaries then
        self:_addError("书源索引", list_err)
        self.last_stage = "无法读取书源列表"
        self.finished = true
        if self.on_done then pcall(self.on_done, self.errors, self) end
        return
    end
    local health_map = Storage:listSourceHealth()
    local skipped_id = ""
    if self.mode == "content" then
        skipped_id = tostring(self.book.source_id or "")
    elseif self.mode == "cover" then
        skipped_id = tostring(self.book.cover_source_id or self.book.source_id or "")
    end
    local records_path, records_err = Storage:getSourceCatalogRecordsPath()
    if not records_path then
        self:_addError("书源索引", records_err)
        self.last_stage = "无法读取书源记录文件"
        self.finished = true
        if self.on_done then pcall(self.on_done, self.errors, self) end
        return
    end
    local queue = {}
    local pre_skipped = 0
    for _, summary in ipairs(summaries) do
        local eligible = summary.enabled ~= false and summary.searchable ~= false
            and summary.has_search_url == true
            and tostring(summary.id or "") ~= skipped_id
            and (self.mode ~= "cover" or summary.cover_supported ~= false)
        if eligible then
            local manual_priority = SourcePreference:get(summary) == SourcePreference.PRIORITY
            local decision = SourceHealth:cachedDecision(summary, nil, health_map)
            if decision == false and not manual_priority then
                pre_skipped = pre_skipped + 1
            else
                queue[#queue + 1] = {
                    id = summary.id,
                    name = summary.name,
                    capability_profile = summary.capability_profile,
                    capability_score = summary.capability_score,
                    weight = summary.weight,
                    custom_order = summary.custom_order,
                    health = health_map[tostring(summary.id or "")],
                    manual_priority = manual_priority,
                    records_path = records_path,
                    record_offset = summary.record_offset,
                    record_length = summary.record_length,
                }
            end
        end
    end
    summaries = nil
    -- Keep learned quality inside the automatic main queue. Manual-priority
    -- entries are held in their own insertion queue so failed entries can be
    -- appended to that queue's tail without waiting for the entire main scan.
    queue, self.fast_phase_count = adaptiveQueueOrder(queue)
    local main_queue, manual_priority_queue, deferred_queue = {}, {}, {}
    for _, entry in ipairs(queue) do
        if entry.manual_priority == true then
            manual_priority_queue[#manual_priority_queue + 1] = entry
        elseif SourcePreference:get(entry) == SourcePreference.LAST then
            deferred_queue[#deferred_queue + 1] = entry
        else
            main_queue[#main_queue + 1] = entry
        end
    end
    self.queue = main_queue
    self.queue_index = 0
    self.manual_priority_queue = manual_priority_queue
    self.manual_insert_next = false
    self.deferred_retry_queue = deferred_queue
    self.total_sources = #queue
    self.skipped_sources = pre_skipped
    self:_notifyProgress(pre_skipped > 0
        and ("已跳过 " .. tostring(pre_skipped) .. " 个近期不可连接书源")
        or (self.fast_phase_count > 0
            and ("先搜索 " .. tostring(self.fast_phase_count) .. " 个常用/快速与探索书源")
            or "书源索引已准备"), true)
    collectgarbage("step", 80)
    self:_scheduleFill(0)
end

function AsyncSourceSearch:_scheduleFill(delay)
    if self.cancelled or self.finished or self.paused or self._fill_callback then return end
    local callback
    callback = function()
        self._fill_callback = nil
        self:_fillSlots()
    end
    self._fill_callback = callback
    UIManager:scheduleIn(delay or SOURCE_BATCH_YIELD, callback)
end

function AsyncSourceSearch:_releaseWorkerBudget(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

function AsyncSourceSearch:_processSourceResult(entry, payload)
    payload = type(payload) == "table" and payload or { results = {}, error = "单源搜索结果损坏" }
    self:_markFastAttempt(entry)
    self.completed_sources = self.completed_sources + 1
    if payload.health then SourceHealth:save(payload.health) end
    if payload.resource_guard then
        self.resource_skipped_sources = self.resource_skipped_sources + 1
    elseif payload.skipped or payload.health and payload.health.status == "offline" then
        self.skipped_sources = self.skipped_sources + 1
    end
    if payload.error then self:_addError(entry and entry.name, payload.error) end
    local direct = type(payload.results) == "table" and payload.results or {}
    local emitted = self:_emit(direct, entry)
    -- A preferred source that returned no usable result gets one later retry at
    -- the tail of the manual insertion queue, before that queue is exhausted.
    if not emitted then self:_deferManualPriority(entry) end
    -- Drop the decoded IPC tree as soon as the tiny rows have been handed off.
    -- On Kindle 7 this matters more than keeping a large payload alive until the
    -- next periodic collection.
    payload.results = nil
    payload.runtime = nil
    local stage
    if emitted then
        stage = self.mode == "global"
            and ("已发现 " .. tostring(self.discovered_count) .. " 条相关结果；继续后台搜索")
            or ("已找到 " .. tostring(self.discovered_count) .. " 个同名结果；继续后台搜索")
    elseif payload.resource_guard then
        stage = "内存保护已跳过高负载书源；继续搜索 " .. tostring(self.completed_sources) .. "/" .. tostring(self.total_sources)
    elseif payload.health and payload.health.status == "offline" then
        stage = "已跳过不可连接书源 " .. tostring(self.completed_sources) .. "/" .. tostring(self.total_sources)
    elseif payload.error and not payload.no_same_title and not payload.query_mismatch then
        stage = "已跳过异常书源 " .. tostring(self.completed_sources) .. "/" .. tostring(self.total_sources)
    else
        -- Title/query mismatches are normal search misses. Keep them internal,
        -- as Legado-style streaming search does, rather than blaming a source.
        if entry and entry.fast_phase and not entry.fast_retry_done and self.fast_phase_count > 0 then
            stage = "优先搜索常用/快速书源 " .. tostring(self.fast_attempted_count)
                .. "/" .. tostring(self.fast_phase_count)
        else
            stage = "继续完整扫描 " .. tostring(self.completed_sources)
                .. "/" .. tostring(self.total_sources) .. " 个书源"
        end
    end
    self:_notifyProgress(stage, emitted or self.completed_sources == self.total_sources)
    return emitted
end

function AsyncSourceSearch:_continueAfterSource()
    if self.cancelled or self.finished or self.paused then return end
    local delay = SOURCE_BATCH_YIELD
    if self.low_ram and self.completed_sources > 0
            and self.completed_sources % LOW_RAM_WAVE_SIZE == 0 then
        -- Give the allocator/kernel a real recovery point instead of forking
        -- hundreds of children back-to-back on a 256 MiB Kindle.
        collectgarbage("collect")
        delay = LOW_RAM_WAVE_REST
        self:_notifyProgress("低内存设备休整片刻；已完成 "
            .. tostring(self.completed_sources) .. "/" .. tostring(self.total_sources) .. " 个书源", true)
    else
        collectgarbage("step", self.low_ram and 120 or 48)
    end
    self:_scheduleFill(delay)
end

function AsyncSourceSearch:_removeWorker(worker)
    if worker then self.workers[worker] = nil end
end

function AsyncSourceSearch:_completeWorker(worker, payload)
    if not worker or not self.workers[worker] then return end
    self:_removeWorker(worker)
    worker.finished = true
    self:_releaseWorkerBudget(worker)
    if not self.cancelled then self:_processSourceResult(worker.entry, payload) end
    if not self.paused then self:_continueAfterSource() end
    self:_finishIfIdle()
end

function AsyncSourceSearch:_reapWorker(worker, outcome, retry_entry)
    if not worker or worker.reaping then return end
    worker.reaping = true
    self.reaping_count = self.reaping_count + 1
    local function reap()
        if worker.reap_finalized then return end
        if ffiutil.isSubProcessDone(worker.pid) then
            worker.reap_finalized = true
            closeResultPipe(worker)
            self:_removeWorker(worker)
            self:_releaseWorkerBudget(worker)
            worker.finished = true
            self.reaping_count = math.max(0, self.reaping_count - 1)
            if retry_entry == "deferred" then
                if worker.entry and worker.entry.manual_priority == true then
                    self:_deferManualPriority(worker.entry)
                else
                    self:_deferEntry(worker.entry)
                end
            elseif retry_entry then self:_returnEntry(worker.entry) end
            if outcome and not self.cancelled then self:_processSourceResult(worker.entry, outcome) end
            if not self.paused and not self.cancelled then self:_continueAfterSource() end
            self:_finishIfIdle()
        else
            UIManager:scheduleIn(REAP_INTERVAL, reap)
        end
    end
    UIManager:scheduleIn(REAP_INTERVAL, reap)
end

function AsyncSourceSearch:_preemptWorker(worker, retry_entry)
    if not worker or not self.workers[worker] or worker.reap_finalized then return end
    if retry_entry == nil then retry_entry = true end

    if not worker.finished then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        self:_notifyProgress("前台操作优先；正在异步回收后台搜索进程", true)
    end

    -- Never call blocking waitpid from KOReader's UI thread. The foreground
    -- process ticket remains queued until this short non-blocking reaper releases
    -- the background ticket; AsyncBookOperation has its own bounded queue timeout.
    if not worker.reaping then self:_reapWorker(worker, nil, retry_entry) end
    return false
end

function AsyncSourceSearch:_spawnSource(holder, budget_ticket)
    self.pending[holder] = nil
    holder.ticket = nil
    if self.cancelled or self.finished or self.paused then
        ProcessBudget:release(budget_ticket)
        self:_returnEntry(holder.entry)
        return
    end
    local payload_path = SubprocessPayload:newPath("source-search-" .. tostring(holder.entry and holder.entry.id or ""),
        type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
    if self.low_ram then MemoryGuard:prepareForFork() else collectgarbage("step", 96) end
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local payload = executeSourceJob(holder.job)
        SubprocessPayload:write(write_fd, payload_path, payload, { max_bytes = RESULT_PAYLOAD_LIMIT })
    end, true)
    if not pid then
        SubprocessPayload:cleanup(payload_path)
        ProcessBudget:release(budget_ticket)
        self:_processSourceResult(holder.entry, {
            results = {}, error = tostring(result_fd_or_err or "无法启动单源搜索进程"),
            health = SourceHealth:record(holder.entry, "offline", nil, nil, "无法启动单源搜索进程"),
        })
        self:_continueAfterSource()
        return
    end
    local worker = {
        pid = pid,
        result_fd = result_fd_or_err,
        entry = holder.entry,
        started_at = socket.gettime(),
        deadline = sourceDeadline(holder.entry),
        finished = false,
        budget_ticket = budget_ticket,
        payload_path = payload_path,
    }
    self.workers[worker] = true
    budget_ticket.on_preempt = function() self:_preemptWorker(worker) end
    UIManager:scheduleIn(POLL_INTERVAL, function() self:_pollWorker(worker) end)
    self:_scheduleFill(0)
end

function AsyncSourceSearch:_requestEntry(entry)
    local job = {
        source_id = entry.id,
        source_name = entry.name,
        cached_health = entry.health,
        records_path = entry.records_path,
        record_offset = entry.record_offset,
        record_length = entry.record_length,
        book_title = self.book and self.book.title,
        book_author = self.book and self.book.author,
        keyword = self.keyword ~= "" and self.keyword or tostring(self.book and self.book.title or ""),
        mode = self.mode,
        manual_priority = entry.manual_priority == true,
        priority_score = entry.priority_score,
        inspect_limit = SearchSettings:getLimit(),
    }
    local holder = { entry = entry, job = job }
    self.pending[holder] = true
    local ticket
    ticket = ProcessBudget:request{
        owner = holder,
        label = self.mode == "global" and "global-source-search" or (self.mode .. "-source-search"),
        priority = self.process_priority,
        on_start = function(granted) self:_spawnSource(holder, granted) end,
        on_error = function(err)
            self.pending[holder] = nil
            self:_processSourceResult(entry, { results = {}, error = tostring(err) })
            self:_continueAfterSource()
        end,
    }
    if ticket.state == "queued" then holder.ticket = ticket end
end

function AsyncSourceSearch:_fillSlots()
    if self.cancelled or self.finished or self.paused then return end
    local memory_workers = MemoryGuard:recommendedBackgroundWorkers()
    local safe_limit = math.min(self.requested_parallel_workers or MAX_PARALLEL_WORKERS,
        math.max(1, tonumber(memory_workers or 1) or 1))
    if safe_limit < self.max_parallel_workers then
        self.max_parallel_workers = safe_limit
        local active = {}
        for worker in pairs(self.workers) do active[#active + 1] = worker end
        while #active > safe_limit do self:_preemptWorker(table.remove(active), true) end
    elseif safe_limit > self.max_parallel_workers then
        self.max_parallel_workers = safe_limit
    end
    if type(ffiutil.writeToFD) ~= "function" or type(ffiutil.readAllFromFD) ~= "function" then
        self:_addError("书源搜索", "当前 KOReader 版本无法开始搜索")
        self.queue_index = self.queue and #self.queue or 0
        self.retry_queue = {}
        self.deferred_retry_queue = {}
        self:_finishIfIdle()
        return
    end
    while self:_activeCount() + self:_pendingCount() < self.max_parallel_workers do
        local entry = self:_nextEntry()
        if not entry then break end
        self:_requestEntry(entry)
    end
    self:_finishIfIdle()
end

function AsyncSourceSearch:_pollWorker(worker)
    if self.cancelled or not worker or not self.workers[worker] or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        local payload, payload_err = readResultPayload(worker)
        if type(payload) ~= "table" then
            payload = { results = {}, error = tostring(payload_err or "单源搜索没有返回有效结果") }
        end
        self:_completeWorker(worker, payload)
    else
        local unsafe, memory_reason = MemoryGuard:backgroundChildUnsafe(worker.pid)
        if unsafe then
            worker.finished = true
            ffiutil.terminateSubProcess(worker.pid)
            self:_reapWorker(worker, {
                results = {}, skipped = true, resource_guard = true,
                error = "为防止 Kindle 内存不足已中止该书源：" .. tostring(memory_reason or "内存压力过高"),
            }, false)
            return
        end
        local deadline = tonumber(worker.deadline or SOURCE_DEADLINE) or SOURCE_DEADLINE
        if socket.gettime() - worker.started_at >= deadline then
            worker.finished = true
            ffiutil.terminateSubProcess(worker.pid)
            if worker.entry
                    and (worker.entry.fast_phase or worker.entry.manual_priority == true)
                    and not worker.entry.fast_retry_done
                    and not worker.entry.manual_priority_retry_done then
                -- A first-pass timeout is not a source failure. Automatic
                -- fast-phase entries go to the full-scan retry queue; a
                -- preferred entry is appended to its own insertion queue by
                -- the reaper, so it keeps its place among manual retries.
                if worker.entry.manual_priority ~= true then
                    worker.entry.fast_retry_done = true
                    self:_markFastAttempt(worker.entry)
                else
                    -- This first timeout has no result payload to pass through
                    -- _processSourceResult, but it is still one completed
                    -- attempt because the retry is counted separately.
                    self.completed_sources = self.completed_sources + 1
                    self:_deferManualPriority(worker.entry)
                end
                local stage = worker.entry.manual_priority == true
                    and "手动优先源首次未响应，已排到插队队列末尾重试"
                    or ("快速阶段暂未响应，已留到完整扫描再试 · "
                        .. tostring(self.fast_attempted_count) .. "/" .. tostring(self.fast_phase_count))
                self:_notifyProgress(stage, true)
                self:_reapWorker(worker, nil, "deferred")
            else
                self:_reapWorker(worker, {
                    results = {}, skipped = true,
                    error = "这条书源搜索超时（" .. tostring(SOURCE_DEADLINE) .. "秒）",
                    health = SourceHealth:record(worker.entry, "offline",
                        math.floor(SOURCE_DEADLINE * 1000), nil,
                        "这条书源搜索超时（" .. tostring(SOURCE_DEADLINE) .. "秒）"),
                }, false)
            end
        else
            UIManager:scheduleIn(POLL_INTERVAL, function() self:_pollWorker(worker) end)
        end
    end
end

function AsyncSourceSearch:start()
    if self.finished or self.cancelled or self.catalog_ticket or self.queue then return self end
    self:_notifyProgress("正在准备书源……", true)
    self.catalog_ticket = AsyncSourceCatalog:ensure(function(ok, err)
        self.catalog_ticket = nil
        if self.cancelled or self.finished then return end
        if not ok then
            self:_addError("书源索引", err)
            self.last_stage = "书源索引准备失败"
            self.finished = true
            if self.on_done then pcall(self.on_done, self.errors, self) end
            return
        end
        self:_prepareQueue()
    end)
    return self
end

function AsyncSourceSearch:setParallelLimit(limit)
    limit = math.max(1, math.min(MAX_PARALLEL_WORKERS, tonumber(limit or MAX_PARALLEL_WORKERS) or MAX_PARALLEL_WORKERS))
    self.requested_parallel_workers = limit
    local memory_workers = MemoryGuard:recommendedBackgroundWorkers()
    self.max_parallel_workers = math.min(limit, math.max(1, tonumber(memory_workers or 1) or 1))
    local active = {}
    for worker in pairs(self.workers) do active[#active + 1] = worker end
    while #active > limit do
        local worker = table.remove(active)
        self:_preemptWorker(worker, true)
    end
    if not self.paused and not self.cancelled and not self.finished then self:_scheduleFill(0.05) end
end

function AsyncSourceSearch:applySourcePreference()
    if self.cancelled or self.finished then return false end
    local old_main, old_preferred, old_deferred = {}, {}, {}
    local pending = {}
    if self.queue then
        for index = self.queue_index + 1, #self.queue do
            old_main[#old_main + 1] = self.queue[index]
            pending[#pending + 1] = self.queue[index]
        end
    end
    for _, entry in ipairs(self.manual_priority_queue or {}) do
        old_preferred[#old_preferred + 1] = entry
        pending[#pending + 1] = entry
    end
    for _, entry in ipairs(self.deferred_retry_queue or {}) do
        old_deferred[#old_deferred + 1] = entry
        pending[#pending + 1] = entry
    end

    local main, preferred, deferred = {}, {}, {}
    for _, entry in ipairs(manualQueueOrder(pending)) do
        local tier = SourcePreference:get(entry)
        if tier == SourcePreference.PRIORITY then
            preferred[#preferred + 1] = entry
        elseif tier == SourcePreference.LAST then
            deferred[#deferred + 1] = entry
        else
            main[#main + 1] = entry
        end
    end

    local function differs(left, right)
        if #left ~= #right then return true end
        for index, entry in ipairs(left) do
            if entry ~= right[index] then return true end
        end
        return false
    end

    local retry = manualQueueOrder(self.retry_queue)
    local changed = differs(main, old_main) or differs(preferred, old_preferred)
        or differs(deferred, old_deferred) or differs(retry, self.retry_queue)
    self.queue = main
    self.queue_index = 0
    self.manual_priority_queue = preferred
    self.manual_insert_next = false
    self.retry_queue, self.deferred_retry_queue = retry, deferred
    if changed and not self.paused then self:_scheduleFill(0) end
    return changed
end

function AsyncSourceSearch:pause(reason)
    if self.cancelled or self.finished or self.paused then return end
    self.paused = true
    self.pause_reason = tostring(reason or "前台任务优先")
    if self._fill_callback then
        pcall(UIManager.unschedule, UIManager, self._fill_callback)
        self._fill_callback = nil
    end
    for holder in pairs(self.pending) do
        if holder.ticket then ProcessBudget:cancel(holder.ticket) end
        self.pending[holder] = nil
        self:_returnEntry(holder.entry)
    end
    local active = {}
    for worker in pairs(self.workers) do active[#active + 1] = worker end
    for _, worker in ipairs(active) do self:_preemptWorker(worker, true) end
    self:_notifyProgress("后台搜索已暂停：" .. self.pause_reason, true)
end

function AsyncSourceSearch:resume()
    if self.cancelled or self.finished or not self.paused then return end
    self.paused = false
    self.pause_reason = nil
    self:_notifyProgress("继续后台搜索", true)
    self:_scheduleFill(0.05)
end

-- Expose only pure queue-ordering helpers for deterministic regression tests.
-- Production code never reads this table.
AsyncSourceSearch._test = {
    sourcePriorityScore = sourcePriorityScore,
    adaptiveQueueOrder = adaptiveQueueOrder,
    explorationSeeds = explorationSeeds,
    sourceDeadline = sourceDeadline,
    manualQueueOrder = manualQueueOrder,
}

function AsyncSourceSearch:cancel()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    pcall(SourceHealth.scheduleFlush, SourceHealth, 20)
    if self.catalog_ticket then
        AsyncSourceCatalog:cancel(self.catalog_ticket)
        self.catalog_ticket = nil
    end
    if self._fill_callback then
        pcall(UIManager.unschedule, UIManager, self._fill_callback)
        self._fill_callback = nil
    end
    for holder in pairs(self.pending) do
        if holder.ticket then ProcessBudget:cancel(holder.ticket) end
        self.pending[holder] = nil
    end
    local active = {}
    for worker in pairs(self.workers) do active[#active + 1] = worker end
    self.queue = nil
    self.manual_priority_queue = {}
    self.retry_queue = {}
    self.deferred_retry_queue = {}
    self.seen = {}
    for _, worker in ipairs(active) do
        self:_preemptWorker(worker, false)
    end
end

return AsyncSourceSearch
