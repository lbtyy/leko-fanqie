local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local rapidjson = require("rapidjson")
local socket = require("socket")

local ProcessBudget = require("Leko/ProcessBudget")
local QuickJS = require("Leko/QuickJS")
local UI = require("Leko/UI")

local QuickJSRuntimeCheck = {
    worker = nil,
    budget_ticket = nil,
    poll_interval = 0.25,
    timeout_seconds = 8,
    max_result_bytes = 64 * 1024,
}

local function now()
    if socket and type(socket.gettime) == "function" then return socket.gettime() end
    return os.clock()
end

local function yesNo(value)
    return value and "是" or "否"
end

local function bytes(value)
    value = tonumber(value or 0) or 0
    if value < 1024 then return string.format("%d B", value) end
    if value < 1024 * 1024 then return string.format("%.1f KB", value / 1024) end
    return string.format("%.2f MB", value / (1024 * 1024))
end

local function resultText(result)
    if type(result) ~= "table" then return tostring(result or "无") end
    return string.format("脚本运算=%s；文本匹配=%s；Java 调用=%s；加密功能=%s",
        tostring(result.mapped or ""), yesNo(result.regex),
        yesNo(result.bridge_return_is_undefined),
        yesNo(result.aes_direct_api and result.aes_object_api))
end

local function failedReport(message, crashed)
    return {
        native_loaded = false,
        engine = "未知",
        bridge = "未知",
        abi = "未知",
        result = nil,
        bridge_called = false,
        elapsed_ms = 0,
        peak_memory_bytes = 0,
        error = tostring(message or "JavaScript 引擎没有返回检查结果"),
        crashed = crashed == true,
        ok = false,
    }
end

local function friendlyError(message)
    local text = tostring(message or "")
    local lower = text:lower()
    if lower:find("not found", 1, true) or lower:find("unavailable", 1, true) then
        return "找不到随插件安装的 JavaScript 引擎文件。请重新安装完整的 Leko 插件。"
    end
    if lower:find("abi mismatch", 1, true) or lower:find("probe failed", 1, true) then
        return "JavaScript 引擎文件与当前插件版本不匹配。请重新安装同一版本的完整插件。"
    end
    if lower:find("quarantined", 1, true) or lower:find("crash", 1, true) then
        return "JavaScript 引擎此前意外退出，本次已停止使用。重新启动 KOReader 后可以再检查一次。"
    end
    return text ~= "" and text or "脚本结果不符合预期。"
end

local function renderReport(report)
    report = type(report) == "table" and report or failedReport("自检结果损坏")
    local conclusion
    if report.crashed then
        conclusion = "结果：JavaScript 引擎意外退出，但没有影响 KOReader。"
    elseif report.ok then
        conclusion = "结果：JavaScript 引擎工作正常。"
    else
        conclusion = "结果：检查没有通过。\n" .. friendlyError(report.error)
    end
    return table.concat({
        "JavaScript 引擎检查",
        "",
        "引擎加载：" .. yesNo(report.native_loaded),
        "QuickJS 版本：" .. tostring(report.engine or "未知"),
        "脚本测试：" .. resultText(report.result),
        "耗时：" .. tostring(report.elapsed_ms or 0) .. " ms",
        "最高内存占用：" .. bytes(report.peak_memory_bytes),
        "安全隔离：是",
        "",
        conclusion,
    }, "\n")
end

local function encodeChildReport(report)
    local ok, encoded = pcall(rapidjson.encode, report)
    if ok and type(encoded) == "string" and #encoded <= QuickJSRuntimeCheck.max_result_bytes then
        return encoded
    end
    local fallback = failedReport("无法保存 JavaScript 引擎检查结果")
    local fallback_ok, fallback_encoded = pcall(rapidjson.encode, fallback)
    return fallback_ok and fallback_encoded or "{}"
end

