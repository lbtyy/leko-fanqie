local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local ErrorGuard = {}

local function tracebackMessage(err)
    if debug and debug.traceback then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

function ErrorGuard:run(label, callback)
    local ok, result_a, result_b, result_c = xpcall(callback, tracebackMessage)
    if ok then return true, result_a, result_b, result_c end

    local message = tostring(result_a or "unknown error")
    logger.err("Leko", tostring(label or "operation"), message)
    UIManager:show(InfoMessage:new{
        text = "Leko 操作失败，不会退出 KOReader。\n\n" .. message,
    })
    return false, message
end

function ErrorGuard:wrap(label, callback)
    return function(...)
        local args = { ... }
        return self:run(label, function()
            return callback(unpack(args))
        end)
    end
end

return ErrorGuard
