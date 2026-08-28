-- Leko/Fanqie/FanqieContent.lua
--
-- 番茄正文清洗：不可见字符 → 去广告 → 去标签 → HTML 实体解码 → PUA 解码。
-- 输出纯文本（leko 章节模型只消费纯文本）；fanqie 的 HTML 生成/CREngine
-- 链路（txt_to_xhtml/save_chapter_html/fix_svg_imgs_in_text 等）按设计
-- §1.5/Q4 全部废弃，不进入本文件。

local FanqieContent = {}

-- 移植自 fanqie/content.lua:423 PUA_CODE，原样数据（官方 API 正文私用区编码区间）。
local PUA_CODE = { { 58344, 58715 }, { 58345, 58716 } }

-- 移植自 fanqie/content.lua:424-427 PUA_CHARSET，原样数据表（PUA 码位 → 明文字符）。
-- 表内 "?" 为上游数据本身的占位符（未知字符），decode 时遇到 "?" 不解码、保留原字符。
local PUA_CHARSET = {
    { "D","在","主","特","家","军","然","表","场","4","要","只","v","和","?","6","别","还","g","现","儿","岁","?","?","此","象","月","3","出","战","工","相","o","男","直","失","世","F","都","平","文","什","V","O","将","真","T","那","当","?","会","立","些","u","是","十","张","学","气","大","爱","两","命","全","后","东","性","通","被","1","它","乐","接","而","感","车","山","公","了","常","以","何","可","话","先","p","i","叫","轻","M","士","w","着","变","尔","快","l","个","说","少","色","里","安","花","远","7","难","师","放","t","报","认","面","道","S","?","克","地","度","I","好","机","U","民","写","把","万","同","水","新","没","书","电","吃","像","斯","5","为","y","白","几","日","教","看","但","第","加","候","作","上","拉","住","有","法","r","事","应","位","利","你","声","身","国","问","马","女","他","Y","比","父","x","A","H","N","s","X","边","美","对","所","金","活","回","意","到","z","从","j","知","又","内","因","点","Q","三","定","8","R","b","正","或","夫","向","德","听","更","?","得","告","并","本","q","过","记","L","让","打","f","人","就","者","去","原","满","体","做","经","K","走","如","孩","c","G","给","使","物","?","最","笑","部","?","员","等","受","k","行","一","条","果","动","光","门","头","见","往","自","解","成","处","天","能","于","名","其","发","总","母","的","死","手","入","路","进","心","来","h","时","力","多","开","已","许","d","至","由","很","界","n","小","与","Z","想","代","么","分","生","口","再","妈","望","次","西","风","种","带","J","?","实","情","才","这","?","E","我","神","格","长","觉","间","年","眼","无","不","亲","关","结","0","友","信","下","却","重","己","老","2","音","字","m","呢","明","之","前","高","P","B","目","太","e","9","起","稜","她","也","W","用","方","子","英","每","理","便","四","数","期","中","C","外","样","a","海","们","任" },
    { "s","?","作","口","在","他","能","并","B","士","4","U","克","才","正","们","字","声","高","全","尔","活","者","动","其","主","报","多","望","放","h","w","次","年","?","中","3","特","于","十","入","要","男","同","G","面","分","方","K","什","再","教","本","己","结","1","等","世","N","?","说","g","u","期","Z","外","美","M","行","给","9","文","将","两","许","张","友","0","英","应","向","像","此","白","安","少","何","打","气","常","定","间","花","见","孩","它","直","风","数","使","道","第","水","已","女","山","解","d","P","的","通","关","性","叫","儿","L","妈","问","回","神","来","S","","四","望","前","国","些","O","v","l","A","心","平","自","无","军","光","代","是","好","却","c","得","种","就","意","先","立","z","子","过","Y","j","表","","么","所","接","了","名","金","受","J","满","眼","没","部","那","m","每","车","度","可","R","斯","经","现","门","明","V","如","走","命","y","6","E","战","很","上","f","月","西","7","长","夫","想","话","变","海","机","x","到","W","一","成","生","信","笑","但","父","开","内","东","马","日","小","而","后","带","以","三","几","为","认","X","死","员","目","位","之","学","远","人","音","呢","我","q","乐","象","重","对","个","被","别","F","也","书","稜","D","写","还","因","家","发","时","i","或","住","德","当","o","l","比","觉","然","吃","去","公","a","老","亲","情","体","太","b","万","C","电","理","?","失","力","更","拉","物","着","原","她","工","实","色","感","记","看","出","相","路","大","你","候","2","和","?","与","p","样","新","只","便","最","不","进","T","r","做","格","母","总","爱","身","师","轻","知","往","加","从","?","天","e","H","?","听","场","由","快","边","让","把","任","8","条","头","事","至","起","点","真","手","这","难","都","界","用","法","n","处","下","又","Q","告","地","5","k","t","岁","有","会","果","利","民" }
}

