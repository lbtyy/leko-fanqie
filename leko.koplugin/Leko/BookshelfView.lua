local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local BookService = require("Leko/BookService")
local Storage = require("Leko/Storage")
local UI = require("Leko/UI")

local BookRow = InputContainer:extend{}

function BookRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self[1] = self.content
    self.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldBook = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function BookRow:onTapBook()
    if self.on_open then self.on_open(self.summary) end
    return true
end

function BookRow:onHoldBook()
    if self.on_details then self.on_details(self.summary) end
    return true
end

local BookshelfView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
    page_size = 4,
}

function BookshelfView:init()
    self.page = self.page or 1
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { "Back" }, { "Esc" } }
        self.key_events.OpenMenu = { { "Menu" } }
    end
    self:refresh()
end

function BookshelfView:setUpdateState(state, text, current, total)
    self.update_state = state
    self.update_text = text
    self.update_current = tonumber(current or 0) or 0
    self.update_total = tonumber(total or 0) or 0
    self:rebuild()
end

function BookshelfView:_updateButton()
    local running = self.update_state == "started" or self.update_state == "running"
        or self.update_state == "paused"
    if running then
        local current = math.max(0, self.update_current or 0)
        local total = math.max(current, self.update_total or 0)
        return "检查中 " .. tostring(current) .. "/" .. tostring(total), function()
            return self:onCancelUpdates()
        end
    end
    return "检查更新", function() return self:onCheckUpdates() end
end

function BookshelfView:getMetrics()
    local header_h = math.max(54, math.floor(self.dimen.h * 0.075))
    local footer_h = math.max(54, math.floor(self.dimen.h * 0.072))
    local body_h = self.dimen.h - header_h - footer_h
    local row_h = math.floor(body_h / self.page_size)
    return header_h, footer_h, body_h, row_h
end

function BookshelfView:buildCover(summary, width, height)
    local cover_path = BookService:getValidCoverPath(summary)
    if cover_path then
        return FrameContainer:new{
            width = width,
            height = height,
            bordersize = 1,
            padding = 2,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - 6, h = height - 6 },
                ImageWidget:new{
                    file = cover_path,
                    width = width - 8,
                    height = height - 8,
                    scale_factor = 0,
                    file_do_cache = false,
                },
            },
        }
    end
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = 1,
        padding = 2,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width - 6, h = height - 6 },
            TextBoxWidget:new{
                text = "无封面",
                width = width - 12,
                alignment = "center",
                face = Font:getFace("smallinfofont", 16),
            },
        },
    }
end

function BookshelfView:buildBookRow(summary, row_h)
    local width = self.dimen.w
    local margin = math.max(10, math.floor(width * 0.02))
    local cover_h = math.max(72, row_h - 12)
    local cover_w = math.floor(cover_h * 0.70)
    local info_w = width - cover_w - margin * 3
    local position = summary.position or { chapter = 1 }
    local update_count = tonumber(summary.toc_update_count or 0) or 0
    local update_notice = update_count > 0 and ("\n更新 " .. tostring(update_count) .. " 章")
        or (summary.toc_check_status == "failed" and "\n目录检查失败" or "")
    local progress = string.format("第 %d / %d 章", position.chapter or 1, summary.chapter_count or 0)
    local author = (summary.author and summary.author ~= "") and summary.author or "佚名"
    -- [seam] leko-plus：番茄书角标"〔番〕"（P1-4）。
    local title_text = summary.title or "未命名"
    if summary.provider then title_text = "〔番〕" .. title_text end
    local info = VerticalGroup:new{
        TextBoxWidget:new{
            text = title_text,
            width = info_w,
            face = Font:getFace("cfont", 24),
            bold = true,
            alignment = "left",
        },
        UI.vspace(5),
        TextBoxWidget:new{
            text = author .. "\n" .. progress .. "\n轻点阅读 · 长按详情",
            width = info_w,
            face = Font:getFace("smallinfofont", 17),
            alignment = "left",
        },
    }
    if update_notice ~= "" then
        table.insert(info, TextBoxWidget:new{
            text = update_notice,
            width = info_w,
            face = Font:getFace("smallinfofont", 18),
            alignment = "left",
        })
    end
    local content = FrameContainer:new{
        width = width,
        height = row_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = margin },
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = row_h },
                self:buildCover(summary, cover_w, cover_h),
            },
            HorizontalSpan:new{ width = margin },
            LeftContainer:new{ dimen = Geom:new{ w = info_w, h = row_h }, info },
        },
    }
    return BookRow:new{
        width = width,
        height = row_h,
        summary = summary,
        content = content,
        on_open = function(item)
            if self.onOpenBook then self.onOpenBook(item.id, self) end
        end,
        on_details = function(item)
            if self.onShowBookInfo then self.onShowBookInfo(item.id, self) end
        end,
    }
