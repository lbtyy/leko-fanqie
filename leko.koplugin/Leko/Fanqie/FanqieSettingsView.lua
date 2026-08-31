local Device = require("device")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
-- [seam] leko-plus 修复：KOReader 的 Geom 位于 ui/geometry，不是 ui/widget/geometry。
-- 错误路径会让本模块 require 直接抛错，而主菜单入口（MainMenuView fanqie_settings）
-- 用 pcall 包住了调用，于是"点了番茄账号设置没有任何反应"。
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Notification = require("ui/widget/notification")
local Screen = Device.screen

local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")
local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
local FanqieAuth = require("Leko/Fanqie/FanqieAuth")
local ProviderRegistry = require("Leko/providers/ProviderRegistry")
local QRLoginView = require("Leko/Fanqie/QRLoginView")
local ProgressSync = require("Leko/Fanqie/ProgressSync")

-- Leko/Fanqie/FanqieSettingsView.lua
--
-- 设置页"番茄账号"分区（PRD §3.1 + 设计文档 T09）。
-- 包含两态：未开启态（仅显示说明 + 开启按钮）、开启后完整功能。
-- 外部 I-1 修复（BookInfoView 详情两行状态）与 I-2 修复（ProgressSync
-- 读取 config.sync 开关）由本设置页触发 + 在 ProgressSync 模块同步修改。
--
-- 合规姿态：聚合源（fanqie:dahuilang / fanqie:qingtian）服务器地址仅
-- 来自 config.lua，GUI 不预填；本页面仅展示开关 + 提示文案。

local TEXT = {
    title = "番茄账号",
    section_account = "账号",
    section_sources = "内容源",
    section_sync = "云端进度同步",
    toggle_on = "开启番茄源",
    toggle_off = "关闭番茄源",
    account_login = "扫码登录",
    account_logout = "退出登录",
    account_status_logged_in = "已登录：%s",
    account_status_idle = "未登录",
    account_status_expire = "登录态临期（>50 天），建议重新扫码",
    source_status_enabled = "可用",
    source_status_unconfigured = "需配置（编辑 config.lua 中的 dahuilang.server_url / qingtian.server_url）",
    source_status_disabled = "已禁用",
    sync_label_pull = "打开书时拉取云端进度",
    sync_label_upload = "翻页保存时上传",
    sync_label_flush = "退出阅读时强制上传",
    reload = "重载配置文件",
    reloaded = "config.lua 已重载",
    compliance_message_unconfirmed = "开启前请阅读并同意免责声明",
    disclaimer_link = "查看免责声明",
    enabled_state = "番茄源已开启",
    disabled_state = "番茄源已关闭",
    close = "关闭",
}

-- 复用的"区域头部"小 widget
local function buildSection(title, hint)
    local children = {
        TextBoxWidget:new{
            text = title,
            face = Font:getFace("tfont", 22),
            bold = true,
            width = 0,
            alignment = "left",
        },
    }
    if hint then
        children[#children + 1] = TextBoxWidget:new{
            text = hint,
            face = Font:getFace("smallinfofont", 14),
            width = 0,
            alignment = "left",
        }
    end
    children[#children + 1] = VerticalSpan:new{ width = 0, height = 6 }
    return VerticalGroup:new{ unpack(children) }
end

-- 通用"行"——左侧文字、右侧按钮/开关
local function row(width, left_widget, right_widget)
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.7), h = 36 },
            left_widget,
        },
        RightContainer:new{
            dimen = Geom:new{ w = math.floor(width * 0.3), h = 36 },
            right_widget,
        },
    }
end

local function button(text, callback, accent)
    local btn = Button:new{
        text = text,
        margin_h = 4,
        margin_v = 2,
        callback = callback,
    }
    return btn
end

-- 重建 dialog
local function rebuild(dialog_ref, build_body)
    if dialog_ref._settings_body then return end
    dialog_ref._settings_body = true
    build_body()
    dialog_ref._settings_body = nil
end

local function showMessage(text, is_warning)
    if is_warning then
        UIManager:show(Notification:new{ text = text })
    else
        UIManager:show(Notification:new{ text = text })
    end
end

