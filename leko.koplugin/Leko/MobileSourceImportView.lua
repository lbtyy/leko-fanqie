local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local AsyncSourceImport = require("Leko/AsyncSourceImport")
local MobileSourceImport = require("Leko/MobileSourceImport")
local QRCode = require("Leko/QRCode")
local QRCodeWidget = require("Leko/QRCodeWidget")
local TaskProgress = require("Leko/TaskProgress")
local UI = require("Leko/UI")

local MobileSourceImportView = InputContainer:extend{
    covers_fullscreen = true,
    modal = false,
}

function MobileSourceImportView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { "Back" }, { "Esc" } } end
    self._closing = false
    self._shutdown_done = false
    self._submission_started = false
    self._import_worker = nil
    self._import_progress = nil
    self._temp_path = nil
    self.status = "等待手机连接"
end

function MobileSourceImportView:_setStatus(text)
    self.status = tostring(text or "")
    if self.status_widget then
        self.status_widget:setText("当前状态：" .. self.status)
        UIManager:setDirty(self, "ui", self.dimen)
    end
end

function MobileSourceImportView:_build()
    local width, height = self.dimen.w, self.dimen.h
    local header_h = math.max(54, math.floor(height * 0.075))
    local footer_h = math.max(62, math.floor(height * 0.085))
    local text_width = math.max(1, width - 28)
    local qr_limit = math.min(width - 36, math.floor(height * 0.49))
    local module_size = math.max(1, math.floor(qr_limit / (self.qr.size + 8)))
    local qr = QRCodeWidget:new{
        matrix = self.qr.modules,
        size = self.qr.size,
        module_size = module_size,
        quiet_zone = 4,
    }

    local header = UI.header(width, header_h, {
        left_text = "‹ 返回",
        title = "用手机导入书源",
        on_left = function() self:onClose() end,
    })
    local instruction = TextBoxWidget:new{
        text = "请让手机和 Kindle 连接同一个 Wi-Fi，然后扫描二维码。",
        width = text_width,
        face = Font:getFace("smallinfofont", 19),
        alignment = "center",
    }
    local address = TextBoxWidget:new{
        text = "备用地址：\n" .. tostring(self.url or ""),
        width = text_width,
        height = math.max(48, math.floor(height * 0.075)),
        face = Font:getFace("smallinfofont", 16),
        alignment = "center",
    }
    self.status_widget = TextBoxWidget:new{
        text = "当前状态：" .. self.status,
        width = text_width,
        height = math.max(44, math.floor(height * 0.07)),
        face = Font:getFace("smallinfofont", 18),
        alignment = "center",
    }
    local body = VerticalGroup:new{
        instruction,
        UI.vspace(7),
        CenterContainer:new{ dimen = Geom:new{ w = width, h = qr.dimen.h }, qr },
        UI.vspace(7),
        address,
        UI.vspace(4),
        self.status_widget,
    }
    local footer = UI.footer(width, footer_h, {
        { text = "取消", bold = true, callback = function() self:onClose() end },
    })
    self[1] = UI.screen(width, height, header, body, footer, header_h, footer_h)
    UIManager:setDirty(self, "ui", self.dimen)
end

function MobileSourceImportView:_onSessionClosed(reason)
    if self._closing or self._submission_started then return end
    if reason == "timeout" then
        self:_setStatus("等待时间已到，请重新打开“用手机导入”。\n手机无法连接时，可以返回并使用“从文件导入”。")
    elseif reason == "network" or reason == "suspend" then
        self:_setStatus("网络连接已断开，请返回后重新打开“用手机导入”。\n手机无法连接时，可以返回并使用“从文件导入”。")
    else
        self:_setStatus("暂时无法等待手机连接，请稍后重试。\n手机无法连接时，可以返回并使用“从文件导入”。")
    end
end

