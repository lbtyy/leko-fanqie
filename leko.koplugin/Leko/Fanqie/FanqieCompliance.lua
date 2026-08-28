local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Util = require("Leko/Util")

-- 番茄合规门禁（G6 守门人）。
--
-- 用户首次开启番茄功能前必须确认免责声明；确认状态持久化到
-- data/leko/providers/fanqie/compliance.lua。未确认时
-- ProviderRegistry:get() 对任何 "fanqie:*" Provider 返回 nil，
-- 番茄域名请求在代码路径上不可达（默认零番茄网络请求）。
--
-- 本模块刻意不 require Leko/Storage：Storage 的加载链较重，
-- 而门禁必须在 Provider 注册器的最早期就可用。数据目录定位与
-- Storage:getProviderDataDir("fanqie") 使用同一公式，改动时必须同步。

local TEXT = {
    disclaimer_title = "开启番茄源前的声明",
    disclaimer = table.concat({
        "番茄功能通过官方公开接口访问您自己账号的书架与阅读进度。",
        "",
        "1. 本插件不提供、不分发任何书源与内容，仅接入您已合法拥有访问权限的账号数据。",
        "2. 登录凭证（Cookie）仅保存在本机数据目录，不会上传到任何第三方服务器。",
        "3. 请遵守番茄小说的用户协议与适用法律，仅用于个人阅读，不要用于批量抓取或传播。",
        "4. 聚合源服务器地址完全来自您自己的 config.lua 配置，插件不内置、不推荐任何第三方聚合服务。",
        "",
        "确认后即表示您理解并同意以上条款。",
    }, "\n"),
    ok = "我已阅读并同意",
    cancel = "取消",
}

local FanqieCompliance = {
    _settings = nil,
    _confirmed = nil,
}

-- 与 Storage:getProviderDataDir("fanqie") 相同的定位公式（保持同步）。
local function fanqieDataDir()
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", "fanqie")
end

local function compliancePath()
    return Util.joinPath(fanqieDataDir(), "compliance.lua")
end

function FanqieCompliance:_load()
    if self._confirmed ~= nil then return self._confirmed end
    self._confirmed = false
    local path = compliancePath()
    if lfs.attributes(path, "mode") == "file" then
        local ok, data = pcall(function() return LuaSettings:open(path).data end)
        if ok and type(data) == "table" and data.disclaimer_confirmed == true then
            self._confirmed = true
        end
    end
    return self._confirmed
end

--- 合规门禁唯一判定出口。
-- @return boolean 用户已确认免责声明时为 true
function FanqieCompliance:isEnabled()
    return self:_load() == true
end

local function persist(confirmed)
    Util.mkdirp(fanqieDataDir())
    local settings = LuaSettings:open(compliancePath())
    settings.data = {
        disclaimer_confirmed = confirmed == true,
        confirmed_at = confirmed and os.time() or nil,
        version = 1,
    }
    local ok, err = pcall(settings.flush, settings)
    if not ok then
        logger.err("Leko FanqieCompliance: flush failed:", tostring(err))
        return false
    end
    return true
end

--- 首次开启番茄源时弹出免责声明。
-- 已确认过：立即返回 true（可选地同步触发 on_confirmed）。
-- 未确认：弹 ConfirmBox，用户确认后持久化并回调 on_confirmed，返回 false。
-- @param options table|nil { on_confirmed = function, on_cancelled = function }
-- @return boolean 当前是否已处于已确认状态
function FanqieCompliance:requireConfirmation(options)
    if self:isEnabled() then
        if type(options) == "table" and type(options.on_confirmed) == "function" then
            pcall(options.on_confirmed)
        end
        return true
    end
    options = options or {}
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local dialog
    dialog = ConfirmBox:new{
        title = TEXT.disclaimer_title,
        text = TEXT.disclaimer,
        ok_text = TEXT.ok,
        cancel_text = TEXT.cancel,
        ok_callback = function()
            if persist(true) then
                self._confirmed = true
                logger.info("Leko FanqieCompliance: disclaimer confirmed")
                if type(options.on_confirmed) == "function" then pcall(options.on_confirmed) end
            end
        end,
        cancel_callback = function()
            if type(options.on_cancelled) == "function" then pcall(options.on_cancelled) end
        end,
    }
    UIManager:show(dialog)
    return false
end

--- 撤销确认（设置页"关闭番茄源"使用）：回到未确认状态，门禁立即关闭。
function FanqieCompliance:revoke()
    self._confirmed = false
    persist(false)
    logger.info("Leko FanqieCompliance: disclaimer revoked")
    return true
end

--- 测试/调试用：丢弃内存缓存，下次 isEnabled 重新读盘。
function FanqieCompliance:resetCache()
    self._confirmed = nil
end

return FanqieCompliance
