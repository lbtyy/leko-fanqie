local rapidjson = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local AsyncSourceCatalog = require("Leko/AsyncSourceCatalog")
local BookIdentity = require("Leko/BookIdentity")
local ExecutionTrace = require("Leko/ExecutionTrace")
local LegadoSource = require("Leko/LegadoSource")
local ProcessBudget = require("Leko/ProcessBudget")
local SourceDiagnosticLog = require("Leko/SourceDiagnosticLog")
local StageError = require("Leko/StageError")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local AsyncSourceDiagnostic = {}
AsyncSourceDiagnostic.__index = AsyncSourceDiagnostic

local POLL_INTERVAL = 0.20
local REAP_INTERVAL = 0.20
local BATCH_YIELD = 0.10
local SOURCE_DEADLINE = 40
local PROCESS_PRIORITY = 28
local PIPE_PAYLOAD_LIMIT = 2 * 1024
local MAX_SEARCH_RESULTS = 50
local MAX_CHAIN_CANDIDATES = 3
local MAX_CONTENT_CHAPTERS = 3
local MIN_CONTENT_CHARS = 1

local function encodePipe(payload)
    payload = type(payload) == "table" and payload or {}
    -- The child has already appended the complete, lossless result to disk.
    -- The pipe is control-plane IPC only.  Always send a tiny bounded summary
    -- so a Kindle's ~4 KiB pipe can never fill while the parent is waiting for
    -- process exit (the historical 159-second RESULT_DAMAGED deadlock).
    local summary = {
        status = payload.status or "PROCESS_ERROR",
        stage = payload.stage or "process",
        code = payload.code or "",
        compatibility_class = payload.compatibility_class or "",
        elapsed_ms = tonumber(payload.elapsed_ms) or 0,
        search_results = tonumber(payload.search_results) or nil,
        candidate_rank = tonumber(payload.candidate_rank) or nil,
        chapter_rank = tonumber(payload.chapter_rank) or nil,
        chapters = tonumber(payload.chapters) or nil,
        content_chars = tonumber(payload.content_chars) or nil,
        book = tostring(payload.book or ""):sub(1, 180),
    }
    local trace = type(payload.runtime_trace) == "table" and payload.runtime_trace or nil
    if trace then
        summary.quickjs_evaluation_count = tonumber(trace.js_evaluation_count) or 0
        summary.host_api_call_count = tonumber(trace.host_api_call_count) or 0
        summary.java_bridge_called = trace.java_bridge_called == true
        summary.interaction_required = trace.interaction_required == true
        if type(trace.last_request) == "table" then
            summary.last_request = {
                stage = trace.last_request.stage,
                method = trace.last_request.method,
                url = trace.last_request.url,
                code = trace.last_request.code,
                ok = trace.last_request.ok,
            }
        end
    end
    local ok, encoded = pcall(rapidjson.encode, summary)
    if ok and #encoded <= PIPE_PAYLOAD_LIMIT then return encoded end
    local fallback = {
        status = summary.status, stage = summary.stage, code = summary.code,
        elapsed_ms = summary.elapsed_ms,
    }
    ok, encoded = pcall(rapidjson.encode, fallback)
    return ok and encoded or '{"status":"PROCESS_ERROR","stage":"process","code":"SERIALIZE_FAILED"}'
end

local function closeResultPipe(worker)
    if not worker or not worker.result_fd then return nil end
    local fd = worker.result_fd
    worker.result_fd = nil
    local ok, raw = pcall(ffiutil.readAllFromFD, fd)
    return ok and raw or nil
end

