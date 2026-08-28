local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Storage = require("Leko/Storage")

local App = {
    bookshelf = nil,
    reader = nil,
    reading_coordinator = nil,
}

local function tocUpdater()
    local ok, updater = pcall(require, "Leko/AsyncTocUpdate")
    return ok and updater or nil
end

function App:_ensureReadingCoordinator()
    if self.reading_coordinator then return self.reading_coordinator end
    -- Keep plugin discovery and the file-manager menu independent from the
    -- reader/source stack.  ReadingCoordinator pulls BookService and the
    -- Legado/PCRE path, which is only needed after a book is opened.
    local ReadingCoordinator = require("Leko/ReadingCoordinator")
    self.reading_coordinator = ReadingCoordinator:new{
        create_reader = function(book, reader_options) return self:_createReader(book, reader_options) end,
        on_reader_created = function(reader) self.reader = reader end,
        on_toc_updated = function(book)
            self:refreshBookshelf(nil, book, { toc_changed = true })
        end,
    }
    return self.reading_coordinator
end

function App:init()
    Storage:init()
    Storage:seedDemoBook()
    Storage:cleanupTrials()
    Storage:releaseSourceSettings()
    -- [seam] leko-plus：注册内置 Native Provider（番茄等）。只加载模块，
    -- 不产生任何网络请求；合规门禁未确认时注册器查询仍会返回 nil（G6）。
    pcall(function() require("Leko/providers/ProviderRegistry"):warmup() end)
    -- [seam] leko-plus T11：旧 fanqie.koplugin 数据迁移（一次性后台调度）。
    -- 不阻塞主流程；失败仅记录日志。
    UIManager:scheduleIn(2, function()
        pcall(function() require("Leko/Fanqie/FanqieMigration"):run({}) end)
    end)
    -- [seam] leko-plus T05：进度同步重试；启动 5 秒后调度一次。
    UIManager:scheduleIn(5, function()
        pcall(function() require("Leko/Fanqie/ProgressSync"):start() end)
    end)
    -- Maintenance uses the same global process budget and is always preemptible.
    local AsyncMaintenance = require("Leko/AsyncMaintenance")
    UIManager:scheduleIn(90, function() AsyncMaintenance:start() end)
    return self
end

function App:refreshBookshelf(no_repaint, updated, change)
    if not self.bookshelf then return end
    if updated and change and change.cover_changed and self.bookshelf.updateBook then
        self.bookshelf:updateBook(updated, no_repaint, change)
    else
        self.bookshelf:refresh(no_repaint)
    end
end

function App:showBookshelf()
    if self.bookshelf and UIManager.isWidgetShown and UIManager:isWidgetShown(self.bookshelf) then
        self.bookshelf:refresh()
        return
    end
    local BookshelfView = require("Leko/BookshelfView")
    local shelf = BookshelfView:new{
        onOpenBook = function(book_id) return self:openBook(book_id) end,
        onOpenMainMenu = function() self:showMainMenu() end,
        onShowBookInfo = function(book_id) self:showBookInfo(book_id) end,
        onCheckUpdatesRequested = function(view) return self:startBookshelfUpdate(view, true) end,
        onCancelUpdatesRequested = function(view) return self:cancelBookshelfUpdate(view) end,
    }
    self.bookshelf = shelf
    UIManager:show(self.bookshelf, "full")
end

function App:startBookshelfUpdate(view, force)
    view = view or self.bookshelf
    if not view then return nil, "书架尚未打开" end
    local updater = tocUpdater()
    if not updater then return nil, "目录检查模块不可用" end
    return updater:start{
        force = force == true,
        on_state = function(state, text, current, total)
            if self.bookshelf == view and view.setUpdateState then
                view:setUpdateState(state, text, current, total)
            end
        end,
        on_book = function(updated)
            self:refreshBookshelf(nil, updated, { toc_changed = true })
        end,
        on_done = function()
            if self.bookshelf == view then view:refresh() end
        end,
    }
end

function App:cancelBookshelfUpdate(view)
    if view and view.setUpdateState then view:setUpdateState("cancelled", "已取消检查更新", 0, 0) end
    local updater = tocUpdater()
    return updater and updater:cancel() or false
end

function App:showMainMenu()
    local MainMenuView = require("Leko/MainMenuView")
    UIManager:show(MainMenuView:new{
        onReadBook = function(book, options) return self:openBookObject(book, options) end,
        onChanged = function() self:refreshBookshelf() end,
    }, "full")
end

function App:showBookInfo(book_id)
    local book, err = Storage:loadBook(book_id)
    if not book then
        UIManager:show(InfoMessage:new{ text = "无法读取书籍信息：\n" .. tostring(err) })
        return
    end
    return self:showBookInfoObject(book)
end

