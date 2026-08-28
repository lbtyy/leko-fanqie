local AsyncBookOperation = require("Leko/AsyncBookOperation")
local BookOperationSpec = require("Leko/BookOperationSpec")
local Storage = require("Leko/Storage")
local TaskProgress = require("Leko/TaskProgress")

local ForegroundBookTask = {}
ForegroundBookTask.__index = ForegroundBookTask

function ForegroundBookTask:new(options)
    options = options or {}
    return setmetatable({
        owner = options.owner,
        worker = nil,
        progress = nil,
        generation = 0,
        active_kind = nil,
        on_kind_start = options.on_kind_start,
        on_kind_done = options.on_kind_done,
        _kind_finished = true,
        active_on_cancel = nil,
    }, self)
end

function ForegroundBookTask:isBusy()
    return self.worker ~= nil or self.progress ~= nil or self._kind_finished == false
end

function ForegroundBookTask:_beginKind(kind)
    self.active_kind = kind
    self._kind_finished = false
    if type(self.on_kind_start) == "function" then pcall(self.on_kind_start, kind) end
end

function ForegroundBookTask:_finishKind()
    if self._kind_finished then return end
    self._kind_finished = true
    local kind = self.active_kind
    self.active_kind = nil
    if type(self.on_kind_done) == "function" then pcall(self.on_kind_done, kind) end
end

function ForegroundBookTask:_closeProgress(progress)
    progress = progress or self.progress
    if progress then pcall(progress.close, progress) end
    if self.progress == progress then self.progress = nil end
end

function ForegroundBookTask:complete(progress)
    self.worker = nil
    self.active_on_cancel = nil
    self:_closeProgress(progress)
    self:_finishKind()
end

function ForegroundBookTask:cancel(reason, options)
    options = options or {}
    self.generation = self.generation + 1
    local worker = self.worker
    self.worker = nil
    if worker then pcall(AsyncBookOperation.cancel, AsyncBookOperation, worker) end
    local progress = self.progress
    self.progress = nil
    if progress and not options.keep_progress then pcall(progress.close, progress) end
    local on_cancel = options.on_cancel or self.active_on_cancel
    self.active_on_cancel = nil
    if type(on_cancel) == "function" then pcall(on_cancel, reason) end
    self:_finishKind()
    return worker ~= nil or progress ~= nil
end

function ForegroundBookTask:start(job)
    job = job or {}
    if not job.operation then return nil, "缺少前台任务类型" end
    if self:isBusy() then self:cancel("replaced") end

    self.generation = self.generation + 1
    local generation = self.generation
    local spec = BookOperationSpec:get(job.operation, job.spec)
    self.active_on_cancel = job.on_cancel
    self:_beginKind(job.kind or spec.kind)

    local cancel_callback = function()
        if generation ~= self.generation then return end
        self:cancel("user")
    end
    local progress = job.progress or TaskProgress:new{
        title = job.title or spec.title,
        total = tonumber(job.total or spec.total) or 4,
        current = tonumber(job.current or 0) or 0,
        stage = job.stage or spec.queued,
        cancel_text = job.cancel_text or spec.cancel_text,
        cancel_callback = cancel_callback,
    }
    self.progress = progress
    -- Custom progress widgets may have been created by the caller. Keep the
    -- same callback contract for them while the default TaskProgress receives
    -- it before init(), so its touch button and Back binding are constructed.
    progress.cancel_callback = cancel_callback
    if job.progress == nil and job.show_progress ~= false then progress:show() end

    if job.release_sources ~= false then
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
        collectgarbage("step", 96)
    end

    local pending_worker = {}
    self.worker = pending_worker
    local worker, spawn_err
    worker, spawn_err = AsyncBookOperation:start({
        operation = job.operation,
        book_id = job.book_id or (job.book and job.book.id),
        book = job.book,
        result = job.result,
        chapter_index = job.chapter_index,
        timeout_seconds = tonumber(job.timeout_seconds or spec.timeout_seconds),
        queue_timeout_seconds = tonumber(job.queue_timeout_seconds or spec.queue_timeout_seconds),
        on_payload_ready = job.on_payload_ready,
        force_network = job.force_network == true,
        export_format = job.export_format,
        on_state = function(state, text, current, total, active_worker)
            if generation ~= self.generation then return end
            if self.worker ~= pending_worker and self.worker ~= active_worker then return end
            if self.progress and text then
                self.progress:update(current or self.progress.current,
                    text, total or self.progress.total)
            end
            if type(job.on_state) == "function" then
                pcall(job.on_state, state, text, current, total, active_worker)
            end
        end,
    }, function(ok, err, completed_worker, payload, book)
        if generation ~= self.generation then return end
        if self.worker ~= pending_worker and self.worker ~= completed_worker then return end
        self.worker = nil
        if not ok or not book then
            self.active_on_cancel = nil
            self:_closeProgress(progress)
            self:_finishKind()
            if type(job.on_failure) == "function" then
                pcall(job.on_failure, tostring(err or "前台任务失败"), payload)
            end
            return
        end
        if job.keep_progress ~= true then self:_closeProgress(progress) end
        if job.finish_on_success ~= false then
            self.active_on_cancel = nil
            self:_finishKind()
        end
        if type(job.on_success) == "function" then
            local success_ok, success_err = xpcall(function()
                job.on_success(book, payload, progress, self)
            end, function(callback_err)
                return debug and debug.traceback
                    and debug.traceback(tostring(callback_err), 2) or tostring(callback_err)
            end)
            if not success_ok then
                self:complete(progress)
                if type(job.on_failure) == "function" then
                    pcall(job.on_failure, "应用前台任务结果失败：" .. tostring(success_err), payload)
                end
            end
        elseif job.finish_on_success == false then
            self:complete(progress)
        end
    end)

    if not worker then
        if self.worker == pending_worker then self.worker = nil end
        self:_closeProgress(progress)
        self:_finishKind()
        if type(job.on_failure) == "function" then
            pcall(job.on_failure, tostring(spawn_err or "无法启动前台任务"))
        end
        return nil, spawn_err
    end
    if self.worker == pending_worker then self.worker = worker end
    return self
end

return ForegroundBookTask
