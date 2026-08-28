local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local BookService = require("Leko/BookService")
local FontSelectionView = require("Leko/FontSelectionView")
local Paginator = require("Leko/Paginator")
local ReaderFooter = require("Leko/ReaderFooter")
local Storage = require("Leko/Storage")
local TocView = require("Leko/TocView")
local UI = require("Leko/UI")
local Util = require("Leko/Util")

-- [seam] leko-plus：段落标记 + 段评弹窗（阶段③ T07）。
-- 仅在番茄 Provider 书打开时加载 FanqieReviewService 模块；惰性 require
-- 避免对普通 leko 用户产生任何 fanqie 模块加载开销。
local function reviewService()
    return require("Leko/Fanqie/FanqieReviewService")
end

-- Keep the semantic direction constants available even when an older or
-- mixed plugin directory cannot load the optional transition coordinator.
-- The real module is loaded only when a ReaderView is created.
local SwipeRefresh = { FORWARD = "forward", BACKWARD = "backward" }
local swipe_refresh_module
local swipe_refresh_load_error

local function loadSwipeRefresh()
    if swipe_refresh_module ~= nil then
        return swipe_refresh_module ~= false and swipe_refresh_module or nil,
            swipe_refresh_load_error
    end
    local ok, module = pcall(require, "Leko/SwipeRefresh")
    if not ok or type(module) ~= "table" or type(module.new) ~= "function" then
        swipe_refresh_load_error = tostring(ok and "transition coordinator API is invalid" or module)
        swipe_refresh_module = false
        return nil, swipe_refresh_load_error
    end
    swipe_refresh_module = module
    SwipeRefresh = module
    return module
end

local ReaderView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function ReaderView:init()
    self.style = Storage:getReaderStyle()
    self.history = {}
    self.menu_visible = false
    self._exit_dialog = nil
    self._layout_dialog = nil
    self._closing = false
    self.prefetch_state = nil
    self._prefetch_footer_signature = nil
    self._prefetch_footer_rendered_signature = nil
    self._prefetch_footer_refresh_pending = false
    self._progress_dirty = false
    self._footer_dirty = true
    self.page_generation = 0
    self._pending_rebuild = nil
    self.swipe_animation_enabled = self.style.page_transition_enabled ~= false
    self.chapter_clean_wave_enabled = self.style.chapter_clean_wave_enabled ~= false
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local swipe_module, swipe_error = loadSwipeRefresh()
    if swipe_module then
        local constructed, coordinator = pcall(swipe_module.new, swipe_module, {
            screen = Screen,
            ui_manager = UIManager,
        })
        if constructed and type(coordinator) == "table" then
            self.swipe_refresh = coordinator
        else
            self.swipe_refresh = nil
            swipe_error = tostring(coordinator or "transition coordinator initialization failed")
        end
    end
    self._swipe_refresh_load_error = swipe_error
    self.ges_events = self.ges_events or {}
    self.key_events = self.key_events or {}

    if Device:isTouchDevice() then
        if self.registerTouchZones then
            self:registerTouchZones({
                {
                    id = "leko_reader_tap_router",
                    ges = "tap",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function(ges) return self:routeTap(ges) end,
                },
                {
                    id = "leko_reader_hold_router",
                    ges = "hold",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function() return self:toggleMenu(true) end,
                },
                {
                    id = "leko_reader_swipe_router",
                    ges = "swipe",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function(ges) return self:routeSwipe(ges) end,
                },
            })
        end
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } }
    end

    if Device:hasKeys() then
        self.key_events.Close = { { "Back" }, { "Esc" } }
        self.key_events.ReaderMenu = { { "Menu" } }
        self.key_events.PageForward = { { "Right" }, { "RPgFwd" }, { "LPgFwd" }, { "PgFwd" } }
        self.key_events.PageBackward = { { "Left" }, { "RPgBack" }, { "LPgBack" }, { "PgBack" } }
    end

    BookService:observePrefetch(self.book.id, self, function(state)
        self:onPrefetchProgress(state)
    end)

    local position = Util.positionCopy(self.book.position)
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then page = self:errorPage(position, err) end
    self:consumeFontFallbackNotice()
    self:setPage(page, "full")
    if self._swipe_refresh_load_error then
        local message = "动画效果模块加载失败，已回退普通刷新。请完全退出并重新打开 KOReader 后，重新复制完整的 leko.koplugin 文件夹。"
        logger.warn("Leko transition coordinator disabled:", self._swipe_refresh_load_error)
        if type(UIManager.nextTick) == "function" then
            UIManager:nextTick(function()
                if not self._closing then
                    UIManager:show(Notification:new{ text = message })
                end
            end)
        else
            UIManager:show(Notification:new{ text = message })
        end
    end
end

function ReaderView:consumeFontFallbackNotice()
    if not self.style or not self.style._font_fallback_pending then return false end
    self.style._font_fallback_pending = nil
    Storage:saveReaderStyle(self.style)
    UIManager:show(Notification:new{ text = "原字体不可用，已恢复系统默认字体" })
    return true
end

function ReaderView:errorPage(position, err)
    local geometry = Paginator:getGeometry(self.style)
    return {
        start_position = Util.positionCopy(position),
        next_position = Util.positionCopy(position),
        elements = {{ type = "line", text = "加载失败：" .. tostring(err), height = geometry.body_line_height }},
        chapter_index = position.chapter,
        chapter_title = self.book.chapters[position.chapter] and self.book.chapters[position.chapter].title or self.book.title,
        geometry = geometry,
        style = self.style,
        used_height = geometry.body_line_height,
        at_end = true,
    }
end

function ReaderView:getMenuMetrics()
    local top_h = math.max(56, math.floor(self.dimen.h * 0.075))
    -- One compact action row. Font controls live inside the layout dialog.
    local bottom_h = math.max(64, math.floor(self.dimen.h * 0.09))
    return top_h, bottom_h
end

function ReaderView:_syncPrefetchState()
    if not self.book or type(BookService.getPrefetchState) ~= "function" then
        return self.prefetch_state
    end
    self.prefetch_state = BookService:getPrefetchState(self.book.id)
    return self.prefetch_state
