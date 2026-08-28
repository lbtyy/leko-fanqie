local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local AsyncSourceImport = require("Leko/AsyncSourceImport")
local Importer = require("Leko/Importer")
local Storage = require("Leko/Storage")
local TaskProgress = require("Leko/TaskProgress")
local UI = require("Leko/UI")

local SourceBackupView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    modal = false,
}

function SourceBackupView:buildItems()
    local backups = Storage:listSourceBackups()
    if #backups == 0 then
        return {{ text = "还没有书源备份", mandatory = "导入书源后会自动保存", dim = true }}
    end
    local items = {}
    for _, backup in ipairs(backups) do
        items[#items + 1] = {
            text = backup.name,
            mandatory = os.date("%Y-%m-%d %H:%M", backup.modified)
                .. " · " .. Storage:formatBytes(backup.size),
            backup = backup,
        }
    end
    return items
end

function SourceBackupView:_startRestore(backup)
    if self._worker then
        UIManager:show(Notification:new{ text = "已有书源恢复正在进行" })
        return
    end
    local worker
    local progress = TaskProgress:new{
        title = "恢复书源备份",
        total = 5,
        current = 0,
        stage = "准备后台恢复……",
        cancel_text = "取消恢复",
        cancel_callback = function()
            if not worker then return true end
            local cancelled = AsyncSourceImport:cancel(worker)
            if cancelled ~= false then
                if self._worker == worker then self._worker = nil end
                return true
            end
            progress:update(4, "正在安全保存书源，当前阶段不能中断", 5)
            return false
        end,
    }
    progress:show()
    local start_err
    worker, start_err = AsyncSourceImport:start({
        kind = "file",
        path = backup.path,
        backup = false,
        on_state = function(_, text, current, total)
            if text and not progress._closing then
                progress:update(current or progress.current, text, total or progress.total)
            end
        end,
    }, function(ok, err, completed_worker, payload)
        if self._worker == completed_worker then self._worker = nil end
        progress:close()
        if not ok then
            UIManager:show(InfoMessage:new{ text = "书源恢复失败：\n" .. tostring(err) })
            return
        end
        local stats = payload and payload.stats
        UIManager:show(Notification:new{
            text = stats and Importer:summarizeSourceStats(stats) or "书源备份已恢复",
        })
        if self.on_changed then pcall(self.on_changed, stats) end
    end)
    if not worker then
        progress:close()
        UIManager:show(InfoMessage:new{ text = "无法开始恢复：\n" .. tostring(start_err) })
        return
    end
    self._worker = worker
end

function SourceBackupView:init()
    self.title = "书源备份"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = self:buildItems()
    self.onMenuSelect = function(menu, item)
        if not item.backup then return end
        local backup = item.backup
        UI.showLater(menu, "restore_source_backup", function()
            return ConfirmBox:new{
                text = "恢复这份书源备份？\n\n"
                    .. os.date("%Y-%m-%d %H:%M", backup.modified)
                    .. " · " .. Storage:formatBytes(backup.size)
                    .. "\n\n备份中的书源会添加或更新；其他现有书源不会删除。",
                ok_text = "开始恢复",
                ok_callback = function()
                    UI.defer(menu, "restore_source_backup_start", function()
                        menu:_startRestore(backup)
                    end)
                end,
            }
        end)
    end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
end

function SourceBackupView:onReturn()
    if self._worker then
        UIManager:show(Notification:new{ text = "请先等待恢复完成，或在进度窗口中取消" })
        return true
    end
    UIManager:close(self, "full")
    return true
end

return SourceBackupView
