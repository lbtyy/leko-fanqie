local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local BookService = require("Leko/BookService")
local ForegroundBookTask = require("Leko/ForegroundBookTask")
local Storage = require("Leko/Storage")

local ReadingCoordinator = {}
ReadingCoordinator.__index = ReadingCoordinator

local function runAfterPaint(callback)
    if type(UIManager.tickAfterNext) == "function" then
        UIManager:tickAfterNext(callback)
    elseif type(UIManager.nextTick) == "function" then
        UIManager:nextTick(callback)
    else
        UIManager:scheduleIn(0, callback)
    end
end

local function closeIfShown(widget, refresh_mode)
    if not widget then return end
    if not UIManager.isWidgetShown or UIManager:isWidgetShown(widget) then
        UIManager:close(widget, refresh_mode or "ui")
    end
end

local function clampChapter(book, requested)
    local count = #(book and book.chapters or {})
    if count < 1 then return nil, "章节目录为空" end
    local index = tonumber(requested or (book.position and book.position.chapter) or 1) or 1
    index = math.max(1, math.min(count, index))
    return index
end

function ReadingCoordinator:new(options)
    options = options or {}
    local instance = setmetatable({
        create_reader = options.create_reader,
        on_reader_created = options.on_reader_created,
        on_reader_shown = options.on_reader_shown,
        on_toc_updated = options.on_toc_updated,
        active_reader = nil,
    }, self)
    instance.task = ForegroundBookTask:new{}
    return instance
end

function ReadingCoordinator:isBusy()
    return self.task:isBusy()
end

function ReadingCoordinator:cancel(reason)
    return self.task:cancel(reason or "cancelled")
end

function ReadingCoordinator:_showError(title, err, callback)
    if type(callback) == "function" then
        pcall(callback, err)
    else
        UIManager:show(InfoMessage:new{ text = tostring(title) .. "：\n" .. tostring(err) })
    end
end

function ReadingCoordinator:_presentReader(book, progress, task, options)
    runAfterPaint(function()
        local ok, reader_or_err, model_err = xpcall(function()
            local current, index_err = clampChapter(book, options.chapter_index)
            if not current then return nil, index_err end
            book.position = book.position or {}
            book.position.chapter = current
            local chapter = book.chapters[current]
            book.position.chapter_id = chapter and chapter.id or nil

            -- Parse exactly once before ReaderView construction. ReaderView receives
            -- the same BookService cache and does not perform a network fallback.
            local model, parse_err = BookService:loadChapterModel(book, current)
            if not model then return nil, tostring(parse_err or "章节解析失败") end
            if type(self.create_reader) ~= "function" then return nil, "阅读器工厂不可用" end

            if type(options.on_before_present) == "function" then
                pcall(options.on_before_present, book)
            end
            local reader = self.create_reader(book, {
                return_view = options.return_view,
            })
            if not reader then return nil, "阅读器创建失败" end
            self.active_reader = reader
            UIManager:show(reader, "full")
            -- [seam] leko-plus：番茄书开书后异步拉取云端进度（不影响显示延迟）
            if book.provider then
                pcall(function()
                    require("Leko/Fanqie/ProgressSync"):pullProgress(book, function() end)
                end)
            end
            -- Opening a book acknowledges the existing shelf badge. New
            -- network checks are deliberately manual from the shelf or reader.
            if type(BookService.markTocUpdateSeen) == "function" then
                BookService:markTocUpdateSeen(book)
            end
            -- A result list can be the return route. Keep it in the UI stack so
            -- closing the reader reveals the exact search/source session.
            if options.origin_view and options.origin_view ~= options.return_view then
                closeIfShown(options.origin_view, "full")
            end
            task:complete(progress)
            if UIManager.setDirty then UIManager:setDirty(reader, "full") end
            if UIManager.forceRePaint then UIManager:forceRePaint() end
            if type(self.on_reader_created) == "function" then pcall(self.on_reader_created, reader, book) end
            if type(self.on_reader_shown) == "function" then pcall(self.on_reader_shown, reader, book) end
            if type(options.on_reader_shown) == "function" then pcall(options.on_reader_shown, reader, book) end
            return reader
        end, function(err)
            return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
        end)

        if not ok then
            task:complete(progress)
            self:_showError("无法进入阅读器", reader_or_err, options.on_failure)
        elseif not reader_or_err then
            task:complete(progress)
            self:_showError("无法进入阅读器", model_err or "首屏生成失败", options.on_failure)
        end
    end)
end

function ReadingCoordinator:open(book, options)
    options = options or {}
    if not book or not book.id then
        self:_showError("无法准备阅读", "书籍信息不完整", options.on_failure)
        return nil
    end
    if self:isBusy() then return nil, "已有阅读任务正在进行" end

    local in_library = Storage:isInLibrary(book.id)
    local title = options.title or (in_library and "正在准备阅读" or "正在准备试读")
    local chapter_index = tonumber(options.chapter_index
        or (book.position and book.position.chapter) or 1) or 1

    return self.task:start{
        operation = "prepare-reading",
        book = book,
        book_id = book.id,
        chapter_index = chapter_index,
        title = title,
        cancel_text = options.cancel_text or (in_library and "取消阅读" or "取消试读"),
        keep_progress = true,
        finish_on_success = false,
        on_state = options.on_state,
        on_payload_ready = options.on_payload_ready,
        on_cancel = function(reason)
            if type(options.on_cancel) == "function" then pcall(options.on_cancel, reason) end
        end,
        on_failure = function(err)
            self:_showError("无法准备阅读", err, options.on_failure)
        end,
        on_success = function(ready_book, _, progress, task)
            self:_presentReader(ready_book, progress, task, {
                chapter_index = chapter_index,
                origin_view = options.origin_view,
                return_view = options.return_view,
                on_before_present = options.on_before_present,
                on_reader_shown = options.on_reader_shown,
                on_failure = options.on_failure,
            })
        end,
    }
