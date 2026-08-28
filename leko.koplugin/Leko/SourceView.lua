local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local SourceManagementController = require("Leko/SourceManagementController")
local SourceHealth = require("Leko/SourceHealth")
local SourceDiagnosticLog = require("Leko/SourceDiagnosticLog")
local Storage = require("Leko/Storage")
local SourcePreference = require("Leko/SourcePreference")
local UI = require("Leko/UI")
local SourceStatus = require("Leko/SourceStatus")
local QuickJSRuntimeCheck = require("Leko/QuickJSRuntimeCheck")

local SourceView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    modal = false,
}

local function executableSources(sources)
    local result = {}
    for _, source in ipairs(sources or {}) do
        if source.enabled ~= false and source.searchable ~= false and source.has_search_url == true then
            result[#result + 1] = source
        end
    end
    return result
end

local function connectivitySummary(sources, health_map)
    local online, offline, unknown = 0, 0, 0
    for _, source in ipairs(executableSources(sources)) do
        local record = health_map[tostring(source.id)]
        local decision = SourceHealth:cachedDecision(source, nil, health_map)
        if decision == true then online = online + 1
        elseif decision == false then offline = offline + 1
        else unknown = unknown + 1 end
    end
    return online, offline, unknown
end

function SourceView:buildItems()
    local sources, catalog_err = Storage:listSourceSummaries()
    if not sources then
        return {
            { text = "正在准备书源…", mandatory = tostring(catalog_err or "首次打开需要一点时间"), dim = true },
        }
    end
    sources = SourcePreference:sortSummaries(sources)
    local stats = { total = 0, enabled = 0, supported = 0, unsupported = 0, capabilities = {} }
    for _, source in ipairs(sources) do
        stats.total = stats.total + 1
        if source.enabled ~= false then stats.enabled = stats.enabled + 1 end
        if source.searchable ~= false and source.supported ~= false then stats.supported = stats.supported + 1
        else stats.unsupported = stats.unsupported + 1 end
        local capability = SourceStatus:capability(source)
        stats.capabilities[capability] = (stats.capabilities[capability] or 0) + 1
    end
    local health_map = Storage:listSourceHealth()
    local online, offline, unknown = connectivitySummary(sources, health_map)
    local probe = self.source_controller and self.source_controller:probeState() or {}
    local diagnostic = self.source_controller and self.source_controller:diagnosticState() or {}
    local probe_text = probe.active and "停止连接检查" or "检查书源能否连接"
    local probe_status
    if probe.active then
        probe_status = string.format("%d/%d · 成功%d 失败%d", probe.completed or 0,
            probe.total or 0, probe.online or 0, probe.offline or 0)
    else
        probe_status = string.format("请求成功%d · 失败%d · 未测/过期%d", online, offline, unknown)
    end
    local items = {
        {
            text = "书源概况",
            mandatory = string.format("可使用 %d · 暂不支持 %d", stats.supported or 0, stats.unsupported or 0),
            action = "show_stats",
        },
        { text = probe_text, mandatory = probe_status, action = "probe_all", separator = true },
        {
            text = diagnostic.active and "停止逐项检查" or "检查全部书源",
            mandatory = diagnostic.active
                and string.format("%d/%d", diagnostic.completed or 0, diagnostic.total or 0) or "尝试搜书和阅读",
            action = "diagnostic_all",
        },
        { text = "查看书源检查记录", mandatory = "详细结果", action = "diagnostic_log", separator = true },
        { text = "JavaScript 引擎检查", mandatory = "检查设备运行环境", action = "quickjs_check" },
    }
    for _, source in ipairs(sources) do
        local support = SourceStatus:structural(source)
        local status
        if source.enabled == false then
            status = support .. " · 已停用"
        else
            status = support .. " · " .. SourceHealth:shortLabel(health_map[tostring(source.id)])
        end
        items[#items + 1] = {
            text = SourcePreference:label(source) .. " " .. source.name,
            mandatory = status,
            source = source,
            dim = source.enabled == false,
        }
    end
    if #items == 5 then items[6] = { text = "尚未导入书源", dim = true } end
    return items
end

function SourceView:_cancelRefresh()
    if self._refresh_callback then
        pcall(UIManager.unschedule, UIManager, self._refresh_callback)
        self._refresh_callback = nil
    end
end

function SourceView:_scheduleRefresh(immediate)
    if immediate then
        self:_cancelRefresh()
        self.item_table = self:buildItems()
        self:updateItems()
        return
    end
    if self._refresh_callback then return end
    local callback
    callback = function()
        self._refresh_callback = nil
        self.item_table = self:buildItems()
        self:updateItems()
    end
    self._refresh_callback = callback
    UIManager:scheduleIn(1.0, callback)
end

function SourceView:cancelProbe(show_notice)
    if self.source_controller then self.source_controller:cancelProbe("user") end
    self:_scheduleRefresh(true)
    if show_notice then UIManager:show(Notification:new{ text = "已停止连接检查" }) end
end

function SourceView:startProbe(source_ids)
    if not self.source_controller then return nil, "书源控制器不可用" end
    local session, err = self.source_controller:startProbe(source_ids)
    self:_scheduleRefresh(true)
    if not session and err then
        UIManager:show(InfoMessage:new{ text = "无法开始检查：\n" .. tostring(err) })
    end
    return session, err
end

function SourceView:showDiagnosticLog()
    local tail, path = SourceDiagnosticLog:readTail(6000)
    local body = "记录保存在：\n" .. tostring(path)
        .. "\n\n检查结果会逐条保存。即使检查意外中断，已经完成的结果也不会丢失。"
    if tail and tail ~= "" then body = body .. "\n\n最近的结果：\n" .. tail end
    UI.showLater(self, "source_diagnostic_log", function()
        return InfoMessage:new{ text = body }
    end)
end

function SourceView:startDiagnostic()
    if not self.source_controller then return nil, "书源控制器不可用" end
    if self.source_controller:isProbing() then self.source_controller:cancelProbe("diagnostic") end
    local session, err = self.source_controller:startDiagnostic("我的")
    self:_scheduleRefresh(true)
    if not session and err then
        UIManager:show(InfoMessage:new{ text = "无法开始书源检查：\n" .. tostring(err) })
    end
    return session, err
end

function SourceView:confirmDiagnostic()
    UI.showLater(self, "confirm_source_diagnostic", function()
        return ConfirmBox:new{
            text = "检查全部书源？\n\n"
                .. "Leko 会逐条尝试搜索、书籍详情、目录和正文。这比简单的连接检查更准确，也会花费更长时间并使用网络。\n\n"
                .. "找不到合适的测试书不会算作失败。每条书源最多检查 40 秒，检查不会停用或修改书源。",
            ok_text = "开始检查",
            ok_callback = function() self:startDiagnostic() end,
        }
    end)
end

function SourceView:_releaseController()
    self:_cancelRefresh()
    if self.source_controller then self.source_controller:close(); self.source_controller = nil end
    self.item_table = {}
    Storage:releaseSourceSettings()
    Storage:releaseSourceHealthSettings()
    Storage:releaseSourceOverrideSettings()
end

function SourceView:showSourceDetails(source)
    local full_source = Storage:getSource(source.id) or source
    local record = Storage:getSourceHealth(source.id)
    local label = SourceStatus:capability(full_source)
    local reasons = full_source.compatibility_reasons or {}
    local friendly_reasons = {}
    local seen_reasons = {}
    for _, reason in ipairs(reasons) do
        local friendly = SourceStatus:friendlyReason(reason)
        if friendly ~= "" and not seen_reasons[friendly] then
            seen_reasons[friendly] = true
            friendly_reasons[#friendly_reasons + 1] = "• " .. friendly
        end
    end
    local executable = full_source.searchable ~= false and full_source.supported ~= false
    UI.showLater(self, "source_compat_" .. tostring(source.id), function()
        return InfoMessage:new{
            text = full_source.name
                .. "\n\n状态：" .. (executable and "可使用" or "暂不支持")
                .. "\n内容类型：" .. (tostring(full_source.media_kind or "text") == "text" and "文字" or tostring(full_source.media_kind))
                .. "\n需要的功能：" .. label
                .. (#friendly_reasons > 0 and ("\n\n" .. table.concat(friendly_reasons, "\n"))
                    or "\n\n没有发现明显问题，实际结果仍以联网使用为准。")
                .. "\n\n连接情况\n" .. SourceHealth:detailText(record),
        }
    end)
end

function SourceView:init()
    self.source_controller = SourceManagementController:new{
        on_catalog_ready = function(ok, err)
            if not ok then
                UIManager:show(InfoMessage:new{ text = "书源准备失败：\n" .. tostring(err) })
                return
            end
            self:_scheduleRefresh(true)
        end,
        on_probe_result = function(_, completed, total)
            if completed <= 1 then self:_scheduleRefresh(true)
            elseif completed < total then self:_scheduleRefresh(false) end
        end,
        on_probe_done = function(event, state)
            self:_scheduleRefresh(true)
            local text
            if event and event.error then
                text = "连接检查出错：" .. tostring(event.error)
            else
                text = string.format("连接检查完成：成功 %d，失败 %d",
                    state.online or 0, state.offline or 0)
            end
            UIManager:show(Notification:new{ text = text })
        end,
        on_diagnostic_result = function() self:_scheduleRefresh(false) end,
        on_diagnostic_progress = function() self:_scheduleRefresh(false) end,
        on_diagnostic_done = function(event, state)
            self:_scheduleRefresh(true)
            local text
            if event and event.error then
                text = "书源检查出错：" .. tostring(event.error)
            else
                text = string.format("检查完成：完整可用 %d · 未找到测试书 %d · 失败 %d",
                    state.full_pass or 0, state.inconclusive or 0,
                    (state.runtime_or_rule or 0) + (state.request_error or 0)
                        + (state.access_required or 0) + (state.timeout or 0) + (state.process_error or 0))
            end
            UIManager:show(Notification:new{ text = text })
        end,
        on_diagnostic_cancelled = function() self:_scheduleRefresh(true) end,
    }
    self.title = "Leko · 管理书源"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = self:buildItems()
    self.onMenuSelect = function(menu, item)
        if item.action == "show_stats" then
            local stats = Storage:getSourceStats()
            UI.showLater(menu, "source_stats", function()
                return InfoMessage:new{
                    text = string.format(
                        "书源总数：%d\n已启用：%d\n\n可使用：%d\n暂不支持：%d\n\n所需功能：%s\n\n可使用的文字书源会参与搜索。连接失败和解析失败会分别显示，方便判断问题出在哪里。",
                        stats.total or 0, stats.enabled or 0,
                        stats.supported or 0, stats.unsupported or 0,
                        (function()
                            local labels = {}
                            for name, count in pairs(stats.capabilities or {}) do
                                labels[#labels + 1] = tostring(name) .. " " .. tostring(count)
                            end
                            table.sort(labels)
                            return #labels > 0 and table.concat(labels, " · ") or "尚未分析"
                        end)()
                    ),
                }
            end)
            return
        end
        if item.action == "quickjs_check" then
            QuickJSRuntimeCheck:show(menu)
            return
        end
        if item.action == "probe_all" then
            if menu.source_controller and menu.source_controller:isProbing() then menu:cancelProbe(true) else menu:startProbe(nil) end
            return
        end
        if item.action == "diagnostic_all" then
            if menu.source_controller and menu.source_controller:isDiagnosing() then
                menu.source_controller:cancelDiagnostic("user")
                menu:_scheduleRefresh(true)
                UIManager:show(Notification:new{ text = "已停止检查；完成的结果仍然保留" })
            else
                menu:confirmDiagnostic()
            end
            return
        end
        if item.action == "diagnostic_log" then
            menu:showDiagnosticLog()
            return
        end
        if not item.source then return end
        local enabled = Storage:toggleSource(item.source.id)
        UIManager:show(Notification:new{ text = enabled and "已启用" or "已停用" })
        menu.item_table = menu:buildItems()
        menu:updateItems()
        if menu.on_changed then pcall(menu.on_changed) end
    end
    self.onMenuHold = function(menu, item)
        if not item.source then return end
        return UI.defer(menu, "source_hold", function()
            local source = item.source
            local dialog
            local function setPriority(value, label)
                UIManager:close(dialog)
                SourcePreference:set(source, value)
                menu.item_table = menu:buildItems()
                menu:updateItems()
                UIManager:show(Notification:new{ text = source.name .. "：" .. label .. "；下次搜索生效" })
            end
            dialog = ButtonDialog:new{
                modal = true,
                title = source.name,
                buttons = {
                    {{ text = "↑ 优先搜索", callback = function()
                        setPriority(SourcePreference.PRIORITY, "已设为优先搜索")
                    end }},
                    {{ text = "· 自动排序", callback = function()
                        setPriority(SourcePreference.AUTO, "已恢复自动排序")
                    end }},
                    {{ text = "↓ 靠后搜索", callback = function()
                        setPriority(SourcePreference.LAST, "已设为靠后搜索")
                    end }},
                    {{ text = "检查能否连接", callback = function()
                        UIManager:close(dialog)
                        menu:startProbe({ source.id })
                    end }},
                    {{ text = "查看检查结果", callback = function()
                        UIManager:close(dialog)
                        menu:showSourceDetails(source)
                    end }},
                    {{ text = source.enabled == false and "启用" or "停用", callback = function()
                        UIManager:close(dialog)
                        Storage:toggleSource(source.id)
                        menu.item_table = menu:buildItems()
                        menu:updateItems()
                        if menu.on_changed then pcall(menu.on_changed) end
                    end }},
                    {{ text = "删除", callback = function()
                        UIManager:close(dialog)
                        UI.showLater(menu, "delete_source_" .. tostring(source.id), function()
                            return ConfirmBox:new{
                                text = "删除书源“" .. source.name .. "”？",
                                ok_text = "删除",
                                ok_callback = function()
                                    Storage:deleteSource(source.id)
                                    menu.item_table = menu:buildItems()
                                    menu:updateItems()
                                    if menu.on_changed then pcall(menu.on_changed) end
                                end,
                            }
                        end)
                    end }},
                },
            }
            UIManager:show(dialog)
        end)
    end
    self.close_callback = function()
        self:_releaseController()
        UIManager:close(self, "full")
    end
    Menu.init(self)
    self.source_controller:ensureCatalog()
end

function SourceView:onReturn()
    self:_releaseController()
    UIManager:close(self, "full")
    return true
end

return SourceView
