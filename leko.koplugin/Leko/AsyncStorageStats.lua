local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")

local AsyncStorageStats = {
    worker = nil,
    budget_ticket = nil,
    callbacks = {},
    poll_interval = 0.25,
    reap_interval = 0.25,
    hard_timeout = 60,
    min_refresh_interval = 30,
    last_completed_at = nil,
}

local function closeResultPipe(worker)
    if not worker or not worker.result_fd then return nil end
    local fd = worker.result_fd
    worker.result_fd = nil
    local ok, raw = pcall(ffiutil.readAllFromFD, fd)
    return ok and raw or nil
end

local function safeTerminate(pid)
    if pid then pcall(ffiutil.terminateSubProcess, pid) end
end

function AsyncStorageStats:_notify(ok, stats, err)
    local callbacks = self.callbacks
    self.callbacks = {}
    for _, callback in ipairs(callbacks) do pcall(callback, ok, stats, err) end
end

function AsyncStorageStats:_release(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
    self.budget_ticket = nil
end

function AsyncStorageStats:_finish(worker)
    if self.worker ~= worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    self:_release(worker)
    local raw = closeResultPipe(worker)
    local ok, payload = pcall(rapidjson.decode, raw or "")
    local stats = ok and type(payload) == "table" and payload.stats or nil
    if not stats then
        self:_notify(false, nil, "无法读取存储统计")
        return
    end
    local saved, save_err = Storage:saveCachedStorageStats(stats)
    if not saved then
        self:_notify(false, nil, tostring(save_err or "无法保存存储统计"))
        return
    end
    self.last_completed_at = socket.gettime()
    self:_notify(true, Storage:getCachedStorageStats())
end

function AsyncStorageStats:_poll(worker)
    if self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
    elseif socket.gettime() - worker.started_at >= self.hard_timeout then
        worker.finished = true
        self.worker = nil
        safeTerminate(worker.pid)
        self:_notify(false, nil, "存储统计超时")
        local function reap()
            if ffiutil.isSubProcessDone(worker.pid) then
                closeResultPipe(worker)
                self:_release(worker)
            else
                UIManager:scheduleIn(self.reap_interval, reap)
            end
        end
        UIManager:scheduleIn(self.reap_interval, reap)
    else
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
end

function AsyncStorageStats:_spawn(ticket)
    self.budget_ticket = ticket
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local payload = { stats = Storage:getStorageStats() }
        local ok, encoded = pcall(rapidjson.encode, payload)
        if not ok then encoded = '{"error":"encode failed"}' end
        ffiutil.writeToFD(write_fd, encoded, true)
    end, true)
    if not pid then
        ProcessBudget:release(ticket)
        self.budget_ticket = nil
        self:_notify(false, nil, tostring(result_fd_or_err or "无法启动存储统计"))
        return
    end
    local worker = {
        pid = pid,
        result_fd = result_fd_or_err,
        started_at = socket.gettime(),
        finished = false,
        budget_ticket = ticket,
    }
    self.worker = worker
    UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
end

function AsyncStorageStats:_preempt()
    local worker = self.worker
    if not worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    safeTerminate(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            self:_release(worker)
            self:_notify(false, nil, "存储统计已让位给当前操作")
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncStorageStats:start(callback, force)
    if type(callback) == "function" then self.callbacks[#self.callbacks + 1] = callback end
    if self.worker or self.budget_ticket then return true end
    local cached = Storage:getCachedStorageStats()
    local completed_at = tonumber(self.last_completed_at or 0) or 0
    if not force and cached and completed_at > 0
            and socket.gettime() - completed_at < self.min_refresh_interval then
        UIManager:nextTick(function() self:_notify(true, cached) end)
        return true
    end
    if type(ffiutil.writeToFD) ~= "function" or type(ffiutil.readAllFromFD) ~= "function" then
        self:_notify(false, nil, "当前 KOReader 版本不支持后台存储统计")
        return false
    end
    local ticket
    ticket = ProcessBudget:request{
        owner = self,
        label = "storage-stats",
        priority = 2,
        on_start = function(granted) self:_spawn(granted) end,
        on_preempt = function() self:_preempt() end,
        on_error = function(err)
            self.budget_ticket = nil
            self:_notify(false, nil, tostring(err or "无法启动存储统计"))
        end,
    }
    if ticket.state == "queued" then self.budget_ticket = ticket end
    return true
end

return AsyncStorageStats
