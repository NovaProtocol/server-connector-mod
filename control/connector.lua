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

local PLANET_PLATFORM_NAME = "~Space Platforms"
local LEGACY_PLANET_PLATFORM_NAME = "Space Platforms"
local SPACE_ICON = "[space-location=solar-system-edge]"
local INCOMING = "~Incoming (Space to Planet)"
local OUTGOING = "~Outgoing (Planet to Space)"
local LEGACY_INCOMING = "Incoming (Space to Planet)"
local LEGACY_OUTGOING = "Outgoing (Planet to Space)"

local INSTANCE = state.instance
local PROTOCOL = state.PROTOCOL

-- Forward declarations: these are called by functions defined above them. A local declared
-- later is a nil global to an earlier body, which is a runtime error the parser cannot see.
local enforce_platform
local inventory_insert
local inventory_remove
-- Assigned after push_state; ensure_all runs at runtime, so this forward is live by then.
local push_full
-- Assigned after create_platform; create_platform uses it to repair a hubless connector.
local remove

-- The boot marker is module-local on purpose: on_load must not modify storage, and
-- Factorio refuses to load the save when it does. The first tick reads it and clears it.
local boot_pending = false
local function mark_boot()
    boot_pending = true
end

local function role()
    return INSTANCE() == "space" and "space" or "planet"
end

local function force()
    return state.main_force()
end

local function known()
    -- A solo profile has an identity but no topology. Its connector is a telemetry and
    -- speed endpoint only; every planet-side operation below stays dormant.
    return state.known() and state.is_multi()
end

local function storage_ready()
    storage.connector_clock = storage.connector_clock or 0
    storage.connector_dirty = storage.connector_dirty or {}
    storage.connector_events = storage.connector_events or {}
    storage.connector_deleted = storage.connector_deleted or {}
    storage.connector_bay_seq = storage.connector_bay_seq or 0
    storage.connector_repairing = storage.connector_repairing or {}
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
    return string.format("~[planet=%s] %s Hub", planet, display_name(planet))
end

-- The name this build used before the tilde. Kept so an existing save's connectors are still
-- recognised and renamed in place instead of being duplicated by ensure_all.
local function legacy_connector_name(planet)
    if role() == "planet" then
        return LEGACY_PLANET_PLATFORM_NAME
    end
    return string.format("[planet=%s] %s Hub", planet, display_name(planet))
end

local function legacy_group_names(planet)
    if role() == "planet" then
        return LEGACY_INCOMING, LEGACY_OUTGOING, "Buffer"
    end
    return string.format("%s Space to [planet=%s] %s", SPACE_ICON, planet, display_name(planet)),
        string.format("[planet=%s] %s to %s Space", planet, display_name(planet), SPACE_ICON),
        string.format("[planet=%s] %s Buffer", planet, display_name(planet))
end

local function group_names(planet)
    if role() == "planet" then
        return INCOMING, OUTGOING, "~Buffer"
    end
    local in_name, out_name, buffer_name = legacy_group_names(planet)
    return "~" .. in_name, "~" .. out_name, "~" .. buffer_name
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
    return string.match(tostring(platform.name), "^~?%[planet=([^%]]+)%]")
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
    local name = platform.name
    return name == connector_name(planet) or name == legacy_connector_name(planet)
end

local function find_connector(planet)
    if not planet then
        return nil
    end
    if role() == "planet" and planet ~= INSTANCE() then
        return nil
    end
    local want, old = connector_name(planet), legacy_connector_name(planet)
    for _, platform in pairs(force().platforms or {}) do
        if platform.valid and (platform.name == want or platform.name == old) then
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
        request_from = text(filter.request_from),
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