function MobileSourceImportView:_acceptSubmission(spec, import_session)
    if self._closing or self._submission_started then return false end
    self._submission_started = true
    self._temp_path = spec.path
    self:_setStatus("已收到，正在导入")
    local worker
    local progress
    progress = TaskProgress:new{
        title = "导入书源",
        total = 5,
        current = 0,
        stage = "准备后台导入……",
        cancel_text = "取消导入",
        cancel_callback = function()
            if not worker then return true end
            local cancelled = AsyncSourceImport:cancel(worker)
            if cancelled == false then
                progress:update(4, "正在安全提交书源，当前阶段不能中断", 5)
                return false
            end
            if self._import_worker == worker then self._import_worker = nil end
            if self._import_progress == progress then self._import_progress = nil end
            if self._temp_path then
                MobileSourceImport:removeTempFile(self._temp_path)
                self._temp_path = nil
            end
            self._submission_started = false
            local can_continue = MobileSourceImport:allowNextSubmission(import_session)
            if not self._closing then
                self:_setStatus(can_continue
                    and "导入已取消，手机页面可以继续发送。"
                    or "导入已取消，请返回后重新打开“用手机导入”。")
            end
            return true
        end,
    }
    self._import_progress = progress
    progress:show()

    local start_err
    worker, start_err = AsyncSourceImport:start({
        kind = spec.kind,
        path = spec.path,
        url = spec.url,
        mobile = true,
        on_state = function(_, text, current, total)
            if text and self._import_progress == progress and not progress._closing then
                progress:update(current or progress.current, text, total or progress.total)
            end
        end,
    }, function(ok, err, completed_worker, payload)
        if self._import_worker == completed_worker then self._import_worker = nil end
        if self._import_progress == progress then self._import_progress = nil end
        progress:close()
        if self._temp_path then
            MobileSourceImport:removeTempFile(self._temp_path)
            self._temp_path = nil
        end
        if self._closing then return end
        if not ok then
            self._submission_started = false
            local can_continue = MobileSourceImport:allowNextSubmission(import_session)
            self:_setStatus(can_continue
                and "导入失败，请检查内容后在手机页面重新发送。"
                or "导入失败，请检查书源内容或网址后重试。")
            return
        end
        local stats = payload and payload.stats or {}
        self._submission_started = false
        local can_continue = MobileSourceImport:allowNextSubmission(import_session)
        self:_setStatus(string.format("导入完成：%d 个 · 可使用 %d · 暂不支持 %d%s",
            tonumber(stats.total or 0) or 0,
            tonumber(stats.supported or 0) or 0,
            tonumber(stats.unsupported or 0) or 0,
            can_continue and "\n手机页面可以继续发送" or ""))
        if self.on_changed then pcall(self.on_changed, payload) end
    end)
    if not worker then
        if self._import_progress == progress then self._import_progress = nil end
        progress:close()
        if self._temp_path then MobileSourceImport:removeTempFile(self._temp_path); self._temp_path = nil end
        self._submission_started = false
        self:_setStatus("导入失败，请检查书源内容或网址后重试。")
        return false
    end
    self._import_worker = worker
    return true
end

function MobileSourceImportView:startSession()
    local session, err = MobileSourceImport:start{
        on_client = function() self:_setStatus("手机已连接，正在接收") end,
        on_submit = function(spec, import_session) return self:_acceptSubmission(spec, import_session) end,
        on_closed = function(reason) self:_onSessionClosed(reason) end,
    }
    if not session then return nil, err end
    self.session = session
    self.url = session.url
    local qr, qr_err = QRCode:encode(session.url)
    if not qr then
        MobileSourceImport:stop(session, "qr-error", false)
        return nil, qr_err or "无法生成二维码"
    end
    self.qr = qr
    self:_build()
    return true
end

function MobileSourceImportView.open(options)
    local view = MobileSourceImportView:new(options or {})
    local ok, err = view:startSession()
    if not ok then return nil, err end
    UIManager:show(view, "full")
    return view
end

function MobileSourceImportView:_shutdown()
    if self._shutdown_done then return end
    self._shutdown_done = true
    self._closing = true
    if self.session then MobileSourceImport:stop(self.session, "closed", false) end
    if self._import_worker then
        local cancelled = AsyncSourceImport:cancel(self._import_worker)
        if cancelled ~= false and self._temp_path then
            MobileSourceImport:removeTempFile(self._temp_path)
            self._temp_path = nil
        end
    elseif self._temp_path then
        MobileSourceImport:removeTempFile(self._temp_path)
        self._temp_path = nil
    end
    if self._import_progress then
        local progress = self._import_progress
        self._import_progress = nil
        progress:close()
    end
end

function MobileSourceImportView:onClose()
    self:_shutdown()
    UIManager:close(self, "full")
    return true
end

function MobileSourceImportView:onCloseWidget()
    self:_shutdown()
end

return MobileSourceImportView
