local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local ErrorGuard = require("Leko/ErrorGuard")
local AsyncSourceCatalog = require("Leko/AsyncSourceCatalog")
local AsyncSourceImport = require("Leko/AsyncSourceImport")
local AsyncStorageStats = require("Leko/AsyncStorageStats")
local Importer = require("Leko/Importer")
local SearchView = require("Leko/SearchView")
local SearchSettings = require("Leko/SearchSettings")
local SourceView = require("Leko/SourceView")
local SourceBackupView = require("Leko/SourceBackupView")
local Storage = require("Leko/Storage")
local StorageView = require("Leko/StorageView")
local TaskProgress = require("Leko/TaskProgress")
local UI = require("Leko/UI")
local MobileSourceImportView = require("Leko/MobileSourceImportView")
local BUILD = require("Leko/Version").version

local function showResult(ok_value, err, success_text, onChanged)
    if not ok_value then
        UIManager:show(InfoMessage:new{ text = "操作失败：\n" .. tostring(err) })
        return
    end
    UIManager:show(Notification:new{ text = success_text or "完成" })
    if onChanged then onChanged() end
end

local function showSourceImportResult(result, err, onChanged)
    if not result then
        UIManager:show(InfoMessage:new{ text = "书源导入失败：\n" .. tostring(err) })
        return
    end
    local summary
    if result.total ~= nil and result.supported ~= nil then
        summary = Importer:summarizeSourceStats(result)
    else
        summary = Importer:summarizeSources(result)
    end
    UIManager:show(InfoMessage:new{
        text = summary .. "\n\n书源已经准备好，现在可以返回书架搜书。",
    })
    if onChanged then onChanged() end
end

local ImportMenuView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function ImportMenuView:init()
    self.title = "导入书籍"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = {
        { text = "导入单个 TXT", mandatory = "本地文件", action = "txt" },
        { text = "导入章节目录", mandatory = "多个 TXT", action = "dir" },
    }
    self.onMenuSelect = function(menu, item) menu:handleAction(item.action) end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
end

function ImportMenuView:_handleAction(action)
    if action == "txt" then
        Importer:chooseFile(function(path)
            local loading = InfoMessage:new{ text = "正在导入 TXT……", dismissable = false }
            UIManager:show(loading)
            UIManager:nextTick(function()
                local book, err = Importer:importTextFile(path)
                UIManager:close(loading)
                showResult(book, err, book and ("已导入：" .. book.title), self.onChanged)
            end)
        end)
    elseif action == "dir" then
        Importer:chooseDirectory(function(path)
            local loading = InfoMessage:new{ text = "正在导入章节目录……", dismissable = false }
            UIManager:show(loading)
            UIManager:nextTick(function()
                local book, err = Importer:importDirectory(path)
                UIManager:close(loading)
                showResult(book, err, book and ("已导入：" .. book.title), self.onChanged)
            end)
        end)
    end
end

function ImportMenuView:handleAction(action)
    return UI.defer(self, "import_" .. tostring(action), function() self:_handleAction(action) end)
end

function ImportMenuView:onReturn()
    UIManager:close(self, "full")
    return true
end

local SourceHubView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function SourceHubView:init()
    local cached_storage = Storage:getCachedStorageStats()
    Storage:releaseSourceSettings()
    self.title = "书源"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = {
        { text = "管理书源", mandatory = cached_storage and string.format("可使用 %d · 暂不支持 %d",
            cached_storage.source_supported or 0, cached_storage.source_unsupported or 0)
            or "正在统计…", action = "manage" },
        { text = "用手机导入", mandatory = "推荐 · 手机扫码", action = "mobile" },
        { text = "从文件导入", mandatory = "书源文件", action = "local" },
        { text = "通过网址导入", mandatory = "网络地址", action = "url" },
        { text = "从备份恢复", mandatory = cached_storage
            and (tostring(cached_storage.backup_count or 0) .. " 份备份") or "正在统计…", action = "backups", separator = true },
        { text = "把欢迎书放回书架", mandatory = "不影响已有书源", action = "welcome" },
    }
    self.onMenuSelect = function(menu, item) menu:handleAction(item.action) end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
    UIManager:nextTick(function()
        if self._closed then return end
        AsyncStorageStats:start(function(ok, storage_stats)
            if ok and storage_stats and not self._closed then self:_updateBackupCount(storage_stats) end
        end)
    end)
