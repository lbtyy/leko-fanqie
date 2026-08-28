local logger = require("logger")

local Storage = require("Leko/Storage")

-- Leko/Fanqie/FanqieShelfService.lua
--
-- 番茄账号书架 → leko 统一书架的领域服务。
-- 移植自 fanqie/bookshelf.lua:297-340 get_shelf 的字段映射语义，适配点：
--   1. fanqie 的 shelf 内存/文件两层缓存由 leko 原生 per-book 存储接管
--      （books/<fq*>/book.lua + 书架 summary），失败保旧数据天然成立：
--      网络失败时不做任何写盘，书架保留上一次成功同步的记录；
--   2. 网络出 UI 线程走 AsyncProviderTask（lane="background"），
--      本文件只负责映射与合并，不直接发起任何网络请求；
--   3. 番茄书 id = "fq" + provider_book_id（§2.2），position/chapters
--      等 leko 原生字段在合并时保留。

local PROVIDER_ID = "fanqie:official"

local FanqieShelfService = {}

local function asyncProviderTask()
    return require("Leko/Fanqie/AsyncProviderTask")
end

--- 拉取账号书架（UI 线程异步）。
-- @param opts table { force=bool }
-- @param callback function(books|nil, err) books 为 toLekoBooks 之后的 leko 书记录数组
-- @return worker|nil, err
function FanqieShelfService:syncShelf(opts, callback)
    opts = opts or {}
    return asyncProviderTask():run(PROVIDER_ID, "shelf", {
        force = opts.force == true,
    }, function(ok, err, result)
        if not ok then
            callback(nil, tostring(err or "书架同步失败"))
            return
        end
        local books = self:toLekoBooks(result and result.books or {})
        callback(books, nil)
    end, { lane = "background", label = "fanqie:shelf" })
end

--- 把 Provider 的 shelf_books 映射为 leko book 记录（设计文档 §2.2）。
-- 移植自 fanqie/bookshelf.lua:313-338 的字段选择（book_id/title/author/
-- cover/desc/item_id/serial_count/read_progress）。
-- @param shelf_books table Provider fetchShelf 返回的数组
-- @return table leko book 记录数组
function FanqieShelfService:toLekoBooks(shelf_books)
    local books = {}
    for _, item in ipairs(shelf_books or {}) do
        local provider_book_id = tostring(item.provider_book_id or item.book_id or "")
        if provider_book_id ~= "" then
            local total_chapters = tonumber(item.last_chapter or item.total_chapters or 0) or 0
            books[#books + 1] = {
                id = "fq" .. provider_book_id,
                title = tostring(item.title or "未知"),
                author = tostring(item.author or ""),
                provider = PROVIDER_ID,
                provider_book_id = provider_book_id,
                provider_source = PROVIDER_ID,
                source_name = "番茄·官方",
                book_url = "https://fanqienovel.com/page/" .. provider_book_id,
                cover = item.cover_url,
                selected_cover_url = item.cover_url,
                intro = tostring(item.abstract or ""),
                chapters = {},
                chapter_count = total_chapters,
                detail_resolved = true,
                position = { chapter = 1, paragraph = 1, char = 1 },
                last_read_at = tonumber(item.last_read_ts or 0) or 0,
                fanqie_item_id = item.item_id and tostring(item.item_id) or nil,
            }
        end
    end
    return books
end

--- 并入统一书架：已存在的番茄书保留 chapters/position/封面落盘状态，
-- 只更新元数据；新书直接入库。网络失败时调用方不调用本函数，
-- 书架自然保留上一次成功的数据（两层缓存语义由 leko 存储承担）。
-- @param books table toLekoBooks 的输出
-- @return added number, updated number
function FanqieShelfService:mergeIntoBookshelf(books)
    local added, updated = 0, 0
    for _, incoming in ipairs(books or {}) do
        local existing = Storage:loadBook(incoming.id)
        if existing then
            -- 保留阅读相关的本地状态，只刷新元数据字段。
            for _, key in ipairs({
                "title", "author", "provider", "provider_book_id", "provider_source",
                "source_name", "book_url", "intro", "fanqie_item_id", "last_read_at",
            }) do
                if incoming[key] ~= nil then existing[key] = incoming[key] end
            end
            -- 封面：本地已有封面文件时不回退；云端给了新地址则更新描述符。
            if incoming.cover and incoming.cover ~= "" then
                existing.cover = incoming.cover
                existing.selected_cover_url = incoming.selected_cover_url
            end
            existing.detail_resolved = true
            existing.updated_at = os.time()
            Storage:saveBook(existing, { force_summary = true })
            updated = updated + 1
        else
            Storage:addBookToLibrary(incoming)
            added = added + 1
        end
    end
    logger.info("Leko FanqieShelfService: merged fanqie shelf, added", added, "updated", updated)
    return added, updated
end

return FanqieShelfService
