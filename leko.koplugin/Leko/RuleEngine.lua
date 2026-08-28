local rapidjson = require("rapidjson")
local htmlparser = require("htmlparser")
local Http = require("Leko/Http")
local QuickJS = require("Leko/QuickJS")
local ExecutionTrace = require("Leko/ExecutionTrace")
local Regex = require("Leko/Regex")
local Util = require("Leko/Util")
local Digest = require("Leko/Digest")

local RuleEngine = {}

-- A few focused parser tests provide a deliberately tiny HTTP double.  Keep
-- diagnostic redaction optional there while retaining the production helper
-- whenever the real HTTP module is loaded.
local function diagnosticUrl(value)
    if type(Http.diagnosticUrl) == "function" then
        local ok, redacted = pcall(Http.diagnosticUrl, Http, value)
        if ok and redacted ~= nil then return tostring(redacted) end
    end
    return tostring(value or "")
end

local function isNode(value)
    return type(value) == "table" and (type(value.select) == "function" or type(value.getcontent) == "function")
end

local function nodeHtml(node)
    if node == nil then return "" end
    if type(node) == "string" or type(node) == "number" then return tostring(node) end
    if isNode(node) and node.getcontent then
        local ok, value = pcall(node.getcontent, node)
        if ok and value then return tostring(value) end
    end
    return ""
end

local function nodeOuterHtml(node)
    if node == nil then return "" end
    if type(node) == "string" or type(node) == "number" then return tostring(node) end
    -- lua-htmlparser exposes the complete element (opening tag, content and
    -- closing tag) through gettext(), while getcontent() is inner HTML.
    if isNode(node) and type(node.gettext) == "function" then
        local ok, value = pcall(node.gettext, node)
        if ok and value then return tostring(value) end
    end
    if isNode(node) and type(node.outerHtml) == "function" then
        local ok, value = pcall(node.outerHtml, node)
        if ok and value then return tostring(value) end
    end
    return nodeHtml(node)
end

local function nodeText(node)
    if node == nil then return "" end
    if type(node) == "string" or type(node) == "number" then return tostring(node) end
    return Util.stripHtml(nodeHtml(node))
end