local function errorClass(stage, err)
    local code = StageError:code(err) or ""
    local text = tostring(err or "")
    -- A parse-stage wrapper can carry an explicit browser requirement from a
    -- request-rule JS callback. Preserve the actionable access boundary.
    if text:find("WEBVIEW_REQUIRED", 1, true) then
        return "ACCESS_REQUIRED", "WEBVIEW_REQUIRED"
    end
    if text:find("INTERACTION_REQUIRED", 1, true)
            or text:find("PAY_ACTION_REQUIRED", 1, true)
            or text:find("LOGIN_CHECK_FAILED", 1, true) then
        if text:find("PAY_ACTION_REQUIRED", 1, true) then return "ACCESS_REQUIRED", "PAY_ACTION_REQUIRED" end
        if text:find("LOGIN_CHECK_FAILED", 1, true) then return "ACCESS_REQUIRED", "LOGIN_CHECK_FAILED" end
        return "ACCESS_REQUIRED", "INTERACTION_REQUIRED"
    end
    if code == "WEBVIEW_REQUIRED" or code == "INTERACTION_REQUIRED"
            or code == "PAY_ACTION_REQUIRED" or code == "LOGIN_CHECK_FAILED" then
        return "ACCESS_REQUIRED", code
    end
    if code == "SEARCH_REQUEST_FAILED" or code == "DETAIL_REQUEST_FAILED"
            or code == "TOC_REQUEST_FAILED" or code == "CONTENT_REQUEST_FAILED" then
        return "REQUEST_ERROR", code
    end
    if code == "SCRIPT_UNSUPPORTED" or code == "RULE_UNSUPPORTED"
            or code == "REQUEST_RULE_FAILED" or code == "REQUEST_URL_EMPTY"
            or code == "REQUEST_URL_INVALID" or code == "CHARSET_FAILED"
            or code == "DATA_URI_INVALID" or code == "SEARCH_PARSE_EMPTY"
            or code == "DETAIL_PARSE_FAILED" or code == "TOC_PARSE_EMPTY"
            or code == "CONTENT_PARSE_EMPTY" then
        return "RUNTIME_OR_RULE", code
    end
    local lower_text = text:lower()
    if lower_text:find("timeout", 1, true) or lower_text:find("timed out", 1, true) then
        return "REQUEST_ERROR", code ~= "" and code or "NETWORK_TIMEOUT"
    end
    if lower_text:find("http", 1, true) or lower_text:find("network", 1, true)
            or text:find("连接", 1, true) or text:find("dns", 1, true) then
        return "REQUEST_ERROR", code ~= "" and code or "NETWORK_OR_HTTP"
    end
    return "RUNTIME_OR_RULE", code ~= "" and code or (tostring(stage or "unknown"):upper() .. "_FAILED")
end

-- Stable machine-readable category for the compatibility matrix.  Keep the
-- older status/code pair for existing UI consumers, but expose whether a
-- failure is transport, rule/host, or an explicit interaction boundary.
local function compatibilityClass(status, stage, code, err)
    status, stage, code = tostring(status or ""), tostring(stage or ""), tostring(code or "")
    local text = tostring(err or ""):lower()
    if status == "FULL_PASS" or status == "READABLE_PASS" then return "FULL_PASS" end
    if status == "INCONCLUSIVE" or code == "SEARCH_OK_NO_CANDIDATE" then return "NO_CANDIDATE" end
    if code == "WEBVIEW_REQUIRED" or text:find("WEBVIEW_REQUIRED", 1, true) then
        return "BROWSER_INTERACTION_REQUIRED"
    end
    if text:find("browser verification", 1, true) or code == "INTERACTION_REQUIRED" then
        return "BROWSER_INTERACTION_REQUIRED"
    end
    if code == "LOGIN_CHECK_FAILED" or text:find("login", 1, true) then return "LOGIN_REQUIRED" end
    if text:find("host-unsupported", 1, true) or text:find("unsupported java", 1, true)
            or code == "HOST_API_UNSUPPORTED" then return "HOST_API_UNSUPPORTED" end
    if text:find("quickjs", 1, true) or text:find("syntaxerror", 1, true)
            or code == "SCRIPT_UNSUPPORTED" or code == "QUICKJS_FAILURE" then return "QUICKJS_FAILURE" end
    if code == "TLS_FAILURE" or text:find("tls", 1, true) or text:find("ssl", 1, true)
            or text:find("certificate", 1, true) then return "TLS_FAILURE" end
    if status == "REQUEST_ERROR" or code:find("_REQUEST_FAILED", 1, true) then
        if text:find("http 4", 1, true) or text:find("http 5", 1, true)
                or text:find(" 401", 1, true) or text:find(" 403", 1, true)
                or text:find(" 404", 1, true) or text:find(" 429", 1, true) then
            return "HTTP_REJECTED"
        end
        return "NETWORK_FAILURE"
    end
    if status == "ACCESS_REQUIRED" then return "BROWSER_INTERACTION_REQUIRED" end
    if status == "PROCESS_ERROR" and (stage == "process" or stage == "runner") then return "QUICKJS_FAILURE" end
    return "RULE_MISMATCH"
