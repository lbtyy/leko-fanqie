local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Leko/Fanqie/ReviewDialog.lua
--
-- 段评弹窗（阶段③ T07）：复用 leko Dialog/InputDialog/ScrollTextWidget，
-- 居中半屏，点击触底加载下一页，关闭回原位不重排。
-- 设计依据：docs/DESIGN-leko-plus.md §2 类图 + §4.4 时序图 + §T07 验收。
--
-- 数据流：
--   ReaderView:onParaMarkerTap(book, item_id, para_index)
--     → FanqieReviewService:fetchPage
--     → FanqieReviewDialog:show
-- 弹窗生命周期：
--   open:   show（modal，背景保持原章节 widget 不重排）
--   close:  UIManager:close → ReaderView 局部刷新由 ReaderView 负责
--   paging: 列表触底 → onReachEnd → fetchPage(page+1)

local TEXT = {
    title_prefix = "第",
    title_suffix_known = "段 · 共",
    title_suffix_unknown = "段",
    loading = "段评加载中…",
    empty = "暂无评论",
    end_reached = "已加载全部评论",
    load_more = "点击加载更多…",
    error_title = "段评加载失败",
    unsupported = "当前内容源不支持段评",
    close = "关闭",
}

-- [seam] leko-plus 修复：下列 5 个模块路径在 KOReader 中并不存在，
-- 会导致本模块 require 抛错、段评弹窗永远打不开。修正为真实路径：
--   ui/widget/framecontainer  → ui/widget/container/framecontainer
--   ui/widget/leftcontainer   → ui/widget/container/leftcontainer
--   ui/widget/rightcontainer  → ui/widget/container/rightcontainer
--   ui/widget/geometry        → ui/geometry
--   ui/blitbuffer             → ffi/blitbuffer
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")

local ReviewDialog = {}

-- ---------------------------------------------------------------------------
-- 工具：构建评论条目 widget（楼层 / 昵称 / 时间 / 内容）
-- ---------------------------------------------------------------------------

local function padding(size) return VerticalSpan:new{ width = 0, height = size } end
local function vpadding(size) return VerticalSpan:new{ width = 0, height = size } end

local function buildCommentLine(comment, width)
    local floor = tonumber(comment.floor) or 1
    local nick = tostring(comment.nick or "匿名")
    local time = tostring(comment.time or "")
    local text = tostring(comment.text or "")
    local meta_h = math.max(20, math.floor(Font:getFace("smallinfofont", 16).size * 1.4))
    local width_info = math.floor(width * 0.6)
    local width_meta = math.max(80, math.floor(width * 0.35))
    local row = HorizontalGroup:new{
        align = "top",
        LeftContainer:new{
            dimen = Geom:new{ w = width_info, h = meta_h },
            TextBoxWidget:new{
                text = "#" .. tostring(floor) .. "  " .. nick,
                face = Font:getFace("smallinfofont", 16),
                bold = true,
                width = width_info,
                height = meta_h,
                alignment = "left",
            },
        },
        RightContainer:new{
            dimen = Geom:new{ w = width_meta, h = meta_h },
            TextBoxWidget:new{
                text = time,
                face = Font:getFace("smallinfofont", 14),
                width = width_meta,
                height = meta_h,
                alignment = "right",
            },
        },
    }
    local body = TextBoxWidget:new{
        text = text,
        face = Font:getFace("cfont", 18),
        width = width - 16,
        alignment = "left",
    }
    return VerticalGroup:new{
        row,
        padding(4),
        body,
        padding(8),
    }
end

-- ---------------------------------------------------------------------------
-- 列表容器（VerticalGroup）+ 触底回调
-- ---------------------------------------------------------------------------

