local AsyncSourceSearch = require("Leko/AsyncSourceSearch")
local SourceSearchController = {}
SourceSearchController.__index = SourceSearchController

function SourceSearchController:new(options)
    options = options or {}
    return setmetatable({
        options = options,
        session = nil,
        cancelled = false,
        generation = 0,
    }, self)
end

function SourceSearchController:start()
    if self.session then return self.session end
    self.cancelled = false
    self.generation = self.generation + 1
    local generation = self.generation
    local options = self.options
    local view = options.view
    local completed = false
    local session = AsyncSourceSearch:new{
        book = options.book,
        mode = options.mode,
        keyword = options.keyword,
        max_results = options.max_results,
        on_batch = function(batch)
            if self.cancelled or generation ~= self.generation then return end
            -- AsyncSourceSearch guarantees that executable candidate state was
            -- already spilled by the source child. Never materialize or re-encode
            -- that state in KOReader's UI process.
            if type(options.on_batch) == "function" then pcall(options.on_batch, batch)
            elseif view and view.appendResults then view:appendResults(batch) end
        end,
        on_progress = function(scanned, total, stage, search)
            if self.cancelled or generation ~= self.generation then return end
            if type(options.on_progress) == "function" then
                pcall(options.on_progress, scanned, total, stage, search)
            elseif view and view.setSearchProgress then
                view:setSearchProgress(scanned, total, stage, false, {
                    discovered_count = search and search.discovered_count,
                    overflow_count = search and search.overflow_count,
                })
            end
        end,
        on_done = function(errors, search)
            if self.cancelled or generation ~= self.generation then return end
            completed = true
            self.session = nil
            if type(options.on_done) == "function" then
                pcall(options.on_done, errors, search)
            elseif view and view.setSearchProgress then
                local total = search and search.total_sources or 0
                local finished = search and search.completed_sources or total
                local stage = search and search.last_stage or "后台搜索已完成"
                view:setSearchProgress(finished, total, stage, true, {
                    error_count = #(errors or {}),
                    discovered_count = search and search.discovered_count,
                    overflow_count = search and search.overflow_count,
                })
            end
        end,
    }
    self.session = session
    local started = session:start() or session
    if not completed and generation == self.generation and not self.cancelled then
        self.session = started
    end
    return started
end

function SourceSearchController:pause(reason)
    if self.session and not self.session.paused then self.session:pause(reason) end
end

function SourceSearchController:resume()
    if self.session and self.session.paused then self.session:resume() end
end

function SourceSearchController:applySourcePreference()
    if self.session and type(self.session.applySourcePreference) == "function" then
        return self.session:applySourcePreference()
    end
    return false
end

function SourceSearchController:cancel()
    self.cancelled = true
    self.generation = self.generation + 1
    if self.session then self.session:cancel(); self.session = nil end
end

function SourceSearchController:isPaused()
    return self.session and self.session.paused == true
end

function SourceSearchController:isActive()
    return self.cancelled ~= true and self.session ~= nil
end

return SourceSearchController