end

function BookshelfView:rebuild(no_repaint)
    local header_h, footer_h, body_h, row_h = self:getMetrics()
    local width = self.dimen.w
    local total_pages = math.max(1, math.ceil(#self.books / self.page_size))
    if self.page > total_pages then self.page = total_pages end

    local header = UI.header(width, header_h, {
        left_text = "‹ 退出",
        title = "Leko 书架",
        right_text = "≡ 菜单",
        on_left = function() self:onClose() end,
        on_right = function()
            if self.onOpenMainMenu then self.onOpenMainMenu(self) end
        end,
    })

    local rows = VerticalGroup:new{}
    if #self.books == 0 then
        table.insert(rows, CenterContainer:new{
            dimen = Geom:new{ w = width, h = body_h },
            TextBoxWidget:new{
                text = "书架为空\n\n点击右上角“菜单”，搜索或导入书籍。",
                width = math.floor(width * 0.75),
                face = Font:getFace("cfont", 24),
                alignment = "center",
            },
        })
    else
        local start_index = (self.page - 1) * self.page_size + 1
        for slot = 1, self.page_size do
            local summary = self.books[start_index + slot - 1]
            if summary then
                table.insert(rows, self:buildBookRow(summary, row_h))
            else
                table.insert(rows, FrameContainer:new{
                    width = width,
                    height = row_h,
                    bordersize = 0,
                    padding = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    UI.vspace(row_h),
                })
            end
        end
    end

    local update_text, update_callback = self:_updateButton()
    local footer = UI.footer(width, footer_h, {
        {
            text = "‹ 上一页",
            enabled = self.page > 1,
            callback = function()
                self.page = math.max(1, self.page - 1)
                self:rebuild()
            end,
        },
        { text = update_text, callback = update_callback, bold = self.update_state == "running" },
        { text = string.format("%d / %d", self.page, total_pages), bold = true },
        {
            text = "下一页 ›",
            enabled = self.page < total_pages,
            callback = function()
                self.page = math.min(total_pages, self.page + 1)
                self:rebuild()
            end,
        },
    })

    self[1] = UI.screen(width, self.dimen.h, header, rows, footer, header_h, footer_h)
    if not no_repaint then UIManager:setDirty(self, "ui", self.dimen) end
end

function BookshelfView:onCheckUpdates()
    if self.onCheckUpdatesRequested then return self.onCheckUpdatesRequested(self) end
    return true
end

function BookshelfView:onCancelUpdates()
    if self.onCancelUpdatesRequested then return self.onCancelUpdatesRequested(self) end
    return true
end

function BookshelfView:refresh(no_repaint)
    self.books = Storage:listBooks()
    self:rebuild(no_repaint)
end


function BookshelfView:updateBook(book, no_repaint, change)
    if not book or not book.id then return self:refresh(no_repaint) end
    if change and change.cover_changed then BookService:invalidateCoverPath(book.cover_path) end
    local summary = Storage:makeBookSummary(book)
    local found = false
    for index, item in ipairs(self.books or {}) do
        if tostring(item.id) == tostring(book.id) then
            self.books[index] = summary
            found = true
            break
        end
    end
    if not found and Storage:isInLibrary(book.id) then
        table.insert(self.books, summary)
    end
    table.sort(self.books, function(a, b)
        local a_time = tonumber(a.last_read_at or a.updated_at or 0) or 0
        local b_time = tonumber(b.last_read_at or b.updated_at or 0) or 0
        if a_time == b_time then return tostring(a.title) < tostring(b.title) end
        return a_time > b_time
    end)
    self:rebuild(no_repaint)
end

function BookshelfView:onOpenMenu()
    if self.onOpenMainMenu then self.onOpenMainMenu(self) end
    return true
end

function BookshelfView:onClose()
    UIManager:close(self, "full")
    return true
end

return BookshelfView
