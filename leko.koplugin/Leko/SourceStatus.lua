local SourceStatus = {}

function SourceStatus:capability(source)
    if type(source) ~= "table" then return "尚未分析" end
    if source.supported == false or source.searchable == false then return "包含暂不支持的功能" end
    local profile = tostring(source.capability_profile or source.compatibility_label or "基础规则")
    if profile == "标准规则" then return "基础规则" end
    if profile == "兼容运行时" then return "需要 JavaScript" end
    return profile
end

function SourceStatus:structural(source)
    if type(source) ~= "table" then return "尚未检测" end
    return (source.supported == false or source.searchable == false) and "暂不支持" or "可使用"
end

function SourceStatus:friendlyReason(reason)
    local text = tostring(reason or "")
    local lower = text:lower()
    if text:find("网页注入", 1, true) or lower:find("webview", 1, true)
            or text:find("浏览器", 1, true) or text:find("验证码", 1, true) then
        return "需要浏览器交互，Kindle 上暂时无法完成"
    end
    if text:find("登录", 1, true) then return "包含可选的登录功能" end
    if lower:find("rsa", 1, true) then return "需要当前版本尚未提供的加密功能" end
    if text:find("构造器", 1, true) or lower:find("java.", 1, true) then
        return "需要当前版本尚未提供的 JavaScript 功能"
    end
    if lower:find("promise", 1, true) or lower:find("async", 1, true) then
        return "需要异步 JavaScript，当前版本暂不支持"
    end
    if lower:find("jslib", 1, true) or lower:find("javascript", 1, true)
            or text:find("兼容桥", 1, true) or text:find("状态运行时", 1, true) then
        return "需要 JavaScript；Leko 会在实际使用时运行"
    end
    if lower:find("xpath", 1, true) then return "使用网页路径规则" end
    if text:find("GBK", 1, true) or text:find("GB18030", 1, true) then
        return text:find("缺少", 1, true) and "设备缺少旧网页编码支持" or "使用旧网页编码转换"
    end
    if text:find("分页规则", 1, true) then return "目录或正文包含多页" end
    if text:find("纯文本小说源", 1, true) then return "这不是文字小说书源" end
    return text ~= "" and text or "需要当前版本尚未提供的功能"
end

function SourceStatus:connectivity(record)
    if type(record) ~= "table" then return "尚未检测" end
    if record.transport_state == "http_rejected" then
        return "网站拒绝访问或要求验证"
    end
    if record.transport_state == "reachable"
            or (record.transport_state == nil and record.status == "online") then
        return "请求成功"
    end
    local error_text = tostring(record.error or "")
    local lower = error_text:lower()
    if lower:find("dns", 1, true) or lower:find("resolve", 1, true) or error_text:find("解析", 1, true) then
        return "找不到网站"
    end
    if lower:find("tls", 1, true) or lower:find("ssl", 1, true) or lower:find("handshake", 1, true) then
        return "安全连接失败"
    end
    if lower:find("timeout", 1, true) or error_text:find("超时", 1, true) then
        return "超时"
    end
    return "连接失败"
end

function SourceStatus:fullChain(result)
    local status = tostring(type(result) == "table" and result.status or "")
    if status == "FULL_PASS" or status == "READABLE_PASS" then return "完整可用" end
    if status == "INCONCLUSIVE" then return "没有找到可测试的书" end
    if status == "TIMEOUT" then return "超时" end
    if status == "REQUEST_ERROR" then return "请求失败" end
    if status == "ACCESS_REQUIRED" then return "网站要求登录或验证" end
    if status == "RUNTIME_OR_RULE" then return "书源解析失败" end
    if status == "PROCESS_ERROR" then return "后台任务失败" end
    return status ~= "" and status or "尚未检测"
end

return SourceStatus