end

function SourceHubView:_updateBackupCount(storage_stats)
    for _, item in ipairs(self.item_table or {}) do
        if item.action == "manage" then
            item.mandatory = string.format("可使用 %d · 暂不支持 %d",
                storage_stats.source_supported or 0, storage_stats.source_unsupported or 0)
        elseif item.action == "backups" then
            item.mandatory = tostring(storage_stats.backup_count or 0) .. " 份备份"
        end
    end
    if self.updateItems then self:updateItems() end
end

function SourceHubView:_refreshSourceStats(force_storage)
    local cached_storage = Storage:getCachedStorageStats()
    for _, item in ipairs(self.item_table or {}) do
        if item.action == "manage" then
            item.mandatory = cached_storage and string.format("可使用 %d · 暂不支持 %d",
                cached_storage.source_supported or 0, cached_storage.source_unsupported or 0)
                or "正在统计…"
        elseif item.action == "backups" then
            item.mandatory = cached_storage
                and (tostring(cached_storage.backup_count or 0) .. " 份备份") or "正在统计…"
        end
    end
    if self.updateItems then self:updateItems() end
    AsyncStorageStats:start(function(ok, storage_stats)
        if ok and storage_stats and not self._closed then self:_updateBackupCount(storage_stats) end
    end, force_storage == true)
end

function SourceHubView:showBackups()
    UIManager:show(SourceBackupView:new{
        on_changed = function()
            Storage:clearCachedStorageStats()
            self:_refreshSourceStats(true)
            if self.onChanged then self.onChanged() end
        end,
    }, "full")
end

function SourceHubView:_addWelcomeGuide()
    local ticket
    local progress = TaskProgress:new{
        title = "添加欢迎书",
        total = 2,
        current = 0,
        stage = "正在把《欢迎来到 Leko》放回书架……",
    }
    progress:show()
    UIManager:nextTick(function()
        local source_ok, _, total = pcall(Storage.seedBuiltinSources, Storage, true)
        local book_ok = pcall(Storage.seedDemoBook, Storage, true)
        if not source_ok or not book_ok then
            progress:close()
            UIManager:show(InfoMessage:new{ text = "无法把欢迎书放回书架，请稍后重试。" })
            return
        end
        progress:update(1, "正在更新书源列表……", 2)
        ticket = AsyncSourceCatalog:ensure(function(catalog_ok, err)
            ticket = nil
            progress:close()
            if not catalog_ok then
                UIManager:show(InfoMessage:new{ text = "书源列表更新失败：\n" .. tostring(err) })
                return
            end
            Storage:clearCachedStorageStats()
            self:_refreshSourceStats(true)
            UIManager:show(Notification:new{
                text = "《欢迎来到 Leko》已放回书架；其他书源保持不变",
            })
            if self.onChanged then self.onChanged() end
        end)
    end)
end

function SourceHubView:confirmAddWelcomeGuide()
    UI.showLater(self, "add_welcome_guide", function()
        return ConfirmBox:new{
            text = "把《欢迎来到 Leko》放回书架？\n\n"
                .. "会重新生成这本本地使用说明并加入书架，不会删除、停用或替换已经导入的书源。",
            ok_text = "放回书架",
            ok_callback = function()
                UI.defer(self, "add_welcome_guide_start", function() self:_addWelcomeGuide() end)
            end,
        }
    end)
end