end

function ReadingCoordinator:prepareChapter(reader, position, refresh_type, options)
    options = options or {}
    if not reader or not reader.book then return nil, "阅读器状态不完整" end
    -- A new foreground page request owns the reader. Replacing the previous
    -- chapter task prevents quick taps from becoming a hidden task queue.
    -- ForegroundBookTask separately guards every subprocess callback with its
    -- own generation token.
    if self:isBusy() then self.task:cancel("replaced") end
    local chapter_index = tonumber(position and position.chapter) or 1
    local chapter = reader.book.chapters and reader.book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end

    BookService:cancelPrefetch(reader.book.id, true)
    local force_network = options.force_network == true
    local operation = "prepare-chapter"
    if force_network then operation = "redownload-chapter" end
    return self.task:start{
        operation = operation,
        book = reader.book,
        book_id = reader.book.id,
        chapter_index = chapter_index,
        title = "正在打开章节",
        force_network = force_network,
        stage = "正在等待前台章节任务",
        keep_progress = true,
        finish_on_success = false,
        on_failure = function(err)
            if reader._closing then return end
            if options.generation and type(reader.isPageGenerationCurrent) == "function"
                    and not reader:isPageGenerationCurrent(options.generation) then
                return
            end
            if type(reader._settleSwipeRefresh) == "function" then
                reader:_settleSwipeRefresh()
            end
            self:_showError(force_network and "刷新本章失败" or "章节打开失败", err, options.on_failure)
        end,
        on_success = function(updated_book, _, progress, task)
            runAfterPaint(function()
                if reader._closing then task:complete(progress); return end
                if options.generation and type(reader.isPageGenerationCurrent) == "function"
                        and not reader:isPageGenerationCurrent(options.generation) then
                    task:complete(progress)
                    return
                end
                reader.book = updated_book
                if force_network then
                    BookService:clearBookCache(updated_book.id)
                end
                local ok, page_err
                if type(options.present) == "function" then
                    ok, page_err = options.present(reader, updated_book, position, refresh_type)
                else
                    ok, page_err = reader:applyPreparedPosition(position, refresh_type,
                        options.direction, options.generation)
                end
                task:complete(progress)
                if not ok then
                    if type(reader._settleSwipeRefresh) == "function" then
                        reader:_settleSwipeRefresh()
                    end
                    self:_showError("章节加载失败", page_err, options.on_failure)
                end
            end)
        end,
    }
end

function ReadingCoordinator:refreshToc(reader, options)
    options = options or {}
    if not reader or not reader.book then return nil, "阅读器状态不完整" end
    if self:isBusy() then return nil, "已有前台读取任务正在进行" end
    BookService:cancelPrefetch(reader.book.id, true)
    local old_page = reader.page
    local old_chapter_count = #(reader.book.chapters or {})
    local generation = reader.page_generation
    return self.task:start{
        operation = "refresh-toc",
        book = reader.book,
        book_id = reader.book.id,
        title = "正在检查最新章节",
        cancel_text = "取消检查",
        show_progress = false,
        keep_progress = true,
        finish_on_success = false,
        on_failure = function(err)
            if reader._closing then return end
            if generation and type(reader.isPageGenerationCurrent) == "function"
                    and not reader:isPageGenerationCurrent(generation) then
                return
            end
            if type(reader._settleSwipeRefresh) == "function" then
                reader:_settleSwipeRefresh()
            end
            self:_showError("目录检查失败", err, options.on_failure)
        end,
        on_success = function(updated, payload, progress, task)
            runAfterPaint(function()
                if reader._closing then task:complete(progress); return end
                if generation and type(reader.isPageGenerationCurrent) == "function"
                        and not reader:isPageGenerationCurrent(generation) then
                    task:complete(progress)
                    return
                end
                local change = payload and payload.toc_change or {}
                if type(reader.applyTocUpdate) == "function" then
                    reader:applyTocUpdate(updated, change)
                else
                    reader.book = updated
                end
                if type(self.on_toc_updated) == "function" then
                    pcall(self.on_toc_updated, updated, change)
                end
                task:complete(progress)
                local new_count = tonumber(change and change.new_count or 0) or 0
                if new_count > 0 then
                    UIManager:show(InfoMessage:new{ text = "发现 " .. tostring(new_count) .. " 个新章节" })
                    local target = (updated.position and updated.position.chapter or old_chapter_count) + 1
                    if old_page and old_page.at_end and target <= #(updated.chapters or {}) then
                        reader:loadPage({ chapter = target, paragraph = 1, char = 1 }, "full")
                    end
                else
                    UIManager:show(InfoMessage:new{ text = "已经是最新章节" })
                end
                if type(options.on_success) == "function" then pcall(options.on_success, updated, change) end
            end)
        end,
    }
end

return ReadingCoordinator
