local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Http = require("Leko/Http")
local LegadoSource = require("Leko/LegadoSource")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local Importer = {}

local function uniqueBookId(seed)
    return "book-" .. Util.hashId(seed .. "\n" .. tostring(os.time()) .. "\n" .. tostring(math.random()))
end

function Importer:importTextFile(path)
    local content, err = Util.readFile(path)
    if not content then return nil, err end
    local stem = Util.splitext(Util.basename(path))
    local chapters = Util.splitTextIntoChapters(content, stem)
    local book = {
        id = uniqueBookId(path),
        title = stem,
        author = "",
        intro = "从本地 TXT 导入",
        imported_from = path,
        created_at = os.time(),
        updated_at = os.time(),
        last_read_at = 0,
        position = { chapter = 1, paragraph = 1, char = 1 },
        chapters = {},
    }
    for index, chapter_data in ipairs(chapters) do
        table.insert(book.chapters, {
            id = Util.hashId(path .. "#" .. index .. chapter_data.title),
            title = chapter_data.title,
            index = index,
            downloaded = false,
        })
    end
    Util.mkdirp(Storage:getBookDir(book.id))
    Util.mkdirp(Storage:getChapterDir(book.id))
    for index, chapter_data in ipairs(chapters) do
        local ok, save_err = Storage:saveChapter(book, index, chapter_data.content)
        if not ok then return nil, save_err end
    end
    book._toc_dirty = true
    Storage:saveBook(book, { force_toc = true })
    return book
end

function Importer:importDirectory(path)
    local entries = {}
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local stem, extension = Util.splitext(entry)
            if extension == "txt" and lfs.attributes(Util.joinPath(path, entry), "mode") == "file" then
                table.insert(entries, { filename = entry, stem = stem })
            end
        end
    end
    table.sort(entries, function(a, b) return Util.naturalLess(a.filename, b.filename) end)
    if #entries == 0 then return nil, "目录中没有 TXT 文件" end

    local book = {
        id = uniqueBookId(path),
        title = Util.basename(path),
        author = "",
        intro = "从本地章节目录导入",
        imported_from = path,
        created_at = os.time(),
        updated_at = os.time(),
        last_read_at = 0,
        position = { chapter = 1, paragraph = 1, char = 1 },
        chapters = {},
    }
    for index, item in ipairs(entries) do
        local chapter_path = Util.joinPath(path, item.filename)
        local content, err = Util.readFile(chapter_path)
        if not content then return nil, err end
        local first_line = Util.trim((content:match("([^\r\n]+)") or ""))
        local has_heading = Util.looksLikeChapterTitle(first_line)
        local title = has_heading and first_line or item.stem
        if has_heading then
            content = content:gsub("^[^\r\n]+[\r\n]*", "", 1)
        end
        table.insert(book.chapters, {
            id = Util.hashId(chapter_path),
            title = title,
            index = index,
            downloaded = false,
        })
        Util.mkdirp(Storage:getBookDir(book.id))
        Util.mkdirp(Storage:getChapterDir(book.id))
        local ok, save_err = Storage:saveChapter(book, index, content)
        if not ok then return nil, save_err end
    end
    book._toc_dirty = true
    Storage:saveBook(book, { force_toc = true })
    return book
end

local function decodeSourceItems(raw)
    raw = tostring(raw or ""):gsub("^\239\187\191", "")
    local ok, decoded = pcall(rapidjson.decode, raw)
    if not ok or type(decoded) ~= "table" then return nil, "无效书源 JSON" end
    if decoded.bookSourceName or decoded.searchUrl then return { decoded } end
    return decoded
end

local function notifyImportStage(options, current, stage, total)
    local callback = options and options.on_stage
    if type(callback) == "function" then pcall(callback, current, stage, total) end
end

local function sourceImportStats(sources)
    local stats = { total = 0, supported = 0, unsupported = 0 }
    for _, source in ipairs(sources or {}) do
        stats.total = stats.total + 1
        if source.searchable ~= false and source.supported ~= false then
            stats.supported = stats.supported + 1
        else
            stats.unsupported = stats.unsupported + 1
        end
    end
    return stats
end

