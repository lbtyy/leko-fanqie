local DataStorage = require("datastorage")
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Util = require("Leko/Util")

-- Leko/Fanqie/FanqieReviewService.lua
--
-- 段评数据层（阶段③，T06）：段评索引/详情缓存服务。
-- 设计依据：docs/DESIGN-leko-plus.md §2.4 + §T06。
--
-- 数据结构（reviews/<book_id>/<item_id>.json）：
--   {
--     saved_at:        number,               -- TTL 判定：now - saved_at > 7d 视为过期
--     index:           {["<para_1based>"]: count, ...},
--     pages:           {["<para_1based>"]: {items, has_more, total}, ...},
--     lru_touch:       number                -- 所属书本的 LRU 时间戳
--   }
--
-- 淘汰策略：
--   1. 段评缓存 TTL = 7 天（live = 604800 秒）；
--   2. 书本 LRU = 50 本（lru_limit = 50）；全局索引 reviews/index.json
--      记录 {books: {book_id: {lru_touch, items: {item_id: saved_at}}}}，
--      超限时按 lru_touch 升序淘汰旧本书（删除整本书目录）；
--   3. 提供 clearForBook(book_id) 给迁移/清理时调用（P1-8 随本书清理）。
--
-- 铁律：
--   1. 段评数据必须经 AsyncProviderTask:run 走子进程，UI 线程仅做编排；
--   2. Cookie 等字符串键 hash table 一律数组形式（fanqie/async.lua:41-44 教训）；
--   3. 当前阶段由 DahuilangProvider (T08) 提供数据；T07 通过读
--      cachedIndex 与 fetchPage 实现段评弹窗；
--   4. 未开启段评或未登录时所有方法为 no-op（合规门禁 + 配置开关）。
--   5. data/leko/providers/fanqie/reviews/ 子目录创建由本模块负责。

local TTL_SECONDS = 7 * 24 * 60 * 60        -- 7 天（PRD §1.3 主理人裁决 #5）
local LRU_BOOK_LIMIT = 50                    -- 50 本（主理人裁决 #5）

local FanqieReviewService = {
    _initialized = false,
    _index = nil,    -- { books = { [book_id] = { lru_touch = N, items = { [item_id] = N } } } }
}

-- 与 Storage:getProviderDataDir("fanqie") 相同的定位公式（保持同步）。
local function fanqieDataDir()
    return Util.joinPath(DataStorage:getDataDir(), "leko", "providers", "fanqie")
end

local function reviewsRoot()
    return Util.joinPath(fanqieDataDir(), "reviews")
end

local function bookDir(book_id)
    return Util.joinPath(reviewsRoot(), tostring(book_id or ""))
end

local function itemPath(book_id, item_id)
    return Util.joinPath(bookDir(book_id), tostring(item_id or "") .. ".json")
end

local function indexPath()
    return Util.joinPath(reviewsRoot(), "index.json")
end

-- ---------------------------------------------------------------------------
-- 全局 LRU 索引（reviews/index.json）—— 书本维度淘汰的依据
-- ---------------------------------------------------------------------------

local function readIndex()
    if FanqieReviewService._index then return FanqieReviewService._index end
    local blank = { version = 1, books = {} }
    local path = indexPath()
    if lfs.attributes(path, "mode") ~= "file" then
        FanqieReviewService._index = blank
        return blank
    end
    local raw = Util.readFile(path, true)
    if not raw or raw == "" then
        FanqieReviewService._index = blank
        return blank
    end
    local ok, decoded = pcall(rapidjson.decode, raw)
    if not ok or type(decoded) ~= "table" or type(decoded.books) ~= "table" then
        FanqieReviewService._index = blank
        return blank
    end
    FanqieReviewService._index = decoded
    return decoded
end

local function writeIndex()
    Util.mkdirp(reviewsRoot())
    local index = FanqieReviewService._index
    if not index or type(index.books) ~= "table" then return end
    local ok, encoded = pcall(rapidjson.encode, {
        version = 1,
        updated_at = os.time(),
        books = index.books,
    })
    if not ok then return end
    pcall(Util.writeFile, indexPath(), encoded, true)
end