end

local function samplesFrom(results)
    local samples = {}
    for index = 1, math.min(3, #(results or {})) do
        local item = results[index] or {}
        samples[#samples + 1] = Util.collapseSpaces(tostring(item.title or ""))
            .. (tostring(item.author or "") ~= "" and (" / " .. Util.collapseSpaces(tostring(item.author))) or "")
    end
    return samples
end

local function diagnosticKeyword(source, fallback)
    local rules = type(source and source.rule_search) == "table" and source.rule_search or {}
    local raw = type(source and source.raw) == "table" and source.raw or {}
    local raw_rules = type(raw.ruleSearch) == "table" and raw.ruleSearch
        or (type(raw.rule_search) == "table" and raw.rule_search or {})
    local configured = rules.checkKeyWord or rules.checkKeyword
        or raw_rules.checkKeyWord or raw_rules.checkKeyword
        or raw.checkKeyWord or raw.checkKeyword
    configured = Util.trim(tostring(configured or ""))
    if configured ~= "" and #configured <= 120
            and not configured:find("://", 1, true)
            and configured:sub(1, 2) ~= "--" then
        return configured, "source-check-keyword"
    end
    return Util.trim(tostring(fallback or "我的")), "fallback-keyword"
end

local function orderedCandidates(found, keyword)
    local output, seen = {}, {}
    local exact = BookIdentity:bestExactTitle(found, keyword, nil, false)
    local function append(item, mode)
        if type(item) ~= "table" then return end
        local key = tostring(item.book_url or item.url or "") .. "\n"
            .. tostring(item.title or "") .. "\n" .. tostring(item.author or "")
        if seen[key] then return end
        seen[key] = true
        output[#output + 1] = { item = item, mode = mode }
    end
    append(exact, "exact-preferred")
    for _, item in ipairs(found or {}) do append(item, exact == item and "exact-preferred" or "search-fallback") end
    return output
end

local function readableChapters(chapters)
    local free, other, seen = {}, {}, {}
    local function append(bucket, chapter)
        if not chapter then return end
        local key = tostring(chapter.url or chapter.id or chapter.title or "")
        if seen[key] then return end
        seen[key] = true
        bucket[#bucket + 1] = chapter
    end
    for _, chapter in ipairs(chapters or {}) do
        if not chapter.is_vip and not chapter.is_pay then append(free, chapter)
        else append(other, chapter) end
    end

    -- Compatibility means “can this source yield readable text”, not “is its
    -- very first chapter healthy”.  Sample the free range rather than burning
    -- all three probes on adjacent front-matter/locked chapters.
    local output, picked = {}, {}
    local function sample(pool)
        local n = #pool
        if n == 0 then return end
        local indices = n == 1 and {1}
            or n == 2 and {1, 2}
            or {1, math.max(2, math.floor((n + 1) / 2)), n}
        for _, index in ipairs(indices) do
            local chapter = pool[index]
            local key = chapter and tostring(chapter.url or chapter.id or chapter.title or "") or ""
            if chapter and not picked[key] then
                picked[key] = true
                output[#output + 1] = chapter
                if #output >= MAX_CONTENT_CHAPTERS then return true end
            end
        end
    end
    if sample(free) then return output end
    sample(other)
    return output
end

local STAGE_DEPTH = { detail = 1, toc = 2, content = 3 }

local function executeDiagnostic(entry, keyword)
    local started = socket.gettime()
    local source
    local result = {
        status = "PROCESS_ERROR",
        stage = "source",
        source_id = entry.id,
        source_name = entry.name,
    }
    local function bookFields(book)
        if type(book) ~= "table" then return nil end
        return {
            title = tostring(book.title or ""), author = tostring(book.author or ""),
            kind = tostring(book.kind or ""), toc_url = tostring(book.toc_url or ""),
            cover_present = tostring(book.cover or "") ~= "",
            intro_chars = #tostring(book.intro or ""),
            variable_keys = (function()
                local keys = {}
                for key in pairs(book.variables or {}) do if tostring(key):sub(1, 2) ~= "__" then keys[#keys + 1] = tostring(key) end end
                table.sort(keys); return keys
            end)(),
        }
    end
    local function classifyFailure(stage, err, target)
        target = target or result
        local status, code = errorClass(stage, err)
        target.status, target.stage, target.code = status, stage, code
        target.error = tostring(err or "未知错误")
        target.compatibility_class = compatibilityClass(status, stage, code, target.error)
        return target
    end
    local function finish(target)
        target = target or result
        target.elapsed_ms = math.floor(math.max(0, socket.gettime() - started) * 1000 + 0.5)
        target.compatibility_class = compatibilityClass(target.status, target.stage, target.code, target.error)
        local succeeded = target.status == "FULL_PASS" or target.status == "READABLE_PASS"
        target.stage_evidence = { success_stage = succeeded and "complete" or nil,
            code = target.code, reason = target.error }
        if not succeeded then target.stage_evidence.failure_stage = target.stage end
        if source then
            target.runtime_trace = ExecutionTrace:finish(source)
        end
        return target
    end

    local source_err
    source, source_err = Storage:readSourceRecord(entry.records_path, entry.record_offset,
        entry.record_length, entry.id, true)
    if not source then return finish(classifyFailure("source", source_err or "找不到书源定义")) end
    source._suppress_runtime_persist = true
    source._diagnostic_full_errors = true
    source._diagnostic_trace_enabled = true
    ExecutionTrace:begin(source)
    local function setStage(stage)
        source._diagnostic_stage = stage
        ExecutionTrace:setStage(source, stage)
    end
    local function copySearchDiagnostic()
        local diagnostic = source._last_search_diagnostic
        if type(diagnostic) ~= "table" then return nil end
        local copied = {}
        for key, value in pairs(diagnostic) do copied[key] = value end
        return copied
    end

    local search_keyword, keyword_mode = diagnosticKeyword(source, keyword)
    result.search_keyword, result.keyword_mode = search_keyword, keyword_mode
    result.stage = "search"
    setStage("search")
    local found, search_err = LegadoSource:search(source, search_keyword, 1, {
        cache_read = false,
        cache_write = false,
        save_runtime = false,
        max_results = MAX_SEARCH_RESULTS,
        request_options = {
            timeout = 8,
            maxtime = 12,
            retries = 0,
            max_bytes = 2 * 1024 * 1024,
        },
    })
    if not found then return finish(classifyFailure("search", search_err or "搜索失败")) end

    result.search_diagnostic = copySearchDiagnostic()

    -- A stale source-authored checkKeyWord may legitimately return nothing.
    -- Give the deterministic fallback keyword one chance before declaring the
    -- source non-diagnostic; an empty search is not a compatibility failure.
    local fallback_keyword = Util.trim(tostring(keyword or "我的"))
    if #found == 0 and keyword_mode == "source-check-keyword"
            and fallback_keyword ~= "" and fallback_keyword ~= search_keyword then
        local fallback_found, fallback_err = LegadoSource:search(source, fallback_keyword, 1, {
            cache_read = false, cache_write = false, save_runtime = false,
            max_results = MAX_SEARCH_RESULTS,
            request_options = { timeout = 8, maxtime = 12, retries = 0, max_bytes = 2 * 1024 * 1024 },
        })
        if fallback_found then
            found = fallback_found
            result.search_keyword, result.keyword_mode = fallback_keyword, "fallback-after-empty-check-keyword"
            result.search_diagnostic = copySearchDiagnostic() or result.search_diagnostic
        elseif fallback_err then
            -- The first search did execute successfully, so do not turn a
            -- secondary fallback request failure into a false incompatibility.
            result.fallback_search_error = tostring(fallback_err)
            result.fallback_search_diagnostic = copySearchDiagnostic()
        end
    end

    result.search_results = #found
    result.samples = samplesFrom(found)
    if #found == 0 then
        result.status, result.stage, result.code = "INCONCLUSIVE", "search", "SEARCH_OK_NO_CANDIDATE"
        result.error = "搜索成功，但没有找到可继续检查目录和正文的书；不计为失败"
        return finish(result)
    end

    local candidates = orderedCandidates(found, result.search_keyword)
    local attempts, best_failure, best_depth = {}, nil, -1
    for rank = 1, math.min(MAX_CHAIN_CANDIDATES, #candidates) do
        local wrapper = candidates[rank]
        local candidate = wrapper.item
        local attempt = {
            rank = rank,
            mode = wrapper.mode,
            title = tostring(candidate.title or ""),
            url = tostring(candidate.book_url or candidate.url or ""),
            stage = "detail",
        }
        attempts[#attempts + 1] = attempt

        setStage("detail")
        local info, detail_err = LegadoSource:getBookInfo(source, candidate, {
            cache_read = false, cache_write = false, save_runtime = false,
        })
        if not info then
            classifyFailure("detail", detail_err or "详情失败", attempt)
        else
            ExecutionTrace:state(source, "book", info)
            attempt.book_title = info.title or candidate.title
            attempt.stage = "toc"
            setStage("toc")
            local chapters, toc_err = LegadoSource:getToc(source, info, {
                cache_read = false, cache_write = false, save_runtime = false,
                -- Device compatibility/connection details must exercise the
                -- same WebBook production preUpdateJs branch as a real TOC
                -- refresh, otherwise a source can be misclassified at TOC.
                run_per_js = true,
            })
            if not chapters or #chapters == 0 then
                classifyFailure("toc", toc_err or "目录为空", attempt)
            else
                attempt.chapter_count = #chapters
                attempt.stage = "content"
                setStage("content")
                local chapter_candidates = readableChapters(chapters)
                local last_content_err
                for chapter_rank = 1, math.min(MAX_CONTENT_CHAPTERS, #chapter_candidates) do
                    local chapter = chapter_candidates[chapter_rank]
                    ExecutionTrace:state(source, "chapter", chapter)
                    local content, content_err = LegadoSource:getContent(source, info, chapter)
                    if content and #Util.trim(content) >= MIN_CONTENT_CHARS then
                        setStage("complete")
                        result.status, result.stage, result.code = "FULL_PASS", "complete", "OK"
                        result.book_title = info.title or candidate.title
                        result.book_fields = bookFields(info)
                        result.candidate_rank = rank
                        result.candidate_mode = wrapper.mode
                        result.chapter_rank = chapter_rank
                        result.chapter_count = #chapters
                        result.content_chars = #content
                        result.candidate_attempts = attempts
                        return finish(result)
                    end
                    last_content_err = content_err or ("正文不足 " .. tostring(MIN_CONTENT_CHARS) .. " 字符")
                end
                classifyFailure("content", last_content_err or "没有可验证正文的章节", attempt)
            end
        end

        local depth = STAGE_DEPTH[attempt.stage] or 0
        if depth > best_depth then best_failure, best_depth = attempt, depth end
    end

    best_failure = best_failure or attempts[1]
    result.status = best_failure and best_failure.status or "RUNTIME_OR_RULE"
    result.stage = best_failure and best_failure.stage or "detail"
    result.code = best_failure and best_failure.code or "DETAIL_PARSE_FAILED"
    result.error = best_failure and best_failure.error or "找到的结果都无法继续打开详情、目录或正文"
    result.book_title = best_failure and (best_failure.book_title or best_failure.title) or nil
    result.candidate_attempts = attempts
    return finish(result)
end

function AsyncSourceDiagnostic:new(options)
    options = options or {}
    local instance = setmetatable({}, self)
    instance.keyword = tostring(options.keyword or "我的")
    instance.on_result = options.on_result
    instance.on_progress = options.on_progress
    instance.on_done = options.on_done
    instance.completed = 0
    instance.total = 0
    instance.full_pass = 0
    instance.inconclusive = 0
    instance.runtime_or_rule = 0
    instance.request_error = 0
    instance.access_required = 0
    instance.timeout = 0
    instance.process_error = 0
    instance.skipped = 0
    instance.finished = false
    instance.cancelled = false
    instance.worker = nil
    instance.pending = nil
    instance.queue = nil
    instance.queue_index = 0
    instance.catalog_ticket = nil
    instance._fill_callback = nil
    instance._last_progress_at = 0
    instance.log_path = SourceDiagnosticLog:getPath()
    return instance
end

function AsyncSourceDiagnostic:state()
    return {
        active = not self.finished and not self.cancelled,
        completed = self.completed,
        total = self.total,
        full_pass = self.full_pass,
        inconclusive = self.inconclusive,
        runtime_or_rule = self.runtime_or_rule,
        request_error = self.request_error,
        access_required = self.access_required,
        timeout = self.timeout,
        process_error = self.process_error,
        skipped = self.skipped,
        log_path = self.log_path,
    }
end

function AsyncSourceDiagnostic:_notifyProgress(stage, force)
    local now = socket.gettime()
    if not force and now - (self._last_progress_at or 0) < 0.8 then return end
    self._last_progress_at = now
    if self.on_progress then pcall(self.on_progress, self.completed, self.total, stage, self, self:state()) end
end

function AsyncSourceDiagnostic:_count(result)
    local status = result and result.status or "PROCESS_ERROR"
    if status == "FULL_PASS" then self.full_pass = self.full_pass + 1
    elseif status == "INCONCLUSIVE" then self.inconclusive = self.inconclusive + 1
    elseif status == "RUNTIME_OR_RULE" then self.runtime_or_rule = self.runtime_or_rule + 1
    elseif status == "REQUEST_ERROR" then self.request_error = self.request_error + 1
    elseif status == "ACCESS_REQUIRED" then self.access_required = self.access_required + 1
    elseif status == "TIMEOUT" then self.timeout = self.timeout + 1
    elseif status == "SKIPPED_UNSUPPORTED" then self.skipped = self.skipped + 1
    else self.process_error = self.process_error + 1 end
end

function AsyncSourceDiagnostic:_finishResult(entry, result)
    self.completed = self.completed + 1
    self:_count(result)
    if self.on_result and not self.cancelled then
        pcall(self.on_result, result, self.completed, self.total, self, self:state())
    end
    self:_notifyProgress(string.format("正在检查书源 %d/%d · 完整可用 %d · 未找到测试书 %d · 失败 %d",
        self.completed, self.total, self.full_pass, self.inconclusive,
        self.runtime_or_rule + self.request_error + self.access_required + self.timeout + self.process_error), true)
end

function AsyncSourceDiagnostic:_appendFooter(cancelled)
    if self._footer_written then return end
    self._footer_written = true
    SourceDiagnosticLog:appendFooter(self:state(), cancelled == true)
end

function AsyncSourceDiagnostic:_finishIfIdle()
    if self.finished or self.cancelled then return true end
    if self.worker or self.pending or self._fill_callback then return false end
    if self.queue and self.queue_index < #self.queue then return false end
    self.finished = true
    self:_appendFooter(false)
    self:_notifyProgress("体检完成；日志已逐源写入 " .. tostring(self.log_path), true)
    if self.on_done then pcall(self.on_done, self, { log_path = self.log_path }, self:state()) end
    return true
end

function AsyncSourceDiagnostic:_prepareQueue()
    local summaries, err = Storage:listSourceSummaries()
    if not summaries then
        self.finished = true
        if self.on_done then pcall(self.on_done, self, { error = tostring(err or "无法读取书源索引") }, self:state()) end
        return
    end
    local records_path, records_err = Storage:getSourceCatalogRecordsPath()
    if not records_path then
        self.finished = true
        if self.on_done then pcall(self.on_done, self, { error = tostring(records_err or "书源记录文件不可用") }, self:state()) end
        return
    end
    local queue = {}
    for _, summary in ipairs(summaries) do
        queue[#queue + 1] = {
            id = summary.id,
            name = summary.name,
            capability_profile = summary.capability_profile,
            executable = summary.searchable ~= false and summary.has_search_url == true,
            records_path = records_path,
            record_offset = summary.record_offset,
            record_length = summary.record_length,
        }
    end
    self.queue, self.total = queue, #queue
    local path, log_err = SourceDiagnosticLog:begin(self.keyword, self.total)
    if not path then
        self.finished = true
        if self.on_done then pcall(self.on_done, self, { error = "无法创建体检日志：" .. tostring(log_err) }, self:state()) end
        return
    end
    self.log_path = path
    self:_notifyProgress("正在逐条尝试搜索、详情、目录和正文……", true)
    self:_scheduleNext(0)
end

function AsyncSourceDiagnostic:_scheduleNext(delay)
    if self.cancelled or self.finished or self.worker or self.pending or self._fill_callback then return end
    local callback
    callback = function()
        self._fill_callback = nil
        self:_startNext()
    end
    self._fill_callback = callback
    UIManager:scheduleIn(delay or BATCH_YIELD, callback)
end

function AsyncSourceDiagnostic:_nextEntry()
    self.queue_index = self.queue_index + 1
    return self.queue and self.queue[self.queue_index] or nil
end

function AsyncSourceDiagnostic:_startNext()
    if self.cancelled or self.finished or self.worker or self.pending then return end
    local entry = self:_nextEntry()
    if not entry then self:_finishIfIdle(); return end
    SourceDiagnosticLog:appendStart(self.queue_index, self.total, entry)
    if not entry.executable then
        local result = {
            status = "SKIPPED_UNSUPPORTED", stage = "source", code = "SOURCE_NOT_IN_TEXT_EXECUTION_QUEUE",
            elapsed_ms = 0, error = "这条书源包含当前版本暂不支持的功能，因此没有联网检查",
        }
        SourceDiagnosticLog:appendResult(self.queue_index, self.total, entry, result)
        self:_finishResult(entry, result)
        self:_scheduleNext(BATCH_YIELD)
        return
    end
    local holder = { entry = entry, index = self.queue_index }
    self.pending = holder
    local ticket
    ticket = ProcessBudget:request{
        owner = holder,
        label = "source-compat-diagnostic",
        priority = PROCESS_PRIORITY,
        on_start = function(granted) self:_spawn(holder, granted) end,
        on_error = function(request_err)
            if self.pending ~= holder then return end
            self.pending = nil
            local result = { status="PROCESS_ERROR", stage="process", code="BUDGET_ERROR", error=tostring(request_err), elapsed_ms=0 }
            SourceDiagnosticLog:appendResult(holder.index, self.total, entry, result)
            self:_finishResult(entry, result)
            self:_scheduleNext(BATCH_YIELD)
        end,
    }
    if ticket.state == "queued" then holder.ticket = ticket end
end

function AsyncSourceDiagnostic:_spawn(holder, budget_ticket)
    if self.pending ~= holder then ProcessBudget:release(budget_ticket); return end
    self.pending = nil
    if self.cancelled or self.finished then ProcessBudget:release(budget_ticket); return end
    local entry, index, keyword, total = holder.entry, holder.index, self.keyword, self.total
    local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
        local result
        local ok, child_err = xpcall(function()
            result = executeDiagnostic(entry, keyword)
        end, debug.traceback)
        if not ok then
            result = {
                status = "PROCESS_ERROR", stage = "process", code = "UNCAUGHT_CHILD_ERROR",
                error = tostring(child_err or "后台检查意外中断"), trace = tostring(child_err or ""), elapsed_ms = 0,
            }
        end
        -- Durability comes before UI handoff: the child itself commits the final
        -- source result, then sends only a compact summary to the KOReader parent.
        local log_path, log_err = SourceDiagnosticLog:appendResult(index, total, entry, result)
        if not log_path then result.log_error = tostring(log_err or "检查记录保存失败") end
        pcall(Storage.releaseSourceSettings, Storage)
        pcall(Storage.releaseSourceOverrideSettings, Storage)
        ffiutil.writeToFD(write_fd, encodePipe(result), true)
    end, true)
    if not pid then
        ProcessBudget:release(budget_ticket)
        local result = {
            status="PROCESS_ERROR", stage="process", code="SPAWN_FAILED",
            error="无法开始后台检查：" .. tostring(result_fd_or_err or "未知错误"), elapsed_ms=0,
        }
        SourceDiagnosticLog:appendResult(index, total, entry, result)
        self:_finishResult(entry, result)
        self:_scheduleNext(BATCH_YIELD)
        return
    end
    local worker = {
        pid = pid, result_fd = result_fd_or_err, entry = entry, index = index,
        started_at = socket.gettime(), finished = false, budget_ticket = budget_ticket,
    }
    self.worker = worker
    budget_ticket.on_preempt = function() self:_preempt(worker, "被更高优先级前台任务抢占") end
    UIManager:scheduleIn(POLL_INTERVAL, function() self:_poll(worker) end)
end

function AsyncSourceDiagnostic:_releaseWorker(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
end

function AsyncSourceDiagnostic:_complete(worker, result)
    if self.worker ~= worker then return end
    self.worker = nil
    worker.finished = true
    self:_releaseWorker(worker)
    if not self.cancelled then self:_finishResult(worker.entry, result) end
    collectgarbage("collect")
    if not self.cancelled then self:_scheduleNext(BATCH_YIELD) end
    self:_finishIfIdle()
end

function AsyncSourceDiagnostic:_reap(worker, result, write_parent_result)
    if not worker or worker.reaping then return end
    worker.reaping = true
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closeResultPipe(worker)
            if self.worker == worker then self.worker = nil end
            self:_releaseWorker(worker)
            if write_parent_result and result then
                SourceDiagnosticLog:appendResult(worker.index, self.total, worker.entry, result)
            end
            if result and not self.cancelled then self:_finishResult(worker.entry, result) end
            collectgarbage("collect")
            if self.cancelled then self:_appendFooter(true)
            else self:_scheduleNext(BATCH_YIELD) end
            self:_finishIfIdle()
        else
            UIManager:scheduleIn(REAP_INTERVAL, reap)
        end
    end
    UIManager:scheduleIn(REAP_INTERVAL, reap)
end

function AsyncSourceDiagnostic:_preempt(worker, reason)
    if self.worker ~= worker or worker.finished then return end
    worker.finished = true
    ffiutil.terminateSubProcess(worker.pid)
    local result = {
        status="PROCESS_ERROR", stage="process", code="PREEMPTED",
        error=tostring(reason or "后台检查被当前阅读任务打断"),
        elapsed_ms=math.floor(math.max(0, socket.gettime() - worker.started_at) * 1000 + 0.5),
    }
    self:_reap(worker, result, true)
end

function AsyncSourceDiagnostic:_poll(worker)
    if self.cancelled or self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        local raw = closeResultPipe(worker)
        local ok, result = pcall(rapidjson.decode, raw or "")
        if not ok or type(result) ~= "table" then
            result = {
                status="PROCESS_ERROR", stage="process", code="RESULT_DAMAGED",
                error="后台检查已退出，但结果损坏；请查看已保存的逐条记录",
                elapsed_ms=math.floor(math.max(0, socket.gettime() - worker.started_at) * 1000 + 0.5),
            }
            -- Do not duplicate a child result here: if the child had reached its
            -- durable append, the log already contains it. This parent-only row
            -- is useful only when IPC itself failed, so mark it explicitly.
            SourceDiagnosticLog:appendResult(worker.index, self.total, worker.entry, result)
        end
        self:_complete(worker, result)
    elseif socket.gettime() - worker.started_at >= SOURCE_DEADLINE then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        local result = {
            status="TIMEOUT", stage="process", code="HARD_TIMEOUT",
            error="这条书源检查超时（" .. tostring(SOURCE_DEADLINE) .. "秒）",
            elapsed_ms=math.floor(SOURCE_DEADLINE * 1000),
        }
        self:_reap(worker, result, true)
    else
        UIManager:scheduleIn(POLL_INTERVAL, function() self:_poll(worker) end)
    end
end

function AsyncSourceDiagnostic:start()
    if self.finished or self.cancelled or self.catalog_ticket or self.queue then return self end
    self:_notifyProgress("正在准备书源……", true)
    self.catalog_ticket = AsyncSourceCatalog:ensure(function(ok, err)
        self.catalog_ticket = nil
        if self.cancelled or self.finished then return end
        if not ok then
            self.finished = true
            if self.on_done then pcall(self.on_done, self, { error=tostring(err or "书源索引准备失败") }, self:state()) end
            return
        end
        self:_prepareQueue()
    end)
    return self
end

function AsyncSourceDiagnostic:cancel()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    if self.catalog_ticket then AsyncSourceCatalog:cancel(self.catalog_ticket); self.catalog_ticket = nil end
    if self._fill_callback then pcall(UIManager.unschedule, UIManager, self._fill_callback); self._fill_callback = nil end
    if self.pending then
        if self.pending.ticket then ProcessBudget:cancel(self.pending.ticket) end
        self.pending = nil
    end
    local worker = self.worker
    self.worker = nil
    if worker and not worker.finished then
        worker.finished = true
        ffiutil.terminateSubProcess(worker.pid)
        local result = {
            status="PROCESS_ERROR", stage="process", code="CANCELLED",
            error="用户停止书源检查",
            elapsed_ms=math.floor(math.max(0, socket.gettime() - worker.started_at) * 1000 + 0.5),
        }
        -- The START line is already durable. Add an explicit cancellation after
        -- the process is reaped, then write the session footer last.
        self:_reap(worker, result, true)
    else
        self:_appendFooter(true)
    end
    if self.on_done then pcall(self.on_done, self, { cancelled=true, log_path=self.log_path }, self:state()) end
end

AsyncSourceDiagnostic._executeDiagnosticForTests = executeDiagnostic
AsyncSourceDiagnostic._errorClassForTests = errorClass
AsyncSourceDiagnostic._encodePipeForTests = encodePipe

return AsyncSourceDiagnostic
