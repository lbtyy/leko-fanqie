local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local BookOperationSpec = require("Leko/BookOperationSpec")
local Diagnostics = require("Leko/Diagnostics")
local BookService = require("Leko/BookService")
local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")

local AsyncBookOperation = {
    poll_interval = 0.18,
    reap_interval = 0.25,
    hard_timeout = 45,
    process_priority = 90,
    result_payload_limit = 512 * 1024,
    queue_poll_interval = 0.20,
    queue_timeout = 8,
}

local function cleanupProgress(worker)
    if worker and worker.progress_path then
        os.remove(worker.progress_path)
        os.remove(worker.progress_path .. ".new")
        worker.progress_path = nil
    end
end

local function writeProgress(path, current, total, stage)
    if not path then return end
    stage = tostring(stage or ""):gsub("[\r\n\t]", " ")
    local temp = path .. ".new"
    local file = io.open(temp, "wb")
    if not file then return end
    file:write(tostring(current or 0), "\t", tostring(total or 1), "\t", stage)
    file:close()
    os.remove(path)
    os.rename(temp, path)
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
    if not worker then return nil, "书籍后台任务不存在" end
    local fd = worker.result_fd
    worker.result_fd = nil
    local path = worker.payload_path
    worker.payload_path = nil
    return SubprocessPayload:read(fd, path, { max_bytes = AsyncBookOperation.result_payload_limit })
end

