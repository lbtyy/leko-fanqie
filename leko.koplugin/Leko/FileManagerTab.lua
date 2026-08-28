-- Build-after integration for the KOReader FileManager top tab bar.
--
-- This module deliberately wraps only FileManagerMenu:setUpdateItemTable.
-- The reader menu, shared menu widget, menu order files, and other plugins
-- remain outside
-- this integration boundary.

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local App = require("Leko/App")

local FileManagerTab = {
    id = "leko_bookshelf",
    marker = "_leko_bookshelf_tab",
    custom_icon = "leko.bookshelf",
    fallback_icon = "book.opened",
    injection_marker = "_leko_filemanager_bookshelf_injection",
    wrapper_marker = "_leko_filemanager_bookshelf_wrapper",
    previous_marker = "_leko_filemanager_bookshelf_previous",
    enabled_marker = "_leko_filemanager_bookshelf_enabled",
    diagnostics = {},
    active_menus = setmetatable({}, { __mode = "k" }),
}

local pack = table.pack or function(...)
    return { n = select("#", ...), ... }
end
local unpack_values = table.unpack or unpack

local function traceback_message(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function join_path(left, right)
    if left:sub(-1) == "/" or left:sub(-1) == "\\" then
        return left .. right
    end
    return left .. "/" .. right
end

local function module_directory()
    if not debug or not debug.getinfo then return nil end
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)[/\\]Leko[/\\][^/\\]+$")
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local bytes = file:read("*a")
    file:close()
    return bytes
end

local function log_once(self, key, message)
    if self.diagnostics[key] then return end
    self.diagnostics[key] = true
    logger.warn("Leko FileManager tab:", message)
end

function FileManagerTab:_report_failure(message)
    message = tostring(message or "unknown error")
    logger.err("Leko FileManager tab:", message)
    local ok, display_error = xpcall(function()
        UIManager:show(InfoMessage:new{
            text = "Leko 书架暂时无法打开\n" .. message,
        })
    end, traceback_message)
    if not ok then
        logger.err("Leko FileManager tab: error message failed:", tostring(display_error))
    end
end

local function is_marker(item)
    if type(item) ~= "table" then return false end
    -- Both fields are written by Leko.  Requiring both prevents an unrelated
    -- item that happens to use one field from being treated as our tab.
    return item.id == FileManagerTab.id and item[FileManagerTab.marker] == true
end

local function has_identity_marker(item)
    if type(item) ~= "table" then return false end
    -- A partially preserved old Leko item is still safe to remove.  The
    -- inserted item always carries the stable id and the private marker.
    return item.id == FileManagerTab.id or item[FileManagerTab.marker] == true
end

local function text_matches(item, values)
    if type(item) ~= "table" then return false end
    for _, field in ipairs({ "id", "name", "text", "icon" }) do
        local value = item[field]
        if type(value) == "string" then
            for _, expected in ipairs(values) do
                if value == expected then return true end
                if value:lower() == expected:lower() then return true end
            end
        end
    end
    return false
end

local function is_search_tab(item)
    return text_matches(item, { "search", "Search", "搜索", "appbar.search" })
end

local function is_main_tab(item)
    return text_matches(item, { "main", "Main", "menu", "Menu", "主菜单", "菜单", "appbar.menu" })
end

local function validate_tab_table(tab_item_table)
    if type(tab_item_table) ~= "table" then
        return false, "tab_item_table is not a table"
    end

    local maximum = 0
    for key, value in pairs(tab_item_table) do
        -- KOReader's MenuSorter keeps native metadata beside the numeric tab
        -- sequence (including host metadata). Only numeric keys are
        -- array positions; other keys belong to the host or another plugin.
        if type(key) == "number" then
            if key ~= key or key < 1 or key % 1 ~= 0 then
                return false, "tab_item_table has an invalid numeric index: " .. tostring(key)
            end
            if type(value) ~= "table" then
                return false, "tab_item_table numeric item " .. tostring(key) .. " is not a table"
            end
            if key > maximum then maximum = key end
        end
    end
    for index = 1, maximum do
        if tab_item_table[index] == nil then
            return false, "tab_item_table has an array hole"
        end
    end
    return true
