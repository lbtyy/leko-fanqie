local rapidjson = require("rapidjson")

local Version = require("Leko/Version")
local WelcomeGuide = require("Leko/WelcomeGuide")

local BuiltinSources = {
    version = Version.builtin_sources_version or 1,
}

BuiltinSources.sources = {
    {
        bookSourceName = "Leko 内置说明",
        bookSourceGroup = "Leko 内置",
        bookSourceUrl = "leko://fixture",
        enabled = false,
        enabledCookieJar = false,
        searchUrl = "leko://fixture/search.json?key={{key}}&page={{page}}",
        ruleSearch = {
            bookList = "$.results[*]",
            name = "$.title",
            author = "$.author",
            bookUrl = "$.book_url",
            intro = "$.intro",
        },
        ruleBookInfo = {
            init = "$",
            name = "$.title",
            author = "$.author",
            intro = "$.intro",
            tocUrl = "$.toc_url",
        },
        ruleToc = {
            chapterList = "$.chapters[*]",
            chapterName = "$.title",
            chapterUrl = "$.url",
        },
        ruleContent = {
            content = "#content@html",
        },
    },
}

local fixture_bodies = {
    ["leko://fixture/search.json"] = function()
        return rapidjson.encode({
            results = {
                {
                    title = WelcomeGuide.title,
                    author = WelcomeGuide.author,
                    intro = WelcomeGuide.intro,
                    book_url = "leko://fixture/book.json",
                },
            },
        }), "application/json; charset=utf-8"
    end,
    ["leko://fixture/book.json"] = function()
        return rapidjson.encode({
            title = WelcomeGuide.title,
            author = WelcomeGuide.author,
            intro = WelcomeGuide.intro,
            toc_url = "leko://fixture/toc.json",
        }), "application/json; charset=utf-8"
    end,
    ["leko://fixture/toc.json"] = function()
        return rapidjson.encode({
            chapters = (function()
                local chapters = {}
                for index, chapter in ipairs(WelcomeGuide.chapters) do
                    chapters[index] = { title = chapter.title, url = "leko://fixture/chapter-" .. index .. ".html" }
                end
                return chapters
            end)(),
        }), "application/json; charset=utf-8"
    end,
}

local function escapeHtml(text)
    return tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

for index, chapter in ipairs(WelcomeGuide.chapters) do
    local chapter_text = chapter.text
    fixture_bodies["leko://fixture/chapter-" .. index .. ".html"] = function()
        local paragraphs = {}
        for paragraph in tostring(chapter_text or ""):gmatch("[^\n]+") do
            if paragraph:match("%S") then paragraphs[#paragraphs + 1] = "<p>" .. escapeHtml(paragraph) .. "</p>" end
        end
        return '<!doctype html><html><body><article id="content">'
            .. table.concat(paragraphs) .. '</article></body></html>', "text/html; charset=utf-8"
    end
end

function BuiltinSources:isFixtureUrl(url)
    return tostring(url or ""):match("^leko://fixture") ~= nil
end

function BuiltinSources:request(url)
    local normalized = tostring(url or ""):gsub("[?#].*$", "")
    local producer = fixture_bodies[normalized]
    if not producer then return nil, "内置说明资源不存在：" .. normalized end
    local body, content_type = producer()
    return {
        url = normalized,
        code = 200,
        headers = { ["content-type"] = content_type },
        content_type = content_type,
        body = body,
        status = "200 OK",
    }
end

return BuiltinSources