local function buildListView(items, width, has_more, on_reach_end)
    local children = {}
    if not items or #items == 0 then
        children[#children + 1] = TextBoxWidget:new{
            text = TEXT.empty,
            face = Font:getFace("cfont", 18),
            width = width - 16,
            alignment = "center",
        }
    else
        for _, comment in ipairs(items) do
            children[#children + 1] = buildCommentLine(comment, width - 8)
        end
        if has_more then
            local btn = Button:new{
                text = TEXT.load_more,
                callback = function() if on_reach_end then on_reach_end() end end,
                margin_h = 0,
                margin_v = 0,
            }
            children[#children + 1] = HorizontalGroup:new{
                align = "center",
                LeftContainer:new{
                    dimen = Geom:new{ w = width - 8, h = 30 },
                    btn,
                },
            }
        else
            children[#children + 1] = TextBoxWidget:new{
                text = TEXT.end_reached,
                face = Font:getFace("smallinfofont", 14),
                width = width - 8,
                alignment = "center",
            }
        end
    end
    return VerticalGroup:new{ unpack(children) }
end

-- ---------------------------------------------------------------------------
-- 弹窗工厂
-- ---------------------------------------------------------------------------

--- @param ctx {provider_id, provider_book_id, item_id, para_index, total_count,
--             on_close = function()}
function ReviewDialog:show(ctx)
    if not ctx or not ctx.provider_id then return false, "无法弹出段评：参数缺失" end
    local FanqieReviewService = require("Leko/Fanqie/FanqieReviewService")
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local width = math.min(math.floor(screen_w * 0.92), 720)
    local height = math.floor(screen_h * 0.7)
    local padding = math.max(16, math.floor(width * 0.05))
    local inner_w = width - padding * 2

    local items = {}
    local page = 1
    local has_more = true
    local loading = true
    local error_text = nil
    local list_view = nil
    local header_widget = nil
    local dialog = nil

    local function updateHeader()
        if not header_widget then return end
        local total = ctx.total_count and (" · 共 " .. tostring(ctx.total_count) .. " 条") or ""
        header_widget[1] = TextBoxWidget:new{
            text = string.format("%s %d %s%s", TEXT.title_prefix, ctx.para_index or 0,
                TEXT.title_suffix_unknown, total),
            face = Font:getFace("tfont", 22),
            bold = true,
            width = inner_w - 24,
            alignment = "left",
        }
    end

    local function buildBody()
        local body_children = {}
        if error_text then
            body_children[#body_children + 1] = TextBoxWidget:new{
                text = TEXT.error_title .. "\n" .. tostring(error_text),
                face = Font:getFace("cfont", 18),
                width = inner_w - 16,
                alignment = "left",
            }
        elseif loading then
            body_children[#body_children + 1] = TextBoxWidget:new{
                text = TEXT.loading,
                face = Font:getFace("cfont", 18),
                width = inner_w - 16,
                alignment = "center",
            }
        else
            list_view = buildListView(items, inner_w, has_more, function()
                if loading or not has_more then return end
                page = page + 1
                loading = true
                rebuild()
                loadNextPage()
            end)
            body_children[#body_children + 1] = list_view
        end
        return body_children
    end

    local function rebuild()
        updateHeader()
        if not dialog then return end
        local body = VerticalGroup:new{ unpack(buildBody()) }
        dialog[1] = FrameContainer:new{
            width = width,
            height = height,
            padding = padding,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                header_widget,
                vpadding(12),
                body,
                vpadding(8),
                HorizontalGroup:new{
                    align = "right",
                    LeftContainer:new{
                        dimen = Geom:new{ w = inner_w - 80, h = 36 },
                    },
                    Button:new{
                        text = TEXT.close,
                        margin_h = 4,
                        margin_v = 4,
                        callback = function() closeDialog() end,
                    },
                },
            },
        }
        UIManager:setDirty(dialog, "ui")
    end

    local function loadNextPage()
        FanqieReviewService:fetchPage(ctx.provider_id, ctx.provider_book_id, ctx.item_id,
            ctx.para_index, page, function(ok, err, page_table)
                loading = false
                if not ok then
                    error_text = tostring(err or "网络请求失败")
                    rebuild()
                    return
                end
                for _, c in ipairs(page_table.items or {}) do
                    items[#items + 1] = c
                end
                has_more = page_table.has_more == true
                rebuild()
            end)
    end

    local function closeDialog()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
        if ctx.on_close then pcall(ctx.on_close) end
    end

    -- 标题栏 + 关闭按钮
    header_widget = VerticalGroup:new{
        TextBoxWidget:new{
            text = string.format("%s %d %s", TEXT.title_prefix, ctx.para_index or 0,
                TEXT.title_suffix_unknown),
            face = Font:getFace("tfont", 22),
            bold = true,
            width = inner_w - 24,
            alignment = "left",
        },
    }

    -- 容器 —— 以"自动弹层"方式加入 UI Manager，背景读者 widget 不重排
    dialog = FrameContainer:new{
        width = width,
        height = height,
        background = Blitbuffer.COLOR_WHITE,
    }
    dialog._fanqie_review_dialog = true
    dialog._review_close = closeDialog
    UIManager:show(dialog, "full")
    rebuild()
    loadNextPage()
    return true
end

-- 不支持段评的源点击提示（设计文档 PRD §P0-4④）
function ReviewDialog:showUnsupported(ctx)
    local screen_w = Screen:getWidth()
    local width = math.min(math.floor(screen_w * 0.92), 480)
    local height = 180
    local body_height = height - 60
    local dialog = FrameContainer:new{
        width = width,
        height = height,
        padding = 18,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            TextBoxWidget:new{
                text = TEXT.unsupported,
                face = Font:getFace("cfont", 20),
                width = width - 36,
                height = body_height - 36,
                alignment = "left",
            },
            vpadding(8),
            HorizontalGroup:new{
                align = "right",
                LeftContainer:new{
                    dimen = Geom:new{ w = width - 96, h = 36 },
                },
                Button:new{
                    text = TEXT.close,
                    margin_h = 4,
                    margin_v = 4,
                    callback = function()
                        UIManager:close(dialog)
                        if ctx and ctx.on_close then pcall(ctx.on_close) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "full")
    return true
end

return ReviewDialog
