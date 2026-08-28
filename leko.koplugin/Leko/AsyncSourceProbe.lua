local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local AsyncSourceCatalog = require("Leko/AsyncSourceCatalog")
local ProcessBudget = require("Leko/ProcessBudget")
local SourceHealth = require("Leko/SourceHealth")
local Storage = require("Leko/Storage")

local AsyncSourceProbe = {}
AsyncSourceProbe.__index = AsyncSourceProbe

local POLL_INTERVAL = 0.18
local REAP_INTERVAL = 0.18
local BATCH_YIELD = 0.08
local MAX_PARALLEL_WORKERS = 2
local SOURCE_DEADLINE = 7
local PROCESS_PRIORITY = 30
local PIPE_PAYLOAD_LIMIT = 4 * 1024

local function closeResultPipe(worker)
    if not worker or not worker.result_fd then return nil end
    local fd = worker.result_fd
    worker.result_fd = nil
    local ok, raw = pcall(ffiutil.readAllFromFD, fd)
    return ok and raw or nil
end

local function encodePipePayload(payload)
    local ok, encoded = pcall(rapidjson.encode, payload)
    if ok and #encoded <= PIPE_PAYLOAD_LIMIT then return encoded end
    local health = type(payload) == "table" and payload.health or nil
    local fallback = {
        health = {
            source_id = health and health.source_id or nil,
            source_name = health and health.source_name or nil,
            status = health and health.status or "offline",
            latency_ms = health and health.latency_ms or nil,
            http_code = health and health.http_code or nil,
            checked_at = health and health.checked_at or os.time(),
            error = "探测结果过大，已截断",
        },
    }
    ok, encoded = pcall(rapidjson.encode, fallback)
    if ok and #encoded <= PIPE_PAYLOAD_LIMIT then return encoded end
    return '{"health":{"status":"offline","error":"探测结果序列化失败"}}'
end

function AsyncSourceProbe:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.source_ids = options.source_ids
    instance.only_enabled = options.only_enabled ~= false
    instance.only_executable = options.only_executable ~= false
    instance.force = options.force ~= false
    instance.max_parallel_workers = math.max(1,
        math.min(MAX_PARALLEL_WORKERS, tonumber(options.max_parallel_workers or MAX_PARALLEL_WORKERS) or MAX_PARALLEL_WORKERS))
    instance.on_result = options.on_result
    instance.on_progress = options.on_progress
    instance.on_done = options.on_done
    instance.completed = 0
    instance.total = 0
    instance.online = 0
    instance.offline = 0
    instance.finished = false
    instance.cancelled = false
    instance.workers = {}
    instance.pending = {}
    instance.retry_queue = {}
    instance.reaping_count = 0
    instance.catalog_ticket = nil
    instance.queue = nil
    instance.queue_index = 0
    instance._fill_callback = nil
    instance._last_progress_at = 0
    return instance
end

function AsyncSourceProbe:_notifyProgress(stage, force)
    if self.cancelled or self.finished and not force then return end
    local now = socket.gettime()
    if not force and now - (self._last_progress_at or 0) < 0.8 then return end
    self._last_progress_at = now
    if self.on_progress then pcall(self.on_progress, self.completed, self.total, stage, self) end
end

function AsyncSourceProbe:_activeCount()
    local count = 0
    for _ in pairs(self.workers) do count = count + 1 end
    return count
end

function AsyncSourceProbe:_pendingCount()
    local count = 0
    for _ in pairs(self.pending) do count = count + 1 end
    return count
end

function AsyncSourceProbe:_hasRemaining()
    return #self.retry_queue > 0 or self.queue and self.queue_index < #self.queue
end

function AsyncSourceProbe:_nextEntry()
    if #self.retry_queue > 0 then return table.remove(self.retry_queue, 1) end
    self.queue_index = self.queue_index + 1
    return self.queue and self.queue[self.queue_index] or nil
end

function AsyncSourceProbe:_returnEntry(entry)
    if entry and not self.cancelled and not self.finished then table.insert(self.retry_queue, 1, entry) end
end

function AsyncSourceProbe:_finishIfIdle(event)
    if self.finished or self.cancelled then return true end
    if self:_hasRemaining() or self:_activeCount() > 0 or self:_pendingCount() > 0
            or self.reaping_count > 0 then return false end
    self.finished = true
    self.queue = nil
    self.retry_queue = {}
    self:_notifyProgress(string.format("测试完成 · 请求成功 %d · 失败/拒绝 %d", self.online, self.offline), true)
    if self.on_done then pcall(self.on_done, self, event or {}) end
    return true
end

