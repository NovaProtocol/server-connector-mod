-- server-connector-mod / control/connector.lua
--
-- One connector platform per planet, mirrored between the planet save and the space save.
--
-- The planet holds a platform named "Space Platforms"; the space server holds the same
-- platform as "[planet=<id>] <Planet> Hub". Both are writable. An edit on either side is
-- pushed over UDP, the manager applies the same change to the counterpart over RCON, and
-- the counterpart's hub weight is the receipt: a weight that does not match means the
-- mirror missed something, and the manager re-reads that one platform.
--
-- Only the hub and cargo bays may exist on a connector. Anything else a player builds is
-- mined away, so the item comes back to the player rather than disappearing.
--
-- There is no polling here. Request edits come from on_entity_logistic_slot_changed; group
-- existence is re-asserted whenever a slot changes and at boot, so a deleted or renamed
-- group is corrected at the next edit rather than on a timer.
--
-- Required after platforms and platform_api, before events and rcon.

local state = require("__server-connector-mod__.control.state")
local debug = require("__server-connector-mod__.control.debug")
local bus = require("__server-connector-mod__.control.bus")
local platforms = require("__server-connector-mod__.control.platforms")
local platform_api = require("__server-connector-mod__.control.platform_api")

local PLANET_PLATFORM_NAME = "Space Platforms"
local SPACE_ICON = "[space-location=solar-system-edge]"
local INCOMING = "Incoming (Space to Planet)"
local OUTGOING = "Outgoing (Planet to Space)"

local INSTANCE = state.instance

-- Forward declarations: these are called by functions defined above them. A local declared
-- later is a nil global to an earlier body, which is a runtime error the parser cannot see.
local enforce_platform
local inventory_insert
local inventory_remove

local function role()
    return INSTANCE() == "space" and "space" or "planet"
end

local function force()
    return state.main_force()
end

local function known()
    return state.known()
end

local function storage_ready()
    storage.connector_clock = storage.connector_clock or 0
    storage.connector_dirty = storage.connector_dirty or {}
    storage.connector_events = storage.connector_events or {}
    storage.connector_deleted = storage.connector_deleted or {}
end

