-- server-connector-mod / control/requests.lua
--
-- A pending platform request belongs on the server that owns the planet it was named at. A
-- player can name a platform from anywhere, and the game creates it in the save they are
-- connected to; when that is the wrong planet's server, the request sits in a world whose
-- rocket will never be fired for it.
--
-- This module moves such a request: destroy it here, tell the manager over UDP, and let the
-- server that owns the planet recreate the same request through the request_platform call.
-- The manager acks the move; until it does, the move is re-sent. Nothing is touched unless
-- every check below passes: an unclear platform is kept.
--
-- Dry-run by default, on new and existing saves. `request_purge_mode {live=true}` is the only
-- way to arm it.
--
-- Required as "__server-connector-mod__.control.requests". Required after outbound and before
-- events, so the dispatcher can register the timers.

local state = require("__server-connector-mod__.control.state")
local platforms = require("__server-connector-mod__.control.platforms")
local bus = require("__server-connector-mod__.control.bus")
local debug = require("__server-connector-mod__.control.debug")

local instance = state.instance
local main_force = state.main_force

local TTL = 18000
local MAX_PER_PASS = 5
local DEFAULT_PACK = "space-platform-starter-pack"
local PROBE_VERSION = 60

local function ensure()
    storage.request_moves = storage.request_moves or {}
    storage.request_in = storage.request_in or {}
    storage.request_seen = storage.request_seen or {}
end

local function live()
    return storage.request_purge_live == true
end

-- Pending only if every check passes. Anything unclear means "keep".
local function is_pending(p)
    if not p or not p.valid or p.scheduled_for_deletion ~= 0 then
        return false
    end
    if platforms.is_copy(p) then
        return false
    end

    local ok1, hub = pcall(function() return p.hub end)
    local ok2, surface = pcall(function() return p.surface end)
    if not (ok1 and ok2) or hub ~= nil or surface ~= nil then
        return false
    end

    local waiting = defines.space_platform_state.waiting_for_starter_pack
    if waiting ~= nil and p.state ~= waiting then
        return false
    end
    return true
end

-- The one place that decides which planet a request is for. nil means unknown, and an
-- unknown request is kept.
local function request_planet(p)
    local ok, loc = pcall(function() return p.space_location end)
    if not ok or not loc then
        return nil
    end
    return loc.name or nil
end

-- This server's planet, or nil. The purge refuses to run when it is nil.
local function own_planet()
    local own = (storage.topology or {})[instance()]
    if not own or own.kind ~= "planet" then
        return nil
    end
    if not game.planets[instance()] then
        return nil
    end
    return instance()
end

-- A prototype field as a plain string. starter_pack.quality is a LuaQualityPrototype, not a
-- string, and a name can be a prototype too; both have .name.
local function plain(value)
    if type(value) == "table" or type(value) == "userdata" then
        return value.name
    end
    return value
end

-- The starter pack the player chose, as plain strings.
local function pack_of(p)
    local ok, sp = pcall(function() return p.starter_pack end)
    if not ok or not sp then
        return DEFAULT_PACK, nil
    end
    return plain(sp.name) or DEFAULT_PACK, plain(sp.quality)
end