end

function ReaderView:refreshFooterFromCache(refresh_type)
    if self._closing or not self.page then return false end
    self:_settleSwipeRefresh()
    self:_syncPrefetchState()
    self._prefetch_footer_signature = ReaderFooter:prefetchSignature(self.prefetch_state)
    self._prefetch_footer_rendered_signature = nil
    self._footer_dirty = true
    local region = self.menu_visible and self.dimen or self:_footerRegion()
    return self:rebuild(refresh_type or "full", region or self.dimen)
end

function ReaderView:_scheduleFooterRefresh(force)
    return UI.defer(self, "footer_restore", function()
        if self._closing or not self.page then return end
        if not force and (self.menu_visible
                or (UIManager.isWidgetShown and not UIManager:isWidgetShown(self))) then
            return
        end
        self:refreshFooterFromCache(force and "full" or "fast")
    end)
end

function ReaderView:buildFooterStatus(page, geometry)
    local total_chapters = #(self.book.chapters or {})
    local state = self.prefetch_state
    -- A page rebuild already contains the current cache indicator.  Remember
    -- that signature so a queued prefetch notification can coalesce with the
    -- page turn instead of rebuilding the whole reading page a second time.
    self._prefetch_footer_rendered_signature = ReaderFooter:prefetchSignature(state)
    self._prefetch_footer_signature = self._prefetch_footer_rendered_signature
    self._footer_dirty = false
    local chapter_index = tonumber(page.chapter_index or 1) or 1
    local chapter_percentage = 0
    -- Paginator already loaded the current chapter to create this page. Keep
    -- that reference on the page so an ordinary (non-animated) page turn does
    -- not perform another cache/disk lookup just to draw the footer.
    local model = page.chapter_model or BookService:loadChapterModel(self.book, chapter_index)
    if model then
        local position = page.next_position or page.start_position
        chapter_percentage = ReaderFooter:percentage(model, position, chapter_index, page.at_end)
    elseif page.at_end then
        chapter_percentage = 1
    end

    local left_text = string.format("第 %d / %d 章", chapter_index, total_chapters)
    local right_text = string.format("本章 %d%%", math.floor(chapter_percentage * 100 + 0.5))
    local cache = ReaderFooter:prefetchLabel(state)
    -- Keep the status line inside the same horizontal reading margins as the
    -- body. This avoids text touching the panel edges on small Kindle screens.
    local width = math.max(1, geometry.content_width or (geometry.screen_width
        - geometry.left - geometry.right))
    local height = geometry.footer_height
    local left_width = math.floor(width * 0.34)
    local right_width = math.floor(width * 0.24)
    local middle_width = math.max(1, width - left_width - right_width)

    local left = LeftContainer:new{
        dimen = Geom:new{ w = left_width, h = height },
        TextWidget:new{
            text = left_text,
            face = geometry.chrome_face,
            padding = 0,
            max_width = left_width,
        },
    }
    local right = RightContainer:new{
        dimen = Geom:new{ w = right_width, h = height },
        TextWidget:new{
            text = right_text,
            face = geometry.chrome_face,
            padding = 0,
            max_width = right_width,
        },
    }

    local middle_content
    if cache then
        -- Keep the 0.15.39 visual scale: the bar was 22% of the usable
        -- reading width. Computing 28% of the already narrowed middle column
        -- made it only about 12% of the page and nearly invisible on Kindle 7.
        local cache_bar_width = math.max(Screen:scaleBySize(54), math.floor(width * 0.22))
        middle_content = HorizontalGroup:new{
            align = "center",
            TextWidget:new{
                text = cache.text,
                face = geometry.chrome_face,
                padding = 0,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(5) },
            ProgressWidget:new{
                width = cache_bar_width,
                height = math.max(3, Screen:scaleBySize(5)),
                padding = 0,
                margin = 0,
                fillcolor = Blitbuffer.COLOR_BLACK,
                percentage = cache.percentage,
            },
        }
    else
        middle_content = TextWidget:new{ text = "", face = geometry.chrome_face, padding = 0 }
    end

    local footer = HorizontalGroup:new{
        left,
        CenterContainer:new{
            dimen = Geom:new{ w = middle_width, h = height },
            middle_content,
        },
        right,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = geometry.screen_width, h = height },
        footer,
    }
end

function ReaderView:_footerRegion()
    if not self.page or not self.page.geometry then return nil end
    local geometry = self.page.geometry
    return Geom:new{
        x = 0,
        y = geometry.screen_height - geometry.footer_height,
        w = geometry.screen_width,
        h = geometry.footer_height,
    }
end

function ReaderView:_schedulePrefetchFooterRefresh()
    if self._prefetch_footer_refresh_pending then return true end
    self._prefetch_footer_refresh_pending = true
    local callback = function()
        self._prefetch_footer_refresh_pending = false
        if self._closing or self.menu_visible or not self.page or not self.style.show_footer then return end
        if self._prefetch_footer_signature == self._prefetch_footer_rendered_signature then
            return
        end
        local region = self:_footerRegion()
        if not region then return end
        if self:isSwipeAnimationEnabled() and self.swipe_refresh
                and self.swipe_refresh:isRunning() then
            self._pending_rebuild = { refresh_type = "fast", refresh_region = region }
            return
        end
        self:rebuild("fast", region)
    end
    if type(UIManager.nextTick) == "function" then
        UIManager:nextTick(callback)
    else
        UIManager:scheduleIn(0.05, callback)
    end
    return true
end

function ReaderView:onPrefetchProgress(state)
    local previous_signature = self._prefetch_footer_signature
    self.prefetch_state = state
    self._prefetch_footer_signature = ReaderFooter:prefetchSignature(state)
    self._footer_dirty = true
    if self._closing or self.menu_visible or not self.page or not self.style.show_footer then return end
    if UIManager.isWidgetShown and not UIManager:isWidgetShown(self) then return end
    if self._prefetch_footer_signature == previous_signature then return end
    self:_schedulePrefetchFooterRefresh()
end

