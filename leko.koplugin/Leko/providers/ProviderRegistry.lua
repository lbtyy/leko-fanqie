local logger = require("logger")

-- Leko/providers/ProviderRegistry.lua
--
-- Provider 注册器 + 合规门禁唯一出口（G6）。
-- 任何代码不得绕过本模块直接构造番茄 Provider 实例：
-- "fanqie:*" 域的 get() 在 FanqieCompliance 未确认时一律返回 nil，
-- 使番茄网络请求在代码路径上不可达。
--
-- 内置 Provider 采用运行时惰性 require：注册表在 load 期不引用具体
-- Provider 模块，规避 ProviderRegistry ↔ AsyncProviderTask ↔
-- Fanqie*Provider 之间的 load-time 循环依赖。子进程 fork 后同样经
-- get() 惰性加载，语义一致。

local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")

-- 内置 Provider：id → 模块路径（惰性加载）。
-- fanqie:official 由 Provider 抽象层阶段①（T03）注册；fanqie:dahuilang 与
-- fanqie:qingtian 由阶段④（T08）注册。同一域（fanqie）共享 RateLimiter
-- 数据目录 data/leko/providers/fanqie/。
local BUILTIN_PROVIDERS = {
    ["fanqie:official"] = "Leko/Fanqie/FanqieOfficialProvider",
    ["fanqie:dahuilang"] = "Leko/Fanqie/FanqieDahuilangProvider",
    ["fanqie:qingtian"] = "Leko/Fanqie/FanqieQingtianProvider",
}

local ProviderRegistry = {
    providers = {},
}

local function domainOf(id)
    return tostring(id or ""):match("^([^:]+):") or ""
end

local function complianceAllowed(id)
    -- 目前唯一受合规门禁约束的域是 fanqie；未来新增域在此登记。
    if domainOf(id) == "fanqie" then
        return FanqieCompliance:isEnabled()
    end
    return true
end

--- 注册一个 Provider 实例（模块返回的单例 table）。
-- @param provider table 至少包含 id/name/capabilities
-- @return boolean, err
function ProviderRegistry:register(provider)
    if type(provider) ~= "table" then return false, "provider must be a table" end
    local id = tostring(provider.id or "")
    if id == "" or not id:find(":", 1, true) then
        return false, "provider id 必须形如 <域>:<源>"
    end
    if type(provider.capabilities) ~= "table" then
        return false, "provider.capabilities 缺失"
    end
    self.providers[id] = provider
    logger.info("Leko ProviderRegistry: registered", id)
    return true
end

function ProviderRegistry:_ensureBuiltin(id)
    if self.providers[id] then return true end
    local module = BUILTIN_PROVIDERS[id]
    if not module then return false end
    local ok, provider = pcall(require, module)
    if not ok or type(provider) ~= "table" then
        logger.err("Leko ProviderRegistry: builtin provider load failed:", id, tostring(provider))
        return false
    end
    local registered, err = self:register(provider)
    if not registered then
        logger.err("Leko ProviderRegistry: builtin provider register failed:", id, tostring(err))
        return false
    end
    return true
end

--- 查询 Provider（合规门禁在此生效）。
-- @return Provider|nil 未注册或合规门禁未通过时为 nil
function ProviderRegistry:get(id)
    id = tostring(id or "")
    if id == "" then return nil end
    if not complianceAllowed(id) then return nil end
    self:_ensureBuiltin(id)
    return self.providers[id]
end

--- 所有已注册且 isEnabled() 的 Provider（数组，按 id 排序）。
function ProviderRegistry:enabledProviders()
    local list = {}
    for id, _ in pairs(BUILTIN_PROVIDERS) do self:_ensureBuiltin(id) end
    for id, provider in pairs(self.providers) do
        if complianceAllowed(id) then
            local enabled = false
            if type(provider.isEnabled) == "function" then
                local ok, value = pcall(provider.isEnabled, provider)
                enabled = ok and value == true
            end
            if enabled then list[#list + 1] = provider end
        end
    end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return list
end

--- @return table|nil capabilities 表；Provider 不可用时为 nil
function ProviderRegistry:capabilitiesOf(id)
    local provider = self:get(id)
    return provider and provider.capabilities or nil
end

--- 启动预热：注册内置 Provider（不触发网络，仅加载模块）。
-- App:init 调用；每个 Provider 独立 pcall，单个失败不影响其余。
function ProviderRegistry:warmup()
    for id, _ in pairs(BUILTIN_PROVIDERS) do
        local ok, err = pcall(function() self:_ensureBuiltin(id) end)
        if not ok then logger.err("Leko ProviderRegistry: warmup failed:", id, tostring(err)) end
    end
    return true
end

return ProviderRegistry