local function directText(node)
    if not isNode(node) then return nodeText(node) end
    local output = {}
    for _, child in ipairs(node.nodes or node.children or {}) do
        if type(child) == "string" then
            output[#output + 1] = child
        elseif type(child) == "table" and (child.name == nil or child.name == "#text" or child.type == "text") then
            output[#output + 1] = nodeHtml(child)
        end
    end
    if #output == 0 then return nodeText(node) end
    return Util.htmlEntityDecode(table.concat(output))
end

local function nodeAttribute(node, attribute)
    if not node or type(node) ~= "table" then return "" end
    for _, map in ipairs({ node.attributes, node.attr, node.attrs }) do
        if type(map) == "table" then
            local value = map[attribute]
            if type(value) == "table" then value = value[1] end
            if value ~= nil then return tostring(value) end
        end
    end
    if type(node.getattribute) == "function" then
        local ok, value = pcall(node.getattribute, node, attribute)
        if ok and value ~= nil then return tostring(value) end
    end
    return ""
end

local function parseJsonIfNeeded(value)
    if type(value) == "table" and not isNode(value) then return value end
    if type(value) ~= "string" then return nil end
    local candidate = value
    -- A surprising number of mobile APIs prepend a UTF-8 BOM or the common
    -- XSSI guard `)]}',` before otherwise valid JSON. Android/Legado accepts
    -- these responses through its parser path; treating them as HTML here
    -- makes valid JSONPath rules silently return empty results.
    candidate = candidate:gsub("^\239\187\191", "")
    candidate = candidate:gsub("^%s*%)%]%}',?%s*[\r\n]+", "")
    local first = candidate:match("^%s*(.)")
    if first ~= "{" and first ~= "[" then return nil end
    local ok, decoded = pcall(rapidjson.decode, candidate)
    return ok and decoded or nil
end

local function tableValues(value)
    local result = {}
    if type(value) ~= "table" then return result end
    for _, item in ipairs(value) do result[#result + 1] = item end
    if #result == 0 then
        -- The former compatibility interpreter annotated arrays with
        -- non-data `__js_*` fields.  Those
        -- fields are implementation metadata, never list items.  In
        -- particular, an empty JavaScript array must stay empty instead of
        -- becoming one candidate containing its constructor marker.
        for key, item in pairs(value) do
            if not (type(key) == "string" and key:match("^__js_")) then
                result[#result + 1] = item
            end
        end
    end
    return result
end

local function isArrayLike(value)
    if type(value) ~= "table" then return false end
    if rawget(value, "__js_constructor") ~= nil then return true end
    local count, maximum, has_non_numeric = 0, 0, false
    for key in pairs(value) do
        if type(key) == "number" and key >= 1 and key % 1 == 0 then
            count = count + 1
            if key > maximum then maximum = key end
        elseif not (type(key) == "string" and key:match("^__js_")) then
            has_non_numeric = true
        end
    end
    return not has_non_numeric and count > 0 and maximum == count
end

local function directJsonValue(value)
    if type(value) ~= "table" then return { value } end
    -- A bare JSON rule such as `init=data` selects the object itself when
    -- `data` is an object, but expands an array when it is a list rule.  The
    -- old implementation expanded every table, turning `{book_id=...}` into
    -- a scalar field and losing IDs needed by the next URL template.
    if next(value) == nil then return {} end
    if isArrayLike(value) then return tableValues(value) end
    return { value }
end

local function recursiveFind(value, key, output, depth)
    if type(value) ~= "table" or depth > 40 then return end
    if key == "*" then
        for _, child in pairs(value) do output[#output + 1] = child; recursiveFind(child, key, output, depth + 1) end
    else
        if value[key] ~= nil then output[#output + 1] = value[key] end
        for _, child in pairs(value) do recursiveFind(child, key, output, depth + 1) end
    end
end

local function parseJsonPath(path)
    path = tostring(path or "")
    local path_lower = path:lower()
    if path_lower:sub(1, 6) == "@json:" then path = path:sub(7) elseif path_lower:sub(1, 5) == "json:" then path = path:sub(6) end
    local tokens, i = {}, 1
    if path:sub(1, 1) == "$" then i = 2 end
    while i <= #path do
        if path:sub(i, i + 1) == ".." then
            i = i + 2
            local name = path:match("^([%w_%-*]+)", i)
            if not name then break end
            tokens[#tokens + 1] = { kind = "recursive", value = name }
            i = i + #name
        elseif path:sub(i, i) == "." then
            i = i + 1
            -- Jayway/Legado accepts a redundant dot before a bracket selector
            -- (`$.[*]`, `$.[0]`, `$.[?()]`).  Community sources use this in
            -- post-JS pipelines.  Do not require a property name after every
            -- dot; let the bracket branch consume the selector on the next
            -- iteration instead of silently truncating the JSONPath.
            if path:sub(i, i) ~= "[" then
                local name = path:match("^([%w_%-*]+)", i)
                if not name then break end
                tokens[#tokens + 1] = { kind = name == "*" and "wildcard" or "key", value = name }
                i = i + #name
            end
        elseif path:sub(i, i) == "[" then
            local close, quote, escaped, depth = nil, nil, false, 1
            local j = i + 1
            while j <= #path do
                local char = path:sub(j, j)
                if quote then
                    if escaped then escaped = false elseif char == "\\" then escaped = true elseif char == quote then quote = nil end
                elseif char == "'" or char == '"' then quote = char
                elseif char == "[" then depth = depth + 1
                elseif char == "]" then depth = depth - 1; if depth == 0 then close = j break end end
                j = j + 1
            end
            if not close then break end
            local inside = Util.trim(path:sub(i + 1, close - 1))
            if inside == "*" then tokens[#tokens + 1] = { kind = "wildcard" }
            elseif inside:match("^%?%(") then tokens[#tokens + 1] = { kind = "filter", value = inside:sub(3, -2) }
            elseif inside:find(":", 1, true) then
                local a, b, step = inside:match("^(-?%d*)%s*:%s*(-?%d*)%s*:?%s*(-?%d*)$")
                tokens[#tokens + 1] = { kind = "slice", first = tonumber(a), last = tonumber(b), step = tonumber(step) or 1 }
            elseif inside:find(",", 1, true) then
                local values = {}
                for _, part in ipairs(Util.splitPlain(inside, ",")) do
                    part = Util.trim(part):gsub("^['\"]", ""):gsub("['\"]$", "")
                    values[#values + 1] = tonumber(part) or part
                end
                tokens[#tokens + 1] = { kind = "union", values = values }
            else
                inside = inside:gsub("^['\"]", ""):gsub("['\"]$", "")
                tokens[#tokens + 1] = { kind = tonumber(inside) and "index" or "key", value = tonumber(inside) or inside }
            end
            i = close + 1
        else
            local name = path:match("^([%w_%-*]+)", i)
            if not name then break end
            tokens[#tokens + 1] = { kind = name == "*" and "wildcard" or "key", value = name }
            i = i + #name
        end
    end
    return tokens
end

local function filterMatches(item, expression)
    if type(item) ~= "table" then return false end
    local regex_field, regex, flags = expression:match("^%s*@%.([%w_%-%.]+)%s*=~%s*/(.-)/([%a]*)%s*$")
    if regex_field then
        local value = item
        for part in regex_field:gmatch("[^%.]+") do value = type(value) == "table" and value[part] or nil end
        return Regex:test(tostring(value or ""), regex, flags)
    end
    local field, tail = expression:match("^%s*@%.([%w_%-%.]+)%s*(.-)%s*$")
    if not field then return false end
    local operator, raw
    for _, candidate in ipairs({ "==", "!=", ">=", "<=", ">", "<" }) do
        if tail:sub(1, #candidate) == candidate then
            operator, raw = candidate, Util.trim(tail:sub(#candidate + 1))
            break
        end
    end
    if not operator then return false end
    local value = item
    for part in field:gmatch("[^%.]+") do value = type(value) == "table" and value[part] or nil end
    raw = raw:gsub("^['\"]", ""):gsub("['\"]$", "")
    local right = tonumber(raw) or raw
    local left = tonumber(value) or tostring(value or "")
    if operator == "==" then return tostring(left) == tostring(right)
    elseif operator == "!=" then return tostring(left) ~= tostring(right)
    elseif operator == ">" then return left > right elseif operator == "<" then return left < right
    elseif operator == ">=" then return left >= right elseif operator == "<=" then return left <= right end
    return false
end

local function jsonPathValues(root, path)
    local current = { root }
    for _, token in ipairs(parseJsonPath(path)) do
        local next_values = {}
        for _, value in ipairs(current) do
            if token.kind == "recursive" then recursiveFind(value, token.value, next_values, 0)
            elseif token.kind == "wildcard" then for _, item in pairs(type(value) == "table" and value or {}) do next_values[#next_values + 1] = item end
            elseif token.kind == "key" and type(value) == "table" then if value[token.value] ~= nil then next_values[#next_values + 1] = value[token.value] end
            elseif token.kind == "index" and type(value) == "table" then
                local index = token.value >= 0 and token.value + 1 or #value + token.value + 1
                if value[index] ~= nil then next_values[#next_values + 1] = value[index] end
            elseif token.kind == "union" and type(value) == "table" then
                for _, key in ipairs(token.values) do
                    local index = type(key) == "number" and (key >= 0 and key + 1 or #value + key + 1) or key
                    if value[index] ~= nil then next_values[#next_values + 1] = value[index] end
                end
            elseif token.kind == "slice" and type(value) == "table" then
                local first = token.first or 0; local last = token.last or #value
                if first < 0 then first = #value + first end; if last < 0 then last = #value + last end
                local step = token.step ~= 0 and token.step or 1
                local index = first
                while (step > 0 and index < last) or (step < 0 and index > last) do
                    if value[index + 1] ~= nil then next_values[#next_values + 1] = value[index + 1] end
                    index = index + step
                end
            elseif token.kind == "filter" and type(value) == "table" then
                for _, item in ipairs(value) do if filterMatches(item, token.value) then next_values[#next_values + 1] = item end end
            end
        end
        current = next_values
    end
    return current
end

local function flattenJsonSelection(values)
    if #values == 1 and type(values[1]) == "table" and not isNode(values[1]) then
        -- A JSONPath that resolves to an empty array is an empty list, not one
        -- candidate whose fields are all missing.  rapidjson represents both
        -- arrays and objects as Lua tables, but in list-selection context an
        -- empty table cannot produce a usable list item either way.  Returning
        -- it as a node made live APIs such as Kuwo report SEARCH_PARSE_EMPTY
        -- instead of the correct successful/no-candidate outcome.
        if next(values[1]) == nil then return {} end
        if isArrayLike(values[1]) then return tableValues(values[1]) end
    end
    return values
end

local function splitTopLevel(text, delimiter)
    local output, start = {}, 1
    local quote, escaped, round, square, curly = nil, false, 0, 0, 0
    local i = 1
    while i <= #text do
        local char = text:sub(i, i)
        if quote then
            if escaped then escaped = false
            elseif char == "\\" then escaped = true
            elseif char == quote then quote = nil end
        elseif char == "'" or char == '"' or char == "`" then quote = char
        elseif char == "(" then round = round + 1
        elseif char == ")" then round = round - 1
        elseif char == "[" then square = square + 1
        elseif char == "]" then square = square - 1
        elseif char == "{" then curly = curly + 1
        elseif char == "}" then curly = curly - 1
        elseif round == 0 and square == 0 and curly == 0
                and text:sub(i, i + #delimiter - 1) == delimiter then
            output[#output + 1] = text:sub(start, i - 1)
            start = i + #delimiter
            i = start - 1
        end
        i = i + 1
    end
    output[#output + 1] = text:sub(start)
    return output
end

local function unquoteRule(value)
    value = Util.trim(value or "")
    local quote = value:sub(1, 1)
    if (quote == "'" or quote == '"' or quote == "`") and value:sub(-1) == quote then
        value = value:sub(2, -2)
        value = value:gsub("\\" .. quote, quote):gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
    end
    return value
end

local function parsePutMap(spec)
    spec = Util.trim(spec or "")
    if spec:sub(1, 1) == "{" and spec:sub(-1) == "}" then spec = spec:sub(2, -2) end
    local assignments = {}
    for _, entry in ipairs(splitTopLevel(spec, ",")) do
        local parts = splitTopLevel(entry, ":")
        if #parts >= 2 then
            local key = unquoteRule(table.remove(parts, 1))
            local value = unquoteRule(table.concat(parts, ":"))
            if key ~= "" then assignments[#assignments + 1] = { key = key, rule = value } end
        end
    end
    return assignments
end

local function parseReplacement(rule)
    rule = tostring(rule or ""):gsub("###$", "##")
    local parts = Util.splitPlain(rule, "##")
    if #parts < 2 then return rule, nil, nil end
    return parts[1], parts[2], parts[3] or ""
end

local TERMINAL_ATTRIBUTES = {
    text = true, textnodes = true, owntext = true,
    html = true, content = true, innerhtml = true,
    href = true, src = true, url = true, value = true,
    title = true, alt = true, content_attr = true,
    style = true, class = true, id = true, name = true, type = true, rel = true,
    target = true, action = true, method = true, poster = true, datetime = true,
}

local function isTerminalAttribute(name)
    name = tostring(name or ""):lower()
    return TERMINAL_ATTRIBUTES[name] == true
        or name:match("^data%-[%w_:%-]+$") ~= nil
        or name:match("^aria%-[%w_:%-]+$") ~= nil
        or name:match("^on[%a][%w_:%-]*$") ~= nil
end

local function parseLegacyIndexList(raw, delimiter)
    local indexes = {}
    local pattern = delimiter == "," and "[^,]+" or "[^:]+"
    for token in tostring(raw or ""):gmatch(pattern) do
        local cleaned = Util.trim(token)
        local index = tonumber(cleaned)
        if index == nil then return nil end
        indexes[#indexes + 1] = index
    end
    if #indexes == 0 then return nil end
    return #indexes == 1 and indexes[1] or indexes
end

local function splitLegacyIndex(value)
    value = tostring(value or "")
    -- Reading/Legado sources use both `span.1:2` and `span[0,-1]` to select
    -- multiple positions.  A single integer remains a scalar for backwards
    -- compatibility; multiple positions are kept in source order.
    local base, raw_indexes = value:match("^(.-)%.([%-?%d:]+)$")
    if base then
        local parsed = parseLegacyIndexList(raw_indexes, ":")
        if parsed ~= nil then return base, parsed end
    end
    base, raw_indexes = value:match("^(.-)%[([%d%-,]+)%]$")
    if base then
        local parsed = parseLegacyIndexList(raw_indexes, ",")
        if parsed ~= nil then return base, parsed end
    end
    return value, nil
end

local function normalizeCssSelector(selector)
    selector = Util.trim(selector or "")
    selector = selector:gsub("～", "~")
    selector = selector:gsub("%s*>%s*", " > ")
    return selector
end

local function parseLegacyExclusions(spec)
    local exclusions = {}
    for raw in tostring(spec or ""):gmatch("[^:]+") do
        local index = tonumber(tostring(Util.trim(raw)))
        if index ~= nil then exclusions[#exclusions + 1] = index end
    end
    return exclusions
end

local function legacySelector(segment)
    segment = Util.trim(segment or "")
    if segment:lower() == "children" or segment:lower() == "child" then
        return "__children__", nil, nil, {}
    end

    -- Legacy Legado selectors allow an exclusion suffix after `!`, e.g.
    -- `tag.dd!0:1:-1`.  The excluded positions are zero-based; negatives count
    -- from the end.  This is widely used to drop headings/ads from TOCs.
    local selector_part, exclusion_spec = segment:match("^(.-)!(.*)$")
    if selector_part then
        segment = selector_part:gsub("%.$", "")
    end
    local exclusions = parseLegacyExclusions(exclusion_spec)

    local text_match = segment:match("^text%.(.+)$")
    if text_match then
        local wanted, index = splitLegacyIndex(text_match)
        return "*", index, unquoteRule(wanted), exclusions
    end
    local kind, rest
    for _, candidate in ipairs({ "class", "id", "tag" }) do
        local matched = segment:match("^" .. candidate .. "%.(.+)$")
        if matched then kind, rest = candidate, matched break end
    end
    local index
    if kind then
        rest, index = splitLegacyIndex(rest)
        if kind == "class" then
            local classes = {}
            for item in tostring(rest):gmatch("%S+") do classes[#classes + 1] = item end
            return "." .. table.concat(classes, "."), index, nil, exclusions
        elseif kind == "id" then return "#" .. rest, index, nil, exclusions end
        return rest, index, nil, exclusions
    end
    local base
    base, index = splitLegacyIndex(segment)
    return normalizeCssSelector(base), index, nil, exclusions
end

local function filterExcluded(values, exclusions)
    if type(exclusions) ~= "table" or #exclusions == 0 then return values end
    local rejected = {}
    for _, index in ipairs(exclusions) do
        local target = index >= 0 and index + 1 or #values + index + 1
        if target >= 1 and target <= #values then rejected[target] = true end
    end
    local output = {}
    for index, value in ipairs(values) do
        if not rejected[index] then output[#output + 1] = value end
    end
    return output
end

local function filterIndex(values, index)
    if index == nil then return values end
    local indexes = type(index) == "table" and index or { index }
    local output, seen = {}, {}
    for _, wanted in ipairs(indexes) do
        local target = wanted >= 0 and wanted + 1 or #values + wanted + 1
        if target >= 1 and target <= #values and not seen[target] then
            output[#output + 1] = values[target]
            seen[target] = true
        end
    end
    return output
end

local function siblingPosition(node, same_type)
    if not node or not node.parent or type(node.parent.nodes) ~= "table" then return nil, nil end
    local position, total = 0, 0
    for _, sibling in ipairs(node.parent.nodes) do
        if type(sibling) == "table" and (not same_type or sibling.name == node.name) then
            total = total + 1; if sibling == node then position = total end
        end
    end
    return position, total
end

local function elementSiblingIndex(node)
    local pos, total = siblingPosition(node, false)
    if not pos then return nil, nil end
    return pos - 1, total
end

local function nodeMatchesSimpleSelector(node, selector)
    if not isNode(node) then return false end
    selector = normalizeCssSelector(selector or "")
    if selector == "" or selector == "*" then return true end

    -- This matcher deliberately covers the simple selectors that frequently
    -- appear inside Legado's :not(...).  More complex selectors can still be
    -- delegated to the parent parser where possible.
    local tag = selector:match("^([%w_%-]+)")
    if tag and tostring(node.name or ""):lower() ~= tag:lower() then return false end
    local wanted_id = selector:match("#([%w_%-]+)")
    if wanted_id and nodeAttribute(node, "id") ~= wanted_id then return false end
    for class in selector:gmatch("%.([%w_%-]+)") do
        local classes = " " .. nodeAttribute(node, "class") .. " "
        if not classes:find(" " .. class .. " ", 1, true) then return false end
    end
    for attr in selector:gmatch("%[([%w_:%-]+)%]") do
        if nodeAttribute(node, attr) == "" then return false end
    end
    for attr, quote, value in selector:gmatch("%[([%w_:%-]+)%s*=%s*(['\"]?)(.-)%2%]") do
        if nodeAttribute(node, attr) ~= value then return false end
    end
    return true
end

local function hasDescendant(node, selector)
    selector = normalizeCssSelector(selector or "")
    if selector == "" then return false end
    if not isNode(node) or type(node.select) ~= "function" then return false end
    if selector:sub(1, 1) == ">" then
        local wanted = normalizeCssSelector(selector:sub(2))
        local ok, matches = pcall(node.select, node, wanted)
        if not ok or type(matches) ~= "table" then return false end
        for _, match in ipairs(matches) do
            if match.parent == node then return true end
        end
        return false
    end
    local ok, matches = pcall(node.select, node, selector)
    return ok and type(matches) == "table" and #matches > 0
end

local function nthMatcher(expression)
    expression = Util.trim(tostring(expression or "")):lower():gsub("%s+", "")
    if expression == "" then return nil end
    if expression == "n" then return function() return true end end
    if expression == "odd" then expression = "2n+1" end
    if expression == "even" then expression = "2n" end
    local direct = tonumber(expression)
    if direct then return function(position) return position == direct end end
    local a_text, b_text = expression:match("^([+-]?%d*)n([+-]?%d*)$")
    if not a_text then return nil end
    local a = (a_text == "" or a_text == "+") and 1 or (a_text == "-" and -1 or tonumber(a_text))
    local b = b_text == "" and 0 or tonumber(b_text)
    if not a or not b then return nil end
    return function(position)
        local delta = position - b
        if a == 0 then return delta == 0 end
        local n = delta / a
        return n >= 0 and n % 1 == 0
    end
end

local function selectNodes(context, selector)
    if selector == "" or selector == "." then return { context } end
    if not isNode(context) or not context.select then return {} end
    local combined = {}
    -- Do not split commas inside :has(...) / :not(...).
    for _, raw_selector in ipairs(splitTopLevel(selector, ",")) do
        local css = normalizeCssSelector(raw_selector)
        local has_clauses, not_clauses = {}, {}
        css = css:gsub(":has%(([^()]*)%)", function(inner)
            has_clauses[#has_clauses + 1] = Util.trim(inner)
            return ""
        end)
        css = css:gsub(":not%(([^()]*)%)", function(inner)
            not_clauses[#not_clauses + 1] = Util.trim(inner)
            return ""
        end)
        local eq = tonumber(css:match(":eq%((-?%d+)%)"))
        local lt = tonumber(css:match(":lt%((-?%d+)%)"))
        local gt = tonumber(css:match(":gt%((-?%d+)%)"))
        local nth_child_expr = css:match(":nth%-child%(([^()]*)%)")
        local nth_type_expr = css:match(":nth%-of%-type%(([^()]*)%)")
        local nth_child = nthMatcher(nth_child_expr)
        local nth_type = nthMatcher(nth_type_expr)
        local contains = css:match(":contains%([\"']?(.-)[\"']?%)")
        local first_child = css:find(":first%-child") ~= nil
        local last_child = css:find(":last%-child") ~= nil
        css = css:gsub(":eq%(-?%d+%)", ""):gsub(":lt%(-?%d+%)", ""):gsub(":gt%(-?%d+%)", "")
        css = css:gsub(":nth%-child%([^()]*%)", ""):gsub(":nth%-of%-type%([^()]*%)", "")
        css = css:gsub(":contains%(.-%)", ""):gsub(":first%-child", ""):gsub(":last%-child", "")
        css = normalizeCssSelector(css)
        local ok, nodes = pcall(context.select, context, css)
        if ok and type(nodes) == "table" then
            -- Jsoup's Element.select() evaluates the root element as well as
            -- its descendants.  lua-htmlparser's node:select() only walks
            -- descendants, which breaks common Legado chains where the list
            -- node is already the requested element, e.g. an <a> chapter
            -- followed by `tag.a@href`.  Include the root for bounded simple
            -- selectors and de-duplicate it when a backend already follows
            -- Jsoup semantics.  Complex combinators remain delegated to the
            -- parser because matching their root relationship locally would
            -- be ambiguous.
            local root_match_safe = css ~= "" and not css:find("[%s>+~,:]")
            if root_match_safe and nodeMatchesSimpleSelector(context, css) then
                local contains_root = false
                for _, node in ipairs(nodes) do
                    if node == context then contains_root = true break end
                end
                if not contains_root then table.insert(nodes, 1, context) end
            end
            local filtered = {}
            for _, node in ipairs(nodes) do
                local keep = not contains or nodeText(node):find(contains, 1, true) ~= nil
                if keep and #has_clauses > 0 then
                    for _, has_selector in ipairs(has_clauses) do
                        if not hasDescendant(node, has_selector) then keep = false break end
                    end
                end
                if keep and #not_clauses > 0 then
                    for _, not_selector in ipairs(not_clauses) do
                        if not_selector == ":first-child" then
                            local index = elementSiblingIndex(node)
                            if index == 0 then keep = false break end
                        elseif nodeMatchesSimpleSelector(node, not_selector) then
                            keep = false break
                        end
                    end
                end
                if keep and (eq ~= nil or lt ~= nil or gt ~= nil or nth_child or first_child or last_child) then
                    local index, total = elementSiblingIndex(node)
                    if index == nil then keep = false else
                        local eq_target = eq
                        if eq_target and eq_target < 0 then eq_target = total + eq_target end
                        local lt_target = lt
                        if lt_target and lt_target < 0 then lt_target = total + lt_target end
                        local gt_target = gt
                        if gt_target and gt_target < 0 then gt_target = total + gt_target end
                        if eq_target ~= nil and index ~= eq_target then keep = false end
                        if lt_target ~= nil and index >= lt_target then keep = false end
                        if gt_target ~= nil and index <= gt_target then keep = false end
                        if nth_child and not nth_child(index + 1, total) then keep = false end
                        if first_child and index ~= 0 then keep = false end
                        if last_child and index ~= total - 1 then keep = false end
                    end
                end
                if keep and nth_type then
                    local pos, total = siblingPosition(node, true)
                    if not pos or not nth_type(pos, total) then keep = false end
                end
                if keep then filtered[#filtered + 1] = node end
            end
            for _, node in ipairs(filtered) do combined[#combined + 1] = node end
        end
    end
    return combined
end

local function xpathToSelector(rule)
    local rule_lower = tostring(rule or ""):lower()
    if rule_lower:sub(1, 7) == "@xpath:" then rule = rule:sub(8) elseif rule_lower:sub(1, 6) == "xpath:" then rule = rule:sub(7) end
    local any_attribute = tostring(rule or ""):match("^//%s*@([%w_:%-]+)%s*$")
    if any_attribute then return "*", any_attribute end
    if rule:find("|", 1, true) or rule:find("::", 1, true) then return nil end
    local terminal = "text"
    rule = rule:gsub("/text%(%)[%s]*$", function() terminal = "text"; return "" end)
    rule = rule:gsub("/@([%w_:%-]+)[%s]*$", function(attr) terminal = attr; return "" end)
    local descendant = rule:sub(1, 2) == "//"
    rule = rule:gsub("^/+", "")
    local segments, current, bracket, quote = {}, {}, 0, nil
    for i = 1, #rule do
        local char = rule:sub(i, i)
        if quote then current[#current + 1] = char; if char == quote then quote = nil end
        elseif char == "'" or char == '"' then quote = char; current[#current + 1] = char
        elseif char == "[" then bracket = bracket + 1; current[#current + 1] = char
        elseif char == "]" then bracket = bracket - 1; current[#current + 1] = char
        elseif char == "/" and bracket == 0 then segments[#segments + 1] = table.concat(current); current = {}
        else current[#current + 1] = char end
    end
    segments[#segments + 1] = table.concat(current)
    local css = {}
    for _, segment in ipairs(segments) do
        segment = Util.trim(segment)
        if segment ~= "" then
            local tag = segment:match("^([%w_%-*]+)") or "*"
            local selector = tag
            for attr, value in segment:gmatch("%[@([%w_:%-]+)%s*=%s*['\"](.-)['\"]%]") do
                if attr == "id" then selector = selector .. "#" .. value
                elseif attr == "class" then for class in value:gmatch("%S+") do selector = selector .. "." .. class end
                else selector = selector .. "[" .. attr .. "=\"" .. value .. "\"]" end
            end
            for class in segment:gmatch("contains%s*%(%s*@class%s*,%s*['\"](.-)['\"]%s*%)") do selector = selector .. "." .. class end
            -- Common Legado pagination XPath uses text predicates such as
            -- `//a[contains(text(),'下一页')]/@href`.  Preserve that predicate
            -- through the CSS translation instead of silently selecting every
            -- anchor on the page.
            local text_contains = segment:match("contains%s*%(%s*text%s*%(%s*%)%s*,%s*['\"](.-)['\"]%s*%)")
                or segment:match("contains%s*%(%s*%.%s*,%s*['\"](.-)['\"]%s*%)")
            if text_contains and text_contains ~= "" then selector = selector .. ":contains(" .. text_contains .. ")" end
            local index = tonumber(segment:match("%[(%d+)%]"))
            if index then selector = selector .. ":nth-of-type(" .. index .. ")" end
            if segment:find("%[last%(%)]") then selector = selector .. ":last-child" end
            css[#css + 1] = selector
        end
    end
    if #css == 0 then return nil end
    return table.concat(css, descendant and " " or " > "), terminal
end

local function parseSelector(rule)
    rule = Util.trim(rule)
    local lower = rule:lower()
    if lower:sub(1, 5) == "@css:" then rule = rule:sub(6) elseif lower:sub(1, 4) == "css:" then rule = rule:sub(5) end
    if rule == "" or rule == "." then return "", "text" end
    if rule:sub(1, 1) == "@" then return "", rule:sub(2) end
    local selector, attribute = rule:match("^(.-)@([%w_:%-]+)$")
    return selector and normalizeCssSelector(selector) or normalizeCssSelector(rule), attribute or "text"
end

local function directChildren(node)
    local output = {}
    for _, child in ipairs(type(node) == "table" and (node.nodes or node.children) or {}) do
        if isNode(child) then output[#output + 1] = child end
    end
    return output
end

local function selectLegacy(context, rule)
    rule = Util.trim(rule or "")
    local reverse_list = rule:sub(1, 1) == "-"
    if reverse_list then rule = Util.trim(rule:sub(2)) end

    local current, terminal = { context }, "text"
    local segments = Util.splitPlain(rule, "@")
    for index, segment in ipairs(segments) do
        segment = Util.trim(segment)
        if segment ~= "" then
            local lower = segment:lower()
            if index == #segments and isTerminalAttribute(lower) then terminal = lower
            else
                local selector, item_index, text_match, exclusions = legacySelector(segment)
                local next_nodes = {}
                for _, node in ipairs(current) do
                    local selected_nodes = selector == "__children__" and directChildren(node) or selectNodes(node, selector)
                    if text_match then
                        local exact = {}
                        for _, selected in ipairs(selected_nodes) do
                            if Util.trim(nodeText(selected)) == text_match then exact[#exact + 1] = selected end
                        end
                        if #exact == 0 then
                            for _, selected in ipairs(selected_nodes) do
                                if nodeText(selected):find(text_match, 1, true) then exact[#exact + 1] = selected end
                            end
                        end
                        selected_nodes = exact
                    end
                    selected_nodes = filterExcluded(selected_nodes, exclusions)
                    for _, selected in ipairs(filterIndex(selected_nodes, item_index)) do next_nodes[#next_nodes + 1] = selected end
                end
                current = next_nodes
            end
        end
    end
    if reverse_list then
        local reversed = {}
        for index = #current, 1, -1 do reversed[#reversed + 1] = current[index] end
        current = reversed
    end
    return current, terminal
end

local function valueFromNode(node, attribute)
    attribute = (attribute or "text"):lower()
    if attribute == "text" then return nodeText(node)
    elseif attribute == "textnodes" or attribute == "owntext" then return directText(node)
    elseif attribute == "html" or attribute == "innerhtml" then return nodeOuterHtml(node)
    -- `@content` is the ordinary HTML `content` attribute (most commonly on
    -- OpenGraph/meta nodes).  Legado uses `@html` for inner HTML.  Treating
    -- content as innerHTML erased book names, covers and IDs from meta-based
    -- sources because <meta> has no child HTML.
    elseif attribute == "content" or attribute == "content_attr" then return nodeAttribute(node, "content")
    else return nodeAttribute(node, attribute) end
end

local function splitPostScript(rule)
    rule = tostring(rule or "")
    local trimmed = Util.trim(rule)
    if trimmed:lower():match("^@js:") then return "", trimmed, "" end
    local lower_rule = rule:lower()
    local open_pos = lower_rule:find("<js>", 1, true)
    if open_pos then
        local close_pos = lower_rule:find("</js>", open_pos + 4, true)
        if close_pos then
            local before = rule:sub(1, open_pos - 1):gsub("%s+$", "")
            local script = rule:sub(open_pos, close_pos + 4)
            local after = rule:sub(close_pos + 5):gsub("^%s+", "")
            return before, script, after
        elseif open_pos == 1 then return "", rule, "" end
    end
    -- The compact form `@onclick@js:...` is common in mobile source packs.
    -- It is the same selector-plus-script pipeline as the newline form below;
    -- treating the whole string as a legacy selector silently returns no node.
    local inline_js = lower_rule:find("@js:", 1, true)
    if inline_js and inline_js > 1 then
        return rule:sub(1, inline_js - 1):gsub("%s+$", ""), rule:sub(inline_js), ""
    end
    local a = lower_rule:find("\n@js:", 1, true)
    if a then return rule:sub(1, a - 1), rule:sub(a + 1), "" end
    return rule, nil, ""
end

local function flattenResult(value)
    if value == nil then return {} end
    if type(value) ~= "table" or isNode(value) then return { value } end
    -- JavaScript arrays and JSON arrays are list values; ordinary objects are
    -- one pipeline value.  Expanding every Lua table here used to turn a
    -- search candidate into its fields.  The next URL rule then received the
    -- whole response/object (or several unrelated scalar fields), producing
    -- malformed requests such as QQ's 414 Request-URI Too Large.
    if isArrayLike(value) then
        return tableValues(value)
    end
    if next(value) == nil then return {} end
    return { value }
end

local function scriptInput(values, force_list)
    if type(values) ~= "table" or #values == 0 then return nil end
    return (not force_list and #values == 1) and values[1] or values
end

local function htmlParserNeedsDangerPlaceholderMode(body)
    -- lua-htmlparser normally protects `<` / `>` inside quoted attributes by
    -- replacing them with two byte values that do not occur in the document.
    -- Byte-dense pages (compressed-looking inline data, legacy encodings, or
    -- large script blobs) can legitimately use every candidate byte. Upstream
    -- then logs "Impossible to find at least two unused byte codes" and the
    -- resulting DOM may be incomplete without throwing a Lua error. Reproduce
    -- the upstream candidate scan here so we enable its documented fallback
    -- only for documents that actually need it.
    body = tostring(body or "")
    local unused = 0
    for byte = 0, 31 do
        if not body:find(string.char(byte), 1, true) then
            unused = unused + 1
            if unused >= 2 then return false end
        end
    end
    for byte = 128, 254 do
        if not body:find(string.char(byte), 1, true) then
            unused = unused + 1
            if unused >= 2 then return false end
        end
    end
    return true
end

local function parseHtmlSafely(body)
    body = tostring(body or "")
    if not htmlParserNeedsDangerPlaceholderMode(body) then
        return pcall(htmlparser.parse, body, 20000)
    end

    -- `htmlparser_opts.keep_danger_placeholders` is the parser's documented
    -- escape hatch for exactly this case. The option is process-global, so
    -- install it only around this parse and restore the caller's table even if
    -- parsing throws. This keeps ordinary documents on the safer default path.
    local previous = rawget(_G, "htmlparser_opts")
    local temporary = {}
    if type(previous) == "table" then
        for key, value in pairs(previous) do temporary[key] = value end
    end
    temporary.keep_danger_placeholders = true
    rawset(_G, "htmlparser_opts", temporary)
    local ok, root = pcall(htmlparser.parse, body, 20000)
    rawset(_G, "htmlparser_opts", previous)
    return ok, root
end

function RuleEngine:parseDocument(body, content_type)
    local decoded = parseJsonIfNeeded(body)
    if decoded then return decoded, "json" end
    local ok, root = parseHtmlSafely(body)
    if not ok then return body or "", "text" end
    return root, "html"
end

function RuleEngine:_jsEnv(context, base_url, env, result)
    local out = {}
    for key, value in pairs(env or {}) do out[key] = value end
    -- Legado's `@js:` receives the raw response body when the rule has no
    -- preceding static selector.  Passing the parsed document/table here
    -- turns JSON.parse(result) into JSON.parse("[object Object]") and makes
    -- otherwise valid API rules look like empty parser results.  Keep an
    -- explicit selector result when one exists, while retaining the raw
    -- response as the default input for pure scripts.
    local raw_result = out.__raw_response_body
    local js_result = result ~= nil and result or (raw_result ~= nil and raw_result or context)
    out.context, out.result, out.src = context, js_result, raw_result ~= nil and tostring(raw_result) or nodeHtml(context)
    out.baseUrl, out.base_url = base_url or out.baseUrl or "", base_url or out.base_url or ""
    out.variables = out.variables or {}
    out.getString = function(rule) return self:extract(context, rule, base_url, "", out) end
    out.getStringList = function(rule) return self:extractAll(context, rule, base_url, out) end
    out.getElements = function(rule) return self:select(context, rule, out) end
    out.setContent = function(value)
        -- Legado scripts commonly iterate java.getElements(...), then pass
        -- each Jsoup Element straight back to java.setContent(element).
        -- Preserve an already parsed DOM node as the new context.  tostring()
        -- on a Lua htmlparser node produces `table: 0x...`; reparsing that
        -- string silently empties every nested selector in the script.
        if isNode(value) then
            context, out.context, out.result = value, value, value
            out.src = nodeHtml(value)
            out.__raw_response_body = out.src
            return value
        end
        local raw = tostring(value or "")
        local parsed = self:parseDocument(raw)
        context, out.context, out.result, out.src = parsed, parsed, parsed, raw
        out.__raw_response_body = raw
        return value
    end
    if out.__js_lib and out.__js_lib ~= "" and type(QuickJS.installLibrary) == "function" then
        local target = type(out.source) == "table" and rawget(out.source, "__target") or nil
        local session = type(target) == "table" and rawget(target, "__quickjs_session") or nil
        if not session or session.closed then
            local trace_source = type(out.source) == "table" and rawget(out.source, "__target") or nil
            if type(trace_source) == "table" then
                local trace = ExecutionTrace:get(trace_source)
                if trace then
                    local library_field = trace.stage == "content" and "content.content" or (trace.stage or "unknown")
                    local library_base = trace.stage == "content" and trace_source._js_library_base_url_override
                        or base_url
                    ExecutionTrace:setRule(trace_source, out, library_field, out.__js_lib, library_base)
                end
            end
            QuickJS:installLibrary(out.__js_lib, out)
        end
    end
    return out
end

function RuleEngine:_expandTemplates(text, context, base_url, env, rule_result)
    text = tostring(text or "")
    -- Community rules frequently append a path segment to `{{baseUrl}}`.  If
    -- the current response URL already ends in '/', naive string expansion
    -- creates `//` at the join boundary and strict servers reject it.  Legado
    -- rules use this as URL composition, so normalize only this explicit
    -- template boundary; do not globally collapse double slashes in arbitrary
    -- HTTP paths where they may be intentional.
    text = text:gsub("{{%s*baseUrl%s*}}/+", function()
        local current = tostring((env and (env.baseUrl or env.base_url)) or base_url or "")
        return current:gsub("/+$", "") .. "/"
    end)
    local depth = 0
    while text:find("{{", 1, true) and depth < 8 do
        local changed = false
        text = text:gsub("{{([%s%S]-)}}", function(inner)
            changed = true
            local raw_inner = inner
            inner = Util.trim(inner)
            if inner:sub(1, 2) == "@@" then
                local nested_rule = raw_inner:gsub("^%s*@@", "")
                return self:extract(context, nested_rule, base_url, "", env)
            end
            local lower = inner:lower()
            if inner:sub(1, 1) == "$" or inner:match("^//")
                or lower:match("^@?css:") or lower:match("^@?json:") or lower:match("^@?xpath:")
                or lower:match("^class%.") or lower:match("^id%.") or lower:match("^tag%.") then
                return self:extract(context, inner, base_url, "", env)
            end
            -- In a selector -> JS -> URL pipeline, `result` means the value
            -- produced by the previous step. The environment also carries
            -- __raw_response_body for pure @js rules; allowing that fallback
            -- here would substitute the whole search JSON into {{result}}.
            local value = QuickJS:eval(inner, self:_jsEnv(context, base_url, env, rule_result))
            return value ~= nil and tostring(value) or ""
        end)
        if not changed then break end
        depth = depth + 1
    end
    -- @get:{key} is an inline variable substitution as well as a standalone
    -- rule.  Community sources commonly pair it with a leading @put block:
    -- `@put:{id:$.id}\nhttps://host/book/@get:{id}.html`.
    text = text:gsub("@get:%s*{([^{}\r\n]+)}", function(key)
        key = Util.trim(key)
        local value = env and env.variables and env.variables[key]
        return value ~= nil and tostring(value) or ""
    end)

    -- Older imported Legado sources also use a compact single-brace
    -- JSONPath placeholder in URL fields, e.g. `.../b/{$.wapBookId}.html`.
    -- Restrict this to `$`-prefixed paths so normal JavaScript/object braces
    -- are never mistaken for templates.
    -- Do not consume the `{...}` portion of a JavaScript template
    -- interpolation (`${$.id}`).  It is evaluated by QuickJS inside the
    -- script; treating it as a Legado compact placeholder turns it into `$`
    -- and corrupts request bodies such as `chapterIdList:"$,"`.
    text = text:gsub("(%$?)({[^\r\n{}]-})", function(dollar, braces)
        if dollar == "$" then return dollar .. braces end
        local inner = braces:sub(2, -2)
        local compact = Util.trim(inner)
        if compact:sub(1, 1) == "$" and compact:sub(2, 2) ~= "$"
                and (compact:sub(2, 2) == "." or compact:sub(2, 2) == "[")
                and not compact:find("%s") then
            return self:extract(context, compact, base_url, "", env)
        end
        return braces
    end)
    return text
end

-- Every selector/JS/URL rule uses the same hand-off.  Keeping this in the
-- existing rule engine prevents one phase from accidentally passing the raw
-- response while another phase passes the selected value.  `rule_result` is
-- reserved for the value produced by the preceding pipeline step (the value
-- visible to {{result}}); it is deliberately separate from the response body.
function RuleEngine:_evaluateRuleScript(script, context, base_url, env, values, rule_result, force_list)
    script = self:_expandTemplates(script, context, base_url, env, rule_result)
    local js_env = self:_jsEnv(context, base_url, env, scriptInput(values, force_list))
    local source_proxy = env and rawget(env, "source")
    local source = type(source_proxy) == "table" and rawget(source_proxy, "__target") or nil
    if source then
        rawset(js_env, "__diagnostic_js_base_url_type", type(base_url))
        rawset(js_env, "__diagnostic_js_base_url_http", type(base_url) == "string" and base_url:match("^https?://") ~= nil)
        rawset(js_env, "__diagnostic_env_base_url_present", js_env.baseUrl ~= nil and tostring(js_env.baseUrl) ~= "")
        ExecutionTrace:setRule(source, js_env,
            rawget(env, "__diagnostic_rule_field") or "rule-script", script, base_url)
    end
    local result, err = QuickJS:eval(script, js_env)
    if err and env then env.last_js_error = err end
    return result, err
end

function RuleEngine:_selectStatic(context, rule)
    rule = Util.trim(rule or "")
    if rule == "" then return { context }, "text" end
    -- A leading `@attr` is Legado's direct-attribute accessor and accepts
    -- arbitrary HTML attributes (onclick, data-*, aria-*, ...), not only the
    -- small set of common href/src/text terminals.  Sending unknown attrs
    -- through the legacy selector chain makes `@onclick@js:...` select a
    -- fictitious <onclick> child and silently empties valid results.
    local direct_attr = rule:match("^@([%w_:%-]+)$")
    if direct_attr then return { context }, direct_attr end
    local lower = rule:lower()
    if lower:match("^@?json:") or rule:match("^%$") then return flattenJsonSelection(jsonPathValues(parseJsonIfNeeded(context) or context, rule)), nil end
    -- Legado treats bare dotted paths as JSONPath when the current context is
    -- JSON. Without this, common rules such as data.books or AuthorInfo.Author
    -- were incorrectly sent to the CSS selector engine and returned nothing.
    if type(context) == "table" and not isNode(context) then
        if context[rule] ~= nil then return directJsonValue(context[rule]), nil end
        return flattenJsonSelection(jsonPathValues(context, rule)), nil
    end
    local lower_rule = lower
    if (lower_rule == "text" or lower_rule == "html" or lower_rule == "innerhtml")
            and (isNode(context) or type(context) == "string") then
        return { context }, lower_rule
    end
    if lower:match("^@?xpath:") or rule:match("^//") then
        local selector, terminal = xpathToSelector(rule)
        return selector and selectNodes(context, selector) or {}, terminal
    end
    local legacy_probe = rule:sub(1, 1) == "-" and Util.trim(rule:sub(2)) or rule
    local starts_legacy = legacy_probe:match("^class%.") or legacy_probe:match("^id%.") or legacy_probe:match("^tag%.") or legacy_probe:match("^text%.")
        or legacy_probe:lower():match("^children@?") or legacy_probe:lower():match("^child@?")
    local at_count = select(2, rule:gsub("@", ""))
    local tail_segment = at_count > 0 and Util.trim(rule:match("@([^@]+)$") or "") or ""
    local single_at_chain = at_count == 1 and tail_segment ~= ""
        and not isTerminalAttribute(tail_segment)
    local indexed_segment = rule:match("[^@]+%.%-?%d+@") or rule:match("[^@]+%.%-?%d+$")
        or rule:match("[^@]+%.%-?%d+:%-?%d+")
        or rule:match("[^@]+%[%-?%d+%]@") or rule:match("[^@]+%[%-?%d+%]$")
        or rule:match("[^@]+%[[%d%-,]+%]")
    if not lower:match("^@?css:") and (starts_legacy or at_count >= 2 or single_at_chain or indexed_segment
            or rule:find("!", 1, true)
            or rule:find("@tag%.") or rule:find("@class%.") or rule:find("@id%.") or rule:find("@text%.")
            or isTerminalAttribute(rule:lower())) then
        return selectLegacy(context, rule)
    end
    local selector, terminal = parseSelector(rule)
    return selectNodes(context, selector), terminal
end

function RuleEngine:_applyPut(context, spec, base_url, env)
    if not env then return context end
    env.variables = env.variables or {}
    for _, assignment in ipairs(parsePutMap(spec)) do
        local value = self:extract(context, assignment.rule, base_url, "", env)
        -- AnalyzeUrl.put writes to the current rule data object (chapter
        -- first, then book, then source) and is observable as java.put.  The
        -- old implementation only changed the transient environment table,
        -- so @put values disappeared from the returned Book and the host
        -- trace missed the bridge call.
        local target_proxy = rawget(env, "chapter") or rawget(env, "book") or rawget(env, "source")
        local put_variable = type(target_proxy) == "table" and rawget(target_proxy, "putVariable") or nil
        if type(put_variable) == "function" then
            put_variable(target_proxy, assignment.key, value)
        else
            env.variables[assignment.key] = value
        end
        local source_proxy = rawget(env, "source")
        local source = type(source_proxy) == "table" and rawget(source_proxy, "__target") or nil
        if source then
            ExecutionTrace:markHost(env, "java.put", true, nil, { assignment.key, value }, value)
            ExecutionTrace:sideEffect(source, "ruleData", "put", assignment.key)
        end
    end
    return context
end

local function splitPutSuffix(rule)
    local before, object = tostring(rule or ""):match("^(.-)@put:%s*(%b{})%s*$")
    return before, object
end

-- Legado permits @put:{...} as a state-producing prefix followed by another
-- rule on the next line.  It is not merely a terminal/suffix operator.  Real
-- sources use this to capture an id from the current JSON/DOM node and then
-- build the navigation URL from @get:{id}.  Treating the whole string as one
-- selector silently empties otherwise valid search results.
local function splitPutPrefix(rule)
    local object, rest = tostring(rule or ""):match("^@put:%s*(%b{})([%s%S]*)$")
    if not object then return nil, nil end
    return object, Util.trim(rest or "")
end

local function interleaveLists(lists)
    local output, max_length = {}, 0
    for _, values in ipairs(lists) do if #values > max_length then max_length = #values end end
    for index = 1, max_length do
        for _, values in ipairs(lists) do
            if values[index] ~= nil then output[#output + 1] = values[index] end
        end
    end
    return output
end

function RuleEngine:select(context, rule, env)
    if rule == nil then return {} end
    if type(rule) == "table" then
        local output = {}; for _, item in ipairs(rule) do for _, value in ipairs(self:select(context, item, env)) do output[#output + 1] = value end end; return output
    end
    rule = Util.trim(rule)
    if rule == "" then return {} end
    -- Legado list rules (search/explore/TOC) may start with `+` to mark an
    -- AllInOne rule.  The marker is metadata for list evaluation, not part of
    -- the CSS/Default/JS expression itself.  Leaving it attached turns valid
    -- selectors such as `+.item` into an invalid selector and also contaminates
    -- `<js>` preambles.  `select()` is the list-rule entry point, so consume the
    -- marker here only; scalar field extraction keeps ordinary leading `+`
    -- untouched.
    if rule:sub(1, 1) == "+" then
        rule = Util.trim(rule:sub(2))
        if rule == "" then return { context } end
    end
    local standalone_put = rule:match("^@put:%s*(%b{})%s*$")
    if standalone_put then
        self:_applyPut(context, standalone_put, env and env.base_url, env)
        return { context }
    end
    local get_key = rule:match("^@get:%s*{?(.-)}?%s*$")
    if get_key then
        local value = env and env.variables and env.variables[get_key]
        return value ~= nil and { value } or {}
    end
    local global_static, global_script, global_after = splitPostScript(rule)
    if global_script then
        local values = global_static ~= "" and self:select(context, global_static, env) or {}
        local result, err = self:_evaluateRuleScript(
            global_script, context, env and env.base_url, env, values)
        if result ~= nil then values = flattenResult(result) end
        if global_after ~= "" then
            local piped = {}
            local inputs = #values > 0 and values or { context }
            for _, value in ipairs(inputs) do
                local pipeline_context = value
                if type(value) == "string" and Util.trim(value):sub(1, 1) == "<" then
                    pipeline_context = self:parseDocument(value)
                end
                for _, selected in ipairs(self:select(pipeline_context, global_after, env)) do piped[#piped + 1] = selected end
            end
            return piped
        end
        return values
    end
    local union = Util.splitPlain(rule, "%%")
    if #union > 1 then
        local lists = {}
        for _, part in ipairs(union) do lists[#lists + 1] = self:select(context, part, env) end
        return interleaveLists(lists)
    end
    for _, alternative in ipairs(Util.splitPlain(rule, "||")) do
        alternative = Util.trim(alternative)
        local put_prefix, put_rest = splitPutPrefix(alternative)
        if put_prefix then
            self:_applyPut(context, put_prefix, env and env.base_url, env)
            alternative = put_rest
            if alternative == "" then return { context } end
        end
        local static, script, after = splitPostScript(alternative)
        local values = {}
        if static ~= "" then values = self:_selectStatic(context, static) end
        if script then
            local result, err = self:_evaluateRuleScript(
                script, context, env and env.base_url, env, values, nil, true)
            if result ~= nil then values = flattenResult(result) end
            if after ~= "" then
                local piped = {}
                local inputs = #values > 0 and values or { context }
                for _, value in ipairs(inputs) do
                    for _, selected in ipairs(self:select(value, after, env)) do piped[#piped + 1] = selected end
                end
                values = piped
            end
        end
        if #values > 0 then return values end
    end
    return {}
end

function RuleEngine:extractAll(context, rule, base_url, env, rule_result)
    if rule == nil then return {} end
    if type(rule) == "table" then
        local output = {}; for _, item in ipairs(rule) do for _, value in ipairs(self:extractAll(context, item, base_url, env, rule_result)) do output[#output + 1] = value end end; return output
    end
    rule = Util.trim(rule)
    if rule == "" then return {} end

    local global_static, global_script, global_after = splitPostScript(rule)
    if global_script then
        -- The static half is the input to the JS half.  Keep href/src values
        -- relative until the complete selector -> JS -> URL pipeline has
        -- finished; resolving them here changes the value visible as
        -- `result` for common source rules that prepend their own host.
        local static_base_url = base_url
        local static_lower = tostring(global_static or ""):lower()
        if static_lower:match("@href%s*$") or static_lower:match("@src%s*$")
                or static_lower:match("@url%s*$") then
            static_base_url = nil
        end
        local pipelined = global_after ~= ""
            local values = global_static ~= ""
            and (pipelined and self:select(context, global_static, env) or self:extractAll(context, global_static, static_base_url, env)) or {}
        local result, err = self:_evaluateRuleScript(
            global_script, context, base_url, env, values, rule_result)
        if result ~= nil then values = flattenResult(result) end
        if pipelined then
            local extracted = {}
            local inputs = #values > 0 and values or { context }
            for _, value in ipairs(inputs) do
                local pipeline_context = value
                if type(value) == "string" and Util.trim(value):sub(1, 1) == "<" then
                    pipeline_context = self:parseDocument(value)
                end
                for _, item in ipairs(self:extractAll(pipeline_context, global_after, base_url, env, value)) do extracted[#extracted + 1] = item end
            end
            return extracted
        end
        local cleaned = {}
        for _, value in ipairs(values) do
            if isNode(value) then value = nodeText(value)
            elseif type(value) == "table" then local ok, encoded = pcall(rapidjson.encode, value); value = ok and encoded or "" end
            value = Util.trim(tostring(value or ""))
            if value ~= "" then cleaned[#cleaned + 1] = value end
        end
        return cleaned
    end

    local union = Util.splitPlain(rule, "%%")
    if #union > 1 then
        local lists = {}
        for _, part in ipairs(union) do lists[#lists + 1] = self:extractAll(context, part, base_url, env) end
        return interleaveLists(lists)
    end

    for _, alternative in ipairs(Util.splitPlain(rule, "||")) do
        alternative = Util.trim(alternative)
        local put_prefix, put_rest = splitPutPrefix(alternative)
        if put_prefix then
            self:_applyPut(context, put_prefix, base_url, env)
            alternative = put_rest
            if alternative == "" then
                local current = isNode(context) and nodeText(context) or context
                return flattenResult(current)
            end
        end
        local put_before, put_object = splitPutSuffix(alternative)
        if put_object then
            self:_applyPut(context, put_object, base_url, env)
            alternative = Util.trim(put_before or "")
            if alternative == "" then
                local current = isNode(context) and nodeText(context) or context
                return flattenResult(current)
            end
        end
        local static, script, after = splitPostScript(alternative)
        local original_template = static:find("{{", 1, true) ~= nil
            or static:find("@get:", 1, true) ~= nil
            or static:match("{%s*%$[%.%[][^%s{}]-}%s*") ~= nil
        if original_template then static = self:_expandTemplates(static, context, base_url, env, rule_result) end
        local base_rule, pattern, replacement = parseReplacement(static)
        local values = {}

        local get_key = base_rule:match("^@get:%s*{?(.-)}?%s*$")
        local put_object = base_rule:match("^@put:%s*(%b{})%s*$")
        if get_key then values = { env and env.variables and env.variables[get_key] or "" }
        elseif put_object then
            self:_applyPut(context, put_object, base_url, env)
            values = { context }
        elseif original_template then values = { base_rule }
        elseif base_rule == "" and pattern then values = { type(context) == "string" and context or nodeHtml(context) }
        elseif base_rule:lower():match("^@?json:") or base_rule:match("^%$") then
            for _, value in ipairs(flattenJsonSelection(jsonPathValues(parseJsonIfNeeded(context) or context, base_rule))) do
                values[#values + 1] = value
            end
        elseif base_rule:lower():match("^regex:") then
            local expression = base_rule:sub(7)
            local captures = Regex:captures(type(context) == "string" and context or nodeHtml(context), expression, "")
            if captures then for i = 1, 31 do if captures[i] ~= nil then values[#values + 1] = captures[i] end end end
        elseif type(context) == "table" and not isNode(context) then
            local direct = context[base_rule]
            if direct ~= nil then values = directJsonValue(direct)
            else
                local selected = self:_selectStatic(context, base_rule)
                values = selected
            end
        else
            local nodes, terminal = self:_selectStatic(context, base_rule)
            for _, node in ipairs(nodes) do values[#values + 1] = terminal and valueFromNode(node, terminal) or node end
        end

        if script then
            local js_result, err = self:_evaluateRuleScript(
                script, context, base_url, env, values, rule_result)
            if js_result ~= nil then values = flattenResult(js_result) end
            if after ~= "" then
                local piped = {}
                local inputs = #values > 0 and values or { context }
                for _, value in ipairs(inputs) do
                    local pipeline_context = value
                    if type(value) == "string" and Util.trim(value):sub(1, 1) == "<" then
                        pipeline_context = self:parseDocument(value)
                    end
                    for _, item in ipairs(self:extractAll(pipeline_context, after, base_url, env, value)) do piped[#piped + 1] = item end
                end
                values = piped
            end
        end

        local cleaned = {}
        for _, value in ipairs(values) do
            if type(value) == "table" and not isNode(value) then
                local ok, encoded = pcall(rapidjson.encode, value); value = ok and encoded or ""
            elseif isNode(value) then value = nodeText(value) end
            value = tostring(value or "")
            if pattern then value = Regex:replace(value, pattern, replacement, "g") end
            value = Util.trim(value)
            if value ~= "" then
                local lower_rule = base_rule:lower()
                local is_url = lower_rule == "href" or lower_rule == "src" or lower_rule == "url" or lower_rule:match("@href$") or lower_rule:match("@src$") or lower_rule:match("@url$")
                -- Legado applies a selector -> JS pipeline before the final
                -- URL normalization.  Resolving href/src here would feed an
                -- absolute URL into `@js`, changing rules that prepend their
                -- own host.  Plain URL rules keep the eager normalization;
                -- extractUrl() performs the deferred normalization below.
                if base_url and is_url and script == nil then value = Http:absolute(base_url, value) end
                cleaned[#cleaned + 1] = value
            end
        end
        if #cleaned > 0 then return cleaned end
    end
    return {}
end

function RuleEngine:extract(context, rule, base_url, joiner, env)
    local collected = {}
    for _, part in ipairs(Util.splitPlain(tostring(rule or ""), "&&")) do
        local values = self:extractAll(context, part, base_url, env)
        if #values > 0 then collected[#collected + 1] = table.concat(values, joiner or "\n") end
    end
    return table.concat(collected, joiner or "")
end

-- Legado resolves URL-valued Default rules with getString0(): each rule part
-- contributes at most its first selected value. Ordinary text extraction may
-- join multiple matched nodes, but concatenating several href/src values
-- creates an invalid request URL (e.g. book + author + latest-chapter links).
-- Keep `&&` composition intact because sources may intentionally construct a
-- URL from multiple rule parts; only collapse each selector to its first value.
function RuleEngine:extractUrl(context, rule, base_url, env)
    local collected = {}
    for _, part in ipairs(Util.splitPlain(tostring(rule or ""), "&&")) do
        local values = self:extractAll(context, part, base_url, env)
        if #values > 0 then
            local value = tostring(values[1] or "")
            if base_url and value ~= "" then value = Http:absolute(base_url, value) end
            collected[#collected + 1] = value
        end
    end
    return table.concat(collected, "")
end

function RuleEngine:applyReplaceRules(value, rules)
    if rules == nil or rules == "" then return value end
    if type(rules) ~= "table" then rules = { rules } end
    for _, rule in ipairs(rules) do
        local parts = Util.splitPlain(tostring(rule or ""), "##")
        local pattern, replacement
        if #parts >= 2 then
            pattern = parts[1] ~= "" and parts[1] or parts[2]
            replacement = parts[1] ~= "" and (parts[2] or "") or (parts[3] or "")
        else pattern, replacement = tostring(rule or ""), "" end
        value = Regex:replace(value, pattern, replacement, "g")
    end
    return value
end

function RuleEngine:cleanContent(value)
    value = tostring(value or "")
    if value:find("<", 1, true) and value:find(">", 1, true) then value = Util.stripHtml(value) else value = Util.htmlEntityDecode(value) end
    return Util.normalizeText(value)
end

-- BookContent applies Legado's HtmlFormatter.formatKeepImg after extracting
-- the content rule.  In particular, @html is an outer-HTML value and block
-- tags become newlines with ideographic indentation; trimming that value
-- loses observable paragraph layout.  Keep the formatter local to content so
-- ordinary title/author extraction retains its scalar normalization.
function RuleEngine:formatContent(value, base_url)
    value = tostring(value or "")
    local image_contract = {
        rendering = "unsupported-placeholder",
        -- The text-only reader cannot render HtmlFormatter keep-img output.
        -- Keep a stable ASCII placeholder so an HTML tag can never become
        -- visible reader text or vary with the source page encoding.
        placeholder = "[image]",
        base_url = diagnosticUrl(base_url or ""),
        count = 0,
        items = {},
    }
    value = value:gsub("&nbsp;", " ")
        :gsub("&ensp;", " ")
        :gsub("&emsp;", " ")
        :gsub("&thinsp;", "")
        :gsub("&zwnj;", "")
        :gsub("&zwj;", "")
        :gsub("\226\128\137", "")
        :gsub("\226\128\140", "")
        :gsub("\226\128\141", "")
    value = value:gsub("<!%-%-.-%-%->", "")
    -- HtmlFormatter treats these tags as line boundaries, including the
    -- opening and closing form.  The source parser has already selected the
    -- content node, so a conservative tag pattern is sufficient here.
    value = value:gsub("<%s*/?%s*[Dd][Ii][Vv][^>]*>", "\n")
        :gsub("<%s*/?%s*[Pp][^>]*>", "\n")
        :gsub("<%s*/?%s*[Bb][Rr][^>]*>", "\n")
        :gsub("<%s*/?%s*[Hh][Rr][^>]*>", "\n")
        :gsub("<%s*/?%s*[Hh][1-6][^>]*>", "\n")
        :gsub("<%s*/?%s*[Aa][Rr][Tt][Ii][Cc][Ll][Ee][^>]*>", "\n")
        :gsub("<%s*/?%s*[Dd][Dd][^>]*>", "\n")
        :gsub("<%s*/?%s*[Dd][Ll][^>]*>", "\n")
    value = value:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
        :gsub("<%s*[Ss][Tt][Yy][Ll][Ee][^>]*>.-</%s*[Ss][Tt][Yy][Ll][Ee]%s*>", "")
    value = value:gsub("<%s*[Ii][Mm][Gg]%f[%s/>]([^>]*)/?>", function(attributes)
        local function attribute(name)
            return attributes:match("[%s]" .. name .. "%s*=%s*['\"]([^'\"]+)['\"]")
                or attributes:match("[%s]" .. name .. "%s*=%s*([^%s>]+)")
        end
        local data_src = attribute("data%-src")
        local src = attribute("src")
        local raw_url = data_src or src or ""
        local plain_url = raw_url:gsub("%{.*$", ""):gsub(",%s*$", "")
        local resolved = plain_url ~= "" and Http:absolute(base_url or "", plain_url) or ""
        image_contract.count = image_contract.count + 1
        if #image_contract.items < 32 then
            image_contract.items[#image_contract.items + 1] = {
                source_attribute = data_src and "data-src" or (src and "src" or "missing"),
                source_sha256 = Digest:sha256(raw_url),
                resolved_url_sha256 = Digest:sha256(resolved),
                resolved_url = diagnosticUrl(resolved),
                has_legado_params = raw_url:find("{", 1, true) ~= nil,
            }
        end
        return "\n[image]\n"
    end)
    value = value:gsub("<[^>]+>", function(tag)
        return ""
    end)
    local indent = "\227\128\128\227\128\128"
    value = value:gsub("[ \t\r\f]*\n+[ \t\r\f]*", "\n" .. indent)
    value = value:gsub("^[\n\r \t\f]+", indent)
    value = value:gsub("[\n\r \t\f]+$", "")
    return Util.htmlEntityDecode(value), image_contract
end

function RuleEngine:toSource(value) return isNode(value) and nodeHtml(value) or tostring(value or "") end
function RuleEngine:toOuterSource(value) return isNode(value) and nodeOuterHtml(value) or tostring(value or "") end
function RuleEngine:isNode(value) return isNode(value) end
function RuleEngine:translateXPath(rule) return xpathToSelector(rule) end
function RuleEngine:jsonPathValues(context, rule) return jsonPathValues(context, rule) end
function RuleEngine:parsePutMap(spec) return parsePutMap(spec) end

return RuleEngine