-- ---------------------------------------------------------------------------
-- 设置页本体
-- ---------------------------------------------------------------------------
-- [seam] leko-plus 修复：原实现把面板直接当作顶层 widget 显示，结果
--   1. 面板固定在屏幕左上角（函数名 centeredDialog，实际并未居中）；
--   2. 没有任何关闭入口（无返回按钮、无 Back/Esc 键处理），用户进去后出不来。
-- 改为与 QRLoginView / MobileSourceImportView 同构的全屏 InputContainer：
-- 面板居中、Back/Esc 可关、整屏重绘不会与下层菜单互相残影。
local SettingsDialog = InputContainer:extend{
    covers_fullscreen = true,
    modal = false,
}

function SettingsDialog:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { "Back" }, { "Esc" } } end
    self._closing = false
    self.panel_w = math.min(math.floor(self.dimen.w * 0.94), 760)
    self.panel_h = math.floor(self.dimen.h * 0.85)
    self.padding = 16
    self.inner_w = self.panel_w - self.padding * 2
    self:_build()
end

function SettingsDialog:onClose()
    if self._closing then return true end
    self._closing = true
    UIManager:close(self, "full")
    return true
end

function SettingsDialog:_sourceStatus(provider_id)
    local ok, provider = pcall(function() return ProviderRegistry:get(provider_id) end)
    if not ok or not provider then
        return TEXT.source_status_disabled, "disabled"
    end
    local enabled = false
    if type(provider.isEnabled) == "function" then
        local ok2, value = pcall(provider.isEnabled, provider)
        enabled = ok2 and value == true
    end
    if enabled then
        return TEXT.source_status_enabled, "enabled"
    end
    return TEXT.source_status_unconfigured, "unconfigured"
end

function SettingsDialog:_providerName(provider_id)
    local ok, provider = pcall(function() return ProviderRegistry:get(provider_id) end)
    if not ok or not provider then return provider_id end
    return provider.name or provider_id
end

function SettingsDialog:_accountStatus()
    if not FanqieAuth:isLoggedIn() then return TEXT.account_status_idle end
    local nickname = ""
    local ok, account = pcall(function() return FanqieAuth:getAccount() end)
    if ok and type(account) == "table" then nickname = tostring(account.nickname or "") end
    if FanqieAuth:isExpiringSoon() then
        return TEXT.account_status_expire
    end
    return string.format(TEXT.account_status_logged_in, nickname ~= "" and nickname or "已登录")
end

-- ---------------------------------------------------------------------------
-- 私有组件：sync 配置写入（I-2 修复由 ProgressSync 读取 FanqieConfig）
-- ---------------------------------------------------------------------------

local function writeSync(section_key, value)
    local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
    local ok, err = FanqieConfig:setGuiOverride("sync", section_key, value)
    return ok, err
end

local function syncEnabled(section_key)
    local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
    local cur = FanqieConfig:get("sync", section_key)
    if cur == nil then
        local defaults = { pull_on_open = true, upload_on_close = true }
        return defaults[section_key] == true
    end
    return cur == true
end

-- 切换：写 GUI override（I-2 fanqie.progress_sync 读取该字段）
local function toggleSync(section_key, on_change)
    local new_value = not syncEnabled(section_key)
    local ok = writeSync(section_key, new_value)
    if ok then
        if on_change then on_change(new_value) end
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 主体入口
-- ---------------------------------------------------------------------------