local function releaseBudget(worker)
    cleanupProgress(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

local function dispatchCallback(worker, ok, err, payload, book, on_complete)
    if not worker or not worker.callback then
        if on_complete then pcall(on_complete) end
        return
    end
    local callback = worker.callback
    worker.callback_pending = true
    local function run()
        worker.callback_pending = false
        if not worker.cancelled then pcall(callback, ok, err, worker, payload, book) end
        if on_complete then pcall(on_complete) end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

local function dispatchState(worker, state, text, current, total)
    if not worker or type(worker.on_state) ~= "function" or worker.cancelled then return end
    local callback = worker.on_state
    local function run()
        if not worker.cancelled then pcall(callback, state, text, current, total, worker) end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

local function readProgress(worker)
    if not worker or not worker.progress_path then return end
    local file = io.open(worker.progress_path, "rb")
    if not file then return end
    local value = file:read("*a"); file:close()
    if value == "" or value == worker.last_progress then return end
    local current, total, stage = value:match("^(%d+)\t(%d+)\t(.*)$")
    if not current then return end
    worker.last_progress = value
    dispatchState(worker, "running", stage, tonumber(current), tonumber(total))
end

local function cleanOperationError(err)
    local message = tostring(err or "书籍后台任务失败")
    local trace_at = message:find("\nstack traceback:", 1, true)
    if trace_at then message = message:sub(1, trace_at - 1) end
    message = message:gsub("^.-%.lua:%d+:%s*", "", 1)
    return message
end

local function execute(job)
    local payload = { ok = false }
    local ok, err = xpcall(function()
        if job.operation == "prepare" then
            local book, book_err = BookService:prepareSearchResult(job.result)
            if not book then error(tostring(book_err or "无法准备书籍")) end
            payload.ok = true
            payload.book_id = book.id
        elseif job.operation == "prepare-reading" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local ready, read_err = BookService:prepareReading(book, job.chapter_index)
            if not ready then error(tostring(read_err or "试读章节准备失败")) end
            payload.ok = true
            payload.book_id = ready.id
            payload.chapter_index = ready.position and ready.position.chapter or job.chapter_index
            payload.load_toc = true
            payload.parent_load_delay = 0.30
        elseif job.operation == "prepare-chapter" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local chapter_index = tonumber(job.chapter_index
                or (book.position and book.position.chapter) or 1) or 1
            local ready, chapter_err = BookService:ensureChapter(book, chapter_index, {
                persist_metadata = false,
            })
            if not ready then error(tostring(chapter_err or "目标章节准备失败")) end
            book.position = book.position or {}
            book.position.chapter = chapter_index
            local chapter = book.chapters and book.chapters[chapter_index]
            book.position.chapter_id = chapter and chapter.id or nil
            payload.ok = true
            payload.book_id = book.id
            payload.chapter_index = chapter_index
            payload.load_toc = true
        elseif job.operation == "redownload-chapter" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local chapter_index = tonumber(job.chapter_index
                or (book.position and book.position.chapter) or 1) or 1
            local ready, chapter_err = BookService:ensureChapter(book, chapter_index, {
                persist_metadata = false,
                force_network = true,
            })
            if not ready then error(tostring(chapter_err or "本章刷新失败")) end
            book.position = book.position or {}
            book.position.chapter = chapter_index
            local chapter = book.chapters and book.chapters[chapter_index]
            book.position.chapter_id = chapter and chapter.id or nil
            payload.ok = true
            payload.book_id = book.id
            payload.chapter_index = chapter_index
            payload.load_toc = true
            payload.redownloaded = true
        elseif job.operation == "prepare-toc" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local ready, toc_err = BookService:ensureToc(book)
            if not ready then error(tostring(toc_err or "目录准备失败")) end
            payload.ok = true
            payload.book_id = ready.id
            payload.load_toc = true
        elseif job.operation == "switch-source" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local updated, switch_err, warning = BookService:switchContentSource(book, job.result, nil, {
                prepare_chapter = true,
            })
            if not updated then error(tostring(switch_err or "内容源切换失败")) end
            payload.ok = true
            payload.book_id = updated.id
            payload.warning = warning
            payload.load_toc = true
        elseif job.operation == "refresh-toc" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local updated, refresh_err, change = BookService:refreshToc(book)
            if not updated then error(tostring(refresh_err or "目录刷新失败")) end
            payload.ok = true
            payload.book_id = updated.id
            payload.load_toc = true
            payload.toc_change = change
        elseif job.operation == "apply-cover" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local path, cover_err = BookService:setCoverFromSearchResult(book, job.result)
            if not path then error(tostring(cover_err or "封面应用失败")) end
            payload.ok = true
            payload.book_id = book.id
            payload.cover_path = path
            payload.load_toc = false
        elseif job.operation == "reload-cover" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            local path, cover_err = BookService:reloadNetworkCover(book)
            if not path then error(tostring(cover_err or "网络封面刷新失败")) end
            payload.ok = true
            payload.book_id = book.id
            payload.cover_path = path
            payload.load_toc = false
        elseif job.operation == "export-book" then
            local book, load_err = Storage:loadBook(job.book_id)
            if not book then error(tostring(load_err or "无法读取当前书籍")) end
            -- Export is uncommon and relatively large; keep its writer and ZIP
            -- tables out of every ordinary foreground child.
            local BookExporter = require("Leko/BookExporter")
            local path, export_err, export_meta = BookExporter:export(book, job.export_format, function(current, total, stage)
                writeProgress(job.progress_path, current, total, stage)
            end)
            if not path then error(tostring(export_err or "书籍导出失败")) end
            payload.ok = true
            payload.book_id = book.id
            payload.export_path = path
            payload.export_format = job.export_format
            payload.export_warning = export_meta and export_meta.cover_warning or nil
            payload.load_toc = false
        else
            error("未知书籍后台任务")
        end
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
    end, function(failure)
        if debug and debug.traceback then return debug.traceback(tostring(failure), 2) end
        return tostring(failure)
    end)
    if not ok then
        payload.ok = false
        payload.diagnostic_error = tostring(err)
        payload.error = cleanOperationError(err)
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
    end
    return payload
end

function AsyncBookOperation:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local spec = worker.spec or BookOperationSpec:get(worker.operation)
    dispatchState(worker, "handoff", spec.handoff, 2, spec.total)
    local payload, payload_err = readResultPayload(worker)
    if worker.cancelled then releaseBudget(worker); return end
    local function release() releaseBudget(worker) end
    if type(payload) ~= "table" then
        dispatchCallback(worker, false, tostring(payload_err or "书籍后台任务没有返回有效结果"), nil, nil, release)
        return
    end
    if payload.ok ~= true then
        local visible_error = tostring(payload.error or "书籍后台任务失败")
        if payload.diagnostic_error then
            local diagnostic_path = Diagnostics:record("foreground-book-operation", payload.diagnostic_error)
            payload.diagnostic_path = diagnostic_path
            if diagnostic_path then
                visible_error = visible_error .. "\n\n详细错误已保存到：" .. diagnostic_path
            end
        end
        dispatchCallback(worker, false, visible_error, payload, nil, release)
        return
    end
    if type(worker.on_payload_ready) == "function" then
        pcall(worker.on_payload_ready, worker, payload)
    end
    if worker.cancelled then release(); return end
    local function loadParentBook()
        if worker.cancelled then release(); return end
        dispatchState(worker, "loading", spec.loading, 3, spec.total)
        collectgarbage("collect")
        local book, load_err = Storage:loadBook(payload.book_id, { load_toc = payload.load_toc ~= false })
        if not book then
            dispatchCallback(worker, false, tostring(load_err or "任务完成但无法读取书籍"), payload, nil, release)
            return
        end
        -- Disk preparation and UI presentation are separate states. The final
        -- visible completion belongs to the coordinator that owns the reader or
        -- mutation UI, not to this subprocess transport layer.
        dispatchState(worker, "layout", spec.layout, 3, spec.total)
        dispatchCallback(worker, true, nil, payload, book, release)
    end
    local delay = tonumber(payload.parent_load_delay or 0) or 0
    if delay > 0 then UIManager:scheduleIn(delay, loadParentBook) else loadParentBook() end
end

function AsyncBookOperation:_poll(worker)
    if not worker or worker.finished then return end
    readProgress(worker)
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
    elseif socket.gettime() - worker.started_at >= worker.timeout_seconds then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        local function finishTimeout()
            closeResultPipe(worker)
            releaseBudget(worker)
            if not worker.cancelled then
                dispatchCallback(worker, false,
                    "打开书籍超时（" .. tostring(worker.timeout_seconds) .. "秒）",
                    { timed_out = true })
            end
        end
        local function reap()
            if ffiutil.isSubProcessDone(worker.pid) then finishTimeout()
            else UIManager:scheduleIn(self.reap_interval, reap) end
        end
        UIManager:scheduleIn(self.reap_interval, reap)
    else
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
end

function AsyncBookOperation:_watchPending(worker)
    if not worker or worker.finished or worker.cancelled or not worker.pending then return end
    local elapsed = socket.gettime() - (worker.requested_at or socket.gettime())
    if elapsed >= 0.35 and not worker.waiting_reported then
        worker.waiting_reported = true
        dispatchState(worker, "waiting", worker.spec.queued, 0, worker.spec.total)
    end
    if elapsed >= worker.queue_timeout_seconds then
        worker.finished = true
        worker.pending = false
        if worker.budget_ticket then
            ProcessBudget:cancel(worker.budget_ticket)
            worker.budget_ticket = nil
        end
        dispatchCallback(worker, false,
            "后台搜书进程未能在限定时间内释放，已安全中止本次前台任务；当前页面仍可继续操作。")
        return
    end
    UIManager:scheduleIn(self.queue_poll_interval, function() self:_watchPending(worker) end)
end

function AsyncBookOperation:start(job, callback)
    if type(job) ~= "table" or not job.operation then return nil, "书籍后台任务参数不完整" end
    if type(job.book) == "table" then
        local saved, save_err = BookService:persistTrialMetadata(job.book)
        if not saved then return nil, "无法保存试读信息：" .. tostring(save_err) end
    end
    local compact_job = {
        operation = job.operation,
        book_id = job.book_id,
        chapter_index = tonumber(job.chapter_index),
        force_network = job.force_network == true,
        export_format = job.export_format,
        progress_path = job.operation == "export-book" and os.tmpname() or nil,
        -- The selected candidate carries executable ruleSearch context. Fork
        -- with the complete table; never shrink variables/Cookie/login state to
        -- satisfy an IPC control-message limit.
        result = job.result,
    }
    local spec = BookOperationSpec:get(job.operation)
    local worker = {
        callback = callback,
        cancelled = false,
        finished = false,
        pending = true,
        timeout_seconds = math.max(10,
            tonumber(job.timeout_seconds or spec.timeout_seconds or self.hard_timeout) or self.hard_timeout),
        on_payload_ready = job.on_payload_ready,
        on_state = job.on_state,
        on_cancel = job.on_cancel,
        on_preempt = job.on_preempt,
        operation = job.operation,
        progress_path = compact_job.progress_path,
        spec = spec,
        requested_at = socket.gettime(),
        queue_timeout_seconds = math.max(3,
            tonumber(job.queue_timeout_seconds or spec.queue_timeout_seconds or self.queue_timeout)
                or self.queue_timeout),
    }

    local function spawn(ticket)
        worker.pending = false
        worker.budget_ticket = ticket
        dispatchState(worker, "running", worker.spec.running, 1, worker.spec.total)
        if worker.cancelled then worker.finished = true; releaseBudget(worker); return end
        pcall(BookService.clearTransientMemory, BookService)
        MemoryGuard:prepareForFork()
        local payload_path = SubprocessPayload:newPath("book-operation-" .. tostring(job.operation or ""),
            type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
            SubprocessPayload:write(write_fd, payload_path, execute(compact_job),
                { max_bytes = AsyncBookOperation.result_payload_limit })
        end, true)
        if not pid then
            SubprocessPayload:cleanup(payload_path)
            worker.finished = true
            releaseBudget(worker)
            dispatchCallback(worker, false,
                tostring(result_fd_or_err or "无法启动书籍后台任务"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.payload_path = payload_path
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    local lane = "foreground"
    if job.background then lane = "background" end
    if job.lane then lane = job.lane end
    local ticket
    ticket = ProcessBudget:request{
        owner = worker,
        label = job.label or (job.background and "background-book-operation" or "foreground-book-operation"),
        priority = tonumber(job.priority or (job.background and 1 or self.process_priority))
            or (job.background and 1 or self.process_priority),
        lane = lane,
        on_start = function(granted) spawn(granted) end,
        on_preempt = function()
            self:cancel(worker, "preempted")
        end,
        on_error = function(err)
            worker.pending = false
            worker.finished = true
            dispatchCallback(worker, false, tostring(err))
        end,
    }
    if ticket.state == "queued" then
        worker.budget_ticket = ticket
        dispatchState(worker, "queued", worker.spec.queued, 0, worker.spec.total)
        UIManager:scheduleIn(self.queue_poll_interval, function() self:_watchPending(worker) end)
    end
    return worker
end

function AsyncBookOperation:cancel(worker, reason)
    if not worker or worker.cancelled then return end
    worker.cancelled = true
    worker.cancel_reason = reason or "cancelled"
    if worker.finished then return end
    if worker.pending and worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.pending = false
        worker.finished = true
        cleanupProgress(worker)
        if type(worker.on_cancel) == "function" then
            pcall(worker.on_cancel, worker.cancel_reason or "cancelled", worker)
        end
        return
    end
    if not worker.pid then
        worker.finished = true
        releaseBudget(worker)
        if type(worker.on_cancel) == "function" then
            pcall(worker.on_cancel, worker.cancel_reason or "cancelled", worker)
        end
        return
    end
    ffiutil.terminateSubProcess(worker.pid)
    local function finishCancel()
        worker.finished = true
        closeResultPipe(worker)
        releaseBudget(worker)
        if type(worker.on_cancel) == "function" then
            pcall(worker.on_cancel, worker.cancel_reason or "cancelled", worker)
        end
    end
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then finishCancel()
        else UIManager:scheduleIn(self.reap_interval, reap) end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

return AsyncBookOperation