end

local function tab_has_content(item)
    if type(item) ~= "table" then return false end
    for index = 1, #item do
        if type(item[index]) == "table" then return true end
    end
    return false
end

function FileManagerTab:_schedule_next_tick(callback)
    local manager = self.ui_manager or UIManager
    if type(manager.nextTick) == "function" then
        return manager:nextTick(callback)
    end
    if type(manager.scheduleIn) == "function" then
        return manager:scheduleIn(0, callback)
    end
    if type(manager.tickAfterNext) == "function" then
        return manager:tickAfterNext(callback)
    end
    error("UIManager has no safe next-tick scheduler")
end

function FileManagerTab:_activate(menu)
    local ok, result = xpcall(function()
        if type(menu) ~= "table" then
            error("FileManager menu instance is missing")
        end
        if type(menu.onCloseFileManagerMenu) ~= "function" then
            error("FileManager standard close method is unavailable")
        end

        local close_result = menu:onCloseFileManagerMenu()
        if close_result == false then
            error("FileManager standard close method returned false")
        end

        return self:_schedule_next_tick(function()
            local open_ok, open_error = xpcall(function()
                local app = self.app or App
                if type(app) ~= "table" or type(app.showBookshelf) ~= "function" then
                    error("App:showBookshelf is unavailable")
                end
                local open_result = app:showBookshelf()
                if open_result == false then
                    error("App:showBookshelf returned false")
                end
            end, traceback_message)
            if not open_ok then
                self:_report_failure(open_error)
            end
        end)
    end, traceback_message)

    if not ok then
        self:_report_failure(result)
        return false, result
    end
    return true, result
end

function FileManagerTab:_make_tab(menu, icon)
    local activate = function()
        return self:_activate(menu)
    end
    return {
        id = self.id,
        text = "Leko 书架",
        name = "Leko 书架",
        icon = icon,
        remember = false,
        [self.marker] = true,
        -- A real child keeps the tab non-empty on KOReader builds that finish
        -- the tab switch after the callback has closed the FileManager menu.
        {
            id = "leko_bookshelf_open",
            text = "打开 Leko 书架",
            callback = activate,
        },
        callback = activate,
    }
end

function FileManagerTab:injectLekoBookshelfTab(menu)
    if not self.enabled then return false end
    if type(menu) ~= "table" then
        log_once(self, "missing_menu", "menu instance is missing; keeping the ordinary entry")
        return false
    end

    local tab_item_table = menu.tab_item_table
    local valid, reason = validate_tab_table(tab_item_table)
    if not valid then
        log_once(self, "invalid_table", reason .. "; skipping top-bar injection")
        return false
    end

    local existing
    for index = #tab_item_table, 1, -1 do
        local item = tab_item_table[index]
        if has_identity_marker(item) then
            if not existing and is_marker(item) then
                existing = table.remove(tab_item_table, index)
            else
                -- Only remove entries carrying Leko's identity markers.
                table.remove(tab_item_table, index)
            end
        end
    end

    local search_index
    local main_index
    for index, item in ipairs(tab_item_table) do
        if not search_index and is_search_tab(item) then search_index = index end
        if not main_index and is_main_tab(item) then main_index = index end
    end

    if search_index and main_index and search_index >= main_index then
        log_once(self, "unexpected_order", "Search/Main tab order is inconsistent; skipping top-bar injection")
        if existing then
            -- Restore the only previously valid Leko item at the end.  This is
            -- still limited to Leko's own item and avoids changing native tabs.
            table.insert(tab_item_table, existing)
        end
        return false
    end

    local insertion_index
    if search_index then
        insertion_index = search_index + 1
    elseif main_index then
        insertion_index = main_index
    else
        insertion_index = #tab_item_table + 1
    end

    local item = existing or self:_make_tab(menu, self.icon_name)
    item.id = self.id
    item.text = "Leko 书架"
    item.name = "Leko 书架"
    item.icon = self.icon_name
    item.remember = false
    item[self.marker] = true
    if not tab_has_content(item) then
        item[1] = {
            id = "leko_bookshelf_open",
            text = "打开 Leko 书架",
            callback = function() return self:_activate(menu) end,
        }
    end
    item.callback = function() return self:_activate(menu) end

    table.insert(tab_item_table, insertion_index, item)
    self.active_menus[menu] = true
    return true
