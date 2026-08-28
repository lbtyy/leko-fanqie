local UIManager = require("ui/uimanager")

local SourceResultActions = {}

local function sourceId(result)
    return tostring(result and result.source_id or "")
end

local function sourceName(result, summary)
    return tostring((summary and summary.name) or (result and result.source_name) or "书源")
end

local function currentEnabled(result, summary)
    if summary and summary.enabled ~= nil then return summary.enabled ~= false end
    if result and result.source_enabled ~= nil then return result.source_enabled ~= false end
    return result and result.enabled ~= false or true
end

function SourceResultActions:show(owner, result, options)
    options = options or {}
    local id = sourceId(result)
    if id == "" then return false end

    -- Keep the shared result list cheap to load in subprocesses and desktop
    -- parser tests. These widgets and storage services are only needed after
    -- a user actually holds a source row.
    local ButtonDialog = require("ui/widget/buttondialog")
    local Notification = require("ui/widget/notification")
    local Storage = require("Leko/Storage")
    local SourcePreference = require("Leko/SourcePreference")
    local UI = require("Leko/UI")
    return UI.defer(owner, "source_result_actions_" .. id, function()
        local summary = Storage:getSourceSummary(id)
        local enabled = currentEnabled(result, summary)
        local title = sourceName(result, summary)
        local dialog
        local buttons = {}

        if type(options.primary_callback) == "function" then
            buttons[#buttons + 1] = {{
                text = options.primary_text or "打开",
                callback = function()
                    UIManager:close(dialog)
                    options.primary_callback(result)
                end,
            }}
        end

        local function setPriority(value, label)
            UIManager:close(dialog)
            SourcePreference:set(result, value)
            if type(options.on_priority_changed) == "function" then
                pcall(options.on_priority_changed, result, value)
            end
            if owner and type(owner.refreshItems) == "function" then owner:refreshItems() end
            UIManager:show(Notification:new{ text = title .. "：" .. label .. "；下次搜索生效" })
        end
        buttons[#buttons + 1] = {{
            text = "↑ 优先搜索",
            callback = function() setPriority(SourcePreference.PRIORITY, "已设为优先搜索") end,
        }}
        buttons[#buttons + 1] = {{
            text = "· 自动排序",
            callback = function() setPriority(SourcePreference.AUTO, "已恢复自动排序") end,
        }}
        buttons[#buttons + 1] = {{
            text = "↓ 靠后搜索",
            callback = function() setPriority(SourcePreference.LAST, "已设为靠后搜索") end,
        }}

        buttons[#buttons + 1] = {{
            text = enabled and "停用此书源" or "启用此书源",
            callback = function()
                UIManager:close(dialog)
                local next_enabled = Storage:toggleSource(id)
                if next_enabled == nil then
                    UIManager:show(Notification:new{ text = "无法更新书源状态：" .. title })
                    return
                end
                result.source_enabled = next_enabled
                if type(options.on_toggled) == "function" then
                    pcall(options.on_toggled, result, next_enabled)
                end
                if owner and type(owner.refreshItems) == "function" then owner:refreshItems() end
                UIManager:show(Notification:new{ text = title .. (next_enabled and "已启用" or "已停用") })
            end,
        }}

        buttons[#buttons + 1] = {{
            text = "取消",
            callback = function() UIManager:close(dialog) end,
        }}
        dialog = ButtonDialog:new{ modal = true, title = title, buttons = buttons }
        UIManager:show(dialog)
    end)
end

return SourceResultActions
