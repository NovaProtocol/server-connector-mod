-- platform_check: the copy's cargo and requests, as the manager's check page reads them.
--
-- Runs under plain Lua with `state` and `platforms` stubbed.
-- `lua tests/platform_check_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
        instance = function() return INSTANCE end,
        known = function() return true end,
        main_force = function() return {platforms = PLATFORMS} end,
    }
end

package.preload["__server-connector-mod__.control.debug"] = function()
    return {
        enabled = function() return false end,
        emit = function() end,
        dump = function() end,
        json = function() return "" end,
        platform_table = function() return {} end,
        silo_table = function() return {} end,
        surface_table = function() return {} end,
        event = function() end,
        call = function() end,
        push = function() end,
        boot = function() end,
    }
end

package.preload["__server-connector-mod__.control.platforms"] = function()
    return {
        bay_count = function() return 2 end,
    }
end

INSTANCE = "gleba"
storage = {}
defines = {
    inventory = {cargo_unit = 1},
    logistic_member_index = {hub = 1},
}
log = function() end

local inventory = {
    {valid_for_read = true, name = "iron-plate", count = 5, quality = nil},
}
local point = {
    sections = {
        {filters = {{value = {name = "iron-plate", quality = nil}, min = 10, max = 20}}},
    },
}
local hub = {
    valid = true,
    get_inventory = function() return inventory end,
    get_logistic_point = function() return point end,
}
PLATFORMS = {{name = "Test", index = 3, hub = hub}}

local platform_api = dofile("control/platform_api.lua")
local result = platform_api.check()

assert(#result == 1, "expected one copy, got " .. #result)
local entry = result[1]
assert(entry.name == "Test", "wrong name: " .. tostring(entry.name))
assert(entry.index == 3, "wrong index: " .. tostring(entry.index))
assert(entry.bays == 2, "wrong bay count: " .. tostring(entry.bays))
assert(#entry.cargo == 1 and entry.cargo[1].item == "iron-plate" and entry.cargo[1].count == 5,
    "cargo was not read")
assert(#entry.requests == 1 and entry.requests[1].count == 10 and entry.requests[1].max_count == 20,
    "requests were not read")

-- The space server owns the real platforms; a check there has no copies to report.
INSTANCE = "space"
assert(#platform_api.check() == 0, "the space server should report no copies")

print("platform check: copies report cargo, requests and bays")
