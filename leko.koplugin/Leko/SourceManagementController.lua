local AsyncSourceCatalog = require("Leko/AsyncSourceCatalog")
local AsyncSourceProbe = require("Leko/AsyncSourceProbe")
local AsyncSourceDiagnostic = require("Leko/AsyncSourceDiagnostic")

local SourceManagementController = {}
SourceManagementController.__index = SourceManagementController

function SourceManagementController:new(options)
    options = options or {}
    return setmetatable({
        options = options,
        catalog_ticket = nil,
        probe_session = nil,
        diagnostic_session = nil,
        catalog_generation = 0,
        probe_generation = 0,
        diagnostic_generation = 0,
        probe_completed = 0,
        probe_total = 0,
        probe_online = 0,
        probe_offline = 0,
        closed = false,
    }, self)
end

function SourceManagementController:isProbing()
    return self.probe_session ~= nil
end

function SourceManagementController:isDiagnosing()
    return self.diagnostic_session ~= nil
end

function SourceManagementController:diagnosticState()
    local session = self.diagnostic_session
    if session and type(session.state) == "function" then return session:state() end
    return { active = false, completed = 0, total = 0 }
end

function SourceManagementController:probeState()
    return {
        active = self:isProbing(),
        completed = tonumber(self.probe_completed or 0) or 0,
        total = tonumber(self.probe_total or 0) or 0,
        online = tonumber(self.probe_online or 0) or 0,
        offline = tonumber(self.probe_offline or 0) or 0,
    }
end

function SourceManagementController:ensureCatalog()
    if self.closed then return nil, "controller closed" end
    if self.catalog_ticket then return self.catalog_ticket end
    self.catalog_generation = self.catalog_generation + 1
    local generation = self.catalog_generation
    local pending = {}
    self.catalog_ticket = pending
    local ticket
    ticket = AsyncSourceCatalog:ensure(function(ok, err)
        if self.closed or generation ~= self.catalog_generation then return end
        if self.catalog_ticket ~= pending and self.catalog_ticket ~= ticket then return end
        self.catalog_ticket = nil
        if type(self.options.on_catalog_ready) == "function" then
            pcall(self.options.on_catalog_ready, ok, err)
        end
    end)
    if self.catalog_ticket == pending then self.catalog_ticket = ticket end
    return ticket
end

function SourceManagementController:cancelCatalog()
    self.catalog_generation = self.catalog_generation + 1
    local ticket = self.catalog_ticket
    self.catalog_ticket = nil
    if ticket then pcall(AsyncSourceCatalog.cancel, AsyncSourceCatalog, ticket) end
    return ticket ~= nil
end

function SourceManagementController:cancelProbe(reason)
    self.probe_generation = self.probe_generation + 1
    local probe = self.probe_session
    self.probe_session = nil
    if probe then pcall(probe.cancel, probe) end
    self.probe_completed, self.probe_total = 0, 0
    if type(self.options.on_probe_cancelled) == "function" then
        pcall(self.options.on_probe_cancelled, reason)
    end
    return probe ~= nil
end

function SourceManagementController:startProbe(source_ids)
    if self.closed then return nil, "controller closed" end
    if self.probe_session then self:cancelProbe("replaced") end
    self.probe_generation = self.probe_generation + 1
    local generation = self.probe_generation
    self.probe_completed, self.probe_total = 0, 0
    self.probe_online, self.probe_offline = 0, 0

    local session
    session = AsyncSourceProbe:new{
        source_ids = source_ids,
        only_enabled = source_ids == nil,
        only_executable = source_ids == nil,
        force = true,
        on_result = function(record, completed, total, probe)
            if self.closed or generation ~= self.probe_generation or self.probe_session ~= probe then return end
            self.probe_completed, self.probe_total = completed, total
            self.probe_online, self.probe_offline = probe.online, probe.offline
            if type(self.options.on_probe_result) == "function" then
                pcall(self.options.on_probe_result, record, completed, total, self:probeState())
            end
        end,
        on_progress = function(completed, total, stage, probe)
            if self.closed or generation ~= self.probe_generation or self.probe_session ~= probe then return end
            self.probe_completed, self.probe_total = completed, total
            if type(self.options.on_probe_progress) == "function" then
                pcall(self.options.on_probe_progress, completed, total, stage, self:probeState())
            end
        end,
        on_done = function(probe, event)
            if self.closed or generation ~= self.probe_generation or self.probe_session ~= probe then return end
            self.probe_session = nil
            self.probe_completed, self.probe_total = probe.completed, probe.total
            self.probe_online, self.probe_offline = probe.online, probe.offline
            if type(self.options.on_probe_done) == "function" then
                pcall(self.options.on_probe_done, event, self:probeState())
            end
        end,
    }
    self.probe_session = session
    session:start()
    return session
end


function SourceManagementController:cancelDiagnostic(reason)
    self.diagnostic_generation = self.diagnostic_generation + 1
    local session = self.diagnostic_session
    self.diagnostic_session = nil
    if session then pcall(session.cancel, session) end
    if type(self.options.on_diagnostic_cancelled) == "function" then
        pcall(self.options.on_diagnostic_cancelled, reason)
    end
    return session ~= nil
end

function SourceManagementController:startDiagnostic(keyword)
    if self.closed then return nil, "controller closed" end
    if self.diagnostic_session then self:cancelDiagnostic("replaced") end
    self.diagnostic_generation = self.diagnostic_generation + 1
    local generation = self.diagnostic_generation
    local session
    session = AsyncSourceDiagnostic:new{
        keyword = keyword or "我的",
        on_result = function(result, completed, total, diagnostic, state)
            if self.closed or generation ~= self.diagnostic_generation
                    or self.diagnostic_session ~= diagnostic then return end
            if type(self.options.on_diagnostic_result) == "function" then
                pcall(self.options.on_diagnostic_result, result, completed, total, state)
            end
        end,
        on_progress = function(completed, total, stage, diagnostic, state)
            if self.closed or generation ~= self.diagnostic_generation
                    or self.diagnostic_session ~= diagnostic then return end
            if type(self.options.on_diagnostic_progress) == "function" then
                pcall(self.options.on_diagnostic_progress, completed, total, stage, state)
            end
        end,
        on_done = function(diagnostic, event, state)
            if self.closed or generation ~= self.diagnostic_generation
                    or self.diagnostic_session ~= diagnostic then return end
            self.diagnostic_session = nil
            if type(self.options.on_diagnostic_done) == "function" then
                pcall(self.options.on_diagnostic_done, event or {}, state or {})
            end
        end,
    }
    self.diagnostic_session = session
    session:start()
    return session
end

function SourceManagementController:close()
    if self.closed then return end
    self.closed = true
    self:cancelCatalog()
    self:cancelProbe("closed")
    self:cancelDiagnostic("closed")
    self.options = {}
end

return SourceManagementController