function ReaderView:buildReadingPage(page)
    local geometry = page.geometry
    local group = VerticalGroup:new{ align = "left" }
    table.insert(group, UI.vspace(geometry.body_top or geometry.top))

    if page.show_header then
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = geometry.screen_width, h = geometry.header_height },
            TextWidget:new{
                text = page.chapter_title or self.book.title,
                face = geometry.chrome_face,
                padding = 0,
                max_width = geometry.content_width,
            },
        })
    end

    -- [seam] leko-plus：段落标记位预加载（阶段③ T07）。
    -- 仅当书是 fanqie Provider 时尝试加载缓存索引；命中后 buildReadingPage
    -- 在该段首行额外渲染一个左对齐的小圆点提示。
    local review_index = self:_currentReviewIndex()

    for _, element in ipairs(page.elements) do
        if element.type == "title" then
            table.insert(group, UI.vspace(element.top_gap))
            table.insert(group, HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = geometry.left },
                LeftContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    TextBoxWidget:new{
                        text = element.text,
                        face = element.face,
                        bold = element.bold,
                        width = geometry.content_width,
                        height = element.height,
                        line_height = element.line_height or 0.18,
                        lang = "zh-CN",
                        alignment = "left",
                        alignment_strict = true,
                    },
                },
            })
            table.insert(group, UI.vspace(element.bottom_gap))
        elseif element.type == "gap" then
            table.insert(group, UI.vspace(element.height))
        elseif element.type == "line" then
            -- 段落标记渲染：仅当 paragraph_end=true（段首行）且 review 计数>0
            local show_marker = false
            if review_index and element.paragraph and element.paragraph_end then
                local count = tonumber(review_index[tostring(element.paragraph)]) or 0
                if count > 0 then show_marker = true end
            end
            local line_inner = LeftContainer:new{
                dimen = Geom:new{ w = geometry.content_width, h = element.height },
                TextWidget:new{
                    text = element.text,
                    face = geometry.body_face,
                    padding = 0,
                    line_height = self.style.line_spacing or 0.28,
                    lang = "zh-CN",
                    bold = false,
                },
            }
            if show_marker then
                -- 在段落首行左侧重叠一颗 6px 圆点（行首标记位）
                local marker_w = 14
                table.insert(group, HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = geometry.left - marker_w - 6 },
                    LeftContainer:new{
                        dimen = Geom:new{ w = marker_w, h = element.height },
                        CenterContainer:new{
                            dimen = Geom:new{ w = marker_w, h = element.height },
                            TextWidget:new{
                                text = "●",
                                face = geometry.body_face,
                                padding = 0,
                                bold = true,
                            },
                        },
                    },
                    line_inner,
                })
            else
                table.insert(group, HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = geometry.left },
                    line_inner,
                })
            end
        end
    end

    local remaining = geometry.content_height - page.used_height
    if remaining > 0 then table.insert(group, UI.vspace(remaining)) end

    -- Keep the reading margin above the status line, matching the original
    -- 0.15.39 reading geometry; the footer remains flush with the bottom edge.
    if self.style.show_footer then
        table.insert(group, UI.vspace(geometry.bottom))
        table.insert(group, self:buildFooterStatus(page, geometry))
    elseif geometry.footer_height > 0 then
        table.insert(group, UI.vspace(geometry.footer_height))
    end

    return FrameContainer:new{
        width = geometry.screen_width,
        height = geometry.screen_height,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
end

function ReaderView:buildMenuOverlay()
    local width, height = self.dimen.w, self.dimen.h
    local top_h, bottom_h = self:getMenuMetrics()
    local top = UI.header(width, top_h, {
        left_text = "‹ 书架",
        title = self.book.title or "阅读",
        right_text = "书籍详情",
        on_left = function() self:requestExit() end,
        on_right = function() self:showBookInfo() end,
        title_size = 21,
    })
    top.overlap_offset = { 0, 0 }

    local actions = UI.footer(width, bottom_h, {
        { text = "目录", bold = true, callback = function() self:showToc() end },
        { text = "上一章", callback = function() self:jumpChapter(-1) end },
        { text = "下一章", callback = function() self:jumpChapter(1) end },
        { text = "排版", callback = function() self:showLayoutMenu() end },
        { text = "刷新本章", font_size = 16, callback = function() self:reloadCurrentChapter() end },
    })
    local bottom = FrameContainer:new{
        width = width,
        height = bottom_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        overlap_offset = { 0, height - bottom_h },
        actions,
    }
    return top, bottom
end

function ReaderView:rebuild(refresh_type, refresh_region)
    -- The callback is not guaranteed to run after a dialog closes or a
    -- reflow reconstructs the ReaderView. Read the service-owned state at
    -- every visual rebuild so the native 0.15.47 footer cannot retain a stale
    -- cache bar when no new notification arrives.
    -- The cache window is established by setPage before the target page is
    -- built. Here we only recover the service-owned state for a redraw.
    self:_syncPrefetchState()
    -- The ordinary path must remain independent of transition state. This is
    -- especially important immediately after the user turns animation off:
    -- a stale visual coordinator flag must not turn a direct rebuild into a
    -- pending repaint.
    if self:isSwipeAnimationEnabled() and self.swipe_refresh
            and self.swipe_refresh:isRunning() then
        self._pending_rebuild = {
            refresh_type = refresh_type or "ui",
            refresh_region = refresh_region,
        }
        return false
    end
    local page_widget = self:buildReadingPage(self.page)
    if self.menu_visible then
        local top, bottom = self:buildMenuOverlay()
        self[1] = OverlapGroup:new{
            dimen = self.dimen:copy(),
            allow_mirroring = false,
            page_widget,
            top,
            bottom,
        }
    else
        self[1] = page_widget
    end
    UIManager:setDirty(self, refresh_type or "ui", refresh_region or self.dimen)
    return true
end

-- The transition callback means that Screen.bb now owns the submitted pixels;
-- it is not a physical E Ink waveform-complete notification.
function ReaderView:_finishSwipeSubmission()
    if self._closing or not self.page then return end
    self:_syncPrefetchState()
    local page_widget = self:buildReadingPage(self.page)
    if self.menu_visible then
        local top, bottom = self:buildMenuOverlay()
        self[1] = OverlapGroup:new{
            dimen = self.dimen:copy(),
            allow_mirroring = false,
            page_widget,
            top,
            bottom,
        }
    else
        self[1] = page_widget
    end
    local pending = self._pending_rebuild
    self._pending_rebuild = nil
    if pending then
        UIManager:setDirty(self, pending.refresh_type or "ui", pending.refresh_region or self.dimen)
    end
end

function ReaderView:_settleSwipeRefresh()
    return self.swipe_refresh and self.swipe_refresh:settle() or false
end

function ReaderView:_cancelSwipeRefresh()
    return self.swipe_refresh and self.swipe_refresh:cancel() or false
end

function ReaderView:isSwipeAnimationEnabled()
    return self.swipe_animation_enabled ~= false
end

function ReaderView:setSwipeAnimationEnabled(enabled)
    enabled = enabled == true
    self.swipe_animation_enabled = enabled
    self.style.page_transition_enabled = enabled
    Storage:saveReaderStyle(self.style)
    if not enabled and self.swipe_refresh and self.swipe_refresh:isRunning() then
        -- Disabling animation must not wait for the physical waveform.  Drop
        -- the visual transition and repaint the current logical page through
        -- the ordinary ReaderView path.
        self:_cancelSwipeRefresh()
        self._pending_rebuild = nil
        if self.page then self:rebuild("partial") end
    end
    if not self:_refreshLayoutToggle("page_animation_toggle",
            enabled and "动画效果：开" or "动画效果：关") then
        self:refreshLayoutMenu()
    end
    return enabled
end

function ReaderView:isChapterCleanWaveEnabled()
    return self.chapter_clean_wave_enabled ~= false
end

function ReaderView:setChapterCleanWaveEnabled(enabled)
    enabled = enabled == true
    self.chapter_clean_wave_enabled = enabled
    self.style.chapter_clean_wave_enabled = enabled
    Storage:saveReaderStyle(self.style)
    if not enabled and self.swipe_refresh
            and type(self.swipe_refresh.isWaveRunning) == "function"
            and self.swipe_refresh:isWaveRunning() then
        self:_cancelSwipeRefresh()
        if self.page then self:rebuild("partial") end
    end
    if not self:_refreshLayoutToggle("chapter_wave_toggle",
            enabled and "跨章净屏动画：开" or "跨章净屏动画：关") then
        self:refreshLayoutMenu()
    end
    return enabled
end

function ReaderView:_nextPageGeneration()
    self.page_generation = (self.page_generation or 0) + 1
    return self.page_generation
end

function ReaderView:isPageGenerationCurrent(generation)
    return generation == nil or generation == self.page_generation
end

function ReaderView:setPage(page, refresh_type, direction, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return false end
    local previous_chapter = self.page and self.page.chapter_index
    local chapter_changed = previous_chapter ~= nil and previous_chapter ~= page.chapter_index
    if not direction then self:_cancelSwipeRefresh() end
    self.page = page
    self._progress_dirty = true
    self._footer_dirty = true
    -- Kindle flash storage is intentionally not touched on page turns. Keep
    -- the exact cursor in memory and write it once when the reader closes.
    BookService:savePosition(self.book, page.start_position, false)
    -- Establish the cache window before constructing the target page. This
    -- lets the footer show the existing unfinished cached/total state on the
    -- first paint of a page turn, instead of waiting for a later event.
    BookService:requestPrefetch(self.book, page.chapter_index, BookService.prefetch_window)
    self:_syncPrefetchState()
    if direction and self:isSwipeAnimationEnabled() and self.swipe_refresh then
        self.menu_visible = false
        local target_widget = self:buildReadingPage(page)
        local begin_ok, started, begin_err = pcall(self.swipe_refresh.begin,
            self.swipe_refresh,
            target_widget,
            direction,
            function() self:_finishSwipeSubmission() end,
            {
                chapter_changed = chapter_changed,
                page_animation_enabled = self:isSwipeAnimationEnabled(),
                chapter_clean_wave_enabled = self:isChapterCleanWaveEnabled(),
            })
        if not begin_ok then
            begin_err = tostring(started)
            started = nil
            logger.warn("Leko transition backend failed; disabling it for this reader:", begin_err)
            pcall(self.swipe_refresh.cancel, self.swipe_refresh)
            self.swipe_refresh = nil
        end
        if not started then
            self:rebuild(refresh_type or "partial")
        end
    else
        if direction and self:isSwipeAnimationEnabled()
                and self.swipe_refresh and self.swipe_refresh:isRunning() then
            self:_cancelSwipeRefresh()
        end
        -- This is the 0.15.44/0.15.39 direct path.  No-animation turns do
        -- not consult, schedule or settle the transition coordinator.
        self:rebuild(refresh_type or "partial")
    end
    return true
end

function ReaderView:applyPreparedPosition(position, refresh_type, direction, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return true end
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then return nil, tostring(err or "章节分页失败") end
    self.menu_visible = false
    return self:setPage(page, refresh_type, direction, generation)
end

function ReaderView:loadPage(position, refresh_type, direction, generation)
    generation = generation or self:_nextPageGeneration()
    if not self:isPageGenerationCurrent(generation) then return true end
    local target_chapter = self.book.chapters and self.book.chapters[position.chapter]
    if not target_chapter then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = "章节不存在" })
        return nil, "章节不存在"
    end
    local on_disk = BookService:isChapterDownloaded(self.book, position.chapter)
    local needs_download = not on_disk and target_chapter.url
    if needs_download then
        if type(self.onPrepareChapter) ~= "function" then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = "这一章尚未下载，现在无法读取" })
            return nil, "异步章节读取器不可用"
        end
        local task, err = self.onPrepareChapter(self, position, refresh_type, {
            direction = direction,
            generation = generation,
        })
        if not task and err then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = tostring(err) })
        end
        return task
    end
    local ok, err = self:applyPreparedPosition(position, refresh_type, direction, generation)
    if not ok then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = tostring(err) })
    end
    return ok, err
