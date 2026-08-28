local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local SearchCandidateContext = require("Leko/SearchCandidateContext")
local SourceResultActions = require("Leko/SourceResultActions")

local StreamingResultList = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    modal = false,
    max_results = nil,
}

function StreamingResultList:resultKey(result)
    return tostring(result and result.title or "") .. "\n"
        .. tostring(result and result.author or "") .. "\n"
        .. tostring(result and result.source_id or "") .. "\n"
        .. tostring(result and result.book_url or "")
end

function StreamingResultList:_initializeResults()
    self.results = self.results or {}
    self._seen = {}
    for _, result in ipairs(self.results) do self._seen[self:resultKey(result)] = true end
    self.searching = self.searching ~= false
    self._result_refresh = nil
    self._arrival_sequence = tonumber(self._arrival_sequence or #self.results) or #self.results
    for index, result in ipairs(self.results) do result._arrival_order = result._arrival_order or index end
    self.discovered_count = tonumber(self.discovered_count or #self.results) or #self.results
end

function StreamingResultList:_installMenuCallbacks()
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.onMenuSelect = function(menu, item)
        if item.result and not item.dim then
            menu:onResultSelected(item.result, item)
        end
    end
    self.onMenuHold = function(menu, item)
        if item.result and not item.dim and type(menu.onResultHeld) == "function" then
            return menu:onResultHeld(item.result, item)
        end
    end
    self.close_callback = function() self:onReturn() end
end

function StreamingResultList:init()
    self:_initializeResults()
    self:_installMenuCallbacks()
    -- Menu:updateItems relies on geometry created by Menu.init. Build the
    -- initial table first, but never ask an inherited update method to repaint
    -- an object whose widget tree does not exist yet.
    self._initializing_menu = true
    if self.refreshItems then self:refreshItems() end
    self._initializing_menu = false
    Menu.init(self)
end

function StreamingResultList:onResultSelected(result)
    if self.onSelectResult then self.onSelectResult(result) end
end

function StreamingResultList:showSourceResultActions(result, options)
    return SourceResultActions:show(self, result, options)
end

function StreamingResultList:_scheduleResultRefresh(delay)
    if self.foreground_loading or self._result_refresh then return end
    local callback
    callback = function()
        self._result_refresh = nil
        if self.refreshItems then self:refreshItems() end
    end
    self._result_refresh = callback
    UIManager:scheduleIn(tonumber(delay or 1.0) or 1.0, callback)
end

function StreamingResultList:_cancelPendingRefresh()
    if self._result_refresh then
        pcall(UIManager.unschedule, UIManager, self._result_refresh)
        self._result_refresh = nil
    end
end

function StreamingResultList:appendResults(batch)
    local before = #self.results
    for _, result in ipairs(batch or {}) do
        if self.max_results and #self.results >= self.max_results then break end
        local key = self:resultKey(result)
        if key ~= "\n\n\n" and key ~= "\n" and not self._seen[key] then
            self._seen[key] = true
            self._arrival_sequence = (self._arrival_sequence or 0) + 1
            result._arrival_order = self._arrival_sequence
            self.results[#self.results + 1] = result
        end
    end
    if #self.results == before then return false end
    self._results_dirty = true
    if self.foreground_loading then return true end
    if before <= tonumber(self.immediate_refresh_threshold or 0) then self:refreshItems()
    else self:_scheduleResultRefresh(self.refresh_delay or 1.0) end
    return true
end

function StreamingResultList:releaseResults()
    self:_cancelPendingRefresh()
    SearchCandidateContext:cleanupBatch(self.results)
    self.results = {}
    self._seen = {}
    self.item_table = {}
    self._results_dirty = false
    collectgarbage("step", 160)
end

-- Keep a result list alive while a selected book is being inspected/read. The
-- list may be closed by UIManager during the transition, but its candidate
-- sidecars remain available until the user explicitly leaves the list.
function StreamingResultList:prepareForReturn()
    self._preserve_for_return = true
    self.searching = false
    self:_cancelPendingRefresh()
    if not self._return_search_cancelled and self.onCancelSearch then
        pcall(self.onCancelSearch)
        self._return_search_cancelled = true
    end
    return self
end

function StreamingResultList:onReturn()
    if self.cancelBookOperation then pcall(self.cancelBookOperation, self) end
    if not self._return_search_cancelled and self.onCancelSearch then pcall(self.onCancelSearch) end
    self._preserve_for_return = false
    self._return_search_cancelled = false
    self:releaseResults()
    if not UIManager.isWidgetShown or UIManager:isWidgetShown(self) then
        UIManager:close(self, "full")
    end
    return true
end

function StreamingResultList:onCloseWidget()
    self:_cancelPendingRefresh()
    if not self._return_search_cancelled and self.onCancelSearch then pcall(self.onCancelSearch) end
    if self._preserve_for_return then return end
    -- Candidate execution contexts may have been spilled to tmp sidecars on
    -- low-memory devices. A widget can be closed programmatically without
    -- going through onReturn(), so clean them here as well.
    SearchCandidateContext:cleanupBatch(self.results)
end

return StreamingResultList