--- 重建设置页全部内容（合规状态/登录态/同步开关变化后调用）。
function SettingsDialog:_build()
    if self._closing then return end
    local inner_w = self.inner_w
    local inner_children = {}

    -- 顶部标题 + 关闭
    inner_children[#inner_children + 1] = row(inner_w,
        TextBoxWidget:new{
            text = TEXT.title,
            face = Font:getFace("tfont", 28),
            bold = true,
            width = math.floor(inner_w * 0.7),
            alignment = "left",
        },
        button(TEXT.close, function() self:onClose() end))
    inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 12 }

    if not FanqieCompliance:isEnabled() then
        -- 未开启态
        inner_children[#inner_children + 1] = TextBoxWidget:new{
            text = TEXT.disabled_state .. "\n" .. TEXT.compliance_message_unconfirmed,
            face = Font:getFace("cfont", 18),
            width = inner_w,
            alignment = "left",
        }
        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 16 }
        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{ text = TEXT.disclaimer_link,
                face = Font:getFace("cfont", 16), width = math.floor(inner_w * 0.7) },
            button(TEXT.toggle_on, function()
                FanqieCompliance:requireConfirmation({
                    on_confirmed = function()
                        showMessage(TEXT.enabled_state)
                        self:_build()
                    end,
                    on_cancelled = function() end,
                })
            end))
    else
        -- 开启后：完整功能
        inner_children[#inner_children + 1] = buildSection(TEXT.section_account,
            "扫码登录仅官方源使用；聚合源请通过 config.lua 配置")

        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{
                text = self:_accountStatus(),
                face = Font:getFace("cfont", 16),
                width = math.floor(inner_w * 0.7),
            },
            button(FanqieAuth:isLoggedIn() and TEXT.account_logout or TEXT.account_login,
                function()
                    if FanqieAuth:isLoggedIn() then
                        FanqieAuth:logout()
                        self:_build()
                        return
                    end
                    -- 弹出扫码登录页（已存在的 QRLoginView 实例）
                    local qr = QRLoginView:new{
                        on_login_success = function()
                            self:_build()
                        end,
                    }
                    UIManager:show(qr, "full")
                end))

        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 18 }
        inner_children[#inner_children + 1] = buildSection(TEXT.section_sources, nil)

        -- 三源状态卡
        local sources = {
            { id = "fanqie:official", name = "番茄·官方" },
            { id = "fanqie:dahuilang", name = "番茄·大灰狼" },
            { id = "fanqie:qingtian", name = "番茄·晴天" },
        }
        for _, source in ipairs(sources) do
            local status_text = self:_sourceStatus(source.id)
            inner_children[#inner_children + 1] = row(inner_w,
                TextBoxWidget:new{
                    text = string.format("%s — %s", source.name, status_text),
                    face = Font:getFace("cfont", 16),
                    width = math.floor(inner_w * 0.7),
                },
                TextBoxWidget:new{
                    text = self:_providerName(source.id),
                    face = Font:getFace("smallinfofont", 14),
                    width = math.floor(inner_w * 0.3),
                    alignment = "right",
                })
            inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 6 }
        end

        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 18 }
        inner_children[#inner_children + 1] = buildSection(TEXT.section_sync, nil)

        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{
                text = TEXT.sync_label_pull,
                face = Font:getFace("cfont", 16),
                width = math.floor(inner_w * 0.7),
            },
            button(syncEnabled("pull_on_open") and "开" or "关",
                function()
                    toggleSync("pull_on_open", function() self:_build() end)
                end))
        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 6 }
        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{
                text = TEXT.sync_label_upload,
                face = Font:getFace("cfont", 16),
                width = math.floor(inner_w * 0.7),
            },
            button(syncEnabled("upload_on_close") and "开" or "关",
                function()
                    toggleSync("upload_on_close", function() self:_build() end)
                end))

        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 24 }
        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{
                text = TEXT.toggle_off,
                face = Font:getFace("cfont", 16),
                width = math.floor(inner_w * 0.7),
            },
            button(TEXT.toggle_off, function()
                FanqieCompliance:revoke()
                self:_build()
            end))
        inner_children[#inner_children + 1] = VerticalSpan:new{ width = 0, height = 24 }
        inner_children[#inner_children + 1] = row(inner_w,
            TextBoxWidget:new{
                text = TEXT.reload,
                face = Font:getFace("cfont", 14),
                width = math.floor(inner_w * 0.7),
            },
            button(TEXT.reload, function()
                local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
                local ok = pcall(function() FanqieConfig:reload() end)
                showMessage(ok and TEXT.reloaded or "重载失败")
            end))
    end

    local panel = FrameContainer:new{
        width = self.panel_w,
        height = self.panel_h,
        padding = self.padding,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ unpack(inner_children) },
    }
    self[1] = CenterContainer:new{ dimen = self.dimen:copy(), panel }
    UIManager:setDirty(self, "full")
end

local FanqieSettingsView = {}

--- 打开番茄账号设置页（MainMenuView fanqie_settings 入口）。
-- @return table 已显示的设置页 widget
function FanqieSettingsView:show()
    local dialog = SettingsDialog:new{}
    UIManager:show(dialog, "full")
    return dialog
end

return FanqieSettingsView
