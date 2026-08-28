local socket = require("socket")

local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local SourceDiagnosticLog = {}

local function clean(value, limit)
    value = tostring(value or "")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
    limit = tonumber(limit)
    if limit and #value > limit then value = value:sub(1, limit) .. "…[truncated]" end
    return value
end

function SourceDiagnosticLog:getPath()
    return Util.joinPath(Storage:getLogsDir(), "source-compatibility.log")
end

function SourceDiagnosticLog:getPreviousPath()
    return Util.joinPath(Storage:getLogsDir(), "source-compatibility.previous.log")
end

function SourceDiagnosticLog:_write(mode, text)
    local path = self:getPath()
    Util.mkdirp(Storage:getLogsDir())
    local file, err = io.open(path, mode or "ab")
    if not file then return nil, tostring(err or "无法打开诊断日志") end
    local ok, write_err = file:write(text or "")
    if ok then file:flush() end
    file:close()
    if not ok then return nil, tostring(write_err or "无法写入诊断日志") end
    return path
end

function SourceDiagnosticLog:begin(keyword, total)
    Util.mkdirp(Storage:getLogsDir())
    local path, previous = self:getPath(), self:getPreviousPath()
    os.remove(previous)
    local old = io.open(path, "rb")
    if old then
        old:close()
        os.rename(path, previous)
    end
    local header = table.concat({
        "Leko 书源检查记录",
        "started_at=" .. os.date("%Y-%m-%d %H:%M:%S"),
        "keyword=" .. clean(keyword, 200),
        "total_sources=" .. tostring(total or 0),
        "mode=search -> any-usable-candidate -> detail -> toc -> readable-content",
        "note=不要求搜索结果与《" .. clean(keyword, 120) .. "》同名；只要找到可用结果就继续检查详情、目录和正文。",
        "note=搜索成功但没有找到可测试的书时记为 INCONCLUSIVE，不计为失败。",
        "note=每条书源开始和完成时都会立即保存；中途退出时，已完成的记录仍然保留。",
        string.rep("-", 72),
        "",
    }, "\n")
    return self:_write("wb", header)
end

function SourceDiagnosticLog:appendRaw(text)
    return self:_write("ab", clean(text))
end

function SourceDiagnosticLog:appendStart(index, total, entry)
    local line = string.format("%s [%03d/%03d] START source=%s id=%s capability=%s\n",
        os.date("%Y-%m-%d %H:%M:%S"), tonumber(index or 0) or 0, tonumber(total or 0) or 0,
        clean(entry and entry.name or ""):gsub("\n", " "),
        clean(entry and entry.id or ""):gsub("\n", " "),
        clean(entry and entry.capability_profile or "尚未分析"):gsub("\n", " "))
    return self:_write("ab", line)
end