end

function FileManagerTab:_safe_inject(menu)
    -- This boundary covers only Leko's post-processing.  The previous layer
    -- is deliberately outside it in the wrapper below, so native/plugin
    -- exceptions from the existing chain are never swallowed.
    local ok, result = xpcall(function()
        return self:injectLekoBookshelfTab(menu)
    end, traceback_message)
    if not ok then
        log_once(self, "injection_error", "post-build injection failed: " .. tostring(result))
        return false
    end
    return result
end

function FileManagerTab:_remove_from_menu(menu)
    if type(menu) ~= "table" or type(menu.tab_item_table) ~= "table" then return end
    for index = #menu.tab_item_table, 1, -1 do
        if has_identity_marker(menu.tab_item_table[index]) then
            table.remove(menu.tab_item_table, index)
        end
    end
end

local function builtin_icon_exists(icon)
    local lfs = require("libs/libkoreader-lfs")
    for _, directory in ipairs({ "resources/icons/mdlight", "resources/icons", "resources" }) do
        if lfs.attributes(directory .. "/" .. icon .. ".svg", "mode") == "file" then
            return true
        end
        if file_exists(directory .. "/" .. icon .. ".svg") then
            return true
        end
    end
    return false
end

function FileManagerTab:_register_custom_icon()
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local data_dir = DataStorage:getDataDir()
    local icons_dir = join_path(data_dir, "icons")
    if lfs.attributes(icons_dir, "mode") ~= "directory" then
        local created, create_error = lfs.mkdir(icons_dir)
        if not created and lfs.attributes(icons_dir, "mode") ~= "directory" then
            return nil, "cannot create KOReader user icon directory: " .. tostring(create_error)
        end
    end

    local target = join_path(icons_dir, self.custom_icon .. ".svg")
    local directory = module_directory()
    if not directory then return nil, "cannot locate the bundled Leko icon" end
    local source_path = join_path(join_path(directory, "resources/icons"), self.custom_icon .. ".svg")
    local bytes = read_file(source_path)
    if not bytes then return nil, "bundled Leko icon is missing" end
    if not bytes or bytes == "" then return nil, "bundled Leko icon is empty" end

    if read_file(target) ~= bytes then
        local previous_bytes = read_file(target)
        local destination = io.open(target, "wb")
        if not destination then return nil, "cannot register the bundled Leko icon" end
        local write_ok, write_error = destination:write(bytes)
        destination:close()
        if not write_ok or read_file(target) ~= bytes then
            -- Best-effort restoration keeps a failed icon refresh from damaging
            -- the previously working registered asset.
            if previous_bytes then
                local restore = io.open(target, "wb")
                if restore then restore:write(previous_bytes); restore:close() end
            end
            return nil, "cannot finish registering the bundled Leko icon: " .. tostring(write_error)
        end
    end

    -- Clean up the short-lived development workaround if it was ever installed.
    os.remove(join_path(icons_dir, "leko.bookshelf.v2.svg"))

    -- IconWidget snapshots its lookup directories when first required.  Force
    -- that normal KOReader resolver to see the registered file now; this also
    -- avoids installing a tab whose icon would later resolve to a checkerboard
    -- or the generic missing-icon asset.
    local icon_module_ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if not icon_module_ok or type(IconWidget) ~= "table" or type(IconWidget.new) ~= "function" then
        return nil, "KOReader icon resolver is unavailable"
    end
    local icon_instance_ok, icon_instance = pcall(function()
        return IconWidget:new{ icon = self.custom_icon }
    end)
    local resolved_path = icon_instance_ok and icon_instance and icon_instance.file
    local normalize_path = function(path)
        return tostring(path or ""):gsub("\\\\", "/"):gsub("^%./", ""):lower()
    end
    if not icon_instance_ok or type(icon_instance) ~= "table"
            or not resolved_path or not file_exists(resolved_path)
            or normalize_path(resolved_path) ~= normalize_path(target) then
        return nil, "KOReader did not resolve the registered Leko icon"
    end
    if icon_instance.free then icon_instance:free() end
    return self.custom_icon
