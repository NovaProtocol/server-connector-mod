-- server-connector-mod / control/pod.lua
--
-- Planet <-> platform cargo, across two saves.
--
-- The copy hub on a planet and the real hub on the space server are not the same inventory. A
-- cargo pod inside the planet's save changes only the copy; the real hub has to be told. Two
-- events are the whole of it:
--
--   on_cargo_pod_started_ascending / on_cargo_pod_finished_ascending
--       a pod left a copy hub -> remove the same cargo from the real hub.
--       a pod left a planet landing pad or a rocket silo -> remember the cargo; it is on its
--       way to a copy hub and must be added when it arrives.
--
--   on_cargo_pod_delivered_cargo
--       a pod arrived at a copy hub -> add the remembered cargo to the real hub.
--
-- The real space hubs are authoritative. A pod moving between them is the game's own
-- platform logistics and is ignored here.
--
-- The event is queued in storage and re-sent for 60 seconds. The manager de-duplicates by the
-- queue id for an hour, so a retry is harmless and a dropped localhost datagram is not a lost
-- cargo move. There is deliberately no RCON acknowledgement: an ack would write this storage
-- from outside the game while a player is connected, which is exactly the kind of client-side
-- divergence that desyncs.

local state = require("__server-connector-mod__.control.state")
local outbound = require("__server-connector-mod__.control.outbound")
local platform_api = require("__server-connector-mod__.control.platform_api")

local known = state.known
local instance = state.instance
local main_force = state.main_force

local QUEUE_TTL = 60 * 60          -- 60 seconds, in ticks
local CARGO_TTL = 10 * 60 * 60     -- 10 minutes for an unfinished pod record

local function ensure()
    storage.pod_queue = storage.pod_queue or {}
    storage.pod_cargo = storage.pod_cargo or {}
end

local function platform_of(entity)
    if not entity or not entity.valid then
        return nil
    end
    local surface = entity.surface
    return surface and surface.platform or nil
end

