-- QuickJS-backed Legado JavaScript runtime.
--
-- The Lua side deliberately knows only the opaque bridge ABI declared in
-- lqjs_bridge.h.  QuickJS values never cross this boundary: host calls are
-- length-delimited JSON and DOM/response objects are opaque handles owned by
-- one Session.  The desktop qjs executable is a development fallback for
-- pure JavaScript tests; KOReader requires the packaged native bridge.

local rapidjson = require("rapidjson")
local ChineseConvert = require("Leko/ChineseConvert")
local ExecutionTrace = require("Leko/ExecutionTrace")
local JavaHostCompat = require("Leko/JavaHostCompat")
local unpack = table.unpack or unpack
local function pack(...)
    return { n = select("#", ...), ... }
end

local QuickJS = {}
local Session = {}
Session.__index = Session

local ENGINE_VERSION = "2026-06-04"
local BRIDGE_ABI = 2
local BRIDGE_VERSION = "2.0.0"
local MAX_MEMORY = 6 * 1024 * 1024
local MAX_STACK = 384 * 1024
local DEFAULT_TIMEOUT = 350
local DEFAULT_RESULT = 512 * 1024
local HANDLE_LIMIT = 4096
-- LuaJIT callback trampolines are process resources.  Keep a bounded registry
-- so a caller that creates source/session objects repeatedly cannot exhaust
-- the callback allocator before Lua happens to collect an unreachable cdata
-- closure.  Source-owned sessions remain shared until they are explicitly
-- closed or selected as the least-recently-used idle session.
local MAX_ACTIVE_SESSIONS = 64
local active_sessions = {}
local native_disabled = false

local ffi_ok, ffi = pcall(require, "ffi")
local ffi_abi_ok = false
local ffi_lib
local ffi_error
local native_callback
local current_native_session

