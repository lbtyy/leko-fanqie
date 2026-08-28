local UIManager = require("ui/uimanager")
local MemoryGuard = require("Leko/MemoryGuard")

-- Global subprocess budget for low-memory Kindle devices.
--
-- Idle source discovery may use up to two direct background children when the
-- kernel reports enough headroom. Any user-visible foreground task is exclusive:
-- all background children are terminated/reaped first, then exactly one cover,
-- TOC, source-switch or chapter-preparation child may run. This avoids the
-- parent + search children + image/TOC child fork/COW peak that can restart the
-- Kindle framework.

local function nextTick(callback)
    if type(UIManager.nextTick) == "function" then return UIManager:nextTick(callback) end
    if type(UIManager.scheduleIn) == "function" then return UIManager:scheduleIn(0, callback) end
    return callback()
end

local ProcessBudget = {
    capacity = 2,
    background_capacity = 2,
    foreground_capacity = 1,
    active = {},
    queue = {},
    sequence = 0,
    dispatch_scheduled = false,
}

local function removeQueued(queue, ticket)
    for index = #queue, 1, -1 do
        if queue[index] == ticket then table.remove(queue, index); return true end
    end
    return false
end

local function removeActive(active, ticket)
    for index = #active, 1, -1 do
        if active[index] == ticket then table.remove(active, index); return true end
    end
    return false
end

local function sortQueue(queue)
    table.sort(queue, function(left, right)
        local lp = tonumber(left.priority or 0) or 0
        local rp = tonumber(right.priority or 0) or 0
        if lp ~= rp then return lp > rp end
        return tonumber(left.sequence or 0) < tonumber(right.sequence or 0)
    end)
end

function ProcessBudget:_scheduleDispatch()
    if self.dispatch_scheduled then return end
    self.dispatch_scheduled = true
    nextTick(function()
        self.dispatch_scheduled = false
        self:_dispatch()
    end)
end

function ProcessBudget:_laneActiveCount(lane)
    local count = 0
    for _, ticket in ipairs(self.active) do if ticket.lane == lane then count = count + 1 end end
    return count
end

function ProcessBudget:_backgroundActiveCount() return self:_laneActiveCount("background") end
function ProcessBudget:_foregroundActiveCount() return self:_laneActiveCount("foreground") end

function ProcessBudget:_hasQueuedForeground()
    for _, ticket in ipairs(self.queue) do
        if not ticket.cancelled and ticket.lane == "foreground" then return true end
    end
    return false
end

function ProcessBudget:_backgroundLimit()
    local recommended = MemoryGuard:recommendedBackgroundWorkers()
    return math.max(1, math.min(self.background_capacity, tonumber(recommended or 1) or 1))
end

function ProcessBudget:_canStart(ticket)
    if not ticket then return false end
    if ticket.lane == "foreground" then
        -- Foreground work is exclusive, not a third concurrent child.
        return #self.active == 0 and self:_foregroundActiveCount() < self.foreground_capacity
    end
    if self:_foregroundActiveCount() > 0 or self:_hasQueuedForeground() then return false end
    return #self.active < self.capacity and self:_backgroundActiveCount() < self:_backgroundLimit()
end