function App:showBookInfoObject(book, reader)
    local BookInfoView = require("Leko/BookInfoView")
    local info_view

    local function runNext(callback)
        if type(UIManager.nextTick) == "function" then
            UIManager:nextTick(callback)
        else
            UIManager:scheduleIn(0, callback)
        end
    end

    local function refreshReaderFooter()
        if not reader then return end
        if type(reader.refreshFooterFromCache) == "function" then
            reader:refreshFooterFromCache("full")
        elseif UIManager.setDirty then
            UIManager:setDirty(reader, "full")
        end
    end

    local function closeDetails()
        if not info_view then return end
        -- BookInfoView's close callback must not treat this handoff as a
        -- normal return: the active reader is already the destination.
        info_view._entering_reader = true
        if not UIManager.isWidgetShown or UIManager:isWidgetShown(info_view) then
            UIManager:close(info_view, "full")
        end
    end

    local function revealExistingReader(selected, read_options)
        if not reader then return nil, "阅读器状态不可用" end
        local chapter_index = tonumber(read_options and read_options.chapter_index)
        if chapter_index and reader.page and reader.page.chapter_index ~= chapter_index then
            reader:jumpToChapter(chapter_index)
        end
        runNext(function()
            closeDetails()
            refreshReaderFooter()
            if read_options and type(read_options.on_reader_shown) == "function" then
                pcall(read_options.on_reader_shown, reader, selected)
            end
        end)
        return true
    end

    local function returnToUpdatedReader(updated)
        if not reader then return end
        reader.book = updated
        reader.history = {}
        local target = updated.position or { chapter = 1, paragraph = 1, char = 1 }
        reader:loadPage(target, "full")
        runNext(function()
            closeDetails()
            refreshReaderFooter()
        end)
    end

    info_view = BookInfoView:new{
        book = book,
        onRead = function(selected, read_options)
            if reader then return revealExistingReader(selected, read_options) end
            return self:openBookObject(selected, read_options)
        end,
        onChapterSelected = function(selected, chapter_index)
            if reader then
                reader:jumpToChapter(chapter_index)
            else
                selected.position = { chapter = chapter_index, paragraph = 1, char = 1 }
                return self:openBookObject(selected, { chapter_index = chapter_index })
            end
        end,
        allow_delete = reader == nil,
        onBookAdded = function(added)
            if reader then
                reader.book = added
                reader:rebuild("ui")
            end
            self:refreshBookshelf()
        end,
        onBookUpdated = function(updated, change)
            if reader then
                if change and change.source_changed then
                    returnToUpdatedReader(updated)
                else
                    reader.book = updated
                    reader:rebuild("ui")
                end
            end
            self:refreshBookshelf(nil, updated, change)
        end,
        onBookRemoved = function(removed)
            if reader then
                reader.book = removed
                reader:rebuild("ui")
            end
            self:refreshBookshelf()
        end,
        onBookDeleted = function() self:refreshBookshelf() end,
        reader_active = reader ~= nil,
        onDetailsClosed = function()
            if reader then runNext(refreshReaderFooter) end
        end,
    }
    UIManager:show(info_view, "full")
    return info_view
end

function App:openBook(book_id)
    local book, err = Storage:loadBook(book_id)
    if not book then
        UIManager:show(InfoMessage:new{ text = "无法打开书籍：\n" .. tostring(err) })
        return
    end
    return self:openBookObject(book)
end

function App:_createReader(book, reader_options)
    local coordinator = self:_ensureReadingCoordinator()
    local ReaderView = require("Leko/ReaderView")
    reader_options = reader_options or {}
    return ReaderView:new{
        book = book,
        onPrepareChapter = function(reader, position, refresh_type, options)
            return coordinator:prepareChapter(reader, position, refresh_type, options)
        end,
        onRefreshToc = function(reader, options)
            return coordinator:refreshToc(reader, options)
        end,
        onBeforeReaderClose = function(closing_book)
            -- Reveal an explicit return route before doing shelf bookkeeping.
            if reader_options.return_view then return end
            if self.bookshelf and self.bookshelf.updateBook then
                self.bookshelf:updateBook(closing_book, true)
            else
                self:refreshBookshelf(true)
            end
        end,
        onReaderClosed = function()
            self.reader = nil
            coordinator.active_reader = nil
            local return_view = reader_options.return_view
            if return_view and (not UIManager.isWidgetShown or not UIManager:isWidgetShown(return_view)) then
                UIManager:show(return_view, "full")
                if UIManager.setDirty then UIManager:setDirty(return_view, "full") end
            end
            local function afterReturnPaint()
                if return_view and type(return_view.onReaderReturned) == "function" then
                    pcall(return_view.onReaderReturned, return_view)
                end
                if return_view and Storage:isInLibrary(book.id) then
                    UIManager:scheduleIn(0.35, function() self:refreshBookshelf(true) end)
                end
            end
            if type(UIManager.nextTick) == "function" then UIManager:nextTick(afterReturnPaint)
            else UIManager:scheduleIn(0, afterReturnPaint) end
        end,
        onBookAdded = function()
            self:refreshBookshelf()
        end,
        onShowBookInfo = function(selected, active_reader)
            self:showBookInfoObject(selected, active_reader)
        end,
    }
end

function App:openBookObject(book, options)
    options = options or {}
    local coordinator = self:_ensureReadingCoordinator()
    local task, err = coordinator:open(book, options)
    -- Callers that own a foreground handoff (BookInfoView/SearchView) render
    -- the returned error themselves.  Keep the direct App entry self-contained
    -- without showing a duplicate dialog before the caller can inspect it.
    if not task and err and type(options.on_failure) ~= "function" then
        UIManager:show(InfoMessage:new{ text = "无法开始阅读：\n" .. tostring(err) })
    end
    return task, err
end

return App