end

function FileManagerTab:_resolve_icon()
    local ok, icon_or_error, detail = xpcall(function()
        return self:_register_custom_icon()
    end, traceback_message)
    if ok and icon_or_error then
        return icon_or_error
    end
    local reason = ok and detail or icon_or_error
    log_once(self, "icon_registration", tostring(reason or "custom icon registration failed"))
    if builtin_icon_exists(self.fallback_icon) then
        return self.fallback_icon
    end
    log_once(self, "icon_unavailable", "no safe custom or built-in icon is available")
    return nil
end

function FileManagerTab:install(options)
    options = options or {}
    self.app = options.app or self.app or App
    self.ui_manager = options.ui_manager or self.ui_manager or UIManager

    local menu_class = options.file_manager_menu
    if not menu_class then
        local required, required_class = pcall(require, "apps/filemanager/filemanagermenu")
        if not required then
            log_once(self, "filemanager_module", "FileManagerMenu is unavailable; ordinary entry remains active")
            return false
        end
        menu_class = required_class
    end
    if type(menu_class) ~= "table" or type(menu_class.setUpdateItemTable) ~= "function" then
        log_once(self, "filemanager_method", "FileManagerMenu:setUpdateItemTable is unavailable; ordinary entry remains active")
        return false
    end

    self.menu_class = menu_class
    menu_class[self.enabled_marker] = true

    if menu_class[self.injection_marker] then
        -- Leko is already in the wrapper chain.  Re-enabling the flag is safe
        -- and, importantly, does not wrap a later SimpleUI/other-plugin layer.
        self.enabled = true
        return true
    end

    local icon = options.icon or self:_resolve_icon()
    if not icon then
        menu_class[self.enabled_marker] = false
        self.enabled = false
        return false
    end
    self.icon_name = icon

    local previous = menu_class.setUpdateItemTable
    local wrapper = function(menu, ...)
        -- Do not catch this call: exceptions and all return values from the
        -- already-installed layer must retain their native behavior.
        local results = pack(previous(menu, ...))
        FileManagerTab:_safe_inject(menu)
        return unpack_values(results, 1, results.n)
    end

    menu_class[self.previous_marker] = previous
    menu_class[self.wrapper_marker] = wrapper
    menu_class[self.injection_marker] = true
    menu_class[self.enabled_marker] = true
    menu_class.setUpdateItemTable = wrapper
    self.previous_set_update_item_table = previous
    self.wrapper = wrapper
    self.enabled = true
    return true
end

function FileManagerTab:teardown()
    local menu_class = self.menu_class
    if not menu_class then return true end
    self.enabled = false
    menu_class[self.enabled_marker] = false

    for menu in pairs(self.active_menus) do
        self:_remove_from_menu(menu)
        self.active_menus[menu] = nil
    end

    -- If another plugin wrapped us after installation, leave that wrapper and
    -- the rest of its chain intact.  The disabled flag stops future Leko
    -- injections; a later rebuild can still be owned by the other plugin.
    if menu_class.setUpdateItemTable == menu_class[self.wrapper_marker] then
        menu_class.setUpdateItemTable = menu_class[self.previous_marker]
        menu_class[self.injection_marker] = false
    end
    return true
end

return FileManagerTab