function SourceHubView:_startSourceImport(spec)
    if self._source_import_worker then
        UIManager:show(Notification:new{ text = "已有书源导入正在进行" })
        return
    end
    local worker
    local progress = TaskProgress:new{
        title = "导入书源",
        total = 5,
        current = 0,
        stage = "准备后台导入……",
        cancel_text = "取消导入",
        cancel_callback = function()
            if not worker then return true end
            local cancelled = AsyncSourceImport:cancel(worker)
            if cancelled ~= false then
                if self._source_import_worker == worker then self._source_import_worker = nil end
                return true
            end
            progress:update(4, "正在安全提交书源，当前阶段不能中断", 5)
            return false
        end,
    }
    progress:show()

    local start_err
    worker, start_err = AsyncSourceImport:start({
        kind = spec.kind,
        path = spec.path,
        url = spec.url,
        on_state = function(_, text, current, total)
            if text and progress and not progress._closing then
                progress:update(current or progress.current, text, total or progress.total)
            end
        end,
    }, function(ok, err, completed_worker, payload)
        if self._source_import_worker == completed_worker then self._source_import_worker = nil end
        progress:close()
        Storage:clearCachedStorageStats()
        self:_refreshSourceStats(true)
        if not ok then
            showSourceImportResult(nil, err, self.onChanged)
            return
        end
        showSourceImportResult(payload and payload.stats, nil, self.onChanged)
        -- Source counts/grades in this page may have changed. Re-entering the
        -- page will rebuild its lightweight rows; do not parse full sources here.
    end)
    if not worker then
        progress:close()
        UIManager:show(InfoMessage:new{ text = "无法启动书源导入：\n" .. tostring(start_err) })
        return
    end
    self._source_import_worker = worker
end

function SourceHubView:openMobileSourceImport()
    NetworkMgr:runWhenConnected(function()
        local view, err = MobileSourceImportView.open{
            on_changed = function()
                Storage:clearCachedStorageStats()
                self:_refreshSourceStats(true)
                if self.onChanged then self.onChanged() end
            end,
        }
        if not view then
            UIManager:show(InfoMessage:new{
                text = "无法开始手机导入：\n" .. tostring(err or "请稍后重试")
                    .. "\n\n手机无法连接时，可以返回并使用“从文件导入”。",
            })
        end
    end)
end

function SourceHubView:importSourcesFromUrl(url)
    NetworkMgr:runWhenConnected(function()
        self:_startSourceImport{ kind = "url", url = url }
    end)
end

