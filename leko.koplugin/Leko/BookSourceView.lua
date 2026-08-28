local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local SearchResultFormatter = require("Leko/SearchResultFormatter")
local StreamingResultList = require("Leko/StreamingResultList")
local SearchCandidateContext = require("Leko/SearchCandidateContext")

local BookSourceView = StreamingResultList:extend{
    -- Current source row plus a bounded set of lightweight alternate candidates.
    max_results = nil,
    -- Alternate content sources are scarce and immediately actionable. Show
    -- every arrival instead of holding the second or later candidate behind
    -- the generic one-second list coalescer.
    immediate_refresh_threshold = math.huge,
    immediate_progress_count = 8,
}

function BookSourceView:resultKey(result)
    return tostring(result and result.source_id or "") .. "\n"
        .. tostring(result and result.book_url or "")
end

function BookSourceView:isCurrent(result)
    return tostring(result and result.source_id or "") == tostring(self.current_source_id or "")
        and tostring(result and result.book_url or "") == tostring(self.current_book_url or "")
end

function BookSourceView:buildItems()
    local items = {}
    local count = #(self.results or {})
    if self.searching then
        items[#items + 1] = {
            text = SearchResultFormatter:progressText(self.scanned, self.total_sources, count),
            dim = true,
        }
    end
    for _, result in ipairs(self.results or {}) do
        local current = self:isCurrent(result)
        local formatted = SearchResultFormatter:bookItem(result, {
            mode = "content",
            current = current,
            fallback_title = self.book_title,
            fallback_author = self.book_author,
        })
        formatted.result = result
        formatted.bold = current
        formatted.dim = current
        items[#items + 1] = formatted
    end
    if not self.searching and count == 0 then
        items[1] = { text = "没有找到可用的同名内容源", dim = true }
    end
    return items
end

function BookSourceView:_sortResultsIfNeeded()
    if not self._results_dirty then return end
    table.sort(self.results, function(left, right)
        local left_current, right_current = self:isCurrent(left), self:isCurrent(right)
        if left_current ~= right_current then return left_current end
        -- Keep alternate sources in arrival order. The current source remains
        -- pinned for orientation, but a late result must not reorder the rest
        -- of the list by a changing health/priority score.
        return tonumber(left._arrival_order or 0) < tonumber(right._arrival_order or 0)
    end)
    self._results_dirty = false
end

function BookSourceView:refreshItems()
    self:_sortResultsIfNeeded()
    self.title = "书籍换源 · " .. tostring(self.book_title or "当前书籍") .. " · "
        .. tostring(#(self.results or {})) .. " 个源"
    self.item_table = self:buildItems()
    if not self._initializing_menu and self.updateItems then self:updateItems() end
end

function BookSourceView:onResultSelected(result)
    local resolved, err = SearchCandidateContext:hydrate(result)
    if not resolved then
        UIManager:show(InfoMessage:new{ text = "无法打开这个换源结果：\n" .. tostring(err) })
        return true
    end
    if self.onSelectSource then self.onSelectSource(resolved) end
end

function BookSourceView:onResultHeld(result)
    return self:showSourceResultActions(result, {
        primary_text = "使用此内容源",
        primary_callback = function(candidate) self:onResultSelected(candidate) end,
        on_toggled = function(candidate, enabled)
            if self.onSourceToggled then self.onSourceToggled(candidate, enabled) end
        end,
        on_priority_changed = function(candidate)
            if self.onSourcePriorityChanged then self.onSourcePriorityChanged(candidate) end
        end,
    })
end

function BookSourceView:setSearchProgress(scanned, total, stage, done, details, discovered_count, overflow_count)
    if type(details) ~= "table" then
        details = {
            error_count = details,
            discovered_count = discovered_count,
            overflow_count = overflow_count,
        }
    end
    self.scanned = tonumber(scanned or self.scanned or 0) or 0
    self.total_sources = tonumber(total or self.total_sources or 0) or 0
    self.search_stage = stage or self.search_stage
    self.discovered_count = tonumber(details.discovered_count
        or self.discovered_count or #self.results) or #self.results
    self.overflow_count = tonumber(details.overflow_count or self.overflow_count or 0) or 0
    self.search_error_count = tonumber(details.error_count or self.search_error_count or 0) or 0
    if done then self.searching = false end
    local immediate_count = tonumber(self.immediate_progress_count or 8) or 8
    local last = tonumber(self._last_progress_paint or -8) or -8
    if done or self.scanned == 0 or self.scanned <= immediate_count
            or self.scanned - last >= 8 then
        self._last_progress_paint = self.scanned
        self:_cancelPendingRefresh()
        self:refreshItems()
    end
end

function BookSourceView:onCloseWidget()
    StreamingResultList.onCloseWidget(self)
end

return BookSourceView
