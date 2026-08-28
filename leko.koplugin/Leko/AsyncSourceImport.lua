local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local Importer = require("Leko/Importer")
local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")
local Util = require("Leko/Util")

-- Large source packs must never be decoded/normalized in KOReader's UI process.
-- A foreground subprocess owns the whole transaction while the parent only polls
-- a tiny atomic status file. On low-memory Kindles this keeps the several-MiB
-- source JSON and its expanded Lua tables out of the long-lived UI heap.
local AsyncSourceImport = {
    poll_interval = 0.22,
    reap_interval = 0.25,
    hard_timeout = 180,
    queue_timeout = 12,
    process_priority = 115,
    result_payload_limit = 64 * 1024,
}

local function writeStatus(path, current, stage, total, cancellable)
    if not path then return end
    local payload = {
        current = tonumber(current or 0) or 0,
        total = tonumber(total or 5) or 5,
        stage = tostring(stage or "正在处理……"),
        cancellable = cancellable ~= false,
        updated_at = tonumber(socket.gettime()) or os.time(),
    }
    local ok, encoded = pcall(rapidjson.encode, payload)
    if ok then pcall(Util.writeFile, path, encoded, true) end
end

local function readStatus(path)
    if not path then return nil end
    local raw = Util.readFile(path, true)
    if not raw or raw == "" then return nil end
    local ok, payload = pcall(rapidjson.decode, raw)
    if ok and type(payload) == "table" then return payload end
    return nil
end

local function cleanupFiles(worker)
    if not worker then return end
    if worker.status_path then
        os.remove(worker.status_path)
        os.remove(worker.status_path .. ".tmp")
        worker.status_path = nil
    end
    SubprocessPayload:cleanup(worker.payload_path)
    worker.payload_path = nil
end

