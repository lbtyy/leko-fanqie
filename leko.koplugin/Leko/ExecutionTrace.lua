-- Bounded, redacted evidence for the text-source compatibility diagnostic.
--
-- The normal reader path does not allocate this trace.  A diagnostic child
-- opts in with source._diagnostic_full_errors, so the trace can explain a
-- failed stage without leaking cookies, tokens, response bodies or arbitrary
-- source data into the UI/log stream.

local Http = require("Leko/Http")
local Digest = require("Leko/Digest")
local rapidjson = require("rapidjson")

local ExecutionTrace = {}

local MAX_RULES = 96
local MAX_HOST_CALLS = 128
local MAX_REQUESTS = 48
local MAX_PREVIEW = 160

local function valueType(value)
    if value == nil then return "undefined" end
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return kind end
    if kind == "table" then
        local marker = rawget(value, "kind")
        if marker == "java_byte_array" or marker == "JavaString" then
            return marker == "java_byte_array" and "array" or "string"
        end
        local count, numeric = 0, true
        for key in pairs(value) do
            count = count + 1
            if type(key) ~= "number" then numeric = false end
        end
        return numeric and "array" or "object"
    end
    return kind
end

local function rawHash(value)
    local ok, result = pcall(Digest.sha256, Digest, tostring(value or ""))
    return ok and result or ""
end

