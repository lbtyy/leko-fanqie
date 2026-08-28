local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UI = require("Leko/UI")

local Screen = Device.screen

local TaskProgress = InputContainer:extend{
    modal = true,
    dismissable = false,
    stop_events_propagation = true,
    current = 0,
    total = 1,
}

function TaskProgress:init()
    if self.cancel_callback and Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { "Back" }, { "Esc" } }
    end
    self.total = math.max(1, tonumber(self.total) or 1)
    self.current = math.max(0, math.min(self.total, tonumber(self.current) or 0))
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local width = math.max(Screen:scaleBySize(260), Screen:getWidth() - Screen:scaleBySize(70))
    local inner_width = width - Screen:scaleBySize(36)

    self.title_widget = TextWidget:new{
        text = tostring(self.title or "正在处理"),
        face = Font:getFace("ffont", 24),
        bold = true,
        max_width = inner_width,
    }
    self.stage_widget = TextWidget:new{
        text = tostring(self.stage or "准备中……"),
        face = Font:getFace("smallffont", 19),
        max_width = inner_width,
    }
    self.count_widget = TextWidget:new{
        text = string.format("%d / %d", self.current, self.total),
        face = Font:getFace("smallinfofont", 17),
        max_width = inner_width,
    }
    self.stage_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = self.stage_widget:getSize().h },
        self.stage_widget,
    }
    self.count_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = self.count_widget:getSize().h },
        self.count_widget,
    }
    self.progress_bar = ProgressWidget:new{
        fillcolor = Blitbuffer.COLOR_BLACK,
        width = inner_width,
        height = Screen:scaleBySize(18),
        padding = Screen:scaleBySize(4),
        margin = 0,
        percentage = self.current / self.total,
    }

    local content = VerticalGroup:new{
        self.title_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        self.stage_row,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        self.progress_bar,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        self.count_row,
    }
    if self.cancel_callback then
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(content, UI.cell{
            text = tostring(self.cancel_text or "取消"),
            width = inner_width,
            height = Screen:scaleBySize(52),
            bold = true,
            font_size = 21,
            callback = function() self:cancel() end,
        })
    end
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 2,
        padding = Screen:scaleBySize(18),
        radius = Screen:scaleBySize(6),
        content,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        frame,
    }
end

function TaskProgress:show()
    UIManager:show(self, "ui")
    self:repaint()
    return self
end

function TaskProgress:repaint()
    UIManager:setDirty(self, "ui", self.dimen)
    UIManager:forceRePaint()
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
end

function TaskProgress:update(current, stage, total)
    if total then self.total = math.max(1, tonumber(total) or self.total) end
    self.current = math.max(0, math.min(self.total, tonumber(current) or self.current))
    if stage and stage ~= "" then
        self.stage = tostring(stage)
        self.stage_widget:setText(self.stage)
    end
    self.count_widget:setText(string.format("%d / %d", self.current, self.total))
    self.progress_bar:setPercentage(self.current / self.total)
    self:repaint()
    return self
end

function TaskProgress:close()
    if self._closing then return end
    self._closing = true
    -- Successful completion must not run the cancellation callback.
    self.cancel_callback = nil
    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self, "ui")
    end
end

function TaskProgress:cancel()
    if self._closing or self._cancelled then return true end
    self._cancelled = true
    local callback = self.cancel_callback
    self.cancel_callback = nil
    if callback then
        local ok, allow_close = pcall(callback)
        -- A transactional task may enter a short commit section where killing
        -- its child could corrupt state. Returning false keeps this dialog alive
        -- and restores the Cancel callback instead of pretending cancellation
        -- succeeded. Existing callbacks return nil and retain the old behavior.
        if ok and allow_close == false then
            self._cancelled = false
            self.cancel_callback = callback
            return true
        end
    end
    self._closing = true
    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self, "ui")
    end
    return true
end

function TaskProgress:onClose()
    return self:cancel()
end

function TaskProgress:onTapClose()
    return true
end

return TaskProgress
