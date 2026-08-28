-- Pure scheduling helpers for the cover browser. Kept independent from KOReader UI
-- so rapid-navigation behaviour can be unit-tested on a desktop Lua runtime.
local CoverPrefetch = {}

function CoverPrefetch:window(count, current, ahead, behind)
    count = math.max(0, math.floor(tonumber(count or 0) or 0))
    current = math.max(1, math.min(count, math.floor(tonumber(current or 1) or 1)))
    ahead, behind = tonumber(ahead or 2) or 2, tonumber(behind or 1) or 1
    local output, seen = {}, {}
    local function add(index)
        if index >= 1 and index <= count and not seen[index] then
            seen[index] = true
            output[#output + 1] = index
        end
    end
    add(current)
    for offset = 1, ahead do add(current + offset) end
    for offset = 1, behind do add(current - offset) end
    return output
end

function CoverPrefetch:newState()
    return { generation = 0 }
end

function CoverPrefetch:bump(state)
    state.generation = (tonumber(state.generation or 0) or 0) + 1
    return state.generation
end

function CoverPrefetch:isCurrent(state, generation)
    return state and state.generation == generation
end

return CoverPrefetch
