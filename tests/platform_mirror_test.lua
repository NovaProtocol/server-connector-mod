-- Adopting a native platform: destroy, ask, and keep asking until the copy arrives.
--
-- This is the regression test for the bug where the mirror destroyed a player's new platform
-- and then threw on a require inside report_platform_create, so the create was never sent.
--
-- Runs under plain Lua with state, debug and bus stubbed.
-- `lua tests/platform_mirror_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
        MOD = "server-connector",
        instance = function() return INSTANCE end,
        known = function() return true end,
        main_force = function() return FORCE end,
    }
end

package.preload["__server-connector-mod__.control.debug"] = function()
    return {
        enabled = function() return false end,
        emit = function() end,
        dump = function() end,
        json = function() return "" end,
        platform_table = function(p) return {name = p and p.name} end,
        silo_table = function() return {} end,
        surface_table = function() return {} end,
        event = function() end,
        call = function() end,
        push = function() end,
        boot = function() end,
    }
end

PUSHED = {}

package.preload["__server-connector-mod__.control.bus"] = function()
    return {
        push = function(kind, payload)
            PUSHED[#PUSHED + 1] = {kind = kind, payload = payload}
        end,
        epoch = function() return "test" end,
    }
end

INSTANCE = "nauvis"
LOG = {}
log = function(message) LOG[#LOG + 1] = tostring(message) end

game = {tick = 100, planets = {nauvis = {}}}
storage = {topology = {nauvis = {kind = "planet"}}}
prototypes = {item = {["space-platform-starter-pack"] = {}}, quality = {normal = {}}}

-- A pending native platform: no hub, no surface, for nauvis itself.
local native = {
    name = "Elysium_81",
    index = 64,
    valid = true,
    state = 8,
    hub = nil,
    surface = nil,
    space_location = {name = "nauvis"},
    scheduled_for_deletion = 0,
    destroyed = 0,
}

-- Declared first, then wired: a local is not in scope inside its own initializer, so a
-- destroy defined in the table would write to a nil global.
native.cancel_deletion = function() end
native.destroy = function(ticks)
    native.destroyed = native.destroyed + 1
    native.scheduled_for_deletion = 1
end

FORCE = {platforms = {native}}

local platforms = dofile("control/platforms.lua")

-- 1. the adoption path destroys it and asks the space server to create it
assert(platforms.adopt_native_platform(native, "Elysium_81") == true,
    "adoption should succeed")
assert(native.destroyed == 1, "the native platform should be destroyed once")
assert(PUSHED[1] and PUSHED[1].kind == "platform_create",
    "the create must be pushed, not lost at a require")
assert(PUSHED[1].payload.name == "Elysium_81", "the create should carry the name")
assert(PUSHED[1].payload.location == "nauvis", "the create should carry the planet")
assert(storage.native_creates and storage.native_creates["Elysium_81"],
    "the create should be remembered for a retry")

-- 2. no copy yet, so the next timer pass asks again
PUSHED = {}
assert(platforms.retry_native_creates() == 1, "an unconfirmed create should be re-sent")
assert(PUSHED[1] and PUSHED[1].kind == "platform_create", "the retry should push the create")
assert(storage.native_creates["Elysium_81"].tries == 2, "the retry count should advance")

-- 3. the copy arrives: the record is cleared and nothing more is sent
local copy = {
    name = "Elysium_81",
    index = 70,
    valid = true,
    scheduled_for_deletion = 0,
    hub = {},
    surface = {},
}
storage.copies = {["Elysium_81"] = true}
FORCE.platforms = {copy}
PUSHED = {}
assert(platforms.retry_native_creates() == 0, "a confirmed create must stop retrying")
assert(storage.native_creates["Elysium_81"] == nil, "the record should be cleared")
assert(#PUSHED == 0, "nothing should be pushed once the copy exists")

-- 4. a native with the same name still standing clears the record without a push
storage.native_creates = {["Another"] = {location = "nauvis", at = game.tick, tries = 1}}
FORCE.platforms = {{
    name = "Another",
    index = 80,
    valid = true,
    scheduled_for_deletion = 0,
}}
storage.copies = {}
PUSHED = {}
assert(platforms.retry_native_creates() == 0, "a live native must not be re-asked")
assert(storage.native_creates["Another"] == nil, "the stale record should be dropped")
assert(#PUSHED == 0, "no create should be pushed for a live native")

-- 5. a platform the game refuses to destroy is not adopted and not recorded
local stuck = {
    name = "Stuck",
    index = 81,
    valid = true,
    scheduled_for_deletion = 0,
    cancel_deletion = function() end,
    destroy = function() error("the game refused") end,
}
storage.native_creates = {}
PUSHED = {}
assert(platforms.adopt_native_platform(stuck, "Stuck") == false,
    "a failed destroy must not be recorded as adopted")
assert(storage.native_creates["Stuck"] == nil, "no record for a platform still standing")
assert(#PUSHED == 0, "no create for a platform still standing")

print("platform mirror: adopt, push create, retry, confirm, drop")
