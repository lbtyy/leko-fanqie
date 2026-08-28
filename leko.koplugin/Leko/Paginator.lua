local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Screen = require("device").screen
local BookService = require("Leko/BookService")
local Util = require("Leko/Util")

local Paginator = {}

-- Only the horizontal reading margins are user-facing layout settings. These
-- vertical gaps belong to the reader chrome: keep the header/footer close to
-- the edges regardless of legacy margin_top/margin_bottom fields in a saved
-- style.
local READER_CHROME_TOP_GAP = 14
local READER_CHROME_BOTTOM_GAP = 12
-- When the header is hidden, keep the body away from the physical top edge.
-- This preserves the 0.15.39-sized reading inset without making the visible
-- header's own outer gap as large as the legacy user margin.
local READER_BODY_TOP_GAP = 24

local INDENT = "\u{3000}\u{3000}"
local IDEOGRAPHIC_SPACE = "\u{3000}"
local NO_BREAK_SPACE = "\u{00A0}"
local SYSTEM_FONT = "cfont"
local SYSTEM_FONT_DISPLAY_NAME = "系统默认（简体中文优先）"

local function resolveReaderFace(style, font_field, index_field, display_field, size)
    local path = tostring(style[font_field] or SYSTEM_FONT)
    local index = tonumber(style[index_field])
    local ok, face
    if index == nil then
        ok, face = pcall(Font.getFace, Font, path, size)
    else
        ok, face = pcall(Font.getFace, Font, path, size, index)
    end
    if ok and face then return face end

    if path ~= SYSTEM_FONT then
        -- Keep Font.faces intact: KOReader owns that cache and clearing it can
        -- invalidate faces still used by the current page. Only repair this
        -- reader style, then let ReaderView show one friendly notification.
        style[font_field] = SYSTEM_FONT
        style[index_field] = nil
        style[display_field] = SYSTEM_FONT_DISPLAY_NAME
        local paired_field = font_field == "body_font" and "title_font" or "body_font"
        local paired_index = paired_field == "body_font" and "body_font_index" or "title_font_index"
        local paired_display = paired_field == "body_font" and "body_font_display_name" or "title_font_display_name"
        if tostring(style[paired_field] or "") == path then
            style[paired_field] = SYSTEM_FONT
            style[paired_index] = nil
            style[paired_display] = SYSTEM_FONT_DISPLAY_NAME
        end
        style._font_fallback_pending = true
        local fallback_ok, fallback = pcall(Font.getFace, Font, SYSTEM_FONT, size)
        if fallback_ok and fallback then return fallback end
    end
    error("系统默认字体无法加载")
end