local function record(kind, detail)
    storage_ready()
    local log = storage.connector_events
    log[#log + 1] = {kind = kind, detail = detail, tick = game.tick}
    while #log > 60 do
        table.remove(log, 1)
    end
end

local function display_name(id)
    -- The planet id is the stable half of every connector name. The manager's topology
    -- label can change; the name the converter seeds and the name the mod looks for must
    -- not. Capitalise the id and leave it alone.
    return id:sub(1, 1):upper() .. id:sub(2)
end

local function connector_name(planet)
    if role() == "planet" then
        return PLANET_PLATFORM_NAME
    end
    return string.format("[planet=%s] %s Hub", planet, display_name(planet))
end

local function group_names(planet)
    if role() == "planet" then
        return INCOMING, OUTGOING
    end
    return string.format("%s Space to [planet=%s] %s", SPACE_ICON, planet, display_name(planet)),
        string.format("[planet=%s] %s to %s Space", planet, display_name(planet), SPACE_ICON)
end

-- Which planet a platform belongs to. On a planet that is the instance; on space it is
-- where the platform is, and the name is the fallback when the location is not readable.
local function planet_of(platform)
    if role() == "planet" then
        return INSTANCE()
    end
    if not platform then
        return nil
    end
    local location = platform.space_location
    if location and location.name then
        return location.name
    end
    return string.match(tostring(platform.name), "^%[planet=([^%]]+)%]")
end

local function is_connector(platform)
    if not platform or not platform.valid then
        return false
    end
    -- The creation event can fire before space_location is readable. Remembering the name
    -- being created is what stops the event handler from deleting the platform it is
    -- looking at.
    if storage.connector_creating == platform.name then
        return true
    end
    local planet = planet_of(platform)
    if not planet then
        return false
    end
    return platform.name == connector_name(planet)
end

local function find_connector(planet)
    if not planet then
        return nil
    end
    if role() == "planet" and planet ~= INSTANCE() then
        return nil
    end
    local want = connector_name(planet)
    for _, platform in pairs(force().platforms or {}) do
        if platform.valid and platform.name == want then
            return platform
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- sections and filters
--------------------------------------------------------------------------------

-- A LogisticFilter as the manager carries it. The source is part of the filter in 2.1
-- (request_from / import_from); it is what makes "Incoming is platform-sourced" a real
-- setting rather than a label.
local function quality_name(value)
    if value == nil then
        return "normal"
    end
    if type(value) == "string" then
        return value
    end
    local ok, name = pcall(function() return value.name end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return "normal"
end

local function text(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    local ok, name = pcall(function() return value.name end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

local function filter_out(filter)
    local value = filter and filter.value
    if not value or not value.name then
        return nil
    end
    local count = tonumber(filter.min) or 0
    if count <= 0 then
        return nil
    end
    return {
        item = value.name,
        quality = quality_name(value.quality),
        count = count,
        max_count = filter.max,
        request_from = filter.request_from,
        import_from = text(filter.import_from),
        minimum_delivery_count = filter.minimum_delivery_count,
    }
end

local function read_section(point, name)
    if not point then
        return {}, false
    end
    local found = nil
    for _, section in pairs(point.sections or {}) do
        if section.is_manual and section.group == name then
            found = section
            break
        end
    end
    if not found then
        return {}, false
    end
    local out = {}
    for _, filter in pairs(found.filters or {}) do
        local entry = filter_out(filter)
        if entry then
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a, b)
        if a.item ~= b.item then return a.item < b.item end
        return a.quality < b.quality
    end)
    return out, true
end

local function find_section(point, name)
    for _, section in pairs(point.sections or {}) do
        if section.is_manual and section.group == name then
            return section
        end
    end
    return nil
end

local function ensure_section(point, name)
    local section = find_section(point, name)
    if section then
        return section
    end
    local ok, created = pcall(function() return point.add_section(name) end)
    if ok and created then
        pcall(function() created.group = name end)
        return created
    end
    ok, created = pcall(function() return point.add_section() end)
    if ok and created then
        pcall(function() created.group = name end)
        return created
    end
    return nil
end

-- Build the filter array for one group. The source is forced here, not trusted from the
-- caller: Incoming is always platform-sourced, Outgoing is always planet-sourced with the
-- correct planet. max is nil on purpose: a finite maximum is what makes a platform
-- offload the excess to a planet below, and a fake planet surface on the space server is
-- exactly where that cargo used to be dropped.
local function build_filters(list, source, planet)
    local out = {}
    for _, entry in ipairs(list or {}) do
        local count = math.floor(tonumber(entry.count) or 0)
        local item = entry.item or entry.name
        if item and count > 0 then
            out[#out + 1] = {
                value = {
                    type = "item",
                    name = item,
                    quality = entry.quality or "normal",
                },
                min = count,
                max = nil,
                request_from = source,
                -- The planet selector is the planet itself, not whatever the player picked.
                -- "from all" and "from the wrong planet" are the two states the rule exists
                -- to prevent.
                import_from = (source == "planet") and planet or nil,
                minimum_delivery_count = entry.minimum_delivery_count,
            }
        end
    end
    return out
end

local function begin_write()
    storage_ready()
    storage.connector_writing = (storage.connector_writing or 0) + 1
end

local function end_write()
    storage.connector_writing = math.max(0, (storage.connector_writing or 1) - 1)
end

local function write_section(point, name, filters)
    local section = ensure_section(point, name)
    if not section then
        return false, "no manual section"
    end
    pcall(function() section.group = name end)

    local ok, err = pcall(function() section.filters = filters end)
    if ok then
        return true
    end
    log(string.format("[%s] writing %s failed: %s", INSTANCE(), name, tostring(err)))

    -- A logistic point that is not a space platform may refuse the source fields. The
    -- request itself is still the order; write the shape it accepts rather than nothing.
    local plain = {}
    for index, entry in ipairs(filters) do
        plain[index] = {value = entry.value, min = entry.min, max = entry.max}
    end
    local fallback, fallback_err = pcall(function() section.filters = plain end)
    if not fallback then
        log(string.format("[%s] writing %s without source failed: %s",
            INSTANCE(), name, tostring(fallback_err)))
    end
    return fallback
end

--------------------------------------------------------------------------------
-- the landing pad
--------------------------------------------------------------------------------

local function pads()
    local surface = game.surfaces[INSTANCE()]
    if not surface then
        return {}
    end
    local ok, list = pcall(function()
        return surface.find_entities_filtered{name = "cargo-landing-pad"}
    end)
    return ok and list or {}
end

local function pad_point(pad)
    if not pad or not pad.valid then
        return nil
    end
    if storage.pad_member ~= nil then
        local ok, point = pcall(function() return pad.get_logistic_point(storage.pad_member) end)
        if ok and point then
            return point
        end
        storage.pad_member = nil
    end
    for _, name in ipairs({"logistic_container", "requester", "hub_main"}) do
        local value = defines.logistic_member_index and defines.logistic_member_index[name]
        if value ~= nil then
            local ok, point = pcall(function() return pad.get_logistic_point(value) end)
            if ok and point then
                storage.pad_member = value
                return point
            end
        end
    end
    for _, value in pairs(defines.logistic_member_index or {}) do
        local ok, point = pcall(function() return pad.get_logistic_point(value) end)
        if ok and point then
            storage.pad_member = value
            return point
        end
    end
    return nil
end

local function enforce_pad(pad, incoming, planet)
    local point = pad_point(pad)
    if not point then
        return false
    end

    -- A pad set to trash unrequested items pushes its whole inventory into the platform as
    -- soon as a request is added. The pad is a request point, not a disposal point.
    pcall(function() point.trash_not_requested = false end)

    begin_write()
    -- Only the Incoming group. Removing from the highest index down keeps the indices
    -- stable while the list shrinks.
    local indices = {}
    for index, section in pairs(point.sections or {}) do
        if not (section.is_manual and section.group == INCOMING) then
            indices[#indices + 1] = index
        end
    end
    table.sort(indices, function(a, b) return a > b end)
    for _, index in ipairs(indices) do
        pcall(function() point.remove_section(index) end)
    end

    local wrote = write_section(point, INCOMING, build_filters(incoming, "platforms", planet))
    end_write()
    return wrote
end

local function pad_requests()
    for _, pad in ipairs(pads()) do
        local point = pad_point(pad)
        if point then
            return read_section(point, INCOMING), true
        end
    end
    return {}, false
end

--------------------------------------------------------------------------------
-- protection and existence
--------------------------------------------------------------------------------

-- Damage immunity, not a locked door: the hub and bays can still be mined (that is how a
-- player deletes the platform) and the hub stays operable so its requests can be edited.
local function protect(platform)
    local function one(entity)
        if entity and entity.valid then
            pcall(function()
                entity.destructible = false
                entity.minable_flag = true
                entity.operable = true
            end)
        end
    end
    one(platform.hub)
    for _, bay in ipairs(platforms.bay_list(platform) or {}) do
        one(bay)
    end
end

local function create_platform(planet)
    local name = connector_name(planet)
    -- The creation event fires before this call returns, and a handler that also asks for
    -- ensure would otherwise create a second platform under the same name.
    if storage.connector_creating == name then
        return nil
    end
    local existing = find_connector(planet)
    if existing then
        -- A platform already scheduled for deletion is on its way out. Creating one under
        -- the same name now is refused until it is gone, so the retry queue is the safe
        -- path: try again a few ticks later instead of failing silently.
        if (existing.scheduled_for_deletion or 0) == 0 then
            return existing
        end
        storage.connector_retry = storage.connector_retry or {}
        storage.connector_retry[planet] = game.tick + 10
        return nil
    end

    storage.connector_creating = name
    local ok, created = pcall(function()
        return force().create_space_platform{
            planet = planet,
            name = name,
            starter_pack = "space-platform-starter-pack",
        }
    end)
    storage.connector_creating = nil
    if not ok or not created then
        log(string.format("[%s] could not create connector %s at %s: %s",
            INSTANCE(), name, planet, tostring(created)))
        record("create-failed", {planet = planet, error = tostring(created)})
        return nil
    end

    local applied, hub = pcall(function() return created.apply_starter_pack(true) end)
    if not applied or not hub then
        log(string.format("[%s] connector %s has no hub; removing it", INSTANCE(), name))
        pcall(function() created.destroy(1) end)
        return nil
    end

    pcall(function() created.destroy_asteroid_chunks{} end)
    protect(created)
    record("created", {planet = planet, name = name})
    log(string.format("[%s] created connector %s at %s", INSTANCE(), name, planet))
    return created
end

local function remove(platform, why)
    if not platform or not platform.valid then
        return true
    end
    if platform.hub then
        pcall(function() platform.hub.destructible = true end)
        pcall(function() platform.hub.minable_flag = true end)
    end
    for _, bay in ipairs(platforms.bay_list(platform) or {}) do
        pcall(function() bay.destructible = true end)
        pcall(function() bay.minable_flag = true end)
    end
    pcall(function() platform.cancel_deletion() end)
    local ok, err = pcall(function() platform.destroy(2) end)
    if not ok then
        log(string.format("[%s] could not remove %s: %s",
            INSTANCE(), tostring(platform.name), tostring(err)))
    else
        record("removed", {name = platform.name, why = why})
    end
    return ok
end

local function ensure_one(planet)
    if not known() then
        return nil
    end
    if role() == "planet" and planet ~= INSTANCE() then
        return nil
    end
    return create_platform(planet)
end

local function planets()
    local out = {}
    for id, entry in pairs(storage.topology or {}) do
        if entry.kind == "planet" then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- A platform that is not the connector for its planet is a duplicate: a starter pack that
-- was launched, an older copy, or a platform made before this design. It goes, and the
-- connector is made again. The spec is one platform per planet.
local function ensure_all()
    if not known() then
        return {ok = false, skipped = "no identity"}
    end
    storage_ready()

    local made = {}
    if role() == "planet" then
        local connector = create_platform(INSTANCE())
        if connector then
            made[#made + 1] = connector.name
        end
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and platform.name ~= PLANET_PLATFORM_NAME then
                remove(platform, "not the connector")
            end
        end
        for _, platform in pairs(force().platforms or {}) do
            if is_connector(platform) then
                protect(platform)
                local point = platform_api.request_point(platform.hub)
                local in_name, out_name = group_names(INSTANCE())
                local incoming, pad_found = pad_requests()
                if not pad_found then
                    -- No landing pad yet: keep the group that is there rather than
                    -- replacing it with an empty list.
                    incoming = read_section(point, in_name)
                end
                local outgoing = read_section(point, out_name)
                enforce_platform(platform, incoming, outgoing, INSTANCE())
                for _, pad in ipairs(pads()) do
                    enforce_pad(pad, incoming, INSTANCE())
                end
            end
        end
    else
        -- Without a topology there is no list of planets to keep, and pruning on an empty
        -- list would remove every platform on the space server -- including the connectors
        -- the converter just made. set_instance arrives before set_topology, so this is a
        -- real boot order, not a hypothetical.
        local wantedPlanets = planets()
        if #wantedPlanets == 0 then
            return {ok = false, skipped = "no topology"}
        end
        for _, planet in ipairs(wantedPlanets) do
            local connector = create_platform(planet)
            if connector then
                made[#made + 1] = connector.name
            end
        end
        local wanted = {}
        for _, planet in ipairs(wantedPlanets) do
            wanted[connector_name(planet)] = true
        end
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and not wanted[platform.name] then
                remove(platform, "not a connector")
            end
        end
        for _, platform in pairs(force().platforms or {}) do
            if is_connector(platform) then
                protect(platform)
                local planet = planet_of(platform)
                local point = platform_api.request_point(platform.hub)
                local in_name, out_name = group_names(planet)
                local incoming = read_section(point, in_name)
                local outgoing = read_section(point, out_name)
                enforce_platform(platform, incoming, outgoing, planet)
            end
        end
    end

    return {ok = true, role = role(), made = table.concat(made, ",")}
end

enforce_platform = function(platform, incoming, outgoing, planet)
    local point = platform_api.request_point(platform.hub)
    if not point then
        return false
    end
    -- Keep what nobody asked for. A hub left on the default trash setting ejects the
    -- starter-pack foundation over time, and the loss looks like a cargo sync bug.
    pcall(function() point.trash_not_requested = false end)
    begin_write()
    local in_name, out_name = group_names(planet)
    local wrote_in = write_section(point, in_name, build_filters(incoming, "platforms", planet))
    local wrote_out = write_section(point, out_name, build_filters(outgoing, "planet", planet))

    -- Any other manual group on the connector keeps its filters but loses its maximum. A
    -- finite maximum is what makes a hub offload the excess to the planet below, and on the
    -- space server the planet below is a stale surface with a landing pad.
    for _, section in pairs(point.sections or {}) do
        if section.is_manual and section.group ~= in_name and section.group ~= out_name then
            local filters = {}
            local changed = false
            for _, filter in pairs(section.filters or {}) do
                if filter.max ~= nil then
                    changed = true
                end
                filters[#filters + 1] = {
                    value = filter.value,
                    min = filter.min,
                    max = nil,
                    request_from = filter.request_from,
                    import_from = filter.import_from,
                    minimum_delivery_count = filter.minimum_delivery_count,
                }
            end
            if changed then
                pcall(function() section.filters = filters end)
            end
        end
    end
    end_write()
    return wrote_in and wrote_out
end

--------------------------------------------------------------------------------
-- state and apply
--------------------------------------------------------------------------------

local function cargo_of(platform)
    return platform_api.cargo(platform)
end

local function read_state(platform, with_cargo)
    local planet = planet_of(platform)
    local point = platform_api.request_point(platform.hub)
    local in_name, out_name = group_names(planet)
    local incoming = read_section(point, in_name)
    local outgoing = read_section(point, out_name)
    local inventory = platform_api.hub_inventory(platform.hub)
    local st = {
        planet = planet,
        role = role(),
        name = platform.name,
        exists = true,
        clock = storage.connector_clock or 0,
        weight = inventory and inventory.weight or nil,
        -- A request or bay edit deliberately carries no cargo. Sending a stale full list
        -- with a request edit is how a request change would undo a pod that landed between
        -- the read and the apply. has_cargo separates "not sent" from "sent and empty".
        cargo = with_cargo and cargo_of(platform) or nil,
        has_cargo = with_cargo or false,
        -- An empty request list is a real state, not "nothing to say". Without this the
        -- manager's empty apply is skipped and a request cleared on one side stays on the
        -- other for ever.
        has_requests = true,
        bays = platforms.bay_count(platform),
        layout = platforms.layout_of(platform),
        incoming = incoming,
        outgoing = outgoing,
        pad = role() == "planet" and pad_requests() or {},
        groups_ok = find_section(point, in_name) ~= nil and find_section(point, out_name) ~= nil,
    }
    return st
end

local function state_of(planet, with_cargo)
    storage_ready()
    local platform = find_connector(planet)
    if not platform then
        return {
            ok = true,
            exists = false,
            planet = planet,
            role = role(),
            clock = storage.connector_clock or 0,
            incoming = {},
            outgoing = {},
            pad = role() == "planet" and pad_requests() or {},
        }
    end
    local st = read_state(platform, with_cargo)
    st.ok = true
    return st
end

-- The manager's read: always the whole picture, cargo included.
local function state(planet)
    return state_of(planet, true)
end

local function sync_cargo(platform, target)
    local inventory = platform_api.hub_inventory(platform.hub)
    if not inventory then
        return 0
    end

    local function key(entry)
        return tostring(entry.item or entry.name) .. "|" .. tostring(entry.quality or "normal")
    end

    local current, wanted, meta = {}, {}, {}
    for _, entry in ipairs(cargo_of(platform)) do
        local k = key(entry)
        current[k] = (current[k] or 0) + (tonumber(entry.count) or 0)
        meta[k] = {item = entry.item, quality = entry.quality}
    end
    for _, entry in ipairs(target or {}) do
        local k = key(entry)
        wanted[k] = (wanted[k] or 0) + (tonumber(entry.count) or 0)
        meta[k] = {item = entry.item or entry.name, quality = entry.quality or "normal"}
    end

    local applied = 0
    for k, count in pairs(wanted) do
        local have = current[k] or 0
        if count > have then
            local changed = inventory.insert{
                name = meta[k].item,
                quality = meta[k].quality,
                count = count - have,
            }
            if changed and changed > 0 then
                applied = applied + 1
            end
        end
    end
    for k, count in pairs(current) do
        local want = wanted[k] or 0
        if count > want then
            local changed = inventory.remove{
                name = meta[k].item,
                quality = meta[k].quality,
                count = count - want,
            }
            if changed and changed > 0 then
                applied = applied + 1
            end
        end
    end
    return applied
end

-- Apply the manager's canonical state to this side. Every field is optional: a pod delta
-- sends ops only, a request edit sends the two lists, a bay build sends the layout.
local function apply(payload)
    storage_ready()
    if not known() then
        return {ok = false, error = "no identity"}
    end
    payload = payload or {}

    local planet = payload.planet
    if role() == "planet" then
        planet = INSTANCE()
    end
    if not planet then
        return {ok = false, error = "a planet is required"}
    end

    local platform = ensure_one(planet)
    if not platform then
        return {ok = false, error = "no connector"}
    end

    local incoming_clock = tonumber(payload.clock) or 0
    if incoming_clock > (storage.connector_clock or 0) then
        storage.connector_clock = incoming_clock
    end

    if payload.has_requests or payload.incoming or payload.outgoing then
        enforce_platform(platform, payload.incoming or {}, payload.outgoing or {}, planet)
    end
    if role() == "planet" and (payload.has_requests or payload.pad or payload.incoming) then
        -- An empty pad from the space side means "space has no pad", not "clear the pad".
        -- Only a planet-originated payload owns the pad list; a space edit reaches the pad
        -- through the incoming list it edited.
        local pad_list = payload.incoming or {}
        if payload.role == "planet" and type(payload.pad) == "table" then
            pad_list = payload.pad
        end
        for _, pad in ipairs(pads()) do
            enforce_pad(pad, pad_list, planet)
        end
    end

    local applied = 0
    if payload.has_cargo then
        applied = sync_cargo(platform, payload.cargo or {})
    end
    for _, operation in ipairs(payload.ops or {}) do
        local count = math.floor(tonumber(operation.count) or 0)
        if count ~= 0 then
            local item = {
                name = operation.item or operation.name,
                quality = operation.quality or "normal",
                count = math.abs(count),
            }
            local changed = count > 0 and inventory_insert(platform, item) or inventory_remove(platform, item)
            if changed and changed > 0 then
                applied = applied + 1
            end
        end
    end
    if (payload.bays ~= nil) or (payload.layout ~= nil and payload.layout ~= "") then
        platforms.ensure_bays(platform, payload.bays, payload.layout)
    end

    protect(platform)
    local inventory = platform_api.hub_inventory(platform.hub)
    return {
        ok = true,
        planet = planet,
        role = role(),
        applied = applied,
        weight = inventory and inventory.weight or nil,
        clock = storage.connector_clock or 0,
    }
end

inventory_insert = function(platform, item)
    local inventory = platform_api.hub_inventory(platform.hub)
    if not inventory then
        return 0
    end
    return inventory.insert(item)
end

inventory_remove = function(platform, item)
    local inventory = platform_api.hub_inventory(platform.hub)
    if not inventory then
        return 0
    end
    return inventory.remove(item)
end

local function delete(planet)
    storage_ready()
    if role() == "planet" then
        planet = INSTANCE()
    end
    local platform = find_connector(planet)
    if not platform then
        return {ok = true, existed = false, planet = planet, role = role()}
    end
    remove(platform, "manager delete")
    return {ok = true, existed = true, planet = planet, role = role()}
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

local pending_mine = {}
local pending_refund = {}

local function mark_dirty(planet)
    storage_ready()
    if planet then
        storage.connector_dirty[planet] = true
    end
end

local function push_state(planet, why, with_cargo)
    storage_ready()
    local st = state_of(planet, with_cargo)
    st.reason = why
    bus.push("connector_state", st)
    storage.connector_dirty[planet] = nil
    record("push", {planet = planet, reason = why, weight = st.weight})
end

local function debit_clock()
    storage_ready()
    storage.connector_clock = (storage.connector_clock or 0) + 1
    return storage.connector_clock
end

-- A player's own edit: bump the logical clock, enforce the two groups, and push the whole
-- connector state. The clock is what lets the manager resolve two edits that raced.
local function edited(planet, why)
    debit_clock()
    local platform = find_connector(planet)
    if platform then
        local point = platform_api.request_point(platform.hub)
        local in_name, out_name = group_names(planet)
        local incoming = read_section(point, in_name)
        local outgoing = read_section(point, out_name)
        if role() == "planet" then
            local pad_list, pad_found = pad_requests()
            if pad_found then
                incoming = pad_list
            end
        end
        enforce_platform(platform, incoming, outgoing, planet)
        if role() == "planet" then
            for _, pad in ipairs(pads()) do
                enforce_pad(pad, incoming, planet)
            end
        end
        protect(platform)
    end
    -- No cargo on a request or bay edit: a stale list must not undo a pod that landed in
    -- the same window. The weight is still carried and compared.
    push_state(planet, why, false)
end

local function is_hub(entity)
    if not entity then
        return false
    end
    local ok, name = pcall(function() return entity.name end)
    return ok and name == "space-platform-hub"
end

local function platform_of_entity(entity)
    if not entity then
        return nil
    end
    local ok, surface = pcall(function() return entity.surface end)
    if not ok or not surface then
        return nil
    end
    return surface.platform
end

-- Anything other than the hub or a bay is not a platform. It is refunded to the hub and
-- removed; the item is not lost, which is the point of not calling destroy().
local function refund(entity)
    if not entity or not entity.valid then
        return
    end
    local inventory = entity.surface and entity.surface.platform
        and platform_api.hub_inventory(entity.surface.platform.hub) or nil
    local ok, items = pcall(function() return entity.prototype.items_to_place_this end)
    if inventory and ok and type(items) == "table" then
        for _, stack in ipairs(items) do
            pcall(function() inventory.insert(stack) end)
        end
    end
    pcall(function() entity.destroy() end)
end

local function guard_build(event)
    if not known() then
        return
    end
    storage_ready()
    local entity = event.entity
    local platform = event.platform or platform_of_entity(entity)
    if not is_connector(platform) then
        return
    end

    local planet = planet_of(platform)
    if is_hub(entity) then
        mark_dirty(planet)
        return
    end
    if entity and entity.valid and entity.name == "cargo-bay" then
        mark_dirty(planet)
        return
    end

    pending_mine[#pending_mine + 1] = {
        entity = entity,
        player = event.player_index and game.get_player(event.player_index) or nil,
        planet = planet,
    }
    record("guard", {planet = planet, name = entity and entity.name or "?"})
end

local function announce_deleted(planet, why)
    storage_ready()
    local last = storage.connector_deleted[planet]
    if last and game.tick - last <= 300 then
        return
    end
    storage.connector_deleted[planet] = game.tick
    bus.push("connector_deleted", {
        planet = planet,
        role = role(),
        clock = storage.connector_clock or 0,
        why = why,
        tick = game.tick,
    })
    record("deleted", {planet = planet, role = role(), why = why})
end

local function guard_mine(event)
    if not known() then
        return
    end
    storage_ready()
    local entity = event.entity
    local platform = event.platform or platform_of_entity(entity)
    if not is_connector(platform) then
        return
    end
    local planet = planet_of(platform)
    if is_hub(entity) then
        announce_deleted(planet, "mined")
        return
    end
    mark_dirty(planet)
end

-- A platform state change is the only event a deletion is known to raise on some builds.
-- A platform scheduled for deletion is on its way out; tell the manager so the counterpart
-- goes with it and both are rebuilt. A normal state change just refreshes the weight.
local function state_changed(event)
    if not known() then
        return
    end
    local platform = event.platform
    if not platform or not platform.valid then
        return
    end
    if not is_connector(platform) then
        return
    end
    local planet = planet_of(platform)
    if (platform.scheduled_for_deletion or 0) ~= 0 then
        announce_deleted(planet, "scheduled")
        return
    end
    mark_dirty(planet)
end

-- Death and pre-mine are the two other ways a hub can go. Both are bound because which one
-- fires depends on how the platform was deleted; the dedupe window in announce_deleted
-- keeps a platform that raises all three from being reported three times.
local function guard_death(event)
    if not known() then
        return
    end
    local entity = event.entity
    local platform = event.platform or platform_of_entity(entity)
    if is_hub(entity) and is_connector(platform) then
        announce_deleted(planet_of(platform), "died")
    end
end

-- A pod leaving or arriving at a connector hub. The manager applies the delta to the
-- counterpart and compares weights; the direction is the only thing that differs.
local function pod_event(direction, platform, cargo, weight, id)
    storage_ready()
    if not is_connector(platform) then
        return false
    end
    local planet = planet_of(platform)
    bus.push("connector_pod", {
        id = id,
        planet = planet,
        role = role(),
        direction = direction,
        name = platform.name,
        cargo = cargo,
        weight = weight,
        tick = game.tick,
    })
    record("pod", {planet = planet, direction = direction, items = #cargo})
    return true
end

local function tick()
    storage_ready()

    -- Asteroids accumulate on a real connector platform and damage its tiles; the game
    -- repairs them from the hub's foundation, which is what drained the starter-pack cargo.
    -- There is no spawn event to hook, so a one-second sweep is the cheapest correct answer,
    -- the same cadence the fleet's planet asteroid sweep already uses.
    if game.tick - (storage.connector_asteroids_at or 0) >= 60 then
        storage.connector_asteroids_at = game.tick
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and is_connector(platform) then
                pcall(function() platform.destroy_asteroid_chunks{} end)
            end
        end
    end

    -- A platform that was scheduled for deletion when ensure() ran is retried here, once
    -- per pending planet. The queue is empty in the common case.
    if storage.connector_retry and next(storage.connector_retry) ~= nil then
        local retry = {}
        for planet, at in pairs(storage.connector_retry) do
            if game.tick >= at then
                local made = create_platform(planet)
                if not made then
                    retry[planet] = game.tick + 10
                end
            else
                retry[planet] = at
            end
        end
        storage.connector_retry = retry
    end

    -- Anything a player built that is not a hub or a bay goes back to them, one tick after
    -- the build so the event has finished. Mining returns the item to the player; without
    -- one it is refunded to the hub.
    if #pending_mine > 0 then
        local queue = pending_mine
        pending_mine = {}
        for _, entry in ipairs(queue) do
            local entity = entry.entity
            if entity and entity.valid then
                if entry.player and entry.player.valid then
                    local ok = pcall(function()
                        entity.mine{player = entry.player, force = entity.force, raise_destroyed = true}
                    end)
                    if not ok then
                        refund(entity)
                    end
                else
                    refund(entity)
                end
                if entry.planet then
                    mark_dirty(entry.planet)
                end
            end
        end
    end

    -- Coalesce every edit in the same tick into one push per connector.
    local dirty = {}
    for planet in pairs(storage.connector_dirty or {}) do
        dirty[#dirty + 1] = planet
    end
    table.sort(dirty)
    for _, planet in ipairs(dirty) do
        push_state(planet, "edit", false)
    end
end

local function probe()
    storage_ready()
    local out = {
        role = role(),
        instance = INSTANCE(),
        clock = storage.connector_clock,
        pad_member = storage.pad_member,
        platforms = {},
        events = storage.connector_events,
    }
    if role() == "planet" then
        out.platforms[#out.platforms + 1] = state_of(INSTANCE(), true)
    else
        for _, planet in pairs(planets()) do
            out.platforms[#out.platforms + 1] = state_of(planet, true)
        end
    end
    return out
end

return {
    role = role,
    planet_of = planet_of,
    is_connector = is_connector,
    find_connector = find_connector,
    connector_name = connector_name,
    group_names = group_names,
    display_name = display_name,
    ensure_all = ensure_all,
    ensure_one = ensure_one,
    state = state,
    apply = apply,
    delete = delete,
    edit = edited,
    guard_build = guard_build,
    guard_mine = guard_mine,
    guard_death = guard_death,
    state_changed = state_changed,
    pod = pod_event,
    tick = tick,
    pad_requests = pad_requests,
    read_section = read_section,
    build_filters = build_filters,
    write_section = write_section,
    enforce_pad = enforce_pad,
    pads = pads,
    probe = probe,
    INCOMING = INCOMING,
    OUTGOING = OUTGOING,
}
