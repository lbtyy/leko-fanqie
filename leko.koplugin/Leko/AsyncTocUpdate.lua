local UIManager = require("ui/uimanager")

local AsyncBookOperation = require("Leko/AsyncBookOperation")
local Storage = require("Leko/Storage")

local AsyncTocUpdate = {
    interval_seconds = 30 * 60,
    retry_delay = 1.0,
    worker = nil,
    queue = {},
    current = nil,
    generation = 0,
    running = false,
    cancelled = false,
    on_state = nil,
    on_book = nil,
    on_done = nil,
}

local function nextTick(callback)
    if type(UIManager.nextTick) == "function" then return UIManager:nextTick(callback) end
    return UIManager:scheduleIn(0, callback)
end

local function schedule(delay, callback)
    if type(UIManager.scheduleIn) == "function" then return UIManager:scheduleIn(delay, callback) end
    return nextTick(callback)
end

local function bookKey(value)
    if type(value) == "table" then value = value.id end
    return tostring(value or "")
end

local function isRemote(summary)
    return type(summary) == "table" and tostring(summary.source_id or "") ~= ""
end

local function isDue(summary, now, force)
    if force then return true end
    local attempted = tonumber(summary.toc_check_attempted_at or summary.toc_checked_at or 0) or 0
    return attempted <= 0 or now - attempted >= AsyncTocUpdate.interval_seconds
end

