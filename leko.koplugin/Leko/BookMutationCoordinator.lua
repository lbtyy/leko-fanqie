local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local BookService = require("Leko/BookService")
local ForegroundBookTask = require("Leko/ForegroundBookTask")
local SourceHealth = require("Leko/SourceHealth")

local BookMutationCoordinator = {}
BookMutationCoordinator.__index = BookMutationCoordinator

function BookMutationCoordinator:new(options)
    options = options or {}
    local instance = setmetatable({
        owner = options.owner,
        get_book = options.get_book,
        set_book = options.set_book,
        on_book_updated = options.on_book_updated,
        on_rebuild = options.on_rebuild,
    }, self)
    instance.task = ForegroundBookTask:new{
        owner = options.owner,
        on_kind_start = options.on_kind_start,
        on_kind_done = options.on_kind_done,
    }
    return instance
end

function BookMutationCoordinator:isBusy()
    return self.task:isBusy()
end

function BookMutationCoordinator:cancel(reason)
    return self.task:cancel(reason or "cancelled")
end

function BookMutationCoordinator:_book()
    if type(self.get_book) == "function" then return self.get_book() end
    return self.owner and self.owner.book
end

function BookMutationCoordinator:_applyBook(book, change)
    if type(self.set_book) == "function" then self.set_book(book)
    elseif self.owner then self.owner.book = book end
    if type(self.on_book_updated) == "function" then pcall(self.on_book_updated, book, change) end
    if type(self.on_rebuild) == "function" then pcall(self.on_rebuild, book, change) end
end

local function userError(err)
    local message = tostring(err or "未知错误")
    local trace_at = message:find("\nstack traceback:", 1, true)
    if trace_at then message = message:sub(1, trace_at - 1) end
    message = message:gsub("^.-%%.lua:%%d+:%%s*", "", 1)
    return message
end

function BookMutationCoordinator:_error(title, err)
    UIManager:show(InfoMessage:new{ text = tostring(title) .. "：\n" .. userError(err) })
end

function BookMutationCoordinator:switchSource(result, options)
    options = options or {}
    local book = self:_book()
    local cache_state = book and BookService:getFullCacheState(book.id) or nil
    local resume_cache = cache_state and cache_state.active == true
    if resume_cache then BookService:pauseFullBookCache(book.id) end
    local cache_resumed = false
    local function resumeFullCache(target)
        if not resume_cache or cache_resumed or not target then return end
        cache_resumed = true
        BookService:resumeFullBookCache(target)
    end
    return self.task:start{
        operation = "switch-source",
        keep_progress = true,
        finish_on_success = false,
        book = book,
        book_id = book and book.id,
        result = result,
        on_payload_ready = options.on_payload_ready,
        on_cancel = function(reason)
            resumeFullCache(book)
            if type(options.on_failure) == "function" then pcall(options.on_failure, reason) end
        end,
        on_failure = function(err)
            resumeFullCache(book)
            if type(options.on_failure) == "function" then pcall(options.on_failure, err) end
            self:_error("书籍换源失败", err)
        end,
        on_success = function(updated, payload, progress, task)
            if type(options.on_source_view_closing) == "function" and options.source_view then
                pcall(options.on_source_view_closing, options.source_view)
            end
            if options.source_view then UIManager:close(options.source_view, "full") end
            self:_applyBook(updated, { source_changed = true })
            resumeFullCache(updated)
            pcall(SourceHealth.markSelected, SourceHealth, updated.source_id, updated.source_name)
            if type(options.on_success) == "function" then pcall(options.on_success, updated, payload) end
            task:complete(progress)
            local notice = "已切换内容源：" .. tostring(updated.source_name or "")
            if payload and payload.warning then notice = notice .. "\n" .. tostring(payload.warning) end
            UIManager:show(Notification:new{ text = notice })
        end,
    }
end

