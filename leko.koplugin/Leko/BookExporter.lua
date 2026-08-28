local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")

local Storage = require("Leko/Storage")
local Util = require("Leko/Util")

local BookExporter = {}
local unpack = table.unpack or unpack

local function xmlEscape(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function safeFilename(value)
    value = tostring(value or "未命名书籍"):gsub("[\\/:*?\"<>|%c]", "_")
        :gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%.%s]+$", "")
    if value == "" then value = "未命名书籍" end
    if type(Util.truncateUtf8) == "function" then value = Util.truncateUtf8(value, 80) end
    return value
end

local function writeChecked(file, value)
    local ok, err = file:write(value or "")
    if not ok then error(tostring(err or "写入导出文件失败")) end
end

local function atomicStream(path, callback)
    local ok, mkdir_err = Util.mkdirp(Util.dirname(path))
    if not ok then return nil, mkdir_err end
    local temp_path = path .. ".tmp"
    os.remove(temp_path)
    local file, open_err = io.open(temp_path, "wb")
    if not file then return nil, open_err end
    local called, result = xpcall(function() return callback(file, temp_path) end,
        function(err) return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err) end)
    pcall(file.flush, file)
    pcall(file.close, file)
    if not called then os.remove(temp_path); return nil, result end
    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then os.remove(temp_path); return nil, rename_err end
    return path, result
end

local function chapterPath(book, index)
    local chapter = book.chapters and book.chapters[index]
    if not chapter then return nil end
    local path = chapter.path or Storage:getChapterPath(book.id, index, chapter.id)
    if lfs.attributes(path, "mode") == "file" then return path end
    local deterministic = Storage:getChapterPath(book.id, index, chapter.id)
    if lfs.attributes(deterministic, "mode") == "file" then
        -- A source switch or an older summary may leave a stale chapter.path.
        -- Export always follows the deterministic cache file that was actually
        -- proven to exist on disk.
        chapter.path = deterministic
        return deterministic
    end
    return nil
end

function BookExporter:cachedCount(book)
    local cached, total = 0, #(book and book.chapters or {})
    for index = 1, total do if chapterPath(book, index) then cached = cached + 1 end end
    return cached, total
end

function BookExporter:isComplete(book)
    local cached, total = self:cachedCount(book)
    return total > 0 and cached == total, cached, total
end

local function requireContent(book, index)
    if not chapterPath(book, index) then
        error("第 " .. tostring(index) .. " 章尚未缓存：文件不存在")
    end
    local content, err = Storage:loadChapter(book, index)
    if not content then
        error("第 " .. tostring(index) .. " 章尚未缓存：" .. tostring(err or "文件不存在"))
    end
    return Util.normalizeText(content)
end

local COVER_RENDER_WIDTH = 1200
local COVER_RENDER_HEIGHT = 1800
local COVER_MEDIA_TYPES = {
    jpg = "image/jpeg", png = "image/png", gif = "image/gif",
    webp = "image/webp", svg = "image/svg+xml", tiff = "image/tiff",
}

local function readBinary(path)
    local data = Util.readFile and Util.readFile(path, true)
    if type(data) == "string" and data ~= "" then return data end
    local file = io.open(path, "rb")
    if not file then return nil end
    data = file:read("*a")
    file:close()
    return data
end

local function coverDescriptor(book)
    if not book then return nil end
    local value = book.selected_cover_url or book.cover or book.content_cover
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function coverResult(book)
    return {
        id = book and book.id,
        title = book and book.title,
        cover = coverDescriptor(book),
        source_id = book and book.source_id,
        source_name = book and book.source_name,
        book_url = book and (book.cover_book_url or book.book_url),
        variables = book and book.cover_variables,
    }
end

