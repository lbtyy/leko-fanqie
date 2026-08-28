-- Leko/providers/Provider.lua
--
-- Native Provider 接口契约（纯文档与默认值，无实现）。
-- 与 LegadoSource/BuiltinSources 平行的第二条内容来源通道：
-- Legado 走规则解析，Provider 走原生代码直连（番茄三源为首批实现）。
--
-- 命名规约：id 形如 "<域>:<源>"（如 "fanqie:official"），域为未来其他
-- Native 源预留；providers/ 目录内模块保持平台无关，不含任何番茄概念。
--
-- 异步铁律：Provider 的任何网络调用禁止在 UI 线程执行，统一经
-- Leko/Fanqie/AsyncProviderTask 进入 ProcessBudget 托管的子进程。
-- 因此本接口的 fetch* 方法约定在子进程内执行（childOp 分发入口）。

local Provider = {
    -- 示例（番茄·官方）：
    id = "fanqie:official",
    name = "番茄·官方",
    capabilities = {
        shelf = false,     -- 账号书架（官方源独有）
        toc = false,       -- 目录
        content = false,   -- 正文
        progress = false,  -- 云端进度（拉取+上传）
        review = false,    -- 段评
        login = false,     -- 需要登录态
        probe = false,     -- 线路检测（聚合源）
    },
}

--- 合规门禁 + 用户开关 + 配置完备 三者与。
-- @return boolean
function Provider:isEnabled() return false end

--- 登录态相关 UI 是否可见。
function Provider:loginSupported() return self.capabilities.login == true end

-- 以下方法全部经 AsyncProviderTask 在子进程内调用，返回值为 JSON 可序列化
-- 结构；失败返回 nil, err（err 为 string 或 { code=..., message=... }，
-- code 为 StageError 编码，鉴权失败统一 AUTH_EXPIRED）。

--- @return shelf_books|nil, err
-- shelf_books = { { provider_book_id, title, author, cover_url,
--                   last_chapter, abstract, last_read_ts, item_id }, ... }
function Provider:fetchShelf() return nil, "not implemented" end

--- @return chapters|nil, err
-- chapters = { { id=item_id, title=string, url=provider_url }, ... }
-- 与 leko book.chapters 同构。
function Provider:fetchToc(provider_book_id) return nil, "not implemented" end

--- @return raw_text|nil, err
-- raw_text 经 FanqieContent:clean() 后即 leko chapter 纯文本。
function Provider:fetchContent(provider_book_id, chapter) return nil, "not implemented" end

--- @return cloud_progress|nil, err
-- cloud_progress = { item_id, index, read_progress }
function Provider:fetchProgress(provider_book_id) return nil, "not implemented" end

--- @return ok|nil, err
function Provider:pushProgress(provider_book_id, item_id, index, fraction)
    return nil, "not implemented"
end

--- @return reviews|nil, err
-- reviews = { items = { { floor, nick, time, text } }, has_more, total }
function Provider:fetchParaReview(provider_book_id, item_id, para_index, page)
    return nil, "not implemented"
end

--- 仅聚合源：多线路探测选优。
function Provider:probe() return nil, "not implemented" end

function Provider:logout() return true end

--- 子进程操作分发入口（AsyncProviderTask 调用）。
-- @param op string 操作名（如 "shelf" / "toc" / "content" / "qr_create"）
-- @param payload table JSON 可序列化参数
-- @return result|nil, err
function Provider:childOp(op, payload) return nil, "not implemented" end

return Provider