if ffi_ok then
    local cdef_ok = pcall(function()
        ffi.cdef[[
            typedef unsigned char uint8_t;
            typedef unsigned int uint32_t;
            typedef unsigned long long uint64_t;
            typedef long long int64_t;
            typedef struct lqjs_runtime lqjs_runtime;
            typedef struct lqjs_context lqjs_context;
            typedef struct {
                uint32_t abi_version;
                uint32_t flags;
                size_t memory_limit_bytes;
                size_t max_stack_bytes;
            } lqjs_runtime_options;
            typedef struct {
                uint32_t abi_version;
                uint32_t flags;
                uint64_t timeout_ms;
                size_t max_result_bytes;
            } lqjs_eval_options;
            typedef struct {
                uint32_t abi_version;
                uint32_t status;
                int64_t engine_code;
                const char *message;
                size_t message_len;
                const char *stack;
                size_t stack_len;
            } lqjs_error;
            typedef int (*lqjs_host_call_fn)(void *opaque,
                const uint8_t *request, size_t request_len,
                const uint8_t **response, size_t *response_len);
            uint32_t lqjs_abi_version(void);
            const char *lqjs_engine_version(void);
            const char *lqjs_bridge_version(void);
            lqjs_runtime *lqjs_runtime_new(const lqjs_runtime_options *options,
                lqjs_error *error_out);
            void lqjs_runtime_free(lqjs_runtime *runtime);
            lqjs_context *lqjs_context_new(lqjs_runtime *runtime,
                lqjs_error *error_out);
            void lqjs_context_free(lqjs_context *context);
            void lqjs_runtime_memory_usage(lqjs_runtime *runtime,
                size_t *current, size_t *peak);
            int lqjs_context_install_host_policy_json(lqjs_context *context,
                const uint8_t *policy_json, size_t policy_len,
                lqjs_error *error_out);
            int lqjs_context_install_host_callback(lqjs_context *context,
                lqjs_host_call_fn callback, void *opaque,
                lqjs_error *error_out);
            int lqjs_eval_json(lqjs_context *context,
                const uint8_t *script, size_t script_len,
                const uint8_t *input_json, size_t input_len,
                const lqjs_eval_options *options,
                uint8_t **result_json, size_t *result_len,
                lqjs_error *error_out);
            void lqjs_buffer_free(void *buffer);
        ]]
    end)
    ffi_abi_ok = cdef_ok
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- JsExtensions.toNumChapter uses the reference title-number pattern and
-- converts Chinese numerals only inside a 第...章/节 title.  Keep the
-- conversion in the host bridge so JavaScript sees the same host operation;
-- it is deliberately not a general-purpose text heuristic.
local function toNumChapter(value)
    value = tostring(value or "")
    local tokens = {}
    local byte_index = 1
    while byte_index <= #value do
        local first = value:byte(byte_index)
        local width = first < 0x80 and 1 or (first < 0xe0 and 2 or (first < 0xf0 and 3 or 4))
        tokens[#tokens + 1] = value:sub(byte_index, byte_index + width - 1)
        byte_index = byte_index + width
    end
    local chapter = string.char(0xe7, 0xac, 0xac)
    local end_chapter = string.char(0xe7, 0xab, 0xa0)
    local end_section = string.char(0xe8, 0x8a, 0x82)
    local digits = {
        [string.char(0xe9, 0x9b, 0xb6)] = 0, [string.char(0xe3, 0x80, 0x87)] = 0,
        [string.char(0xe4, 0xb8, 0x80)] = 1, [string.char(0xe4, 0xba, 0x8c)] = 2,
        [string.char(0xe4, 0xb8, 0xa4)] = 2, [string.char(0xe4, 0xb8, 0x89)] = 3,
        [string.char(0xe5, 0x9b, 0x9b)] = 4, [string.char(0xe4, 0xba, 0x94)] = 5,
        [string.char(0xe5, 0x85, 0xad)] = 6, [string.char(0xe4, 0xb8, 0x83)] = 7,
        [string.char(0xe5, 0x85, 0xab)] = 8, [string.char(0xe4, 0xb9, 0x9d)] = 9,
    }
    local units = {
        [string.char(0xe5, 0x8d, 0x81)] = 10, [string.char(0xe7, 0x99, 0xbe)] = 100,
        [string.char(0xe5, 0x8d, 0x83)] = 1000, [string.char(0xe4, 0xb8, 0x87)] = 10000,
    }
    local function chineseNumber(first, last)
        local total, section, number, seen = 0, 0, 0, false
        for index = first, last do
            local digit, unit = digits[tokens[index]], units[tokens[index]]
            if digit ~= nil then number, seen = digit, true
            elseif unit then
                seen = true
                if unit == 10000 then
                    total = total + (section + number) * unit
                    section, number = 0, 0
                else
                    if number == 0 then number = 1 end
                    section, number = section + number * unit, 0
                end
            end
        end
        return seen and (total + section + number) or nil
    end
    local output, index = {}, 1
    while index <= #tokens do
        if tokens[index] == chapter then
            local last = index + 1
            while last <= #tokens and (digits[tokens[last]] ~= nil or units[tokens[last]] ~= nil) do
                last = last + 1
            end
            if last > index + 1 and (tokens[last] == end_chapter or tokens[last] == end_section) then
                local number = chineseNumber(index + 1, last - 1)
                output[#output + 1] = chapter .. tostring(number) .. tokens[last]
                index = last + 1
            else
                output[#output + 1] = tokens[index]
                index = index + 1
            end
        else
            output[#output + 1] = tokens[index]
            index = index + 1
        end
    end
    return table.concat(output)
end

local function pathDir(path)
    return tostring(path or ""):match("^(.*)[/\\][^/\\]+$") or "."
end

local function modulePath()
    local source = debug.getinfo(1, "S").source or ""
    return source:sub(1, 1) == "@" and source:sub(2) or source
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end

local function loadNative()
    if not ffi_ok or not ffi_abi_ok then
        ffi_error = "LuaJIT FFI is unavailable"
        return nil
    end
    if native_disabled then
        ffi_error = ffi_error or "QuickJS native bridge is quarantined after a native-process crash"
        return nil
    end
    if ffi_lib then return ffi_lib end
    local plugin_dir = pathDir(pathDir(modulePath()))
    local candidates = {}
    local configured = os.getenv and os.getenv("LEKO_QUICKJS_LIBRARY") or nil
    if configured and configured ~= "" then candidates[#candidates + 1] = configured end
    candidates[#candidates + 1] = plugin_dir .. "/native/liblekoqjs.so"
    candidates[#candidates + 1] = plugin_dir .. "/native/liblekoqjs.dll"
    candidates[#candidates + 1] = plugin_dir .. "/Leko/native/liblekoqjs.so"
    candidates[#candidates + 1] = plugin_dir .. "/Leko/native/liblekoqjs.dll"
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            local ok, loaded = pcall(ffi.load, path)
            if ok and loaded then
                local abi_ok, valid = pcall(function()
                    return tonumber(loaded.lqjs_abi_version()) == BRIDGE_ABI
                end)
                if abi_ok and valid then
                    ffi_lib = loaded
                    return ffi_lib
                end
                if not abi_ok then
                    ffi_error = "QuickJS bridge ABI probe failed: " .. tostring(valid)
                else
                    ffi_error = "QuickJS bridge ABI mismatch: " .. tostring(path)
                end
            else
                ffi_error = tostring(loaded or ("cannot load " .. path))
            end
        end
    end
    ffi_error = ffi_error or "packaged QuickJS native library not found"
    return nil
end

local function shellQuote(value)
    value = tostring(value or "")
    if package.config and package.config:sub(1, 1) == "\\" then
        return '"' .. value:gsub('"', '\\"') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function qjsExecutable()
    local configured = os.getenv and os.getenv("LEKO_QUICKJS_QJS") or nil
    if configured and fileExists(configured) then return configured end
    return nil
end

local function nativeRequired()
    return os.getenv and os.getenv("LEKO_QUICKJS_REQUIRE_NATIVE") == "1"
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function writeFile(path, value)
    local file = io.open(path, "wb")
    if not file then return nil, "cannot open temporary file" end
    file:write(value or "")
    file:close()
    return true
end

local temp_counter = 0
local function tempPath(suffix)
    temp_counter = temp_counter + 1
    local directory = (os.getenv and (os.getenv("TEMP") or os.getenv("TMP"))) or "."
    local stamp = tostring(os.time()) .. "-" .. tostring(temp_counter) .. "-" .. tostring(math.random(100000, 999999))
    return directory .. "/leko-quickjs-" .. stamp .. tostring(suffix or ".tmp")
end

local function jsonEncode(value)
    local ok, encoded = pcall(rapidjson.encode, value)
    return ok and encoded or nil, ok and nil or tostring(encoded)
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function isHandle(value)
    return type(value) == "table" and rawget(value, "__leko_handle_kind") ~= nil
end

local function isByteArray(value)
    return type(value) == "table" and rawget(value, "__leko_byte_array") ~= nil
end

local function isResponseProxy(value)
    return type(value) == "table" and type(rawget(value, "body")) == "function"
        and type(rawget(value, "url")) == "function"
end

local function isDomValue(value)
    if type(value) ~= "table" then return false end
    if rawget(value, "__values") ~= nil then return true end
    return type(rawget(value, "select")) == "function"
        or type(rawget(value, "getcontent")) == "function"
        or type(rawget(value, "gettext")) == "function"
end

function Session:_register(value, kind)
    if isHandle(value) then return rawget(value, "__leko_handle_id") end
    local id = self.next_handle
    if id > HANDLE_LIMIT then
        error("host-denied: QuickJS handle limit exceeded")
    end
    self.next_handle = id + 1
    self.handles[id] = { value = value, kind = kind }
    return id
end

function Session:_makeHandle(value, kind)
    return {
        __leko_handle_kind = tostring(kind or "host"),
        __leko_handle_id = self:_register(value, kind),
    }
end

function Session:_encode(value, seen, depth)
    depth = depth or 0
    if depth > 48 then return { __leko_kind = "undefined" } end
    if value == nil then return { __leko_kind = "undefined" } end
    local value_type = type(value)
    if value_type == "boolean" or value_type == "string" then return value end
    if value_type == "number" then
        return isFiniteNumber(value) and value or { __leko_kind = "undefined" }
    end
    if value_type == "cdata" and ffi_ok then
        local ok, text = pcall(ffi.string, value)
        if ok and text then return text end
        return { __leko_kind = "undefined" }
    end
    if value_type == "function" or value_type == "thread" or value_type == "userdata" then
        return { __leko_kind = "undefined" }
    end
    if value_type ~= "table" then return { __leko_kind = "undefined" } end
    if rawget(value, "__leko_kind") == "java_ref" then
        return {
            __leko_kind = "java_ref",
            ref_kind = rawget(value, "ref_kind"),
            name = rawget(value, "name"),
        }
    end
    if isHandle(value) then
        return {
            __leko_kind = rawget(value, "__leko_handle_kind"),
            id = rawget(value, "__leko_handle_id"),
        }
    end
    if isByteArray(value) then
        local bytes = {}
        for index, item in ipairs(rawget(value, "__leko_byte_array") or {}) do
            bytes[index] = tonumber(item) and (tonumber(item) % 256) or 0
        end
        return { __leko_kind = "byte_array", value = bytes }
    end
    if isResponseProxy(value) then
        return { __leko_kind = "response", id = self:_register(value, "response") }
    end
    if isDomValue(value) then
        local kind = rawget(value, "__values") ~= nil and "dom_list" or "dom"
        return { __leko_kind = kind, id = self:_register(value, kind) }
    end
    seen = seen or {}
    if seen[value] then return { __leko_kind = "undefined" } end
    seen[value] = true
    local target = rawget(value, "__target")
    if type(target) == "table" then value = target end
    local array = #value > 0
    local result = {}
    if array then
        for index = 1, #value do
            result[index] = self:_encode(value[index], seen, depth + 1)
        end
    else
        for key, item in pairs(value) do
            if (type(key) == "string" or type(key) == "number")
                    and tostring(key):sub(1, 2) ~= "__"
                    and type(item) ~= "function" then
                result[tostring(key)] = self:_encode(item, seen, depth + 1)
            end
        end
    end
    seen[value] = nil
    return result
end

function Session:_decode(value, depth)
    depth = depth or 0
    if depth > 48 or value == nil then return value end
    if type(value) ~= "table" then return value end
    local kind = rawget(value, "__leko_kind")
    if kind == "undefined" or kind == "null" or kind == "function" then return nil end
    if kind == "bigint" then return tostring(value.value or "0") end
    if kind == "java_ref" then
        return { kind = tostring(value.ref_kind or ""), name = tostring(value.name or "") }
    end
    if kind == "dom" or kind == "dom_list" or kind == "response" then
        local item = self.handles[tonumber(value.id)]
        return item and item.value or nil
    end
    if kind == "java_object" or kind == "java_byte_array" then
        local item = self.handles[tonumber(value.id)]
        return item and item.value or nil
    end
    if kind == "byte_array" then
        local bytes = {}
        for index, item in ipairs(value.value or {}) do bytes[index] = tonumber(item) or 0 end
        return bytes
    end
    local result = {}
    for key, item in pairs(value) do result[key] = self:_decode(item, depth + 1) end
    return result
end

function Session:_proxyTarget(proxy)
    if type(proxy) ~= "table" then return proxy end
    return rawget(proxy, "__target") or proxy
end

local function methodFromTable(container, name)
    if type(container) ~= "table" then return nil end
    local value = rawget(container, name)
    return type(value) == "function" and value or nil
end

local function sourceMethodAlias(env, name)
    local aliases = {
        getString = "getString", getStringList = "getStringList",
        getElement = "getElement", getElements = "getElements",
        setContent = "setContent", ajax = "ajax", ajaxAll = "ajaxAll",
        getCookie = "getCookie", base64Encode = "base64Encode",
        base64Decode = "base64Decode", md5Encode = "md5Encode",
    }
    local key = aliases[name]
    return key and type(env[key]) == "function" and env[key] or nil
end

local function callFunction(fn, receiver, args)
    local ok, value = pcall(fn, receiver, unpack(args or {}))
    if ok then return true, value end
    return false, value
end

local function makeHostError(message)
    error("HOST_API_UNSUPPORTED: host-unsupported: " .. tostring(message or "unsupported host operation"))
end

function Session:_wrapJavaValue(value)
    if type(value) ~= "table" or rawget(value, "kind") == nil then return value end
    local kind = rawget(value, "kind")
    if kind == "java_byte_array" then return self:_makeHandle(value, "java_byte_array") end
    return self:_makeHandle(value, "java_object")
end

function Session:_javaObjectMethod(id, name, args)
    local entry = self.handles[tonumber(id)]
    if not entry or (entry.kind ~= "java_object" and entry.kind ~= "java_byte_array") then
        makeHostError("released Java object handle")
    end
    if entry.kind == "java_byte_array" then
        if name == "property" then return JavaHostCompat:handleProperty(entry.value, args[1]) end
        return JavaHostCompat:method(entry.value, name, args)
    end
    return self:_wrapJavaValue(JavaHostCompat:method(entry.value, name, args))
end

function Session:_javaMethod(name, args)
    local env = self.env or {}
    local java = env.java or {}
    if name == "resolve" then
        local resolved = JavaHostCompat:resolve(args[1])
        return {
            __leko_kind = "java_ref",
            ref_kind = resolved.kind,
            name = resolved.name,
        }
    elseif name == "importPackage" then
        return JavaHostCompat:importPackage(args[1])
    elseif name == "construct" then
        return self:_wrapJavaValue(JavaHostCompat:construct(args[1], { unpack(args, 2) }))
    elseif name == "static" then
        return self:_wrapJavaValue(JavaHostCompat:static(args[1], args[2], { unpack(args, 3) }))
    end
    local fn = methodFromTable(java, name)
    if name == "toNumChapter" and not fn then return toNumChapter(args[1]) end
    if not fn then
        if name == "getString" then
            fn = sourceMethodAlias(env, name)
            if fn then return fn(unpack(args or {})) end
        elseif name == "getStringList" then
            fn = sourceMethodAlias(env, name)
            if fn then return fn(unpack(args or {})) end
        elseif name == "getElement" then
            local values = type(env.getElements) == "function" and env.getElements(unpack(args or {})) or {}
            -- Legado's AnalyzeRule.getElement returns a Jsoup Elements-like
            -- collection, including an empty collection. Keeping that shape
            -- matters for rules that probe `.length` before launching a
            -- browser verification flow.
            if type(values) == "table" and rawget(values, "__values") ~= nil then return values end
            return { __values = type(values) == "table" and values or {} }
        elseif name == "getElements" then
            fn = type(env.getElements) == "function" and env.getElements or nil
            if fn then
                local values = fn(unpack(args or {}))
                if type(values) == "table" and rawget(values, "__values") == nil then return { __values = values } end
                return values
            end
        elseif name == "setContent" then
            fn = type(env.setContent) == "function" and env.setContent or nil
            if fn then return fn(unpack(args or {})) end
        end
    end
    if not fn then
        local ok, Digest = pcall(require, "Leko/Digest")
        local crypto_ok, Crypto = pcall(require, "Leko/CryptoCompat")
        local koreader_ok, koreader_util = pcall(require, "util")
        if name == "t2s" then return ChineseConvert.t2s(args[1]) end
        if name == "s2t" then return ChineseConvert.s2t(args[1]) end
        if name == "md5Encode" and ok then return Digest:md5(args[1]) end
        if name == "md5Encode16" and ok then return Digest:md5(args[1]):sub(9, 24) end
        if name == "base64Encode" and crypto_ok then return Crypto.base64Encode(args[1]) end
        if name == "base64Decode" and crypto_ok then return Crypto.base64Decode(args[1]) end
        if name == "base64DecodeToByteArray" and crypto_ok then
            local decoded = Crypto.base64Decode(args[1])
            local bytes = { decoded:byte(1, #decoded) }
            return { __leko_byte_array = bytes }
        end
        if name == "createSymmetricCrypto" and crypto_ok then
            local ok_crypto, crypto = pcall(function()
                return Crypto:createSymmetricCrypto(args[1], args[2], args[3])
            end)
            if not ok_crypto or type(crypto) ~= "table" then
                makeHostError("java.createSymmetricCrypto: " .. tostring(crypto or "creation failed"))
            end
            return self:_makeHandle(crypto, "crypto")
        end
        if name == "hexEncodeToString" and crypto_ok then return Crypto.hex(args[1]) end
        if name == "hexDecodeToString" and crypto_ok then return Crypto.unhex(args[1]) end
        if name == "bytesToStr" then
            local bytes, output = args[1], {}
            if type(bytes) ~= "table" then return tostring(bytes or "") end
            for index, byte in ipairs(bytes) do output[index] = string.char((tonumber(byte) or 0) % 256) end
            return table.concat(output)
        end
        if name == "digestHex" and crypto_ok then return Crypto:digestHex(args[1], args[2]) end
        if name == "HMacHex" and crypto_ok then return Crypto:hmacHex(args[1], args[2], args[3]) end
        if name == "HMacBase64" and crypto_ok then return Crypto:hmacBase64(args[1], args[2], args[3]) end
        if name == "randomUUID" and crypto_ok then return Crypto:randomUUID() end
        if name == "aesBase64DecodeToString" and crypto_ok then
            return Crypto:aesBase64DecodeToString(args[1], args[2], args[3], args[4])
        end
        if name == "desEncodeToBase64String" and crypto_ok then
            return Crypto:desEncodeToBase64String(args[1], args[2], args[3], args[4])
        end
        if (name == "urlEncode" or name == "encodeURI") and koreader_ok then return koreader_util.urlEncode(tostring(args[1] or "")) end
        if name == "urlDecode" and koreader_ok then return koreader_util.urlDecode(tostring(args[1] or "")) end
        if name == "getCookie" and env.cookie and type(env.cookie.getCookie) == "function" then
            return env.cookie:getCookie(args[1] or env.baseUrl)
        end
        if name == "getStrResponse" then return env.currentResponse end
        if name == "getWebViewUA" or name == "getUserAgent" then
            return "Mozilla/5.0 (Linux; Kindle) AppleWebKit/537.36 Mobile Safari/537.36"
        end
        if name == "androidId" and ok then return Digest:md5(tostring(env.baseUrl or "Leko")):sub(1, 16) end
        if name == "timeFormat" or name == "timeFormatUTC" then
            local timestamp = tonumber(args[1]) or 0
            if timestamp > 100000000000 then timestamp = timestamp / 1000 end
            local format = tostring(args[2] or "%Y-%m-%d %H:%M")
            format = format:gsub("yyyy", "%%Y"):gsub("MM", "%%m"):gsub("dd", "%%d")
                :gsub("HH", "%%H"):gsub("mm", "%%M"):gsub("ss", "%%S")
            return os.date(format, math.floor(timestamp))
        end
        if name == "htmlFormat" then
            local Util = require("Leko/Util")
            return Util.stripHtml(tostring(args[1] or ""))
        end
        if name == "log" then
            pcall(print, "[Legado] " .. tostring(args[1] or ""))
            return nil
        end
        if name == "put" then
            env.variables = env.variables or {}
            env.variables[tostring(args[1] or "")] = args[2]
            return args[2]
        end
        if name == "get" then
            env.variables = env.variables or {}
            return env.variables[tostring(args[1] or "")] or ""
        end
        if name == "removeCookie" and env.cookie and type(env.cookie.removeCookie) == "function" then
            return env.cookie:removeCookie(args[1])
        end
    end
    if fn then return fn(java, unpack(args or {})) end
    if name == "startBrowser" or name == "startBrowserAwait" or name == "webView"
            or name == "webview" or name == "showBrowser" or name == "getVerificationCode"
            or name == "toast" or name == "longToast" then
        if type(java[name]) == "function" then return java[name](java, unpack(args or {})) end
        makeHostError("interactive Java API java." .. name .. " requires user interaction")
    end
    makeHostError("unsupported Java API java." .. tostring(name))
end

function Session:_stateMethod(kind, name, args)
    local env = self.env or {}
    if name == "get" and kind == "state" then return nil end
    local proxy = env[kind]
    if kind == "java" then
        local value = env.java and env.java[name]
        if type(value) ~= "function" then return value end
    end
    if type(proxy) ~= "table" then return nil end
    local fn = methodFromTable(proxy, name)
    if not fn then fn = proxy[name] end
    if type(fn) ~= "function" then return fn end
    return fn(proxy, unpack(args or {}))
end

function Session:_domMethod(kind, id, name, args)
    local entry = self.handles[tonumber(id)]
    if not entry then makeHostError("released " .. tostring(kind) .. " handle") end
    local value = entry.value
    if name == "release" then self.handles[tonumber(id)] = nil; return nil end
    local function removeNode(node)
        if type(node) ~= "table" then return false end
        local remove = rawget(node, "remove")
        if type(remove) == "function" then
            local ok = pcall(remove, node)
            if ok then return true end
        end
        local parent = rawget(node, "parent")
        local children = type(parent) == "table" and (rawget(parent, "children") or rawget(parent, "nodes")) or nil
        if type(children) == "table" then
            for index = #children, 1, -1 do
                if children[index] == node then table.remove(children, index); return true end
            end
        end
        return false
    end
    local function nodeValue(node, method, method_args)
        if type(node) ~= "table" then return nil end
        local fn = rawget(node, method)
        if type(fn) == "function" then return fn(node, unpack(method_args or {})) end
        if method == "text" then
            local content = rawget(node, "getcontent")
            if type(content) == "function" then
                local ok, result = pcall(content, node)
                if ok then return tostring(result or ""):gsub("<[^>]+>", "") end
            end
        elseif method == "html" then
            local content = rawget(node, "getcontent")
            if type(content) == "function" then return content(node) end
        elseif method == "outerHtml" then
            local content = rawget(node, "gettext") or rawget(node, "outerHtml")
            if type(content) == "function" then return content(node) end
            return tostring(node)
        end
        return nil
    end
    if kind == "dom_list" then
        local values = rawget(value, "__values") or {}
        if name == "values" then return values end
        if name == "size" then return #values end
        if name == "get" then return values[(tonumber(args[1]) or 0) + 1] end
        if name == "first" then return values[1] end
        if name == "last" then return values[#values] end
        if name == "text" or name == "html" then
            local output = {}
            for index, node in ipairs(values) do output[index] = tostring(nodeValue(node, name, args) or "") end
            return table.concat(output, " ")
        end
        if name == "attr" or name == "hasAttr" or name == "hasClass" then
            local first = values[1]
            if not first then return name == "hasAttr" or name == "hasClass" and false or "" end
            if name == "hasClass" then
                local classes = tostring(nodeValue(first, "attr", { "class" }) or "")
                for wanted in tostring(args[1] or ""):gmatch("%S+") do
                    if not classes:match("(^|%s)" .. wanted .. "(%s|$)") then return false end
                end
                return true
            end
            local result = nodeValue(first, name, args)
            return name == "hasAttr" and result ~= nil and tostring(result) ~= "" or result or ""
        end
        if name == "remove" then
            for index = #values, 1, -1 do removeNode(values[index]) end
            return value
        end
        if name == "select" then
            local selected = {}
            for _, node in ipairs(values) do
                local matches = nodeValue(node, "select", args)
                if type(matches) == "table" then for _, match in ipairs(matches) do selected[#selected + 1] = match end end
            end
            return { __values = selected }
        end
        if name == "toString" then
            local output = {}
            for index, node in ipairs(values) do output[index] = tostring(node or "") end
            return table.concat(output, ",")
        end
    end
    if kind == "dom" then
        if name == "select" then
            local select = type(value) == "table" and rawget(value, "select") or nil
            if type(select) == "function" then
                local matches = select(value, unpack(args or {}))
                if type(matches) == "table" and rawget(matches, "__values") == nil then return { __values = matches } end
                return matches
            end
        end
        if name == "text" or name == "html" or name == "outerHtml" then return nodeValue(value, name, args) or "" end
        if name == "selectFirst" then
            local matches = nodeValue(value, "select", args)
            return type(matches) == "table" and matches[1] or nil
        end
        if name == "hasClass" then
            local classes = tostring(nodeValue(value, "attr", { "class" }) or "")
            for wanted in tostring(args[1] or ""):gmatch("%S+") do
                if not classes:match("(^|%s)" .. wanted .. "(%s|$)") then return false end
            end
            return true
        end
        if name == "remove" then removeNode(value); return value end
    end
    local fn = type(value) == "table" and rawget(value, name) or nil
    if type(fn) == "function" then return fn(value, unpack(args or {})) end
    if name == "toString" then return tostring(value or "") end
    if fn ~= nil then return fn end
    makeHostError("unsupported " .. tostring(kind) .. " method " .. tostring(name))
end

function Session:hostCall(method, args)
    method = tostring(method or "")
    args = args or {}
    if method == "state.get" then
        local kind, key = tostring(args[1] or ""), tostring(args[2] or "")
        if kind == "java" then return (self.env.java or {})[key] end
        local proxy = self.env[kind]
        if type(proxy) == "table" then return proxy[key] end
        return nil
    elseif method == "state.set" then
        local kind, key, value = tostring(args[1] or ""), tostring(args[2] or ""), args[3]
        local proxy = self.env[kind]
        if type(proxy) == "table" then proxy[key] = value end
        return value
    elseif method:sub(1, 7) == "global." then
        local name = method:sub(8)
        local fn = self.env[name]
        if type(fn) ~= "function" then makeHostError("unsupported global function " .. name) end
        return fn(unpack(args))
    elseif method:sub(1, 5) == "java." then
        return self:_javaMethod(method:sub(6), args)
    elseif method:sub(1, 7) == "source." or method:sub(1, 5) == "book."
            or method:sub(1, 8) == "chapter." or method:sub(1, 7) == "cookie."
            or method:sub(1, 6) == "cache." then
        local dot = method:find(".", 1, true)
        local kind, name = method:sub(1, dot - 1), method:sub(dot + 1)
        return self:_stateMethod(kind, name, args)
    elseif method:sub(1, 4) == "dom." then
        return self:_domMethod("dom", args[1], method:sub(5), { unpack(args, 2) })
    elseif method:sub(1, 9) == "dom_list." then
        return self:_domMethod("dom_list", args[1], method:sub(10), { unpack(args, 2) })
    elseif method:sub(1, 9) == "response." then
        return self:_domMethod("response", args[1], method:sub(10), { unpack(args, 2) })
    elseif method:sub(1, 7) == "crypto." then
        return self:_domMethod("crypto", args[1], method:sub(8), { unpack(args, 2) })
    elseif method:sub(1, 12) == "java_object." then
        return self:_javaObjectMethod(args[1], method:sub(13), { unpack(args, 2) })
    elseif method == "handle.serialize" then
        local entry = self.handles[tonumber(args[1])]
        return entry and { __leko_kind = entry.kind, id = tonumber(args[1]) } or nil
    end
    makeHostError(method)
end

function Session:_hostCallback(request_ptr, request_len, response_ptr, response_len)
    local request_text = ffi.string(request_ptr, tonumber(request_len))
    local ok, request = pcall(rapidjson.decode, request_text)
    local response
    if not ok or type(request) ~= "table" then
        response = { ok = false, error = "invalid host request JSON" }
    else
        local args = {}
        for index, value in ipairs(request.args or {}) do args[index] = self:_decode(value) end
        local call_ok, value = pcall(function() return self:hostCall(request.method, args) end)
        local trace_args = args
        local trace_value = call_ok and value or nil
        -- Java object handle ids are process-local implementation details.
        -- Remove the id from diagnostic parameters and unwrap the return
        -- value so the differential oracle compares the Java-visible bytes
        -- and types rather than opaque QuickJS handle allocation order.
        local method_text = tostring(request.method or "")
        if method_text:sub(1, 12) == "java_object." then
            trace_args = {}
            for index = 2, #args do trace_args[#trace_args + 1] = args[index] end
        end
        if call_ok and type(value) == "table" and rawget(value, "__leko_handle_id")
                and (method_text:sub(1, 12) == "java_object."
                    or method_text == "java.static" or method_text == "java.construct") then
            local entry = self.handles[tonumber(rawget(value, "__leko_handle_id"))]
            trace_value = entry and entry.value or value
        end
        ExecutionTrace:markHost(self.env, request.method, call_ok, call_ok and nil or value,
            trace_args, trace_value)
        if call_ok then
            local encoded = self:_encode(value)
            response = { ok = true, value = encoded }
        else
            response = { ok = false, error = tostring(value) }
        end
    end
    local encoded, encode_error = jsonEncode(response)
    if not encoded then
        encoded = '{"ok":false,"error":"host response encoding failed"}'
    end
    self.host_buffer = ffi.new("uint8_t[?]", #encoded + 1)
    ffi.copy(self.host_buffer, encoded, #encoded)
    response_ptr[0] = ffi.cast("const uint8_t *", self.host_buffer)
    response_len[0] = #encoded
    return 0
end

local HOST_BOOTSTRAP = [[
(function () {
  const input = globalThis.__lekoInput || {};
  const callNative = globalThis.__lekoHostCall;
  const call = function () {
    if (typeof callNative !== "function") throw new Error("host-unsupported: QuickJS host callback is unavailable");
    return revive(callNative.apply(null, arguments));
  };
  function revive(value) {
    if (value === null || value === undefined) return value;
    if (Array.isArray(value)) return value.map(revive);
    if (typeof value !== "object") return value;
    if (value.__leko_kind === "undefined") return undefined;
    if (value.__leko_kind === "dom" || value.__leko_kind === "dom_list" || value.__leko_kind === "response"
        || value.__leko_kind === "crypto" || value.__leko_kind === "java_object"
        || value.__leko_kind === "java_byte_array")
      return makeHandle(value.__leko_kind, value.id);
    if (value.__leko_kind === "java_ref") {
      if (value.ref_kind === "package") return makeJavaPackage(value.name);
      if (value.ref_kind === "class") return makeJavaClass(value.name);
    }
    if (value.__leko_kind === "byte_array") return new Uint8Array((value.value || []).map(Number));
    const result = {};
    for (const key of Object.keys(value)) result[key] = revive(value[key]);
    return result;
  }
  function makeHandle(kind, id) {
    const target = {};
    Object.defineProperty(target, "__leko_kind", { value: kind, enumerable: false });
    Object.defineProperty(target, "__leko_id", { value: id, enumerable: false });
    return new Proxy(target, {
      get: function (object, property) {
        if (property === "__leko_kind") return kind;
        if (property === "__leko_id") return id;
        if (property === "toJSON") return function () { return { __leko_kind: kind, id: id }; };
        if (property === Symbol.toPrimitive) return function () { return call(kind + ".toString", id); };
        if (kind === "java_byte_array" && property === "length") return call("java_object.property", id, "length");
        if (kind === "java_byte_array" && typeof property === "string" && /^\d+$/.test(property))
          return call("java_object.property", id, property);
        if (kind === "java_byte_array" && property === Symbol.iterator)
          return function* () {
            const length = call("java_object.property", id, "length");
            for (let i = 0; i < length; i++) yield call("java_object.property", id, String(i));
          };
        if (kind === "dom_list" && property === "length") return call("dom_list.size", id);
        if (kind === "dom_list" && property === "forEach") return function (callback) {
          const values = call("dom_list.values", id) || [];
          values.forEach(function (item, index) { callback(item, index, values); });
        };
        if (kind === "dom_list" && property === "map") return function (callback) {
          const values = call("dom_list.values", id) || [];
          return values.map(function (item, index) { return callback(item, index, values); });
        };
        if (property === "then") return undefined;
        return function () { return call(kind + "." + String(property), id, ...arguments); };
      },
      set: function () { throw new Error("host-unsupported: DOM handles are immutable from JavaScript"); }
    });
  }
  const sourceMethods = new Set(["getLoginHeader","putLoginHeader","removeLoginHeader","put","get",
    "putLoginInfo","getLoginInfoMap","getLoginInfo","getKey","refreshExplore","refreshJSLib",
    "getVariable","setVariable","putVariable","putCustomVariable","setReverseToc","setUseReplaceRule",
    "getLoginHeaderMap"]);
  const bookMethods = new Set(["getVariable","setVariable","putVariable","putCustomVariable",
    "setReverseToc","setUseReplaceRule"]);
  const chapterMethods = new Set(["getVariable","setVariable","putVariable","putCustomVariable","isVip","isPay"]);
  function makeState(kind, initial) {
    const target = Object.assign({}, initial || {});
    const changed = Object.create(null);
    Object.defineProperty(target, "__lekoChanged", { value: changed, enumerable: false });
    const methods = kind === "source" ? sourceMethods : (kind === "book" ? bookMethods : chapterMethods);
    return new Proxy(target, {
      get: function (object, property) {
        // __lekoChanged is a non-configurable internal slot.  Proxy invariants
        // require a get trap to return the exact stored value for such a slot;
        // reviving it into a new object would make every state snapshot throw
        // `TypeError: proxy: inconsistent get` in QuickJS.
        if (property === "__lekoChanged") return object[property];
        if (property === "toJSON") return undefined;
        if (typeof property === "symbol") return object[property];
        if (Object.prototype.hasOwnProperty.call(object, property)) return revive(object[property]);
        if (methods.has(String(property))) return function () { return call(kind + "." + String(property), ...arguments); };
        return call("state.get", kind, String(property));
      },
      set: function (object, property, value) {
        object[property] = value;
        changed[String(property)] = true;
        call("state.set", kind, String(property), value);
        return true;
      },
      deleteProperty: function (object, property) {
        delete object[property];
        changed[String(property)] = true;
        call("state.set", kind, String(property), undefined);
        return true;
      }
    });
  }
  function makeService(kind) {
    return new Proxy({}, { get: function (object, property) {
      if (property === "toJSON") return undefined;
      if (property === "then") return undefined;
      return function () { return call(kind + "." + String(property), ...arguments); };
    }});
  }
  globalThis.source = makeState("source", revive(input.source));
  globalThis.book = input.book == null ? undefined : makeState("book", revive(input.book));
  globalThis.chapter = input.chapter == null ? undefined : makeState("chapter", revive(input.chapter));
  globalThis.cookie = makeService("cookie");
  globalThis.cache = makeService("cache");
  globalThis.java = new Proxy({}, { get: function (object, property) {
    if (property === "toJSON" || property === "then") return undefined;
    if (property === "ruleUrl") return call("state.get", "java", "ruleUrl");
    return function () { return call("java." + String(property), ...arguments); };
  }});
  const functions = Array.isArray(input.__lekoFunctions) ? input.__lekoFunctions : [];
  for (const name of functions) globalThis[name] = function () { return call("global." + name, ...arguments); };
  function installBinding(name, incoming) {
    const current = globalThis[name];
    const isHandle = function (value) {
      return value && typeof value === "object" && value.__leko_kind;
    };
    // DOM/response handles are immutable proxies, not ordinary objects.  A
    // reused session must replace them for the next document instead of
    // attempting to merge fields through their guarded set trap.
    if (isHandle(incoming) || isHandle(current)) {
      globalThis[name] = incoming;
      return;
    }
    // Keep mutations made to an ordinary object in the reused QuickJS
    // session (for example `params.sign = ...`) while refreshing fields that
    // the Lua caller supplies on a later evaluation.  Primitive bindings are
    // replaced below, which is required for per-request values such as
    // `baseUrl`.
    if (incoming && typeof incoming === "object" && !Array.isArray(incoming)
        && current && typeof current === "object" && !Array.isArray(current)) {
      for (const key of Object.keys(incoming)) current[key] = incoming[key];
      return;
    }
    globalThis[name] = incoming;
  }
  for (const name of Object.keys(input)) {
    if (name === "source" || name === "book" || name === "chapter" || name === "result" || name === "currentResponse"
        || name === "__lekoFunctions" || name === "__lekoSession") continue;
    if (name === "java" || name === "cookie" || name === "cache") continue;
    // Refresh primitive bindings on every evaluation, but retain ordinary
    // object mutations made by scripts in this reused session.
    installBinding(name, revive(input[name]));
  }
  globalThis.result = revive(input.result);
  globalThis.currentResponse = revive(input.currentResponse);
  globalThis.context = revive(input.context);
  globalThis.window = globalThis;
  globalThis.global = globalThis;
  function makeJavaPackage(name) {
    const target = {};
    Object.defineProperty(target, "__leko_kind", { value: "java_ref", enumerable: false });
    Object.defineProperty(target, "__leko_ref_kind", { value: "package", enumerable: false });
    Object.defineProperty(target, "__leko_name", { value: String(name || ""), enumerable: false });
    return new Proxy(target, { get: function (object, property) {
      if (property === "__leko_kind") return "java_ref";
      if (property === "__leko_ref_kind") return "package";
      if (property === "__leko_name") return object.__leko_name;
      if (property === "toJSON" || property === "then") return undefined;
      if (typeof property === "symbol") return undefined;
      const nextName = object.__leko_name
        ? object.__leko_name + "." + String(property)
        : String(property);
      return call("java.resolve", nextName);
    }});
  }
  function makeJavaClass(name) {
    const target = function () {};
    Object.defineProperty(target, "__leko_kind", { value: "java_ref", enumerable: false });
    Object.defineProperty(target, "__leko_ref_kind", { value: "class", enumerable: false });
    Object.defineProperty(target, "__leko_name", { value: String(name || ""), enumerable: false });
    return new Proxy(target, {
      get: function (object, property) {
        if (property === "__leko_kind") return "java_ref";
        if (property === "__leko_ref_kind") return "class";
        if (property === "__leko_name") return object.__leko_name;
        if (property === "toJSON" || property === "then") return undefined;
        if (typeof property === "symbol") return undefined;
        return function () { return call("java.static", object.__leko_name, String(property), ...arguments); };
      },
      apply: function (object, thisArg, args) {
        // Rhino/Legado rules commonly use an imported Java class as a
        // function (`String(value)`) rather than with `new`.  JavaImporter
        // exposes the class name in the `with` scope, so preserve that
        // construction form at the explicit host boundary as well.
        return call("java.construct", object.__leko_name, ...args);
      },
      construct: function (object, args) {
        return call("java.construct", object.__leko_name, ...args);
      }
    });
  }
  function JavaImporter() {
    const imported = {};
    imported.importPackage = function () {
      for (const packageValue of arguments) {
        if (!packageValue || packageValue.__leko_ref_kind !== "package")
          throw new Error("HOST_API_INVALID: host-unsupported: importPackage requires a Packages package");
        const packageName = packageValue.__leko_name;
        const classes = call("java.importPackage", packageName) || [];
        for (const className of classes)
          imported[className] = makeJavaClass(packageName + "." + className);
      }
      return imported;
    };
    imported.importClass = function () {
      for (const classValue of arguments) {
        if (!classValue || classValue.__leko_ref_kind !== "class")
          throw new Error("HOST_API_INVALID: host-unsupported: importClass requires a Packages class");
        const className = classValue.__leko_name;
        imported[className.slice(className.lastIndexOf(".") + 1)] = classValue;
      }
      return imported;
    };
    imported.importPackage(...arguments);
    return imported;
  }
  globalThis.JavaImporter = JavaImporter;
  globalThis.Packages = makeJavaPackage("");
  if (typeof globalThis.Java === "undefined") globalThis.Java = { type: function (name) {
    return call("java.resolve", String(name));
  }};
  // Keep unsupported Rhino/Android constructors explicit at runtime.  An
  // undefined identifier would otherwise surface as a misleading generic
  // ReferenceError/TypeError, while the compatibility classifier already
  // knows these names are outside the KOReader host boundary.
  for (const name of ["SecretKeySpec", "IvParameterSpec",
      "PKCS8EncodedKeySpec", "ByteArrayInputStream", "ByteArrayOutputStream",
      "GZIPInputStream", "OkHttpClient", "LinkedHashMap", "Request"]) {
    if (typeof globalThis[name] === "undefined") globalThis[name] = function () {
      throw new Error("host-unsupported: constructor " + name + " is not mapped");
    };
  }
  function wire(value, seen) {
    if (value === null) return { __leko_kind: "null" };
    if (value === undefined) return { __leko_kind: "undefined" };
    if (value && value.__leko_kind === "java_ref") return {
      __leko_kind: "java_ref", ref_kind: value.__leko_ref_kind, name: value.__leko_name
    };
    if (typeof value === "function") return { __leko_kind: "function" };
    if (typeof value === "bigint") return { __leko_kind: "bigint", value: String(value) };
    if (typeof value !== "object") return value;
    if (value.__leko_kind) return { __leko_kind: value.__leko_kind, id: value.__leko_id };
    if (value instanceof Uint8Array) {
      return { __leko_kind: "byte_array", value: Array.from(value, function (item) { return Number(item); }) };
    }
    seen = seen || [];
    if (seen.indexOf(value) >= 0) return { __leko_kind: "undefined" };
    seen.push(value);
    if (Array.isArray(value)) {
      const array = value.map(function (item) { return wire(item, seen); });
      seen.pop();
      return array;
    }
    const object = {};
    for (const key of Object.keys(value)) object[key] = wire(value[key], seen);
    seen.pop();
    return object;
  }
  function snapshot(value) {
    if (value === undefined) return null;
    const result = {};
    const changed = value && value.__lekoChanged;
    const keys = changed ? Object.keys(changed) : Object.keys(value);
    for (const key of keys) {
      const item = value[key];
      if (typeof item !== "function" && key.indexOf("__leko") !== 0) result[key] = item;
    }
    return result;
  }
  const sourceText = __LEKO_USER_SCRIPT__;
  let value;
  try {
    value = (0, eval)(sourceText);
  } catch (error) {
    const message = String(error && error.message || error);
    if (message.indexOf("return") >= 0
        && (message.indexOf("outside") >= 0 || message.indexOf("not in a function") >= 0))
      value = (new Function(sourceText))();
    else throw error;
  }
  return { value: wire(value), state: {
    source: wire(snapshot(globalThis.source)), book: wire(snapshot(globalThis.book)),
    chapter: wire(snapshot(globalThis.chapter))
  } };
})()
]]

local QJS_DRIVER = [[
import * as std from "std";
const inputPath = scriptArgs[1];
const sourcePath = scriptArgs[2];
const outputPath = scriptArgs[3];
let result;
try {
  globalThis.__lekoInput = JSON.parse(std.loadFile(inputPath));
  const source = std.loadFile(sourcePath);
  result = (0, eval)(source);
} catch (error) {
  result = { kind: "error", message: String(error && error.toString ? error.toString() : error) + "\n" + String(error && error.stack || "") };
}
const output = std.open(outputPath, "w");
output.puts(JSON.stringify(result));
output.close();
]]

local function fillBootstrap(script)
    local encoded, err = jsonEncode(tostring(script or ""))
    if not encoded then return nil, err end
    return HOST_BOOTSTRAP:gsub("__LEKO_USER_SCRIPT__", function() return encoded end), nil
end

function Session:_nativeError(error_value, fallback)
    local message = fallback or "QuickJS execution failed"
    if error_value and error_value.message ~= nil then
        local ok, value = pcall(ffi.string, error_value.message, tonumber(error_value.message_len) or 0)
        if ok and value and value ~= "" then message = value end
    end
    if error_value and error_value.stack ~= nil then
        local ok, value = pcall(ffi.string, error_value.stack, tonumber(error_value.stack_len) or 0)
        if ok and value and value ~= "" then message = message .. "\n" .. value end
    end
    return message
end

function Session:_freeNative()
    local lib = self.lib
    if lib and self.context ~= nil then
        pcall(lib.lqjs_context_free, self.context)
        self.context = nil
    end
    if lib and self.runtime ~= nil then
        pcall(lib.lqjs_runtime_free, self.runtime)
        self.runtime = nil
    end
    self.native = false
    self.host_buffer = nil
    -- LuaJIT owns the callback trampoline through this reference.  It must be
    -- released only after the native context has stopped calling it.
    -- All native contexts share one process-level FFI callback trampoline;
    -- the synchronous eval dispatcher selects the current session.
    self.callback = nil
end

function Session:_newNative()
    local lib = loadNative()
    if not lib then return nil, ffi_error or "QuickJS native bridge unavailable" end
    self.lib = lib
    local options = ffi.new("lqjs_runtime_options")
    options.abi_version, options.flags = BRIDGE_ABI, 0
    options.memory_limit_bytes, options.max_stack_bytes = MAX_MEMORY, MAX_STACK
    local error_value = ffi.new("lqjs_error")
    self.runtime = lib.lqjs_runtime_new(options, error_value)
    if self.runtime == nil then return nil, self:_nativeError(error_value, "QuickJS runtime creation failed") end
    self.context = lib.lqjs_context_new(self.runtime, error_value)
    if self.context == nil then
        self:_freeNative()
        return nil, self:_nativeError(error_value, "QuickJS context creation failed")
    end
    local policy = '{}'
    local policy_bytes = ffi.new("uint8_t[?]", #policy)
    ffi.copy(policy_bytes, policy, #policy)
    local status = lib.lqjs_context_install_host_policy_json(self.context, policy_bytes, #policy, error_value)
    if tonumber(status) ~= 0 then
        local message = self:_nativeError(error_value, "QuickJS host policy setup failed")
        self:_freeNative()
        return nil, message
    end
    if not native_callback then
        native_callback = ffi.cast("lqjs_host_call_fn", function(_, request, request_len, response, response_len)
            local session = current_native_session
            if not session then return -1 end
            return session:_hostCallback(request, request_len, response, response_len)
        end)
    end
    self.callback = native_callback
    status = lib.lqjs_context_install_host_callback(self.context, native_callback, nil, error_value)
    if tonumber(status) ~= 0 then
        local message = self:_nativeError(error_value, "QuickJS host callback setup failed")
        self:_freeNative()
        return nil, message
    end
    self.native = true
    return true
end

function Session:_evalNative(script, input, timeout_ms, max_result_bytes)
    local script_bytes = ffi.new("uint8_t[?]", #script + 1)
    ffi.copy(script_bytes, script, #script)
    local input_json, input_error = jsonEncode(input)
    if not input_json then return nil, "QuickJS input encoding failed: " .. tostring(input_error) end
    local input_bytes = ffi.new("uint8_t[?]", #input_json + 1)
    ffi.copy(input_bytes, input_json, #input_json)
    local options = ffi.new("lqjs_eval_options")
    options.abi_version, options.flags = BRIDGE_ABI, 0
    options.timeout_ms, options.max_result_bytes = timeout_ms or DEFAULT_TIMEOUT, max_result_bytes or DEFAULT_RESULT
    local result_ptr = ffi.new("uint8_t *[1]")
    local result_len = ffi.new("size_t[1]")
    local error_value = ffi.new("lqjs_error")
    local previous_session = current_native_session
    current_native_session = self
    local status = self.lib.lqjs_eval_json(self.context, script_bytes, #script,
        input_bytes, #input_json, options, result_ptr, result_len, error_value)
    current_native_session = previous_session
    if tonumber(status) ~= 0 then return nil, self:_nativeError(error_value) end
    local result_json = ffi.string(result_ptr[0], tonumber(result_len[0]))
    self.lib.lqjs_buffer_free(result_ptr[0])
    local ok, decoded = pcall(rapidjson.decode, result_json)
    if not ok then return nil, "QuickJS bridge returned invalid JSON: " .. tostring(decoded) end
    return decoded
end

function Session:memoryStats()
    if not self.native or not self.lib or self.runtime == nil then return nil end
    local current = ffi.new("size_t[1]")
    local peak = ffi.new("size_t[1]")
    -- Looking up a missing optional export happens before a normal pcall can
    -- run.  Keep older bridge DLLs from taking down the LuaJIT worker while
    -- still reporting memory when the current bridge provides the API.
    local lookup_ok, memory_usage = pcall(function()
        return self.lib.lqjs_runtime_memory_usage
    end)
    if not lookup_ok or memory_usage == nil then return nil end
    local call_ok = pcall(memory_usage, self.runtime, current, peak)
    if not call_ok then return nil end
    return {
        current_bytes = tonumber(current[0]) or 0,
        peak_bytes = tonumber(peak[0]) or 0,
    }
end

function Session:_evalQJS(script, input)
    local executable = qjsExecutable()
    if not executable then return nil, "QuickJS engine unavailable: set LEKO_QUICKJS_QJS for desktop tests" end
    local input_path, source_path, output_path, driver_path = tempPath(".input"), tempPath(".source"), tempPath(".output"), tempPath(".driver.js")
    local function cleanup()
        for _, path in ipairs({ input_path, source_path, output_path, driver_path }) do pcall(os.remove, path) end
    end
    local input_json, input_error = jsonEncode(input)
    if not input_json then cleanup(); return nil, "QuickJS input encoding failed: " .. tostring(input_error) end
    local ok, err = writeFile(input_path, input_json)
    if not ok then cleanup(); return nil, err end
    ok, err = writeFile(source_path, script)
    if not ok then cleanup(); return nil, err end
    ok, err = writeFile(driver_path, QJS_DRIVER)
    if not ok then cleanup(); return nil, err end
    local command = table.concat({ shellQuote(executable), shellQuote(driver_path), shellQuote(input_path), shellQuote(source_path), shellQuote(output_path) }, " ")
    if package.config and package.config:sub(1, 1) == "\\" then
        -- Lua 5.3's os.execute on Windows does not reliably launch a quoted
        -- executable path directly.  Let cmd parse the complete argv once.
        command = "cmd.exe /d /c \"" .. command .. "\""
    end
    local status = os.execute(command)
    local output = readFile(output_path)
    cleanup()
    if not output or output == "" then return nil, "QuickJS qjs process failed: " .. tostring(status) .. " command=" .. command end
    local decoded_ok, decoded = pcall(rapidjson.decode, output)
    if not decoded_ok then return nil, "QuickJS qjs returned invalid JSON: " .. tostring(decoded) end
    if decoded.kind == "error" then return nil, tostring(decoded.message or "QuickJS exception") end
    return { kind = "json", value = decoded }
end

local function compactSessions()
    for index = #active_sessions, 1, -1 do
        local session = active_sessions[index]
        if not session or session.closed then table.remove(active_sessions, index) end
    end
end

local function oldestIdleSession()
    local oldest, oldest_time
    for _, session in ipairs(active_sessions) do
        if session and not session.closed and (tonumber(session.busy) or 0) == 0 then
            local used = tonumber(session.last_used) or 0
            if not oldest or used < oldest_time then oldest, oldest_time = session, used end
        end
    end
    return oldest
end

local function reserveSession()
    compactSessions()
    while #active_sessions >= MAX_ACTIVE_SESSIONS do
        local oldest = oldestIdleSession()
        if not oldest then
            return nil, "QuickJS session limit reached: all sessions are busy"
        end
        oldest:close()
        compactSessions()
    end
    return true
end

function Session:close()
    if self.closed then return end
    self.closed = true
    self.handles = {}
    self.next_handle = 1
    self:_freeNative()
    if self.env and rawget(self.env, "__quickjs_session") == self then
        rawset(self.env, "__quickjs_session", nil)
    end
    if self.source_target and rawget(self.source_target, "__quickjs_session") == self then
        rawset(self.source_target, "__quickjs_session", nil)
    end
    self.env = nil
    self.source_target = nil
end

function Session.new(env)
    local reserved, reserve_error = reserveSession()
    if not reserved then return nil, reserve_error end
    local self = setmetatable({
        env = env or {}, native = false, closed = false, handles = {}, next_handle = 1,
        busy = 0, last_used = os.clock(), source_target = nil,
    }, Session)
    active_sessions[#active_sessions + 1] = self
    if ffi_ok then
        local call_ok, native_ok, err = pcall(function() return self:_newNative() end)
        if not call_ok then
            self:_freeNative()
            native_ok, err = nil, tostring(native_ok)
        end
        if not native_ok then self.native_error = err end
    end
    if not self.native and nativeRequired() then
        self.native_error = self.native_error or "native QuickJS is required; desktop qjs fallback is disabled"
    elseif not self.native then
        self.qjs = qjsExecutable()
    end
    return self
end

local function serializeEnv(session, env)
    local input = {}
    local functions = {}
    local skip = {
        java = true, cookie = true, cache = true, source = true, book = true,
        chapter = true, result = true, currentResponse = true,
        __quickjs_session = true, __js_lib = true,
    }
    for key, value in pairs(env or {}) do
        if type(key) == "string" and key:sub(1, 2) ~= "__" then
            if type(value) == "function" then
                functions[#functions + 1] = key
            elseif not skip[key] then
                input[key] = session:_encode(value)
            end
        end
    end
    input.source = session:_encode(env and env.source)
    input.book = session:_encode(env and env.book)
    input.chapter = session:_encode(env and env.chapter)
    input.result = session:_encode(env and env.result)
    input.currentResponse = session:_encode(env and env.currentResponse)
    input.context = session:_encode(env and env.context)
    input.__lekoFunctions = functions
    return input
end

local function applyState(session, env, state)
    if type(state) ~= "table" then return end
    local aliases = {
        source = { bookSourceUrl = "source_key", bookSourceName = "name", bookSourceGroup = "group" },
        book = {
            bookUrl = "book_url", tocUrl = "toc_url", coverUrl = "cover", name = "title",
            kind = "kind", wordCount = "word_count", lastChapter = "last_chapter",
            latestChapterTitle = "last_chapter", canUpdate = "can_update",
        },
        chapter = { chapterUrl = "url", name = "title", isVipValue = "is_vip", isPayValue = "is_pay" },
    }
    for _, kind in ipairs({ "source", "book", "chapter" }) do
        local values = state[kind]
        local target = env and env[kind]
        if type(values) == "table" and type(target) == "table" then
            local mapped_keys = {}
            for key in pairs(values) do
                local mapped = aliases[kind] and aliases[kind][key]
                if mapped then mapped_keys[mapped] = true end
            end
            for key, value in pairs(values) do
                if tostring(key):sub(1, 2) ~= "__" then
                    local decoded = session:_decode(value)
                    -- Host methods such as setReverseToc/putVariable mutate
                    -- the Lua-owned variables table.  Merge its serialized
                    -- snapshot instead of replacing the table with the stale
                    -- JS copy captured before the host call.
                    local mapped = aliases[kind] and aliases[kind][key] or key
                    -- When JavaScript wrote through a Legado camelCase alias,
                    -- the host proxy has already updated the canonical Lua
                    -- field.  The state snapshot still contains the stale
                    -- canonical field captured before that write; do not let
                    -- it undo the host side effect.
                    if aliases[kind] and aliases[kind][key] == nil and mapped_keys[key] then
                        goto continue_state_value
                    end
                    if key == "variables" and type(decoded) == "table" and type(target.variables) == "table" then
                        for variable, variable_value in pairs(decoded) do
                            target.variables[variable] = variable_value
                        end
                    else
                        target[mapped] = decoded
                    end
                end
                ::continue_state_value::
            end
        end
    end
end

function Session:_eval(script, env, options)
    if self.closed then return nil, "QuickJS session is closed" end
    self.env = env or self.env or {}
    script = QuickJS:unwrap(script)
    if trim(script) == "" then return nil end
    local source, source_error = fillBootstrap(script)
    if not source then return nil, source_error end
    local input = serializeEnv(self, self.env)
    local result, err
    if self.native then
        result, err = self:_evalNative(source, input,
            options and options.timeout_ms or DEFAULT_TIMEOUT,
            options and options.max_result_bytes or DEFAULT_RESULT)
    else
        result, err = self:_evalQJS(source, input)
    end
    if not result then return nil, err end
    if result.kind == "undefined" then return nil end
    local envelope = result.value
    if type(envelope) ~= "table" then return self:_decode(envelope) end
    applyState(self, self.env, envelope.state)
    return self:_decode(envelope.value)
end

function Session:eval(script, env, options)
    if self.closed then return nil, "QuickJS session is closed" end
    self.busy = (tonumber(self.busy) or 0) + 1
    self.last_used = os.clock()
    local result = pack(xpcall(function()
        return self:_eval(script, env, options)
    end, debug.traceback))
    self.busy = math.max(0, (tonumber(self.busy) or 1) - 1)
    self.last_used = os.clock()
    if not result[1] then return nil, "QuickJS execution panic: " .. tostring(result[2]) end
    return unpack(result, 2, result.n)
end

function QuickJS:unwrap(script)
    script = trim(script)
    script = script:gsub("^@[Jj][Ss]:%s*", "")
    script = script:gsub("^<[Jj][Ss]>%s*", "")
    script = script:gsub("%s*</[Jj][Ss]>$", "")
    return trim(script)
end

function QuickJS:_session(env)
    env = env or {}
    local session = rawget(env, "__quickjs_session")
    if session and not session.closed then
        session.env, session.last_used = env, os.clock()
        return session
    end
    local source = rawget(env, "source")
    local source_target = type(source) == "table" and rawget(source, "__target") or nil
    source_target = type(source_target) == "table" and source_target or nil
    if source_target and rawget(source_target, "__quickjs_session")
            and not rawget(source_target, "__quickjs_session").closed then
        session = rawget(source_target, "__quickjs_session")
        session.env, session.source_target, session.last_used = env, source_target, os.clock()
    else
        local create_error
        session, create_error = Session.new(env)
        if not session then return nil, create_error end
        session.source_target = source_target
        if source_target then rawset(source_target, "__quickjs_session", session) end
    end
    rawset(env, "__quickjs_session", session)
    return session
end

function QuickJS:eval(script, env, options)
    if env and rawget(env, "__js_lib_error") then
        env.last_js_error = rawget(env, "__js_lib_error")
        return nil, rawget(env, "__js_lib_error")
    end
    local session, session_error = self:_session(env)
    if not session then
        if env then env.last_js_error = session_error end
        return nil, session_error
    end
    ExecutionTrace:markJs(env, script)
    local value, err = session:eval(script, env, options)
    -- Keep the return type/value on the same bounded trace entry for every
    -- production JS call site (URL/header/body scripts, login checks,
    -- preUpdateJs, jsLib, and field rules), not only RuleEngine selectors.
    ExecutionTrace:markJsResult(env, value, err)
    if err and env then env.last_js_error = err end
    return value, err
end

function QuickJS:installLibrary(script, env)
    script = trim(script)
    if script == "" then return nil end
    local previous_kind
    if env then
        previous_kind = rawget(env, "__diagnostic_js_kind")
        rawset(env, "__diagnostic_js_kind", "library")
    end
    local value, err = self:eval(script, env)
    if env then rawset(env, "__diagnostic_js_kind", previous_kind) end
    return value, err
end

function QuickJS:closeSession(target)
    local session
    if type(target) == "table" then
        session = rawget(target, "__quickjs_session")
        if not session and type(rawget(target, "raw")) == "table" then
            session = rawget(rawget(target, "raw"), "__quickjs_session")
        end
        if not session then
            local source = rawget(target, "source")
            local source_target = type(source) == "table" and rawget(source, "__target") or nil
            session = type(source_target) == "table" and rawget(source_target, "__quickjs_session") or nil
        end
    end
    if session and type(session.close) == "function" then session:close(); return true end
    return false
end

function QuickJS:closeAll()
    for index = #active_sessions, 1, -1 do
        local session = active_sessions[index]
        if session and type(session.close) == "function" then session:close() end
    end
    compactSessions()
end

function QuickJS:sessionStats()
    compactSessions()
    local native, busy = 0, 0
    for _, session in ipairs(active_sessions) do
        if session.native then native = native + 1 end
        if (tonumber(session.busy) or 0) > 0 then busy = busy + 1 end
    end
    return { active = #active_sessions, native = native, busy = busy, limit = MAX_ACTIVE_SESSIONS }
end

function QuickJS:canEvaluate(script)
    script = self:unwrap(script)
    if script == "" then return true end
    -- This method is also used by source import/compatibility analysis, which
    -- can run in KOReader's UI process.  Do not call ffi.load here: a broken
    -- ARM ELF or an incompatible loader is a native-process failure, not a
    -- Lua error that pcall can contain.  The real load/evaluation happens in
    -- the source worker (or the isolated runtime self-check), where the
    -- failure is classified and the parent can quarantine the bridge.
    if native_disabled then
        return false, ffi_error or "QuickJS native bridge is quarantined"
    end
    if ffi_ok and ffi_abi_ok then
        local plugin_dir = pathDir(pathDir(modulePath()))
        local candidates = {}
        local configured = os.getenv and os.getenv("LEKO_QUICKJS_LIBRARY") or nil
        if configured and configured ~= "" then candidates[#candidates + 1] = configured end
        candidates[#candidates + 1] = plugin_dir .. "/native/liblekoqjs.so"
        candidates[#candidates + 1] = plugin_dir .. "/native/liblekoqjs.dll"
        candidates[#candidates + 1] = plugin_dir .. "/Leko/native/liblekoqjs.so"
        candidates[#candidates + 1] = plugin_dir .. "/Leko/native/liblekoqjs.dll"
        for _, path in ipairs(candidates) do
            if fileExists(path) then return true end
        end
    end
    if nativeRequired() then
        return false, ffi_error or "native QuickJS is required; desktop qjs fallback is disabled"
    end
    if qjsExecutable() then return true end
    return false, ffi_error or "QuickJS engine unavailable"
end

-- A SIGSEGV in a native bridge cannot be caught by LuaJIT's pcall.  The UI
-- self-check therefore quarantines the bridge in the parent process when its
-- isolated probe dies.  Future source workers inherit this state at fork and
-- report an ordinary JavaScript-runtime-unavailable error instead of loading
-- the known-bad library again.
function QuickJS:markNativeUnsafe(reason)
    native_disabled = true
    ffi_lib = nil
    ffi_error = "QuickJS native bridge quarantined: " .. tostring(reason or "native process crashed")
    return true
end

function QuickJS:nativeIsQuarantined()
    return native_disabled == true
end

function QuickJS:engineInfo()
    local lib = loadNative()
    if lib then
        local ok_engine, engine = pcall(function() return ffi.string(lib.lqjs_engine_version()) end)
        local ok_bridge, bridge = pcall(function() return ffi.string(lib.lqjs_bridge_version()) end)
        return {
            available = true, kind = "native", engine = ok_engine and engine or ENGINE_VERSION,
            bridge = ok_bridge and bridge or BRIDGE_VERSION, abi = BRIDGE_ABI,
        }
    end
    if nativeRequired() then
        return {
            available = false, kind = "native-required", engine = ENGINE_VERSION,
            abi = BRIDGE_ABI, error = ffi_error or "native QuickJS is required for this runtime",
        }
    end
    return { available = qjsExecutable() ~= nil, kind = "qjs-cli", engine = ENGINE_VERSION, abi = BRIDGE_ABI, error = ffi_error }
end

-- This probe intentionally exercises syntax and built-ins that a text
-- transpiler/evaluator cannot convincingly fake, then calls java.log so the UI
-- can prove the Legado host bridge was crossed in the same session.
local SELF_CHECK_SCRIPT = [[
(() => {
    const mapped = [1, 2, 3].map(value => value * 2);
    const roundTrip = JSON.parse(JSON.stringify({ mapped, text: "Leko QuickJS" }));
    const regexMatched = /^Leko\s+QuickJS$/.test(roundTrip.text);
    const bridgeReturn = java.log("Leko QuickJS runtime self-check");
    const aesFixture = "mqz0140mOY5D4gQzJJPU5Ihf4dDLadLLhhSfQeyrr0Y=";
    const aesExpected = "Leko AES bridge self-check";
    const aesScalar = java.aesBase64DecodeToString(aesFixture,
        "0123456789abcdef", "AES/CBC/PKCS5Padding", "abcdef9876543210");
    const aesCipher = java.createSymmetricCrypto("AES/CBC/PKCS5Padding",
        "0123456789abcdef", "abcdef9876543210");
    return {
        mapped: roundTrip.mapped.join("-"),
        regex: regexMatched,
        bridge_return_is_undefined: bridgeReturn === undefined,
        aes_direct_api: aesScalar === aesExpected,
        aes_object_api: aesCipher.decryptStr(aesFixture) === aesExpected,
    };
})()
]]

function QuickJS:selfCheck()
    local started = os.clock()
    local info = self:engineInfo()
    local report = {
        native_loaded = info.kind == "native" and info.available == true,
        engine = info.engine,
        bridge = info.bridge,
        abi = info.abi,
        script = SELF_CHECK_SCRIPT,
        bridge_called = false,
        result = nil,
        error = nil,
        elapsed_ms = 0,
        peak_memory_bytes = 0,
        memory_source = "QuickJS JS_ComputeMemoryUsage sampled at evaluation boundaries",
    }
    if not report.native_loaded then
        report.error = info.error or "native QuickJS library is unavailable"
        report.elapsed_ms = math.floor((os.clock() - started) * 1000 + 0.5)
        return report
    end

    local bridge_called = false
    local env = {
        java = {
            log = function() bridge_called = true end,
        },
    }
    local session, session_err = Session.new(env)
    if not session then
        report.error = session_err
    else
        local before = session:memoryStats()
        local value, eval_err = session:eval(SELF_CHECK_SCRIPT, env, {
            timeout_ms = DEFAULT_TIMEOUT, max_result_bytes = DEFAULT_RESULT,
        })
        local after = session:memoryStats()
        report.bridge_called = bridge_called
        report.result = value
        report.error = eval_err
        report.peak_memory_bytes = math.max(
            tonumber(before and before.peak_bytes or 0) or 0,
            tonumber(after and after.peak_bytes or 0) or 0)
        session:close()
    end
    report.elapsed_ms = math.floor((os.clock() - started) * 1000 + 0.5)
    report.ok = report.native_loaded and report.error == nil
        and report.bridge_called == true and type(report.result) == "table"
        and report.result.mapped == "2-4-6"
        and report.result.regex == true
        and report.result.aes_direct_api == true
        and report.result.aes_object_api == true
    return report
end

QuickJS.SELF_CHECK_SCRIPT = SELF_CHECK_SCRIPT

QuickJS.ENGINE_VERSION = ENGINE_VERSION
QuickJS.BRIDGE_ABI = BRIDGE_ABI
QuickJS.BRIDGE_VERSION = BRIDGE_VERSION
QuickJS.MAX_ACTIVE_SESSIONS = MAX_ACTIVE_SESSIONS
QuickJS.Session = Session

return QuickJS
