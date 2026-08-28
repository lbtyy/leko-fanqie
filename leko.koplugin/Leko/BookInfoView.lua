local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local BookMutationCoordinator = require("Leko/BookMutationCoordinator")
local BookService = require("Leko/BookService")
local BookSourceView = require("Leko/BookSourceView")
local CoverBrowserView = require("Leko/CoverBrowserView")
local CoverLoadController = require("Leko/CoverLoadController")
local Importer = require("Leko/Importer")
local SourceSearchController = require("Leko/SourceSearchController")
local Storage = require("Leko/Storage")
local TocView = require("Leko/TocView")
local UI = require("Leko/UI")
local Util = require("Leko/Util")

local function boundedIntro(value)
    local limit = tonumber(Util.PRESENTATION_TEXT_LIMIT or 500) or 500
    if type(Util.truncateUtf8) == "function" then return Util.truncateUtf8(value, limit) end
    value = tostring(value or "")
    if #value <= limit then return value end
    return value:sub(1, math.max(0, limit - 3)) .. "…"
end

local function boundedCover(value)
    if type(Util.safeCoverDescriptor) == "function" then return Util.safeCoverDescriptor(value) end
    local limit = tonumber(Util.COVER_DESCRIPTOR_LIMIT or (16 * 1024)) or (16 * 1024)
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or #value > limit then return nil end
    return value
end


local BookInfoView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function BookInfoView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { "Back" }, { "Esc" } } end
    -- Search-result details must appear without waiting for search-process reap,
    -- flash writes or image decode. A deferred cover remains deferred for this
    -- lightweight trial page; users can explicitly open 封面换源 when desired.
    self._cover_deferred = self.defer_cover == true
    self._cover_image = nil
    self._cover_error = nil
    self._cover_loading = false
    self._loaded_cover_result = nil
    self._cover_loader = CoverLoadController:new{ owner = self }
    self._return_view = nil
    self._mutations = BookMutationCoordinator:new{
        owner = self,
        get_book = function() return self.book end,
        set_book = function(book) self.book = book end,
        on_book_updated = function(book, change)
            if change and change.source_changed then
                self._cover_image = nil
                self._cover_error = nil
                self._cover_loading = false
                self._loaded_cover_result = nil
                if self._cover_loader then self._cover_loader:cancel() end
                UI.defer(self, "reload_book_cover", function() self:loadCover() end)
            end
            if self.onBookUpdated then self.onBookUpdated(book, change) end
        end,
        on_rebuild = function() self:rebuild() end,
        on_kind_start = function(kind)
            if self.onHeavyTaskStart then pcall(self.onHeavyTaskStart, kind) end
        end,
        on_kind_done = function(kind)
            if self.onHeavyTaskDone then pcall(self.onHeavyTaskDone, kind) end
        end,
    }
    BookService:observeFullCache(self.book.id, self, function(state)
        local previous = self._full_cache_status
        self._full_cache_state = state
        self._full_cache_status = state and state.status or nil
        self:_refreshBookMenuProgress(state)
        if self._closing or previous == nil or previous == self._full_cache_status then return end
        if state.status == "ready" then
            UIManager:show(Notification:new{ text = "《" .. tostring(self.book.title or "本书") .. "》全书缓存完成" })
        elseif state.status == "partial" and state.active ~= true then
            UIManager:show(InfoMessage:new{
                text = "全书缓存暂时完成\n\n进度：" .. tostring(state.cached or 0) .. "/" .. tostring(state.total or 0)
                    .. (state.last_error and ("\n\n" .. tostring(state.last_error)) or ""),
            })
        end
    end)
    self:rebuild()
    UI.defer(self, "load_book_cover", function() self:loadCover() end)
end

function BookInfoView:_coverCandidate()
    local book = self.book or {}
    return {
        title = book.title,
        author = book.author,
        source_id = book.cover_source_id or book.source_id,
        source_name = book.cover_source_name or book.source_name,
        book_url = book.cover_book_url or book.book_url,
        cover = boundedCover(book.selected_cover_url or book.content_cover or book.cover),
        variables = book.cover_variables or book.variables,
        _source_record = book.cover_source_record or book.source_record,
        _source_runtime = book.candidate_source_runtime,
    }