-- 移植自 fanqie/content.lua:429-451 utf8_codepoint，适配点：无。
local function utf8_codepoint(str, i)
    local b1 = str:byte(i)
    if not b1 then return nil, i end
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
        local b2 = str:byte(i + 1)
        if not b2 then return nil, i end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        if not b2 or not b3 then return nil, i end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4 then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        local b4 = str:byte(i + 3)
        if not b2 or not b3 or not b4 then return nil, i end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), i + 4
    end
    return nil, i
end

--- PUA 私用区解码。
-- 移植自 fanqie/content.lua:453-484 decode_pua_content，适配点：无。
function FanqieContent:decodePua(content)
    if not content then return "" end
    local result = {}
    local i = 1
    while i <= #content do
        local code, next_i = utf8_codepoint(content, i)
        if not code then
            table.insert(result, content:sub(i, i))
            i = i + 1
            goto continue
        end
        local decoded = false
        for mode = 1, 2 do
            local range = PUA_CODE[mode]
            if code >= range[1] and code <= range[2] then
                local bias = code - range[1]
                local charset = PUA_CHARSET[mode]
                if bias + 1 <= #charset and charset[bias + 1] ~= "?" then
                    table.insert(result, charset[bias + 1])
                    decoded = true
                end
                break
            end
        end
        if not decoded then
            table.insert(result, content:sub(i, next_i - 1))
        end
        i = next_i
        ::continue::
    end
    return table.concat(result)
end

--- 去标签（保留换行语义）。
-- 移植自 fanqie/content.lua:486-496 strip_html，适配点：无。
function FanqieContent:stripHtml(html)
    if not html then return "" end
    html = html:gsub("<br%s*/?>", "\n"):gsub("</p%s*>", "\n")
    html = html:gsub("</div%s*>", "\n"):gsub("</h[1-6]%s*>", "\n")
    html = html:gsub("<[^>]+>", ""):gsub("&nbsp;", " ")
    html = html:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    html = html:gsub("&quot;", "\""):gsub("&#39;", "'")
    html = html:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    html = html:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    return html
end

-- 移植自 fanqie/content.lua:498-509 utf8_char，适配点：无。
local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    elseif code < 0x110000 then
        return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + (math.floor(code / 0x1000) % 0x40), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    end
    return ""
end

--- HTML 实体解码（含数字实体）。
-- 移植自 fanqie/content.lua:511-526 decode_html_entities，适配点：无。
function FanqieContent:decodeHtmlEntities(text)
    if not text then return "" end
    text = text:gsub("&nbsp;", " "):gsub("&amp;", "&")
    text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("&quot;", "\""):gsub("&#39;", "'")
    text = text:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    text = text:gsub("&lsquo;", "\u{2018}"):gsub("&rsquo;", "\u{2019}")
    text = text:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    text = text:gsub("&#(%d+);", function(code)
        return utf8_char(tonumber(code, 10))
    end)
    text = text:gsub("&#x([0-9a-fA-F]+);", function(code)
        return utf8_char(tonumber(code, 16))
    end)
    return text
end