end

function ReaderView:applyTocUpdate(updated_book, change)
    if type(updated_book) ~= "table" then return nil, "目录更新结果无效" end
    self:_settleSwipeRefresh()
    self:_nextPageGeneration()
    local previous = self.book
    local page = self.page
    local current_chapter = page and page.chapter_index
    local current_id = current_chapter and previous.chapters
        and previous.chapters[current_chapter] and previous.chapters[current_chapter].id
    local position = page and Util.positionCopy(page.start_position)
    self.book = updated_book
    BookService:clearBookCache(updated_book.id)
    local target_index
    if current_id then
        for index, chapter in ipairs(updated_book.chapters or {}) do
            if chapter.id == current_id then target_index = index; break end
        end
    end
    target_index = target_index or (updated_book.position and updated_book.position.chapter) or 1
    if position then
        local target = updated_book.chapters and updated_book.chapters[target_index]
        local same_chapter = current_chapter == target_index
            and (not current_id or (target and tostring(current_id) == tostring(target.id)))
        position.chapter = target_index
        position.chapter_id = target and target.id or nil
        if not same_chapter then
            position.paragraph = 1
            position.char = 1
        end
        local rebuilt = Paginator:makePage(updated_book, position, self.style)
        if rebuilt then
            self:setPage(rebuilt, "ui")
        end
    end
    return true
