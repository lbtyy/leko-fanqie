local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")

local AsyncSourceCatalog = {
    poll_interval = 0.25,
    reap_interval = 0.25,
    hard_timeout = 180,
    worker = nil,
    budget_ticket = nil,
    process_priority = 35,
    pipe_payload_limit = 4 * 1024,
    tickets = {},
}

local function closeResultPipe(worker)
    if not worker or not worker.result_fd then return nil end
    local fd = worker.result_fd
    worker.result_fd = nil
    local ok, raw = pcall(ffiutil.readAllFromFD, fd)
    return ok and raw or nil
end

local function encodePipePayload(payload, limit)
    local ok, encoded = pcall(rapidjson.encode, payload)
    if ok and #encoded <= limit then return encoded end
    local fallback = {
        ok = false,
        error = payload and payload.error and tostring(payload.error):sub(1, 1024)
            or "书源索引结果过大，已安全中止",
    }
    ok, encoded = pcall(rapidjson.encode, fallback)
    if ok and #encoded <= limit then return encoded end
    return '{"ok":false,"error":"书源索引结果序列化失败"}'
end

local function safeTerminate(pid)
    if pid then pcall(ffiutil.terminateSubProcess, pid) end
end

function AsyncSourceCatalog:_restartAfterReap()
    if self.worker or self.budget_ticket or #self.tickets == 0 then return end
    UIManager:scheduleIn(0.5, function()
        if not self.worker and not self.budget_ticket and #self.tickets > 0 then self:_start() end
    end)
end

function AsyncSourceCatalog:_notify(ok, err, payload)
    local tickets = self.tickets
    self.tickets = {}
    for _, ticket in ipairs(tickets) do
        if not ticket.cancelled and ticket.callback then
            pcall(ticket.callback, ok, err, payload or {})
        end
    end
end

function AsyncSourceCatalog:_finish(worker)
    if self.worker ~= worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    if worker.budget_ticket then ProcessBudget:release(worker.budget_ticket); worker.budget_ticket = nil end
    self.budget_ticket = nil
    local raw = closeResultPipe(worker)
    local ok, payload = pcall(rapidjson.decode, raw or "")
    if not ok or type(payload) ~= "table" then
        self:_notify(false, "书源列表没有准备成功")
        return
    end
    if payload.ok == true then
        self:_notify(true, nil, payload)
    else
        self:_notify(false, tostring(payload.error or "书源列表准备失败"), payload)
    end
end

function AsyncSourceCatalog:_timeout(worker)
    if self.worker ~= worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    safeTerminate(worker.pid)
    self:_notify(false, "准备书源列表超时")
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            if worker.budget_ticket then ProcessBudget:release(worker.budget_ticket); worker.budget_ticket = nil end
            self.budget_ticket = nil
            self:_restartAfterReap()
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncSourceCatalog:_poll(worker)
    if self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
    elseif socket.gettime() - worker.started_at >= self.hard_timeout then
        self:_timeout(worker)
    else
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
end

function AsyncSourceCatalog:_spawn(budget_ticket)
    self.budget_ticket = budget_ticket
    if #self.tickets == 0 then
        ProcessBudget:release(budget_ticket)
        self.budget_ticket = nil
        return
    end
    -- Do not fork while the UI process still holds the imported source pack.
    -- The compact catalog can reload it in the child; dropping the parent cache
    -- first substantially reduces the Kindle 7 fork/COW memory peak.
    pcall(Storage.releaseSourceSettings, Storage)
    pcall(Storage.releaseSourceOverrideSettings, Storage)
    collectgarbage("collect")
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local payload = { ok = false }
        local ok, err = xpcall(function()
            -- Compatibility refresh and builtin seeding can parse the full source
            -- pack. Keep that work out of the UI process and do it only when the
            -- compact catalog actually needs rebuilding.
            Storage:refreshSourceCompatibility(false)
            Storage:seedBuiltinSources(false)
            local count, indexed_or_err = Storage:rebuildSourceCatalog()
            if not count then error(tostring(indexed_or_err or "书源列表准备失败")) end
            payload.ok = true
            payload.count = count
            payload.indexed = indexed_or_err
            pcall(Storage.releaseSourceSettings, Storage)
            pcall(Storage.releaseSourceOverrideSettings, Storage)
        end, debug.traceback)
        if not ok then
            payload.error = tostring(err)
            pcall(Storage.releaseSourceSettings, Storage)
            pcall(Storage.releaseSourceOverrideSettings, Storage)
        end
        ffiutil.writeToFD(write_fd, encodePipePayload(payload, AsyncSourceCatalog.pipe_payload_limit), true)
    end, true)
    if not pid then
        ProcessBudget:release(budget_ticket)
        self.budget_ticket = nil
        self:_notify(false, tostring(result_fd_or_err or "无法启动书源索引构建进程"))
        return
    end
    local worker = {
        pid = pid,
        result_fd = result_fd_or_err,
        started_at = socket.gettime(),
        finished = false,
        budget_ticket = budget_ticket,
    }
    self.worker = worker
    UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
end


function AsyncSourceCatalog:_preempt()
    local worker = self.worker
    if not worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    safeTerminate(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            if worker.budget_ticket then ProcessBudget:release(worker.budget_ticket); worker.budget_ticket = nil end
            self.budget_ticket = nil
            -- Keep waiting callers. Rebuild later after the foreground task has
            -- released the global process slot.
            self:_restartAfterReap()
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncSourceCatalog:_start()
    if self.worker or self.budget_ticket then return end
    if type(ffiutil.writeToFD) ~= "function" or type(ffiutil.readAllFromFD) ~= "function" then
        self:_notify(false, "当前 KOReader 版本无法准备书源列表")
        return
    end
    local ticket
    ticket = ProcessBudget:request{
        owner = self,
        label = "source-catalog",
        priority = self.process_priority,
        on_start = function(granted) self:_spawn(granted) end,
        on_preempt = function() self:_preempt() end,
        on_error = function(err)
            self.budget_ticket = nil
            self:_notify(false, tostring(err or "书源索引构建失败"))
        end,
    }
    if ticket.state == "queued" then self.budget_ticket = ticket end
end

function AsyncSourceCatalog:ensure(callback)
    local ticket = { callback = callback, cancelled = false }
    if Storage:isSourceCatalogReady() then
        local callback = function()
            if not ticket.cancelled and ticket.callback then pcall(ticket.callback, true, nil, {}) end
        end
        if type(UIManager.nextTick) == "function" then UIManager:nextTick(callback)
        else UIManager:scheduleIn(0, callback) end
        return ticket
    end
    self.tickets[#self.tickets + 1] = ticket
    self:_start()
    return ticket
end

function AsyncSourceCatalog:cancel(ticket)
    if ticket then ticket.cancelled = true end
    local active = false
    for _, item in ipairs(self.tickets) do
        if not item.cancelled then active = true; break end
    end
    if active then return end
    if self.budget_ticket and not self.worker then
        ProcessBudget:cancel(self.budget_ticket)
        self.budget_ticket = nil
        self.tickets = {}
        return
    end
    if not self.worker then return end
    local worker = self.worker
    self.worker = nil
    worker.finished = true
    safeTerminate(worker.pid)
    self.tickets = {}
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            if worker.budget_ticket then ProcessBudget:release(worker.budget_ticket); worker.budget_ticket = nil end
            self.budget_ticket = nil
            self:_restartAfterReap()
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

return AsyncSourceCatalog