--- 纯文本语境的墨水屏安全处理。
-- 移植自 fanqie/content.lua:115-155 fix_svg_for_inkscreen 的意图，适配点：
-- fanqie 原函数服务于 CREngine 的 SVG 灰度转换；leko-plus 正文为纯文本
-- （设计 Q4：不下载正文图片），此处只需剥离残留的 <img>/<svg> 标签。
function FanqieContent:inkscreenSafe(text)
    if not text then return "" end
    text = text:gsub("<[iI][mM][gG][^>]*>", "")
    text = text:gsub("<[sS][vV][gG][^>]*>[%s%S]-</[sS][vV][gG]%s*>", "")
    return text
end

--- 正文清洗主入口：官方 API 的 content 字段 → leko 章节纯文本。
-- 移植自 fanqie/content.lua:528-562 clean_chapter_content 的清洗段，适配点：
--   1. <comment> 段评气泡的 HTML 生成废弃（上游段评链接协议不移植），
--      段评阶段③由 ReaderView 命中区域实现；此处仅移除 <comment> 标签；
--   2. body 提取/广告删除/不可见字符语义与上游一致；
--   3. PUA 解码前置（对应上游 fetch_chapter_content:1218 的调用顺序：
--      先解码再清洗；触发条件为正文含 \238 即 U+E000-U+F8FF 私用区首字节）。
function FanqieContent:clean(raw_content, title)
    if not raw_content then return "" end
    local content = raw_content

    -- PUA 解码必须在清洗之前（与上游 fetch_chapter_content:1218 的顺序一致：
    -- 先 decode_pua_content 再 clean_chapter_content），否则广告起始标记
    -- （📣/本书源）与 <comment> 标签在 PUA 编码文本中无法命中。
    -- 触发条件同上游：正文含 \238 即 U+E000-U+F8FF 私用区首字节。
    if content:find("\238", 1, true) then
        content = self:decodePua(content)
    end

    -- 移除不可见字符（零宽空格、BOM、软连字符、双向控制符等）
    -- U+200B-200F, U+2028-202E, U+FEFF, U+00AD
    content = content:gsub("\226\128[\139\140\141\142\143]", "")  -- U+200B-200F
    content = content:gsub("\226\128[\168\169\170\171\172\173\174]", "")  -- U+2028-202E
    content = content:gsub("\194\173", "")  -- U+00AD 软连字符
    content = content:gsub("\239\187\191", "")  -- U+FEFF BOM

    -- 移除非正文元素
    content = content:gsub("<header[^>]->[%s%S]-</header>", "")
    content = content:gsub("<script[^>]->[%s%S]-</script>", "")
    content = content:gsub("<style[^>]->[%s%S]-</style>", "")
    content = content:gsub("<nav[^>]->[%s%S]-</nav>", "")
    content = content:gsub("<!--[%s%S]--->", "")

    local body_match = content:match("<body[^>]->([%s%S]-)</body>")
    if body_match then
        content = body_match
    end

    -- 移除末尾广告：晴天广告以 📣 开头，大灰狼以 "本书源" 开头
    -- 📣 = U+1F4E3 = F0 9F 93 A3
    local ad_start = nil
    local qt_ad = content:find("\240\159\147\163", 1, true)
    local dl_ad = content:find("本书源", 1, true)
    if qt_ad then ad_start = qt_ad end
    if dl_ad and (not ad_start or dl_ad < ad_start) then ad_start = dl_ad end
    if ad_start then
        content = content:sub(1, ad_start - 1)
    end

    -- 段评 <comment> 标签：leko-plus 阶段③用段落命中区域实现段评，
    -- 此处只摘除标签，保留段落文字。
    content = content:gsub('<comment%s+ident="([^"]*)"%s+count="([^"]*)"%s*/?>', "")
    content = content:gsub('<comment%s+ident="([^"]*)"%s*/?>', "")

    -- 去标签 → 实体解码 → 墨水屏安全（纯文本兜底）
    content = self:stripHtml(content)
    content = self:decodeHtmlEntities(content)
    content = self:inkscreenSafe(content)

    -- 规范化换行并去掉首尾空白
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    content = content:gsub("^\n+", ""):gsub("\n+$", "")
    return content
end

return FanqieContent