local function build_buffer_filters(list)
    local out = {}
    for _, entry in ipairs(list or {}) do
        local count = math.floor(tonumber(entry.count) or 0)
        local item = entry.item or entry.name
        if item and count > 0 then
            out[#out + 1] = {
                value = {type = "item", name = item, quality = entry.quality or "normal"},
                min = count,
                max = nil,
                request_from = entry.request_from,
                import_from = entry.import_from,
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

local function quiet_trash(entity)
    if not entity or not entity.valid then
        return
    end
    -- A hub or pad can expose several logistic points; the one the requests are read from
    -- is not always the one carrying trash_unrequested. Clearing all of them is what stops
    -- the pad pushing its inventory into the platform and the hub ejecting its cargo.
    for _, value in pairs(defines.logistic_member_index or {}) do
        local ok, point = pcall(function() return entity.get_logistic_point(value) end)
        if ok and point then
            pcall(function() point.trash_not_requested = false end)
        end
    end
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
    for _, bay in ipairs(platforms.all_bays(platform) or {}) do
        one(bay)
        if platforms.is_base_bay(platform.hub, bay) then
            pcall(function() bay.minable_flag = false end)
        end
    end
end

-- The base grid is built one platform per tick, never in a burst. The key is the hub's
-- unit number and position, so a rebuilt hub is a new grid while a moved one is not.
local function grid_key(platform)
    local hub = platform.hub
    return string.format("%s:%.1f,%.1f", tostring(hub.unit_number), hub.position.x, hub.position.y)
end

local function queue_base_grid(platform)
    if not platform or not platform.valid or not platform.hub or not platform.hub.valid then
        return
    end
    storage.base_grid_done = storage.base_grid_done or {}
    if storage.base_grid_done[platform.name] == grid_key(platform) then
        return
    end
    storage.base_grid_queue = storage.base_grid_queue or {}
    if storage.base_grid_queue[platform.name] == nil then
        storage.base_grid_queue[platform.name] = 0
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
        -- A connector with no hub is a platform shell -- exactly the floating cargo bay
        -- the owner saw. It cannot hold cargo or requests, so it is not the connector:
        -- remove it and let the retry make a fresh hub-only platform. The repair stays
        -- guarded until the replacement exists, because destroy(2) raises its events on
        -- a later tick.
        if not existing.hub or not existing.hub.valid then
            log(string.format("[%s] connector %s has no hub; rebuilding it", INSTANCE(), name))
            record("repair", {planet = planet, name = name})
            storage.connector_repairing[planet] = true
            begin_write()
            remove(existing, "no hub")
            end_write()
            storage.connector_retry = storage.connector_retry or {}
            storage.connector_retry[planet] = game.tick + 10
            return nil
        end
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
    if not ok or not created then
        storage.connector_creating = nil
        log(string.format("[%s] could not create connector %s at %s: %s",
            INSTANCE(), name, planet, tostring(created)))
        record("create-failed", {planet = planet, error = tostring(created)})
        return nil
    end

    -- The hub build event fires during the starter pack. It is this mod's creation, not a
    -- player edit, so the flag stays set through it.
    local applied, hub = pcall(function() return created.apply_starter_pack(true) end)
    storage.connector_creating = nil
    if not applied or not hub then
        log(string.format("[%s] connector %s has no hub; removing it", INSTANCE(), name))
        pcall(function() created.destroy(1) end)
        return nil
    end

    pcall(function() created.destroy_asteroid_chunks{} end)
    protect(created)
    queue_base_grid(created)
    storage.connector_repairing[planet] = nil
    record("created", {planet = planet, name = name})
    log(string.format("[%s] created connector %s at %s", INSTANCE(), name, planet))
    return created
end

remove = function(platform, why)
    if not platform or not platform.valid then
        return true
    end
    if platform.hub then
        pcall(function() platform.hub.destructible = true end)
        pcall(function() platform.hub.minable_flag = true end)
    end
    for _, bay in ipairs(platforms.all_bays(platform) or {}) do
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

-- Rename the three groups made by older builds to their tilde-prefixed names. The tilde is
-- deliberately cosmetic: it sorts generated groups below a player's own groups, and the
-- connector's identity is still the platform name, not these labels.
local function migrate_group_names(platform, planet)
    if not platform or not platform.valid or not platform.hub or not platform.hub.valid then
        return
    end
    local point = platform_api.request_point(platform.hub)
    if not point then
        return
    end
    local old_in, old_out, old_buffer = legacy_group_names(planet)
    local new_in, new_out, new_buffer = group_names(planet)
    for _, pair in ipairs({
        {old = old_in, new = new_in},
        {old = old_out, new = new_out},
        {old = old_buffer, new = new_buffer},
    }) do
        if pair.old ~= pair.new then
            local old_section = find_section(point, pair.old)
            local new_section = find_section(point, pair.new)
            if old_section and not new_section then
                pcall(function() old_section.group = pair.new end)
            end
        end
    end
end

-- A platform that is not the connector for its planet is a duplicate: a starter pack that
-- was launched, an older copy, or a platform made before this design. It goes, and the
-- connector is made again. The spec is one platform per planet.
-- A connector hub must be a provider for the other platforms, not just a requester.
-- The checkbox is a player-facing property, so a player can uncheck it; the mod restores
-- it on the next pass. This is deliberately a timer rather than relying on a GUI event:
-- the property can also be changed by blueprints, migration or another mod.
local function enforce_providing()
    if not known() then
        return
    end
    for _, platform in pairs(force().platforms or {}) do
        if platform.valid and platform.hub and platform.hub.valid and is_connector(platform) then
            pcall(function()
                if platform.hub.providing_to_other_platforms ~= true then
                    platform.hub.providing_to_other_platforms = true
                end
            end)
        end
    end
end

-- Both copies of every planet connector keep their spoilable stock fresh. The planet
-- server owns one connector; the space server owns one connector per planet. A real
-- platform hub is not a connector and is not touched. spoil_percent is the percent
-- spoiled, so writing 0 is 100% freshness; only stacks already off fresh are written.
local function refresh_platform(platform)
    if not platform or not platform.hub or not platform.hub.valid then
        return 0
    end
    local inventory = platform_api.hub_inventory(platform.hub)
    if not inventory then
        return 0
    end
    local reset = 0
    for index = 1, #inventory do
        local stack = inventory[index]
        if stack and stack.valid_for_read and stack.count > 0 then
            local percent = tonumber(stack.spoil_percent) or 0
            if percent > 0 then
                -- spoil_ticks is optional on item prototypes; reading it directly throws for
                -- every non-spoiling item in the hub and aborted the whole sweep.
                local okp, total = pcall(function() return stack.prototype.spoil_ticks end)
                total = okp and tonumber(total) or 0
                local ok = pcall(function()
                    -- percent alone is not enough: an old absolute spoil_tick can still
                    -- convert the stack on the next engine pass. Give it a full fresh timer.
                    stack.spoil_percent = 0
                    if total > 0 then
                        stack.spoil_tick = game.tick + total
                    end
                end)
                if ok then
                    reset = reset + 1
                end
            end
        end
    end
    return reset
end

local function refresh_spoilage()
    if not known() then
        return 0
    end
    local reset = 0
    if role() == "planet" then
        reset = refresh_platform(find_connector(INSTANCE()))
    else
        for _, planet in ipairs(planets()) do
            reset = reset + refresh_platform(find_connector(planet))
        end
    end
    return reset
end

-- Read-only diagnostic for the manager: spoilable stacks in the connector hubs and their
-- current spoil percentages.
local function spoilage_report()
    local out = {instance = INSTANCE(), role = role(), platforms = {}}
    local ids = role() == "planet" and {INSTANCE()} or planets()
    for _, planet in ipairs(ids) do
        local platform = find_connector(planet)
        local row = {planet = planet, stacks = {}}
        if platform and platform.hub and platform.hub.valid then
            local inventory = platform_api.hub_inventory(platform.hub)
            if inventory then
                for index = 1, #inventory do
                    local stack = inventory[index]
                    if stack and stack.valid_for_read and stack.count > 0 then
                        local percent = tonumber(stack.spoil_percent) or 0
                        if percent > 0 then
                            row.stacks[#row.stacks + 1] = {
                                item = stack.name,
                                count = stack.count,
                                spoil_percent = percent,
                                spoil_tick = stack.spoil_tick,
                            }
                        end
                    end
                end
            end
        end
        out.platforms[#out.platforms + 1] = row
    end
    return out
end

local function ensure_all()
    if not known() then
        return {ok = false, skipped = "no identity"}
    end
    storage_ready()

    local made = {}
    if role() == "planet" then
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and platform.name == LEGACY_PLANET_PLATFORM_NAME then
                pcall(function() platform.name = PLANET_PLATFORM_NAME end)
            end
        end
        local connector = create_platform(INSTANCE())
        if connector then
            made[#made + 1] = connector.name
        end
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and platform.name ~= PLANET_PLATFORM_NAME then
                platforms.settle_stray(platform)
            end
        end
        for _, platform in pairs(force().platforms or {}) do
            if is_connector(platform) then
                migrate_group_names(platform, INSTANCE())
                protect(platform)
                queue_base_grid(platform)
                enforce_platform(platform, {}, INSTANCE())
            end
        end
        for _, pad in ipairs(pads()) do
            quiet_trash(pad)
        end
        enforce_providing()
    else
        -- Without a topology there is no list of planets to keep, and pruning on an empty
        -- list would remove every platform on the space server -- including the connectors
        -- the converter just made. set_instance arrives before set_topology, so this is a
        -- real boot order, not a hypothetical.
        -- A connector named the old way is renamed in place: is_connector already accepts
        -- both, so nothing is duplicated either way, and a failed rename is only a log line.
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid then
                local planet = planet_of(platform)
                if planet and platform.name == legacy_connector_name(planet)
                    and connector_name(planet) ~= legacy_connector_name(planet) then
                    local ok, err = pcall(function() platform.name = connector_name(planet) end)
                    if ok then
                        record("renamed", {from = legacy_connector_name(planet), to = connector_name(planet)})
                    else
                        log(string.format("[%s] could not rename %s: %s",
                            INSTANCE(), tostring(platform.name), tostring(err)))
                    end
                end
            end
        end
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
        -- The real platforms are the fleet's, not copies. Only the connector is created here;
        -- nothing else is pruned on the space server.
        for _, platform in pairs(force().platforms or {}) do
            if is_connector(platform) then
                local planet = planet_of(platform)
                migrate_group_names(platform, planet)
                protect(platform)
                queue_base_grid(platform)
                enforce_platform(platform, {}, planet)
            end
        end
        enforce_providing()
    end

    storage.demand_pending = "ensure"
    if push_full then
        if role() == "planet" then
            push_full(INSTANCE())
        else
            for _, planet in ipairs(planets()) do
                push_full(planet)
            end
        end
    end

    return {ok = true, role = role(), made = table.concat(made, ",")}
end

enforce_platform = function(platform, lists, planet)
    lists = lists or {}
    local point = platform_api.request_point(platform.hub)
    if not point then
        return false
    end
    if not platform.hub or not platform.hub.valid then
        return false
    end
    quiet_trash(platform.hub)
    begin_write()
    local in_name, out_name, buffer_name = group_names(planet)

    -- One row per item per hub. The game fills every request row it is handed, so the same
    -- item in Incoming and in Outgoing is requested twice and the hub is delivered twice
    -- what anybody asked for. Incoming wins; Outgoing and Buffer lose the duplicate.
    if type(lists.incoming) == "table" then
        local taken = {}
        for _, entry in ipairs(lists.incoming) do
            taken[(entry.item or "?") .. "|" .. tostring(entry.quality)] = true
        end
        for _, group in ipairs({"outgoing", "buffer"}) do
            if lists[group] ~= nil then
                local kept = {}
                for _, entry in ipairs(lists[group]) do
                    if not taken[(entry.item or "?") .. "|" .. tostring(entry.quality)] then
                        kept[#kept + 1] = entry
                    end
                end
                lists[group] = kept
            end
        end
    end

    -- All three groups always exist, whether or not this call writes them.
    ensure_section(point, in_name)
    ensure_section(point, out_name)
    ensure_section(point, buffer_name)
    local ok = true
    if lists.incoming ~= nil then
        ok = write_section(point, in_name, build_filters(lists.incoming, "platforms", planet)) and ok
    end
    if lists.outgoing ~= nil then
        ok = write_section(point, out_name, build_filters(lists.outgoing, "planet", planet)) and ok
    end
    if lists.buffer ~= nil then
        ok = write_section(point, buffer_name, build_buffer_filters(lists.buffer)) and ok
    end
    -- KEEP the existing loop here unchanged: every other manual group keeps its filters
    -- and loses its maximum. It now also covers Buffer, which is intended.
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
    return ok
end

--------------------------------------------------------------------------------
-- state and apply
--------------------------------------------------------------------------------

local function cargo_of(platform)
    return platform_api.cargo(platform)
end

local function read_state(platform, with_cargo, with_shape)
    local planet = planet_of(platform)
    -- A platform shell with no hub has no logistic point, no inventory and no requests.
    -- Reading it must still return a state (exists=true, hub=false), not raise: the manager
    -- uses that answer to see the repair case instead of losing the whole read.
    if not platform.hub or not platform.hub.valid then
        return {
            planet = planet,
            role = role(),
            name = platform.name,
            exists = true,
            hub = false,
            clock = storage.connector_clock or 0,
            providing = false,
            weight = nil,
            cargo = with_cargo and {} or nil,
            has_cargo = with_cargo or false,
            has_requests = true,
            bays = with_shape and platforms.bay_count(platform) or nil,
            layout = with_shape and platforms.layout_of(platform) or nil,
            incoming = {},
            outgoing = {},
            buffer = {},
            groups_ok = false,
            bay_seq = storage.connector_bay_seq or 0,
        }
    end
    local point = platform_api.request_point(platform.hub)
    local in_name, out_name, buffer_name = group_names(planet)
    local incoming = read_section(point, in_name)
    local outgoing = read_section(point, out_name)
    local buffer = read_section(point, buffer_name)
    local inventory = platform_api.hub_inventory(platform.hub)
    local st = {
        planet = planet,
        role = role(),
        name = platform.name,
        exists = true,
        hub = true,
        clock = storage.connector_clock or 0,
        providing = platform.hub.providing_to_other_platforms == true,
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
        -- The bay shape travels only on the boot/reconcile read. A bay edit travels as a
        -- single build/remove event; a full layout on every edit is what made it laggy.
        bays = with_shape and platforms.bay_count(platform) or nil,
        layout = with_shape and platforms.layout_of(platform) or nil,
        incoming = incoming,
        outgoing = outgoing,
        buffer = buffer,
        groups_ok = find_section(point, in_name) ~= nil and find_section(point, out_name) ~= nil
            and find_section(point, buffer_name) ~= nil,
        bay_seq = storage.connector_bay_seq or 0,
    }
    return st
end

local function state_of(planet, with_cargo, with_shape)
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
            buffer = {},
            bay_seq = storage.connector_bay_seq or 0,
        }
    end
    local st = read_state(platform, with_cargo, with_shape)
    st.ok = true
    return st
end

-- The manager's read: always the whole picture, shape included.
local function state(planet)
    return state_of(planet, true, true)
end

local function sync_cargo(platform, target)
    local inventory = platform_api.hub_inventory(platform.hub)
    if not inventory then
        debug.emit("connector cargo sync skipped: no hub inventory")
        return 0, {}
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
    local shortfalls = {}

    -- Every move is accounted, not just the ones that worked. A remove that moved fewer
    -- than it wanted is the signature of the same item being consumed on both sides before
    -- the mirror caught up; an insert that moved fewer is a full hub.
    local function note(operation, entry, want, moved)
        moved = moved or 0
        debug.emit("connector cargo sync %s %s/%s: wanted %d moved %d",
            operation, tostring(entry.item), tostring(entry.quality), want, moved)
        if moved < want then
            local short = {
                item = entry.item,
                quality = entry.quality or "normal",
                operation = operation,
                wanted = want,
                moved = moved,
            }
            shortfalls[#shortfalls + 1] = short
            debug.emit("connector cargo SHORTFALL sync %s %s/%s: wanted %d moved %d",
                operation, tostring(entry.item), tostring(entry.quality), want, moved)
            record("cargo_shortfall", short)
        end
        if moved > 0 then
            applied = applied + 1
        end
    end

    for k, count in pairs(wanted) do
        local have = current[k] or 0
        if count > have then
            local want = count - have
            local moved = inventory.insert{
                name = meta[k].item,
                quality = meta[k].quality,
                count = want,
            } or 0
            note("insert", meta[k], want, moved)
        end
    end
    for k, count in pairs(current) do
        local want = wanted[k] or 0
        if count > want then
            local need = count - want
            local moved = inventory.remove{
                name = meta[k].item,
                quality = meta[k].quality,
                count = need,
            } or 0
            note("remove", meta[k], need, moved)
        end
    end
    return applied, shortfalls
end

-- Apply the manager's canonical state to this side. Every field is optional: a pod delta
-- sends ops only, a request edit sends the two lists, a bay build sends the layout.
local function apply(payload)
    storage_ready()
    if not known() then
        return {ok = false, error = "no identity"}
    end
    payload = payload or {}

    -- Pod deltas are re-sent for a minute and the manager's de-dupe is in memory only, so a
    -- restart used to apply the same cargo again. The id makes this exactly-once here.
    local id = payload.id
    if type(id) == "string" and id ~= "" then
        storage.pod_done = storage.pod_done or {}
        if storage.pod_done[id] then
            return {ok = true, duplicate = true}
        end
        storage.pod_done[id] = game.tick
        for key, at in pairs(storage.pod_done) do
            if game.tick - at > 216000 then
                storage.pod_done[key] = nil
            end
        end
    end

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

    local groups_ok = true
    -- Each side owns one derived group and ignores the other side's claim to it.
    -- Absent (nil) is not touched; empty is written as empty.
    local lists = {}
    if role() == "space" then lists.incoming = payload.incoming end
    if role() == "planet" then lists.outgoing = payload.outgoing end
    lists.buffer = payload.buffer
    if next(lists) ~= nil then
        groups_ok = enforce_platform(platform, lists, planet) and groups_ok
    end
    if payload.mark_buffer_migrated then
        storage.buffer_migrated = storage.buffer_migrated or {}
        storage.buffer_migrated[planet] = true
    end

    local applied = 0
    local shortfalls = {}
    if payload.has_cargo then
        local synced, synced_short = sync_cargo(platform, payload.cargo or {})
        applied = applied + synced
        for _, short in ipairs(synced_short) do
            shortfalls[#shortfalls + 1] = short
        end
    end
    for _, operation in ipairs(payload.ops or {}) do
        local count = math.floor(tonumber(operation.count) or 0)
        if count ~= 0 then
            local item = {
                name = operation.item or operation.name,
                quality = operation.quality or "normal",
                count = math.abs(count),
            }
            local want = math.abs(count)
            local moved
            if count > 0 then
                moved = inventory_insert(platform, item)
            else
                moved = inventory_remove(platform, item)
            end
            moved = moved or 0
            debug.emit("connector cargo pod %s %s/%s: wanted %d moved %d",
                count > 0 and "insert" or "remove",
                tostring(item.name), tostring(item.quality), want, moved)
            if moved < want then
                local short = {
                    item = item.name,
                    quality = item.quality,
                    operation = count > 0 and "insert" or "remove",
                    wanted = want,
                    moved = moved,
                }
                shortfalls[#shortfalls + 1] = short
                debug.emit("connector cargo SHORTFALL pod %s %s/%s: wanted %d moved %d",
                    short.operation, tostring(item.name), tostring(item.quality), want, moved)
                record("cargo_shortfall", short)
            end
            if moved > 0 then
                applied = applied + 1
            end
        end
    end
    if (payload.bays ~= nil) or (payload.layout ~= nil and payload.layout ~= "") then
        -- ensure_bays creates and destroys entities; those raise the platform build/mine
        -- events. They are the manager's write, not a player edit, and must not be pushed
        -- back as a new state.
        begin_write()
        platforms.ensure_bays(platform, payload.bays, payload.layout)
        end_write()
    end

    protect(platform)
    local inventory = platform_api.hub_inventory(platform.hub)
    local result = {
        ok = true,
        planet = planet,
        role = role(),
        applied = applied,
        weight = inventory and inventory.weight or nil,
        clock = storage.connector_clock or 0,
        groups_ok = groups_ok,
    }
    -- An empty Lua table encodes as {}, which a Go slice cannot decode; omit it when clean.
    if #shortfalls > 0 then
        result.shortfalls = shortfalls
    end
    return result
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

-- A bay's identity in the mirror: its offset from the hub, rounded the same way the layout
-- string is. The counterpart creates at the same offset, so the two hubs keep the same ship.
local function parse_offset(offset)
    local x, y = string.match(tostring(offset or ""), "^(-?[%d%.]+),(-?[%d%.]+)$")
    if not x or not y then
        return nil
    end
    return tonumber(x), tonumber(y)
end

local function bay_offset(platform, entity)
    if not platform or not platform.hub or not platform.hub.valid then
        return nil
    end
    if not entity or not entity.valid then
        return nil
    end
    local ok, position = pcall(function() return entity.position end)
    if not ok or not position then
        return nil
    end
    local okh, hub_position = pcall(function() return platform.hub.position end)
    if not okh or not hub_position then
        return nil
    end
    return string.format("%.1f,%.1f", position.x - hub_position.x, position.y - hub_position.y)
end

-- The counterpart half of a bay build/remove. It is the manager's write, so the write flag is
-- held while the entity is created or destroyed and the build/mine events do not echo back.
local function build_bay(payload)
    storage_ready()
    payload = payload or {}
    local planet = role() == "planet" and INSTANCE() or payload.planet
    if not planet then
        return {ok = false, error = "a planet is required"}
    end
    local platform = find_connector(planet)
    if not platform or not platform.surface or not platform.hub then
        return {ok = false, error = "no connector"}
    end
    local x, y = parse_offset(payload.offset)
    if not x or not y then
        return {ok = false, error = "bad offset"}
    end
    if platforms.is_base_offset(x, y) then
        return {ok = true, skipped = "base slot"}
    end

    local hub = platform.hub.position
    local position = {x = hub.x + x, y = hub.y + y}
    local existing = platform.surface.find_entities_filtered{
        name = "cargo-bay", position = position, radius = 0.5,
    }
    if existing and existing[1] then
        return {ok = true, existed = true, offset = payload.offset}
    end

    begin_write()
    local ok, bay = pcall(function()
        return platform.surface.create_entity{
            name = "cargo-bay",
            position = position,
            force = force().name,
        }
    end)
    end_write()
    if not ok or not bay then
        debug.emit("connector bay build failed %s at %s: %s", planet, tostring(payload.offset), tostring(bay))
        record("bay_failed", {action = "build", planet = planet, offset = payload.offset, error = tostring(bay)})
        return {ok = false, error = tostring(bay)}
    end
    protect(platform)
    debug.emit("connector bay built %s at %s", planet, tostring(payload.offset))
    return {ok = true, created = true, offset = payload.offset}
end

local function remove_bay(payload)
    storage_ready()
    payload = payload or {}
    local planet = role() == "planet" and INSTANCE() or payload.planet
    if not planet then
        return {ok = false, error = "a planet is required"}
    end
    local platform = find_connector(planet)
    if not platform or not platform.surface or not platform.hub then
        return {ok = false, error = "no connector"}
    end
    local x, y = parse_offset(payload.offset)
    if not x or not y then
        return {ok = false, error = "bad offset"}
    end
    if platforms.is_base_offset(x, y) then
        return {ok = true, skipped = "base slot"}
    end

    local hub = platform.hub.position
    local position = {x = hub.x + x, y = hub.y + y}
    local existing = platform.surface.find_entities_filtered{
        name = "cargo-bay", position = position, radius = 0.5,
    }
    if not existing or not existing[1] then
        return {ok = true, existed = false, offset = payload.offset}
    end

    begin_write()
    for _, bay in ipairs(existing) do
        pcall(function()
            bay.destructible = true
            bay.destroy()
        end)
    end
    end_write()
    debug.emit("connector bay removed %s at %s", planet, tostring(payload.offset))
    return {ok = true, removed = #existing, offset = payload.offset}
end

-- The hub's storage inventory, asked for by name first and then by probing, so this works
-- whichever index the hub exposes on this build.
local function hub_inventory(platform)
    local ok, inv = pcall(function()
        return platform.hub.get_inventory(defines.inventory.space_platform_hub_main)
    end)
    if ok and inv then
        return inv
    end
    for _, value in pairs(defines.inventory or {}) do
        local ok2, candidate = pcall(function() return platform.hub.get_inventory(value) end)
        if ok2 and candidate then
            return candidate
        end
    end
    return nil
end

-- Set one item's count in a connector hub, exactly. Absolute, never a delta: the mirror's
-- sweep states the count it wants, and the hub ends up holding that many. Requests are not
-- touched. A cargo pod's arrival still applies a delta, because there the change is real.
local function hub_set_item(args)
    storage_ready()
    args = args or {}
    local planet = args.planet
    if role() == "planet" then
        planet = INSTANCE()
    end
    if not planet or type(args.item) ~= "string" then
        return {ok = false, error = "planet and item are required"}
    end
    local want = math.max(0, math.floor(tonumber(args.count) or 0))
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = false, error = "no connector hub"}
    end
    local quality = args.quality
    if quality == "normal" then
        quality = nil
    end

    local function matches(entry)
        if entry.name ~= args.item then
            return false
        end
        local entry_quality = entry.quality and tostring(entry.quality) or "normal"
        return entry_quality == (quality or "normal")
    end

    -- Read every inventory once: the one that actually holds the item is the one to write,
    -- and its count is the base. A probe that answers 0 for an inventory that is not holding
    -- the item is what turned an absolute set into an extra delivery.
    local target_inventory, before = nil, 0
    for _, value in pairs(defines.inventory or {}) do
        local ok, inventory = pcall(function() return platform.hub.get_inventory(value) end)
        if ok and inventory then
            local okc, contents = pcall(function() return inventory.get_contents() end)
            if okc and contents then
                local found = 0
                for _, entry in ipairs(contents) do
                    if matches(entry) then
                        found = found + entry.count
                    end
                end
                if found > 0 then
                    target_inventory, before = inventory, found
                    break
                end
            end
        end
    end
    if not target_inventory then
        target_inventory = hub_inventory(platform)
    end
    if not target_inventory then
        return {ok = false, error = "no hub inventory"}
    end

    if before > 0 then
        pcall(function()
            target_inventory.remove{name = args.item, count = before, quality = quality}
        end)
    end
    if want > 0 then
        local ok, err = pcall(function()
            target_inventory.insert{name = args.item, count = want, quality = quality}
        end)
        if not ok then
            return {ok = false, error = tostring(err), before = before}
        end
    end

    local after = 0
    pcall(function()
        local okc, contents = pcall(function() return target_inventory.get_contents() end)
        if okc and contents then
            for _, entry in ipairs(contents) do
                if matches(entry) then
                    after = after + entry.count
                end
            end
        end
    end)
    debug.emit("hub_set_item %s %s/%s %d -> %d (absolute, want %d)", planet, args.item,
        tostring(args.quality or "normal"), before, after, want)
    return {ok = after == want, planet = planet, item = args.item, before = before, after = after}
end

-- One page of a hub's contents, sorted, for the mirror's slow sweep. Read-only.
local function hub_cargo_page(args)
    storage_ready()
    args = args or {}
    local planet = args.planet
    if role() == "planet" then
        planet = INSTANCE()
    end
    local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
    local limit = math.max(1, math.min(50, math.floor(tonumber(args.limit) or 5)))
    local platform = planet and find_connector(planet) or nil
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = false, error = "no connector hub", planet = planet}
    end
    local inventory = hub_inventory(platform)
    if not inventory then
        return {ok = false, error = "no hub inventory", planet = planet}
    end
    local ok, contents = pcall(function() return inventory.get_contents() end)
    if not ok or not contents then
        return {ok = false, error = "could not read the hub", planet = planet}
    end
    table.sort(contents, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        local qa = a.quality and tostring(a.quality) or "normal"
        local qb = b.quality and tostring(b.quality) or "normal"
        return qa < qb
    end)
    local items = {}
    for i = offset, math.min(#contents, offset + limit - 1) do
        local entry = contents[i]
        items[#items + 1] = {
            item = entry.name,
            quality = entry.quality and tostring(entry.quality) or "normal",
            count = entry.count,
        }
    end
    return {ok = true, planet = planet, offset = offset, total = #contents, items = items}
end

-- Empty a connector hub without rebuilding it. Returns how many items were taken out.
local function clear(planet)
    storage_ready()
    if role() == "planet" then
        planet = INSTANCE()
    end
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = true, existed = false, planet = planet, cleared = 0}
    end
    local cleared = 0
    for _, value in pairs(defines.inventory or {}) do
        local ok, inventory = pcall(function() return platform.hub.get_inventory(value) end)
        if ok and inventory then
            local okc, contents = pcall(function() return inventory.get_contents() end)
            if okc and contents then
                for _, item in ipairs(contents) do
                    cleared = cleared + item.count
                end
            end
            pcall(function() inventory.clear() end)
        end
    end
    log(string.format("[%s] cleared %d item(s) from %s", INSTANCE(), cleared, platform.name))
    return {ok = true, planet = planet, name = platform.name, cleared = cleared}
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
    -- Event states carry no bay shape: the bay build/mine event handles that entity, and a
    -- full layout comparison on every request or bay edit is the lag this replaced.
    local st = state_of(planet, with_cargo, false)
    st.reason = why
    bus.push("connector_state", st)
    storage.connector_dirty[planet] = nil
    record("push", {planet = planet, reason = why, weight = st.weight})
end

-- The boot/reconcile push: the whole shape, cargo and requests. This is the fresh sync.
push_full = function(planet)
    storage_ready()
    local st = state_of(planet, true, true)
    st.reason = "ensure"
    bus.push("connector_state", st)
    record("push", {planet = planet, reason = "ensure", weight = st.weight})
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
        enforce_platform(platform, {}, planet)
        protect(platform)
    end
    push_state(planet, why, false)
end

-- The derived writers: the recalculation and the manager's sync. Quiet writes do not bump
-- the clock or push a state back.
local function set_groups(planet, lists, why, quiet)
    storage_ready()
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return false, "no connector hub"
    end
    local ok = enforce_platform(platform, lists, planet)
    protect(platform)
    if not quiet then
        debit_clock()
        push_state(planet, why or "derived", false)
    end
    return ok
end

local function read_groups(planet)
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return {exists = platform ~= nil, hub = false, incoming = {}, outgoing = {}, buffer = {}, groups_ok = false}
    end
    local point = platform_api.request_point(platform.hub)
    local in_name, out_name, buffer_name = group_names(planet)
    local incoming, in_found = read_section(point, in_name)
    local outgoing, out_found = read_section(point, out_name)
    local buffer, buffer_found = read_section(point, buffer_name)
    return {
        exists = true, hub = true, incoming = incoming, outgoing = outgoing, buffer = buffer,
        groups_ok = in_found and out_found and buffer_found,
        clock = storage.connector_clock or 0,
    }
end

local function read_cargo(planet)
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return {exists = platform ~= nil, hub = false, cargo = {}}
    end
    local inventory = platform_api.hub_inventory(platform.hub)
    return {exists = true, hub = true, cargo = cargo_of(platform), weight = inventory and inventory.weight or nil}
end

local function read_layout(planet)
    local platform = find_connector(planet)
    if not platform or not platform.hub or not platform.hub.valid then
        return {exists = platform ~= nil, hub = false}
    end
    return {
        exists = true, hub = true,
        bays = platforms.bay_count(platform), layout = platforms.layout_of(platform),
        bay_seq = storage.connector_bay_seq or 0,
    }
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
    -- A bay made by ensure_bays on the counterpart is the manager's write. Treating it as a
    -- player build pushed a state back, and that race is what removed the origin bay.
    if (storage.connector_writing or 0) > 0 or storage.connector_creating then
        return
    end
    local entity = event.entity
    local platform = event.platform or platform_of_entity(entity)
    if not is_connector(platform) then
        return
    end

    local planet = planet_of(platform)
    if is_hub(entity) then
        debit_clock()
        -- A rebuilt hub is a new anchor for every bay offset. A state push carries no shape,
        -- so the pair could stay different until a restart; push the whole shape instead.
        storage.base_grid_done = storage.base_grid_done or {}
        storage.base_grid_done[platform.name] = nil
        queue_base_grid(platform)
        push_full(planet)
        return
    end
    if entity and entity.valid and entity.name == "cargo-bay" then
        -- A bay a player just placed is protected at once, not only after the next mirror
        -- apply; otherwise an asteroid in that window can destroy it.
        pcall(function()
            entity.destructible = false
            entity.minable_flag = true
            entity.operable = true
        end)
        debit_clock()
        storage.connector_bay_seq = storage.connector_bay_seq + 1
        local offset = bay_offset(platform, entity)
        if offset then
            bus.push("connector_bay", {
                instance = INSTANCE(),
                planet = planet,
                role = role(),
                action = "build",
                offset = offset,
                clock = storage.connector_clock,
                seq = storage.connector_bay_seq,
                tick = game.tick,
            })
            record("bay", {action = "build", planet = planet, offset = offset})
        else
            debug.emit("connector bay build at an unreadable position")
        end
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
    if (storage.connector_writing or 0) > 0 or storage.connector_creating then
        return
    end
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
    if entity and entity.valid and entity.name == "cargo-bay" then
        local offset = bay_offset(platform, entity)
        debit_clock()
        storage.connector_bay_seq = storage.connector_bay_seq + 1
        if offset then
            bus.push("connector_bay", {
                instance = INSTANCE(),
                planet = planet,
                role = role(),
                action = "remove",
                offset = offset,
                clock = storage.connector_clock,
                seq = storage.connector_bay_seq,
                tick = game.tick,
            })
            record("bay", {action = "remove", planet = planet, offset = offset})
        else
            debug.emit("connector bay mine at an unreadable position")
        end
        return
    end
    debug.emit("connector: ignoring a mine of %s; only the hub and bays are mirrored",
        entity and entity.valid and entity.name or "?")
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
    if (storage.connector_writing or 0) > 0 or storage.connector_creating
        or (storage.connector_repairing or {})[planet] then
        return
    end
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
        local planet = planet_of(platform)
        -- The repair destroys the old platform itself; its death must not announce a
        -- deletion to the manager, or the counterpart would be deleted as well.
        if (storage.connector_writing or 0) > 0 or storage.connector_creating
            or (storage.connector_repairing or {})[planet] then
            return
        end
        announce_deleted(planet, "died")
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

local function sweep_platform(platform)
    if not platform or not platform.valid or not is_connector(platform) then
        return
    end
    pcall(function() platform.destroy_asteroid_chunks{} end)

    -- Asteroids that already reached the surface are ordinary entities (type
    -- "asteroid" for the medium and big ones, "asteroid-chunk" for the small ones).
    -- destroy_asteroid_chunks does not remove those, so remove them directly.
    local surface = platform.surface
    if not surface then
        return
    end
    local ok, entities = pcall(function() return surface.find_entities_filtered{} end)
    if not ok or not entities then
        return
    end
    local destroyed = 0
    for _, entity in ipairs(entities) do
        if entity.valid and (entity.type == "asteroid" or entity.type == "asteroid-chunk") then
            if pcall(function() entity.destroy() end) then
                destroyed = destroyed + 1
            end
        end
    end
    if destroyed > 0 then
        debug.emit("connector swept %d asteroid(s) off %s", destroyed, platform.name)
    end
end

local function tick()
    storage_ready()

    -- Connector hubs represent a player's work and stock. A mod update must not rebuild
    -- them: the old per-build diagnostic reset did exactly that and wiped every bay and
    -- inventory item. Missing or hubless connectors are repaired by ensure_all/create_platform
    -- without touching a healthy one.

    -- Tell the manager this instance is loaded. One datagram per boot, sent from the
    -- server only (the RCON global exists there), after the identity has arrived. The
    -- manager waits for every instance before it runs the startup pre-sync.
    if (boot_pending or storage.connector_ready_pending) and rcon then
        boot_pending = false
        storage.connector_ready_pending = nil
        local version = (script.active_mods and script.active_mods["server-connector-mod"]) or "unknown"
        bus.push("connector_ready", {
            instance = INSTANCE(),
            role = role(),
            protocol = PROTOCOL,
            version = version,
            tick = game.tick,
        })
        record("ready", {role = role(), version = version})
    end

    -- There is no event for an asteroid appearing. The sweep runs every 10 ticks on
    -- connector platforms only and destroys both entity types: the chunk spawns and the
    -- asteroids that already reached the surface.
    if game.tick - (storage.connector_asteroids_at or 0) >= 10 then
        storage.connector_asteroids_at = game.tick
        for _, platform in pairs(force().platforms or {}) do
            sweep_platform(platform)
        end
    end

    -- Self-heal: a connector with no bays has been rebuilt or lost its grid, and nothing in
    -- the event-driven path may ever queue it again. Once a minute is enough.
    if game.tick - (storage.grid_sweep_at or 0) >= 600 then
        storage.grid_sweep_at = game.tick
        for _, platform in pairs(force().platforms or {}) do
            if platform.valid and is_connector(platform)
                and (platforms.bay_count(platform) or 0) == 0 then
                queue_base_grid(platform)
            end
        end
    end

    -- The base grid, one platform per tick. Five tries with a second between them, then the
    -- platform is left alone: a base slot a player already built is never moved or removed.
    local queue = storage.base_grid_queue
    if queue and next(queue) ~= nil and game.tick >= (storage.base_grid_not_before or 0) then
        local name, tries = next(queue)
        queue[name] = nil
        local target = nil
        for _, candidate in pairs(force().platforms or {}) do
            if candidate.valid and candidate.name == name and is_connector(candidate) then
                target = candidate
                break
            end
        end
        if target and target.hub and target.hub.valid and (target.scheduled_for_deletion or 0) == 0 then
            local result = platforms.ensure_base_grid(target)
            log(string.format("[%s] base grid on %s: ok=%s created=%d missing=%d tiles=%d %s",
                INSTANCE(), name, tostring(result.ok), result.created, result.missing, result.tiles,
                result.error or ""))
            if result.ok then
                storage.base_grid_done = storage.base_grid_done or {}
                storage.base_grid_done[name] = grid_key(target)
                protect(target)
            elseif tries < 4 then
                queue[name] = tries + 1
                storage.base_grid_not_before = game.tick + 60
            else
                log(string.format("[%s] base grid on %s: giving up after 5 tries", INSTANCE(), name))
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
        out.platforms[#out.platforms + 1] = state_of(INSTANCE(), true, true)
    else
        for _, planet in pairs(planets()) do
            out.platforms[#out.platforms + 1] = state_of(planet, true, true)
        end
    end
    return out
end

return {
    role = role,
    mark_boot = mark_boot,
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
    clear = clear,
    hub_set_item = hub_set_item,
    hub_cargo_page = hub_cargo_page,
    build_bay = build_bay,
    remove_bay = remove_bay,
    edit = edited,
    guard_build = guard_build,
    guard_mine = guard_mine,
    guard_death = guard_death,
    state_changed = state_changed,
    pod = pod_event,
    tick = tick,
    sweep = sweep_platform,
    planets = planets,
    pad_point = pad_point,
    quiet_trash = quiet_trash,
    set_groups = set_groups,
    enforce_providing = enforce_providing,
    refresh_spoilage = refresh_spoilage,
    spoilage_report = spoilage_report,
    read_groups = read_groups,
    read_cargo = read_cargo,
    read_layout = read_layout,
    read_section = read_section,
    build_filters = build_filters,
    write_section = write_section,
    pads = pads,
    probe = probe,
    INCOMING = INCOMING,
    OUTGOING = OUTGOING,
}
