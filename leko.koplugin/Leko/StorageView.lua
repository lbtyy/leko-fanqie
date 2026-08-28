local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local AsyncStorageStats = require("Leko/AsyncStorageStats")
local BookService = require("Leko/BookService")
local CoverService = require("Leko/CoverService")
local Diagnostics = require("Leko/Diagnostics")
local MemoryGuard = require("Leko/MemoryGuard")
local Storage = require("Leko/Storage")
local SourceBackupView = require("Leko/SourceBackupView")
local UI = require("Leko/UI")

local StorageView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

local function sizeLabel(stats, field)
    return stats and Storage:formatBytes(stats[field] or 0) or "正在统计…"
end

function StorageView:buildItems(stats)
    stats = stats or Storage:getCachedStorageStats()
    return {
        { text = "存储占用", mandatory = sizeLabel(stats, "total"), action = "stats" },
        { text = "查看内存占用", mandatory = "当前使用情况", action = "memory" },
        { text = "封面加载状态", mandatory = "查看下载和缓存情况", action = "cover_diag" },
        { text = "最近一次错误", mandatory = "查看出错原因", action = "last_error", separator = true },
        { text = "清理搜索缓存", mandatory = sizeLabel(stats, "cache_search"), action = "clear_search" },
        { text = "清理详情与目录缓存", mandatory = stats and Storage:formatBytes(
            (stats.cache_bookinfo or 0) + (stats.cache_toc or 0)
        ) or "正在统计…", action = "clear_metadata" },
        { text = "清理图片缓存", mandatory = sizeLabel(stats, "cache_images"), action = "clear_images" },
        { text = "清理临时下载", mandatory = sizeLabel(stats, "cache_tmp"), action = "clear_tmp" },
        { text = "清理全部临时缓存", mandatory = sizeLabel(stats, "cache"), action = "clear_all", separator = true },
        { text = "已下载章节", mandatory = sizeLabel(stats, "books"), dim = true },
        { text = "书源备份", mandatory = stats and (tostring(stats.backup_count or 0)
            .. " 份 · " .. Storage:formatBytes(stats.sources) .. " ›") or "正在统计…", action = "source_backups" },
    }
end

function StorageView:_applyStats(stats)
    self.item_table = self:buildItems(stats)
    self:updateItems()
end

function StorageView:refresh(force)
    self:_applyStats(Storage:getCachedStorageStats())
    AsyncStorageStats:start(function(ok, stats)
        if ok and stats and not self._closed then self:_applyStats(stats) end
    end, force == true)
end

function StorageView:init()
    self.title = "Leko · 存储与缓存"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = self:buildItems(Storage:getCachedStorageStats())
    self.onMenuSelect = function(menu, item)
        return UI.defer(menu, "storage_" .. tostring(item.action), function()
        if item.action == "memory" then
            local memory = BookService:getMemoryStats()
            local kernel = MemoryGuard:snapshot()
            local available = kernel.available_kb and Storage:formatBytes(kernel.available_kb * 1024) or "不可读取"
            local rss = kernel.rss_kb and Storage:formatBytes(kernel.rss_kb * 1024) or "不可读取"
            local peak = kernel.peak_rss_kb and Storage:formatBytes(kernel.peak_rss_kb * 1024) or "不可读取"
            UIManager:show(InfoMessage:new{
                text = "系统可用内存：" .. available
                    .. "\nKOReader 当前占用：" .. rss
                    .. "\nKOReader 最高占用：" .. peak
                    .. "\n应用脚本占用：" .. Storage:formatBytes(memory.lua_kb * 1024)
                    .. "\nLeko 已打开章节：" .. tostring(memory.cached_models)
                    .. "\n章节文字：" .. Storage:formatBytes(memory.paragraph_bytes)
                    .. "\n书源详细数据：" .. (Storage._source_settings and "已载入" or "已释放")
                    .. "\n封面缩略图：" .. tostring(CoverService:getMemoryStats().entries)
                    .. " 张，估算 " .. Storage:formatBytes(CoverService:getMemoryStats().bytes)
                    .. "\n\n应用脚本占用也包含 KOReader 和其他插件，不全是 Leko 使用的内存。",
            })
            return
        end
        if item.action == "cover_diag" then
            UIManager:show(InfoMessage:new{ text = CoverService:getStatsText() })
            return
        end
        if item.action == "last_error" then
            local detail, path = Diagnostics:readLast()
            UIManager:show(InfoMessage:new{
                text = detail and ("最近一次完整错误：\n\n" .. detail .. "\n文件：" .. tostring(path))
                    or ("尚无已记录错误。\n文件位置：" .. tostring(path)),
            })
            return
        end
        if item.action == "stats" then
            local stats = Storage:getCachedStorageStats()
            if not stats then
                UIManager:show(InfoMessage:new{ text = "正在后台统计存储占用，请稍后再试。" })
                self:refresh(true)
                return
            end
            UIManager:show(InfoMessage:new{
                text = "数据目录：\n" .. Storage.root_dir
                    .. "\n\n已下载章节：" .. Storage:formatBytes(stats.books)
                    .. "\n封面：" .. Storage:formatBytes(stats.covers)
                    .. "\n书源备份：" .. Storage:formatBytes(stats.sources)
                    .. "\n临时缓存：" .. Storage:formatBytes(stats.cache)
                    .. "\n总计：" .. Storage:formatBytes(stats.total)
                    .. "\n\n清理临时缓存不会删除书架、阅读进度或已下载章节。",
            })
            return
        end
        if item.action == "source_backups" then
            UIManager:show(SourceBackupView:new{
                on_changed = function()
                    Storage:clearCachedStorageStats()
                    menu:refresh(true)
                    if menu.on_sources_changed then pcall(menu.on_sources_changed) end
                end,
            }, "full")
            return
        end
        local kinds
        if item.action == "clear_search" then kinds = { "search" }
        elseif item.action == "clear_metadata" then kinds = { "bookinfo", "toc" }
        elseif item.action == "clear_images" then kinds = { "images" }
        elseif item.action == "clear_tmp" then kinds = { "tmp", "http" }
        elseif item.action == "clear_all" then kinds = false
        else return end

        UIManager:show(ConfirmBox:new{
            text = item.action == "clear_all"
                and "清理全部临时缓存？不会删除已下载章节。"
                or "清理“" .. item.text .. "”？",
            ok_text = "清理",
            ok_callback = function()
                if kinds == false then
                    CoverService:clearMemory()
                    Storage:clearCache()
                else
                    for _, kind in ipairs(kinds) do
                        if kind == "images" then CoverService:clearMemory() end
                        Storage:clearCache(kind)
                    end
                end
                Storage:clearCachedStorageStats()
                UIManager:show(Notification:new{ text = "缓存已清理" })
                menu:refresh(true)
            end,
        })
        end)
    end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
    UIManager:nextTick(function()
        if not self._closed then self:refresh(false) end
    end)
end

function StorageView:onReturn()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

return StorageView
