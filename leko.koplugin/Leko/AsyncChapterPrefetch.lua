local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local LegadoSource = require("Leko/LegadoSource")
local ProcessBudget = require("Leko/ProcessBudget")
local Util = require("Leko/Util")
local SubprocessPayload = require("Leko/SubprocessPayload")

local AsyncChapterPrefetch = {
    poll_interval = 0.18,
    reap_interval = 0.25,
    hard_timeout = 24,
    process_priority = 10,
    result_payload_limit = 1024 * 1024,
}


local function removeArtifacts(worker)
    if not worker then return end
    for _, path in ipairs({
        worker.temp_path,
        worker.temp_path and (worker.temp_path .. ".tmp") or nil,
        worker.result_payload_path,
        worker.result_payload_path and (worker.result_payload_path .. ".tmp") or nil,
    }) do
        if path and lfs.attributes(path) then os.remove(path) end
    end
end

local function readResult(worker)
    if not worker then return nil, "后台任务未返回结果" end
    local fd = worker.result_fd
    worker.result_fd = nil
    local path = worker.result_payload_path
    worker.result_payload_path = nil
    return SubprocessPayload:read(fd, path, { max_bytes = AsyncChapterPrefetch.result_payload_limit })
end

local function closeResultPipe(worker)
    if not worker then return end
    if worker.result_fd then
        local fd = worker.result_fd
        worker.result_fd = nil
        pcall(ffiutil.readAllFromFD, fd)
    end
    SubprocessPayload:cleanup(worker.result_payload_path)
    worker.result_payload_path = nil
end