-- Legado's HTML formatter keeps paragraph indentation in parsed content.
-- Normalize that presentation whitespace here so the reader setting remains
-- authoritative without changing cached source text or Legado rule semantics.
local function leadingIndentChars(value)
    value = tostring(value or "")
    local byte_index = 1
    local char_count = 0
    while byte_index <= #value do
        local byte = value:sub(byte_index, byte_index)
        if byte == " " or byte == "\t" then
            byte_index = byte_index + 1
            char_count = char_count + 1
        elseif value:sub(byte_index, byte_index + #NO_BREAK_SPACE - 1) == NO_BREAK_SPACE then
            byte_index = byte_index + #NO_BREAK_SPACE
            char_count = char_count + 1
        elseif value:sub(byte_index, byte_index + #IDEOGRAPHIC_SPACE - 1) == IDEOGRAPHIC_SPACE then
            byte_index = byte_index + #IDEOGRAPHIC_SPACE
            char_count = char_count + 1
        else
            break
        end
    end
    return char_count
end

local function bodyMetrics(style)
    local face = resolveReaderFace(style, "body_font", "body_font_index",
        "body_font_display_name", style.body_font_size or 27)
    local probe = TextBoxWidget:new{
        text = "测",
        face = face,
        width = math.max(20, Screen:getWidth() - 20),
        line_height = style.line_spacing or 0.28,
        lang = "zh-CN",
        bold = false,
        for_measurement_only = true,
    }
    return face, probe.line_height_px
end

local function measuredHeight(widget)
    local size = widget and widget.getSize and widget:getSize()
    return math.max(1, math.ceil((size and size.h) or 1))
end

local function smallTextHeight(face)
    local widget = TextWidget:new{ text = "测", face = face, padding = 0 }
    return measuredHeight(widget)
end

function Paginator:getGeometry(style)
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local left = Screen:scaleBySize(style.margin_left or 28)
    local right = Screen:scaleBySize(style.margin_right or 28)
    local top = Screen:scaleBySize(READER_CHROME_TOP_GAP)
    local bottom = Screen:scaleBySize(READER_CHROME_BOTTOM_GAP)
    local content_width = math.max(Screen:scaleBySize(120), screen_width - left - right)

    local body_face, body_line_height = bodyMetrics(style)
    local chrome_face = Font:getFace("smallinfofont", math.max(14, math.floor((style.body_font_size or 27) * 0.58)))
    local chrome_height = smallTextHeight(chrome_face)
    local header_height = style.show_header and chrome_height + Screen:scaleBySize(5) or 0
    -- The reading menu is an overlay, not a permanent button bar. Reserve only
    -- a compact optional status footer so the text area behaves like a reader.
    local footer_height = style.show_footer and (chrome_height + Screen:scaleBySize(5)) or 0
    local control_height = 0
    local body_top = style.show_header and top or Screen:scaleBySize(READER_BODY_TOP_GAP)
    local content_height = screen_height - body_top - bottom - header_height - footer_height

    return {
        screen_width = screen_width,
        screen_height = screen_height,
        left = left,
        right = right,
        top = top,
        body_top = body_top,
        bottom = bottom,
        content_width = content_width,
        content_height = math.max(body_line_height, content_height),
        body_face = body_face,
        body_line_height = body_line_height,
        chrome_face = chrome_face,
        header_height = header_height,
        footer_height = footer_height,
        control_height = control_height,
    }
end


local function paragraphLength(model, paragraph_index)
    model._utf8_lengths = model._utf8_lengths or {}
    local cached = model._utf8_lengths[paragraph_index]
    if cached ~= nil then return cached end
    local length = Util.utf8Length(model.paragraphs[paragraph_index] or "")
    model._utf8_lengths[paragraph_index] = length
    return length
end

local function chapterId(book, chapter_index)
    local chapter = book and book.chapters and book.chapters[chapter_index]
    return chapter and chapter.id or nil
end

local function makePosition(book, chapter_index, paragraph_index, char_index)
    return {
        chapter = chapter_index,
        chapter_id = chapterId(book, chapter_index),
        paragraph = paragraph_index,
        char = char_index,
    }
end

local function normalizePosition(book, position)
    position = Util.positionCopy(position)
    if position.chapter < 1 then position.chapter = 1 end
    if position.chapter > #book.chapters then position.chapter = #book.chapters end
    if position.paragraph < 1 then position.paragraph = 1 end
    if position.char < 1 then position.char = 1 end
    local current_id = chapterId(book, position.chapter)
    if position.chapter_id ~= nil and tostring(position.chapter_id) ~= tostring(current_id) then
        position.paragraph = 1
        position.char = 1
    end
    position.chapter_id = current_id
    return position
end

function Paginator:_advanceToValid(book, position)
    position = normalizePosition(book, position)
    while position.chapter <= #book.chapters do
        local model, err = BookService:loadChapterModel(book, position.chapter)
        if not model then return nil, err end
        if position.paragraph > #model.paragraphs then
            if position.chapter >= #book.chapters then
                return {
                    chapter = #book.chapters,
                    chapter_id = chapterId(book, #book.chapters),
                    paragraph = #model.paragraphs,
                    char = paragraphLength(model, #model.paragraphs) + 1,
                    at_end = true,
                }
            end
            position = makePosition(book, position.chapter + 1, 1, 1)
        else
            local length = paragraphLength(model, position.paragraph)
            if position.char > length then
                position.paragraph = position.paragraph + 1
                position.char = 1
            else
                return position, nil, model
            end
        end
    end
    return nil, "已到书籍末尾"
end

local function makeMeasureWidget(text, face, width, line_spacing, alignment, bold)
    return TextBoxWidget:new{
        text = text,
        face = face,
        width = width,
        line_height = line_spacing,
        lang = "zh-CN",
        bold = bold == true,
        alignment = alignment or "left",
        alignment_strict = true,
        for_measurement_only = true,
    }
end

function Paginator:makePage(book, requested_position, style)
    local position, err, model = self:_advanceToValid(book, requested_position)
    if not position then return nil, err end
    if position.at_end then return nil, "已到书籍末尾" end

    local geometry = self:getGeometry(style)
    local at_chapter_start = position.paragraph == 1 and position.char == 1
    local show_header = style.show_header and not at_chapter_start
    if not show_header and geometry.header_height > 0 then
        geometry.content_height = geometry.content_height + geometry.header_height
        geometry.header_height = 0
    end
    local page = {
        start_position = Util.positionCopy(position),
        next_position = nil,
        -- ReaderView's footer uses the same model that pagination just loaded.
        -- Keeping this one current-chapter reference avoids a second lookup on
        -- every ordinary page turn without creating a page cache.
        chapter_model = model,
        elements = {},
        chapter_index = position.chapter,
        chapter_title = model.title,
        geometry = geometry,
        style = style,
        used_height = 0,
        at_end = false,
        is_chapter_start = at_chapter_start,
        show_header = show_header,
    }

    local remaining_height = geometry.content_height

    if at_chapter_start then
        local title_face = resolveReaderFace(style, "title_font", "title_font_index",
            "title_font_display_name", style.title_font_size or 34)
        local title_bold = style.title_bold ~= false
        local title_measure = makeMeasureWidget(model.title, title_face, geometry.content_width,
            0.18, "left", title_bold)
        local title_height = measuredHeight(title_measure)
        local top_gap, bottom_gap
        if (tonumber(style.layout_version or 2) or 2) >= 2 then
            -- The opening is a proportion of the physical page, not a Kindle
            -- 7-only pixel constant. Keep the first body line around 36% of
            -- the page, then center the title vertically in the physical
            -- opening between the top edge and that body line. The title
            -- remains left aligned with the body; only its Y position moves.
            local body_y = math.floor(geometry.screen_height * 0.36)
            local title_y = math.floor((body_y - title_height) / 2)
            top_gap = math.max(0, title_y - geometry.body_top)
            bottom_gap = math.max(0, body_y - geometry.body_top - top_gap - title_height)
        else
            top_gap = Screen:scaleBySize(style.title_margin_top or 44)
            bottom_gap = Screen:scaleBySize(style.title_margin_bottom or 54)
        end
        local total = top_gap + title_height + bottom_gap
        -- Never emit a title-only page with an unchanged next position.
        -- Keep room for at least one body line; otherwise start with body text.
        if total + geometry.body_line_height <= remaining_height then
            table.insert(page.elements, {
                type = "title",
                text = model.title,
                height = title_height,
                top_gap = top_gap,
                bottom_gap = bottom_gap,
                face = title_face,
                bold = title_bold,
                line_height = 0.18,
                alignment = "left",
            })
            page.used_height = page.used_height + total
            remaining_height = remaining_height - total
        end
    end

    local chapter_index = position.chapter
    local paragraph_index = position.paragraph
    local char_index = position.char
    local paragraph_gap = Screen:scaleBySize(style.paragraph_spacing or 10)
    local added_line = false
    -- A source may return an entire chapter as one physical line. Shaping the
    -- complete remaining paragraph just to draw one screen can freeze a Kindle 7
    -- and briefly duplicate tens of thousands of UTF-8 characters. Measure only a
    -- bounded forward window; a normal page consumes far fewer characters.
    local max_measure_chars = 768
    model._utf8_hints = model._utf8_hints or {}

    while chapter_index == position.chapter and paragraph_index <= #model.paragraphs do
        local paragraph = model.paragraphs[paragraph_index]
        local paragraph_done = false
        while not paragraph_done do
            local prefix = ""
            local prefix_length = 0
            local content_char_index = char_index
            if char_index == 1 then
                content_char_index = char_index + leadingIndentChars(paragraph)
                if style.indent ~= false then
                    prefix = INDENT
                    prefix_length = 2
                end
            end
            local hint = model._utf8_hints[paragraph_index]
            local window_text, window_count, has_more, next_byte = Util.utf8Window(
                paragraph, content_char_index, max_measure_chars,
                hint and hint.char, hint and hint.byte)
            if window_count <= 0 then
                model._utf8_lengths = model._utf8_lengths or {}
                model._utf8_lengths[paragraph_index] = math.max(0, content_char_index - 1)
                paragraph_done = true
                break
            end
            local layout_text = prefix .. window_text
            -- This table is now strictly bounded instead of mirroring the full
            -- chapter-sized paragraph.
            local layout_chars = Util.utf8Chars(layout_text)
            local measure = makeMeasureWidget(layout_text, geometry.body_face,
                geometry.content_width, style.line_spacing or 0.28, "left")
            local lines = measure.vertical_string_list or {}

            for line_index, line in ipairs(lines) do
                if line.end_offset and line.end_offset >= line.offset then
                    if geometry.body_line_height > remaining_height and (added_line or #page.elements > 0) then
                        local next_layout_offset = line.offset
                        local next_char = content_char_index + math.max(0, next_layout_offset - prefix_length - 1)
                        page.next_position = makePosition(book, chapter_index, paragraph_index, next_char)
                        return page
                    end

                    -- TextBoxWidget uses an XText userdata as charlist when shaping is enabled,
                    -- so do not call its private _getLineText() (which expects a Lua table).
                    local text = table.concat(layout_chars, "", line.offset, line.end_offset)
                    local next_line = lines[line_index + 1]
                    local next_layout_offset = next_line and next_line.offset or (#layout_chars + 1)
                    local next_char = content_char_index + math.max(0, next_layout_offset - prefix_length - 1)
                    local is_last_line = line_index == #lines

                    table.insert(page.elements, {
                        type = "line",
                        text = text,
                        height = geometry.body_line_height,
                        paragraph = paragraph_index,
                        start_char = content_char_index + math.max(0, line.offset - prefix_length - 1),
                        next_char = next_char,
                        paragraph_end = is_last_line and not has_more,
                    })
                    page.used_height = page.used_height + geometry.body_line_height
                    remaining_height = remaining_height - geometry.body_line_height
                    added_line = true

                    if not is_last_line and remaining_height < geometry.body_line_height then
                        page.next_position = makePosition(book, chapter_index, paragraph_index, next_char)
                        return page
                    end
                end
            end

            if has_more then
                char_index = content_char_index + window_count
                model._utf8_hints[paragraph_index] = { char = char_index, byte = next_byte }
                if remaining_height < geometry.body_line_height then
                    page.next_position = makePosition(book, chapter_index, paragraph_index, char_index)
                    return page
                end
            else
                model._utf8_lengths = model._utf8_lengths or {}
                model._utf8_lengths[paragraph_index] = content_char_index + window_count - 1
                paragraph_done = true
            end
        end

        paragraph_index = paragraph_index + 1
        char_index = 1
        if paragraph_index <= #model.paragraphs then
            if paragraph_gap + geometry.body_line_height <= remaining_height then
                table.insert(page.elements, { type = "gap", height = paragraph_gap })
                page.used_height = page.used_height + paragraph_gap
                remaining_height = remaining_height - paragraph_gap
            elseif added_line then
                page.next_position = makePosition(book, chapter_index, paragraph_index, 1)
                return page
            end
        end
    end

    if chapter_index < #book.chapters then
        page.next_position = makePosition(book, chapter_index + 1, 1, 1)
    else
        page.next_position = makePosition(book, chapter_index, #model.paragraphs,
            paragraphLength(model, #model.paragraphs) + 1)
        page.at_end = true
    end
    return page
end

local function previousSearchStart(book, target_position)
    local chapter_index = target_position.chapter
    local paragraph_index = target_position.paragraph
    local char_index = target_position.char

    if paragraph_index == 1 and char_index == 1 then
        chapter_index = chapter_index - 1
        if chapter_index < 1 then return nil, "已经是第一页" end
        local model, err = BookService:loadChapterModel(book, chapter_index)
        if not model then return nil, err end
        paragraph_index = math.max(1, #model.paragraphs)
        local length = paragraphLength(model, paragraph_index)
        -- 4096 characters is several Kindle pages in normal layouts, while still
        -- bounding the amount of shaping needed to recover the previous screen.
        char_index = math.max(1, length - 4096)
    elseif char_index > 1 then
        char_index = math.max(1, char_index - 4096)
    else
        paragraph_index = math.max(1, paragraph_index - 8)
        char_index = 1
    end
    return { chapter = chapter_index, paragraph = paragraph_index, char = char_index }
end

function Paginator:findPreviousPage(book, target_position, style)
    target_position = normalizePosition(book, target_position)
    local cursor, start_err = previousSearchStart(book, target_position)
    if not cursor then return nil, start_err end

    local previous_page = nil
    -- Starting near the target removes the old O(all pages since chapter start)
    -- behavior. The window above normally needs fewer than ten iterations; 64 is
    -- a hard safety ceiling for unusual fonts, margins and paragraph structure.
    local safety = 0
    while safety < 64 do
        safety = safety + 1
        local page, err = self:makePage(book, cursor, style)
        if not page then return previous_page, err end
        if Util.positionEqual(page.next_position, target_position) then return page end
        if Util.positionLess(page.next_position, target_position) then
            previous_page = page
            cursor = page.next_position
        else
            return previous_page or page
        end
    end
    return previous_page, "向前分页超过局部安全限制"
end

return Paginator