end

function ReaderView:reloadCurrentChapter()
    if self._closing or type(self.onPrepareChapter) ~= "function" or not self.page then return true end
    self:_settleSwipeRefresh()
    local generation = self:_nextPageGeneration()
    local position = Util.positionCopy(self.page.start_position)
    local task, err = self.onPrepareChapter(self, position, "full", {
        force_network = true,
        generation = generation,
        present = function(reader, updated_book, target_position, refresh_type)
            BookService:clearBookCache(updated_book.id)
            return reader:applyPreparedPosition(target_position, refresh_type, nil, generation)
        end,
    })
    if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
    return task or true
end

function ReaderView:nextPage()
    if self.page.at_end then
        self:_settleSwipeRefresh()
        if type(self.onRefreshToc) == "function" then
            local task, err = self.onRefreshToc(self, {})
            if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
        else
            UIManager:show(Notification:new{ text = "已经是最后一页" })
        end
        return true
    end
    table.insert(self.history, Util.positionCopy(self.page.start_position))
    local generation = self:_nextPageGeneration()
    self:loadPage(self.page.next_position, "partial", SwipeRefresh.FORWARD, generation)
    return true
end

function ReaderView:_showPreviousPage(target_position, refresh_type, generation)
    local page, err = Paginator:findPreviousPage(self.book, target_position, self.style)
    if not page then return nil, tostring(err or "已经是第一页") end
    self.menu_visible = false
    return self:setPage(page, refresh_type or "partial", SwipeRefresh.BACKWARD, generation)
end

function ReaderView:previousPage()
    local target = table.remove(self.history)
    if target then
        local generation = self:_nextPageGeneration()
        self:loadPage(target, "partial", SwipeRefresh.BACKWARD, generation)
        return true
    end

    local current = self.page.start_position
    local generation = self:_nextPageGeneration()
    local crosses_chapter = current.paragraph == 1 and current.char == 1 and current.chapter > 1
    local previous_chapter = crosses_chapter and (current.chapter - 1) or nil
    if previous_chapter and not BookService:isChapterDownloaded(self.book, previous_chapter) then
        if type(self.onPrepareChapter) ~= "function" then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = "上一章尚未下载，现在无法读取" })
            return true
        end
        local task, err = self.onPrepareChapter(self, {
            chapter = previous_chapter, paragraph = 1, char = 1,
        }, "partial", {
            direction = SwipeRefresh.BACKWARD,
            generation = generation,
            present = function(reader)
                return reader:_showPreviousPage(current, "partial", generation)
            end,
        })
        if not task and err then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = tostring(err) })
        end
        return true
    end

    local ok, err = self:_showPreviousPage(current, "partial", generation)
    if not ok then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = tostring(err) })
    end
    return true
end

function ReaderView:jumpToChapter(chapter_index)
    self:_settleSwipeRefresh()
    self.history = {}
    self.menu_visible = false
    local generation = self:_nextPageGeneration()
    self:loadPage({ chapter = chapter_index, paragraph = 1, char = 1 }, "full", nil, generation)
end

function ReaderView:jumpChapter(delta)
    local index = math.max(1, math.min(#(self.book.chapters or {}), (self.page.chapter_index or 1) + delta))
    if index == self.page.chapter_index then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = delta < 0 and "已经是第一章" or "已经是最后一章" })
        return true
    end
    self:jumpToChapter(index)
    return true
end

function ReaderView:showToc()
    self:_settleSwipeRefresh()
    self.menu_visible = false
    self:rebuild("ui")
    return UI.showLater(self, "toc", function()
        return TocView:new{
            book = self.book,
            current_chapter = self.page.chapter_index,
            onChapterSelected = function(chapter_index) self:jumpToChapter(chapter_index) end,
            on_return = function() self:_scheduleFooterRefresh(true) end,
        }
    end, "full")
end

function ReaderView:showBookInfo()
    self:_settleSwipeRefresh()
    self.menu_visible = false
    self:rebuild("ui")
    return UI.defer(self, "book_info", function()
        if self.onShowBookInfo then self.onShowBookInfo(self.book, self) end
    end)
end

function ReaderView:addToBookshelf()
    self:_settleSwipeRefresh()
    if Storage:isInLibrary(self.book.id) then UIManager:show(Notification:new{ text = "本书已在书架" }); return true end
    local book, err = BookService:addToBookshelf(self.book)
    if not book then UIManager:show(Notification:new{ text = "加入书架失败：" .. tostring(err) }); return true end
    self.book = book
    UIManager:show(Notification:new{ text = "已加入书架" })
    if self.onBookAdded then self.onBookAdded(book) end
    self:rebuild("ui")
    return true
end

function ReaderView:toggleMenu(force)
    self:_settleSwipeRefresh()
    self.menu_visible = force == nil and not self.menu_visible or force == true
    self:rebuild("ui")
    if not self.menu_visible then self:_scheduleFooterRefresh(true) end
    return true