local function releaseBudget(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

local function dispatchCallback(worker, ok, err, result)
    if not worker or not worker.callback or worker.cancelled then return end
    local callback = worker.callback
    worker.callback_pending = true
    local function run()
        worker.callback_pending = false
        if worker.cancelled then return end
        callback(ok, err, worker, result)
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

function AsyncChapterPrefetch:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local result, result_err = readResult(worker)
    releaseBudget(worker)
    if worker.cancelled then
        removeArtifacts(worker)
        return
    end
    if not result then
        removeArtifacts(worker)
        dispatchCallback(worker, false, result_err)
        return
    end
    if result.ok ~= true then
        local err = tostring(result.error or "章节预缓存失败")
        removeArtifacts(worker)
        dispatchCallback(worker, false, err, result)
        return
    end
    -- The child writes to a PID-scoped temporary file. Only the parent promotes
    -- it to the deterministic chapter path, so a cancelled child can never leave
    -- a partially downloaded chapter looking valid.
    if lfs.attributes(worker.final_path, "mode") ~= "file" then
        local renamed, rename_err = os.rename(worker.temp_path, worker.final_path)
        if not renamed then
            removeArtifacts(worker)
            dispatchCallback(worker, false, tostring(rename_err or "无法提交预缓存章节"), result)
            return
        end
    else
        os.remove(worker.temp_path)
    end
    dispatchCallback(worker, true, nil, result)
end

function AsyncChapterPrefetch:_poll(worker)
    if not worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
        return
    end
    if socket.gettime() - worker.started_at >= worker.timeout_seconds then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        local function reap()
            if ffiutil.isSubProcessDone(worker.pid) then
                closeResultPipe(worker)
                releaseBudget(worker)
                removeArtifacts(worker)
                if not worker.cancelled then
                    dispatchCallback(worker, false,
                        "后台下载相邻章节超时（" .. tostring(worker.timeout_seconds) .. "秒）",
                        { timed_out = true })
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

function AsyncChapterPrefetch:start(job, callback)
    if not job or not job.source or not job.book or not job.chapter_index or not job.final_path then
        return nil, "后台预缓存参数不完整"
    end
    local source = job.source
    local book = job.book
    local chapter_index = tonumber(job.chapter_index)
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end
    local final_path = job.final_path
    local worker = {
        callback = callback,
        final_path = final_path,
        chapter_index = chapter_index,
        cancelled = false,
        finished = false,
        pending = true,
        timeout_seconds = math.max(8, tonumber(job.timeout_seconds or self.hard_timeout) or self.hard_timeout),
    }

    local function spawn(budget_ticket)
        worker.pending = false
        worker.budget_ticket = budget_ticket
        if worker.cancelled then
            worker.finished = true
            releaseBudget(worker)
            return
        end
        local result_payload_path = SubprocessPayload:newPath("chapter-prefetch-" .. tostring(book.id or ""),
            tostring(final_path):match("^(.*)/[^/]+$") or "/tmp")
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(child_pid, write_fd)
        local temp_path = final_path .. ".prefetch-" .. tostring(child_pid)
        local result = {
            ok = false,
            chapter_index = chapter_index,
        }
        local ok, err = xpcall(function()
            local content, fetch_err = LegadoSource:getContent(source, book, chapter)
            if not content then
                result.error = tostring(fetch_err or "正文下载失败")
                return
            end
            local write_ok, write_err = Util.writeFile(temp_path, Util.normalizeText(content))
            if not write_ok then
                result.error = tostring(write_err or "预缓存文件写入失败")
                return
            end
            result.ok = true
            -- Legado rules may update per-book or per-chapter variables while
            -- resolving the content URL. Return simple state to the parent.
            result.book_variables = type(book.variables) == "table" and book.variables or nil
            result.chapter_variables = type(chapter.variables) == "table" and chapter.variables or nil
        end, debug.traceback)
        if not ok then result.error = tostring(err) end
        SubprocessPayload:write(write_fd, result_payload_path, result,
            { max_bytes = AsyncChapterPrefetch.result_payload_limit })
    end, true)
        if not pid then
            SubprocessPayload:cleanup(result_payload_path)
            worker.finished = true
            releaseBudget(worker)
            dispatchCallback(worker, false,
                tostring(result_fd_or_err or "无法启动后台预缓存进程"))
            return
        end
        worker.pid = pid
        worker.temp_path = final_path .. ".prefetch-" .. tostring(pid)
        worker.result_fd = result_fd_or_err
        worker.result_payload_path = result_payload_path
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    local ticket
    ticket = ProcessBudget:request{
        owner = worker,
        label = tostring(job.label or "chapter-prefetch"),
        priority = tonumber(job.priority or self.process_priority) or self.process_priority,
        on_start = function(granted) spawn(granted) end,
        on_preempt = function() self:preempt(worker) end,
        on_error = function(err)
            worker.pending = false
            worker.finished = true
            dispatchCallback(worker, false, tostring(err))
        end,
    }
    if ticket.state == "queued" then worker.budget_ticket = ticket end
    return worker
end

function AsyncChapterPrefetch:preempt(worker)
    if not worker or worker.finished or worker.cancelled then return end
    if worker.pending and worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.pending = false
        worker.finished = true
        dispatchCallback(worker, false, "后台预缓存已让位给前台任务", { preempted = true })
        return
    end
    if not worker.pid then return end
    worker.finished = true
    ffiutil.terminateSubProcess(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            releaseBudget(worker)
            removeArtifacts(worker)
            if not worker.cancelled then
                dispatchCallback(worker, false, "后台预缓存已让位给前台任务", { preempted = true })
            end
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncChapterPrefetch:cancel(worker)
    if not worker or worker.cancelled then return end
    worker.cancelled = true
    if worker.finished then return end
    if worker.pending and worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.pending = false
        worker.finished = true
        removeArtifacts(worker)
        return
    end
    if not worker.pid then
        releaseBudget(worker)
        worker.finished = true
        removeArtifacts(worker)
        return
    end
    ffiutil.terminateSubProcess(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            worker.finished = true
            closeResultPipe(worker)
            releaseBudget(worker)
            removeArtifacts(worker)
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

return AsyncChapterPrefetch
