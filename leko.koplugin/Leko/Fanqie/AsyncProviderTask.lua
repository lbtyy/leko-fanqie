local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")

local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")

-- Leko/Fanqie/AsyncProviderTask.lua
--
-- Provider 网络任务统一子进程通道（异步铁律的唯一入口）。
-- 模式照抄 Leko/AsyncBookOperation.lua：ProcessBudget:request 排队 →
-- MemoryGuard:prepareForFork → ffiutil.runInSubProcess → SubprocessPayload
-- 信封回传 → UI 线程 nextTick 轻量回调。
--
-- 两条通道：
--   run(provider_id, op, payload, callback, opts) —— UI 线程异步任务；
--   runSync(provider_id, op, payload, opts) —— 仅在已注册的子进程内同步执行
--       （BookService 的 provider 接缝本就在 AsyncBookOperation 子进程里跑，
--       就地执行避免弱设备双重 fork）。runSync 用 fork 内存继承推断守卫：
--       子进程继承 ProcessBudget.active（含生成它的 ticket），
--       activeCount() > 0 才允许就地执行，否则返回明确错误。
--
-- 序列化铁律：payload/result 必须 JSON 可序列化；Cookie 等字符串键
-- hash table 一律用数组形式（fanqie/async.lua:41-44 的教训）。
--
-- 限流合并：子进程内记录的限流时间戳随 fork 丢失。Provider 在 result 里
-- 附带 rate_records = {{source_id=, ts=}, ...}，父进程回调前统一
-- RateLimiter:merge（移植 fanqie/sources.lua:75 的合并语义）。

local AsyncProviderTask = {
    poll_interval = 0.15,
    reap_interval = 0.25,
    hard_timeout = 40,
    foreground_priority = 90,
    background_priority = 1,
    result_payload_limit = 2 * 1024 * 1024,
}

local function rateLimiter()
    return require("Leko/providers/RateLimiter")
end

-- 子进程入口：经 ProviderRegistry（含合规门禁）取 Provider 并分发 op。
-- 该函数同时在 run 的 fork 子进程与 runSync 的就地执行中使用。
local function childExecute(job)
    local payload = { ok = false }
    local ok, err = xpcall(function()
        local ProviderRegistry = require("Leko/providers/ProviderRegistry")
        local provider = ProviderRegistry:get(job.provider_id)
        if not provider then
            error("Provider 不可用或未通过合规门禁：" .. tostring(job.provider_id))
        end
        if type(provider.childOp) ~= "function" then
            error("Provider 不支持子进程操作：" .. tostring(job.provider_id))
        end
        local result, op_err = provider:childOp(job.op, job.payload or {})
        if result == nil then
            payload.ok = false
            if type(op_err) == "table" then
                payload.error = tostring(op_err.message or "Provider 操作失败")
                payload.error_code = op_err.code
            else
                payload.error = tostring(op_err or "Provider 操作失败")
            end
            return
        end
        payload.ok = true
        payload.result = result
    end, function(failure)
        if debug and debug.traceback then return debug.traceback(tostring(failure), 2) end
        return tostring(failure)
    end)
    if not ok then
        payload.ok = false
        local message = tostring(err or "Provider 后台任务失败")
        local trace_at = message:find("\nstack traceback:", 1, true)
        if trace_at then message = message:sub(1, trace_at - 1) end
        payload.error = message:gsub("^.-%.lua:%d+:%s*", "", 1)
        payload.diagnostic_error = tostring(err)
    end
    return payload
end

--- 子进程内同步通道。
-- @return result|nil, err string|nil, error_code string|nil
function AsyncProviderTask:runSync(provider_id, op, op_payload, opts)
    opts = opts or {}
    -- fork 内存继承守卫：只有 AsyncBookOperation/AsyncProviderTask 等
    -- ProcessBudget 托管的子进程才持有非空 active；UI 线程空闲时 active 为空。
    if ProcessBudget:activeCount() <= 0 and opts.allow_unregistered ~= true then
        return nil, "runSync 只允许在已注册的子进程中执行；UI 线程请使用 run()", "ASYNC_RULE"
    end
    local payload = childExecute({
        provider_id = provider_id,
        op = op,
        payload = op_payload,
    })
    if payload.ok ~= true then
        return nil, tostring(payload.error or "Provider 操作失败"), payload.error_code
    end
    return payload.result, nil, nil
end

local function dispatchCallback(worker, ok, err, result, error_code)
    if not worker or not worker.callback then return end
    local callback = worker.callback
    local function run()
        if not worker.cancelled then pcall(callback, ok, err, result, error_code, worker) end
        if worker.budget_ticket then
            ProcessBudget:release(worker.budget_ticket)
            worker.budget_ticket = nil
        end
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