function QuickJSRuntimeCheck:_release(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
    if self.budget_ticket and (not worker or self.budget_ticket == worker.budget_ticket) then
        self.budget_ticket = nil
    end
end

function QuickJSRuntimeCheck:_closeLoading(holder)
    if holder and holder.loading then
        pcall(UIManager.close, UIManager, holder.loading)
        holder.loading = nil
    end
end

function QuickJSRuntimeCheck:_finish(holder, report, worker)
    if not holder or holder.finished then return end
    holder.finished = true
    if worker and self.worker == worker then self.worker = nil end
    self:_release(worker)
    self:_closeLoading(holder)
    UIManager:show(InfoMessage:new{ text = renderReport(report) })
end

function QuickJSRuntimeCheck:_readReport(worker)
    local raw = ""
    if worker and worker.result_fd and type(ffiutil.readAllFromFD) == "function" then
        raw = ffiutil.readAllFromFD(worker.result_fd) or ""
        worker.result_fd = nil
    end
    local ok, report = pcall(rapidjson.decode, raw)
    if ok and type(report) == "table" then return report end
    return failedReport(
        "JavaScript 引擎在返回结果前意外退出，但没有影响 KOReader。", true)
end

function QuickJSRuntimeCheck:_poll(worker)
    if self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        worker.finished = true
        local report
        if worker.preempted then
            report = failedReport("检查被正在进行的阅读任务暂时打断")
        elseif worker.timed_out then
            report = failedReport("JavaScript 引擎检查超时")
        else
            report = self:_readReport(worker)
            if report.crashed then
                QuickJS:markNativeUnsafe(report.error)
            end
        end
        self:_finish(worker.holder, report, worker)
        return
    end
    if now() - worker.started_at >= self.timeout_seconds and not worker.timed_out then
        worker.timed_out = true
        pcall(ffiutil.terminateSubProcess, worker.pid)
    end
    UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
end

function QuickJSRuntimeCheck:_spawn(holder, budget_ticket)
    if holder.finished then
        ProcessBudget:release(budget_ticket)
        return
    end
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, report = xpcall(function()
            return QuickJS:selfCheck()
        end, debug.traceback)
        if not ok then report = failedReport(report) end
        if write_fd and type(ffiutil.writeToFD) == "function" then
            ffiutil.writeToFD(write_fd, encodeChildReport(report), true)
        end
    end, true)
    if not pid then
        self:_finish(holder, failedReport("无法启动 JavaScript 引擎检查：" .. tostring(result_fd_or_err)))
        ProcessBudget:release(budget_ticket)
        return
    end
    local worker = {
        pid = pid,
        result_fd = result_fd_or_err,
        holder = holder,
        started_at = now(),
        finished = false,
        budget_ticket = budget_ticket,
    }
    self.worker = worker
    budget_ticket.on_preempt = function()
        if not worker.finished then
            worker.preempted = true
            pcall(ffiutil.terminateSubProcess, worker.pid)
        end
    end
    UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
end

function QuickJSRuntimeCheck:_request(holder)
    local ticket
    ticket = ProcessBudget:request{
        owner = self,
        label = "quickjs-runtime-check",
        priority = 100,
        lane = "foreground",
        on_start = function(granted) self:_spawn(holder, granted) end,
        on_preempt = function(granted)
            if self.worker then
                self.worker.preempted = true
                pcall(ffiutil.terminateSubProcess, self.worker.pid)
            else
                self:_finish(holder, failedReport("检查被正在进行的阅读任务暂时打断"))
                ProcessBudget:release(granted)
            end
        end,
        on_error = function(err)
            self:_finish(holder, failedReport("JavaScript 引擎检查暂时无法开始：" .. tostring(err)))
        end,
    }
    if ticket.state == "queued" then self.budget_ticket = ticket end
end

function QuickJSRuntimeCheck:show(owner)
    if self.worker or self.budget_ticket then
        return UI.showLater(owner, "quickjs_runtime_check_busy", function()
            return InfoMessage:new{ text = "JavaScript 引擎正在检查中。" }
        end)
    end
    local holder = { loading = nil, finished = false }
    return UI.showLater(owner, "quickjs_runtime_check", function()
        local loading = InfoMessage:new{
            text = "正在检查 JavaScript 引擎，请稍候……",
            dismissable = false,
        }
        holder.loading = loading
        if type(UIManager.nextTick) == "function" then
            UIManager:nextTick(function() self:_request(holder) end)
        else
            self:_request(holder)
        end
        return loading
    end)
end

QuickJSRuntimeCheck.renderReport = renderReport

return QuickJSRuntimeCheck