local function touchBook(book_id, item_id)
    if not book_id then return end
    local index = readIndex()
    local book_id_str = tostring(book_id)
    local entry = index.books[book_id_str]
    if not entry then
        entry = { lru_touch = 0, items = {} }
        index.books[book_id_str] = entry
    end
    entry.lru_touch = os.time()
    if item_id then entry.items[tostring(item_id)] = os.time() end
end

-- ---------------------------------------------------------------------------
-- 单文件读写（<book_id>/<item_id>.json）
-- ---------------------------------------------------------------------------

local function readEntry(book_id, item_id)
    local path = itemPath(book_id, item_id)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local raw = Util.readFile(path, true)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(rapidjson.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function writeEntry(book_id, item_id, entry)
    Util.mkdirp(bookDir(book_id))
    local ok, encoded = pcall(rapidjson.encode, entry)
    if not ok then return false, tostring(encoded) end
    local saved, err = Util.writeFile(itemPath(book_id, item_id), encoded, true)
    if not saved then return false, err end
    return true
end

local function updateEntry(book_id, item_id, mutator)
    local entry = readEntry(book_id, item_id) or {
        version = 1,
        saved_at = os.time(),
        index = {},
        pages = {},
        lru_touch = os.time(),
    }
    local ok, err = mutator(entry)
    if ok == false then return false, err end
    entry.saved_at = os.time()
    entry.lru_touch = os.time()
    local saved, save_err = writeEntry(book_id, item_id, entry)
    if not saved then return false, save_err end
    touchBook(book_id, item_id)
    return true
end

local function isExpired(entry, now)
    if not entry or type(entry.saved_at) ~= "number" then return true end
    return (now - entry.saved_at) > TTL_SECONDS
end

-- ---------------------------------------------------------------------------
-- 模块初始化（惰性）
-- ---------------------------------------------------------------------------

function FanqieReviewService:_ensureInit()
    if self._initialized then return end
    self._initialized = true
    Util.mkdirp(reviewsRoot())
    readIndex()
end

-- ---------------------------------------------------------------------------
-- 公共 API
-- ---------------------------------------------------------------------------

--- 读取磁盘缓存的索引（同步）。
-- @param provider_book_id string
-- @param item_id string
-- @return nil | { saved_at, index = { [para]=count }, pages, lru_touch, expired = bool }
function FanqieReviewService:cachedIndex(provider_book_id, item_id)
    self:_ensureInit()
    local entry = readEntry(provider_book_id, item_id)
    if not entry then return nil end
    return {
        saved_at = entry.saved_at,
        index = type(entry.index) == "table" and entry.index or {},
        pages = type(entry.pages) == "table" and entry.pages or {},
        lru_touch = entry.lru_touch,
        expired = isExpired(entry, os.time()),
    }
end

--- 拉取索引（异步；走 AsyncProviderTask 子进程，UI 线程轻量回调）。
-- 缓存命中且未过期直接返回；否则拉取后落盘 + touchBook。
-- @param provider_id string 如 "fanqie:dahuilang"（仅支持段评能力的 provider）
-- @param provider_book_id string
-- @param item_id string
-- @param callback function(ok, err, cached_table|nil) cached_table = {saved_at, index}
function FanqieReviewService:fetchIndex(provider_id, provider_book_id, item_id, callback)
    self:_ensureInit()
    callback = callback or function() end
    if not provider_id or not provider_book_id or not item_id then
        callback(false, "段评索引参数不完整")
        return
    end
    local cached = self:cachedIndex(provider_book_id, item_id)
    if cached and not cached.expired then
        callback(true, nil, cached)
        return
    end
    local AsyncProviderTask = require("Leko/Fanqie/AsyncProviderTask")
    AsyncProviderTask:run(provider_id, "review_index", {
        provider_book_id = provider_book_id,
        item_id = item_id,
    }, function(ok, err, result, error_code)
        if not ok or type(result) ~= "table" then
            logger.dbg("Leko FanqieReviewService: fetchIndex failed", tostring(err),
                tostring(error_code))
            callback(false, err, cached)
            return
        end
        -- result = { index = { ["3"]=count, ... }, source = "remote" }
        local index_map = type(result.index) == "table" and result.index or nil
        if index_map then
            updateEntry(provider_book_id, item_id, function(entry)
                for k, v in pairs(index_map) do entry.index[tostring(k)] = tonumber(v) or 0 end
                return true
            end)
            self:pruneLru(LRU_BOOK_LIMIT)
        end
        callback(true, nil, self:cachedIndex(provider_book_id, item_id))
    end, { lane = "background", label = "fanqie:review_index", timeout_seconds = 25 })
end

--- 拉取某段落的评论分页（异步；按需缓存）。
-- @param callback function(ok, err, page_table)
function FanqieReviewService:fetchPage(provider_id, provider_book_id, item_id, para_index, page, callback)
    self:_ensureInit()
    callback = callback or function() end
    if not provider_id or not provider_book_id or not item_id then
        callback(false, "段评分页参数不完整")
        return
    end
    page = math.max(1, tonumber(page) or 1)
    para_index = math.max(1, tonumber(para_index) or 1)
    local AsyncProviderTask = require("Leko/Fanqie/AsyncProviderTask")
    AsyncProviderTask:run(provider_id, "review_page", {
        provider_book_id = provider_book_id,
        item_id = item_id,
        para_index = para_index,
        page = page,
    }, function(ok, err, result, error_code)
        if not ok or type(result) ~= "table" then
            logger.dbg("Leko FanqieReviewService: fetchPage failed", tostring(err),
                tostring(error_code))
            callback(false, err)
            return
        end
        local items = type(result.items) == "table" and result.items or {}
        local has_more = result.has_more == true
        local total = tonumber(result.total) or #items
        updateEntry(provider_book_id, item_id, function(entry)
            entry.pages[tostring(para_index)] = {
                items = items,
                has_more = has_more,
                total = total,
                page = page,
                saved_at = os.time(),
            }
            return true
        end)
        self:pruneLru(LRU_BOOK_LIMIT)
        callback(true, nil, {
            items = items,
            has_more = has_more,
            total = total,
            page = page,
        })
    end, { lane = "foreground", label = "fanqie:review_page", timeout_seconds = 20 })
end

--- 清空某本书的段评缓存（P1-8 随本书清理）。
function FanqieReviewService:clearForBook(provider_book_id)
    self:_ensureInit()
    if not provider_book_id then return end
    local index = readIndex()
    index.books[tostring(provider_book_id)] = nil
    writeIndex()
    local dir = bookDir(provider_book_id)
    if lfs.attributes(dir, "mode") == "directory" then
        pcall(function()
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    pcall(lfs.rmdir, Util.joinPath(dir, entry))
                    pcall(os.remove, Util.joinPath(dir, entry))
                end
            end
            pcall(lfs.rmdir, dir)
        end)
    end
end

--- 书本维度 LRU 淘汰（limit 默认 50）。
-- 超出时按 lru_touch 升序淘汰整本书（目录 + 索引项）。
function FanqieReviewService:pruneLru(limit)
    self:_ensureInit()
    limit = tonumber(limit) or LRU_BOOK_LIMIT
    local index = readIndex()
    local books = index.books or {}
    local keys = {}
    for k in pairs(books) do keys[#keys + 1] = k end
    if #keys <= limit then return end
    table.sort(keys, function(a, b)
        return (tonumber(books[a].lru_touch) or 0) < (tonumber(books[b].lru_touch) or 0)
    end)
    local to_remove = #keys - limit
    for i = 1, to_remove do
        self:clearForBook(keys[i])
    end
    writeIndex()
end

--- 段评能力探测（前端入口判定是否渲染段落标记）。
-- @return bool  (provider 当前能力 + 合规门禁 + 用户开关)
function FanqieReviewService:enabledFor(provider_id)
    if not provider_id then return false end
    local FanqieCompliance = require("Leko/Fanqie/FanqieCompliance")
    if not FanqieCompliance:isEnabled() then return false end
    local FanqieConfig = require("Leko/Fanqie/FanqieConfig")
    local enabled = FanqieConfig:get("review", "enabled")
    if enabled == false then return false end
    local ProviderRegistry = require("Leko/providers/ProviderRegistry")
    local caps = ProviderRegistry:capabilitiesOf(provider_id)
    return caps and caps.review == true
end

return FanqieReviewService