function Importer:importSourcesText(raw, origin_name, options)
    options = options or {}
    raw = tostring(raw or "")
    if raw == "" then return nil, "书源 JSON 为空" end

    -- Preserve the exact imported pack before decoding it. Once decoded, drop
    -- the multi-MiB raw string immediately so low-memory Kindle devices don't
    -- retain raw JSON + decoded trees + normalized trees at the same time.
    notifyImportStage(options, 2, "保存原始书源备份……", 5)
    if options.backup ~= false then
        local backup_ok, backup_err = Storage:backupImportedSources(raw,
            origin_name or "network-sources.json")
        if not backup_ok then return nil, tostring(backup_err or "无法备份原始书源") end
    end

    notifyImportStage(options, 3, "解析书源 JSON……", 5)
    local source_items, err = decodeSourceItems(raw)
    raw = nil
    collectgarbage("collect")
    if not source_items then return nil, err end

    -- Normalize in place. The previous implementation built a second 459-item
    -- array while the complete rapidjson tree was still alive, which creates a
    -- large avoidable peak on 256 MiB Kindles. Compact valid records into the
    -- same array and release each raw record as soon as it has been normalized.
    local input_count = #source_items
    local write_index = 0
    for index = 1, input_count do
        local raw_source = source_items[index]
        source_items[index] = nil
        if type(raw_source) == "table" then
            local ok, normalized = pcall(LegadoSource.normalize, LegadoSource, raw_source)
            raw_source = nil
            if not ok or type(normalized) ~= "table" then
                return nil, string.format("第 %d 个书源规范化失败：%s", index,
                    tostring(normalized or "未知错误"))
            end
            write_index = write_index + 1
            source_items[write_index] = normalized
        end
        if index % 24 == 0 then
            collectgarbage("step", 160)
            notifyImportStage(options, 3,
                string.format("解析与规范化书源 %d / %d", index, input_count), 5)
        end
    end
    for index = write_index + 1, input_count do source_items[index] = nil end
    collectgarbage("collect")
    if write_index == 0 then return nil, "书源 JSON 中没有有效书源" end

    local stats = sourceImportStats(source_items)
    notifyImportStage(options, 4, string.format("保存 %d 个书源……", stats.total), 5)
    local saved, save_err = Storage:saveSources(source_items)
    if not saved then return nil, tostring(save_err or "保存书源失败") end

    if options.return_summary_only then
        -- Storage now owns references to the normalized records; callers that
        -- only need completion stats should not keep another top-level result.
        source_items = nil
        collectgarbage("collect")
        return stats
    end
    return source_items
end

function Importer:importSources(path, options)
    notifyImportStage(options, 1, "读取本地书源文件……", 5)
    local raw, err = Util.readFile(path)
    if not raw then return nil, err end
    return self:importSourcesText(raw, path, options)
end

function Importer:importSourcesFromUrl(url, options)
    url = Util.trim(url)
    if url == "" then return nil, "书源地址为空" end
    notifyImportStage(options, 1, "下载书源……", 5)
    local response, err = Http:request({
        url = url,
        method = "GET",
        timeout = 20,
        maxtime = 90,
        retries = 1,
        max_bytes = 8 * 1024 * 1024,
        suppress_sensitive_log = options and options.suppress_sensitive_log == true,
    })
    if not response then return nil, err end
    local body = response.body
    local origin = Util.basename(response.url or "network-sources.json")
    response = nil
    return self:importSourcesText(body, origin, options)
end

function Importer:summarizeSourceStats(stats)
    stats = stats or {}
    return string.format("已导入 %d 个书源：可使用 %d · 暂不支持 %d",
        tonumber(stats.total or 0) or 0,
        tonumber(stats.supported or 0) or 0,
        tonumber(stats.unsupported or 0) or 0)
end

function Importer:summarizeSources(sources)
    return self:summarizeSourceStats(sourceImportStats(sources))
end

function Importer:chooseFile(on_confirm)
    local chooser = PathChooser:new{
        select_directory = false,
        path = Storage:getLastImportPath(),
        onConfirm = function(path)
            Storage:setLastImportPath(Util.dirname(path))
            on_confirm(path)
        end,
    }
    UIManager:show(chooser)
end

function Importer:chooseDirectory(on_confirm)
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = Storage:getLastImportPath(),
        onConfirm = function(path)
            Storage:setLastImportPath(path)
            on_confirm(path)
        end,
    }
    UIManager:show(chooser)
end

return Importer