local function exportCover(book, format, scratch_path)
    local path = book and book.cover_path
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return nil, "未找到可用封面文件（封面可能尚未持久化或已被删除）"
    end
    local data = readBinary(path)
    if type(data) ~= "string" or data == "" then
        return nil, "封面文件无法读取"
    end

    local pipeline_ok, ImagePipeline = pcall(require, "Leko/ImagePipeline")
    if not pipeline_ok or type(ImagePipeline.prepare) ~= "function" then
        return nil, "封面验证管线不可用：" .. tostring(ImagePipeline or "未知错误")
    end
    local policy = ImagePipeline.saved_policy or {
        max_bytes = 8 * 1024 * 1024,
        max_pixels = 12000000,
        max_side = 6000,
        require_dimensions = true,
        require_complete_jpeg = true,
    }
    local prepared, prepare_err = ImagePipeline:prepare(data, nil, {
        policy = policy,
        decode = false,
    })
    if not prepared then return nil, "封面验证失败：" .. tostring(prepare_err or "图片无效") end

    local source_format = tostring(prepared.info and prepared.info.format or prepared.ext or ""):lower()
    local raw_allowed = (format == "epub" and (source_format == "jpg" or source_format == "png"
        or source_format == "gif" or source_format == "svg"))
        or (format == "mobi" and (source_format == "jpg" or source_format == "png"))
    if raw_allowed then
        return {
            data = prepared.body,
            extension = source_format,
            media_type = COVER_MEDIA_TYPES[source_format],
            source_format = source_format,
        }
    end

    -- WebP/TIFF and non-MOBI formats are decoded only after header validation,
    -- fitted to a bounded bitmap, encoded through KOReader's BlitBuffer API,
    -- and freed immediately. EPUB receives a portable PNG; MOBI receives the
    -- same stable JPEG/PNG set required by old Kindle readers.
    if type(ImagePipeline.freeImage) ~= "function" or type(ImagePipeline.encodeImage) ~= "function" then
        return nil, "封面格式需要 KOReader 图像转换能力"
    end
    local decoded, decode_err = ImagePipeline:prepare(data, nil, {
        policy = policy,
        width = COVER_RENDER_WIDTH,
        height = COVER_RENDER_HEIGHT,
        keep_image = true,
    })
    if not decoded or not decoded.image then
        return nil, "封面转换失败：" .. tostring(decode_err or "KOReader 无法解码该图片")
    end
    local output_path = tostring(scratch_path or path) .. ".cover-convert.png.tmp"
    os.remove(output_path)
    local encoded, encode_err = ImagePipeline:encodeImage(decoded.image, output_path, "png", 90)
    ImagePipeline:freeImage(decoded.image)
    os.remove(output_path)
    if not encoded then return nil, "封面转换失败：" .. tostring(encode_err or "无法写出 PNG") end

    local verified, verify_err = ImagePipeline:prepare(encoded, "image/png", {
        policy = policy,
        decode = false,
    })
    if not verified then return nil, "封面转换结果验证失败：" .. tostring(verify_err or "PNG 无效") end
    return {
        data = verified.body,
        extension = "png",
        media_type = "image/png",
        source_format = source_format,
    }
end

local function reloadBookForExport(book)
    if type(Storage.loadBook) ~= "function" then return book end
    local ok, latest, err = pcall(Storage.loadBook, Storage, book.id, { load_toc = true })
    if not ok then return nil, tostring(latest) end
    if type(latest) ~= "table" then return nil, tostring(err or "无法读取最新书籍状态") end
    -- A legacy host may return a summary without TOC even when requested. Keep
    -- the already verified chapter list for export, but never copy old cover
    -- fields back over the freshly loaded disk state.
    if type(latest.chapters) ~= "table" or #latest.chapters == 0 then latest.chapters = book.chapters end
    return latest
end

local function persistCachedCoverForExport(book)
    if type(Storage.loadBook) ~= "function" then return book, nil end
    local service_ok, BookService = pcall(require, "Leko/BookService")
    if not service_ok or type(BookService) ~= "table" then
        return book, "封面持久化服务不可用"
    end

    local existing, existing_err = BookService:getValidCoverPath(book)
    if not existing then
        local result = coverResult(book)
        local path, _, materialize_err = BookService:materializeCachedCover(book, result)
        if not path then
            return book, tostring(materialize_err or existing_err or "详情页封面缓存不可用")
        end
    end
    local latest, reload_err = reloadBookForExport(book)
    if not latest then return book, "封面已写入但重新读取失败：" .. tostring(reload_err) end
    return latest, nil
end

local function stripParagraphIndent(line)
    line = tostring(line or "")
    if line:sub(1, 3) == "\239\187\191" then line = line:sub(4) end
    while line ~= "" do
        local first = line:sub(1, 1)
        if first == " " or first == "\t" then
            line = line:sub(2)
        elseif line:sub(1, 2) == "\194\160" then
            line = line:sub(3)
        elseif line:sub(1, 3) == "\227\128\128" then
            line = line:sub(4)
        else
            break
        end
    end
    return line
end

