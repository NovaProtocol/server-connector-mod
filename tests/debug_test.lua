-- The debug switch: every dump is safe to call, and the flag is on while we work on it.
--
-- Runs under plain Lua with state, defines and helpers stubbed.
-- `lua tests/debug_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
        instance = function() return "nauvis" end,
        known = function() return true end,
        main_force = function() return FORCE end,
    }
end

INSTANCE = "nauvis"
LOG = {}

log = function(message) LOG[#LOG + 1] = tostring(message) end

helpers = {
    table_to_json = function(value)
        if type(value) == "table" and value.huge then
            return string.rep("x", 20000)
        end
        return '{"json":true}'
    end,
}

-- script.active_mods, not game.active_mods: the game table has no active_mods in 2.1, and
-- the first version of this test used the wrong table, so it never exercised the real line.
script = {
    active_mods = {["server-connector-mod"] = "0.36.62", base = "2.1.23"},
}

game = {
    tick = 1234,
    planets = {nauvis = {}},
}

prototypes = {
    item = {["space-platform-starter-pack"] = {}},
    quality = {normal = {}, uncommon = {}},
}

defines = {
    space_platform_state = {waiting_for_starter_pack = 0, docked = 4},
    logistic_member_index = {rocket_silo_requester = 1, logistic_container = 2},
    rocket_silo_status = {rocket_rising = 3},
    controllers = {ghost = 1, character = 2, remote = 3},
    inventory = {rocket_silo_rocket = 1},
    events = {on_surface_created = 10, on_entity_logistic_slot_changed = 11},
}

storage = {schema = 12, topology = {nauvis = {kind = "planet"}}}

local platform = {
    name = "test",
    index = 7,
    valid = true,
    state = 0,
    hub = nil,
    surface = nil,
    space_location = {name = "vulcanus"},
    space_connection = nil,
    distance = nil,
    paused = false,
    hidden = false,
    scheduled_for_deletion = 0,
    starter_pack = {name = "space-platform-starter-pack", quality = "normal"},
}

local stack = {valid_for_read = true, name = "space-platform-starter-pack", count = 3}
local silo = {
    unit_number = 42,
    name = "rocket-silo",
    position = {x = 1, y = 2},
    surface = {name = "nauvis"},
    rocket_silo_status = 3,
    get_inventory = function()
        return {stack, {valid_for_read = false}}
    end,
    get_logistic_point = function(member)
        if member ~= 1 then
            return nil
        end
        return {
            sections = {
                [1] = {
                    type = "give",
                    active = true,
                    filters = {
                        [1] = {
                            value = {name = "space-platform-starter-pack", quality = "normal"},
                            min = 1,
                        },
                    },
                },
            },
        }
    end,
}

FORCE = {platforms = {platform}}

local debug = dofile("control/debug.lua")

assert(debug.enabled() == true, "the switch is on while the fleet is being finalised")

local fields = debug.platform_table(platform)
assert(fields.state_name == "waiting_for_starter_pack", "the numeric state should be named")
assert(fields.space_location == "vulcanus", "the planet should be readable")
assert(fields.hub_present == false and fields.surface_present == false,
    "a pending request has neither hub nor surface")
assert(fields.starter_pack.quality == "normal", "the pack quality should be readable")

local detail = debug.silo_table(silo)
assert(detail.status_name == "rocket_rising", "the numeric silo status should be named")
assert(detail.rocket[1].item == "space-platform-starter-pack", "the rocket inventory should be read")
assert(detail.requests.readable == true, "the requester point should be found by name")
assert(detail.requests.sections[1].filters[1].item == "space-platform-starter-pack",
    "the request filter should be read")

local surface = debug.surface_table({name = "nauvis", index = 1})
assert(surface.name == "nauvis" and surface.platform_present == false, "a plain surface should describe")

debug.event("a test", {tick = 1, entity = platform, nested = {deep = {deeper = {deepest = true}}}})
debug.call("probe", {a = 1}, {ok = true})
debug.push("platform", {name = "test"})
debug.dump("huge", {huge = true})
debug.boot()

assert(#LOG > 5, "the dumps should reach the log")
local joined = table.concat(LOG, "\n")
assert(joined:find("%[debug%]%[nauvis%] boot: instance="), "boot should report the instance")
assert(joined:find("boot: events="), "boot should report which optional events exist")
assert(joined:find("boot: mods="), "boot should report the mod versions")
assert(joined:find("boot: failed") == nil, "boot must not fail in the test")
assert(joined:find("truncated"), "a huge JSON value should be truncated, not swallowed")
assert(joined:find("event a test"), "events should be dumped")
assert(joined:find("call probe args"), "calls should be dumped")
assert(joined:find("udp platform"), "pushes should be dumped")

print("debug switch: platform, silo, surface, event, call, push, boot")