-- Kotlin's oracle canonicalizes Java byte[] by first viewing each byte as an
-- ISO-8859-1 code point, then hashing the resulting UTF-8 String.  Lua
-- strings are byte strings, so make that encoding boundary explicit instead
-- of accidentally hashing the wire bytes directly.
local function iso88591Utf8(value)
    value = tostring(value or "")
    local output = {}
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 0x80 then
            output[#output + 1] = string.char(byte)
        else
            output[#output + 1] = string.char(0xc0 + math.floor(byte / 0x40), 0x80 + (byte % 0x40))
        end
    end
    return table.concat(output)
end

local function javaByteHash(value)
    return rawHash(iso88591Utf8(value))
end

local function canonical(value, seen, depth)
    if value == nil then return "undefined" end
    local kind = type(value)
    if kind == "string" then return "string:" .. value end
    if kind == "number" or kind == "boolean" then return kind .. ":" .. tostring(value) end
    if kind ~= "table" then return kind end
    local marker = rawget(value, "kind")
    if marker == "java_byte_array" then
        return "array:java_byte_array:" .. javaByteHash(rawget(value, "bytes") or "")
    elseif marker == "JavaString" then
        return "string:" .. tostring(rawget(value, "value") or "")
    elseif marker == "ByteArrayInputStream" or marker == "ByteArrayOutputStream"
            or marker == "GZIPInputStream" or marker == "Base64Decoder" then
        return "object:java:" .. marker
    end
    if type(value.url) == "function" and type(value.body) == "function" and type(value.code) == "function" then
        local ok_url, url = pcall(value.url)
        local ok_code, code = pcall(value.code)
        local ok_body, body = pcall(value.body)
        return "response:url=" .. canonical(ok_url and url or "")
            .. ";code=" .. canonical(ok_code and code or 0)
            .. ";body_sha256=" .. rawHash(ok_body and body or "")
    end
    if value.url ~= nil and value.body ~= nil and value.code ~= nil then
        return "response:url=" .. canonical(value.url, seen, (depth or 0) + 1)
            .. ";code=" .. canonical(value.code, seen, (depth or 0) + 1)
            .. ";body_sha256=" .. rawHash(value.body)
    end
    depth = depth or 0
    if depth > 12 then return "table:depth" end
    seen = seen or {}
    if seen[value] then return "table:cycle" end
    if rawget(value, "__diagnostic_empty_array") == true then
        return "array:[]"
    end
    seen[value] = true
    local numeric = true
    local numeric_count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            numeric = false
            break
        end
        numeric_count = numeric_count + 1
    end
    if numeric and numeric_count > 0 then
        local parts = {}
        for index = 1, numeric_count do
            parts[#parts + 1] = canonical(value[index], seen, depth + 1)
        end
        seen[value] = nil
        return "array:[" .. table.concat(parts, ", ") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        local text = tostring(key)
        if not text:match("^__diagnostic") and not text:match("^__js_") then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key], seen, depth + 1)
    end
    seen[value] = nil
    return "object:{" .. table.concat(parts, ";") .. "}"
end

local function safeHash(value)
    local ok, result = pcall(Digest.sha256, Digest, canonical(value))
    return ok and result or ""
end

local function safeLength(value)
    if type(value) == "string" then return #value end
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return count
    end
    return value == nil and 0 or #tostring(value)
end

local function errorType(value)
    if value == nil then return nil end
    local text = tostring(value)
    return text:match("([A-Z][A-Z0-9_]+)") or type(value)
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizedScript(value)
    value = trim(value)
    value = value:gsub("^@[Jj][Ss]:%s*", "")
        :gsub("^<[Jj][Ss]>%s*", "")
        :gsub("%s*</[Jj][Ss]>$", "")
    return trim(value):gsub("%s+", " ")
end

local function preview(value)
    value = tostring(value or ""):gsub("[\r\n]+", " ")
    return #value > MAX_PREVIEW and value:sub(1, MAX_PREVIEW) .. "..." or value
end

local function redactUrl(value)
    value = tostring(value or "")
    if value == "" then return "" end
    -- Kotlin's OracleTrace.safeUrl reports a raw @js/<js> rule as an
    -- invalid URL.  Http:diagnosticUrl intentionally makes malformed input
    -- printable as an unknown host, which is useful for UI diagnostics but
    -- would erase this production observation boundary.
    if value:match("^%s*@%s*[Jj][Ss]%s*:") or value:match("^%s*<[Jj][Ss]>")
            or value:find("{", 1, true) or value:find("}", 1, true) then
        return "<invalid-url:" .. rawHash(value) .. ">"
    end
    local base, query = value:match("^(.-)%?(.*)$")
    if not query then return Http:diagnosticUrl(value) end
    local names = {}
    for pair in query:gmatch("[^&]+") do
        local name = pair:match("^([^=]+)") or pair
        if trim(name) ~= "" then names[#names + 1] = trim(name) .. "=<" .. safeHash(pair:match("^[^=]+=(.*)$") or "") .. ">" end
    end
    return Http:diagnosticUrl(base) .. (#names > 0 and ("?" .. table.concat(names, "&")) or "")
end

local function safeHeaders(headers)
    local output = {}
    local private = { cookie=true, authorization=true, ["proxy-authorization"]=true }
    for key, value in pairs(headers or {}) do
        local name = tostring(key)
        local lower = name:lower()
        if private[lower] or lower:find("token", 1, true) or lower:find("secret", 1, true) or lower:find("password", 1, true) then
            -- HTTP header evidence uses the raw wire value.  The fixture
            -- server and the Legado harness use the same raw-byte domain;
            -- typed canonical hashes are reserved for JS/Host values.
            output[lower] = { redacted = true, sha256 = rawHash(value) }
        else
            output[lower] = tostring(value or "")
        end
    end
    return output
end

local function cookieState(source)
    return type(source) == "table" and safeHash(source.cookies or {}) or ""
end

local function enabled(source)
    return type(source) == "table"
        and (source._diagnostic_full_errors == true or source._diagnostic_trace_enabled == true)
end

local function get(source)
    if not enabled(source) then return nil end
    local trace = rawget(source, "_diagnostic_trace")
    if type(trace) ~= "table" then
        trace = {
            schema_version = 1,
            js_evaluation_count = 0,
            js_evaluations = {},
            host_api_call_count = 0,
            host_api_calls = {},
            java_bridge_called = false,
            request_count = 0,
            requests = {},
            url_contexts = {},
            branch_events = {},
            side_effects = {},
            leko_extensions = {},
            last_request = nil,
            interaction_required = false,
        }
        rawset(source, "_diagnostic_trace", trace)
    end
    return trace
end

function ExecutionTrace:begin(source)
    if not enabled(source) then return nil end
    rawset(source, "_diagnostic_trace", nil)
    return get(source)
end

function ExecutionTrace:get(source)
    return get(source)
end

function ExecutionTrace:setStage(source, stage)
    local trace = get(source)
    if trace then trace.stage = tostring(stage or "unknown") end
    return trace
end

function ExecutionTrace:setRule(source, env, field, rule, base_url)
    local trace = get(source)
    if not trace then return end
    field = tostring(field or "rule")
    local rule_text = trim(rule)
    if env then
        rawset(env, "__diagnostic_stage", trace.stage or "unknown")
        rawset(env, "__diagnostic_rule_field", field)
        rawset(env, "__diagnostic_rule_preview", preview(rule_text))
        rawset(env, "__diagnostic_js_base_url", redactUrl(base_url or ""))
        rawset(env, "__diagnostic_trace", trace)
    end
    if #trace.js_evaluations < MAX_RULES then
        -- Registering the field before evaluation makes a rule with no JS
        -- branch visible in the stage trace as well.
        trace.last_rule = { field = field, preview = preview(rule_text) }
    end
end

function ExecutionTrace:markJs(env, script, kind)
    local trace = env and rawget(env, "__diagnostic_trace")
    if type(trace) ~= "table" then return end
    trace.js_evaluation_count = (tonumber(trace.js_evaluation_count) or 0) + 1
    if #trace.js_evaluations < MAX_RULES then
        local observed_base = rawget(env, "__diagnostic_js_base_url") or ""
        if tostring(kind or rawget(env, "__diagnostic_js_kind") or "rule") == "library"
                and trace.stage == "content" then
            local source = rawget(env, "source")
            source = type(source) == "table" and (rawget(source, "__target") or source) or nil
            if type(source) == "table" and source._js_library_base_url_override then
                observed_base = redactUrl(source._js_library_base_url_override)
            end
        end
            trace.js_evaluations[#trace.js_evaluations + 1] = {
                ordinal = trace.js_evaluation_count,
                kind = tostring(kind or rawget(env, "__diagnostic_js_kind") or "rule"),
                stage = tostring(rawget(env, "__diagnostic_stage") or trace.stage or "unknown"),
                rule_field = tostring(rawget(env, "__diagnostic_rule_field") or "script"),
                rule = preview(rawget(env, "__diagnostic_rule_preview") or script),
                base_url = observed_base,
                base_url_type = tostring(rawget(env, "__diagnostic_js_base_url_type") or "unknown"),
                env_base_url_present = rawget(env, "__diagnostic_env_base_url_present") == true,
                base_url_http = rawget(env, "__diagnostic_js_base_url_http") == true,
                script_sha256 = Digest:sha256(normalizedScript(script)),
                script_length = #normalizedScript(script),
                input_type = valueType(rawget(env, "result")),
                input_sha256 = safeHash(rawget(env, "result")),
            }
    end
end

function ExecutionTrace:markJsResult(env, value, err)
    local trace = env and rawget(env, "__diagnostic_trace")
    if type(trace) ~= "table" or #trace.js_evaluations == 0 then return end
    local item = trace.js_evaluations[#trace.js_evaluations]
    if err ~= nil then
        item.error_type = errorType(err)
        item.error_sha256 = safeHash(err)
    elseif value == nil then
        item.error_type = ""
        item.return_type = "undefined"
        item.return_sha256 = safeHash(nil)
        item.return_length = 0
    else
        item.error_type = ""
        item.return_type = valueType(value)
        item.return_sha256 = safeHash(value)
        item.return_length = safeLength(value)
    end
end

function ExecutionTrace:markHost(env, method, ok, err, params, value)
    local trace = env and rawget(env, "__diagnostic_trace")
    if type(trace) ~= "table" then return end
    method = tostring(method or "")
    if method:find("startBrowser", 1, true) or method:find("webView", 1, true)
            or method:find("Verification", 1, true) then
        trace.interaction_required = true
    end
    trace.host_api_call_count = (tonumber(trace.host_api_call_count) or 0) + 1
    if method:sub(1, 5) == "java." then trace.java_bridge_called = true end
    local seen = trace._host_seen or {}
    trace._host_seen = seen
    seen[method] = (tonumber(seen[method]) or 0) + 1
    if #trace.host_api_calls < MAX_HOST_CALLS then
        local params_hash_value = params
        if type(params) == "table" and next(params) == nil then
            params_hash_value = { __diagnostic_empty_array = true }
        end
        local entry = {
            ordinal = trace.host_api_call_count,
            method = method,
            ok = ok == true,
            stage = tostring(trace.stage or "unknown"),
            owner = tostring(trace.stage or "unknown"),
            base_url = rawget(env, "__diagnostic_js_base_url") or "",
            params_type = valueType(params),
            params_sha256 = safeHash(params_hash_value),
            return_type = valueType(value),
            return_sha256 = safeHash(value),
        }
        if ok ~= true then
            entry.error_type = errorType(err)
            entry.error_sha256 = safeHash(err)
        else
            entry.error_type = ""
        end
        trace.host_api_calls[#trace.host_api_calls + 1] = entry
    end
end

-- AnalyzeUrl is constructed before its @js body is evaluated.  Keep that
-- observation separate from the later wire request: an outer URL rule can
-- invoke java.ajax, so the nested HTTP request is intentionally recorded
-- after the outer URL context.
function ExecutionTrace:urlContext(source, m_url, base_url)
    local trace = get(source)
    if not trace then return end
    if #trace.url_contexts < MAX_REQUESTS * 2 then
        trace.url_contexts[#trace.url_contexts + 1] = {
            ordinal = #trace.url_contexts + 1,
            stage = tostring(trace.stage or "unknown"),
            owner = "analyze-url",
            m_url = redactUrl(m_url),
            base_url = redactUrl(base_url),
        }
    end
end

function ExecutionTrace:extension(source, name, enabled_value)
    local trace = get(source)
    if not trace then return end
    trace.leko_extensions[tostring(name)] = enabled_value ~= false
end

-- Record only bounded, non-secret branch evidence.  A branch is considered
-- covered by the comparator only when this event was emitted by the observed
-- production path; source metadata or a default false value is not enough.
function ExecutionTrace:branch(source, name, stage, rule_field, values)
    local trace = get(source)
    if not trace or #trace.branch_events >= 128 then return end
    local item = {
        name = tostring(name or ""),
        stage = tostring(stage or trace.stage or "unknown"),
        rule_field = tostring(rule_field or ""),
    }
    for key, value in pairs(values or {}) do
        if key == "input" or key == "output" or key == "value" then
            item[key .. "_type"] = valueType(value)
            item[key .. "_sha256"] = safeHash(value)
        elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            item[key] = value
        end
    end
    trace.branch_events[#trace.branch_events + 1] = item
end

function ExecutionTrace:state(source, scope, value)
    local trace = get(source)
    if not trace then return end
    scope = tostring(scope or "state")
    trace.final_state = trace.final_state or {}
    local item = trace.final_state[scope] or { present = type(value) == "table", keys = {} }
    if type(value) == "table" then
        item.present = true
        local seen = {}
        for _, key in ipairs(item.keys or {}) do seen[tostring(key)] = true end
        for key in pairs(value) do
            if tostring(key):sub(1, 2) ~= "__" and not seen[tostring(key)] then
                item.keys[#item.keys + 1] = tostring(key)
                seen[tostring(key)] = true
            end
        end
        table.sort(item.keys)
    end
    trace.final_state[scope] = item
end

function ExecutionTrace:contentMedia(source, contract)
    local trace = get(source)
    if not trace or type(contract) ~= "table" then return end
    if (tonumber(contract.count) or 0) > 0 then
        self:branch(source, "content-image-contract", trace.stage or "content", "ruleContent.content", {
            value = contract.count,
        })
    end
    local current = trace.content_media or {
        rendering = "unsupported-placeholder",
        placeholder = "[image]",
        base_url = contract.base_url or "",
        pages = 0,
        count = 0,
        items = {},
    }
    current.pages = (tonumber(current.pages) or 0) + 1
    current.count = (tonumber(current.count) or 0) + (tonumber(contract.count) or 0)
    if current.base_url == "" then current.base_url = contract.base_url or "" end
    for _, item in ipairs(contract.items or {}) do
        if #current.items < 64 then current.items[#current.items + 1] = item end
    end
    trace.content_media = current
end

function ExecutionTrace:sideEffect(source, scope, operation, key)
    local trace = get(source)
    if not trace then return end
    local name = tostring(scope or "state") .. "." .. tostring(operation or "change")
    trace.side_effects[name] = (tonumber(trace.side_effects[name]) or 0) + 1
    if key ~= nil then
        trace.last_side_effect = { scope = tostring(scope or "state"), operation = tostring(operation or "change"), key = preview(key) }
    end
end

function ExecutionTrace:requestStart(source, request)
    local trace = get(source)
    if not trace then return nil end
    trace.request_count = (tonumber(trace.request_count) or 0) + 1
    local item = {
        ordinal = trace.request_count,
        stage = tostring(trace.stage or "unknown"),
        method = tostring(request and request.method or "GET"):upper(),
        url = redactUrl(request and request.url),
        url_sha256 = safeHash(request and request.url),
        base_url = redactUrl(request and request.base_url),
        query = redactUrl(request and request.url):match("%?(.*)$") or "",
        body_bytes = #(tostring(request and request.body or "")),
        body_sha256 = rawHash(request and request.body or ""),
        charset = request and request.charset or nil,
        headers = safeHeaders(request and request.headers or {}),
        header_names = {},
        cookie_before = cookieState(source),
    }
    for key in pairs(request and request.headers or {}) do item.header_names[#item.header_names + 1] = tostring(key):lower() end
    table.sort(item.header_names)
    trace.last_request = item
    if #trace.requests < MAX_REQUESTS then trace.requests[#trace.requests + 1] = item end
    return item
end

function ExecutionTrace:requestEnd(source, item, response, err)
    local trace = get(source)
    if not trace or type(item) ~= "table" then return end
    item.ok = response ~= nil
    if not response then item.error = preview(err) end
    if item.error and item.error:find("INTERACTION_REQUIRED", 1, true) then
        trace.interaction_required = true
    end
    if response then
        item.status = tostring(response.status or "")
        item.code = tonumber(response.code) or response.code
        item.response_url = redactUrl(response.url or response.request_url)
        item.response_base_url = redactUrl(response.request_base_url)
        item.content_type = tostring(response.content_type or "")
        item.response_bytes = #(tostring(response.body or ""))
        item.response_body_sha256 = rawHash(response.body or "")
        item.charset_used = response.charset
        item.response_headers = safeHeaders(response.headers or {})
        item.cookie_after = cookieState(source)
    end
    trace.last_request = item
end

function ExecutionTrace:finish(source)
    local trace = get(source)
    if not trace then return nil end
    trace._host_seen = nil
    trace.last_rule = nil
    trace.last_side_effect = nil
    trace.finished = true
    trace.leko_extension = {
        text_runtime = true,
        webview = "interaction-required",
        android_java = "explicitly-limited",
        filesystem = false,
        system_commands = false,
    }
    return trace
end

return ExecutionTrace
