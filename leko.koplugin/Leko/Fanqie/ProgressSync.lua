local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local logger = require("logger")
local DataStorage = require("datastorage")

local Util = require("Leko/Util")
local AsyncProviderTask = require("Leko/Fanqie/AsyncProviderTask")
local FanqieAuth = require("Leko/Fanqie/FanqieAuth")
local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")

-- Leko/Fanqie/ProgressSync.lua
--
-- 番茄云端进度同步：开书拉取 + 翻页节流上传 + 关闭 flush + 启动重试。
-- 设计依据：docs/DESIGN-leko-plus.md §T05；冲突策略：云端为准 +
-- 本地 position 自动转 progress_backup 书签保留（一次性提示）。
-- 网络全部走 AsyncProviderTask：run；fanqie-para URL 协议、HTML/CREngine
-- 链路与 fanqie.async.lua 全部废弃，Cookie 序列化用 Array规避 rapidjson 丢
-- 字符串 key（fanqie/async.lua:41-44 教训）。
-- 本文件新增方法调用见设计文档附录 B 验收 grep。

local PROVIDER_ID = "fanqie:official"
local PENDING_FILE_NAME = "pending_progress.lua"
local SETTINGS_FILE_NAME = "settings.lua"
local UPLOAD_DEBOUNCE_SECONDS = 30
local CONFLICT_NOTIFY_KEY = "fanqie.progress_conflict_notified"
local RETRY_DELAY_AFTER_STARTUP = 5
local RETRY_INTERITEM_DELAY = 2

local ProgressSync = {
    _pending = {},
    _last_upload_at = {},
    _initialized = false,
}

local function dataDir()
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", "fanqie")
end

local function pendingPath()
    return Util.joinPath(dataDir(), PENDING_FILE_NAME)
end

local function settingsPath()
    return Util.joinPath(dataDir(), SETTINGS_FILE_NAME)
end