local function addCallbacks(item, options)
    if not options then return end
    item.on_books = item.on_books or {}
    item.on_failures = item.on_failures or {}
    if type(options.on_book) == "function" then item.on_books[#item.on_books + 1] = options.on_book end
    if type(options.on_failure) == "function" then item.on_failures[#item.on_failures + 1] = options.on_failure end
end

function AsyncTocUpdate:_notify(state, text)
    if type(self.on_state) == "function" then
        local total = self.total or 0
        local shown = total - #self.queue - (self.current and 0 or 0)
        if self.current and shown < 1 then shown = 1 end
        pcall(self.on_state, state, text, math.max(0, shown), total, self.current)
    end
end

function AsyncTocUpdate:_finishItem(item, ok, err, book, payload)
    if item and ok then
        for _, callback in ipairs(item.on_books or {}) do
            pcall(callback, book, payload and payload.toc_change)
        end
    elseif item and not ok then
        for _, callback in ipairs(item.on_failures or {}) do pcall(callback, err) end
    end
    if ok and type(self.on_book) == "function" then
        pcall(self.on_book, book, payload and payload.toc_change)
    end
end

function AsyncTocUpdate:_releaseWorker(worker)
    if self.worker == worker then self.worker = nil end
    self.current = nil
end

function AsyncTocUpdate:_runNext(generation)
    if self.generation ~= generation or not self.running or self.worker then return end
    local item = table.remove(self.queue, 1)
    if not item then
        self.running = false
        self.current = nil
        self:_notify("done", "目录检查完成")
        if type(self.on_done) == "function" then pcall(self.on_done, self.cancelled) end
        return
    end
    self.current = item
    self:_notify("running", "检查中 " .. tostring((self.total or 0) - #self.queue) .. "/" .. tostring(self.total or 0))

    local worker_holder = {}
    local worker, start_err = AsyncBookOperation:start({
        operation = "refresh-toc",
        book_id = item.book_id,
        background = true,
        lane = "background",
        priority = 1,
        label = "background-toc-check",
        on_state = function(_, text, current, total)
            if self.generation == generation and self.running then
                self:_notify("running", text or ("检查中 " .. tostring(current or 0) .. "/" .. tostring(total or 0)))
            end
        end,
        on_cancel = function(reason)
            if self.generation ~= generation then return end
            self:_releaseWorker(worker_holder.worker)
            if self.cancelled or reason == "user" then
                self.running = false
                self.queue = {}
                self:_notify("cancelled", "已取消检查更新")
                if type(self.on_done) == "function" then pcall(self.on_done, true) end
                return
            end
            -- A foreground operation preempted this request. Put it back at
            -- the head and wait; ProcessBudget remains the arbiter.
            table.insert(self.queue, 1, item)
            self:_notify("paused", "前台任务优先，稍后继续检查")
            schedule(self.retry_delay, function() self:_runNext(generation) end)
        end,
    }, function(ok, err, completed, payload, book)
        if self.generation ~= generation then return end
        if self.worker ~= completed then return end
        self:_releaseWorker(completed)
        self:_finishItem(item, ok, err, book, payload)
        if ok then
            self:_notify("running", "检查中 " .. tostring((self.total or 0) - #self.queue) .. "/" .. tostring(self.total or 0))
        end
        schedule(0.05, function() self:_runNext(generation) end)
    end)
    if not worker then
        self:_releaseWorker(worker)
        self:_finishItem(item, false, start_err or "无法启动目录检查")
        schedule(0.05, function() self:_runNext(generation) end)
        return
    end
    worker_holder.worker = worker
    self.worker = worker
end

function AsyncTocUpdate:_makeQueue(options)
    local now = os.time()
    local force = options and options.force == true
    local requested = options and options.book_ids
    local requested_set
    if type(requested) == "table" then
        requested_set = {}
        for _, id in ipairs(requested) do requested_set[bookKey(id)] = true end
    end
    local queue, seen = {}, {}
    for _, summary in ipairs(Storage:listBooks() or {}) do
        local id = bookKey(summary)
        if id ~= "" and not seen[id] and isRemote(summary)
                and (not requested_set or requested_set[id])
                and isDue(summary, now, force) then
            seen[id] = true
            queue[#queue + 1] = { book_id = id }
        end
    end
    return queue
end

function AsyncTocUpdate:start(options)
    options = options or {}
    if self.running then
        -- A recreated bookshelf can attach its callbacks to the still-running
        -- single scan without starting a second worker.
        if type(options.on_state) == "function" then self.on_state = options.on_state end
        if type(options.on_book) == "function" then self.on_book = options.on_book end
        if type(options.on_done) == "function" then self.on_done = options.on_done end
        return self
    end
    self.generation = self.generation + 1
    self.cancelled = false
    self.queue = self:_makeQueue(options)
    self.total = #self.queue
    self.on_state = options.on_state
    self.on_book = options.on_book
    self.on_done = options.on_done
    self.running = true
    self:_notify("started", self.total == 0 and "没有需要检查的书籍" or "准备检查目录")
    local generation = self.generation
    nextTick(function() self:_runNext(generation) end)
    return self
end

function AsyncTocUpdate:checkBook(book, options)
    options = options or {}
    local id = bookKey(book)
    if id == "" or not isRemote(book) then return nil, "本地书籍不需要更新检查" end
    if self.running then
        if self.current and self.current.book_id == id then
            addCallbacks(self.current, options)
            return self
        end
        for _, item in ipairs(self.queue) do
            if item.book_id == id then
                addCallbacks(item, options)
                return self
            end
        end
        local summary = Storage:getBookSummary(id) or book
        if options.force == true or isDue(summary, os.time(), false) then
            local item = { book_id = id }
            addCallbacks(item, options)
            table.insert(self.queue, 1, item)
            self.total = (self.total or 0) + 1
        end
        return self
    end
    local summary = Storage:getBookSummary(id) or book
    if options.force ~= true and not isDue(summary, os.time(), false) then return nil, "目录检查未到期" end
    options.book_ids = { id }
    return self:start(options)
end

function AsyncTocUpdate:cancel()
    if not self.running then return false end
    self.cancelled = true
    self.generation = self.generation + 1
    local worker = self.worker
    self.queue = {}
    self.running = false
    self.current = nil
    if worker then AsyncBookOperation:cancel(worker, "user") end
    self.worker = nil
    self:_notify("cancelled", "已取消检查更新")
    if type(self.on_done) == "function" then pcall(self.on_done, true) end
    return true
end

function AsyncTocUpdate:isRunning() return self.running end

function AsyncTocUpdate:resetForTests()
    self:cancel()
    self.queue, self.current = {}, nil
    self.worker, self.on_state, self.on_book, self.on_done = nil, nil, nil, nil
    self.total, self.generation = 0, 0
end

return AsyncTocUpdate