local function releaseBudget(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

local function safeTerminate(pid)
    if pid then pcall(ffiutil.terminateSubProcess, pid) end
end

local function dispatchState(worker, state, text, current, total, cancellable)
    if not worker or worker.cancelled or type(worker.on_state) ~= "function" then return end
    local callback = worker.on_state
    local function run()
        if not worker.cancelled then
            pcall(callback, state, text, current, total, cancellable, worker)
        end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

local function dispatchCallback(worker, ok, err, payload, on_complete)
    if not worker or worker.cancelled or type(worker.callback) ~= "function" then
        if on_complete then pcall(on_complete) end
        return
    end
    local callback = worker.callback
    local function run()
        if not worker.cancelled then pcall(callback, ok, err, worker, payload) end
        if on_complete then pcall(on_complete) end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

local function cleanError(err)
    local message = tostring(err or "书源导入失败")
    local trace_at = message:find("\nstack traceback:", 1, true)
    if trace_at then message = message:sub(1, trace_at - 1) end
    message = message:gsub("^.-%.lua:%d+:%s*", "", 1)
    return message
end

local function execute(job, write_fd)
    local payload = { ok = false }
    local function stage(current, text, total)
        -- During the final save/catalog commit, cancellation is deliberately
        -- disabled. Killing a process while it is replacing settings/catalog
        -- files is worse than waiting a few seconds for an atomic completion.
        local cancellable = tonumber(current or 0) < 4
        writeStatus(job.status_path, current, text, total, cancellable)
    end

    local ok, failure = xpcall(function()
        stage(1, job.kind == "url" and "下载书源……" or "读取本地书源文件……", 5)
        local options = {
            return_summary_only = true,
            suppress_sensitive_log = job.mobile == true,
            backup = job.backup ~= false,
            on_stage = function(current, text, total) stage(current, text, total) end,
        }
        local stats, import_err
        if job.kind == "url" then
            stats, import_err = Importer:importSourcesFromUrl(job.url, options)
        else
            stats, import_err = Importer:importSources(job.path, options)
        end
        if not stats then error(tostring(import_err or "书源导入失败")) end

        -- Drop the large source settings object before rebuilding its compact
        -- JSONL catalog. The rebuild can re-open the settings in the child, but
        -- the old rapidjson/normalization intermediates are already collectible.
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
        collectgarbage("collect")

        stage(5, "正在整理书源列表……", 5)
        local catalog_count, catalog_err = Storage:rebuildSourceCatalog()
        if not catalog_count then error(tostring(catalog_err or "书源索引构建失败")) end

        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
        pcall(Storage.releaseSourceCatalogCache, Storage)
        collectgarbage("collect")

        payload.ok = true
        payload.stats = stats
        payload.catalog_count = tonumber(catalog_count or 0) or 0
        stage(5, string.format("已导入 %d 个书源", tonumber(stats.total or 0) or 0), 5)
    end, function(err)
        if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
        return tostring(err)
    end)

    if not ok then
        payload.ok = false
        payload.error = cleanError(failure)
        payload.diagnostic_error = tostring(failure)
        writeStatus(job.status_path, 0, "导入失败", 5, true)
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
    end

    SubprocessPayload:write(write_fd, job.payload_path, payload, {
        max_bytes = AsyncSourceImport.result_payload_limit,
        inline_max_bytes = 3 * 1024,
    })
end

function AsyncSourceImport:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local payload, payload_err = SubprocessPayload:read(worker.result_fd, worker.payload_path, {
        max_bytes = self.result_payload_limit,
    })
    worker.result_fd = nil
    worker.payload_path = nil
    os.remove(worker.status_path or "")
    os.remove((worker.status_path or "") .. ".tmp")
    worker.status_path = nil

    if worker.cancelled then releaseBudget(worker); return end

    -- The child wrote source settings and catalog files. Purge every parent
    -- wrapper/cache that may still point at the pre-import generation before UI
    -- code asks for counts or starts a search.
    pcall(Storage.releaseSourceSettings, Storage)
    pcall(Storage.releaseSourceOverrideSettings, Storage)
    pcall(Storage.releaseSourceCatalogCache, Storage)
    collectgarbage("collect")

    local function release() releaseBudget(worker) end
    if type(payload) ~= "table" then
        dispatchCallback(worker, false, tostring(payload_err or "书源导入没有返回有效结果"), nil, release)
        return
    end
    if payload.ok ~= true then
        dispatchCallback(worker, false, tostring(payload.error or "书源导入失败"), payload, release)
        return
    end
    dispatchState(worker, "done", "书源导入完成", 5, 5, false)
    dispatchCallback(worker, true, nil, payload, release)
end

function AsyncSourceImport:_poll(worker)
    if not worker or worker.finished or worker.cancelled then return end
    local status = readStatus(worker.status_path)
    if status then
        worker.last_status = status
        worker.commit_started = status.cancellable == false or (tonumber(status.current or 0) or 0) >= 4
        local signature = table.concat({
            tostring(status.current or 0), tostring(status.total or 5),
            tostring(status.stage or ""), tostring(status.cancellable ~= false),
        }, "|")
        if signature ~= worker.last_status_signature then
            worker.last_status_signature = signature
            dispatchState(worker, "running", status.stage,
                status.current, status.total, status.cancellable ~= false)
        end
    end

    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
        return
    end
    if not worker.commit_started and type(MemoryGuard.backgroundChildUnsafe) == "function" then
        local unsafe, memory_reason = MemoryGuard:backgroundChildUnsafe(worker.pid)
        if unsafe then
            worker.finished = true
            safeTerminate(worker.pid)
            local visible_error = "为防止 Kindle 内存不足，已在写入书源前停止导入："
                .. tostring(memory_reason or "内存压力过高")
            local function reap_memory_abort()
                if ffiutil.isSubProcessDone(worker.pid) then
                    if worker.result_fd then pcall(ffiutil.readAllFromFD, worker.result_fd); worker.result_fd = nil end
                    cleanupFiles(worker)
                    releaseBudget(worker)
                    if not worker.cancelled then dispatchCallback(worker, false, visible_error, nil) end
                else
                    UIManager:scheduleIn(self.reap_interval, reap_memory_abort)
                end
            end
            UIManager:scheduleIn(self.reap_interval, reap_memory_abort)
            return
        end
    end
    if socket.gettime() - worker.started_at >= worker.timeout_seconds then
        worker.finished = true
        safeTerminate(worker.pid)
        local function reap()
            if ffiutil.isSubProcessDone(worker.pid) then
                if worker.result_fd then pcall(ffiutil.readAllFromFD, worker.result_fd); worker.result_fd = nil end
                cleanupFiles(worker)
                releaseBudget(worker)
                if not worker.cancelled then
                    dispatchCallback(worker, false, string.format("书源导入超过 %d 秒，已停止",
                        math.floor(worker.timeout_seconds)), nil)
                end
            else
                UIManager:scheduleIn(self.reap_interval, reap)
            end
        end
        UIManager:scheduleIn(self.reap_interval, reap)
        return
    end
    UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
end

function AsyncSourceImport:_watchQueued(worker)
    if not worker or worker.finished or worker.cancelled or not worker.pending then return end
    if worker.pid then return end
    if socket.gettime() - worker.queued_at >= worker.queue_timeout_seconds then
        worker.finished = true
        worker.pending = false
        if worker.budget_ticket then
            ProcessBudget:cancel(worker.budget_ticket)
            worker.budget_ticket = nil
        end
        cleanupFiles(worker)
        dispatchCallback(worker, false, "后台任务繁忙，书源导入排队超时")
        return
    end
    UIManager:scheduleIn(self.poll_interval, function() self:_watchQueued(worker) end)
end

function AsyncSourceImport:start(options, callback)
    options = options or {}
    local kind = options.kind == "url" and "url" or "file"
    if kind == "url" and tostring(options.url or "") == "" then return nil, "书源地址为空" end
    if kind == "file" and tostring(options.path or "") == "" then return nil, "书源文件为空" end
    if type(ffiutil.writeToFD) ~= "function" or type(ffiutil.readAllFromFD) ~= "function" then
        return nil, "当前 KOReader 版本无法导入这样大的书源文件"
    end

    -- Make the parent as lean as possible before fork. The child will open a
    -- fresh settings generation and the UI process will stay responsive.
    pcall(Storage.releaseSourceSettings, Storage)
    pcall(Storage.releaseSourceOverrideSettings, Storage)
    pcall(Storage.releaseSourceCatalogCache, Storage)
    collectgarbage("collect")
    MemoryGuard:prepareForFork()

    local tmp_dir = Storage:getCacheDir("tmp")
    Util.mkdirp(tmp_dir)
    local worker = {
        kind = kind,
        url = options.url,
        path = options.path,
        mobile = options.mobile == true,
        backup = options.backup ~= false,
        callback = callback,
        on_state = options.on_state,
        timeout_seconds = tonumber(options.timeout_seconds or self.hard_timeout) or self.hard_timeout,
        queue_timeout_seconds = tonumber(options.queue_timeout_seconds or self.queue_timeout) or self.queue_timeout,
        queued_at = socket.gettime(),
        pending = true,
        finished = false,
        cancelled = false,
        status_path = SubprocessPayload:newPath("source-import-status", tmp_dir),
        payload_path = SubprocessPayload:newPath("source-import-result", tmp_dir),
    }
    writeStatus(worker.status_path, 0, "等待后台任务槽位……", 5, true)

    local function spawn(granted)
        if worker.cancelled then ProcessBudget:release(granted); return end
        worker.budget_ticket = granted
        worker.pending = false
        local job = {
            kind = worker.kind,
            url = worker.url,
            path = worker.path,
            mobile = worker.mobile,
            backup = worker.backup,
            status_path = worker.status_path,
            payload_path = worker.payload_path,
        }
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
            execute(job, write_fd)
        end, true)
        if not pid then
            worker.finished = true
            cleanupFiles(worker)
            releaseBudget(worker)
            dispatchCallback(worker, false, tostring(result_fd_or_err or "无法启动书源导入进程"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.started_at = socket.gettime()
        dispatchState(worker, "running", kind == "url" and "下载书源……" or "读取本地书源文件……", 1, 5, true)
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    local ticket
    ticket = ProcessBudget:request{
        owner = worker,
        label = "foreground-source-import",
        priority = self.process_priority,
        lane = "foreground",
        on_start = function(granted) spawn(granted) end,
        on_error = function(err)
            worker.pending = false
            worker.finished = true
            cleanupFiles(worker)
            dispatchCallback(worker, false, tostring(err or "无法安排书源导入"))
        end,
    }
    if ticket.state == "queued" then
        worker.budget_ticket = ticket
        dispatchState(worker, "queued", "等待正在运行的后台搜索安全退出……", 0, 5, true)
        UIManager:scheduleIn(self.poll_interval, function() self:_watchQueued(worker) end)
    end
    return worker
end

function AsyncSourceImport:cancel(worker)
    if not worker or worker.finished or worker.cancelled then return true end
    -- Re-read the atomic status file synchronously here instead of trusting the
    -- last 220 ms poll. Otherwise a tap could race the child entering save() and
    -- terminate it after commit started but before the parent noticed.
    local fresh_status = readStatus(worker.status_path)
    if fresh_status and (fresh_status.cancellable == false
            or (tonumber(fresh_status.current or 0) or 0) >= 4) then
        worker.commit_started = true
    end
    -- Do not kill a writer in its commit section. TaskProgress understands a
    -- false return as "keep the dialog open" and will continue showing state.
    if worker.commit_started then
        dispatchState(worker, "committing", "正在安全提交书源，当前阶段不能中断", 4, 5, false)
        return false, "正在提交"
    end
    worker.cancelled = true
    if worker.pending and worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.pending = false
        worker.finished = true
        cleanupFiles(worker)
        return true
    end
    if not worker.pid then
        worker.finished = true
        cleanupFiles(worker)
        releaseBudget(worker)
        return true
    end
    safeTerminate(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            worker.finished = true
            if worker.result_fd then pcall(ffiutil.readAllFromFD, worker.result_fd); worker.result_fd = nil end
            cleanupFiles(worker)
            releaseBudget(worker)
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
    return true
end

return AsyncSourceImport