end

function ReaderView:applyStyleChange(callback)
    self:_settleSwipeRefresh()
    callback(self.style)
    self.history = {}
    BookService:clearBookCache(self.book.id)
    local page, err = Paginator:makePage(self.book, self.page.start_position, self.style)
    self:consumeFontFallbackNotice()
    Storage:saveReaderStyle(self.style)
    if not page then UIManager:show(Notification:new{ text = tostring(err) }); return end
    self.page = page
    self._progress_dirty = true
    self._footer_dirty = true
    self.menu_visible = true
    -- Reflow changes only the in-memory cursor; the close path persists it.
    BookService:savePosition(self.book, page.start_position, false)
    self:rebuild("full")
    self:refreshLayoutMenu()
    self:_scheduleFooterRefresh(true)
end

function ReaderView:applyFontSelection(selection)
    if type(selection) ~= "table" then return end
    self:applyStyleChange(function(style)
        local path = selection.font_path or "cfont"
        local index = selection.face_index
        local display = selection.display_name or FontSelectionView.SYSTEM_DISPLAY_NAME
        style.body_font = path
        style.body_font_index = index
        style.body_font_display_name = display
        style.title_font = path
        style.title_font_index = index
        style.title_font_display_name = display
    end)
end

function ReaderView:_refreshLayoutToggle(id, text)
    local dialog = self._layout_dialog
    if not dialog then return false end

    -- ButtonDialog exposes the lookup itself on current KOReader releases;
    -- older hosts only expose the child ButtonTable.  Resolve either form so
    -- the callback can repaint the existing row immediately.
    local button
    if type(dialog.getButtonById) == "function" then
        local ok, found = pcall(dialog.getButtonById, dialog, id)
        if ok then button = found end
    end
    if not button then
        local button_table = dialog.buttontable or dialog.button_table
        if button_table and type(button_table.getButtonById) == "function" then
            local ok, found = pcall(button_table.getButtonById, button_table, id)
            if ok then button = found end
        end
    end
    if not button or type(button.setText) ~= "function" then return false end

    local ok = pcall(button.setText, button, text, button.width)
    if not ok then return false end

    -- Button:refresh() invalidates exactly the button's own label region.  It
    -- is important here: rebuilding the whole dialog from inside its click
    -- callback can leave the old button tree painted until a later UI event.
    if type(button.refresh) == "function" then
        local refreshed = pcall(button.refresh, button)
        if refreshed then return true end
    end

    local child = button[1]
    local region = child and child.dimen or button.dimen
    if child and child.dimen and type(UIManager.widgetRepaint) == "function" then
        pcall(UIManager.widgetRepaint, UIManager, child, child.dimen.x, button.dimen.y)
    end
    if region then UIManager:setDirty(nil, "ui", region) end
    return true
end

-- ButtonDialog materializes non-dynamic labels when it is constructed. For
-- layout changes, rebuild the open dialog on the next UI tick so a callback is
-- not rebuilding the dialog tree while that same button is still dispatching.
function ReaderView:refreshLayoutMenu()
    if not self._layout_dialog then return false end
    return UI.defer(self, "layout_menu_refresh", function()
        local dialog = self._layout_dialog
        if self._closing or not dialog then return end
        if type(dialog.reinit) == "function" then
            dialog.buttons = self:makeLayoutMenuButtons()
            dialog:reinit()
            -- ButtonDialog's geometry is recomputed by reinit().  Pass the
            -- concrete region; the callback-form setDirty used by newer
            -- widgets is not understood by every 0.15.x host.
            local region = dialog.movable and dialog.movable.dimen or dialog.dimen
            if region then UIManager:setDirty(dialog, "ui", region) end
            return
        end
        -- Compatibility fallback for an older host without ButtonDialog:reinit.
        self._layout_dialog = nil
        UIManager:close(dialog)
        self:showLayoutMenu()
        self:_scheduleFooterRefresh(true)
    end)
end