local function paragraphHtml(content)
    local parts = {}
    content = Util.normalizeText(content)
    for line in (content .. "\n"):gmatch("(.-)\n") do
        line = stripParagraphIndent(line)
        if line ~= "" then parts[#parts + 1] = "<p>" .. xmlEscape(line) .. "</p>" end
    end
    if #parts == 0 then parts[1] = "<p>&#160;</p>" end
    return table.concat(parts)
end

local function txtBody(content)
    local parts = {}
    content = Util.normalizeText(content)
    for line in (content .. "\n"):gmatch("(.-)\n") do
        line = stripParagraphIndent(line)
        if line ~= "" then parts[#parts + 1] = "\227\128\128\227\128\128" .. line end
    end
    return table.concat(parts, "\n")
end

local function mobiBody(content)
    local parts = {}
    content = Util.normalizeText(content)
    for line in (content .. "\n"):gmatch("(.-)\n") do
        line = stripParagraphIndent(line)
        if line ~= "" then
            -- Do not use <p>: old Kindle MOBI6 firmware adds its own implicit
            -- paragraph indent to that element. A plain block has no native
            -- first-line indent, so these two ideographic spaces are the only
            -- indentation applied.
            parts[#parts + 1] = '<div>&#12288;&#12288;' .. xmlEscape(line) .. '</div>'
        end
    end
    if #parts == 0 then parts[1] = '<div>&#160;</div>' end
    return table.concat(parts, '<br/>')
end

local function chapterXhtml(book, index, content)
    local chapter = book.chapters[index]
    local title = xmlEscape(chapter and chapter.title or ("第 " .. tostring(index) .. " 章"))
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head>'
        .. '<meta charset="utf-8"/><title>' .. title .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="style.css"/></head><body>'
        .. '<h1>' .. title .. '</h1>' .. paragraphHtml(content) .. '</body></html>'
end

local function reportProgress(callback, current, total, stage)
    if type(callback) == "function" then pcall(callback, current, total, stage) end
end

local function exportTxt(book, path, progress)
    return atomicStream(path, function(file)
        writeChecked(file, "\239\187\191" .. tostring(book.title or "未命名书籍") .. "\n")
        if tostring(book.author or "") ~= "" then writeChecked(file, "作者：" .. tostring(book.author) .. "\n") end
        writeChecked(file, "\n")
        for index, chapter in ipairs(book.chapters or {}) do
            reportProgress(progress, index, #(book.chapters or {}), "正在转换章节")
            writeChecked(file, tostring(chapter.title or ("第 " .. tostring(index) .. " 章")) .. "\n\n")
            writeChecked(file, txtBody(requireContent(book, index)) .. "\n\n")
        end
    end)
end

local crc_table
local function crc32(data)
    if not crc_table then
        crc_table = {}
        for value = 0, 255 do
            local crc = value
            for _ = 1, 8 do
                if bit.band(crc, 1) ~= 0 then crc = bit.bxor(bit.rshift(crc, 1), 0xedb88320)
                else crc = bit.rshift(crc, 1) end
            end
            crc_table[value + 1] = crc
        end
    end
    local crc = 0xffffffff
    for index = 1, #data do
        local slot = bit.band(bit.bxor(crc, data:byte(index)), 0xff) + 1
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[slot])
    end
    crc = bit.bxor(crc, 0xffffffff)
    if crc < 0 then crc = crc + 4294967296 end
    return crc
end

local function le16(value)
    value = value % 65536
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
    value = value % 4294967296
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local ZipWriter = {}
ZipWriter.__index = ZipWriter

function ZipWriter:new(file)
    return setmetatable({ file = file, entries = {}, offset = 0 }, self)
end

function ZipWriter:add(name, data)
    name, data = tostring(name), tostring(data or "")
    if #data >= 4294967296 or self.offset >= 4294967296 then error("EPUB 超过 ZIP32 大小上限") end
    local now = os.date("*t")
    local dos_time = (math.floor((now.sec or 0) / 2)) + (now.min or 0) * 32 + (now.hour or 0) * 2048
    local dos_date = (now.day or 1) + (now.month or 1) * 32 + math.max(0, (now.year or 1980) - 1980) * 512
    local checksum = crc32(data)
    local header = le32(0x04034b50) .. le16(20) .. le16(0x0800) .. le16(0)
        .. le16(dos_time) .. le16(dos_date) .. le32(checksum) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. name
    writeChecked(self.file, header); writeChecked(self.file, data)
    self.entries[#self.entries + 1] = {
        name = name, crc = checksum, size = #data, offset = self.offset,
        dos_time = dos_time, dos_date = dos_date,
    }
    self.offset = self.offset + #header + #data
end

function ZipWriter:finish()
    local central_offset = self.offset
    for _, entry in ipairs(self.entries) do
        local name = entry.name
        local header = le32(0x02014b50) .. le16(20) .. le16(20) .. le16(0x0800) .. le16(0)
            .. le16(entry.dos_time) .. le16(entry.dos_date) .. le32(entry.crc)
            .. le32(entry.size) .. le32(entry.size) .. le16(#name) .. le16(0) .. le16(0)
            .. le16(0) .. le16(0) .. le32(0) .. le32(entry.offset) .. name
        writeChecked(self.file, header)
        self.offset = self.offset + #header
    end
    local count = #self.entries
    if count > 65535 then error("EPUB 文件条目过多") end
    writeChecked(self.file, le32(0x06054b50) .. le16(0) .. le16(0) .. le16(count) .. le16(count)
        .. le32(self.offset - central_offset) .. le32(central_offset) .. le16(0))
end

local function exportEpub(book, path, progress, cover)
    return atomicStream(path, function(file)
        local zip = ZipWriter:new(file)
        zip:add("mimetype", "application/epub+zip")
        zip:add("META-INF/container.xml", '<?xml version="1.0"?>\n'
            .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            .. '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
            .. '</rootfiles></container>')
        local manifest, spine, nav, ncx = {}, {}, {}, {}
        if cover then
            manifest[#manifest + 1] = '<item id="cover-image" href="cover.' .. cover.extension
                .. '" media-type="' .. cover.media_type .. '" properties="cover-image"/>'
            manifest[#manifest + 1] = '<item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>'
            spine[#spine + 1] = '<itemref idref="cover-page" linear="no"/>'
        end
        for index, chapter in ipairs(book.chapters or {}) do
            local filename = string.format("chapter-%06d.xhtml", index)
            manifest[#manifest + 1] = '<item id="c' .. index .. '" href="' .. filename
                .. '" media-type="application/xhtml+xml"/>'
            spine[#spine + 1] = '<itemref idref="c' .. index .. '"/>'
            local title = xmlEscape(chapter.title or ("第 " .. tostring(index) .. " 章"))
            nav[#nav + 1] = '<li><a href="' .. filename .. '">' .. title .. '</a></li>'
            ncx[#ncx + 1] = '<navPoint id="n' .. index .. '" playOrder="' .. index
                .. '"><navLabel><text>' .. title .. '</text></navLabel><content src="' .. filename
                .. '"/></navPoint>'
        end
        local title, author = xmlEscape(book.title or "未命名书籍"), xmlEscape(book.author or "未知作者")
        local identifier = "urn:uuid:leko-" .. tostring(book.id or Util.hashId(title))
        local nav_doc = '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html><html '
            .. 'xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">'
            .. '<head><meta charset="utf-8"/><title>目录</title></head><body><nav epub:type="toc" id="toc">'
            .. '<h1>目录</h1><ol>' .. table.concat(nav) .. '</ol></nav></body></html>'
        local ncx_doc = '<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
            .. 'version="2005-1"><head><meta name="dtb:uid" content="' .. identifier
            .. '"/></head><docTitle><text>' .. title .. '</text></docTitle><navMap>'
            .. table.concat(ncx) .. '</navMap></ncx>'
        manifest[#manifest + 1] = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        manifest[#manifest + 1] = '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        manifest[#manifest + 1] = '<item id="css" href="style.css" media-type="text/css"/>'
        local cover_meta = cover and '<meta name="cover" content="cover-image"/>' or ''
        local guide = cover and '<guide><reference type="cover" title="Cover" href="cover.xhtml"/></guide>' or ''
        local opf = '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" '
            .. 'version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            .. '<dc:identifier id="bookid">' .. identifier .. '</dc:identifier><dc:title>' .. title
            .. '</dc:title><dc:creator>' .. author .. '</dc:creator><dc:language>zh-CN</dc:language>'
            .. '<meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ")
            .. '</meta>' .. cover_meta .. '</metadata><manifest>' .. table.concat(manifest) .. '</manifest><spine toc="ncx">'
            .. table.concat(spine) .. '</spine>' .. guide .. '</package>'
        zip:add("OEBPS/content.opf", opf)
        zip:add("OEBPS/nav.xhtml", nav_doc)
        zip:add("OEBPS/toc.ncx", ncx_doc)
        zip:add("OEBPS/style.css", 'h1{text-align:left;margin:2.5em 0 2em}p{margin:0;text-indent:2em}.cover{text-align:center;margin:0}.cover img{max-width:100%;max-height:100%}')
        if cover then
            zip:add("OEBPS/cover." .. cover.extension, cover.data)
            zip:add("OEBPS/cover.xhtml", '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head><meta charset="utf-8"/><title>Cover</title><link rel="stylesheet" type="text/css" href="style.css"/></head><body class="cover"><img src="cover.' .. cover.extension .. '" alt="' .. title .. '"/></body></html>')
        end
        for index = 1, #(book.chapters or {}) do
            reportProgress(progress, index, #(book.chapters or {}), "正在转换章节")
            zip:add(string.format("OEBPS/chapter-%06d.xhtml", index),
                chapterXhtml(book, index, requireContent(book, index)))
        end
        zip:finish()
    end)
end

local function be16(value)
    value = value % 65536
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function be32(value)
    value = value % 4294967296
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256, value % 256)
end

local function byteArray(size)
    local result = {}; for index = 1, size do result[index] = 0 end; return result
end

local function set16(target, offset, value)
    value = value % 65536
    target[offset + 1], target[offset + 2] = math.floor(value / 256) % 256, value % 256
end

local function set32(target, offset, value)
    value = value % 4294967296
    target[offset + 1], target[offset + 2] = math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256
    target[offset + 3], target[offset + 4] = math.floor(value / 256) % 256, value % 256
end

local function setText(target, offset, value)
    for index = 1, #value do target[offset + index] = value:byte(index) end
end

local function arrayString(target) return string.char(unpack(target)) end

local function exthRecord(kind, value)
    value = tostring(value or "")
    return be32(kind) .. be32(#value + 8) .. value
end

local function buildExth(book, cover_offset)
    local records = {
        exthRecord(100, book.author or "未知作者"),
        exthRecord(503, book.title or "未命名书籍"),
        exthRecord(112, "leko:" .. tostring(book.id or "")),
        exthRecord(113, "L" .. tostring(Util.hashId(tostring(book.id or book.title or "book"))):upper()),
    }
    if cover_offset ~= nil then
        records[#records + 1] = be32(201) .. be32(12) .. be32(cover_offset)
    end
    local payload = table.concat(records)
    local result = "EXTH" .. be32(12 + #payload) .. be32(#records) .. payload
    local pad = (4 - (#result % 4)) % 4
    return result .. string.rep("\0", pad)
end

local function buildFlis()
    local value = byteArray(36); setText(value, 0, "FLIS"); set32(value, 4, 8)
    set16(value, 8, 65); set32(value, 16, 0xffffffff); set16(value, 20, 1); set16(value, 22, 3)
    set32(value, 24, 3); set32(value, 28, 1); set32(value, 32, 0xffffffff)
    return arrayString(value)
end

local function buildFcis(text_length)
    local value = byteArray(44); setText(value, 0, "FCIS"); set32(value, 4, 20); set32(value, 8, 16)
    set32(value, 12, 1); set32(value, 20, text_length); set32(value, 28, 32); set32(value, 32, 8)
    set16(value, 36, 1); set16(value, 38, 1)
    return arrayString(value)
end

local function vwi(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local bytes = { value % 128 }
    value = math.floor(value / 128)
    while value > 0 do
        table.insert(bytes, 1, value % 128)
        value = math.floor(value / 128)
    end
    bytes[#bytes] = bytes[#bytes] + 128
    return string.char(unpack(bytes))
end

local function indxHeader(options)
    options = options or {}
    local header = byteArray(192)
    setText(header, 0, "INDX"); set32(header, 4, 192)
    set32(header, 12, options.unknown1 or 0)
    set32(header, 16, options.kind or 0)
    set32(header, 20, options.idxt_offset or 0)
    set32(header, 24, options.idxt_count or 0)
    set32(header, 28, options.encoding or 0xffffffff)
    set32(header, 32, 0xffffffff)
    set32(header, 36, options.entry_count or 0)
    set32(header, 52, options.cncx_count or 0)
    set32(header, 180, options.tagx_offset or 0)
    return arrayString(header)
end

-- Kindle's "Go To" menu reads MOBI6 INDX/TAGX/CNCX records. The visible
-- HTML table of contents is useful fallback content, but is not this index.
local function buildMobiNcx(entries)
    local tagx = "TAGX" .. be32(32) .. be32(1)
        .. string.char(1, 1, 1, 0, 2, 1, 2, 0, 3, 1, 4, 0, 4, 1, 8, 0, 0, 0, 0, 1)
    local labels, label_records = "", {}
    local entry_records, entry_data, offsets, last_item = {}, "", {}, nil
    for index, entry in ipairs(entries) do
        local title = tostring(entry.title or ("Chapter " .. tostring(index)))
        if #labels + #title + 8 > 60000 then
            label_records[#label_records + 1] = labels
            labels = ""
        end
        local label_offset = #label_records * 65536 + #labels
        labels = labels .. vwi(#title) .. title
        local id = string.format("%06d", index - 1)
        local item = string.char(#id) .. id .. string.char(0x0f)
            .. vwi(entry.position) .. vwi(entry.length) .. vwi(label_offset) .. vwi(0)
        if 192 + #entry_data + #item >= 60000 and #offsets > 0 then
            entry_records[#entry_records + 1] = { data = entry_data, offsets = offsets }
            entry_data, offsets = "", {}
        end
        offsets[#offsets + 1] = 192 + #entry_data
        entry_data = entry_data .. item
        last_item = item
    end
    if #offsets > 0 then entry_records[#entry_records + 1] = { data = entry_data, offsets = offsets } end
    label_records[#label_records + 1] = labels

    local last = last_item:sub(1, (last_item:byte(1) or 0) + 1)
    local before_idxt = 192 + #tagx + #last + 2
    local pad = (4 - (before_idxt % 4)) % 4
    local master_idxt = before_idxt + pad
    local master = indxHeader{
        kind = 2, idxt_offset = master_idxt, idxt_count = 1, encoding = 65001,
        entry_count = #entries, cncx_count = #label_records, tagx_offset = 192,
    } .. tagx .. last .. be16(#entries) .. string.rep("\0", pad)
        .. "IDXT" .. be16(192 + #tagx) .. "\0\0"

    local records = { "\0\0", master }
    for _, entry_record in ipairs(entry_records) do
        local secondary = indxHeader{
            unknown1 = 1, kind = 0, idxt_offset = 192 + #entry_record.data,
            idxt_count = #entry_record.offsets, encoding = 0xffffffff,
        } .. entry_record.data .. "IDXT"
        for _, offset in ipairs(entry_record.offsets) do secondary = secondary .. be16(offset) end
        secondary = secondary .. string.rep("\0", (4 - (#secondary % 4)) % 4)
        records[#records + 1] = secondary
    end
    for _, labels_record in ipairs(label_records) do records[#records + 1] = labels_record end
    return records
end

local function buildRecord0(book, text_length, text_count, layout)
    layout = layout or {}
    local flis_index, fcis_index = assert(layout.flis_index), assert(layout.fcis_index)
    local palmdoc = byteArray(16)
    set16(palmdoc, 0, 1) -- no compression: lowest CPU/RAM cost on Kindle
    set32(palmdoc, 4, text_length); set16(palmdoc, 8, text_count); set16(palmdoc, 10, 4096)
    local mobi = byteArray(232)
    setText(mobi, 0, "MOBI"); set32(mobi, 4, 232); set32(mobi, 8, 2); set32(mobi, 12, 65001)
    set32(mobi, 16, tonumber(Util.hashId(tostring(book.id or book.title or "book")), 16) or 1)
    set32(mobi, 20, 6); set32(mobi, 76, 0x0804); set32(mobi, 88, 6)
    for _, offset in ipairs({ 24,28,32,36,40,44,48,52,56,60,148,152,156,228 }) do set32(mobi, offset, 0xffffffff) end
    set32(mobi, 64, layout.first_non_book_index or (1 + text_count))
    set32(mobi, 92, layout.first_image_index or 0xffffffff); set32(mobi, 112, 0x40)
    set16(mobi, 176, 1); set16(mobi, 178, layout.last_content_index or text_count); set32(mobi, 180, 1)
    set32(mobi, 184, fcis_index); set32(mobi, 188, 1); set32(mobi, 192, flis_index); set32(mobi, 196, 1)
    set32(mobi, 208, 0xffffffff); set32(mobi, 212, 0); set32(mobi, 216, 0xffffffff); set32(mobi, 220, 0xffffffff)
    set32(mobi, 224, 0); set32(mobi, 228, layout.ncx_index or 0xffffffff)
    local exth = buildExth(book, layout.cover_offset)
    local title = tostring(book.title or "未命名书籍")
    local full_name_offset = 16 + 232 + #exth
    set32(mobi, 68, full_name_offset); set32(mobi, 72, #title)
    local record = arrayString(palmdoc) .. arrayString(mobi) .. exth .. title .. "\0\0"
    return record .. string.rep("\0", (4 - (#record % 4)) % 4)
end

local function safeSplit(buffer, limit)
    local split = math.min(limit, #buffer)
    while split > 1 do
        local next_byte = buffer:byte(split + 1)
        if next_byte and next_byte >= 0x80 and next_byte <= 0xbf then split = split - 1 else break end
    end
    local prefix = buffer:sub(1, split)
    local last_open = prefix:match(".*()<")
    local last_close = prefix:match(".*()>")
    if last_open and (not last_close or last_open > last_close) and last_open > 512 then split = last_open - 1 end
    return math.max(1, split)
end

local function mobiChapter(book, index, content)
    local title = xmlEscape(book.chapters[index].title or ("第 " .. tostring(index) .. " 章"))
    -- A bare <br/> run at a forced page boundary is discarded by some old
    -- Kindle MOBI6 renderers. Give every spacer line real (non-breaking)
    -- content so the three lines survive at the top of the page as well as
    -- below the title. The title itself stays left aligned: "centred" here
    -- means vertically centred between the page top and the body text.
    local space = string.rep('<div>&#160;</div>', 3)
    local body = mobiBody(content)
    return '<mbp:pagebreak/><a name="ch' .. index .. '"></a>' .. space
        .. '<div><big><b>' .. title .. '</b></big></div>' .. space .. body
end

local function buildMobiLayout(book, has_cover, progress)
    local prefix = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>'
        .. '</head><body>'
    local suffix = "</body></html>"
    local chapter_lengths, anchor_offsets, cumulative = {}, {}, 0
    local anchor_in_chapter = #'<mbp:pagebreak/>'
    for index = 1, #(book.chapters or {}) do
        reportProgress(progress, index, 2 * #(book.chapters or {}), "正在读取章节")
        local html = mobiChapter(book, index, requireContent(book, index))
        chapter_lengths[index] = #html
        anchor_offsets[index] = cumulative + anchor_in_chapter
        cumulative = cumulative + #html
    end
    local cover_html = has_cover and '<a name="cover"></a><div><img recindex="00001" alt="Cover"/></div><mbp:pagebreak/>' or ""
    local guide, toc = "", ""
    local provisional_refs = {}
    if has_cover then
        provisional_refs[#provisional_refs + 1] = '<reference type="cover" title="Cover" filepos="0000000000"/>'
    end
    if #chapter_lengths >= 2 then
        provisional_refs[#provisional_refs + 1] = '<reference type="toc" title="目录" filepos="0000000000"/>'
    end
    if #provisional_refs > 0 then
        local provisional_guide = '<guide>' .. table.concat(provisional_refs) .. '</guide>'
        local content_position = #prefix + #provisional_guide
        local refs = {}
        if has_cover then
            refs[#refs + 1] = '<reference type="cover" title="Cover" filepos="'
                .. string.format("%010d", content_position) .. '"/>'
            content_position = content_position + #cover_html
        end
        if #chapter_lengths >= 2 then
            refs[#refs + 1] = '<reference type="toc" title="目录" filepos="'
                .. string.format("%010d", content_position) .. '"/>'
        end
        guide = '<guide>' .. table.concat(refs) .. '</guide>'
    end
    if #chapter_lengths >= 2 then
        local provisional = { "<h1>目录</h1>" }
        for index, chapter in ipairs(book.chapters or {}) do
            provisional[#provisional + 1] = '<p><a filepos="0000000000">'
                .. xmlEscape(chapter.title or ("第 " .. index .. " 章")) .. '</a></p>'
        end
        provisional[#provisional + 1] = '<mbp:pagebreak/>'
        local toc_length = #table.concat(provisional)
        local body_start = #prefix + #guide + #cover_html + toc_length
        local entries = { "<h1>目录</h1>" }
        for index, chapter in ipairs(book.chapters or {}) do
            local position = body_start + anchor_offsets[index]
            if position >= 10000000000 then error("MOBI 正文超过 filepos 上限") end
            entries[#entries + 1] = '<p><a filepos="' .. string.format("%010d", position) .. '">'
                .. xmlEscape(chapter.title or ("第 " .. index .. " 章")) .. '</a></p>'
        end
        entries[#entries + 1] = '<mbp:pagebreak/>'
        toc = table.concat(entries)
    end
    local body_start = #prefix + #guide + #cover_html + #toc
    local ncx = {}
    for index, chapter in ipairs(book.chapters or {}) do
        ncx[index] = {
            title = chapter.title or ("Chapter " .. tostring(index)),
            position = body_start + anchor_offsets[index] - anchor_in_chapter,
            length = chapter_lengths[index],
        }
    end
    return prefix, guide, cover_html, toc, suffix, ncx
end

local function exportMobi(book, path, progress, cover)
    local records_path = path .. ".records.tmp"
    os.remove(records_path)
    local records, open_err = io.open(records_path, "wb")
    if not records then return nil, open_err end
    local lengths, buffer, text_length = {}, "", 0
    local function feed(value)
        value = tostring(value or "")
        text_length = text_length + #value
        buffer = buffer .. value
        while #buffer >= 4096 do
            local size = safeSplit(buffer, 4096)
            local chunk = buffer:sub(1, size); buffer = buffer:sub(size + 1)
            writeChecked(records, chunk); lengths[#lengths + 1] = #chunk
        end
    end
    local ncx_entries
    local ok, failure = xpcall(function()
        local prefix, guide, cover_html, toc, suffix, built_ncx = buildMobiLayout(book, cover ~= nil, progress)
        ncx_entries = built_ncx
        feed(prefix); feed(guide); feed(cover_html); feed(toc)
        for index = 1, #(book.chapters or {}) do
            reportProgress(progress, #(book.chapters or {}) + index,
                2 * #(book.chapters or {}), "正在转换章节")
            feed(mobiChapter(book, index, requireContent(book, index)))
        end
        feed(suffix)
        if #buffer > 0 then writeChecked(records, buffer); lengths[#lengths + 1] = #buffer; buffer = "" end
    end, function(err) return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err) end)
    pcall(records.flush, records); pcall(records.close, records)
    if not ok then os.remove(records_path); return nil, failure end
    if #lengths == 0 then os.remove(records_path); return nil, "MOBI 没有正文记录" end
    local navigation_records
    local nav_ok, nav_err = pcall(function() navigation_records = buildMobiNcx(ncx_entries) end)
    if not nav_ok then os.remove(records_path); return nil, nav_err end
    local first_non_book_index = 1 + #lengths
    local ncx_index = first_non_book_index + 1
    local next_index = first_non_book_index + #navigation_records
    local first_image_index = cover and next_index or nil
    if cover then next_index = next_index + 1 end
    local flis_index, fcis_index = next_index, next_index + 1
    if fcis_index + 2 > 65535 then os.remove(records_path); return nil, "MOBI 记录数超出格式上限" end
    local record0 = buildRecord0(book, text_length, #lengths, {
        first_non_book_index = first_non_book_index,
        ncx_index = ncx_index,
        first_image_index = first_image_index,
        cover_offset = cover and 0 or nil,
        last_content_index = cover and first_image_index or #lengths,
        flis_index = flis_index,
        fcis_index = fcis_index,
    })
    local flis, fcis, eof = buildFlis(), buildFcis(text_length), "\233\142\13\10"
    local record_lengths = { #record0 }
    for _, size in ipairs(lengths) do record_lengths[#record_lengths + 1] = size end
    for _, record in ipairs(navigation_records) do record_lengths[#record_lengths + 1] = #record end
    if cover then record_lengths[#record_lengths + 1] = #cover.data end
    record_lengths[#record_lengths + 1] = #flis; record_lengths[#record_lengths + 1] = #fcis
    record_lengths[#record_lengths + 1] = #eof
    local result, err = atomicStream(path, function(file)
        local count = #record_lengths
        local pdb = byteArray(78)
        setText(pdb, 0, ("Leko-" .. tostring(Util.hashId(tostring(book.id or book.title or "book")))):sub(1, 31))
        local palm_time = os.time() + 2082844800
        set32(pdb, 36, palm_time); set32(pdb, 40, palm_time)
        setText(pdb, 60, "BOOK"); setText(pdb, 64, "MOBI"); set32(pdb, 68, count + 1); set16(pdb, 76, count)
        writeChecked(file, arrayString(pdb))
        local offset = 78 + count * 8 + 2
        for index, size in ipairs(record_lengths) do
            writeChecked(file, be32(offset) .. "\0" .. be32(index):sub(2, 4))
            offset = offset + size
        end
        writeChecked(file, "\0\0"); writeChecked(file, record0)
        local source = assert(io.open(records_path, "rb"))
        while true do local chunk = source:read(64 * 1024); if not chunk then break end; writeChecked(file, chunk) end
        source:close()
        for _, record in ipairs(navigation_records) do writeChecked(file, record) end
        if cover then writeChecked(file, cover.data) end
        writeChecked(file, flis); writeChecked(file, fcis); writeChecked(file, eof)
    end)
    os.remove(records_path)
    return result, err
end

function BookExporter:export(book, format, progress)
    if type(book) ~= "table" or not book.id then return nil, "书籍信息不完整" end
    format = tostring(format or "epub"):lower()
    if format ~= "txt" and format ~= "epub" and format ~= "mobi" then return nil, "不支持的导出格式" end

    local latest, reload_err = reloadBookForExport(book)
    if not latest then return nil, "无法读取最新书籍状态：" .. tostring(reload_err or "未知错误") end
    book = latest
    local complete, cached, total = self:isComplete(book)
    if not complete then return nil, "请先完成全书缓存（" .. tostring(cached) .. "/" .. tostring(total) .. "）" end
    local directory = Storage:getExportDir()
    local filename = safeFilename(book.title) .. "." .. format
    local path = Util.joinPath(directory, filename)
    local progress_total = format == "mobi" and 2 * total or total
    reportProgress(progress, 0, progress_total, "正在准备导出")

    local cover, cover_warning
    if format ~= "txt" then
        book, cover_warning = persistCachedCoverForExport(book)
        local exported_cover, export_cover_warning = exportCover(book, format, path)
        cover = exported_cover
        if export_cover_warning then
            cover_warning = cover_warning and (tostring(cover_warning) .. "；" .. tostring(export_cover_warning))
                or export_cover_warning
        end
    end

    local result, err
    if format == "txt" then result, err = exportTxt(book, path, progress)
    elseif format == "epub" then result, err = exportEpub(book, path, progress, cover)
    else result, err = exportMobi(book, path, progress, cover) end
    if result then reportProgress(progress, progress_total, progress_total, "正在完成文件写入") end
    local metadata = cover_warning and { cover_warning = tostring(cover_warning) } or nil
    return result, err, metadata
end

return BookExporter
