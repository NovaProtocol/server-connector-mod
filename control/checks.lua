-- server-connector-mod / control/checks.lua
--
-- Read-only diagnostics for the two request shapes that go quiet without an error:
--   1. a loop: the same item sits in a connector hub's Incoming and Outgoing group, so the
--      planet is asked for what it also exports and the game serves neither.
--   2. a request with no explicit planet: planet-sourced with no import_from. That is fine
--      for personal items such as repair packs; anywhere else it is usually a lost filter.
--      Connector hubs are ignored here, because their groups are one-way by design.
--
-- Nothing in this file changes the world: it reports, and the owner decides.

local state = require("__server-connector-mod__.control.state")
local connector = require("__server-connector-mod__.control.connector")

local function item_of(filter)
    if not filter then
        return nil
    end
    local value = filter.value
    if value and value.name then
        return value.name
    end
    return filter.item
end

local function items_of(list)
    local set = {}
    for _, filter in ipairs(list or {}) do
        local name = item_of(filter)
        if name then
            set[name] = true
        end
    end
    return set
end

local function point_of(hub)
    for _, name in ipairs({"space_platform_hub_requester", "hub_requester"}) do
        local value = defines.logistic_member_index and defines.logistic_member_index[name]
        if value ~= nil then
            local ok, point = pcall(function() return hub.get_logistic_point(value) end)
            if ok and point then
                return point
            end
        end
    end
    return nil
end

local function run()
    local out = {}

    -- 1. Loops, connector hubs only.
    for _, planet in ipairs(connector.planets()) do
        local groups = connector.read_groups(planet)
        if groups and groups.exists and groups.hub then
            local down = items_of(groups.incoming)
            local up = items_of(groups.outgoing)
            local platform = connector.find_connector(planet)
            local label = (platform and platform.name) or planet
            local names = {}
            for name in pairs(down) do
                if up[name] then
                    names[#names + 1] = name
                end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                out[#out + 1] = string.format("detected loop in %s at item %s", label, name)
            end
        end
    end

    -- 2. No explicit planet, real platforms only.
    for _, platform in pairs(state.main_force().platforms or {}) do
        if platform.valid and not connector.is_connector(platform)
            and platform.hub and platform.hub.valid then
            local point = point_of(platform.hub)
            if point then
                for _, section in pairs(point.sections or {}) do
                    for _, filter in ipairs(section.filters or {}) do
                        local name = item_of(filter)
                        local from_planet = filter.request_from == nil
                            or filter.request_from == "planet"
                        local target = filter.import_from
                        if name and from_planet and (target == nil or target == "") then
                            out[#out + 1] = string.format("no planet set on %s at item %s",
                                platform.name, name)
                        end
                    end
                end
            end
        end
    end

    return out
end

return {
    run = run,
}
