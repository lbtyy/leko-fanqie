local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local CoverService = require("Leko/CoverService")
local BookIdentity = require("Leko/BookIdentity")
local LegadoSource = require("Leko/LegadoSource")
local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")
local SubprocessPayload = require("Leko/SubprocessPayload")

local AsyncCoverFetch = {
    poll_interval = 0.18,
    reap_interval = 0.25,
    hard_timeout = 18,
    process_priority = 100,
    result_payload_limit = 2 * 1024 * 1024,
}

local function removePath(path)
    if path and lfs.attributes(path) then os.remove(path) end
end

local function compactSource(source)
    if not source then return nil end
    return {
        id = source.id,
        name = source.name,
        base_url = source.base_url,
        header = source.header,
        cookies = source.cookies,
        variables = source.variables,
        login_header = source.login_header,
        enabled_cookie_jar = source.enabled_cookie_jar,
    }
end

local function compactRuntime(source, fallback)
    if source then
        return {
            cookies = source.cookies,
            variables = source.variables,
            login_header = source.login_header,
        }
    end
    return fallback
end

local function applyRuntime(source, runtime)
    if type(source) ~= "table" or type(runtime) ~= "table" then return source end
    if type(runtime.cookies) == "table" then source.cookies = runtime.cookies end
    if type(runtime.variables) == "table" then source.variables = runtime.variables end
    if runtime.login_header ~= nil then source.login_header = runtime.login_header end
    return source
end

local function compactResult(result, source)
    return {
        title = tostring(result and result.title or ""),
        author = tostring(result and result.author or ""),
        book_url = result and result.book_url or nil,
        toc_url = result and result.toc_url or nil,
        cover = result and result.cover or nil,
        source_id = source and source.id or (result and result.source_id),
        source_name = source and source.name or (result and result.source_name),
        variables = result and result.variables or nil,
        _cover_source = compactSource(source) or (result and result._cover_source),
        _source_runtime = compactRuntime(source, result and result._source_runtime),
        _source_record = result and result._source_record or nil,
    }
end

local function cleanupTemporaryImages(worker)
    if not worker or not worker.temp_suffix then return end
    local dir = Storage:getCacheDir("images")
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:find(worker.temp_suffix, 1, true) then
            removePath(Util.joinPath(dir, name))
        end
    end
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
    if not worker then return nil, "后台封面任务不存在" end
    local fd = worker.result_fd
    worker.result_fd = nil
    local path = worker.payload_path
    worker.payload_path = nil
    return SubprocessPayload:read(fd, path, { max_bytes = AsyncCoverFetch.result_payload_limit })
end

local function cleanup(worker)
    if not worker then return end
    cleanupTemporaryImages(worker)
    SubprocessPayload:cleanup(worker.payload_path)
    worker.payload_path = nil
end