local function loadPending()
    Util.mkdirp(dataDir())
    local ok, settings = pcall(LuaSettings.open, LuaSettings, pendingPath())
    if not ok or type(settings) ~= "table" then ProgressSync._pending = {} return end
    local data = settings.data
    ProgressSync._pending = {}
    if type(data) == "table" and type(data.items) == "table" then
        for _, item in ipairs(data.items) do
            if type(item) == "table" and item.provider_book_id and item.item_id then
                ProgressSync._pending[#ProgressSync._pending + 1] = item
            end
        end
    end
end

local function savePending()
    Util.mkdirp(dataDir())
    local settings = LuaSettings:open(pendingPath())
    settings.data = {
        version = 1,
        items = ProgressSync._pending,
        updated_at = os.time(),
    }
    pcall(function() settings:flush() end)
end

local function enqueuePending(record)
    local kept = {}
    for _, item in ipairs(ProgressSync._pending) do
        if item.provider_book_id ~= record.provider_book_id then
            kept[#kept + 1] = item
        end
    end
    kept[#kept + 1] = record
    ProgressSync._pending = kept
    savePending()
end

local function clearPending(provider_book_id)
    local kept = {}
    for _, item in ipairs(ProgressSync._pending) do
        if item.provider_book_id ~= provider_book_id then
            kept[#kept + 1] = item
        end
    end
    ProgressSync._pending = kept
    savePending()
end

local function markConflictNotified()
    local settings = LuaSettings:open(settingsPath())
    settings.data = settings.data or {}
    settings.data[CONFLICT_NOTIFY_KEY] = os.time()
    pcall(function() settings:flush() end)
end

local function shouldNotifyConflict()
    local settings = LuaSettings:open(settingsPath())
    return not (settings.data and settings.data[CONFLICT_NOTIFY_KEY])
end

local function buildConflictBackup(book, cloud)
    if not book or not book.position then return nil end
    if not cloud then return nil end
    local local_chapter_idx = tonumber(book.position.chapter) or 0
    local cloud_chapter_idx = tonumber(cloud.index) or 0
    if cloud_chapter_idx <= 0 then return nil end
    if local_chapter_idx == cloud_chapter_idx then return nil end
    return {
        chapter_idx = local_chapter_idx,
        fraction = tonumber(book.position.fraction) or 0,
    }
end

function ProgressSync:_ensureInit()
    if self._initialized then return end
    self._initialized = true
    Util.mkdirp(dataDir())
    loadPending()
end

-- [seam] leko-plus I-2：读取 FanqieConfig:sync.* GUI 开关；缺省值继承 DEFAULTS。
function ProgressSync:syncPullEnabled()
    local ok, FanqieConfig = pcall(require, "Leko/Fanqie/FanqieConfig")
    if not ok or not FanqieConfig then return true end
    local value = FanqieConfig:get("sync", "pull_on_open")
    if value == nil then return true end
    return value == true
end

function ProgressSync:syncUploadEnabled()
    local ok, FanqieConfig = pcall(require, "Leko/Fanqie/FanqieConfig")
    if not ok or not FanqieConfig then return true end
    local value = FanqieConfig:get("sync", "upload_on_close")
    if value == nil then return true end
    return value == true
end

function ProgressSync:start()
    self:_ensureInit()
    if not FanqieCompliance:isEnabled() then return end
    if not FanqieAuth:isLoggedIn() then return end
    UIManager:scheduleIn(RETRY_DELAY_AFTER_STARTUP, function()
        self:_retryPending()
    end)
end

function ProgressSync:_retryPending()
    self:_ensureInit()
    if not FanqieCompliance:isEnabled() then return end
    if not FanqieAuth:isLoggedIn() then return end
    -- [seam] leko-plus I-2：启动重试同属同步链；用户关闭后不重试
    if not self:syncUploadEnabled() then return end
    if #self._pending == 0 then return end
    local i = 1
    local queue = ProgressSync._pending
    local function nextItem()
        if i > #queue then return end
        local item = queue[i]
        AsyncProviderTask:run(PROVIDER_ID, "push_progress", {
            provider_book_id = item.provider_book_id,
            item_id = item.item_id,
            fraction = item.fraction,
            index = item.chapter_index,
        }, function(ok, err, _result, error_code)
            if ok then
                clearPending(item.provider_book_id)
                logger.info("Leko ProgressSync: retry pending uploaded",
                    item.provider_book_id)
            elseif error_code == "AUTH_EXPIRED" then
                logger.warn("Leko ProgressSync: retry pending auth expired, dropping queue")
                clearPending(item.provider_book_id)
            else
                logger.warn("Leko ProgressSync: retry pending failed", tostring(err))
            end
            i = i + 1
            UIManager:scheduleIn(RETRY_INTERITEM_DELAY, nextItem)
        end, { lane = "background", label = "fanqie:retry_pending", timeout_seconds = 20 })
    end
    nextItem()
end

function ProgressSync:pullProgress(book, on_done)
    self:_ensureInit()
    if not book or book.provider ~= PROVIDER_ID then
        if on_done then on_done(false, "non-fanqie book") end return
    end
    if not FanqieCompliance:isEnabled() then
        if on_done then on_done(false, "番茄源未开启") end return
    end
    if not FanqieAuth:isLoggedIn() then
        if on_done then on_done(false, "未登录") end return
    end
    -- [seam] leko-plus I-2：阅读 GUI 同步开关 → FanqieConfig:sync.pull_on_open
    if not self:syncPullEnabled() then
        if on_done then on_done(false, "云端进度拉取开关已关闭") end return
    end
    local provider_book_id = book.provider_book_id
    if not provider_book_id then
        if on_done then on_done(false, "provider_book_id 缺失") end return
    end
    AsyncProviderTask:run(PROVIDER_ID, "progress", {
        provider_book_id = provider_book_id,
    }, function(ok, err, result, error_code)
        if not ok or type(result) ~= "table" or type(result.progress) ~= "table" then
            logger.dbg("Leko ProgressSync: pull failed", tostring(err),
                tostring(error_code))
            if on_done then on_done(false, err, error_code) end
            return
        end
        local backup = buildConflictBackup(book, result.progress)
        if backup then
            enqueuePending({
                provider_book_id = provider_book_id,
                item_id = "backup_" .. tostring(backup.chapter_idx),
                chapter_index = backup.chapter_idx,
                fraction = backup.fraction,
                queued_at = os.time(),
                kind = "progress_backup",
            })
            if shouldNotifyConflict() then
                markConflictNotified()
                local function notify()
                    local Notification = require("ui/widget/notification")
                    if Notification and type(Notification.notify) == "function" then
                        Notification:notify("番茄阅读进度：以云端为准，已将本地进度保存为书签", 6)
                    end
                end
                UIManager:scheduleIn(0.5, notify)
            end
        end
        if on_done then on_done(true, nil, result.progress) end
    end, { lane = "background", label = "fanqie:pull_progress", timeout_seconds = 25 })
end

function ProgressSync:scheduleUpload(book)
    self:_ensureInit()
    if not book or book.provider ~= PROVIDER_ID then return end
    if not FanqieCompliance:isEnabled() then return end
    if not FanqieAuth:isLoggedIn() then return end
    -- [seam] leko-plus I-2：翻页保存时上传开关 → FanqieConfig:sync.upload_on_close
    if not self:syncUploadEnabled() then return end
    local provider_book_id = book.provider_book_id
    local chapter = book.chapters and book.position and book.chapters[book.position.chapter]
    if not provider_book_id or not chapter or not chapter.id then return end
    local now = os.time()
    local last = self._last_upload_at[provider_book_id] or 0
    if now - last < UPLOAD_DEBOUNCE_SECONDS then return end
    self._last_upload_at[provider_book_id] = now
    local item_id = chapter.id
    local chapter_index = tonumber(book.position.chapter) or 0
    local fraction = tonumber(book.position.fraction) or 0
    AsyncProviderTask:run(PROVIDER_ID, "push_progress", {
        provider_book_id = provider_book_id,
        item_id = item_id,
        fraction = fraction,
        index = chapter_index,
    }, function(ok, err, _result, error_code)
        if ok then
            logger.dbg("Leko ProgressSync: uploaded", provider_book_id, chapter_index)
        elseif error_code == "AUTH_EXPIRED" then
            logger.warn("Leko ProgressSync: upload auth expired")
            clearPending(provider_book_id)
        else
            logger.warn("Leko ProgressSync: upload failed, enqueueing", tostring(err))
            enqueuePending({
                provider_book_id = provider_book_id,
                item_id = item_id,
                chapter_index = chapter_index,
                fraction = fraction,
                queued_at = now,
                kind = "upload_retry",
            })
        end
    end, { lane = "background", label = "fanqie:upload_progress", timeout_seconds = 20 })
end

function ProgressSync:flushOnExit(book)
    self:_ensureInit()
    if not book or book.provider ~= PROVIDER_ID then return end
    if not FanqieCompliance:isEnabled() then return end
    if not FanqieAuth:isLoggedIn() then return end
    -- [seam] leko-plus I-2：退出阅读强制上传开关，沿用 upload_on_close
    if not self:syncUploadEnabled() then return end
    local provider_book_id = book.provider_book_id
    local chapter = book.chapters and book.position and book.chapters[book.position.chapter]
    if not provider_book_id or not chapter or not chapter.id then return end
    AsyncProviderTask:run(PROVIDER_ID, "push_progress", {
        provider_book_id = provider_book_id,
        item_id = chapter.id,
        fraction = tonumber(book.position.fraction) or 0,
        index = tonumber(book.position.chapter) or 0,
    }, function(ok, err, _result, error_code)
        if ok then
            clearPending(provider_book_id)
            logger.dbg("Leko ProgressSync: flushed on exit", provider_book_id)
        elseif error_code ~= "AUTH_EXPIRED" then
            enqueuePending({
                provider_book_id = provider_book_id,
                item_id = chapter.id,
                chapter_index = tonumber(book.position.chapter) or 0,
                fraction = tonumber(book.position.fraction) or 0,
                queued_at = os.time(),
                kind = "exit_retry",
            })
        end
    end, { lane = "background", label = "fanqie:flush_exit", timeout_seconds = 15 })
end

return ProgressSync