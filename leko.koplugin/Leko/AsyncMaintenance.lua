local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")

local AsyncMaintenance = {
    worker = nil,
    budget_ticket = nil,
    poll_interval = 0.5,
    reap_interval = 0.25,
}

function AsyncMaintenance:_release(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
    self.budget_ticket = nil
end

function AsyncMaintenance:_poll(worker)
    if self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        worker.finished = true
        self.worker = nil
        self:_release(worker)
    else
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
end

function AsyncMaintenance:_preempt()
    local worker = self.worker
    if not worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    ffiutil.terminateSubProcess(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            self:_release(worker)
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncMaintenance:start()
    if self.worker or self.budget_ticket then return end
    local ticket
    ticket = ProcessBudget:request{
        owner = self,
        label = "cache-maintenance",
        priority = 1,
        on_start = function(granted)
            self.budget_ticket = granted
            local pid = ffiutil.runInSubProcess(function()
                pcall(Storage.pruneCaches, Storage)
            end, false)
            if not pid then
                ProcessBudget:release(granted)
                self.budget_ticket = nil
                return
            end
            local worker = { pid = pid, finished = false, budget_ticket = granted }
            self.worker = worker
            granted.on_preempt = function() self:_preempt() end
            UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
        end,
        on_preempt = function() self:_preempt() end,
        on_error = function() self.budget_ticket = nil end,
    }
    if ticket.state == "queued" then self.budget_ticket = ticket end
end

function AsyncMaintenance:cancel()
    if self.budget_ticket and not self.worker then
        ProcessBudget:cancel(self.budget_ticket)
        self.budget_ticket = nil
    elseif self.worker then
        self:_preempt()
    end
end

return AsyncMaintenance
