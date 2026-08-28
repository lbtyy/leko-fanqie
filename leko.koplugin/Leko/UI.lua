local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local UI = {}

function UI.vspace(height)
    -- KOReader's VerticalSpan historically names its vertical extent `width`.
    return VerticalSpan:new{ width = math.max(0, math.floor(height or 0)) }
end

function UI.defer(owner, key, callback)
    owner = owner or UI
    key = tostring(key or "action")
    owner._leko_deferred = owner._leko_deferred or {}
    if owner._leko_deferred[key] then return true end
    owner._leko_deferred[key] = true
    UIManager:nextTick(function()
        owner._leko_deferred[key] = nil
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            logger.err("Leko deferred UI action failed", key, err)
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = "界面操作失败：\n" .. tostring(err) })
        end
    end)
    return true
end

local function showWidget(owner, key, factory, refresh_type, modal)
    return UI.defer(owner, key, function()
        local widget = type(factory) == "function" and factory() or factory
        if not widget then return end
        if modal then widget.modal = true end
        logger.info("Leko UI show", tostring(key), "modal", tostring(widget.modal),
            "owner_modal", tostring(owner and owner.modal))
        UIManager:show(widget, refresh_type)
        if UIManager.getTopmostVisibleWidget then
            local top = UIManager:getTopmostVisibleWidget()
            if top ~= widget then
                logger.warn("Leko widget was not topmost after show", tostring(key), tostring(top), tostring(widget))
            end
        end
    end)
end

function UI.showLater(owner, key, factory, refresh_type)
    return showWidget(owner, key, factory, refresh_type, false)
end

function UI.showModalLater(owner, key, factory, refresh_type)
    return showWidget(owner, key, factory, refresh_type, true)
end

local CellButton = InputContainer:extend{
    text = "",
    callback = nil,
    hold_callback = nil,
    enabled = true,
    align = "center",
    font = "smallinfofont",
    font_size = 20,
    bold = false,
    bordersize = 1,
    padding = 6,
}

function CellButton:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = math.max(1, self.width or 1), h = math.max(1, self.height or 1) }
    local inner_w = math.max(1, self.dimen.w - 2 * self.bordersize - 2 * self.padding)
    local inner_h = math.max(1, self.dimen.h - 2 * self.bordersize - 2 * self.padding)
    local text_widget
    if self.multiline then
        text_widget = TextBoxWidget:new{
            text = self.text or "",
            width = inner_w,
            height = inner_h,
            face = Font:getFace(self.font, self.font_size),
            bold = self.bold,
            alignment = self.align,
            alignment_strict = true,
            fgcolor = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        text_widget = TextWidget:new{
            text = self.text or "",
            face = Font:getFace(self.font, self.font_size),
            bold = self.bold,
            max_width = inner_w,
            fgcolor = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    local content
    if self.align == "left" then
        content = LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, text_widget }
    else
        content = CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, text_widget }
    end
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = self.bordersize,
        padding = self.padding,
        background = self.background or Blitbuffer.COLOR_WHITE,
        content,
    }
    self.ges_events = {
        TapCell = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if self.hold_callback then
        self.ges_events.HoldCell = { GestureRange:new{ ges = "hold", range = self.dimen } }
    end
end

function CellButton:onTapCell()
    if self.enabled and self.callback then self.callback() end
    return true
end

function CellButton:onHoldCell()
    if self.enabled and self.hold_callback then self.hold_callback() end
    return true
end

function UI.cell(options)
    return CellButton:new(options or {})
end

function UI.header(width, height, options)
    options = options or {}
    local left_w = options.left_width or math.floor(width * 0.22)
    local right_w = options.right_width or left_w
    local center_w = width - left_w - right_w
    return HorizontalGroup:new{
        UI.cell{
            text = options.left_text or "‹ 返回",
            width = left_w,
            height = height,
            callback = options.on_left,
            enabled = options.on_left ~= nil,
            font_size = options.font_size or 20,
        },
        UI.cell{
            text = options.title or "",
            width = center_w,
            height = height,
            callback = options.on_title,
            enabled = options.on_title ~= nil,
            bold = true,
            font = "cfont",
            font_size = options.title_size or 23,
        },
        UI.cell{
            text = options.right_text or "",
            width = right_w,
            height = height,
            callback = options.on_right,
            enabled = options.on_right ~= nil,
            font_size = options.font_size or 20,
        },
    }
end

function UI.footer(width, height, cells)
    local group = HorizontalGroup:new{}
    local used = 0
    for index, item in ipairs(cells or {}) do
        local cell_w = item.width
        if not cell_w then
            local remaining_count = #cells - index + 1
            cell_w = math.floor((width - used) / remaining_count)
        end
        if index == #cells then cell_w = width - used end
        used = used + cell_w
        table.insert(group, UI.cell{
            text = item.text or "",
            width = cell_w,
            height = height,
            callback = item.callback,
            hold_callback = item.hold_callback,
            enabled = item.enabled ~= false,
            bold = item.bold == true,
            font = item.font or "smallinfofont",
            font_size = item.font_size or 19,
            multiline = item.multiline,
        })
    end
    return group
end

function UI.screen(width, height, header, body, footer, header_h, footer_h)
    header_h = header and header_h or 0
    footer_h = footer and footer_h or 0
    local body_h = math.max(1, height - header_h - footer_h)
    local body_container = CenterContainer:new{
        dimen = Geom:new{ w = width, h = body_h },
        body,
    }
    local group = VerticalGroup:new{}
    if header then table.insert(group, header) end
    table.insert(group, body_container)
    if footer then table.insert(group, footer) end
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }, body_h
end

return UI