local function releaseBudget(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

local function dispatchCallback(worker, ok, err, payload, on_complete)
    if not worker or not worker.callback then
        if on_complete then pcall(on_complete) end
        return
    end
    local callback = worker.callback
    worker.callback_pending = true
    local function run()
        worker.callback_pending = false
        if not worker.cancelled then pcall(callback, ok, err, worker, payload) end
        if on_complete then pcall(on_complete) end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

function AsyncCoverFetch:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local payload, payload_err = readResultPayload(worker)
    if worker.cancelled then releaseBudget(worker); cleanup(worker); return end
    local function release() releaseBudget(worker) end
    if type(payload) ~= "table" then
        cleanup(worker)
        dispatchCallback(worker, false, tostring(payload_err or "后台封面任务未返回完整结果"), nil, release)
        return
    end
    cleanup(worker)
    if payload.ok == true then
        dispatchCallback(worker, true, nil, payload, release)
    else
        dispatchCallback(worker, false, tostring(payload.error or "封面下载失败"), payload, release)
    end
end

function AsyncCoverFetch:_timeout(worker, reason, resource_guard)
    if not worker or worker.finished then return end
    worker.finished = true
    worker.timed_out = not resource_guard
    ffiutil.terminateSubProcess(worker.pid)
    local message = reason or ("封面候选硬超时（"
        .. tostring(worker.timeout_seconds or self.hard_timeout) .. "秒），已自动跳过")
    dispatchCallback(worker, false, message, {
        timed_out = not resource_guard,
        resource_guard = resource_guard == true,
    })
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            releaseBudget(worker)
            cleanup(worker)
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncCoverFetch:_poll(worker)
    if not worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
    else
        if type(MemoryGuard.backgroundChildUnsafe) == "function" then
            local unsafe, memory_reason = MemoryGuard:backgroundChildUnsafe(worker.pid)
            if unsafe then
                self:_timeout(worker, "为防止 Kindle 内存不足已跳过这个封面："
                    .. tostring(memory_reason or "内存压力过高"), true)
                return
            end
        end
        if socket.gettime() - worker.started_at >= worker.timeout_seconds then
            self:_timeout(worker)
        else
            UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
        end
    end
end

function AsyncCoverFetch:start(job, callback)
    if not job or not job.result then return nil, "封面任务参数不完整" end
    local result = job.result
    if tostring(result.cover or "") == "" and not result.source_id then
        return nil, "这条封面结果的信息不完整"
    end
    local width = math.max(1, math.floor(tonumber(job.width or 360) or 360))
    local height = math.max(1, math.floor(tonumber(job.height or 520) or 520))
    local worker = {
        callback = callback,
        cancelled = false,
        finished = false,
        pending = true,
        timeout_seconds = math.max(5, tonumber(job.timeout_seconds or self.hard_timeout) or self.hard_timeout),
    }

    local function spawn(budget_ticket)
        worker.pending = false
        worker.budget_ticket = budget_ticket
        if worker.cancelled then
            worker.finished = true
            releaseBudget(worker)
            return
        end
        MemoryGuard:prepareForFork()
        local payload_path = SubprocessPayload:newPath("cover-fetch-" .. tostring(result.source_id or ""),
            type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(child_pid, write_fd)
        local temp_suffix = ".prefetch-" .. tostring(child_pid)
        local payload = { ok = false, attempts = {} }
        local ok, err = xpcall(function()
            local resolved = result
            local source = applyRuntime(result._cover_source, result._source_runtime)
            if source then source._suppress_runtime_persist = true end
            local full_source

            local function remember(stage, success, detail, candidate)
                payload.attempts[#payload.attempts + 1] = {
                    stage = stage, ok = success == true, error = success and nil or tostring(detail or "失败"),
                    cover = tostring(candidate and candidate.cover or ""),
                }
            end

            local function loadFullSource()
                if full_source then return full_source end
                if not result.source_id then return nil, "这条封面结果缺少来源信息" end
                local ref = result._source_record
                if type(ref) == "table" and ref.records_path and ref.record_offset ~= nil
                        and ref.record_length ~= nil then
                    full_source = Storage:readSourceRecord(ref.records_path, ref.record_offset,
                        ref.record_length, result.source_id, true)
                end
                if not full_source then
                    full_source = Storage:getSource(result.source_id)
                    if full_source then Storage:hydrateSourceRuntime(full_source) end
                end
                if not full_source then return nil, "找不到封面所属书源" end
                applyRuntime(full_source, result._source_runtime)
                full_source._suppress_runtime_persist = true
                return full_source
            end

            local function tryPrefetch(candidate, request_source, stage)
                local fetched, fetch_err = CoverService:prefetch(candidate, width, height, request_source, temp_suffix,
                    { force = job.force == true })
                remember(stage, fetched ~= nil, fetch_err, candidate)
                return fetched, fetch_err
            end

            -- Fast path: a search-list cover with its compact request context can
            -- be shown without loading the full source pack.
            local direct_error
            if tostring(resolved.cover or "") ~= "" then
                if not source then
                    source = loadFullSource()
                end
                local fetched, fetch_err = tryPrefetch(resolved, source, "search-cover")
                if fetched then
                    Storage:releaseSourceSettings()
                    payload.ok = true
                    payload.result = compactResult(resolved, source)
                    return
                end
                direct_error = tostring(fetch_err or "搜索结果封面下载失败")
            end

            -- Search-list cover fields are frequently empty, stale, placeholders
            -- or anti-hotlink responses in imported source packs. Resolve the actual
            -- detail page and retry instead of declaring the whole source unusable.
            local detail_source, source_err = loadFullSource()
            if not detail_source then
                payload.error = direct_error or tostring(source_err or "找不到封面所属书源")
                Storage:releaseSourceSettings()
                return
            end
            local detail_seed = compactResult(result, detail_source)
            detail_seed.cover = nil
            local info, info_err = LegadoSource:getBookInfo(detail_source, detail_seed, {
                require_cover = true,
                refresh_cover = true,
                cache_write = false,
                save_runtime = false,
            })
            if not info then
                payload.error = direct_error
                    and (direct_error .. "；详情回退失败：" .. tostring(info_err or "详情读取失败"))
                    or tostring(info_err or "书籍详情没有返回封面")
                Storage:releaseSourceSettings()
                return
            end
            if not BookIdentity:sameTitle(result.title, info.title) then
                payload.error = "详情页书名与当前书籍不一致，已跳过该封面"
                Storage:releaseSourceSettings()
                return
            end
            resolved = compactResult(info, detail_source)
            resolved.author_mismatch = BookIdentity:authorDiffers(result.author, info.author)
            if tostring(resolved.cover or "") == "" then
                payload.error = direct_error
                    and (direct_error .. "；书籍详情也没有提供封面")
                    or "书籍详情没有提供封面"
                Storage:releaseSourceSettings()
                return
            end

            local fetched, fetch_err = tryPrefetch(resolved, detail_source, "detail-cover")
            Storage:releaseSourceSettings()
            if not fetched then
                payload.error = direct_error
                    and (direct_error .. "；详情封面仍失败：" .. tostring(fetch_err or "封面下载失败"))
                    or tostring(fetch_err or "封面下载失败")
                return
            end
            payload.ok = true
            payload.result = compactResult(resolved, detail_source)
        end, debug.traceback)
        if not ok then
            pcall(Storage.releaseSourceSettings, Storage)
            payload.error = tostring(err)
        end
        SubprocessPayload:write(write_fd, payload_path, payload,
            { max_bytes = AsyncCoverFetch.result_payload_limit })
    end, true)
        if not pid then
            SubprocessPayload:cleanup(payload_path)
            worker.finished = true
            releaseBudget(worker)
            dispatchCallback(worker, false,
                tostring(result_fd_or_err or "无法启动后台封面进程"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.payload_path = payload_path
        worker.temp_suffix = ".prefetch-" .. tostring(pid)
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    local ticket
    ticket = ProcessBudget:request{
        owner = worker,
        label = "foreground-cover",
        priority = self.process_priority,
        lane = "foreground",
        on_start = function(granted) spawn(granted) end,
        on_error = function(err)
            worker.pending = false
            worker.finished = true
            dispatchCallback(worker, false, tostring(err))
        end,
    }
    if ticket.state == "queued" then worker.budget_ticket = ticket end
    return worker
end

function AsyncCoverFetch:cancel(worker)
    if not worker or worker.cancelled then return end
    worker.cancelled = true
    if worker.finished then return end
    if worker.pending and worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.pending = false
        worker.finished = true
        cleanup(worker)
        return
    end
    if not worker.pid then
        releaseBudget(worker)
        worker.finished = true
        cleanup(worker)
        return
    end
    ffiutil.terminateSubProcess(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            worker.finished = true
            closeResultPipe(worker)
            releaseBudget(worker)
            cleanup(worker)
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

return AsyncCoverFetch
