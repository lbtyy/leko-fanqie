local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local TocView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
    -- Let the native Menu own pagination. A second, manually grouped window made
    -- a 120-chapter section look like an unexplained extra level of pagination.
    items_per_page = 12,
}

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function TocView:_buildItems(selected_chapter)
    local chapters = self.book.chapters or {}
    local total = #chapters
    local current = clamp(tonumber(self.current_chapter or 1) or 1, 1, math.max(1, total))
    self.current_chapter = current

    if total == 0 then
        self.title = tostring(self.book.title or "书籍") .. " · 目录为空"
        return { { text = "暂无章节", dim = true } }, 1
    end

    self.title = tostring(self.book.title or "书籍") .. " · 目录（共 " .. tostring(total) .. " 章）"
    local items = {
        {
            text = "按章节号跳转",
            mandatory = tostring(current) .. "/" .. tostring(total),
            action = "jump-chapter",
            separator = true,
        },
    }
    local selection = 1
    for index, chapter in ipairs(chapters) do
        items[#items + 1] = {
            text = tostring(chapter.title or ("第" .. tostring(index) .. " 章")),
            mandatory = chapter.downloaded and "●" or "○",
            bold = index == current,
            chapter_index = index,
        }
        if index == selected_chapter then selection = #items end
    end
    return items, selection
end

function TocView:_showChapter(chapter_index)
    local items, selection = self:_buildItems(chapter_index)
    self.item_table = items
    self:switchItemTable(self.title, items, selection)
end

function TocView:_promptJump()
    local total = #(self.book.chapters or {})
    if total == 0 then return true end

    local dialog
    dialog = InputDialog:new{
        modal = true,
        title = "跳转章节",
        input = tostring(self.current_chapter or 1),
        input_hint = "输入 1-" .. tostring(total),
        buttons = {
            {
                { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                { text = "跳转", callback = function()
                    local target = tonumber(dialog:getInputText())
                    if not target or target < 1 or target > total or target % 1 ~= 0 then
                        UIManager:show(Notification:new{ text = "请输入 1-" .. tostring(total) .. " 的章节号" })
                        return
                    end
                    UIManager:close(dialog)
                    self.current_chapter = target
                    self:_showChapter(target)
                end },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return true
end

function TocView:init()
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    -- book.lua/toc.lua intentionally do not get rewritten after every cached
    -- chapter. Rebind their display flags from the authoritative disk cache
    -- before the first directory paint.
    local service_ok, BookService = pcall(require, "Leko/BookService")
    if service_ok and type(BookService.refreshChapterDownloadStates) == "function" then
        pcall(BookService.refreshChapterDownloadStates, BookService, self.book)
    end
    local chapters = self.book.chapters or {}
    local current = clamp(tonumber(self.current_chapter or 1) or 1, 1, math.max(1, #chapters))
    self.current_chapter = current
    local items, selection = self:_buildItems(current)
    self.item_table = items
    self.onMenuSelect = function(menu, item)
        if item.action == "jump-chapter" then
            self:_promptJump()
            return
        end
        if not item.chapter_index then return end
        self.current_chapter = item.chapter_index
        UIManager:close(menu, "full")
        if self.onChapterSelected then self.onChapterSelected(item.chapter_index) end
    end
    self.close_callback = function()
        UIManager:close(self, "full")
        self:_notifyReturn()
    end
    Menu.init(self)
    self:switchItemTable(self.title, self.item_table, selection)
end

function TocView:onReturn()
    UIManager:close(self, "full")
    self:_notifyReturn()
    return true
end

function TocView:_notifyReturn()
    if self._return_notified then return end
    self._return_notified = true
    if type(self.on_return) == "function" then self.on_return() end
end

return TocView
