local BookOperationSpec = {}

local SPECS = {
    ["prepare"] = {
        kind = "prepare",
        title = "正在准备书籍",
        cancel_text = "取消",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在读取书籍详情与目录",
        handoff = "书籍数据已准备，正在接收结果",
        loading = "正在载入书籍信息",
        layout = "书籍信息已载入",
        error_title = "无法准备书籍",
    },
    ["prepare-reading"] = {
        kind = "reading",
        title = "正在准备阅读",
        cancel_text = "取消",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台搜书进程退出",
        running = "正在获取目录与当前章节",
        handoff = "目录与当前章节已准备，正在接收结果",
        loading = "正在载入章节目录",
        layout = "书籍数据已载入，正在排版首屏",
        error_title = "无法准备阅读",
    },
    ["prepare-chapter"] = {
        kind = "chapter",
        title = "正在打开章节",
        cancel_text = "取消章节",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在获取目标章节",
        handoff = "目标章节已准备，正在接收结果",
        loading = "正在载入章节信息",
        layout = "章节已载入，正在生成分页",
        error_title = "章节打开失败",
    },
    ["redownload-chapter"] = {
        kind = "chapter-redownload",
        title = "正在刷新本章",
        cancel_text = "取消重下",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待前台任务退出",
        running = "正在重新获取当前章节",
        handoff = "当前章节已重新获取，正在接收结果",
        loading = "正在载入新章节内容",
        layout = "正在重新排版当前页面",
        error_title = "刷新本章失败",
    },
    ["prepare-toc"] = {
        kind = "toc",
        title = "正在准备目录",
        cancel_text = "取消目录",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在获取章节目录",
        handoff = "目录已准备，正在接收结果",
        loading = "正在载入章节目录",
        layout = "目录数据已载入",
        error_title = "无法读取目录",
    },
    ["switch-source"] = {
        kind = "switch-source",
        title = "正在切换内容源",
        cancel_text = "取消换源",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在结束后台内容源搜索进程",
        running = "正在读取目标源目录与当前章节",
        handoff = "目标内容源与当前章节已准备，正在接收结果",
        loading = "正在载入更新后的书籍信息",
        layout = "正在应用内容源并重新排版当前页面",
        error_title = "书籍换源失败",
    },
    ["apply-cover"] = {
        kind = "cover",
        title = "正在应用封面",
        cancel_text = "取消应用",
        timeout_seconds = 24,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台搜索任务退出",
        running = "正在获取并验证封面",
        handoff = "封面已准备，正在接收结果",
        loading = "正在载入更新后的书籍信息",
        layout = "正在刷新书籍详情",
        error_title = "封面换源失败",
    },
    ["reload-cover"] = {
        kind = "cover",
        title = "正在获取封面",
        cancel_text = "取消封面",
        timeout_seconds = 24,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在请求并验证网络封面",
        handoff = "封面已准备，正在接收结果",
        loading = "正在载入更新后的书籍信息",
        layout = "正在刷新书籍详情",
        error_title = "抓取封面失败",
    },
    ["refresh-toc"] = {
        kind = "refresh",
        title = "正在刷新书籍",
        cancel_text = "取消刷新",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在获取最新目录",
        handoff = "最新目录已准备，正在接收结果",
        loading = "正在载入最新目录",
        layout = "目录数据已更新",
        error_title = "刷新失败",
    },
    ["export-book"] = {
        kind = "export",
        title = "正在导出书籍",
        cancel_text = "取消导出",
        timeout_seconds = 20 * 60,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在读取缓存章节并生成电子书",
        handoff = "电子书已生成，正在接收结果",
        loading = "正在确认导出文件",
        layout = "导出已完成",
        error_title = "导出失败",
    },
}

local function copyTable(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

function BookOperationSpec:get(operation, overrides)
    local spec = copyTable(SPECS[operation] or {
        kind = tostring(operation or "task"),
        title = "正在处理",
        cancel_text = "取消",
        timeout_seconds = 45,
        queue_timeout_seconds = 8,
        total = 4,
        queued = "正在等待后台任务退出",
        running = "正在处理",
        handoff = "后台任务已完成，正在接收结果",
        loading = "正在载入结果",
        layout = "正在应用结果",
        error_title = "操作失败",
    })
    for key, value in pairs(overrides or {}) do
        if value ~= nil then spec[key] = value end
    end
    return spec
end

function BookOperationSpec:stage(operation, state)
    local spec = self:get(operation)
    return spec[state]
end

return BookOperationSpec