function BookMutationCoordinator:applyCover(result, options)
    options = options or {}
    local book = self:_book()
    return self.task:start{
        operation = "apply-cover",
        keep_progress = true,
        finish_on_success = false,
        book = book,
        book_id = book and book.id,
        result = result,
        on_payload_ready = options.on_payload_ready,
        on_cancel = options.on_failure,
        on_failure = function(err)
            if type(options.on_failure) == "function" then pcall(options.on_failure, err) end
            self:_error("封面换源失败", err)
        end,
        on_success = function(updated, payload, progress, task)
            if options.cover_view then UIManager:close(options.cover_view, "full") end
            self:_applyBook(updated, { cover_changed = true })
            pcall(SourceHealth.markSelected, SourceHealth, result.source_id, result.source_name)
            if type(options.on_success) == "function" then pcall(options.on_success, updated, payload) end
            task:complete(progress)
            UIManager:show(Notification:new{ text = "已使用封面源：" .. tostring(result.source_name or "") })
        end,
    }
end

function BookMutationCoordinator:reloadCover(options)
    options = options or {}
    local book = self:_book()
    return self.task:start{
        operation = "reload-cover",
        keep_progress = true,
        finish_on_success = false,
        book = book,
        book_id = book and book.id,
        on_failure = function(err) self:_error("抓取封面失败", err) end,
        on_success = function(updated, _, progress, task)
            self:_applyBook(updated, { cover_changed = true })
            if type(options.on_success) == "function" then pcall(options.on_success, updated) end
            task:complete(progress)
            UIManager:show(Notification:new{ text = "封面已更新" })
        end,
    }
end

function BookMutationCoordinator:refreshToc(options)
    options = options or {}
    local book = self:_book()
    local cache_state = book and BookService:getFullCacheState(book.id) or nil
    local resume_cache = cache_state and cache_state.active == true
    if resume_cache then BookService:pauseFullBookCache(book.id) end
    local cache_resumed = false
    local function resumeFullCache(target)
        if not resume_cache or cache_resumed or not target then return end
        cache_resumed = true
        BookService:resumeFullBookCache(target)
    end
    return self.task:start{
        operation = "refresh-toc",
        keep_progress = true,
        finish_on_success = false,
        book = book,
        book_id = book and book.id,
        on_cancel = function() resumeFullCache(book) end,
        on_failure = function(err) resumeFullCache(book); self:_error("刷新失败", err) end,
        on_success = function(updated, _, progress, task)
            self:_applyBook(updated, { toc_changed = true })
            resumeFullCache(updated)
            if type(options.on_success) == "function" then pcall(options.on_success, updated) end
            task:complete(progress)
            UIManager:show(Notification:new{ text = "目录已刷新" })
        end,
    }
end

function BookMutationCoordinator:prepareToc(options)
    options = options or {}
    local book = self:_book()
    return self.task:start{
        operation = "prepare-toc",
        keep_progress = true,
        finish_on_success = false,
        book = book,
        book_id = book and book.id,
        on_failure = function(err) self:_error("无法读取目录", err) end,
        on_success = function(updated, _, progress, task)
            self:_applyBook(updated, { toc_loaded = true })
            if type(options.on_success) == "function" then pcall(options.on_success, updated) end
            task:complete(progress)
        end,
    }
end

function BookMutationCoordinator:exportBook(format, options)
    options = options or {}
    local book = self:_book()
    return self.task:start{
        operation = "export-book",
        book = book,
        book_id = book and book.id,
        export_format = tostring(format or "epub"):lower(),
        keep_progress = true,
        finish_on_success = false,
        on_failure = function(err) self:_error("导出失败", err) end,
        on_success = function(updated, payload, progress, task)
            if type(options.on_success) == "function" then pcall(options.on_success, updated, payload) end
            task:complete(progress)
            UIManager:show(InfoMessage:new{
                text = "导出成功"
                    .. (payload and payload.export_warning
                        and "\n\n提示：" .. tostring(payload.export_warning)
                        or "")
                    .. "\n\n保存位置：\n" .. tostring(payload and payload.export_path or "未知路径"),
            })
        end,
    }
end

return BookMutationCoordinator