function ProcessBudget:_dispatch()
    sortQueue(self.queue)
    while #self.queue > 0 do
        local start_index
        local removed_cancelled = false
        for index, ticket in ipairs(self.queue) do
            if ticket.cancelled then
                table.remove(self.queue, index)
                ticket.state = "cancelled"
                removed_cancelled = true
                break
            elseif self:_canStart(ticket) then
                start_index = index
                break
            end
        end
        if removed_cancelled then
            -- Restart scan because table indices shifted.
        elseif not start_index then
            break
        else
            local ticket = table.remove(self.queue, start_index)
            self.active[#self.active + 1] = ticket
            ticket.state = "active"
            ticket.preempt_requested = false
            local ok, err = xpcall(function()
                if ticket.on_start then ticket.on_start(ticket) end
            end, debug.traceback)
            if not ok then
                removeActive(self.active, ticket)
                ticket.state = "failed"
                ticket.error = tostring(err)
                if ticket.on_error then pcall(ticket.on_error, ticket.error, ticket) end
            end
        end
    end
    if #self.queue > 0 then self:_considerPreemption(self.queue[1]) end
end

function ProcessBudget:_preemptTicket(ticket, incoming)
    if not ticket or ticket.cancelled or ticket.preempt_requested
            or type(ticket.on_preempt) ~= "function" then return false end
    ticket.preempt_requested = true
    nextTick(function()
        local still_active = false
        for _, active in ipairs(self.active) do if active == ticket then still_active = true; break end end
        if still_active and not ticket.cancelled then
            local ok = pcall(ticket.on_preempt, ticket, incoming)
            if not ok then ticket.preempt_requested = false end
        end
    end)
    return true
end

function ProcessBudget:_considerPreemption(incoming)
    if not incoming then return end
    if incoming.lane == "foreground" then
        -- Reclaim every background child. Starting after only one is reaped would
        -- still overlap the foreground child with a mutating search child.
        for _, active in ipairs(self.active) do
            if active.lane == "background" then self:_preemptTicket(active, incoming) end
        end
        return
    end
    if self:_foregroundActiveCount() > 0 or self:_hasQueuedForeground() then return end
    if self:_backgroundActiveCount() < self:_backgroundLimit() then return end
    local victim
    for _, active in ipairs(self.active) do
        local can_preempt = active.lane == "background"
            and not active.cancelled and not active.preempt_requested
            and type(active.on_preempt) == "function"
            and (tonumber(incoming.priority or 0) or 0) > (tonumber(active.priority or 0) or 0)
        if can_preempt and (not victim
                or (tonumber(active.priority or 0) or 0) < (tonumber(victim.priority or 0) or 0)
                or ((tonumber(active.priority or 0) or 0) == (tonumber(victim.priority or 0) or 0)
                    and (tonumber(active.sequence or 0) or 0) < (tonumber(victim.sequence or 0) or 0))) then
            victim = active
        end
    end
    if victim then self:_preemptTicket(victim, incoming) end
end

function ProcessBudget:request(options)
    options = options or {}
    self.sequence = self.sequence + 1
    local ticket = {
        owner = options.owner,
        label = tostring(options.label or "background"),
        priority = tonumber(options.priority or 0) or 0,
        lane = options.lane == "foreground" and "foreground" or "background",
        on_start = options.on_start,
        on_preempt = options.on_preempt,
        on_error = options.on_error,
        sequence = self.sequence,
        state = "queued",
        cancelled = false,
    }
    self.queue[#self.queue + 1] = ticket
    self:_dispatch()
    return ticket
end

function ProcessBudget:release(ticket)
    if not ticket then return end
    if removeActive(self.active, ticket) then
        ticket.state = "done"
        ticket.preempt_requested = false
        self:_scheduleDispatch()
        return
    end
    if removeQueued(self.queue, ticket) then ticket.state = "done" end
end

function ProcessBudget:cancel(ticket)
    if not ticket or ticket.cancelled then return end
    ticket.cancelled = true
    if removeQueued(self.queue, ticket) then ticket.state = "cancelled"; return end
    local active = false
    for _, item in ipairs(self.active) do if item == ticket then active = true; break end end
    if active then
        ticket.state = "cancelling"
        if type(ticket.on_preempt) == "function" then pcall(ticket.on_preempt, ticket, nil) end
    end
end

function ProcessBudget:isIdle() return #self.active == 0 and #self.queue == 0 end
function ProcessBudget:activeCount() return #self.active end

function ProcessBudget:activeLabel()
    if #self.active == 0 then return nil end
    local labels = {}
    for _, ticket in ipairs(self.active) do labels[#labels + 1] = ticket.label end
    return table.concat(labels, ", ")
end

function ProcessBudget:getMemorySnapshot() return MemoryGuard:snapshot() end

function ProcessBudget:resetForTests()
    self.active = {}
    self.queue = {}
    self.sequence = 0
    self.dispatch_scheduled = false
end

return ProcessBudget
