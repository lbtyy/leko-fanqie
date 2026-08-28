local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local CoverLoadController = require("Leko/CoverLoadController")
local CoverPrefetch = require("Leko/CoverPrefetch")
local CoverService = require("Leko/CoverService")
local UI = require("Leko/UI")
local SearchCandidateContext = require("Leko/SearchCandidateContext")

local CoverBrowserView = InputContainer:extend{
    covers_fullscreen = true,
    modal = false,
    max_results = nil,
}

local function resultKey(result)
    local source_id = tostring(result and result.source_id or "")
    local book_url = tostring(result and result.book_url or "")
    if source_id ~= "" or book_url ~= "" then return source_id .. "\n" .. book_url end
    return "cover\n" .. tostring(result and result.cover or "")
end

local function mergeResolvedResult(target, resolved)
    if type(target) ~= "table" or type(resolved) ~= "table" then return end
    for _, key in ipairs({
        "title", "author", "book_url", "toc_url", "cover", "source_id", "source_name",
        "variables", "_cover_source", "_source_runtime",
    }) do
        if resolved[key] ~= nil then target[key] = resolved[key] end
    end
    target.needs_cover_detail = nil
end

function CoverBrowserView:init()
    self.results = self.results or {}
    self._seen = {}
    self._failed = {}
    self._ready = {}
    self.failed_count = tonumber(self.failed_count or 0) or 0
    self.ready_count = tonumber(self.ready_count or 0) or 0
    self.discovered_count = tonumber(self.discovered_count or #self.results) or #self.results
    self.overflow_count = tonumber(self.overflow_count or 0) or 0
    for _, result in ipairs(self.results) do self._seen[resultKey(result)] = true end
    if #self.results == 0 then
        self.index = 0
    else
        self.index = math.max(1, math.min(#self.results, tonumber(self.index or 1) or 1))
    end
    self.searching = self.searching ~= false
    self.prefetch_state = CoverPrefetch:newState()
    self._scheduled = {}
    self._result_refresh = nil
    self.cover_loader = CoverLoadController:new{
        owner = self,
        on_foreground_start = function()
            if self.onForegroundFetchStart then pcall(self.onForegroundFetchStart) end
        end,
        on_foreground_done = function()
            if not self._closing and self.onForegroundFetchDone then pcall(self.onForegroundFetchDone) end
        end,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { "Back" }, { "Esc" } } end
    self:rebuild()
    if #self.results > 0 then self:loadWindow() end
end

function CoverBrowserView:current()
    return self.index > 0 and self.results[self.index] or nil
end

function CoverBrowserView:markReady(result)
    local key = resultKey(result)
    if not self._ready[key] then
        self._ready[key] = true
        self.ready_count = self.ready_count + 1
    end
end

function CoverBrowserView:getDiagnosticsText()
    return "本次封面换源：找到 " .. tostring(self.discovered_count or #self.results)
        .. " 个结果；可用 " .. tostring(self.ready_count or 0)
        .. "；已跳过 " .. tostring(self.failed_count or 0)
        .. (tonumber(self.overflow_count or 0) > 0
            and ("；另有 " .. tostring(self.overflow_count) .. " 个没有显示") or "")
        .. "\n\n下面是以往累计的封面下载情况，不只包含这一次搜索：\n"
        .. CoverService:getStatsText()
end

function CoverBrowserView:isCurrentReady()
    local result = self:current()
    if not result then return false end
    local cover_w, cover_h = self:coverDimensions()
    -- Selection is enabled only after the image is actually visible. This
    -- guarantees applying a cover is a memory hit and never starts a network
    -- request from the confirmation button.
    return CoverService:getMemory(result, cover_w - 8, cover_h - 8) ~= nil
end

function CoverBrowserView:coverDimensions()
    local height = self.dimen.h
    local header_h = math.max(54, math.floor(height * 0.075))
    local footer_h = math.max(64, math.floor(height * 0.09))
    local body_h = height - header_h - footer_h
    local cover_h = math.min(520, math.max(180, math.floor(body_h * 0.70)))
    local cover_w = math.min(360, math.floor(self.dimen.w * 0.58), math.floor(cover_h * 0.70))
    return cover_w, cover_h
end

function CoverBrowserView:coverBox(width, height)
    local result = self:current()
    local image = result and CoverService:getMemory(result, width - 8, height - 8)
    local content
    if image then
        content = ImageWidget:new{
            image = image,
            image_disposable = false,
            width = width - 8,
            height = height - 8,
            scale_factor = 0,
        }
    else
        content = TextBoxWidget:new{
            text = self.loading_text or (self.searching and "正在后台搜索同书封面…" or "没有可用封面"),
            width = width - 24,
            alignment = "center",
            face = Font:getFace("smallinfofont", 19),
        }
    end
    return FrameContainer:new{
        width = width, height = height, padding = 3, bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = width - 8, h = height - 8 }, content },
    }
end

function CoverBrowserView:rebuild()
    local width, height = self.dimen.w, self.dimen.h
    local header_h = math.max(54, math.floor(height * 0.075))
    local footer_h = math.max(64, math.floor(height * 0.09))
    local result = self:current()
    local cover_w, cover_h = self:coverDimensions()
    local count_text = #self.results > 0 and string.format(" %d/%d", self.index, #self.results) or " 0/0"
    local header = UI.header(width, header_h, {
        left_text = "‹ 返回", title = (self.title or "封面") .. count_text,
        right_text = "加载情况 ›", on_left = function() self:onClose() end,
        on_right = function() UIManager:show(InfoMessage:new{ text = self:getDiagnosticsText() }) end,
    })
    local metadata
    if result then
        metadata = (result.provider and "〔番〕" or "") .. (result.title or "未命名")
            .. "\n" .. ((result.author and result.author ~= "") and result.author or "佚名")
            .. "\n" .. tostring(result.provider_name or result.source_name or "")
            .. (result.is_current_cover and " · 当前封面源" or "")
            .. (result.author_mismatch and " · 作者标注不同" or "")
    else
        metadata = "找到封面后会立即显示，不必等待全部书源完成。"
    end
    metadata = metadata .. "\n\n本次：发现 " .. tostring(self.discovered_count or #self.results)
        .. " · 可用 " .. tostring(self.ready_count or 0)
        .. " · 跳过 " .. tostring(self.failed_count or 0)
    if self.searching then
        metadata = metadata .. "\n" .. tostring(self.search_stage or "剩余书源正在后台搜索")
            .. string.format("（%d/%d）", tonumber(self.scanned or 0) or 0, tonumber(self.total_sources or 0) or 0)
    end
    if tonumber(self.overflow_count or 0) > 0 then
        metadata = metadata .. "\n另有 " .. tostring(self.overflow_count) .. " 个结果没有显示"
    end
    if self.error_text then metadata = metadata .. "\n" .. self.error_text end
    local body = VerticalGroup:new{
        UI.vspace(8),
        self:coverBox(cover_w, cover_h),
        UI.vspace(8),
        TextBoxWidget:new{
            text = metadata, width = math.max(100, width - 30), alignment = "center",
            face = Font:getFace("smallinfofont", 19),
        },
    }
    local primary_text = self.onSelectCover and (self.select_text or "使用此封面") or "打开详情"
    local footer = UI.footer(width, footer_h, {
        { text = "‹ 上一张", enabled = self.index > 1, callback = function() self:move(-1) end },
        { text = primary_text, bold = true, enabled = self:isCurrentReady(), callback = function()
            if not result then return end
            if self.onBeforeSelect then pcall(self.onBeforeSelect) end
            local resolved, err = SearchCandidateContext:hydrate(result)
            if not resolved then
                UIManager:show(InfoMessage:new{ text = "无法打开这个封面结果：\n" .. tostring(err) })
                return
            end
            if self.onSelectCover then self.onSelectCover(resolved)
            elseif self.onOpenResult then self.onOpenResult(resolved, true) end
        end },
        { text = "下一张 ›", enabled = self.index > 0 and self.index < #self.results, callback = function() self:move(1) end },
    })
    local old_screen = self[1]
    self[1] = UI.screen(width, height, header, body, footer, header_h, footer_h)
    if old_screen and old_screen ~= self[1] and type(old_screen.free) == "function" then
        pcall(old_screen.free, old_screen)
    end
    UIManager:setDirty(self, "ui", self.dimen)
end

function CoverBrowserView:_scheduleResultRefresh()
    if self._result_refresh then return end
    local callback
    callback = function()
        self._result_refresh = nil
        self:rebuild()
    end
    self._result_refresh = callback
    UIManager:scheduleIn(0.8, callback)
end

function CoverBrowserView:appendResults(batch)
    local before = #self.results
    local first_added = false
    for _, result in ipairs(batch or {}) do
        if self.max_results and #self.results >= self.max_results then break end
        local key = resultKey(result)
        if key ~= "\n" and key ~= "cover\n" and not self._seen[key] and not self._failed[key] then
            self._seen[key] = true
            self.results[#self.results + 1] = result
            self.discovered_count = math.max(tonumber(self.discovered_count or 0) or 0, #self.results)
            if self.index == 0 then self.index = 1; first_added = true end
        end
    end
    if first_added then
        -- The first match is painted immediately. Later arrivals are coalesced
        -- so a long source search does not repeatedly rebuild ImageWidget trees.
        self.loading_text, self.error_text = "正在后台读取第一张封面…", nil
        self:rebuild()
        self:loadWindow()
    elseif #self.results > before then
        self:_scheduleResultRefresh()
    end
end

function CoverBrowserView:setSearchProgress(scanned, total, stage, done, discovered_count, overflow_count)
    self.scanned = tonumber(scanned or self.scanned or 0) or 0
    self.total_sources = tonumber(total or self.total_sources or 0) or 0
    self.search_stage = stage or self.search_stage
    self.discovered_count = tonumber(discovered_count or self.discovered_count or #self.results) or #self.results
    self.overflow_count = tonumber(overflow_count or self.overflow_count or 0) or 0
    if done then self.searching = false end
    -- Rebuilding an ImageWidget for every completed source causes needless
    -- allocations and E Ink refreshes. Results themselves still repaint at once.
    local last = tonumber(self._last_progress_paint or -10) or -10
    if done or self.scanned == 0 or self.scanned - last >= 10 then
        self._last_progress_paint = self.scanned
        self:rebuild()
    end
    if done and #self.results > 0 and self.cover_loader and not self.cover_loader:isBusy() then
        self:loadWindow()
    end
end

function CoverBrowserView:cancelScheduled()
    for _, callback in ipairs(self._scheduled or {}) do pcall(UIManager.unschedule, UIManager, callback) end
    self._scheduled = {}
    if self._result_refresh then
        pcall(UIManager.unschedule, UIManager, self._result_refresh)
        self._result_refresh = nil
    end
end

function CoverBrowserView:cancelCoverWorker()
    if self.cover_loader then self.cover_loader:cancel() end
end

function CoverBrowserView:dropFailedResult(index, err)
    local result = self.results[index]
    if not result then return end
    local key = resultKey(result)
    self._failed[key] = tostring(err or "封面不可用")
    self.failed_count = self.failed_count + 1
    SearchCandidateContext:cleanup(result)
    table.remove(self.results, index)
    if #self.results == 0 then
        self.index = 0
        self.loading_text = self.searching and "继续后台寻找可用封面…" or "没有找到可用封面"
        self.error_text = nil
        self:rebuild()
        return
    end
    self.index = math.max(1, math.min(index, #self.results))
    self.loading_text = "正在尝试下一张有效封面…"
    self.error_text = nil
    self:rebuild()
    self:loadWindow()
end

function CoverBrowserView:loadWindow()
    self:cancelScheduled()
    self:cancelCoverWorker()
    if #self.results == 0 or self.index == 0 or not self.cover_loader then return end
    local generation = CoverPrefetch:bump(self.prefetch_state)
    local index = self.index
    local result = self.results[index]
    local callback
    callback = function()
        if self._closing or not CoverPrefetch:isCurrent(self.prefetch_state, generation)
                or self.results[index] ~= result then return end
        local cover_w, cover_h = self:coverDimensions()
        local fetch_result, context_err = SearchCandidateContext:hydrate(result)
        if not fetch_result then
            self:dropFailedResult(index, context_err)
            return
        end
        self.cover_loader:load{
            result = fetch_result,
            width = cover_w - 8,
            height = cover_h - 8,
            is_current = function()
                return not self._closing
                    and CoverPrefetch:isCurrent(self.prefetch_state, generation)
                    and self.results[index] == result
                    and self.index == index
            end,
            on_resolved = function(resolved)
                mergeResolvedResult(result, resolved)
                self._seen[resultKey(result)] = true
            end,
            on_ready = function()
                self:markReady(result)
                self.loading_text, self.error_text = nil, nil
                self:rebuild()
            end,
            on_failure = function(err)
                self:dropFailedResult(index, err)
            end,
        }
    end
    self._scheduled[#self._scheduled + 1] = callback
    UIManager:scheduleIn(0.12, callback)
end

function CoverBrowserView:move(delta)
    if #self.results == 0 then return true end
    local target = math.max(1, math.min(#self.results, self.index + delta))
    if target == self.index then return true end
    self.index, self.loading_text, self.error_text = target, "正在后台读取封面…", nil
    self:rebuild()
    self:loadWindow()
    return true
end

function CoverBrowserView:onClose()
    self._closing = true
    self:cancelScheduled()
    if self.cover_loader then self.cover_loader:close(); self.cover_loader = nil end
    CoverPrefetch:bump(self.prefetch_state)
    if self.onCancelSearch then pcall(self.onCancelSearch) end
    CoverService:releaseRuntimeSources()
    CoverService:clearMemory()
    SearchCandidateContext:cleanupBatch(self.results)
    self.results, self._seen, self._failed, self._ready = {}, {}, {}, {}
    collectgarbage("step", 160)
    UIManager:close(self, "full")
    return true
end

function CoverBrowserView:onCloseWidget()
    self._closing = true
    self:cancelScheduled()
    if self.cover_loader then self.cover_loader:close(); self.cover_loader = nil end
    CoverPrefetch:bump(self.prefetch_state)
    if self.onCancelSearch then pcall(self.onCancelSearch) end
    CoverService:releaseRuntimeSources()
    CoverService:clearMemory()
    SearchCandidateContext:cleanupBatch(self.results)
    self.results, self._seen, self._failed, self._ready = {}, {}, {}, {}
    collectgarbage("step", 160)
end

return CoverBrowserView