-- Which of several same-named platforms this is, in index order. The manager pairs the real
-- and copy platforms the same way.
local function descriptor(platform)
    if not platform or not platform.valid then
        return nil
    end
    local group = {}
    for _, candidate in pairs(main_force().platforms or {}) do
        if candidate.name == platform.name then
            group[#group + 1] = candidate
        end
    end
    table.sort(group, function(a, b) return a.index < b.index end)
    for index, candidate in ipairs(group) do
        if candidate.index == platform.index then
            return {name = platform.name, ordinal = index}
        end
    end
    return nil
end

local function is_copy_hub(entity)
    return entity ~= nil
        and entity.valid
        and instance() ~= "space"
        and entity.name == "space-platform-hub"
        and platform_of(entity) ~= nil
end

local function is_station(entity)
    return entity ~= nil and entity.valid
        and (entity.name == "cargo-landing-pad" or entity.name == "space-platform-hub")
end

-- A cargo pod's inventory. The game calls it cargo_unit; a build that does not answer that
-- name is searched rather than guessed.
local function pod_cargo(pod)
    if not pod or not pod.valid then
        return {}
    end

    local inventory = nil
    for _, name in ipairs({"cargo_unit", "cargo"}) do
        local ok, candidate = pcall(function()
            return pod.get_inventory(defines.inventory[name])
        end)
        if ok and candidate then
            inventory = candidate
            break
        end
    end

    if not inventory then
        local ok, last = pcall(function() return pod.get_max_inventory_index() end)
        if ok and last then
            for index = 1, last do
                local got, candidate = pcall(function() return pod.get_inventory(index) end)
                if got and candidate and #candidate > 0 then
                    inventory = candidate
                    break
                end
            end
        end
    end

    local cargo = {}
    if not inventory then
        return cargo
    end
    for index = 1, #inventory do
        local stack = inventory[index]
        if stack and stack.valid_for_read and stack.count > 0 then
            cargo[#cargo + 1] = {
                item = stack.name,
                quality = stack.quality and stack.quality.name or "normal",
                count = stack.count,
            }
        end
    end
    return cargo
end

local function event_id(unit, direction)
    return string.format("%s:%s:%s", instance(), tostring(unit), direction)
end

local function enqueue(direction, desc, cargo, unit)
    if not desc or #cargo == 0 then
        return
    end
    ensure()
    local id = event_id(unit, direction)
    local entry = {
        id = id,
        direction = direction,
        platform = desc,
        cargo = cargo,
        tick = game.tick,
        at = game.tick,
    }
    storage.pod_queue[id] = entry
    outbound.push("platform_pod", entry)
end

-- A pod has left a platform hub or a surface. If the source is a copy hub, the cargo has left
-- the copy and must leave the real hub. If it left a planet, remember it for delivery.
local function started(event)
    if not known() then
        return
    end
    local pod = event and event.cargo_pod
    if not pod or not pod.valid then
        return
    end

    local origin = pod.cargo_pod_origin
    if is_copy_hub(origin) then
        local platform = platform_of(origin)
        local cargo = pod_cargo(pod)
        if platform and #cargo > 0 then
            enqueue("remove", descriptor(platform), cargo, pod.unit_number)
        end
        return
    end

    -- A planet landing pad or rocket silo: the pod is on its way to a copy hub.
    local destination = pod.cargo_pod_destination
    local station = destination and destination.type == defines.cargo_destination.station
        and destination.station or nil
    if is_copy_hub(station) then
        local platform = platform_of(station)
        local cargo = pod_cargo(pod)
        if platform and #cargo > 0 then
            ensure()
            storage.pod_cargo[pod.unit_number] = {
                platform = descriptor(platform),
                cargo = cargo,
                at = game.tick,
            }
        end
    end
end

local function delivered(event)
    if not known() then
        return
    end
    local pod = event and event.cargo_pod
    local unit = pod and pod.unit_number or nil
    if not unit then
        return
    end

    ensure()
    local record = storage.pod_cargo[unit]
    if not record then
        return
    end
    enqueue("add", record.platform, record.cargo, unit)
    storage.pod_cargo[unit] = nil
end

-- Re-send the queue for a minute. The manager de-duplicates, so this is safe; the storage
-- write happens on every peer because the tick is deterministic.
local function tick()
    ensure()
    local now = game.tick
    for id, entry in pairs(storage.pod_queue) do
        if now - (entry.at or now) > QUEUE_TTL then
            storage.pod_queue[id] = nil
        else
            outbound.push("platform_pod", entry)
        end
    end
    for unit, record in pairs(storage.pod_cargo) do
        if now - (record.at or now) > CARGO_TTL then
            storage.pod_cargo[unit] = nil
        end
    end
end

local function find_platform(name)
    for _, platform in pairs(main_force().platforms or {}) do
        if platform.name == name then
            return platform
        end
    end
    return nil
end

local function find_landing_pad()
    local surface = game.surfaces[instance()]
    if not surface then
        return nil
    end
    local ok, pads = pcall(function()
        return surface.find_entities_filtered{name = "cargo-landing-pad"}
    end)
    if ok and pads then
        return pads[1]
    end
    return nil
end

local function available_hatch(entity)
    local ok, hatches = pcall(function() return entity.cargo_hatches end)
    if not ok or not hatches then
        return nil, 0
    end
    local count = #hatches
    for _, hatch in ipairs(hatches) do
        local valid, reserved, busy, input = false, true, true, false
        pcall(function() valid = hatch.valid end)
        pcall(function() reserved = hatch.reserved end)
        pcall(function() busy = hatch.busy end)
        pcall(function() input = hatch.is_input_compatible end)
        if valid and not reserved and not busy and input then
            return hatch, count
        end
    end
    return nil, count
end

local function find_rocket_silo()
    local surface = game.surfaces[instance()]
    if not surface then
        return nil
    end
    local ok, silos = pcall(function()
        return surface.find_entities_filtered{name = "rocket-silo"}
    end)
    if not ok or not silos then
        return nil
    end
    local first = nil
    for _, silo in ipairs(silos) do
        if not first then first = silo end
        local ready, status = pcall(function() return silo.rocket_silo_status end)
        if ready and defines.rocket_silo_status.rocket_ready
            and status == defines.rocket_silo_status.rocket_ready then
            return silo
        end
    end
    return first
end

local function insert_cargo(pod, item, count)
    local inventory
    for _, name in ipairs({"cargo_unit", "cargo"}) do
        local ok, candidate = pcall(function()
            return pod.get_inventory(defines.inventory[name])
        end)
        if ok and candidate then
            inventory = candidate
            break
        end
    end
    if not inventory then
        return false
    end
    return (inventory.insert{name = item, count = count, quality = "normal"} or 0) > 0
end

-- Test helpers, reachable with server-connector-mod-podtest. They create real cargo pods in
-- the planet's save; the normal event handlers do the bridge.
local function test(kind, platform_name, item, count)
    if not known() then
        return {ok = false, error = "no identity"}
    end

    if kind == "space_platform_to_platform" then
        if instance() ~= "space" then
            return {ok = false, error = "run this one on the space server"}
        end
        local source = find_platform(platform_name)
        local destination = find_platform(item) -- item is the destination platform name
        if not source or not destination then
            return {ok = false, error = "source or destination platform not found"}
        end
        if not source.hub or not destination.hub then
            return {ok = false, error = "both platforms need a hub"}
        end
        local inventory = platform_api.hub_inventory(source.hub)
        local removed = inventory and inventory.remove{name = "space-platform-foundation", count = count, quality = "normal"} or 0
        if removed < count then
            return {ok = false, error = "source hub does not hold enough space-platform-foundation"}
        end
        local pod = source.hub.create_cargo_pod{}
        if not pod then
            return {ok = false, error = "the game did not create a cargo pod"}
        end
        insert_cargo(pod, "space-platform-foundation", count)
        local hatch, hatches = available_hatch(destination.hub)
        if not hatch then
            return {ok = false, error = "no free input hatch on the destination hub (" .. tostring(hatches) .. ")"}
        end
        pod.cargo_pod_destination = {type = defines.cargo_destination.station, station = destination.hub, hatch = hatch}
        local state = pod.cargo_pod_state
        log(string.format("[%s] podtest %s %s to %s x%d, pod %s state %s",
            instance(), kind, platform_name, item, count, tostring(pod.unit_number), tostring(state)))
        return {ok = true, pod = pod.unit_number, state = state}
    end

    if instance() == "space" then
        return {ok = false, error = "run the pod test on a planet"}
    end

    local platform = find_platform(platform_name)
    if not platform then
        return {ok = false, error = "no such platform on this server"}
    end
    local hub = platform.hub
    if not hub or not hub.valid then
        return {ok = false, error = "the copy has no hub"}
    end

    if kind == "report" then
        local pad = find_landing_pad()
        local pad_cargo = {}
        if pad then
            local ok, inventory = pcall(function()
                return pad.get_inventory(defines.inventory.cargo_landing_pad_main)
            end)
            if ok and inventory then
                for index = 1, #inventory do
                    local stack = inventory[index]
                    if stack and stack.valid_for_read and stack.count > 0 then
                        pad_cargo[#pad_cargo + 1] = {
                            item = stack.name,
                            quality = stack.quality and stack.quality.name or "normal",
                            count = stack.count,
                        }
                    end
                end
            end
        end
        local copy = platform_api.cargo(platform)
        local result = {ok = true, copy = copy, pad = pad_cargo, pad_found = pad ~= nil}
        log(string.format("[%s] podtest report %s: %s", instance(), platform_name,
            helpers.table_to_json(result)))
        return result
    end

    if kind == "rocket_to_platform" then
        local silo = find_rocket_silo()
        if not silo then
            return {ok = false, error = "no rocket silo on this planet"}
        end
        local rocket = silo.get_inventory(defines.inventory.rocket_silo_rocket)
        if not rocket then
            return {ok = false, error = "the silo has no rocket inventory"}
        end
        local inserted = rocket.insert{name = item, count = count, quality = "normal"} or 0
        if inserted < count then
            return {ok = false, error = "the silo rocket did not accept the cargo"}
        end
        local hatch, hatches = available_hatch(hub)
        if not hatch then
            return {ok = false, error = "no free input hatch on the copy hub (" .. tostring(hatches) .. " hatches)"}
        end
        local destination = {type = defines.cargo_destination.station, station = hub, hatch = hatch}
        local launched, result = pcall(function() return silo.launch_rocket(destination) end)
        log(string.format("[%s] podtest rocket_to_platform %s x%d on %s: %s %s",
            instance(), item, count, platform_name, tostring(launched), tostring(result)))
        if not launched or result == false then
            return {ok = false, error = "launch_rocket refused: " .. tostring(result)}
        end
        return {ok = true, status = silo.rocket_silo_status}
    end

    if kind == "cleanup" then
        local units = {373150022, 373150164, 373151285, 373151550, 373151598, 373152448, 373152952, 373152973}
        local wanted = {}
        for _, unit in ipairs(units) do wanted[unit] = true end
        local destroyed = {}
        local surface = game.surfaces[instance()]
        if surface then
            local ok, pods = pcall(function()
                return surface.find_entities_filtered{type = "cargo-pod"}
            end)
            for _, entity in ipairs((ok and pods) or {}) do
                if entity.valid and wanted[entity.unit_number] then
                    destroyed[#destroyed + 1] = entity.unit_number
                    pcall(function() entity.destroy() end)
                end
            end
        end
        log(string.format("[%s] podtest cleanup destroyed %s", instance(),
            helpers.table_to_json(destroyed)))
        return {ok = true, destroyed = destroyed}
    end

    if kind == "force_drop" then
        pcall(function()
            hub.destructible = true
            hub.minable_flag = true
            hub.operable = true
        end)
        local inventory = platform_api.hub_inventory(hub)
        local removed = inventory and inventory.remove{name = item, count = count, quality = "normal"} or 0
        if removed < count then
            return {ok = false, error = "the copy hub does not hold enough " .. item}
        end
        local pod = hub.create_cargo_pod{}
        if not pod then
            return {ok = false, error = "the game did not create a cargo pod"}
        end
        insert_cargo(pod, item, count)
        local surface = game.surfaces[instance()]
        pod.cargo_pod_destination = {
            type = defines.cargo_destination.surface,
            surface = surface.name,
            position = {x = 0, y = 0},
        }
        log(string.format("[%s] podtest force_drop %s x%d from %s, pod %s state %s",
            instance(), item, count, platform_name, tostring(pod.unit_number), tostring(pod.cargo_pod_state)))
        return {ok = true, pod = pod.unit_number, state = pod.cargo_pod_state}
    end

    if kind == "synthetic_add" or kind == "synthetic_remove" then
        local direction = kind == "synthetic_add" and "add" or "remove"
        local desc = descriptor(platform)
        local cargo = {{item = item, quality = "normal", count = count}}
        local id = string.format("%s:test:%d:%s", instance(), game.tick, direction)
        ensure()
        local entry = {
            id = id, direction = direction, platform = desc, cargo = cargo,
            tick = game.tick, at = game.tick,
        }
        storage.pod_queue[id] = entry
        outbound.push("platform_pod", entry)
        log(string.format("[%s] podtest %s %s x%d on %s", instance(), direction, item, count, platform_name))
        return {ok = true, id = id}
    end

    local pad = find_landing_pad()
    if not pad then
        return {ok = false, error = "no cargo landing pad on this planet"}
    end
    local silo = find_rocket_silo()
    if kind == "planet_to_platform" and not silo then
        return {ok = false, error = "no rocket silo on this planet"}
    end

    local pod
    if kind == "planet_to_platform" then
        -- The game will not use a non-operable hub as a cargo station. Test the hypothesis
        -- before deciding how to keep the hub read-only for players and usable for pods.
        pcall(function()
            hub.destructible = true
            hub.minable_flag = true
            hub.operable = true
        end)
        log(string.format("[%s] podtest hub destructible=%s minable=%s operable=%s",
            instance(), tostring(hub.destructible), tostring(hub.minable_flag), tostring(hub.operable)))
        pod = silo and silo.create_cargo_pod{} or nil
        if not pod then
            pod = pad.create_cargo_pod{}
        end
        if pod and insert_cargo(pod, item, count) then
            local hatch, hatches = available_hatch(hub)
            if hatch then
                pod.cargo_pod_destination = {type = defines.cargo_destination.station, station = hub, hatch = hatch}
            else
                return {ok = false, error = "no free input hatch on the copy hub (" .. tostring(hatches) .. " hatches)"}
            end
        end
    elseif kind == "platform_to_planet" then
        pcall(function()
            pad.destructible = true
            pad.minable_flag = true
            pad.operable = true
            hub.destructible = true
            hub.minable_flag = true
            hub.operable = true
        end)
        pod = hub.create_cargo_pod{}
        if pod then
            local inventory = platform_api.hub_inventory(hub)
            local removed = inventory and inventory.remove{name = item, count = count, quality = "normal"} or 0
            if removed < count then
                return {ok = false, error = "the copy hub does not hold enough " .. item}
            end
            insert_cargo(pod, item, count)
            local hatch, hatches = available_hatch(pad)
            if hatch then
                pod.cargo_pod_destination = {type = defines.cargo_destination.station, station = pad, hatch = hatch}
            else
                return {ok = false, error = "no free input hatch on the landing pad (" .. tostring(hatches) .. " hatches)"}
            end
        end
    else
        return {ok = false, error = "kind must be planet_to_platform or platform_to_planet"}
    end

    if not pod then
        return {ok = false, error = "the game did not create a cargo pod"}
    end
    local hub_hatches = hub.cargo_hatches and #hub.cargo_hatches or -1
    local pad_hatches = pad.cargo_hatches and #pad.cargo_hatches or -1
    local destination = nil
    pcall(function() destination = pod.cargo_pod_destination end)
    log(string.format("[%s] podtest %s %s x%d on %s, pod %s state %s hub_hatches %d pad_hatches %d",
        instance(), kind, item, count, platform_name, tostring(pod.unit_number),
        tostring(pod.cargo_pod_state), hub_hatches, pad_hatches))
    return {
        ok = true,
        pod = pod.unit_number,
        state = pod.cargo_pod_state,
        destination = destination,
        hub_hatches = hub_hatches,
        pad_hatches = pad_hatches,
    }
end

return {
    started = started,
    delivered = delivered,
    tick = tick,
    test = test,
}
