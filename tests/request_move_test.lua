-- Moving a pending platform request to the planet's own server.
--
-- Runs under plain Lua with state, platforms and outbound stubbed.
-- `lua tests/request_move_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
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
        platform_table = function() return {} end,
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

package.preload["__server-connector-mod__.control.platforms"] = function()
    return {
        is_copy = function(p) return p.copy == true end,
    }
end

package.preload["__server-connector-mod__.control.outbound"] = function()
    return {
        push = function(kind, payload)
            PUSHED[#PUSHED + 1] = {kind = kind, payload = payload}
        end,
    }
end

INSTANCE = "nauvis"
storage = {
    topology = {nauvis = {kind = "planet"}},
}
game = {tick = 100, planets = {nauvis = {}}}
defines = {space_platform_state = {waiting_for_starter_pack = 0}}
prototypes = {item = {["space-platform-starter-pack"] = true}, quality = {normal = true}}
log = function() end
helpers = {table_to_json = function() return "{}" end}

PUSHED = {}

-- Declared first, then filled: a local is not in scope inside its own initializer, and
-- destroy must set the flag on the returned object.
local function platform(opts)
    local p = {
        valid = opts.valid ~= false,
        name = opts.name or "p",
        index = opts.index or 1,
        state = opts.state or 0,
        hub = opts.hub,
        surface = opts.surface,
        space_location = opts.location and {name = opts.location} or nil,
        starter_pack = opts.pack and {name = opts.pack, quality = opts.quality} or nil,
        scheduled_for_deletion = opts.deleting or 0,
        copy = opts.copy,
        destroyed = false,
    }
    p.destroy = function(ticks)
        p.destroyed = true
    end
    return p
end

local made = {}
FORCE = {
    platforms = {},
    print = function() end,
    create_space_platform = function(spec)
        made[#made + 1] = spec
        -- The game adds the platform to the force; without that the receiver's idempotence
        -- check has nothing to find on a retry.
        local created = platform({name = spec.name, index = 9, location = spec.planet})
        FORCE.platforms[#FORCE.platforms + 1] = created
        return created
    end,
}

local requests = dofile("control/requests.lua")
assert(PUSHED ~= nil, "the bus stub should be in use")

-- 1. pending only when hub, surface and deletion all say so
local pending = platform({name = "req", location = "vulcanus"})
assert(requests.is_pending(pending) == true, "a plain request should be pending")
assert(requests.is_pending(platform({name = "built", location = "vulcanus", hub = {}})) == false,
    "a platform with a hub is not pending")
assert(requests.is_pending(platform({name = "surfaced", location = "vulcanus", surface = {}})) == false,
    "a platform with a surface is not pending")
assert(requests.is_pending(platform({name = "copy", location = "vulcanus", copy = true})) == false,
    "a copy is not pending")
assert(requests.is_pending(platform({name = "dying", location = "vulcanus", deleting = 5})) == false,
    "a platform scheduled for deletion is not pending")

-- 2. the planet comes from space_location; unknown means nil
assert(requests.request_planet(pending) == "vulcanus", "request_planet should read space_location")
assert(requests.request_planet(platform({name = "x"})) == nil, "no space_location is unknown")

-- 3. dry-run: logs, never destroys
FORCE.platforms = {pending}
assert(requests.purge() == 0, "dry-run moves nothing")
assert(pending.destroyed == false, "dry-run must not destroy the request")
assert(storage.request_moves["req"] == nil, "dry-run must not record a move")

-- 4. live: destroy, record, push
assert(requests.set_mode({live = true}).live == true, "set_mode should report live")
assert(requests.purge() == 1, "live mode should move the wrong-planet request")
assert(pending.destroyed == true, "live mode should destroy the request")
local record = storage.request_moves["req"]
assert(record and record.planet == "vulcanus", "the move should be recorded with its planet")
assert(#PUSHED == 1 and PUSHED[1].kind == "platform_request_moved", "the move should be pushed")
assert(PUSHED[1].payload.starter_pack == "space-platform-starter-pack",
    "the pack should travel with the move")

-- 4b. resend re-pushes an unacked move, and an ack stops it
assert(requests.resend() == 1, "an unacked move should be re-sent")
assert(#PUSHED == 2 and PUSHED[2].kind == "platform_request_moved",
    "the resend must push through the bus")
assert(requests.ack({id = record.id}).ok == true, "the ack should be accepted")
assert(requests.resend() == 0, "an acked move must not be re-sent")

-- 5. anti-bounce: a request that arrived here is never moved out
local arrived = platform({name = "arrived", location = "vulcanus"})
storage.request_in["arrived"] = game.tick
FORCE.platforms = {arrived}
requests.purge()
assert(arrived.destroyed == false, "a request that arrived here must not be moved out")

-- 6. a request for this server's planet is kept
local mine = platform({name = "mine", location = "nauvis"})
FORCE.platforms = {mine}
requests.purge()
assert(mine.destroyed == false, "a request for the owned planet must be kept")

-- 7. the receiver validates, is idempotent, and carries the pack
storage.request_in = {}
FORCE.platforms = {}
local wrong = requests.create({planet = "vulcanus", name = "r"})
assert(wrong.ok == false and wrong.error == "wrong server", "a wrong-server create must refuse")

local ok = requests.create({planet = "nauvis", name = "r", starter_pack = "space-platform-starter-pack",
    quality = "normal"})
assert(ok.ok == true and ok.index == 9, "a valid create should succeed")
assert(made[1].planet == "nauvis", "the request should be created for this planet")
assert(type(made[1].starter_pack) == "table" and made[1].starter_pack.quality == "normal",
    "the quality should travel with the pack")

local again = requests.create({planet = "nauvis", name = "r"})
assert(again.ok == true and again.existed == true, "a duplicate create should report existed")

FORCE.platforms = {platform({name = "taken", location = "nauvis"})}
local taken = requests.create({planet = "nauvis", name = "taken"})
assert(taken.ok == false and taken.error == "name_taken", "a taken name should refuse")

local unknown = requests.create({planet = "nauvis", name = "q", starter_pack = "nope"})
assert(unknown.ok == false and unknown.error:find("unknown starter pack") ~= nil,
    "an unknown pack should refuse")

print("request move: pending verdict, dry-run, live move, anti-bounce, receiver")