function ReaderView:makeLayoutMenuButtons()
    local line_values = { 0.12, 0.20, 0.28, 0.38, 0.50 }
    local line_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local margin_values = { 12, 20, 28, 36, 48 }
    local margin_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local paragraph_values = { 0, 6, 10, 16, 24 }
    local paragraph_labels = { "无", "0.25 行", "0.5 行", "0.75 行", "一行" }
    local font_values = { 18, 22, 27, 32, 38, 44 }
    local font_labels = { "很小", "小", "中", "大", "很大", "特大" }

    local function cycle(values, current)
        local closest = 1
        current = tonumber(current) or values[1]
        for index, value in ipairs(values) do
            if math.abs(value - current) < math.abs(values[closest] - current) then closest = index end
        end
        return values[(closest % #values) + 1]
    end

    local function choiceLabel(values, labels, current)
        local closest = 1
        current = tonumber(current) or values[1]
        for index, value in ipairs(values) do
            if math.abs(value - current) < math.abs(values[closest] - current) then closest = index end
        end
        return labels[closest]
    end

    local function apply(fn)
        self:applyStyleChange(fn)
    end

    local function close()
        local dialog = self._layout_dialog
        if dialog then UIManager:close(dialog) end
        self._layout_dialog = nil
        self:_scheduleFooterRefresh(true)
    end

    local function chooseFont()
        self:showFontSelection()
    end

    return {
        {
            { text = "字体", callback = chooseFont },
            { text = "字号：" .. choiceLabel(font_values, font_labels, self.style.body_font_size), callback = function() apply(function(s)
                s.body_font_size = cycle(font_values, s.body_font_size or 27)
            end) end },
        },
        {
            { text = self.style.indent == false and "首行缩进：关" or "首行缩进：开", callback = function() apply(function(s)
                s.indent = not (s.indent ~= false)
            end) end },
            { text = "行距：" .. choiceLabel(line_values, line_labels, self.style.line_spacing), callback = function() apply(function(s)
                s.line_spacing = cycle(line_values, s.line_spacing or 0.28)
            end) end },
        },
        {
            { text = "页边距：" .. choiceLabel(margin_values, margin_labels, self.style.margin_left), callback = function() apply(function(s)
                local margin = cycle(margin_values, s.margin_left or 28)
                s.margin_left, s.margin_right = margin, margin
            end) end },
            { text = "段间距：" .. choiceLabel(paragraph_values, paragraph_labels, self.style.paragraph_spacing), callback = function() apply(function(s)
                s.paragraph_spacing = cycle(paragraph_values, s.paragraph_spacing or 10)
            end) end },
        },
        {
            { text = self.style.show_header and "页眉：显示" or "页眉：隐藏", callback = function() apply(function(s)
                s.show_header = not s.show_header
            end) end },
            { text = self.style.show_footer and "页脚：显示" or "页脚：隐藏", callback = function() apply(function(s)
                s.show_footer = not s.show_footer
            end) end },
        },
        {
            { id = "page_animation_toggle", text = self:isSwipeAnimationEnabled() and "动画效果：开" or "动画效果：关", callback = function()
                self:setSwipeAnimationEnabled(not self:isSwipeAnimationEnabled())
            end },
            { id = "chapter_wave_toggle", text = self:isChapterCleanWaveEnabled() and "跨章净屏动画：开" or "跨章净屏动画：关", callback = function()
                self:setChapterCleanWaveEnabled(not self:isChapterCleanWaveEnabled())
            end },
        },
        { { text = "关闭", callback = close } },
    }
end

function ReaderView:showFontSelection()
    self:_settleSwipeRefresh()
    local dialog = self._layout_dialog
    if dialog then UIManager:close(dialog) end
    self._layout_dialog = nil
    self:_scheduleFooterRefresh(true)
    return UI.showLater(self, "font_selection", function()
        return FontSelectionView:new{
            style = self.style,
            on_selected = function(selection) self:applyFontSelection(selection) end,
            on_return = function()
                self:_scheduleFooterRefresh(true)
                if not self._closing then self:showLayoutMenu() end
            end,
        }
    end, "full")
end

function ReaderView:showLayoutMenu()
    self:_settleSwipeRefresh()
    if self._layout_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._layout_dialog) then return true end
        self._layout_dialog = nil
        self:_scheduleFooterRefresh(true)
    end
    return UI.showModalLater(self, "layout_menu", function()
        local dialog = ButtonDialog:new{
            title = "排版设置",
            modal = true,
            rows_per_page = 6,
            buttons = self:makeLayoutMenuButtons(),
            tap_close_callback = function()
                self._layout_dialog = nil
                self:_scheduleFooterRefresh(true)
            end,
        }
        self._layout_dialog = dialog
        return dialog
    end)
end

function ReaderView:routeTap(ges)
    local x = ges and ges.pos and ges.pos.x or self.dimen.w / 2
    local y = ges and ges.pos and ges.pos.y or self.dimen.h / 2
    if self.menu_visible then return self:toggleMenu(false) end
    -- [seam] leko-plus：段落标记点击分派（阶段③ T07）。
    -- 段落标记行首 24px 宽热区；命中后调用 onParaMarkerTap。
    if x <= 24 and self:_handleParaMarkerTap(x, y) then return true end
    if x < self.dimen.w * 0.27 then return self:previousPage() end
    if x > self.dimen.w * 0.73 then return self:nextPage() end
    return self:toggleMenu(true)
end

-- [seam] leko-plus：根据 y 坐标在当前 page 找出对应 paragraph_index，
-- 返回标记段落（或 nil）。page.elements[].type == 'line' 含 paragraph 字段
-- （Paginator 已经按段填充）；page 内 y 起点 = body_top（对齐 buildReadingPage）。
function ReaderView:_lookupParagraphAtY(y)
    if not self.page or not self.page.elements then return nil end
    local geometry = self.page.geometry or {}
    local top = geometry.body_top or geometry.top or 0
    local cursor = top
    local last_para = nil
    for _, element in ipairs(self.page.elements) do
        local height = tonumber(element.height) or 0
        if y < cursor + height and y >= cursor then
            if element.type == "line" and element.paragraph then
                return element.paragraph
            end
        end
        cursor = cursor + height
        if element.type == "line" and element.paragraph then
            last_para = element.paragraph
        end
    end
    return last_para  -- 命中空白时退回到最近前序段落
end

-- [seam] leko-plus：判断 y 处是否有段评标记；若有则打开弹窗并返回 true。
function ReaderView:_handleParaMarkerTap(x, y)
    if not self.book or not self.book.provider then return false end
    local para_index = self:_lookupParagraphAtY(y)
    if not para_index then return false end
    local provider_id = tostring(self.book.provider_source or self.book.provider)
    local FanqieReviewService = reviewService()
    if not FanqieReviewService:enabledFor(provider_id) then
        return self:onParaMarkerTap(provider_id, para_index, 0)
    end
    local cached = FanqieReviewService:cachedIndex(self.book.provider_book_id,
        self:_currentItemId())
    local count = 0
    if cached and type(cached.index) == "table" then
        count = tonumber(cached.index[tostring(para_index)]) or 0
    end
    -- 缓存未命中或 count=0 时尝试按需拉一次索引（不阻塞返回 false 让 routeTap 兜底）
    if (not cached or cached.expired) and (not self._review_index_pending) then
        self._review_index_pending = true
        FanqieReviewService:fetchIndex(provider_id, self.book.provider_book_id,
            self:_currentItemId(), function()
                self._review_index_pending = nil
            end)
        if count == 0 then return false end
    end
    return self:onParaMarkerTap(provider_id, para_index, count)
end

-- [seam] leko-plus：当前章节的 provider item_id（Paginator 起始位置决定）。
function ReaderView:_currentItemId()
    if not self.book or not self.book.chapters then return nil end
    local ch = self.page and self.page.start_position and self.page.start_position.chapter
    ch = tonumber(ch) or 1
    local chapter = self.book.chapters[ch]
    return chapter and chapter.id or nil
end

-- [seam] leko-plus：当前章节的段评索引缓存。Provider 不支持段评 / 当前书
-- 非 provider 书 / 缓存空 -> 返回 nil；命中后 buildReadingPage 据此渲染。
-- 章节切换时（item_id 变化）自动触发后台 fetchIndex 增量刷新。
function ReaderView:_currentReviewIndex()
    if not self.book or not self.book.provider then return nil end
    local provider_id = tostring(self.book.provider_source or self.book.provider)
    local item_id = self:_currentItemId()
    if not item_id then return nil end
    local FanqieReviewService = reviewService()
    if not FanqieReviewService:enabledFor(provider_id) then return nil end
    local cached = FanqieReviewService:cachedIndex(self.book.provider_book_id, item_id)
    if cached and not cached.expired then return cached.index end
    if cached and not self._review_index_pending then
        self._review_index_pending = true
        FanqieReviewService:fetchIndex(provider_id, self.book.provider_book_id, item_id,
            function() self._review_index_pending = nil end)
    end
    return cached and cached.index or nil
end

-- [seam] leko-plus：段落标记点击的实际分派（弹窗或"该源不支持段评"提示）。
function ReaderView:onParaMarkerTap(provider_id, para_index, count)
    local provider_id = tostring(provider_id or "")
    local para_index = math.max(1, tonumber(para_index) or 1)
    local count = tonumber(count) or 0
    local FanqieReviewService = reviewService()
    if not FanqieReviewService:enabledFor(provider_id) then
        -- 不支持段评的源：明确提示，避免产生静默点击无效果（PRD P0-4④）。
        local ReviewDialog = require("Leko/Fanqie/ReviewDialog")
        return ReviewDialog:showUnsupported({})
    end
    if count <= 0 then
        UIManager:show(Notification:new{ text = "本段落暂无评论" })
        return true
    end
    local ReviewDialog = require("Leko/Fanqie/ReviewDialog")
    ReviewDialog:show({
        provider_id = provider_id,
        provider_book_id = self.book.provider_book_id,
        item_id = self:_currentItemId(),
        para_index = para_index,
        total_count = count,
        on_close = function() UIManager:setDirty(self, "partial") end,
    })
    return true
end

function ReaderView:routeSwipe(ges)
    if self.menu_visible then return self:toggleMenu(false) end
    local direction = ges and ges.direction
    if direction == "west" then return self:nextPage() end
    if direction == "east" then return self:previousPage() end
    if direction == "north" or direction == "south" then return self:toggleMenu(true) end
    return true
end

function ReaderView:onTap(_, ges) return self:routeTap(ges) end
function ReaderView:onHold() return self:toggleMenu(true) end
function ReaderView:onSwipe(_, ges) return self:routeSwipe(ges) end
function ReaderView:onReaderMenu() return self:toggleMenu() end
function ReaderView:onPageForward() return self:nextPage() end
function ReaderView:onPageBackward() return self:previousPage() end

function ReaderView:onFlushSettings()
    if self.page and self._progress_dirty then
        local pos = self.page.start_position or {}
        local saved = BookService:savePosition(self.book, pos, true)
        if saved ~= false then
            self._progress_dirty = false
        else
            self._progress_dirty = true
        end
    end
end

function ReaderView:onSuspend()
    self:_settleSwipeRefresh()
    -- Power/suspend is the other safe persistence boundary. Do not write on
    -- every page turn; save the latest in-memory cursor before sleep.
    self:onFlushSettings()
end

-- Rotation actions are dispatched by the host before the screen geometry is
-- rebuilt.  Settle any old-dimension strip callback first.
function ReaderView:onIterateRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onSwapRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onInvertRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:closeReaderNow()
    if self._closing then return true end
    self._closing = true
    self:_cancelSwipeRefresh()
    if self._exit_dialog then UIManager:close(self._exit_dialog); self._exit_dialog = nil end
    if self._layout_dialog then UIManager:close(self._layout_dialog); self._layout_dialog = nil end

    BookService:cancelPrefetch(self.book.id)
    BookService:unobservePrefetch(self.book.id, self)
    self:onFlushSettings()

    -- Rebuild the covered bookshelf before removing the reader. UIManager will
    -- then reveal it with a single full refresh instead of repainting it twice.
    if self.onBeforeReaderClose then self.onBeforeReaderClose(self.book) end

    local book_id = self.book.id
    self.history = {}
    self.prefetch_state = nil
    self.page = nil
    self[1] = nil
    UIManager:close(self, "full")

    BookService:clearBookCache(book_id)
    BookService:releaseRuntimeSource(book_id)
    if self.onReaderClosed then self.onReaderClosed(self.book) end

    -- Incremental GC avoids a long synchronous pause on older Kindles.
    for step = 1, 4 do
        UIManager:scheduleIn(step * 0.12, function() collectgarbage("step", 180) end)
    end
    return true
end

function ReaderView:requestExit()
    if Storage:isInLibrary(self.book.id) then return self:closeReaderNow() end
    self:_settleSwipeRefresh()
    if self._exit_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._exit_dialog) then return true end
        self._exit_dialog = nil
    end
    return UI.showModalLater(self, "exit_dialog", function()
        local dialog
        dialog = ButtonDialog:new{
            modal = true,
            title = "退出试读",
            buttons = {
                {
                    { text = "加入书架并退出", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil
                        self:addToBookshelf(); self:closeReaderNow()
                    end },
                },
                {
                    { text = "仅退出", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil; self:closeReaderNow()
                    end },
                    { text = "继续阅读", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil
                    end },
                },
            },
            tap_close_callback = function() self._exit_dialog = nil end,
        }
        self._exit_dialog = dialog
        return dialog
    end)
end

function ReaderView:onClose()
    if self.menu_visible then return self:toggleMenu(false) end
    -- [seam] leko-plus：番茄书关闭前异步 flush 云端进度（不阻塞退出）。
    if self.book and self.book.provider then
        pcall(function()
            require("Leko/Fanqie/ProgressSync"):flushOnExit(self.book)
        end)
    end
    return self:requestExit()
end
function ReaderView:onCloseWidget()
    self:_cancelSwipeRefresh()
    self:onFlushSettings()
end

return ReaderView