function SourceDiagnosticLog:appendResult(index, total, entry, result)
    result = type(result) == "table" and result or {}
    local status = clean(result.status or "PROCESS_ERROR"):gsub("\n", " ")
    local stage = clean(result.stage or "unknown"):gsub("\n", " ")
    local code = clean(result.code or ""):gsub("\n", " ")
    local compatibility_class = clean(result.compatibility_class or ""):gsub("\n", " ")
    local elapsed = tonumber(result.elapsed_ms or 0) or 0
    local fields = {
        string.format("%s [%03d/%03d] %s source=%s stage=%s elapsed_ms=%d",
            os.date("%Y-%m-%d %H:%M:%S"), tonumber(index or 0) or 0, tonumber(total or 0) or 0,
            status, clean(entry and entry.name or ""):gsub("\n", " "), stage, elapsed),
    }
    if code ~= "" then fields[1] = fields[1] .. " code=" .. code end
    if compatibility_class ~= "" then fields[1] = fields[1] .. " compatibility_class=" .. compatibility_class end
    if result.search_results ~= nil then fields[1] = fields[1] .. " search_results=" .. tostring(result.search_results) end
    if result.search_keyword and tostring(result.search_keyword) ~= "" then fields[1] = fields[1] .. " search_keyword=" .. string.format("%q", clean(result.search_keyword, 160):gsub("\n", " ")) end
    if result.keyword_mode and tostring(result.keyword_mode) ~= "" then fields[1] = fields[1] .. " keyword_mode=" .. clean(result.keyword_mode, 80):gsub("\n", " ") end
    local function appendSearchDiagnostic(prefix, diagnostic)
        if type(diagnostic) ~= "table" then return end
        fields[1] = fields[1]
            .. " " .. prefix .. "_response_url=" .. string.format("%q", clean(diagnostic.response_url, 240):gsub("\n", " "))
            .. " " .. prefix .. "_status=" .. clean(diagnostic.response_status, 40):gsub("\n", " ")
            .. " " .. prefix .. "_code=" .. clean(diagnostic.response_code, 40):gsub("\n", " ")
            .. " " .. prefix .. "_content_type=" .. string.format("%q", clean(diagnostic.content_type, 120):gsub("\n", " "))
            .. " " .. prefix .. "_body_bytes=" .. tostring(diagnostic.response_bytes or 0)
            .. " " .. prefix .. "_rule_type=" .. clean(diagnostic.book_list_rule_type, 40):gsub("\n", " ")
            .. " " .. prefix .. "_nodes=" .. tostring(diagnostic.book_list_nodes or 0)
            .. " " .. prefix .. "_response_class=" .. clean(diagnostic.response_class, 60):gsub("\n", " ")
            .. " " .. prefix .. "_parser_outcome=" .. clean(diagnostic.parser_outcome, 60):gsub("\n", " ")
            .. " " .. prefix .. "_rule=" .. string.format("%q", clean(diagnostic.book_list_rule, 260):gsub("\n", " "))
            .. " " .. prefix .. "_preview=" .. string.format("%q", clean(diagnostic.response_preview, 300):gsub("\n", " "))
    end
    appendSearchDiagnostic("search", result.search_diagnostic)
    appendSearchDiagnostic("fallback_search", result.fallback_search_diagnostic)
    if result.candidate_rank ~= nil then fields[1] = fields[1] .. " candidate_rank=" .. tostring(result.candidate_rank) end
    if result.candidate_mode and tostring(result.candidate_mode) ~= "" then fields[1] = fields[1] .. " candidate_mode=" .. clean(result.candidate_mode, 80):gsub("\n", " ") end
    if result.chapter_count ~= nil then fields[1] = fields[1] .. " chapters=" .. tostring(result.chapter_count) end
    if result.content_chars ~= nil then fields[1] = fields[1] .. " content_chars=" .. tostring(result.content_chars) end
    if type(result.runtime_trace) == "table" then
        local trace = result.runtime_trace
        fields[1] = fields[1]
            .. " quickjs_evaluations=" .. tostring(trace.js_evaluation_count or 0)
            .. " host_api_calls=" .. tostring(trace.host_api_call_count or 0)
            .. " java_bridge_called=" .. tostring(trace.java_bridge_called == true)
            .. " requests=" .. tostring(trace.request_count or 0)
            .. " interaction_required=" .. tostring(trace.interaction_required == true)
        if type(trace.last_request) == "table" then
            fields[1] = fields[1]
                .. " last_request_stage=" .. clean(trace.last_request.stage or "", 40):gsub("\n", " ")
                .. " last_request_method=" .. clean(trace.last_request.method or "", 12):gsub("\n", " ")
                .. " last_request_url=" .. string.format("%q", clean(trace.last_request.url or "", 260):gsub("\n", " "))
                .. " last_request_code=" .. tostring(trace.last_request.code or "")
        end
    end
    if result.book_title and tostring(result.book_title) ~= "" then
        fields[#fields + 1] = "book=" .. clean(result.book_title):gsub("\n", " ")
    end
    if type(result.samples) == "table" and #result.samples > 0 then
        fields[#fields + 1] = "samples=" .. clean(table.concat(result.samples, " | ")):gsub("\n", " ")
    end
    if type(result.candidate_attempts) == "table" and #result.candidate_attempts > 0 then
        local attempt_lines = {}
        for _, attempt in ipairs(result.candidate_attempts) do
            attempt_lines[#attempt_lines + 1] = string.format("#%s %s %s stage=%s code=%s%s",
                tostring(attempt.rank or "?"), clean(attempt.mode or "", 60):gsub("\n", " "),
                clean(attempt.book_title or attempt.title or "", 160):gsub("\n", " "),
                clean(attempt.stage or "", 40):gsub("\n", " "),
                clean(attempt.code or "", 80):gsub("\n", " "),
                attempt.error and (" error=" .. clean(attempt.error):gsub("\n", " ")) or "")
        end
        fields[#fields + 1] = "candidate_attempts=" .. table.concat(attempt_lines, " || ")
    end
    if result.error and tostring(result.error) ~= "" then
        fields[#fields + 1] = "error=" .. clean(result.error)
    end
    if result.trace and tostring(result.trace) ~= "" then
        fields[#fields + 1] = "trace=" .. clean(result.trace)
    end
    fields[#fields + 1] = ""
    return self:_write("ab", table.concat(fields, "\n"))
end

function SourceDiagnosticLog:appendFooter(summary, cancelled)
    summary = type(summary) == "table" and summary or {}
    local line = string.format(
        "%s SESSION_%s completed=%d/%d full_pass=%d inconclusive=%d runtime_or_rule=%d request=%d access=%d timeout=%d process=%d\n",
        os.date("%Y-%m-%d %H:%M:%S"), cancelled and "CANCELLED" or "DONE",
        tonumber(summary.completed or 0) or 0, tonumber(summary.total or 0) or 0,
        tonumber(summary.full_pass or 0) or 0, tonumber(summary.inconclusive or 0) or 0,
        tonumber(summary.runtime_or_rule or 0) or 0, tonumber(summary.request_error or 0) or 0,
        tonumber(summary.access_required or 0) or 0, tonumber(summary.timeout or 0) or 0,
        tonumber(summary.process_error or 0) or 0)
    return self:_write("ab", "\n" .. string.rep("-", 72) .. "\n" .. line)
end

function SourceDiagnosticLog:readTail(max_bytes)
    local path = self:getPath()
    local file = io.open(path, "rb")
    if not file then return nil, path end
    local size = file:seek("end") or 0
    max_bytes = math.max(1024, tonumber(max_bytes or 12000) or 12000)
    file:seek("set", math.max(0, size - max_bytes))
    local data = file:read("*a")
    file:close()
    return data, path
end

return SourceDiagnosticLog
