-- server-connector-mod / control/debug.lua
--
-- ONE SWITCH. While the fleet is being brought up, set DEBUG = true and the mod narrates
-- what it sees and what it decides. Set it to false for v1; nothing else in the mod reads a
-- flag, so that one edit turns the noise off.
--
-- Logging is local: it writes to the server's log and changes no game state, advances no
-- sequence number and reads nothing that differs between peers. It is safe to leave on.
--
-- Required as "__server-connector-mod__.control.debug". Required right after state, so every
-- module below it can call it.

local state = require("__server-connector-mod__.control.state")

-- The flag.
local DEBUG = true

-- A single JSON value is capped so one dump cannot swallow the log.
local MAX_JSON = 12000

local function enabled()
    return DEBUG
end

local function json(value)
    local ok, text = pcall(helpers.table_to_json, value)
    if not ok then
        return "<unserialisable: " .. tostring(text) .. ">"
    end
    text = tostring(text)
    if #text > MAX_JSON then
        return text:sub(1, MAX_JSON) .. "…<truncated " .. (#text - MAX_JSON) .. " chars>"
    end
    return text
end

-- One line. `fmt` is passed through pcall so a bad format cannot stop a server.
local function emit(fmt, ...)
    if not DEBUG then
        return
    end
    local text = fmt
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        text = ok and formatted or (tostring(fmt) .. " <format error>")
    end
    log(string.format("[debug][%s] %s", state.instance(), text))
end

local function dump(tag, value)
    if not DEBUG then
        return
    end
    emit("%s = %s", tostring(tag), json(value))
end

local function read(fn)
    local ok, value = pcall(fn)
    if not ok then
        return nil, tostring(value)
    end
    return value, nil
end

local function reverse(map)
    local out = {}
    for name, value in pairs(map or {}) do
        out[tostring(value)] = name
    end
    return out
end

local STATES, MEMBERS, SILO_STATUS, CONTROLLERS

local function ensure_maps()
    STATES = STATES or reverse(defines.space_platform_state)
    MEMBERS = MEMBERS or reverse(defines.logistic_member_index)
    SILO_STATUS = SILO_STATUS or reverse(defines.rocket_silo_status)
    CONTROLLERS = CONTROLLERS or reverse(defines.controllers)
end

-- Every readable field of a space platform, with the numeric state and status translated.
local function platform_table(p)
    ensure_maps()
    if not p then
        return nil
    end

    local state_value = (read(function() return p.state end))
    local hub = (read(function() return p.hub end))
    local surface = (read(function() return p.surface end))
    local location = (read(function() return p.space_location end))
    local connection = (read(function() return p.space_connection end))
    local pack = (read(function() return p.starter_pack end))

    return {
        name = (read(function() return p.name end)),
        index = (read(function() return p.index end)),
        valid = (read(function() return p.valid end)),
        state = tostring(state_value),
        state_name = STATES[tostring(state_value)] or "",
        hub_present = hub ~= nil,
        hub_name = hub and hub.name or nil,
        hub_destructible = hub and (read(function() return hub.destructible end)) or nil,
        surface_present = surface ~= nil,
        surface_name = surface and surface.name or nil,
        space_location = location and location.name or nil,
        space_connection = connection and connection.name or nil,
        last_visited = (read(function()
            local last = p.last_visited_space_location
            return last and last.name or nil
        end)),
        distance = (read(function() return p.distance end)),
        paused = (read(function() return p.paused end)),
        hidden = (read(function() return p.hidden end)),
        scheduled_for_deletion = (read(function() return p.scheduled_for_deletion end)),
        starter_pack = pack and {name = pack.name, quality = tostring(pack.quality)} or nil,
    }
end

-- The requester section of a rocket silo, read by the documented member name first.
local function request_detail(silo)
    ensure_maps()
    local point
    local named = defines.logistic_member_index and defines.logistic_member_index.rocket_silo_requester
    if named ~= nil then
        point = (read(function() return silo.get_logistic_point(named) end))
    end
    if not point then
        for _, value in pairs(defines.logistic_member_index or {}) do
            point = (read(function() return silo.get_logistic_point(value) end))
            if point then
                break
            end
        end
    end
    if not point then
        return {readable = false}
    end

    local out = {readable = true, sections = {}}
    for key, section in pairs(point.sections or {}) do
        local entry = {
            key = tostring(key),
            type = tostring(section.type),
            active = section.active,
            filters = {},
        }
        for index, filter in pairs(section.filters or {}) do
            local value = filter and filter.value
            entry.filters[#entry.filters + 1] = {
                index = tostring(index),
                item = value and value.name or nil,
                quality = value and tostring(value.quality) or nil,
                min = filter and filter.min,
                max = filter and filter.max,
            }
        end
        out.sections[#out.sections + 1] = entry
    end
    return out
end

-- Everything a rocket silo can say: status, the rocket inventory, and its requests.
local function silo_table(silo)
    ensure_maps()
    local status = (read(function() return silo.rocket_silo_status end))
    local rocket = (read(function()
        return silo.get_inventory(defines.inventory.rocket_silo_rocket)
    end))
    local stacks = {}
    if rocket then
        for slot = 1, #rocket do
            local stack = rocket[slot]
            if stack and stack.valid_for_read then
                stacks[#stacks + 1] = {slot = slot, item = stack.name, count = stack.count}
            end
        end
    end
    return {
        unit_number = silo.unit_number,
        surface = (read(function() return silo.surface.name end)),
        position = silo.position,
        status = tostring(status),
        status_name = SILO_STATUS[tostring(status)] or "",
        rocket = stacks,
        requests = request_detail(silo),
    }
end

local function surface_table(surface)
    if not surface then
        return nil
    end
    local platform = (read(function() return surface.platform end))
    local planet = (read(function() return surface.planet end))
    return {
        name = surface.name,
        index = surface.index,
        platform_present = platform ~= nil,
        platform_name = platform and platform.name or nil,
        planet_present = planet ~= nil,
        planet_name = planet and planet.name or nil,
    }
end

-- Anything in an event table reduced to JSON: Lua objects become name/object/valid.
local function describe(value, depth)
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then
        return value
    end
    if kind == "userdata" then
        local name = (read(function() return value.name end))
        local object = (read(function() return value.object_name end))
        if name ~= nil or object ~= nil then
            return {
                name = name,
                object = object,
                valid = (read(function() return value.valid end)),
            }
        end
        return tostring(value)
    end

    depth = (depth or 0) + 1
    if depth > 3 then
        return "<deep table>"
    end
    local out = {}
    for key, v in pairs(value) do
        local vk = type(v)
        if vk == "table" or vk == "userdata" then
            out[tostring(key)] = describe(v, depth)
        else
            out[tostring(key)] = v
        end
    end
    return out
end

local function event(name, data)
    if not DEBUG then
        return
    end
    dump("event " .. tostring(name), describe(data or {}))
end

local function call(fn, args, result)
    if not DEBUG then
        return
    end
    dump("call " .. tostring(fn) .. " args", args)
    dump("call " .. tostring(fn) .. " result", result)
end

local function push(kind, payload)
    if not DEBUG then
        return
    end
    dump("udp " .. tostring(kind), payload)
end

-- What this build and this save actually offer. Logged at boot, again whenever the identity
-- is pushed, because an absent event or a renamed member index is the first explanation for
-- anything that "does nothing".
local function boot()
    if not DEBUG then
        return
    end
    ensure_maps()

    local force = state.main_force()
    local mods = {}
    for name, version in pairs(game.active_mods or {}) do
        mods[#mods + 1] = tostring(name) .. "=" .. tostring(version)
    end
    table.sort(mods)

    local events = {}
    for _, name in ipairs({
        "on_space_platform_created",
        "on_space_platform_changed_state",
        "on_space_platform_built_entity",
        "on_surface_created",
        "on_entity_logistic_slot_changed",
        "on_player_joined_game",
        "on_player_left_game",
    }) do
        events[name] = defines.events[name] ~= nil
    end

    emit("boot: instance=%s known=%s tick=%s schema=%s own_entry=%s",
        tostring(state.instance()), tostring(state.known()), tostring(game.tick),
        tostring(storage.schema), json((storage.topology or {})[state.instance()] or {}))
    emit("boot: events=%s", json(events))
    emit("boot: space_platform_state=%s", json(reverse(defines.space_platform_state)))
    emit("boot: logistic_member_index=%s", json(reverse(defines.logistic_member_index)))
    emit("boot: rocket_silo_status=%s", json(reverse(defines.rocket_silo_status)))
    emit("boot: controllers=%s", json(reverse(defines.controllers)))
    emit("boot: capabilities create_space_platform=%s get_space_platforms=%s planets=%s force_platforms=%s",
        tostring(force and force.create_space_platform ~= nil),
        tostring(force and force.get_space_platforms ~= nil),
        tostring(game.planets ~= nil),
        tostring(force and force.platforms ~= nil))
    emit("boot: prototypes starter_pack=%s quality=%s",
        tostring(prototypes.item and prototypes.item["space-platform-starter-pack"] ~= nil),
        tostring(prototypes.quality ~= nil))
    emit("boot: mods=%s", table.concat(mods, ","))
    emit("boot: platforms=%s", json((function()
        local out = {}
        for _, p in pairs((force and force.platforms) or {}) do
            out[#out + 1] = platform_table(p)
        end
        table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
        return out
    end)()))
end

return {
    enabled = enabled,
    emit = emit,
    dump = dump,
    json = json,
    platform_table = platform_table,
    silo_table = silo_table,
    surface_table = surface_table,
    event = event,
    call = call,
    push = push,
    boot = boot,
}