local function sorted_platforms()
    local list = {}
    for _, p in pairs(main_force().platforms or {}) do
        list[#list + 1] = p
    end
    table.sort(list, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)
    return list
end

-- Every platform this server can see, with the two verdicts that matter. Read-only.
local function probe()
    local out = {}
    for _, p in ipairs(sorted_platforms()) do
        local name = p.name
        local sp = pack_of(p)
        local location = request_planet(p) or ""
        out[#out + 1] = {
            name = name,
            index = p.index,
            valid = p.valid,
            hub_present = p.hub ~= nil,
            surface_present = (function()
                local ok, s = pcall(function() return p.surface end)
                return ok and s ~= nil
            end)(),
            state = tostring(p.state),
            space_location = location,
            starter_pack = sp,
            scheduled_for_deletion = p.scheduled_for_deletion,
            is_copy = platforms.is_copy(p),
            is_pending = is_pending(p),
            request_planet = location,
        }
    end
    return {ok = true, instance = instance(), own_planet = own_planet() or "", platforms = out}
end

-- Move at most MAX_PER_PASS wrong-planet requests. Sorted by index, so every peer acts in the
-- same order and the resend pushes in the same order.
local function purge()
    ensure()
    if not state.known() then
        debug.emit("purge: skipped (topology unknown)")
        return 0
    end
    local here = own_planet()
    if not here then
        debug.emit("purge: skipped (instance %s owns no planet)", instance())
        return 0
    end
    debug.emit("purge: instance=%s own=%s live=%s", instance(), here, tostring(live()))

    if storage.request_probe_version ~= PROBE_VERSION then
        storage.request_probe_version = PROBE_VERSION
        local ok, json = pcall(helpers.table_to_json, probe())
        if ok then
            log(string.format("[%s] request probe: %s", instance(), json))
        end
    end

    local all = sorted_platforms()
    debug.emit("purge: %d platform(s) visible", #all)

    local moved = 0
    for _, p in ipairs(all) do
        if moved >= MAX_PER_PASS then
            break
        end

        if is_pending(p) then
            local name = p.name
            local planet = request_planet(p)
            debug.dump("purge pending " .. tostring(name), {
                platform = debug.platform_table(p),
                planet = planet or "",
                own = here,
                copy = platforms.is_copy(p),
                arrived = storage.request_in[name] ~= nil,
                moved = storage.request_moves[name] ~= nil,
                pack = {pack_of(p)},
            })
            if planet == nil then
                debug.emit("purge: pending %s has no readable planet; kept", tostring(name))
            elseif planet == here then
                debug.emit("purge: pending %s belongs here; kept", tostring(name))
            end
            if planet ~= nil and planet ~= here then
                local pack, quality = pack_of(p)

                if storage.request_moves[name] or storage.request_in[name] then
                    log(string.format("[%s] request %s came from or went to another server; keeping it",
                        instance(), tostring(name)))
                    debug.emit("purge: anti-bounce for %s (arrived=%s moved=%s)", tostring(name),
                        tostring(storage.request_in[name] ~= nil),
                        tostring(storage.request_moves[name] ~= nil))
                elseif not live() then
                    if not storage.request_seen[name] then
                        storage.request_seen[name] = game.tick
                        log(string.format("[%s] [dry-run] would move %s (%s) from %s",
                            instance(), tostring(name), tostring(planet), here))
                    else
                        debug.emit("purge: %s already reported by the dry-run; still kept",
                            tostring(name))
                    end
                else
                    local id = instance() .. ":" .. tostring(name) .. ":" .. game.tick
                    storage.request_moves[name] = {
                        id = id,
                        planet = planet,
                        pack = pack,
                        quality = quality,
                        at = game.tick,
                        acked = false,
                    }

                    debug.dump("purge move", {
                        id = id,
                        name = name,
                        planet = planet,
                        pack = pack,
                        quality = quality,
                        at = game.tick,
                    })
                    local destroyed = pcall(function() p.destroy() end)
                    if not destroyed then
                        storage.request_moves[name] = nil
                        log(string.format("[%s] could not destroy the request %s; keeping it",
                            instance(), tostring(name)))
                        debug.emit("purge: p.destroy() failed for %s", tostring(name))
                    else
                        bus.push("platform_request_moved", {
                            instance = instance(),
                            id = id,
                            name = name,
                            planet = planet,
                            starter_pack = pack,
                            quality = quality,
                            tick = game.tick,
                        })
                        main_force().print(string.format(
                            "Platform request '%s' belongs to the %s server and was moved there. Go there to launch it.",
                            tostring(name), tostring(planet)))
                        moved = moved + 1
                    end
                end
            end
        end
    end
    return moved
end

-- Re-send unacked moves. Sorted by name: bus.push advances storage.out_seq, and that
-- sequence has to be identical on every peer.
local function resend()
    ensure()
    local names = {}
    for name in pairs(storage.request_moves) do
        names[#names + 1] = name
    end
    table.sort(names)

    debug.emit("resend: %d move record(s)", #names)

    local sent = 0
    for _, name in ipairs(names) do
        local record = storage.request_moves[name]
        local age = game.tick - (record.at or 0)
        debug.dump("resend record " .. tostring(name), {
            id = record.id,
            planet = record.planet,
            pack = record.pack,
            quality = record.quality,
            age = age,
            acked = record.acked,
        })
        if age > TTL then
            if not record.acked then
                log(string.format("[%s] request %s moved but was never acknowledged", instance(), name))
            end
            storage.request_moves[name] = nil
        elseif not record.acked then
            bus.push("platform_request_moved", {
                instance = instance(),
                id = record.id,
                name = name,
                planet = record.planet,
                starter_pack = record.pack,
                quality = record.quality,
                tick = game.tick,
            })
            sent = sent + 1
        end
    end
    return sent
end

-- The receiver. One table argument; every failure says which check failed.
local function create(args)
    debug.dump("request_platform args", args)
    if type(args) ~= "table" then
        return {ok = false, error = "args must be a table"}
    end

    local here = own_planet()
    if not here then
        return {ok = false, error = "this server owns no planet"}
    end
    if args.planet ~= here then
        return {ok = false, error = "wrong server"}
    end

    local name = args.name
    if type(name) ~= "string" or name == "" then
        return {ok = false, error = "a platform needs a name"}
    end
    if #name > 200 then
        return {ok = false, error = "name too long"}
    end

    for _, p in pairs(main_force().platforms or {}) do
        if p and p.valid and p.name == name then
            ensure()
            if storage.request_in[name] then
                debug.emit("request_platform: %s already here (existed)", name)
                return {ok = true, existed = true, name = name, index = p.index}
            end
            debug.emit("request_platform: %s is taken on %s", name, here)
            return {ok = false, error = "name_taken"}
        end
    end

    local pack = args.starter_pack or DEFAULT_PACK
    if type(pack) ~= "string" or not prototypes.item[pack] then
        return {ok = false, error = "unknown starter pack " .. tostring(pack)}
    end

    local quality = args.quality
    if quality ~= nil then
        if type(quality) ~= "string" or not (prototypes.quality and prototypes.quality[quality]) then
            return {ok = false, error = "unknown quality " .. tostring(quality)}
        end
    end

    local ok, made = pcall(function()
        return main_force().create_space_platform{
            name = name,
            planet = here,
            starter_pack = quality and {name = pack, quality = quality} or pack,
        }
    end)
    if not ok or not made then
        debug.emit("request_platform: create_space_platform failed for %s: %s", name, tostring(made))
        return {ok = false, error = tostring(made)}
    end

    ensure()
    storage.request_in[name] = game.tick
    debug.dump("request_platform created", {
        name = name,
        index = made.index,
        planet = here,
        pack = pack,
        quality = quality,
        platform = debug.platform_table(made),
    })
    log(string.format("[%s] recreated platform request %s for %s", instance(), name, here))
    return {ok = true, name = name, index = made.index}
end

local function ack(args)
    debug.dump("request_moved_ack args", args)
    if type(args) ~= "table" or type(args.id) ~= "string" then
        return {ok = false, error = "an id is required"}
    end
    ensure()
    for name, record in pairs(storage.request_moves) do
        if record.id == args.id then
            record.acked = true
            debug.emit("request_moved_ack: %s acknowledged", name)
            return {ok = true, name = name}
        end
    end
    debug.emit("request_moved_ack: no move with id %s", tostring(args.id))
    return {ok = false, error = "no move with that id"}
end

local function set_mode(args)
    debug.dump("request_purge_mode args", args)
    if type(args) ~= "table" then
        return {ok = false, error = "args must be a table"}
    end
    storage.request_purge_live = args.live == true
    debug.emit("request_purge_mode: live=%s", tostring(storage.request_purge_live))
    return {ok = true, live = storage.request_purge_live}
end

return {
    is_pending = is_pending,
    request_planet = request_planet,
    pack_of = pack_of,
    purge = purge,
    resend = resend,
    create = create,
    ack = ack,
    set_mode = set_mode,
    probe = probe,
}