end

function BookInfoView:loadCover()
    if self._closing or not self.book or not self._cover_loader then return false end
    if BookService:getValidCoverPath(self.book) then return true end
    local candidate = self:_coverCandidate()
    if not candidate.source_id and tostring(candidate.cover or "") == "" then
        self._cover_error = "书源没有提供封面地址"
        self:rebuild()
        return false
    end
    self._cover_loading = true
    self._cover_error = nil
    local width = math.max(1, math.floor(self.dimen.w * 0.28))
    local body_h = self.dimen.h - math.max(54, math.floor(self.dimen.h * 0.075))
        - math.max(62, math.floor(self.dimen.h * 0.085))
    local height = math.min(math.floor(width * 1.42), math.floor(body_h * 0.48))
    self._cover_loader:load{
        result = candidate,
        width = math.max(1, width - 8),
        height = math.max(1, height - 8),
        is_current = function() return not self._closing end,
        on_resolved = function(resolved)
            if self._closing or type(resolved) ~= "table" then return end
            self._loaded_cover_result = resolved
            local cover = boundedCover(resolved.cover)
            if cover then
                self.book.cover = cover
                self.book.content_cover = cover
                self.book.cover_source_id = resolved.source_id or self.book.cover_source_id
                self.book.cover_source_name = resolved.source_name or self.book.cover_source_name
                self.book.cover_book_url = resolved.book_url or self.book.cover_book_url
                self.book.cover_variables = resolved.variables or self.book.cover_variables
                self.book.cover_source_record = resolved._source_record or self.book.cover_source_record
            end
        end,
        on_ready = function(image, prepared, resolved_result)
            if self._closing then return end
            self._cover_loading = false
            self._cover_error = nil
            self._cover_image = image
            self._loaded_cover_result = resolved_result or self._loaded_cover_result or candidate
            self:rebuild()
            self:_scheduleLoadedCoverPersistence(self._loaded_cover_result, prepared)
        end,
        on_failure = function(err)
            if self._closing then return end
            self._cover_loading = false
            self._cover_error = tostring(err or "封面读取失败")
            self:rebuild()
        end,
    }
    return true
end

function BookInfoView:_scheduleLoadedCoverPersistence(result, prepared)
    if self._closing or not self.book or not Storage:isInLibrary(self.book.id) then return false end
    if BookService:getValidCoverPath(self.book) then return false end
    result = result or self._loaded_cover_result or self:_coverCandidate()
    self._loaded_cover_result = result
    return UI.defer(self, "persist_loaded_cover", function()
        if self._closing or not self.book or not Storage:isInLibrary(self.book.id) then return end
        if BookService:getValidCoverPath(self.book) then return end
        local ok, saved, changed = pcall(BookService.materializeCachedCover, BookService,
            self.book, result, prepared)
        if not ok or not saved or not changed then return end
        -- materializeCachedCover commits the cover and clears the decoded
        -- image LRU. Rebuild through the normal local-file path and notify the
        -- bookshelf so its lightweight summary gets the same cover_path.
        self._cover_image = nil
        if self.onBookUpdated then self.onBookUpdated(self.book, { cover_changed = true, cover_auto = true }) end
        self:rebuild()
    end)
end

function BookInfoView:buildCover(width, height)
    -- A deferred search detail starts with the same placeholder as any other
    -- page, then loadCover() resolves it asynchronously.  Do not permanently
    -- suppress the cover just because the detail page came from search.
    if self._cover_deferred and false then
        return FrameContainer:new{
            width = width, height = height, padding = 4, bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - 10, h = height - 10 },
                TextBoxWidget:new{
                    text = "书籍详情已打开\n为降低内存，试读详情不自动解码封面",
                    width = width - 20, alignment = "center",
                    face = Font:getFace("smallinfofont", 17),
                },
            },
        }
    end
    local path = BookService:getValidCoverPath(self.book)
    if path then
        return FrameContainer:new{
            width = width,
            height = height,
            padding = 2,
            bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - 6, h = height - 6 },
                ImageWidget:new{
                    file = path,
                    width = width - 8,
                    height = height - 8,
                    scale_factor = 0,
                    file_do_cache = false,
                },
            },
        }
    end
    if self._cover_image then
        return FrameContainer:new{
            width = width,
            height = height,
            padding = 2,
            bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - 6, h = height - 6 },
                ImageWidget:new{
                    image = self._cover_image,
                    image_disposable = false,
                    width = width - 8,
                    height = height - 8,
                    scale_factor = 0,
                },
            },
        }
    end
    return FrameContainer:new{
        width = width,
        height = height,
        padding = 4,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width - 10, h = height - 10 },
            TextBoxWidget:new{
                text = "暂无封面\n\n使用下方“封面换源”或在“更多”中选择本地图片",
                width = width - 20,
                alignment = "center",
                face = Font:getFace("smallinfofont", 17),
            },
        },
    }