function AsyncSourceProbe:_prepareQueue()
    local summaries, err = Storage:listSourceSummaries()
    if not summaries then
        self.finished = true
        if self.on_done then pcall(self.on_done, self, { error = tostring(err or "无法读取书源列表") }) end
        return
    end
    local wanted
    if type(self.source_ids) == "table" then
        wanted = {}
        for _, id in ipairs(self.source_ids) do wanted[tostring(id)] = true end
    end
    local health_map = Storage:listSourceHealth()
    local records_path, records_err = Storage:getSourceCatalogRecordsPath()
    if not records_path then
        self.finished = true
        if self.on_done then pcall(self.on_done, self, { error = tostring(records_err or "书源记录文件不可用") }) end
        return
    end
    local queue = {}
    for _, summary in ipairs(summaries) do
        if (not wanted or wanted[tostring(summary.id or "")])
                and (not self.only_enabled or summary.enabled ~= false)
                and (not self.only_executable or summary.searchable ~= false)
                and summary.has_search_url == true then
            queue[#queue + 1] = {
                id = summary.id, name = summary.name,
                health = health_map[tostring(summary.id or "")],
                records_path = records_path,
                record_offset = summary.record_offset,
                record_length = summary.record_length,
            }
        end
    end
    self.queue = queue
    self.total = #queue
    self:_notifyProgress("开始测试书源连通性（最多两路）", true)
    self:_scheduleFill(0)
end

function AsyncSourceProbe:_scheduleFill(delay)
    if self.cancelled or self.finished or self._fill_callback then return end
    local callback
    callback = function() self._fill_callback = nil; self:_fillSlots() end
    self._fill_callback = callback
    UIManager:scheduleIn(delay or BATCH_YIELD, callback)
end

function AsyncSourceProbe:_releaseWorkerBudget(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

function AsyncSourceProbe:_processRecord(entry, record)
    if type(record) ~= "table" then
        record = SourceHealth:record(entry, "offline", nil, nil, "探测进程没有返回有效结果")
    end
    SourceHealth:save(record)
    self.completed = self.completed + 1
    if record.transport_state == "reachable"
            or (record.transport_state == nil and record.status == "online") then
        self.online = self.online + 1
    else
        self.offline = self.offline + 1
    end
    if self.on_result and not self.cancelled then
        pcall(self.on_result, record, self.completed, self.total, self)
    end
    self:_notifyProgress(string.format("已测试 %d/%d · 请求成功 %d · 失败/拒绝 %d",
        self.completed, self.total, self.online, self.offline), self.completed == 1 or self.completed == self.total)
    if self.completed % 12 == 0 then collectgarbage("step", 100) end
end

function AsyncSourceProbe:_removeWorker(worker)
    if worker then self.workers[worker] = nil end
end

function AsyncSourceProbe:_completeWorker(worker, record)
    if not worker or not self.workers[worker] then return end
    self:_removeWorker(worker)
    worker.finished = true
    self:_releaseWorkerBudget(worker)
    if not self.cancelled then self:_processRecord(worker.entry, record) end
    self:_scheduleFill(BATCH_YIELD)
    self:_finishIfIdle()
end

function AsyncSourceProbe:_reapWorker(worker, record, retry)
    if not worker or worker.reaping then return end
    worker.reaping = true
    self.reaping_count = self.reaping_count + 1
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            self:_removeWorker(worker)
            self:_releaseWorkerBudget(worker)
            self.reaping_count = math.max(0, self.reaping_count - 1)
            if retry then self:_returnEntry(worker.entry) end
            if record and not self.cancelled then self:_processRecord(worker.entry, record) end
            if not self.cancelled then self:_scheduleFill(BATCH_YIELD) end
            self:_finishIfIdle()
        else
            UIManager:scheduleIn(REAP_INTERVAL, reap)
        end
    end
    UIManager:scheduleIn(REAP_INTERVAL, reap)
end

function AsyncSourceProbe:_preemptWorker(worker)
    if not worker or not self.workers[worker] or worker.finished then return end
    worker.finished = true
    ffiutil.terminateSubProcess(worker.pid)
    self:_reapWorker(worker, nil, true)
end

function AsyncSourceProbe:_spawnProbe(holder, budget_ticket)
    self.pending[holder] = nil
    if self.cancelled or self.finished then
        ProcessBudget:release(budget_ticket)
        self:_returnEntry(holder.entry)
        return
    end
    local entry = holder.entry
    local force = self.force
    local job = {
        source_id = entry.id,
        records_path = entry.records_path,
        record_offset = entry.record_offset,
        record_length = entry.record_length,
        health = entry.health,
    }
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local payload = {}
        local ok, child_err = xpcall(function()
            local source, source_err = Storage:readSourceRecord(job.records_path, job.record_offset,
                job.record_length, job.source_id, true)
            if not source then error(tostring(source_err or "找不到书源定义")) end
            local record
            if not force and type(job.health) == "table" then
                local health_map = { [tostring(job.source_id)] = job.health }
                local decision, cached = SourceHealth:cachedDecision(source, nil, health_map)
                if decision ~= nil then record = cached end
            end
            if not record then record = SourceHealth:probe(source) end
            payload.health = record
            Storage:releaseSourceSettings()
            Storage:releaseSourceOverrideSettings()
        end, debug.traceback)
        if not ok then
            payload.health = SourceHealth:record(entry, "offline", nil, nil, tostring(child_err))
            pcall(Storage.releaseSourceSettings, Storage)
            pcall(Storage.releaseSourceOverrideSettings, Storage)
        end
        ffiutil.writeToFD(write_fd, encodePipePayload(payload), true)
    end, true)
    if not pid then
        ProcessBudget:release(budget_ticket)
        self:_processRecord(entry, SourceHealth:record(entry, "offline", nil, nil,
            "无法启动探测进程：" .. tostring(result_fd_or_err or "未知错误")))
        self:_scheduleFill(BATCH_YIELD)
        return
    end
    local worker = {
        pid = pid, result_fd = result_fd_or_err, entry = entry,
        started_at = socket.gettime(), finished = false, budget_ticket = budget_ticket,
    }
    self.workers[worker] = true
    budget_ticket.on_preempt = function() self:_preemptWorker(worker) end
    UIManager:scheduleIn(POLL_INTERVAL, function() self:_pollWorker(worker) end)
    self:_scheduleFill(0)
