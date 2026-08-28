local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local App = require("Leko/App")
local ErrorGuard = require("Leko/ErrorGuard")
local FileManagerTab = require("Leko/FileManagerTab")
local VERSION = require("Leko/Version").version
local EXPECTED_VERSION = "0.15.49-plus"

local Leko = WidgetContainer:extend{
    name = "leko",
    fullname = "Leko Reader · " .. VERSION,
    is_doc_only = false,
}

function Leko:onDispatcherRegisterActions()
    Dispatcher:registerAction("leko_open", {
        category = "none",
        event = "OpenLekoReader",
        title = self.fullname,
        general = true,
    })
end

function Leko:init()
    logger.info("Leko plugin: initializing", self.fullname,
        self.ui and self.ui.document and "reader" or "filemanager")
    if tostring(VERSION) ~= EXPECTED_VERSION then
        local message = string.format(
            "Leko 文件版本不一致（检测到 %s，需要 %s）。请完全退出 KOReader，删除旧的 leko.koplugin 后复制完整的新目录，再重新打开 KOReader。无需重启 Kindle。",
            tostring(VERSION), EXPECTED_VERSION)
        logger.err("Leko plugin: mixed plugin files:", message)
        UIManager:show(InfoMessage:new{ text = message })
        self:onDispatcherRegisterActions()
        if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
            self.ui.menu:registerToMainMenu(self)
        end
        return false
    end
    ErrorGuard:run("initialize", function() App:init() end)
    -- Install only the FileManager build-after wrapper.  The ordinary plugin
    -- menu entry below remains the explicit fallback if the host cannot expose
    -- a compatible FileManagerMenu contract.
    local tab_ok, tab_result = xpcall(function()
        return FileManagerTab:install({ app = App, ui_manager = UIManager })
    end, function(err)
        return debug and debug.traceback and debug.traceback(tostring(err), 2)
            or tostring(err)
    end)
    if not tab_ok then
        logger.err("Leko plugin: file-manager tab installation failed:", tab_result)
    elseif tab_result == false then
        logger.warn("Leko plugin: file-manager tab unavailable; keeping ordinary menu entry")
    end
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
        logger.info("Leko plugin: ordinary menu entry registered")
    else
        logger.err("Leko plugin: host menu registration API is unavailable")
    end
end

function Leko:onFlushSettings()
    pcall(function() require("Leko/SourceHealth"):flushNow() end)
    pcall(function() require("Leko/CoverService"):flushDiagnostics() end)
end

function Leko:onSuspend()
    pcall(function() require("Leko/MobileSourceImport"):notifySuspend() end)
    self:onFlushSettings()
end

function Leko:addToMainMenu(menu_items)
    -- Keep the lightweight FileManager underneath NovelUI. Opening from an
    -- already active document would retain ReaderUI + CREngine in memory.
    if self.ui and self.ui.document then return end
    menu_items.leko = {
        text = self.fullname,
        sorting_hint = "more_tools",
        callback = function() ErrorGuard:run("open bookshelf", function() App:showBookshelf() end) end,
    }
end

function Leko:onOpenLekoReader()
    if self.ui and self.ui.document then
        UIManager:show(InfoMessage:new{
            text = "为避免同时保留普通文档引擎，请先返回 KOReader 文件管理器，再打开 Leko。",
        })
        return true
    end
    ErrorGuard:run("open bookshelf", function() App:showBookshelf() end)
    return true
end

return Leko