function AsyncProviderTask:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local result_fd = worker.result_fd
    worker.result_fd = nil
    local payload_path = worker.payload_path
    worker.payload_path = nil
    local payload, payload_err = SubprocessPayload:read(result_fd, payload_path,
        { max_bytes = self.result_payload_limit })
    if worker.cancelled then
        if worker.budget_ticket then
            ProcessBudget:release(worker.budget_ticket)
            worker.budget_ticket = nil
        end
        return
    end
    if type(payload) ~= "table" then
        dispatchCallback(worker, false, tostring(payload_err or "Provider 后台任务没有返回有效结果"))
        return
    end
    -- 跨子进程限流时间戳合并（见模块头注释）。
    if type(payload.result) == "table" and type(payload.result.rate_records) == "table" then
        pcall(function() rateLimiter():merge(payload.result.rate_records) end)
    end
    if payload.ok ~= true then
        dispatchCallback(worker, false, tostring(payload.error or "Provider 后台任务失败"),
            nil, payload.error_code)
        return
    end
    dispatchCallback(worker, true, nil, payload.result)
end

function AsyncProviderTask:_poll(worker)
    if not worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        self:_finish(worker)
    elseif socket.gettime() - worker.started_at >= worker.timeout_seconds then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        local function finishTimeout()
            if worker.result_fd then pcall(ffiutil.readAllFromFD, worker.result_fd) end
            worker.result_fd = nil
            SubprocessPayload:cleanup(worker.payload_path)
            worker.payload_path = nil
            if not worker.cancelled then
                dispatchCallback(worker, false,
                    "Provider 任务超时（" .. tostring(worker.timeout_seconds) .. "秒）")
            elseif worker.budget_ticket then
                ProcessBudget:release(worker.budget_ticket)
                worker.budget_ticket = nil
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

--- UI 线程异步通道。
-- @param provider_id string 如 "fanqie:official"
-- @param op string 操作名
-- @param op_payload table JSON 可序列化参数
-- @param callback function(ok, err, result, error_code, worker) UI 线程轻量回调
-- @param opts table|nil { lane="foreground"|"background", label, priority,
--                         timeout_seconds, on_state }
-- @return worker|nil, err
function AsyncProviderTask:run(provider_id, op, op_payload, callback, opts)
    if type(provider_id) ~= "string" or provider_id == "" or type(op) ~= "string" or op == "" then
        return nil, "Provider 任务参数不完整"
    end
    opts = opts or {}
    local job = {
        provider_id = provider_id,
        op = op,
        payload = op_payload or {},
    }
    local worker = {
        callback = callback,
        cancelled = false,
        finished = false,
        timeout_seconds = math.max(10, tonumber(opts.timeout_seconds or self.hard_timeout) or self.hard_timeout),
        provider_id = provider_id,
        op = op,
    }
    local lane = opts.lane == "foreground" and "foreground" or "background"

    local function spawn(ticket)
        worker.budget_ticket = ticket
        if worker.cancelled then
            worker.finished = true
            ProcessBudget:release(ticket)
            return
        end
        MemoryGuard:prepareForFork()
        local payload_path = SubprocessPayload:newPath(
            "provider-" .. tostring(op or "task"),
            type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
            SubprocessPayload:write(write_fd, payload_path, childExecute(job),
                { max_bytes = AsyncProviderTask.result_payload_limit })
        end, true)
        if not pid then
            SubprocessPayload:cleanup(payload_path)
            worker.finished = true
            if worker.budget_ticket then
                ProcessBudget:release(worker.budget_ticket)
                worker.budget_ticket = nil
            end
            dispatchCallback(worker, false, tostring(result_fd_or_err or "无法启动 Provider 后台任务"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.payload_path = payload_path
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    ProcessBudget:request{
        owner = worker,
        label = opts.label or ("provider:" .. tostring(op)),
        priority = tonumber(opts.priority)
            or (lane == "foreground" and self.foreground_priority or self.background_priority),
        lane = lane,
        on_start = function(ticket) spawn(ticket) end,
        on_preempt = function() self:cancel(worker, "preempted") end,
        on_error = function(err)
            worker.finished = true
            dispatchCallback(worker, false, tostring(err))
        end,
    }
    return worker
end

function AsyncProviderTask:cancel(worker, reason)
    if not worker or worker.cancelled then return end
    worker.cancelled = true
    worker.cancel_reason = reason or "cancelled"
    if worker.finished then return end
    if worker.budget_ticket and worker.budget_ticket.state == "queued" then
        ProcessBudget:cancel(worker.budget_ticket)
        worker.budget_ticket = nil
        worker.finished = true
        return
    end
    if not worker.pid then
        worker.finished = true
        if worker.budget_ticket then
            ProcessBudget:release(worker.budget_ticket)
            worker.budget_ticket = nil
        end
        return
    end
    ffiutil.terminateSubProcess(worker.pid)
    local function finishCancel()
        worker.finished = true
        if worker.result_fd then pcall(ffiutil.readAllFromFD, worker.result_fd) end
        worker.result_fd = nil
        SubprocessPayload:cleanup(worker.payload_path)
        worker.payload_path = nil
        if worker.budget_ticket then
            ProcessBudget:release(worker.budget_ticket)
            worker.budget_ticket = nil
        end
    end
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then finishCancel()
        else UIManager:scheduleIn(self.reap_interval, reap) end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

return AsyncProviderTask
