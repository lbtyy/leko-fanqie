-- Lightweight Linux memory-pressure guard for old Kindle devices.
-- It never allocates large buffers and reads only small /proc text files.
local MemoryGuard = {
    -- Below this available-memory level, keep background work single-process.
    cautious_available_kb = 128 * 1024,
    -- A large KOReader parent makes fork/COW expensive even when MemAvailable
    -- still looks healthy. This ceiling also forces one background worker.
    cautious_rss_kb = 96 * 1024,
    -- Used only for diagnostics and more aggressive garbage collection.
    critical_available_kb = 64 * 1024,
    -- Kindle 7-class devices commonly expose only about 256 MiB. Two forked
    -- search children are not safe there even when the current free-memory
    -- snapshot happens to look healthy.
    low_ram_total_kb = 384 * 1024,
}

local function readSmall(path, limit)
    local file = io.open(path, "r")
    if not file then return nil end
    local data = file:read(limit or 8192)
    file:close()
    return data
end

local function fieldKB(text, name)
    if type(text) ~= "string" then return nil end
    return tonumber(text:match("\n?" .. name .. ":%s*(%d+)%s*kB"))
end

function MemoryGuard:snapshot()
    local meminfo = readSmall("/proc/meminfo", 8192)
    local status = readSmall("/proc/self/status", 8192)
    local total = fieldKB(meminfo, "MemTotal")
    local available = fieldKB(meminfo, "MemAvailable")
    if not available then
        local free = fieldKB(meminfo, "MemFree") or 0
        local buffers = fieldKB(meminfo, "Buffers") or 0
        local cached = fieldKB(meminfo, "Cached") or 0
        local reclaim = fieldKB(meminfo, "SReclaimable") or 0
        local shmem = fieldKB(meminfo, "Shmem") or 0
        available = math.max(0, free + buffers + cached + reclaim - shmem)
    end
    return {
        total_kb = total,
        available_kb = available,
        rss_kb = fieldKB(status, "VmRSS"),
        peak_rss_kb = fieldKB(status, "VmHWM"),
    }
end

function MemoryGuard:recommendedBackgroundWorkers()
    local snapshot = self:snapshot()
    local total = tonumber(snapshot.total_kb)
    local available = tonumber(snapshot.available_kb)
    local rss = tonumber(snapshot.rss_kb)
    -- Unknown memory state is treated conservatively. /proc is expected on
    -- KOReader devices; failure to read it must not silently enable two forks.
    if not total or not available or not rss then return 1, snapshot end
    if total < self.low_ram_total_kb then return 1, snapshot end
    if available < self.cautious_available_kb then return 1, snapshot end
    if rss > self.cautious_rss_kb then return 1, snapshot end
    return 2, snapshot
end


function MemoryGuard:isLowRam(snapshot)
    snapshot = snapshot or self:snapshot()
    local total = tonumber(snapshot and snapshot.total_kb)
    -- Unknown Linux memory metadata is treated conservatively on KOReader.
    return total == nil or total < self.low_ram_total_kb, snapshot
end

function MemoryGuard:processRssKB(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return nil end
    local status = readSmall("/proc/" .. tostring(math.floor(pid)) .. "/status", 8192)
    return fieldKB(status, "VmRSS")
end

function MemoryGuard:backgroundChildUnsafe(pid)
    local snapshot = self:snapshot()
    local available = tonumber(snapshot.available_kb)
    local low_ram = self:isLowRam(snapshot)
    local child_rss = self:processRssKB(pid)
    -- MemAvailable is the most useful signal here because fork RSS includes
    -- shared COW pages and therefore grossly overstates unique child memory.
    if available and available < self.critical_available_kb then
        return true, "系统可用内存已低于 " .. tostring(math.floor(self.critical_available_kb / 1024)) .. " MiB", snapshot, child_rss
    end
    -- A child far larger than the parent baseline usually means one source has
    -- produced an extreme response/DOM/script state. Stop it before the kernel
    -- OOM killer chooses KOReader or the Kindle framework.
    if low_ram and child_rss and child_rss > 128 * 1024 then
        return true, "单书源进程内存超过 128 MiB", snapshot, child_rss
    end
    return false, nil, snapshot, child_rss
end

function MemoryGuard:isCritical()
    local snapshot = self:snapshot()
    return snapshot.available_kb ~= nil
        and snapshot.available_kb < self.critical_available_kb, snapshot
end

function MemoryGuard:prepareForFork()
    -- Full collection before fork reduces the number of dirty Lua pages copied
    -- by the child. Avoid loading any other module or settings in this method.
    collectgarbage("collect")
    return self:snapshot()
end

return MemoryGuard