end

function BookInfoView:rebuild()
    local width, height = self.dimen.w, self.dimen.h
    local in_library = Storage:isInLibrary(self.book.id)
    self.book.in_library = in_library
    self.book.not_shelf = not in_library
    local header_h = math.max(54, math.floor(height * 0.075))
    local footer_h = math.max(62, math.floor(height * 0.085))
    local body_h = height - header_h - footer_h
    local margin = math.max(14, math.floor(width * 0.03))
    local cover_w = math.floor(width * 0.28)
    local cover_h = math.min(math.floor(cover_w * 1.42), math.floor(body_h * 0.48))
    local info_w = width - margin * 3 - cover_w
    local source_name = self.book.source_name or "本地书籍"
    -- [seam] leko-plus：番茄书详情显示 Provider 来源标签（PRD §3.3）。
    if self.book.provider then
        local provider_label = tostring(self.book.provider_source or self.book.provider)
        local ok_registry, registry = pcall(require, "Leko/providers/ProviderRegistry")
        if ok_registry and registry then
            local provider = registry:get(self.book.provider_source or self.book.provider)
            if provider and provider.name then provider_label = provider.name end
        end
        source_name = "番茄 · " .. provider_label
    end

    local header = UI.header(width, header_h, {
        left_text = "‹ 返回",
        title = "书籍详情",
        right_text = "更多 ›",
        on_left = function() self:onClose() end,
        on_right = function() self:showBookMenu() end,
    })

    local metadata_lines = {
        "作者：" .. ((self.book.author and self.book.author ~= "") and self.book.author or "佚名"),
        "内容源：" .. source_name,
        "封面源：" .. tostring(self.book.cover_source_name or (self.book.manual_cover and "本地图片") or "跟随内容源"),
        "章节：" .. tostring((#(self.book.chapters or {}) > 0)
            and #(self.book.chapters or {}) or (tonumber(self.book.chapter_count or 0) or 0))
            .. (in_library and "\n状态：已在书架" or "\n状态：试读，尚未加入书架"),
    }
    -- [seam] leko-plus I-1：番茄书详情追加云端进度 + 段评能力两行状态（PRD §3.3）
    if self.book.provider then
        local provider_id = tostring(self.book.provider_source or self.book.provider)
        local review_supported = "不支持"
        local ok_rs, rs = pcall(require, "Leko/Fanqie/FanqieReviewService")
        if ok_rs and rs and type(rs.enabledFor) == "function" then
            local supported = rs:enabledFor(provider_id)
            review_supported = supported and "支持" or "不支持"
        end
        local cloud_progress_text = "未登录"
        local ok_auth, auth = pcall(require, "Leko/Fanqie/FanqieAuth")
        if ok_auth and auth and type(auth.isLoggedIn) == "function" and auth:isLoggedIn() then
            local pos = self.book.position or {}
            local chapter = tonumber(pos.chapter) or 0
            local last_read_ts = tonumber(self.book.last_read_ts or self.book.last_update or 0) or 0
            local time_str = last_read_ts > 0 and os.date("%Y-%m-%d %H:%M", last_read_ts) or "未知"
            cloud_progress_text = string.format("第 %d 章（%s）", chapter, time_str)
        end
        metadata_lines[#metadata_lines + 1] = "云端进度：" .. cloud_progress_text
        metadata_lines[#metadata_lines + 1] = "段评：" .. review_supported
    end

    local metadata = VerticalGroup:new{
        TextBoxWidget:new{
            text = self.book.title or "未命名",
            width = info_w,
            face = Font:getFace("tfont", 28),
            bold = true,
            alignment = "left",
        },
        UI.vspace(10),
        TextBoxWidget:new{
            text = table.concat(metadata_lines, "\n"),
            width = info_w,
            face = Font:getFace("smallinfofont", 19),
            alignment = "left",
        },
    }

    local intro_h = math.max(96, body_h - cover_h - margin * 2)
    local intro = ScrollTextWidget:new{
        text = (self.book.intro and self.book.intro ~= "")
            and boundedIntro(self.book.intro)
            or "暂无简介。",
        width = width - margin * 2,
        height = intro_h,
        face = Font:getFace("cfont", 21),
        dialog = self,
    }

    local body = VerticalGroup:new{
        UI.vspace(margin),
        HorizontalGroup:new{
            HorizontalSpan:new{ width = margin },
            self:buildCover(cover_w, cover_h),
            HorizontalSpan:new{ width = margin },
            LeftContainer:new{ dimen = Geom:new{ w = info_w, h = cover_h }, metadata },
        },
        UI.vspace(margin),
        HorizontalGroup:new{
            HorizontalSpan:new{ width = margin },
            intro,
        },
    }

    local footer = UI.footer(width, footer_h, {
        {
            text = in_library and "继续阅读" or "开始试读",
            bold = true,
            callback = function() self:startReading() end,
        },
        { text = "目录", callback = function() self:showToc() end },
        { text = "书籍换源", font_size = 16, enabled = self.book.source_id ~= nil or self.book.provider ~= nil, callback = function() self:showBookSourceSwitcher() end },
        { text = "封面换源", font_size = 16, enabled = self.book.source_id ~= nil, callback = function() self:showCoverSourceSwitcher() end },
        {
            text = in_library and "移出书架" or "加入书架",
            callback = function() self:toggleBookshelf() end,
        },
    })

    local old_screen = self[1]
    self[1] = UI.screen(width, height, header, body, footer, header_h, footer_h)
    if old_screen and old_screen ~= self[1] and type(old_screen.free) == "function" then
        pcall(old_screen.free, old_screen)
    end
    UIManager:setDirty(self, "ui", self.dimen)
end

function BookInfoView:startReading(chapter_index)
    if self._reading_active or (self._mutations and self._mutations:isBusy()) then return true end
    chapter_index = tonumber(chapter_index
        or (self.book.position and self.book.position.chapter) or 1) or 1
    return UI.defer(self, "start_reading", function()
        if self._reading_active then return end
        self._reading_active = true
        local finished = false
        local function finishReadingTask()
            if finished then return end
            finished = true
            self._reading_active = false
            self._reading_task = nil
            if self.onHeavyTaskDone then pcall(self.onHeavyTaskDone, "reading") end
        end
        if self.onHeavyTaskStart then pcall(self.onHeavyTaskStart, "reading") end
        if not self.onRead then
            finishReadingTask()
            UIManager:show(InfoMessage:new{ text = "阅读器入口不可用" })
            return
        end
        local task, err = self.onRead(self.book, {
            chapter_index = chapter_index,
            origin_view = self,
            return_view = self._return_view,
            title = Storage:isInLibrary(self.book.id) and "正在准备阅读" or "正在准备试读",
            cancel_text = Storage:isInLibrary(self.book.id) and "取消阅读" or "取消试读",
            on_before_present = function(book)
                self.book = book
                self._entering_reader = true
                if self.onBeforeEnterReader then pcall(self.onBeforeEnterReader, book) end
            end,
            on_reader_shown = function()
                finishReadingTask()
            end,
            on_failure = function(open_err)
                self._entering_reader = false
                finishReadingTask()
                UIManager:show(InfoMessage:new{
                    text = "无法进入阅读器：\n" .. tostring(open_err),
                })
            end,
            on_cancel = function()
                self._entering_reader = false
                finishReadingTask()
            end,
        })
        if not task then
            self._entering_reader = false
            finishReadingTask()
            UIManager:show(InfoMessage:new{ text = "无法启动阅读任务：\n" .. tostring(err or "未知错误") })
            return
        end
        -- Existing-reader handoffs complete synchronously and return `true`
        -- instead of a cancellable ForegroundBookTask.  Never retain that
        -- boolean as a task handle: closing this view would otherwise try to
        -- call `true:cancel()` and abort KOReader with an uncaught Lua error.
        if type(task) == "table" and type(task.cancel) == "function" then
            self._reading_task = task
        else
            self._reading_task = nil
        end
    end)
end

function BookInfoView:addToBookshelf()
    if Storage:isInLibrary(self.book.id) then return true end
    local book, err = BookService:addToBookshelf(self.book)
    if not book then
        UIManager:show(Notification:new{ text = "加入书架失败：" .. tostring(err) })
        return true
    end
    self.book = book
    UIManager:show(Notification:new{ text = "已加入书架：" .. tostring(book.title) })
    if self.onBookAdded then self.onBookAdded(book) end
    self:_scheduleLoadedCoverPersistence(self._loaded_cover_result or self:_coverCandidate())
    self:rebuild()
    return true
end

function BookInfoView:removeFromBookshelf()
    if not Storage:isInLibrary(self.book.id) then return true end
    Storage:removeBookFromLibrary(self.book.id, true)
    self.book.in_library = false
    self.book.not_shelf = true
    UIManager:show(Notification:new{ text = "已移出书架，本地试读数据仍保留" })
    if self.onBookRemoved then self.onBookRemoved(self.book) end
    self:rebuild()
    return true
end

function BookInfoView:toggleBookshelf()
    if Storage:isInLibrary(self.book.id) then return self:removeFromBookshelf() end
    return self:addToBookshelf()
end


function BookInfoView:showBookSourceSwitcher()
    if not self.book.source_id then
        UIManager:show(InfoMessage:new{ text = "本地书籍没有可切换的网络内容源" })
        return true
    end
    NetworkMgr:runWhenConnected(function()
        local current = BookService:currentContentCandidate(self.book)
        local view
        local search = SourceSearchController:new{
            book = self.book,
            mode = "content",
        }
        view = BookSourceView:new{
            results = current and { current } or {},
            book_title = self.book.title,
            book_author = self.book.author,
            current_source_id = self.book.source_id,
            current_book_url = self.book.book_url,
            searching = true,
            total_sources = 0,
            search_stage = "优先搜索常用、快速与部分探索书源；找到同名内容源即显示",
            onSelectSource = function(result)
                search:pause("切换内容源期间释放全部搜索进程")
                self:applyBookSource(result, view, {
                    on_failure = function() search:resume() end,
                    on_success = function()
                        search:cancel()
                        -- With no active reader, enter the mapped current
                        -- position after the mutation task releases its
                        -- foreground slot. An active reader is reloaded by
                        -- App and only needs the source list to close.
                        if not self.reader_active then
                            local function resumeReading()
                                if not self._closing then self:startReading() end
                            end
                            if type(UIManager.nextTick) == "function" then UIManager:nextTick(resumeReading)
                            else UIManager:scheduleIn(0, resumeReading) end
                        end
                    end,
                    on_source_view_closing = function(closing_view)
                        if closing_view and closing_view.prepareForReturn then
                            closing_view:prepareForReturn()
                        end
                    end,
                })
            end,
            onSourceToggled = function(result, enabled)
                if not enabled then
                    search:cancel()
                    view.searching = false
                    view.search_stage = "已停用“" .. tostring(result.source_name or "此书源") .. "”；本次换源搜索已停止"
                end
            end,
            onSourcePriorityChanged = function()
                search:applySourcePreference()
            end,
            onCancelSearch = function() search:cancel() end,
        }
        search.options.view = view
        UIManager:show(view, "full")
        search:start()
    end)
    return true
end

function BookInfoView:cancelBookOperation()
    local reading_task = self._reading_task
    self._reading_task = nil
    if type(reading_task) == "table" and type(reading_task.cancel) == "function" then
        reading_task:cancel("detail-closed")
    end
    if self._mutations then self._mutations:cancel("detail-closed") end
end

function BookInfoView:applyBookSource(result, source_view, search_control)
    search_control = search_control or {}
    if not self._mutations then return end
    self._mutations:switchSource(result, {
        source_view = source_view,
        on_payload_ready = search_control.on_payload_ready,
        on_failure = search_control.on_failure,
        on_success = search_control.on_success,
        on_source_view_closing = search_control.on_source_view_closing,
    })
end

function BookInfoView:showCoverSourceSwitcher()
    if not self.book.source_id then
        UIManager:show(InfoMessage:new{ text = "本地书籍可在“更多”中选择本地封面" })
        return true
    end
    NetworkMgr:runWhenConnected(function()
        local view
        local search = SourceSearchController:new{
            book = self.book,
            mode = "cover",
        }
        view = CoverBrowserView:new{
            title = "封面换源",
            results = {},
            searching = true,
            total_sources = 0,
            search_stage = "搜到一个就立即显示；其余书源继续后台搜索",
            select_text = "使用此封面",
            onSelectCover = function(result)
                search:pause("应用封面期间释放全部搜索进程")
                self:applyCoverSource(result, view, {
                    on_failure = function() search:resume() end,
                    on_success = function() search:cancel() end,
                })
            end,
            onForegroundFetchStart = function()
                search:pause("当前封面加载期间释放全部搜索进程")
            end,
            onForegroundFetchDone = function() search:resume() end,
            onCancelSearch = function() search:cancel() end,
        }
        search.options.view = view
        search.options.on_progress = function(scanned, total, stage, session)
            view:setSearchProgress(scanned, total, stage, false,
                session and session.discovered_count, session and session.overflow_count)
        end
        search.options.on_done = function(_, session)
            local total = session and session.total_sources or 0
            local completed = session and session.completed_sources or total
            view:setSearchProgress(completed, total,
                session and session.last_stage or "封面搜索已完成", true,
                session and session.discovered_count, session and session.overflow_count)
        end
        UIManager:show(view, "full")
        search:start()
    end)
    return true
end

function BookInfoView:applyCoverSource(result, cover_view, search_control)
    search_control = search_control or {}
    if not self._mutations then return end
    self._mutations:applyCover(result, {
        cover_view = cover_view,
        on_payload_ready = search_control.on_payload_ready,
        on_failure = search_control.on_failure,
        on_success = search_control.on_success,
    })
end

function BookInfoView:fetchRemoteCover()
    if self._mutations then self._mutations:reloadCover() end
end

function BookInfoView:chooseLocalCover()
    return UI.defer(self, "choose_cover", function()
        Importer:chooseFile(function(path)
            local saved, err = BookService:setCoverFromFile(self.book, path)
            if not saved then
                UIManager:show(InfoMessage:new{ text = "更换封面失败：\n" .. tostring(err) })
                return
            end
            if self.onBookUpdated then self.onBookUpdated(self.book, { cover_changed = true }) end
            self:rebuild()
            UIManager:show(Notification:new{ text = "封面已更换" })
        end)
    end)
end

function BookInfoView:refreshRemoteBook()
    if self._mutations then self._mutations:refreshToc() end
end

function BookInfoView:toggleFullBookCache()
    local state = BookService:getFullCacheState(self.book.id)
    if state and state.active then
        BookService:pauseFullBookCache(self.book.id)
        UIManager:show(InfoMessage:new{
            text = "已暂停全书缓存\n\n进度：" .. tostring(state.cached or 0) .. "/" .. tostring(state.total or 0)
                .. "\n\n稍后可从书籍菜单继续。",
        })
        return true
    end
    local started, err = BookService:resumeFullBookCache(self.book)
    if not started then
        UIManager:show(InfoMessage:new{ text = "无法开始全书缓存：\n" .. tostring(err) })
        return true
    end
    if started.status == "ready" then
        UIManager:show(Notification:new{ text = "全书已经缓存完成" })
    else
        UIManager:show(InfoMessage:new{
            text = "已开始在后台缓存全书\n\n进度：" .. tostring(started.cached or 0) .. "/" .. tostring(started.total or 0)
                .. "\n\n阅读和其他前台操作会自动优先。",
        })
    end
    return true
end

function BookInfoView:_fullCacheButtonText(state, cached, total)
    cached = tonumber(state and state.cached or cached or 0) or 0
    total = tonumber(state and state.total or total or 0) or 0
    if state and state.active then
        local target = tostring(state.target_title or "")
        if target ~= "" and type(Util.truncateUtf8) == "function" then target = Util.truncateUtf8(target, 18) end
        return "暂停缓存 " .. cached .. "/" .. total .. (target ~= "" and (" · " .. target) or "")
    end
    if total > 0 and cached >= total then return "全书已缓存 (" .. cached .. "/" .. total .. ")" end
    if cached > 0 then return "继续缓存全书 (" .. cached .. "/" .. total .. ")" end
    return "缓存全书"
end

function BookInfoView:_refreshBookMenuProgress(state)
    local dialog = self._book_menu
    if not dialog or (UIManager.isWidgetShown and not UIManager:isWidgetShown(dialog))
            or type(dialog.getButtonById) ~= "function" then return end
    local cached = tonumber(state and state.cached or 0) or 0
    local total = tonumber(state and state.total or #(self.book.chapters or {})) or 0
    local ready = total > 0 and cached >= total
    local cache_button = dialog:getButtonById("full_cache")
    if cache_button then
        cache_button:setText(self:_fullCacheButtonText(state, cached, total), cache_button.width)
        cache_button:enableDisable(self.book.source_id ~= nil and not ready)
        cache_button:refresh()
    end
    for _, id in ipairs({ "export_txt", "export_epub", "export_mobi" }) do
        local button = dialog:getButtonById(id)
        if button then button:enableDisable(ready); button:refresh() end
    end
end

function BookInfoView:exportBook(format)
    if not self._mutations or self._mutations:isBusy() then return true end
    local cached, total = BookService:refreshChapterDownloadStates(self.book)
    if total == 0 or cached ~= total then
        UIManager:show(InfoMessage:new{
            text = "导出前需要完成全书缓存。\n当前：" .. tostring(cached) .. "/" .. tostring(total),
        })
        return true
    end
    self._mutations:exportBook(format)
    return true
end

function BookInfoView:showBookMenu()
    if self._book_menu then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._book_menu) then return true end
        self._book_menu = nil
    end
    return UI.showModalLater(self, "book_menu", function()
        local dialog
        local source = self.book.source_id and Storage:getSourceSummary(self.book.source_id) or nil
        local source_info_name = source and source.name or self.book.source_name or "本地书籍"
        local SourceStatus = require("Leko/SourceStatus")
        local source_info_capability = source and SourceStatus:capability(source) or "本地书籍"
        local cached, chapter_total = BookService:refreshChapterDownloadStates(self.book)
        local full_state = BookService:getFullCacheState(self.book.id)
        local cache_text = self:_fullCacheButtonText(full_state, cached, chapter_total)
        local export_ready = chapter_total > 0 and cached == chapter_total
        local buttons = {
            {
                { text = "书籍换源", enabled = self.book.source_id ~= nil, callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:showBookSourceSwitcher()
                end },
                { text = "封面换源", enabled = self.book.source_id ~= nil, callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:showCoverSourceSwitcher()
                end },
            },
            {
                { text = "选择本地封面", callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:chooseLocalCover()
                end },
                { text = self.book.cover_path and "重新获取网络封面" or "获取网络封面", enabled = self.book.cover ~= nil and tostring(self.book.cover) ~= "", callback = function()
                    UIManager:close(dialog); self._book_menu = nil
                    UI.defer(self, "reload_cover", function() self:fetchRemoteCover() end)
                end },
            },
            {
                { text = "刷新目录与书籍信息", callback = function()
                    UIManager:close(dialog); self._book_menu = nil
                    UI.defer(self, "refresh_book", function() self:refreshRemoteBook() end)
                end },
            },
            {
                { id = "full_cache", text = cache_text, enabled = self.book.source_id ~= nil
                    and not (chapter_total > 0 and cached == chapter_total), callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:toggleFullBookCache()
                end },
            },
            {
                { id = "export_txt", text = "导出 TXT", enabled = export_ready, callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:exportBook("txt")
                end },
                { id = "export_epub", text = "导出 EPUB", enabled = export_ready, callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:exportBook("epub")
                end },
                { id = "export_mobi", text = "导出 MOBI", enabled = export_ready, callback = function()
                    UIManager:close(dialog); self._book_menu = nil; self:exportBook("mobi")
                end },
            },
            {
                { text = "书源信息", callback = function()
                    UIManager:close(dialog); self._book_menu = nil
                    UI.showLater(self, "source_info", function()
                        return InfoMessage:new{
                            text = "内容源：" .. tostring(source_info_name)
                                .. "\n封面源：" .. tostring(self.book.cover_source_name or "跟随内容源")
                                .. "\n所需功能：" .. tostring(source_info_capability)
                                .. "\n书籍地址：\n" .. tostring(self.book.book_url or "无"),
                        }
                    end)
                end },
                { text = "清除封面", enabled = self.book.cover_path ~= nil, callback = function()
                    UIManager:close(dialog); self._book_menu = nil
                    local cleared, clear_err = BookService:clearCover(self.book)
                    if not cleared then
                        UIManager:show(InfoMessage:new{ text = "清除封面失败：\n" .. tostring(clear_err) })
                        return
                    end
                    if self.onBookUpdated then self.onBookUpdated(self.book, { cover_changed = true }) end
                    self:rebuild()
                end },
            },
        }
        if self.allow_delete ~= false then
            table.insert(buttons, {
                { text = "删除本地数据", callback = function()
                    UIManager:close(dialog); self._book_menu = nil
                    UI.showModalLater(self, "delete_confirm", function()
                        return ConfirmBox:new{
                            text = "删除“" .. tostring(self.book.title) .. "”的本地数据和已下载章节？",
                            ok_text = "删除",
                            ok_callback = function()
                                local id = self.book.id
                                -- Do not let a low-priority child recreate the
                                -- chapter directory after local data is gone.
                                BookService:cancelFullBookCache(id)
                                Storage:deleteBook(id)
                                UIManager:close(self, "full")
                                if self.onBookDeleted then self.onBookDeleted(id) end
                            end,
                        }
                    end)
                end },
            })
        end
        table.insert(buttons, {
            { text = "关闭", callback = function() UIManager:close(dialog); self._book_menu = nil end },
        })
        dialog = ButtonDialog:new{
            modal = true,
            title = "书籍菜单",
            buttons = buttons,
            tap_close_callback = function() self._book_menu = nil end,
        }
        self._book_menu = dialog
        return dialog
    end)
end

function BookInfoView:_showPreparedToc()
    return UI.showLater(self, "toc", function()
        return TocView:new{
            book = self.book,
            current_chapter = self.book.position and self.book.position.chapter or 1,
            onChapterSelected = function(chapter_index)
                if self.onChapterSelected then
                    UIManager:close(self, "full")
                    self.onChapterSelected(self.book, chapter_index)
                elseif self.onRead then
                    self:startReading(chapter_index)
                end
            end,
        }
    end, "full")
end

function BookInfoView:showToc()
    if #(self.book.chapters or {}) > 0 then return self:_showPreparedToc() end
    if not self._mutations or self._mutations:isBusy() then return true end
    self._mutations:prepareToc{
        on_success = function() self:_showPreparedToc() end,
    }
    return true
end

function BookInfoView:_notifyDetailsClosed()
    if self._details_closed_notified or self._entering_reader then return end
    self._details_closed_notified = true
    if self.onDetailsClosed then pcall(self.onDetailsClosed, self.book) end
end

function BookInfoView:onClose()
    self._closing = true
    BookService:unobserveFullCache(self.book.id, self)
    if self._cover_loader then self._cover_loader:close() end
    self:cancelBookOperation()
    self:_notifyDetailsClosed()
    UIManager:close(self, "full")
    local return_view = self._return_view
    self._return_view = nil
    if return_view and (not UIManager.isWidgetShown or not UIManager:isWidgetShown(return_view)) then
        UIManager:show(return_view, "full")
        if UIManager.setDirty then UIManager:setDirty(return_view, "full") end
    end
    return true
end

function BookInfoView:onCloseWidget()
    self._closing = true
    BookService:unobserveFullCache(self.book.id, self)
    if self._cover_loader then self._cover_loader:close() end
    self:cancelBookOperation()
    self:_notifyDetailsClosed()
end

return BookInfoView
