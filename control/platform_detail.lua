-- server-connector-mod / control/platform_detail.lua
--
-- Read-only detail for one real space platform. The manager's runtime page needs the
-- request list, the hub contents and, when this Factorio build exposes it, the schedule.
-- Nothing here writes: a runtime page must never be able to change a world.

local state = require("__server-connector-mod__.control.state")
local platform_api = require("__server-connector-mod__.control.platform_api")
local platforms = require("__server-connector-mod__.control.platforms")

local function find_platform(index)
    index = tonumber(index)
    if index == nil then
        return nil
    end
    for _, platform in pairs(state.main_force().platforms or {}) do
        if platform and platform.valid and platform.index == index then
            return platform
        end
    end
    return nil
end

local function location_of(platform)
    local ok, location = pcall(function()
        return platform.space_location
    end)
    if not ok or not location then
        return nil
    end
    return location.name
end

-- The schedule is deliberately defensive. The 2.1 API exposes the platform schedule on some
-- builds and not others, and it is not worth making the whole page fail for a bonus panel.
local function schedule_of(platform)
    local ok, schedule = pcall(function()
        return platform.schedule
    end)
    if not ok or schedule == nil then
        return {available = false, reason = "not exposed by this Factorio build", stops = {}}
    end

    local stops = {}
    local read_ok, entries = pcall(function()
        return schedule.stops
    end)
    if read_ok and type(entries) == "table" then
        for _, stop in pairs(entries) do
            local name = nil
            pcall(function()
                name = stop.station or stop.name
            end)
            if name ~= nil then
                stops[#stops + 1] = {name = tostring(name)}
            end
        end
    end
    return {available = true, stops = stops}
end

local function cargo_of(platform)
    local ok, cargo = pcall(platform_api.cargo, platform)
    if not ok or type(cargo) ~= "table" then
        return {}
    end
    return cargo
end

local function requests_of(platform)
    local ok, requests = pcall(platform_api.requests, platform)
    if not ok or type(requests) ~= "table" then
        return {}
    end
    return requests
end

local function detail(index)
    local platform = find_platform(index)
    if not platform then
        return {ok = false, error = "no such platform"}
    end

    local _, inventory = pcall(function()
        return platform_api.hub_inventory(platform.hub)
    end)

    return {
        ok = true,
        instance = state.instance(),
        platform = {index = platform.index, name = platform.name},
        name = platform.name,
        location = location_of(platform),
        paused = platform.paused == true,
        bays = platforms.bay_count(platform),
        weight = inventory and inventory.weight or nil,
        cargo = cargo_of(platform),
        requests = requests_of(platform),
        schedule = schedule_of(platform),
    }
end

-- The manager's existing platform store expects a paged read with this shape. One page is
-- enough for the UI and keeps the call bounded; `done` tells the manager not to ask again.
local function dump(index, cursor, limit)
    local platform = find_platform(index)
    if not platform then
        return {ok = false, error = "no such platform"}
    end

    local cargo = cargo_of(platform)
    local requests = requests_of(platform)
    local _, inventory = pcall(function()
        return platform_api.hub_inventory(platform.hub)
    end)
    return {
        ok = true,
        instance = state.instance(),
        platform = {index = platform.index, name = platform.name},
        cursor = tonumber(cursor) or 0,
        next = 0,
        total = #cargo,
        done = true,
        hash = 0,
        weight = inventory and inventory.weight or nil,
        cargo = cargo,
        requests = requests,
        request_hash = 0,
    }
end

return {
    detail = detail,
    dump = dump,
}
