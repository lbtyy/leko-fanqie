local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local FanqieAuth = require("Leko/Fanqie/FanqieAuth")
local QRCode = require("Leko/QRCode")
local QRCodeWidget = require("Leko/QRCodeWidget")
local UI = require("Leko/UI")

-- Leko/Fanqie/QRLoginView.lua
--
-- 番茄扫码登录视图（全屏）。
-- UI 骨架复用 leko MobileSourceImportView 的布局模式（header/二维码/
-- 状态行/footer），二维码渲染复用 Leko/QRCode + QRCodeWidget；
-- 登录流程编排（轮询/generation 防旧回调）在 FanqieAuth，
-- 移植自 fanqie/qrlogin.lua:216-521（溯源注释见 FanqieAuth）。
--
-- 本视图实现 FanqieAuth 约定的四个回调：
--   showQr(qr_url) / setStatus(text) / showRetry(message) / closeSuccess()

local TEXT = {
    title = "番茄扫码登录",
    instruction = "请用手机番茄小说 App 扫描二维码登录。\n登录凭证只保存在本机，不会上传到任何第三方服务器。",
    waiting = "正在获取二维码……",
    cancel = "取消",
    retry = "重新获取",
    placeholder_pending = "二维码生成中……",
    placeholder_failed = "二维码未能生成",
}

local QRLoginView = InputContainer:extend{
    covers_fullscreen = true,
    modal = false,
}

function QRLoginView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { "Back" }, { "Esc" } } end
    self._closing = false
    self.status = TEXT.waiting
    self.qr = nil
    self.qr_error = nil
    self:_build()
    -- 启动登录流程（网络全部经 AsyncProviderTask 子进程）
    FanqieAuth:startQrLogin(self)
end

function QRLoginView:_setStatus(text)
    self.status = tostring(text or "")
    if self.status_widget then
        self.status_widget:setText("当前状态：" .. self.status)
        UIManager:setDirty(self, "ui", self.dimen)
    end
end

function QRLoginView:_build()
    local width, height = self.dimen.w, self.dimen.h
    local header_h = math.max(54, math.floor(height * 0.075))
    local footer_h = math.max(62, math.floor(height * 0.085))
    local text_width = math.max(1, width - 28)

    local header = UI.header(width, header_h, {
        left_text = "‹ 返回",
        title = TEXT.title,
        on_left = function() self:onClose() end,
    })
    local instruction = TextBoxWidget:new{
        text = TEXT.instruction,
        width = text_width,
        face = Font:getFace("smallinfofont", 19),
        alignment = "center",
    }

    local center
    if self.qr then
        local qr_limit = math.min(width - 36, math.floor(height * 0.46))
        local module_size = math.max(1, math.floor(qr_limit / (self.qr.size + 8)))
        local qr_widget = QRCodeWidget:new{
            matrix = self.qr.modules,
            size = self.qr.size,
            module_size = module_size,
            quiet_zone = 4,
        }
        center = CenterContainer:new{ dimen = Geom:new{ w = width, h = qr_widget.dimen.h }, qr_widget }
    else
        -- [seam] leko-plus 修复：失败态不能再显示"二维码生成中……"。
        -- 扫码失败时本视图会停在占位文案上，用户看到的是"二维码界面不显示二维码"，
        -- 而真正的原因（如二维码内容超出编码器容量）只写在底部状态行，容易被忽略。
        local placeholder = TEXT.placeholder_pending
        if self.qr_error then
            placeholder = TEXT.placeholder_failed .. "\n" .. tostring(self.qr_error)
        end
        center = CenterContainer:new{
            dimen = Geom:new{ w = width, h = math.floor(height * 0.40) },
            TextBoxWidget:new{
                text = placeholder,
                width = text_width,
                face = Font:getFace("smallinfofont", 19),
                alignment = "center",
            },
        }
    end

    self.status_widget = TextBoxWidget:new{
        text = "当前状态：" .. self.status,
        width = text_width,
        height = math.max(48, math.floor(height * 0.08)),
        face = Font:getFace("smallinfofont", 18),
        alignment = "center",
    }
    local body = VerticalGroup:new{
        instruction,
        UI.vspace(7),
        center,
        UI.vspace(7),
        self.status_widget,
    }
    local footer = UI.footer(width, footer_h, {
        { text = TEXT.retry, callback = function() self:_restart() end },
        { text = TEXT.cancel, bold = true, callback = function() self:onClose() end },
    })
    self[1] = UI.screen(width, height, header, body, footer, header_h, footer_h)
    UIManager:setDirty(self, "ui", self.dimen)
end

function QRLoginView:_restart()
    if self._closing then return end
    self.qr = nil
    self.qr_error = nil
    self.status = TEXT.waiting
    self:_build()
    FanqieAuth:startQrLogin(self)
end

-- ---------------------------------------------------------------------------
-- FanqieAuth 回调接口
-- ---------------------------------------------------------------------------

function QRLoginView:showQr(qr_url)
    if self._closing then return end
    local text = tostring(qr_url or "")
    if text == "" then
        self:showRetry("无法生成二维码：\n服务端未返回二维码地址")
        return
    end
    local qr, qr_err = QRCode:encode(text)
    if not qr then
        self:showRetry("无法生成二维码：\n" .. tostring(qr_err or "地址无效"))
        return
    end
    self.qr = qr
    self.qr_error = nil
    self.status = "等待手机扫码……"
    self:_build()
end

function QRLoginView:setStatus(text)
    if self._closing then return end
    self:_setStatus(text)
end

-- 移植 fanqie/qrlogin.lua:522-552 show_retry 的交互（重试/取消）。
function QRLoginView:showRetry(message)
    if self._closing then return end
    FanqieAuth:cancelQrLogin()
    self.qr = nil
    self.qr_error = tostring(message or "登录失败")
    self:_setStatus(self.qr_error)
    self.status = self.qr_error
    self:_build()
end

function QRLoginView:closeSuccess()
    if self._closing then return end
    UIManager:show(InfoMessage:new{ text = "番茄登录成功" })
    self:onClose()
    if type(self.on_login_success) == "function" then
        pcall(self.on_login_success)
    end
end

function QRLoginView:onClose()
    if self._closing then return true end
    self._closing = true
    FanqieAuth:cancelQrLogin()
    UIManager:close(self, "full")
    if type(self.on_close) == "function" then pcall(self.on_close) end
    return true
end

function QRLoginView:onShow()
    return true
end

return QRLoginView