function SourceHubView:promptSourceUrl()
    local dialog
    dialog = InputDialog:new{
        modal = true,
        title = "通过网址导入书源",
        input_hint = "https://…/sources.json",
        buttons = {
            {
                { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                { text = "导入", callback = function()
                    local url = dialog:getInputText()
                    UIManager:close(dialog)
                    UI.defer(self, "import_source_url", function() self:importSourcesFromUrl(url) end)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SourceHubView:_handleAction(action)
    if action == "manage" then
        UIManager:show(SourceView:new{
            on_changed = function()
                Storage:clearCachedStorageStats()
                self:_refreshSourceStats(true)
                if self.onChanged then self.onChanged() end
            end,
        }, "full")
    elseif action == "mobile" then
        self:openMobileSourceImport()
    elseif action == "local" then
        Importer:chooseFile(function(path)
            self:_startSourceImport{ kind = "file", path = path }
        end)
    elseif action == "url" then
        self:promptSourceUrl()
    elseif action == "backups" then
        self:showBackups()
    elseif action == "welcome" then
        self:confirmAddWelcomeGuide()
    end
end

function SourceHubView:handleAction(action)
    return UI.defer(self, "source_" .. tostring(action), function() self:_handleAction(action) end)
end

function SourceHubView:onReturn()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

-- ---------------------------------------------------------------------------
-- [seam] leko-plus：番茄账号入口（阶段①最小闭环；T09 将扩展为完整设置分区）
-- ---------------------------------------------------------------------------

local FanqieMenuView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    modal = false,
}

local function fanqieAuth() return require("Leko/Fanqie/FanqieAuth") end
local function fanqieCompliance() return require("Leko/Fanqie/FanqieCompliance") end

function FanqieMenuView:init()
    self.title = "番茄小说"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self:_buildItems()
    self.onMenuSelect = function(menu, item) menu:handleAction(item.action) end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
end

function FanqieMenuView:_buildItems()
    local enabled = fanqieCompliance():isEnabled()
    local logged_in = enabled and fanqieAuth():isLoggedIn()
    local account = enabled and fanqieAuth():getAccount() or {}
    local saved_at = tonumber(account.cookie_saved_at or 0) or 0
    local login_hint = not enabled and "先开启番茄源"
        or (logged_in
            and ((fanqieAuth():isExpiringSoon() and "登录态临期，建议重新扫码" or "已登录"))
            or "未登录")
    self.item_table = {
        { text = enabled and "番茄源：已开启" or "开启番茄源",
          mandatory = enabled and "免责声明已确认" or "首次需确认免责声明",
          action = "toggle" },
        { text = "扫码登录", mandatory = login_hint, action = "login",
          enabled = enabled },
        { text = "同步番茄书架", mandatory = "拉取账号书架到统一书架 ›", action = "sync",
          enabled = enabled and logged_in },
        { text = "退出番茄登录", mandatory = saved_at > 0
            and ("登录于 " .. os.date("%Y-%m-%d", saved_at)) or "清除本机登录态",
          action = "logout", enabled = logged_in },
    }
end

function FanqieMenuView:_refresh()
    self:_buildItems()
    if self.updateItems then self:updateItems() end
end

function FanqieMenuView:_handleAction(action)
    if action == "toggle" then
        if fanqieCompliance():isEnabled() then
            UIManager:show(ConfirmBox:new{
                text = "关闭番茄源？\n\n关闭后番茄书仍可离线阅读已缓存章节，但不再发起任何番茄网络请求。登录态保留。",
                ok_text = "关闭番茄源",
                ok_callback = function()
                    fanqieCompliance():revoke()
                    self:_refresh()
                    if self.onChanged then self.onChanged() end
                end,
            })
        else
            fanqieCompliance():requireConfirmation{
                on_confirmed = function()
                    self:_refresh()
                    if self.onChanged then self.onChanged() end
                end,
            }
        end
    elseif action == "login" then
        if not fanqieCompliance():isEnabled() then
            UIManager:show(InfoMessage:new{ text = "请先开启番茄源并确认免责声明。" })
            return
        end
        NetworkMgr:runWhenConnected(function()
            local QRLoginView = require("Leko/Fanqie/QRLoginView")
            UIManager:show(QRLoginView:new{
                on_login_success = function()
                    self:_refresh()
                    if self.onChanged then self.onChanged() end
                end,
                on_close = function() self:_refresh() end,
            }, "full")
        end)
    elseif action == "sync" then
        if not fanqieAuth():isLoggedIn() then
            UIManager:show(InfoMessage:new{ text = "请先扫码登录番茄账号。" })
            return
        end
        NetworkMgr:runWhenConnected(function()
            local loading = InfoMessage:new{ text = "正在同步番茄书架……", dismissable = false }
            UIManager:show(loading)
            local FanqieShelfService = require("Leko/Fanqie/FanqieShelfService")
            local worker, start_err = FanqieShelfService:syncShelf({}, function(books, err)
                UIManager:close(loading)
                if not books then
                    UIManager:show(InfoMessage:new{ text = "番茄书架同步失败：\n" .. tostring(err) })
                    return
                end
                local added, updated = FanqieShelfService:mergeIntoBookshelf(books)
                UIManager:show(InfoMessage:new{
                    text = string.format("番茄书架同步完成：共 %d 本（新增 %d · 更新 %d）。",
                        #books, added, updated),
                })
                if self.onChanged then self.onChanged() end
            end)
            if not worker then
                UIManager:close(loading)
                UIManager:show(InfoMessage:new{ text = "无法启动书架同步：\n" .. tostring(start_err) })
            end
        end)
    elseif action == "logout" then
        UIManager:show(ConfirmBox:new{
            text = "退出番茄登录？\n\n本机保存的登录态会被清除，已缓存的章节保留。",
            ok_text = "退出登录",
            ok_callback = function()
                fanqieAuth():logout()
                self:_refresh()
                UIManager:show(Notification:new{ text = "已退出番茄登录" })
                if self.onChanged then self.onChanged() end
            end,
        })
    end
end

function FanqieMenuView:handleAction(action)
    return UI.defer(self, "fanqie_" .. tostring(action), function() self:_handleAction(action) end)
end

function FanqieMenuView:onReturn()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

local MainMenuView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function MainMenuView:init()
    local cached_storage = Storage:getCachedStorageStats()
    Storage:releaseSourceSettings()
    self.title = "Leko " .. BUILD
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = {
        { text = "查找书籍", mandatory = "在线搜索", action = "search" },
        { text = "搜索设置", mandatory = "每条书源最多 " .. tostring(SearchSettings:getLimit()) .. " 个结果 ›", action = "search_settings" },
        { text = "导出设置", mandatory = Storage:getExportDirectoryLabel() .. " ›", action = "export_settings" },
        { text = "导入本地书籍", mandatory = "TXT ›", action = "imports" },
        { text = "书源", mandatory = cached_storage
            and (tostring(cached_storage.source_count or 0) .. " 个 ›") or "正在统计…", action = "sources" },
        { text = "番茄小说", mandatory = "扫码登录 · 账号书架 ›", action = "fanqie" },
        -- [seam] leko-plus T09：番茄账号完整设置分区（含三源/同步开关/重载配置）
        { text = "番茄账号设置", mandatory = "三源 · 同步 · 配置 ›", action = "fanqie_settings" },
        -- [seam] leko-plus T10：番茄诊断面板（PRD P2-1）
        { text = "番茄诊断", mandatory = "Provider 健康度 ›", action = "diagnostics" },
        { text = "存储与缓存", mandatory = cached_storage
            and Storage:formatBytes(cached_storage.cache) or "正在统计…", action = "storage", separator = true },
        { text = "新手帮助", mandatory = "第一次使用先看这里 ›", action = "help" },
        { text = "关于 Leko", mandatory = BUILD, action = "about" },
    }
    self.onMenuSelect = function(menu, item) menu:handleAction(item.action) end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
    UIManager:nextTick(function()
        if self._closed then return end
        AsyncStorageStats:start(function(ok, stats)
            if ok and stats and not self._closed then self:_updateStorageRow(stats) end
        end)
    end)
end

function MainMenuView:_updateStorageRow(stats)
    for _, item in ipairs(self.item_table or {}) do
        if item.action == "sources" then
            item.mandatory = tostring(stats.source_count or 0) .. " 个 ›"
        elseif item.action == "storage" then
            item.mandatory = Storage:formatBytes(stats.cache)
        end
    end
    if self.updateItems then self:updateItems() end
end

function MainMenuView:refreshSourceCount()
    Storage:clearCachedStorageStats()
    for _, item in ipairs(self.item_table or {}) do
        if item.action == "sources" then item.mandatory = "正在统计…"; break end
    end
    if self.updateItems then self:updateItems() end
    AsyncStorageStats:start(function(ok, stats)
        if ok and stats and not self._closed then self:_updateStorageRow(stats) end
    end, true)
end

function MainMenuView:_updateExportDirectoryRow()
    for _, item in ipairs(self.item_table or {}) do
        if item.action == "export_settings" then
            item.mandatory = Storage:getExportDirectoryLabel() .. " ›"
            break
        end
    end
    if self.updateItems then self:updateItems() end
end

function MainMenuView:_chooseExportDirectory(mode, path)
    local ok, err = Storage:setExportDirectory(mode, path)
    if not ok then
        UIManager:show(InfoMessage:new{ text = "无法保存导出目录：\n" .. tostring(err) })
        return
    end
    self:_updateExportDirectoryRow()
    UIManager:show(Notification:new{ text = "导出目录已设置" })
end

function MainMenuView:promptCustomExportDirectory()
    local dialog
    dialog = InputDialog:new{
        modal = true,
        title = "自定义导出目录",
        input = Storage:getExportDir(),
        input_hint = "/mnt/us/documents/文件夹",
        buttons = {{
            { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "保存", callback = function()
                local path = dialog:getInputText()
                UIManager:close(dialog)
                self:_chooseExportDirectory("custom", path)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MainMenuView:showExportSettings()
    if self._export_settings_dialog then return true end
    local function choose(mode)
        UIManager:close(self._export_settings_dialog)
        self._export_settings_dialog = nil
        self:_chooseExportDirectory(mode)
    end
    self._export_settings_dialog = ButtonDialog:new{
        modal = true,
        title = "导出目录\n当前：" .. Storage:getExportDir(),
        buttons = {
            {{ text = "Kindle documents 根目录（推荐）", callback = function() choose("kindle_documents") end }},
            {{ text = "documents/Leko 子目录", callback = function() choose("kindle_leko") end }},
            {{ text = "Leko 数据目录", callback = function() choose("leko_data") end }},
            {{ text = "自定义目录…", callback = function()
                UIManager:close(self._export_settings_dialog)
                self._export_settings_dialog = nil
                self:promptCustomExportDirectory()
            end }},
            {{ text = "取消", callback = function()
                UIManager:close(self._export_settings_dialog)
                self._export_settings_dialog = nil
            end }},
        },
        tap_close_callback = function() self._export_settings_dialog = nil end,
    }
    UIManager:show(self._export_settings_dialog)
    return true
end

function MainMenuView:showSearchSettings()
    if self._search_settings_dialog then return true end
    local buttons = {}
    local current = SearchSettings:getLimit()
    for _, choice in ipairs(SearchSettings.LIMIT_CHOICES) do
        local value = choice
        buttons[#buttons + 1] = {{
            text = (current == value and "✓ " or "") .. tostring(value) .. " 条",
            callback = function()
                SearchSettings:setLimit(value)
                UIManager:close(self._search_settings_dialog)
                self._search_settings_dialog = nil
                for _, item in ipairs(self.item_table or {}) do
                    if item.action == "search_settings" then
                        item.mandatory = "每条书源最多 " .. tostring(value) .. " 个结果 ›"
                        break
                    end
                end
                if self.updateItems then self:updateItems() end
                UIManager:show(Notification:new{ text = "每个书源最多检查 " .. tostring(value) .. " 条结果" })
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = "取消",
        callback = function()
            UIManager:close(self._search_settings_dialog)
            self._search_settings_dialog = nil
        end,
    }}
    self._search_settings_dialog = ButtonDialog:new{
        title = "每条书源最多显示多少个结果",
        modal = true,
        buttons = buttons,
        tap_close_callback = function() self._search_settings_dialog = nil end,
    }
    UIManager:show(self._search_settings_dialog)
    return true
end

function MainMenuView:_handleAction(action)
    if action == "search" then
        SearchView:prompt{
            owner = self,
            onReadBook = self.onReadBook,
            onBookAdded = function(book)
                if self.onChanged then self.onChanged(book) end
            end,
        }
    elseif action == "search_settings" then
        self:showSearchSettings()
    elseif action == "export_settings" then
        self:showExportSettings()
    elseif action == "imports" then
        UIManager:show(ImportMenuView:new{ onChanged = self.onChanged }, "full")
    elseif action == "sources" then
        UIManager:show(SourceHubView:new{
            onChanged = function(...)
                self:refreshSourceCount()
                if self.onChanged then self.onChanged(...) end
            end,
        }, "full")
    elseif action == "fanqie" then
        UIManager:show(FanqieMenuView:new{
            onChanged = function(...)
                if self.onChanged then self.onChanged(...) end
            end,
        }, "full")
    elseif action == "fanqie_settings" then
        -- [seam] leko-plus T09：番茄账号设置分区（完整版）
        pcall(function()
            local FanqieSettingsView = require("Leko/Fanqie/FanqieSettingsView")
            FanqieSettingsView:show()
        end)
    elseif action == "diagnostics" then
        -- [seam] leko-plus T10：诊断面板入口（P2-1）
        pcall(function()
            local InfoMessage = require("ui/widget/infomessage")
            local Diagnostics = require("Leko/Diagnostics")
            local panel = Diagnostics:ensureFanqiePanel()
            local function boolStr(v) return v == true and "是" or "否" end
            local provider_lines = {}
            for id, caps in pairs(panel.providers or {}) do
                provider_lines[#provider_lines + 1] = string.format(
                    "• %s：shelf=%s review=%s login=%s",
                    id, boolStr(caps and caps.shelf), boolStr(caps and caps.review),
                    boolStr(caps and caps.login))
            end
            UIManager:show(InfoMessage:new{
                text = "番茄诊断面板\n\n"
                    .. "合规门禁：" .. boolStr(panel.compliance_enabled) .. "\n"
                    .. "登录态：" .. boolStr(panel.logged_in)
                    .. (panel.expiring_soon and "（临期）" or "") .. "\n"
                    .. "Cookie 昵称：" .. tostring(panel.nickname or "未登录") .. "\n"
                    .. "同步开关 pull=" .. boolStr(panel.sync_pull_enabled)
                    .. " upload=" .. boolStr(panel.sync_upload_enabled) .. "\n"
                    .. "pending 队列：" .. tostring(panel.pending_count or 0) .. " 条\n\n"
                    .. "Provider 能力：\n" .. table.concat(provider_lines, "\n"),
            })
        end)
    elseif action == "storage" then
        UIManager:show(StorageView:new{
            on_sources_changed = function()
                self:refreshSourceCount()
                if self.onChanged then self.onChanged() end
            end,
        }, "full")
    elseif action == "help" then
        UIManager:show(InfoMessage:new{
            text = "第一次使用\n\n"
                .. "1. 书架里的《欢迎来到 Leko》是一份九章使用说明书，不需要联网。\n"
                .. "2. 要联网搜书：先让 Kindle 和手机连接同一个 Wi-Fi，再打开菜单 → 书源 → 用手机导入。\n"
                .. "3. 手机扫码后粘贴网址、JSON 或选择书源文件；从文件导入和通过网址导入仍可作为备用方式。\n"
                .. "4. 导入后回到菜单，点“查找书籍”并输入书名。\n\n"
                .. "常用功能\n\n"
                .. "• 搜索结果可先试读，退出时再决定是否加入书架。\n"
                .. "• 书籍详情 → 书籍换源：更换正文来源。\n"
                .. "• 书籍详情 → 更多 → 刷新目录与书籍信息：手动检查更新。\n"
                .. "• 阅读页 → 排版：调整字号、行距、页边距、段距和缩进。\n"
                .. "• 全书缓存完成后，才能导出完整 TXT、EPUB 或 MOBI。\n\n"
                .. "出错时\n\n"
                .. "先确认《欢迎来到 Leko》能正常阅读，再尝试另一条书源。如果所有书源都失败，可以运行“JavaScript 引擎检查”，并查看“最近一次错误”。",
        })
    elseif action == "about" then
        UIManager:show(InfoMessage:new{
            text = "Leko " .. BUILD
                .. "\n\nKOReader 网络小说插件。书架、搜索、书籍详情和阅读器彼此分离；搜索结果默认先试读，再决定是否加入书架。",
        })
    end
end

function MainMenuView:handleAction(action)
    return UI.defer(self, "main_" .. tostring(action), function() self:_handleAction(action) end)
end

function MainMenuView:onReturn()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

return MainMenuView
