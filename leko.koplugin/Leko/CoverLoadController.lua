local AsyncCoverFetch = require("Leko/AsyncCoverFetch")
local CoverService = require("Leko/CoverService")
local ProcessBudget = require("Leko/ProcessBudget")

local CoverLoadController = {}
CoverLoadController.__index = CoverLoadController

function CoverLoadController:new(options)
    options = options or {}
    return setmetatable({
        owner = options.owner,
        worker = nil,
        decode_ticket = nil,
        generation = 0,
        foreground_active = false,
        on_foreground_start = options.on_foreground_start,
        on_foreground_done = options.on_foreground_done,
        closed = false,
    }, self)
end

function CoverLoadController:isBusy()
    return self.worker ~= nil or self.decode_ticket ~= nil or self.foreground_active
end

function CoverLoadController:_begin()
    if self.foreground_active then return end
    self.foreground_active = true
    if type(self.on_foreground_start) == "function" then pcall(self.on_foreground_start) end
end

function CoverLoadController:_finish()
    if not self.foreground_active then return end
    self.foreground_active = false
    if not self.closed and type(self.on_foreground_done) == "function" then
        pcall(self.on_foreground_done)
    end
end

function CoverLoadController:cancel()
    self.generation = self.generation + 1
    local worker = self.worker
    self.worker = nil
    if worker then pcall(AsyncCoverFetch.cancel, AsyncCoverFetch, worker) end
    local ticket = self.decode_ticket
    self.decode_ticket = nil
    if ticket then pcall(ProcessBudget.cancel, ProcessBudget, ticket) end
    self:_finish()
    return worker ~= nil or ticket ~= nil
end

local function isCurrent(self, generation, job)
    if self.closed or generation ~= self.generation then return false end
    return type(job.is_current) ~= "function" or job.is_current() == true
end

function CoverLoadController:_ready(job, image, prepared, resolved_result)
    if type(job.on_ready) == "function" then
        pcall(job.on_ready, image, prepared, resolved_result or job.result)
    end
end

function CoverLoadController:_fail(job, err)
    if type(job.on_failure) == "function" then pcall(job.on_failure, tostring(err or "封面读取失败")) end
end

function CoverLoadController:load(job)
    job = job or {}
    if self.closed then return nil, "controller closed" end
    if type(job.result) ~= "table" then return nil, "缺少封面结果" end
    self:cancel()
    self.generation = self.generation + 1
    local generation = self.generation
    local result = job.result
    local width = math.max(1, tonumber(job.width or 1) or 1)
    local height = math.max(1, tonumber(job.height or 1) or 1)

    if job.force == true then CoverService:invalidate(result) end

    local image, prepared
    if not job.force then image, prepared = CoverService:getMemory(result, width, height) end
    if image then
        if isCurrent(self, generation, job) then self:_ready(job, image, prepared, result) end
        return self
    end

    self:_begin()
    if not job.force and CoverService:hasDisk(result) then
        local ticket
        ticket = ProcessBudget:request{
            owner = self.owner or self,
            label = "foreground-cover-disk-decode",
            priority = 105,
            lane = "foreground",
            on_start = function(granted)
                if self.decode_ticket == ticket then self.decode_ticket = nil end
                if not isCurrent(self, generation, job) then
                    ProcessBudget:release(granted)
                    self:_finish()
                    return
                end
                collectgarbage("collect")
                local decoded, decoded_prepared, err = CoverService:fetch(result, width, height)
                ProcessBudget:release(granted)
                self:_finish()
                if not isCurrent(self, generation, job) then return end
                if decoded then self:_ready(job, decoded, decoded_prepared, result)
                else self:_fail(job, err or "本地封面无法解码") end
            end,
            on_error = function(err)
                if self.decode_ticket == ticket then self.decode_ticket = nil end
                self:_finish()
                if isCurrent(self, generation, job) then self:_fail(job, err or "无法安排封面解码") end
            end,
        }
        if ticket and ticket.state == "queued" then self.decode_ticket = ticket end
        return self
    end

    local worker, start_err
    local completed = false
    worker, start_err = AsyncCoverFetch:start({
        result = result,
        width = width,
        height = height,
        force = job.force == true,
    }, function(ok, err, finished_worker, payload)
        completed = true
        if self.worker == finished_worker then self.worker = nil end
        if not isCurrent(self, generation, job) then
            self:_finish()
            return
        end
        -- AsyncCoverFetch may resolve an empty/stale search cover from the
        -- detail page.  Decode the resolved candidate, not the original
        -- search row, otherwise a successful detail lookup still ends in a
        -- second fetch against the old empty URL.
        local resolved_result = result
        if payload and type(payload.result) == "table" then
            resolved_result = payload.result
            if type(job.on_resolved) == "function" then
                pcall(job.on_resolved, resolved_result)
            end
        end
        local decoded, decoded_prepared, decode_err
        if ok then decoded, decoded_prepared, decode_err = CoverService:fetch(resolved_result, width, height) end
        self:_finish()
        if not isCurrent(self, generation, job) then return end
        if decoded then self:_ready(job, decoded, decoded_prepared, resolved_result)
        else self:_fail(job, err or decode_err or "封面读取失败") end
    end)
    if not worker then
        self:_finish()
        if isCurrent(self, generation, job) then self:_fail(job, start_err or "无法启动封面任务") end
        return nil, start_err
    end
    if not completed then self.worker = worker end
    return self
end

function CoverLoadController:close()
    if self.closed then return end
    self:cancel()
    self.closed = true
    self.on_foreground_start = nil
    self.on_foreground_done = nil
end

return CoverLoadController