end

function AsyncSourceProbe:_requestEntry(entry)
    local holder = { entry = entry }
    self.pending[holder] = true
    local ticket
    ticket = ProcessBudget:request{
        owner = holder,
        label = "source-probe",
        priority = PROCESS_PRIORITY,
        on_start = function(granted) self:_spawnProbe(holder, granted) end,
        on_error = function(err)
            self.pending[holder] = nil
            self:_processRecord(entry, SourceHealth:record(entry, "offline", nil, nil, tostring(err)))
            self:_scheduleFill(BATCH_YIELD)
        end,
    }
    if ticket.state == "queued" then holder.ticket = ticket end
end

function AsyncSourceProbe:_fillSlots()
    if self.cancelled or self.finished then return end
    while self:_activeCount() + self:_pendingCount() < self.max_parallel_workers do
        local entry = self:_nextEntry()
        if not entry then break end
        self:_requestEntry(entry)
    end
    self:_finishIfIdle()
end

function AsyncSourceProbe:_pollWorker(worker)
    if self.cancelled or not worker or not self.workers[worker] or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        local raw = closeResultPipe(worker)
        local ok, payload = pcall(rapidjson.decode, raw or "")
        self:_completeWorker(worker, ok and type(payload) == "table" and payload.health or nil)
    elseif socket.gettime() - worker.started_at >= SOURCE_DEADLINE then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        self:_reapWorker(worker, SourceHealth:record(worker.entry, "offline",
            math.floor(SOURCE_DEADLINE * 1000), nil,
            "连接检查超时（" .. tostring(SOURCE_DEADLINE) .. "秒）"), false)
    else
        UIManager:scheduleIn(POLL_INTERVAL, function() self:_pollWorker(worker) end)
    end
end

function AsyncSourceProbe:start()
    if self.finished or self.cancelled or self.catalog_ticket or self.queue then return self end
    self:_notifyProgress("正在准备书源……", true)
    self.catalog_ticket = AsyncSourceCatalog:ensure(function(ok, err)
        self.catalog_ticket = nil
        if self.cancelled or self.finished then return end
        if not ok then
            self.finished = true
            if self.on_done then pcall(self.on_done, self, { error = tostring(err or "书源索引准备失败") }) end
            return
        end
        self:_prepareQueue()
    end)
    return self
end

function AsyncSourceProbe:cancel()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    if self.catalog_ticket then AsyncSourceCatalog:cancel(self.catalog_ticket); self.catalog_ticket = nil end
    if self._fill_callback then pcall(UIManager.unschedule, UIManager, self._fill_callback); self._fill_callback = nil end
    for holder in pairs(self.pending) do
        if holder.ticket then ProcessBudget:cancel(holder.ticket) end
        self.pending[holder] = nil
    end
    local active = {}
    for worker in pairs(self.workers) do active[#active + 1] = worker end
    self.queue = nil
    self.retry_queue = {}
    for _, worker in ipairs(active) do
        if not worker.finished then worker.finished = true; ffiutil.terminateSubProcess(worker.pid) end
        self:_reapWorker(worker, nil, false)
    end
end

return AsyncSourceProbe
