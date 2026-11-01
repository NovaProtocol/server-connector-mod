-- server-connector-mod / control/platforms.lua
--
-- The fleet's space platforms, as this server sees them. A planet server holds a *copy*
-- of each real platform -- a hub and its cargo, no asteroids, nothing that can damage it --
-- because the fleet's platforms belong to the space server and a planet server must still
-- be able to see them, request from them and launch to them.
--
-- Also the API probes (platform_api, surface_api), which ask the running game which calls
-- it actually has instead of assuming, because two of this fleet's outages were guessed
-- calls.
--
-- Required as "__server-connector-mod__.control.platforms".

local state = require("__server-connector-mod__.control.state")
local debug = require("__server-connector-mod__.control.debug")
local bus = require("__server-connector-mod__.control.bus")

local instance = state.instance
local main_force = state.main_force

-- The transport is bus.lua, which this module can require at load: bus does not require
-- platforms. A require here used to be lazy (inside this function) to dodge the cycle, and
-- Factorio refuses that at runtime, so every adoption destroyed the platform and then threw
-- before the create was sent.
local function report_platform_create(name, record)
    bus.push("platform_create", {
        instance = instance(),
        name = name,
        location = record.location,
        starter_pack = record.starter_pack,
        quality = record.quality,
        request_id = record.request_id,
        tries = record.tries,
        tick = game.tick,
    })
end

-- A carried request is re-sent until the manager acks it. One hour is long enough for a
-- manager restart to be noticed and for the space server to come back.
local NATIVE_CREATE_TTL = 216000

-- A fake platform must not be deleted by an asteroid chunk that survives the sweep, and a
-- player must not be able to take it apart. `destructible` is damage only; `minable_flag`
-- is the script-controlled switch that stops a player mining the hub or a bay, and
-- `operable` stops the hub's GUI and quick-insert. A protected entity is a view.
local function protect_copy(platform, name)
    local function protect(entity, what)
        if not entity or not entity.valid then
            return
        end
        local ok, err = pcall(function()
            entity.destructible = false
            entity.minable_flag = false
            entity.operable = false
        end)
        if not ok then
            log(string.format("[%s] could not protect the %s of %s: %s",
                instance(), what, name, tostring(err)))
        end
    end

    protect(platform.hub, "hub")

    -- LuaSpacePlatform has no cargo_bays key; the bays are entities on its surface.
    local surface = platform.surface
    if surface then
        local ok, bays = pcall(function()
            return surface.find_entities_filtered{name = "cargo-bay"}
        end)
        if ok then
            for _, bay in pairs(bays or {}) do
                protect(bay, "cargo bay")
            end
        end
    end
end

-- A deconstruction order on a copy is cancelled where it is issued. `minable_flag`
-- already refuses the mine; this stops the order sitting there and being retried when a
-- build or a restart changes the flag.
local function cancel_copy_deconstruction(entity)
    if not entity or not entity.valid or instance() == "space" then
        return
    end
    local surface = entity.surface
    if not surface or not surface.platform then
        return
    end
    pcall(function() entity.cancel_deconstruction(entity.force) end)
    protect_copy(surface.platform, surface.platform.name)
end

--------------------------------------------------------------------------------
-- the fleet's platforms, as copies
--------------------------------------------------------------------------------

-- The free base grid every connector hub carries: 18 x 18 cargo bays (a bay is 4 tiles, so
-- 72 x 72 tiles) with the hub's own 2 x 2 in the middle, which leaves 320. They cannot be
-- mined or destroyed and they are not part of the mirrored layout, so a planet's copy and
-- the space server's real platform describe the same ship with the extras only.
local GRID = 18
local FALLBACK_HUB = 8
local FALLBACK_BAY = 4
local base_cache = nil

local function offset_key(dx, dy)
    return string.format("%.1f,%.1f", dx, dy)
end

-- The grid is a constant of the prototypes, so one table per load is fine. It is not saved.
local function base_offsets()
    if base_cache then
        return base_cache
    end
    local hub_size, bay_size = FALLBACK_HUB, FALLBACK_BAY
    local ok, h, b = pcall(function()
        return prototypes.entity["space-platform-hub"].tile_width,
            prototypes.entity["cargo-bay"].tile_width
    end)
    if ok and type(h) == "number" and type(b) == "number" and b > 0 and h >= b and h % b == 0 then
        hub_size, bay_size = h, b
    end
    local half = hub_size / 2
    local list, lookup = {}, {}
    for i = 0, GRID - 1 do
        local dx = (i - (GRID - 1) / 2) * bay_size
        for j = 0, GRID - 1 do
            local dy = (j - (GRID - 1) / 2) * bay_size
            if not (math.abs(dx) < half and math.abs(dy) < half) then
                list[#list + 1] = {x = dx, y = dy}
                lookup[offset_key(dx, dy)] = true
            end
        end
    end
    base_cache = {list = list, lookup = lookup, hub = hub_size, bay = bay_size, span = GRID * bay_size}
    return base_cache
end

local function is_base_offset(dx, dy)
    return base_offsets().lookup[offset_key(dx, dy)] == true
end

local function is_base_bay(hub, bay)
    if not hub or not hub.valid or not bay or not bay.valid then
        return false
    end
    return is_base_offset(bay.position.x - hub.position.x, bay.position.y - hub.position.y)
end

-- Every cargo bay on the surface, sorted.
local function all_bays(platform)
    local surface = platform.surface
    if not surface then
        return nil
    end
    local ok, bays = pcall(function()
        return surface.find_entities_filtered{name = "cargo-bay"}
    end)
    if not ok or not bays then
        return nil
    end
    table.sort(bays, function(a, b)
        if a.position.x ~= b.position.x then
            return a.position.x < b.position.x
        end
        return a.position.y < b.position.y
    end)
    return bays
end

-- The EXTRA bays only: everything that is not a base bay. This is the mirrored shape.
local function bay_list(platform)
    local all = all_bays(platform)
    if not all then
        return nil
    end
    local hub = platform.hub
    if not hub or not hub.valid then
        return all
    end
    local out = {}
    for _, bay in ipairs(all) do
        if not is_base_bay(hub, bay) then
            out[#out + 1] = bay
        end
    end
    return out
end

local function bay_count(platform)
    local bays = bay_list(platform)
    return bays and #bays or nil
end

local function asteroid_count(platform)
    local ok, chunks = pcall(function()
        return #platform.find_asteroid_chunks_filtered{}
    end)
    return ok and chunks or nil
end

-- The real ship's hub-and-bay shape, as bay offsets from the hub.
--
-- Positions, not just a count: a copy with the right number of bays in a ring is the
-- right size and the wrong ship. The string is sorted so the same layout has the same
-- text on both servers and can be compared directly.
local function layout_of(platform)
    local hub = platform.hub
    local bays = bay_list(platform)
    if not hub or not bays then
        return nil
    end
    local parts = {}
    for _, bay in ipairs(bays) do
        parts[#parts + 1] = string.format("%.1f,%.1f",
            bay.position.x - hub.position.x, bay.position.y - hub.position.y)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function layout_hash(platform)
    local text = layout_of(platform) or ""
    local value = 5381
    for index = 1, #text do
        value = (value * 33 + string.byte(text, index)) % 4294967296
    end
    return value
end

-- Entities on a copy that are not the hub or a cargo bay. A copy is those two things and
-- nothing else, so this should be zero; it is reported rather than assumed.
local function other_entities(platform)
    local surface = platform.surface
    if not surface then
        return nil
    end
    local ok, entities = pcall(function()
        return surface.find_entities_filtered{}
    end)
    if not ok or not entities then
        return nil
    end
    local count = 0
    for _, entity in ipairs(entities) do
        if entity.valid and entity.name ~= "space-platform-hub" and entity.name ~= "cargo-bay"
            and entity.type ~= "asteroid-chunk" and entity.type ~= "asteroid" then
            count = count + 1
        end
    end
    return count
end

-- Give a copy the real platform's hub-and-bay layout.
--
-- `layout` is the real ship's bay offsets from its hub, sorted. The copy's hub is the
-- anchor, so the same offsets put every bay where it is on the real ship. Existing bays
-- are moved rather than destroyed where possible: they carry capacity and a copy's cargo
-- is mirrored into the hub. With no layout (an older manager) fall back to the count, and
-- then only add missing bays.
local function ensure_bays(platform, count, layout)
    local surface = platform.surface
    if not surface then
        return
    end

    local targets = {}
    for part in string.gmatch(layout or "", "([^;]+)") do
        local x, y = string.match(part, "^(-?[%d%.]+),(-?[%d%.]+)$")
        if x and y then
            targets[#targets + 1] = {x = tonumber(x), y = tonumber(y)}
        end
    end
    table.sort(targets, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.y < b.y
    end)

    local bays = bay_list(platform) or {}
    local hub = platform.hub
    local force = main_force()

    if hub and #targets > 0 then
        for index, offset in ipairs(targets) do
            local position = {x = hub.position.x + offset.x, y = hub.position.y + offset.y}
            local bay = bays[index]
            if bay and bay.valid then
                if math.abs(bay.position.x - position.x) > 0.01
                    or math.abs(bay.position.y - position.y) > 0.01 then
                    pcall(function() bay.teleport(position) end)
                end
            else
                pcall(function()
                    surface.create_entity{name = "cargo-bay", position = position, force = force.name}
                end)
            end
        end
        for index = #targets + 1, #bays do
            local bay = bays[index]
            if bay and bay.valid then
                pcall(function() bay.destructible = true end)
                pcall(function() bay.destroy() end)
            end
        end
        return
    end

    count = math.max(0, math.floor(tonumber(count) or 0))
    for index = #bays + 1, count do
        local angle = (index - 1) * (2 * math.pi / math.max(count, 1))
        local radius = 4 + math.floor((index - 1) / 8) * 2
        local position = {x = math.cos(angle) * radius, y = math.sin(angle) * radius}
        pcall(function()
            surface.create_entity{name = "cargo-bay", position = position, force = force.name}
        end)
    end
    -- The fallback used to add only. A copy built from an older layout therefore kept
    -- every extra bay forever when the real platform had no layout (for example a new
    -- platform with zero bays). Trim to the count as well.
    for index = count + 1, #bays do
        local bay = bays[index]
        if bay and bay.valid then
            pcall(function() bay.destructible = true end)
            pcall(function() bay.destroy() end)
        end
    end
end


-- Give a connector its free base grid: foundation tiles first, then the 320 bays, all of
-- them unminable and indestructible. Script creation raises no build event, so nothing is
-- mirrored and no clock is bumped -- raise_built is deliberately not passed.
local function ensure_base_grid(platform)
    local result = {ok = false, created = 0, missing = 0, tiles = 0}
    if not platform or not platform.valid then
        result.error = "invalid platform"
        return result
    end
    local hub, surface = platform.hub, platform.surface
    if not hub or not hub.valid or not surface then
        result.error = "no hub"
        return result
    end

    local grid = base_offsets()
    local origin = hub.position
    local half = grid.span / 2

    -- The tiles must exist before a bay can stand on them.
    pcall(function() surface.request_to_generate_chunks(origin, math.ceil(half / 32) + 1) end)
    pcall(function() surface.force_generate_chunk_requests() end)

    -- The tile under the hub is the platform's own foundation. Use its name.
    local foundation = nil
    local ok_tile, tile = pcall(function() return surface.get_tile(origin.x, origin.y) end)
    if ok_tile and tile and tile.valid then
        foundation = tile.name
    end
    if not foundation or foundation == "empty-space" then
        foundation = "space-platform-foundation"
    end
    if not (prototypes.tile and prototypes.tile[foundation]) then
        result.error = "no foundation tile " .. tostring(foundation)
        return result
    end

    local x0 = math.floor(origin.x - half)
    local y0 = math.floor(origin.y - half)
    local tiles = {}
    for x = x0, x0 + grid.span - 1 do
        for y = y0, y0 + grid.span - 1 do
            local current = surface.get_tile(x, y)
            if current.name ~= foundation then
                tiles[#tiles + 1] = {name = foundation, position = {x = x, y = y}}
            end
        end
    end
    if #tiles > 0 then
        local ok, err = pcall(function() surface.set_tiles(tiles, true) end)
        if not ok then
            result.error = "set_tiles failed: " .. tostring(err)
            return result
        end
        result.tiles = #tiles
    end

    local existing = {}
    for _, bay in ipairs(all_bays(platform) or {}) do
        existing[offset_key(bay.position.x - origin.x, bay.position.y - origin.y)] = bay
    end
    local force_name = main_force().name
    for _, offset in ipairs(grid.list) do
        local bay = existing[offset_key(offset.x, offset.y)]
        if not bay then
            local ok, made = pcall(function()
                return surface.create_entity{
                    name = "cargo-bay",
                    position = {x = origin.x + offset.x, y = origin.y + offset.y},
                    force = force_name,
                }
            end)
            if ok and made then
                bay = made
                result.created = result.created + 1
            else
                result.missing = result.missing + 1
            end
        end
        if bay and bay.valid then
            pcall(function()
                bay.destructible = false
                bay.minable_flag = false
            end)
        end
    end
    result.ok = result.missing == 0
    return result
end

-- Remove a copy. The hub and bays are protected (destructible=false); a protected copy
-- survives destroy(0), which looked like a successful call and left the platform in place.
-- Make them destructible, cancel any earlier schedule and destroy on the next tick -- the
-- pattern the 0.35.6 cleanup used and the one that actually removed them.
local function destroy_copy(platform)
    if not platform or not platform.valid then
        return true
    end
    if platform.hub then
        pcall(function() platform.hub.destructible = true end)
    end
    for _, bay in ipairs(all_bays(platform) or {}) do
        pcall(function() bay.destructible = true end)
    end
    pcall(function() platform.cancel_deletion() end)
    local ok, err = pcall(function() platform.destroy(1) end)
    if not ok then
        log(string.format("[%s] could not destroy the copy of %s: %s",
            instance(), platform.name, tostring(err)))
    end
    return ok
end

-- A copy is made by this mod; a native platform is made by the game when a starter pack
-- launches or a player uses the new-platform button. A copy must never enter the native
-- platform path, or the mirror's own creation would ask for another copy for ever.
local function is_copy(platform)
    if not platform then
        return false
    end
    if storage.creating_copy == platform.name then
        return true
    end
    return storage.copies and storage.copies[platform.name] or false
end

-- A pending request: no hub, no surface, waiting for its starter pack. The game holds it in
-- the force's platform list, so it must never be read as a platform this server owns.
local function is_pending_request(p)
    if not p or not p.valid or (p.scheduled_for_deletion or 0) ~= 0 then
        return false
    end
    if is_copy(p) then
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

local function owns_planet()
    local own = (storage.topology or {})[instance()]
    return own ~= nil and own.kind == "planet"
end

-- A prototype field as a plain string (a name can be a prototype too).
local function plain_value(value)
    if type(value) == "table" or type(value) == "userdata" then
        return value.name
    end
    return value
end

-- Remove a platform that the game created natively on a planet. The space server owns the
-- real one; the planet only gets a protected copy back from the normal mirror.
local function remove_native_platform(platform)
    if not platform or not platform.valid or is_copy(platform) then
        return false
    end
    return destroy_copy(platform)
end

-- Carry a player's platform request to the space server. It reports first and destroys
-- second, so a failed destroy still leaves the request with the manager; it is idempotent,
-- because two events, ensure_all and the retry pass can all reach the same platform.
local function adopt_native_platform(platform, name)
    if instance() == "space" or not state.known() or not owns_planet() then
        return false
    end
    if not platform or not platform.valid or is_copy(platform) then
        return false
    end
    name = name or platform.name
    if (platform.scheduled_for_deletion or 0) ~= 0 then
        return true
    end
    if is_pending_request(platform) then
        return false
    end

    -- A platform with buildings on it is somebody's work. It is reported once, never destroyed.
    local others = other_entities(platform)
    if others and others > 0 then
        storage.stray_warned = storage.stray_warned or {}
        if not storage.stray_warned[name] then
            storage.stray_warned[name] = true
            log(string.format("[%s] platform %s holds %d buildings; it was NOT moved to the space server",
                instance(), tostring(name), others))
            main_force().print(string.format(
                "Platform '%s' holds buildings and stays on this server. Only a fresh platform is moved.",
                tostring(name)))
        end
        return false
    end

    storage.native_creates = storage.native_creates or {}
    local record = storage.native_creates[name]
    local location = platform.space_location and platform.space_location.name or instance()
    local pack, quality = nil, nil
    local ok_pack, starter = pcall(function() return platform.starter_pack end)
    if ok_pack and starter then
        pack, quality = plain_value(starter.name), plain_value(starter.quality)
    end
    record = record or {}
    record.location = record.location or location
    record.starter_pack = record.starter_pack or pack
    record.quality = record.quality or quality
    record.request_id = record.request_id or string.format("%s:%s:%d", instance(), name, game.tick)
    record.at = record.at or game.tick
    record.tries = (record.tries or 0) + 1
    storage.native_creates[name] = record

    -- Report FIRST. If the destroy fails the manager still has the request.
    report_platform_create(name, record)
    if not destroy_copy(platform) then
        log(string.format("[%s] could not remove native %s; the retry pass will try again",
            instance(), tostring(name)))
        return false
    end
    if storage.request_in then
        storage.request_in[name] = nil
    end
    main_force().print(string.format("Platform '%s' is being built on the space server.", tostring(name)))
    log(string.format("[%s] removed native %s and asked the space server to create it at %s (id %s)",
        instance(), tostring(name), tostring(record.location), record.request_id))
    return true
end

-- Called for every platform on a planet server that is not the connector.
local function settle_stray(platform)
    if instance() == "space" or not state.known() or not owns_planet() then
        return "skipped"
    end
    if not platform or not platform.valid then
        return "gone"
    end
    if (platform.scheduled_for_deletion or 0) ~= 0 then
        return "leaving"
    end
    if is_pending_request(platform) then
        return "pending"
    end
    if is_copy(platform) then
        destroy_copy(platform)
        return "copy removed"
    end
    if adopt_native_platform(platform, platform.name) then
        return "adopted"
    end
    return "kept"
end

-- A surface that is a platform's but has no platform attached yet is checked again for five
-- seconds. Platform surfaces are named "platform-<n>".
local function watch_surface(index)
    storage.surface_watch = storage.surface_watch or {}
    storage.surface_watch[index] = game.tick
end

local function tick(is_connector)
    local watch = storage.surface_watch
    if not watch or next(watch) == nil then
        return
    end
    for index, since in pairs(watch) do
        local surface = game.get_surface(index)
        if not surface or not surface.valid or game.tick - since > 300 then
            watch[index] = nil
        elseif surface.platform and surface.platform.valid then
            watch[index] = nil
            local platform = surface.platform
            if not (is_connector and is_connector(platform)) and not storage.connector_creating
                and not storage.creating_copy then
                adopt_native_platform(platform, platform.name)
            end
        end
    end
end

-- Re-send a carried request until the manager acks it. A platform that reappeared here is
-- re-adopted; one that never comes back is given up on after the TTL.
local function retry_native_creates()
    if instance() == "space" or not state.known() then
        return 0
    end
    local records = storage.native_creates
    if not records then
        return 0
    end
    local names = {}
    for name in pairs(records) do
        names[#names + 1] = name
    end
    table.sort(names)

    local sent = 0
    for _, name in ipairs(names) do
        local record = records[name]
        local age = game.tick - (record.at or 0)
        local native = nil
        for _, p in pairs(main_force().platforms or {}) do
            if p.valid and p.name == name and not is_copy(p) and (p.scheduled_for_deletion or 0) == 0 then
                native = p
                break
            end
        end
        if age > NATIVE_CREATE_TTL then
            records[name] = nil
            log(string.format("[%s] native %s was never confirmed after %d ticks; giving up",
                instance(), tostring(name), age))
        elseif native then
            adopt_native_platform(native, name)
            sent = sent + 1
        else
            record.tries = (record.tries or 1) + 1
            report_platform_create(name, record)
            sent = sent + 1
        end
    end
    return sent
end

-- The manager's confirmation. failed=true means the space server could not make it.
local function create_ack(args)
    if type(args) ~= "table" or type(args.name) ~= "string" then
        return {ok = false, error = "a name is required"}
    end
    local records = storage.native_creates or {}
    local record = records[args.name]
    if not record then
        return {ok = true, already = true}
    end
    if args.request_id and record.request_id and args.request_id ~= record.request_id then
        return {ok = false, error = "another request holds that name"}
    end
    records[args.name] = nil
    if args.failed then
        main_force().print(string.format("Platform '%s' could not be built on the space server: %s",
            args.name, tostring(args.error or "unknown error")))
    elseif args.final_name and args.final_name ~= args.name then
        main_force().print(string.format("Platform '%s' was built on the space server as '%s'.",
            args.name, tostring(args.final_name)))
    else
        main_force().print(string.format("Platform '%s' is on the space server.", args.name))
    end
    return {ok = true}
end

local function mirror_platforms(entries)
    -- Retired as a write path. The connector model owns the platforms now: one per planet,
    -- mirrored per event. A whole-list mirror prunes anything it does not know about, which
    -- is what destroyed a platform created between the read and the apply.
    do return {instance = instance(), skipped = "the connector model owns the platforms"} end
end

-- Reading a rocket silo's starter-pack requests.
--
-- Nothing in this mod touches a silo's requests; this exists so a launch that goes nowhere
-- leaves a trace. A count going 1 then 0 with no rocket launched is the report we need, and a
-- count of -1 means the point could not be read.
--
-- The silo's logistic point is found by probing rather than by name: the member index that
-- carries a silo's rocket requests is not the same key on every build, and asking for the
-- wrong one returns nothing at all. The first value that answers is cached.
local function silo_request_point(silo)
    -- The requester point is the one that holds the starter-pack request. Ask for it by the
    -- name the API documents before probing: the probe takes whatever answers first, and
    -- logistic_container answers on a silo with no request on it at all.
    local named = defines.logistic_member_index and defines.logistic_member_index.rocket_silo_requester
    if named ~= nil then
        local ok, point = pcall(function()
            return silo.get_logistic_point(named)
        end)
        if ok and point then
            storage.silo_member = named
            return point
        end
    end

    if storage.silo_member ~= nil then
        local ok, point = pcall(function()
            return silo.get_logistic_point(storage.silo_member)
        end)
        if ok and point then
            return point
        end
        storage.silo_member = nil
    end

    for _, value in pairs(defines.logistic_member_index or {}) do
        local ok, point = pcall(function()
            return silo.get_logistic_point(value)
        end)
        if ok and point then
            storage.silo_member = value
            return point
        end
    end
    return nil
end

local function starter_pack_requests(silo)
    if not silo or not silo.valid or silo.name ~= "rocket-silo" then
        return -1
    end

    local point = silo_request_point(silo)
    if not point then
        return -1
    end

    local count = 0
    for _, section in pairs(point.sections or {}) do
        for _, filter in pairs(section.filters or {}) do
            local value = filter and filter.value
            if value and value.name == "space-platform-starter-pack" then
                count = count + 1
            end
        end
    end
    return count
end

-- The starter-pack count on every silo of this planet, and the platform names this server can
-- see. Logged only on a change, once a minute: the event that should report a silo edit does
-- not always fire, and a launch that goes nowhere has to leave some trace.
local function watch()
    if instance() == "space" then
        return
    end

    local surface = game.surfaces[instance()]
    if not surface then
        return
    end

    storage.silo_requests = storage.silo_requests or {}

    local total = 0
    local readable = true
    local ok, silos = pcall(function()
        return surface.find_entities_filtered{name = "rocket-silo"}
    end)
    if not ok then
        readable = false
    end

    for _, silo in ipairs((ok and silos) or {}) do
        local count = starter_pack_requests(silo)
        if count < 0 then
            readable = false
        else
            total = total + count
        end
    end

    -- Once per build, not once per save: the first pass is the line that says whether the
    -- reader can see a silo at all, and a stored flag from an older build hid it.
    -- The build itself, not a number to remember to bump: the first pass of every version
    -- prints the silo inventory, and a save carrying an older value always re-seeds.
    local WATCH_VERSION = (script.active_mods and script.active_mods["server-connector-mod"]) or "unknown"
    if storage.watch_seeded ~= WATCH_VERSION then
        storage.watch_seeded = WATCH_VERSION
        log(string.format("[%s] platform watch: %d silo(s), requests=%s, member=%s",
            instance(), #((ok and silos) or {}),
            readable and tostring(total) or "unreadable",
            tostring(storage.silo_member)))

        -- Once per build: every silo, in full. This is the line set that says whether the
        -- reader can see a request at all, and which silo holds it.
        for _, silo in ipairs((ok and silos) or {}) do
            debug.dump("silo " .. tostring(silo.unit_number), debug.silo_table(silo))
        end
    end

    if readable then
        local previous = storage.silo_requests[surface.name]
        if previous ~= total then
            log(string.format("[%s] starter-pack requests on %s: %d (was %s)",
                instance(), surface.name, total, tostring(previous)))
            for _, silo in ipairs((ok and silos) or {}) do
                local count = starter_pack_requests(silo)
                if count > 0 then
                    debug.dump("silo with " .. count .. " request(s) " .. tostring(silo.unit_number),
                        debug.silo_table(silo))
                end
            end
            storage.silo_requests[surface.name] = total
        end
    end

    -- Every pass, the whole platform list in compact form: this is what the fleet believes it
    -- holds here, and a pending request shows up in it as a platform with no hub and no
    -- surface.
    local snapshot = {}
    for _, platform in pairs(main_force().platforms or {}) do
        local entry = debug.platform_table(platform)
        entry.copy = is_copy(platform)
        snapshot[#snapshot + 1] = entry
    end
    table.sort(snapshot, function(a, b) return (a.index or 0) < (b.index or 0) end)
    debug.dump("watch platforms", snapshot)

    local first = storage.platform_names == nil
    local seen = {}
    for _, platform in pairs(main_force().platforms or {}) do
        seen[platform.name] = true
        if not first and not storage.platform_names[platform.name] then
            log(string.format("[%s] platform appeared: %s (copy=%s)",
                instance(), platform.name, tostring(is_copy(platform))))
            debug.dump("platform appeared", debug.platform_table(platform))
        end
    end
    for name in pairs(storage.platform_names or {}) do
        if not seen[name] then
            log(string.format("[%s] platform disappeared: %s", instance(), name))
            debug.emit("platform disappeared: %s left force.platforms (no hub, surface or deletion detail is readable after the fact)",
                tostring(name))
        end
    end
    storage.platform_names = seen
end

-- Drop this server's copies so the next mirror push rebuilds them from the fleet's own data.
-- The manager calls this and pushes the platform list a moment later, so doing both here
-- would need entries it has not sent yet. An empty mirror list is exactly "remove every copy".
local function rebuild_platforms()
    return mirror_platforms({})
end

-- A real platform, created where the platforms really live.
--
-- The planet mirror asks for this when a player launches a starter pack: the native
-- platform exists in the planet's save, but the space server is the authority and has to
-- create the real one. Idempotent by name. It runs while players are connected: the join
-- desync was the GUI rebuild, and waiting for an empty space server meant a starter pack
-- launched while somebody watched the platform screen was never adopted.
-- A prototype field as a plain string: quality is a LuaQualityPrototype, and a name can be
-- a prototype too. The manager sends strings, but a moved platform carries what the game
-- handed us.
local function plain(value)
    if type(value) == "table" or type(value) == "userdata" then
        return value.name
    end
    return value
end

local function reserved_name(name)
    return name == "Space Platforms" or string.match(name, "^~?%[planet=[^%]]+%] .+ Hub$") ~= nil
end

local function name_in_use(force, name)
    for _, p in pairs(force.platforms or {}) do
        if p.valid and p.name == name then
            return p
        end
    end
    return nil
end

local function free_name(force, name, tag)
    local candidate = string.format("%s (%s)", name, tag)
    local n = 2
    while (name_in_use(force, candidate) or reserved_name(candidate)) and n < 50 do
        candidate = string.format("%s (%s %d)", name, tag, n)
        n = n + 1
    end
    return candidate
end

local function create_platform(entry)
    if instance() ~= "space" then
        return {ok = false, error = "only the space server creates real platforms"}
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return {ok = false, error = "a platform needs a name"}
    end
    local force = main_force()

    local planet = entry.location
    if type(planet) ~= "string" or planet == "" or planet == "space" then
        planet = "nauvis"
    elseif not (game.planets and game.planets[planet]) then
        return {ok = false, error = "unknown planet " .. tostring(planet), permanent = true}
    end

    -- A request that is re-sent is the same request: same id means "already done". A
    -- different request that happens to share a name gets a suffix instead of merging.
    storage.platform_origin = storage.platform_origin or {}
    local request_id = entry.request_id
    local existing = name_in_use(force, entry.name)
    local final = entry.name
    if existing then
        if (existing.scheduled_for_deletion or 0) ~= 0 then
            return {ok = false, retry = true, error = "a platform with that name is being deleted"}
        end
        local record = storage.platform_origin[entry.name]
        if request_id == nil or (record and record.id == request_id) then
            return {ok = true, name = entry.name, existed = true}
        end
        final = free_name(force, entry.name, tostring(entry.origin or planet))
    elseif reserved_name(entry.name) then
        final = free_name(force, entry.name, tostring(entry.origin or planet))
    end

    -- The pack travels with the platform: a request moved between servers must come back as
    -- the same pack, and a quality pack has to survive the round trip too.
    local pack = plain(entry.starter_pack)
    if type(pack) ~= "string" or not prototypes.item[pack] then
        pack = "space-platform-starter-pack"
    end
    local quality = plain(entry.quality)
    if quality ~= nil and (type(quality) ~= "string"
        or not (prototypes.quality and prototypes.quality[quality])) then
        quality = nil
    end

    debug.dump("create_platform entry", {
        raw = entry,
        name = entry.name,
        location = planet,
        pack = pack,
        quality = quality,
    })

    local ok, created = pcall(function()
        return force.create_space_platform{
            planet = planet,
            name = final,
            starter_pack = quality and {name = pack, quality = quality} or pack,
        }
    end)
    if not ok or not created then
        debug.emit("create_platform: create_space_platform failed for %s: %s", entry.name, tostring(created))
        return {ok = false, error = tostring(created)}
    end
    debug.dump("create_platform created", debug.platform_table(created))

    -- apply_starter_pack returns the hub, not a boolean. A silent failure used to leave the
    -- platform in the list with no hub, which is exactly a pending request: remove it.
    local applied, hub = pcall(function()
        return created.apply_starter_pack(true)
    end)
    if not applied or not hub then
        debug.emit("create_platform: starter pack failed for %s (%s); destroying it",
            final, tostring(hub))
        pcall(function() created.destroy(1) end)
        return {ok = false, error = "the starter pack could not be applied: " .. tostring(hub)}
    end

    storage.platform_origin[final] = {
        id = request_id,
        origin = entry.origin,
        requested = entry.name,
        at = game.tick,
    }
    for stored in pairs(storage.platform_origin) do
        if not name_in_use(force, stored) then
            storage.platform_origin[stored] = nil
        end
    end

    debug.emit("create_platform: created %s at %s pack=%s quality=%s hub=%s",
        final, planet, pack, tostring(quality), tostring(hub.name))
    log(string.format("[%s] created platform %s at %s", instance(), final, planet))
    return {ok = true, name = final, requested = entry.name, renamed = final ~= entry.name,
        location = planet, starter_pack = pack, quality = quality}
end

-- What this server's platforms are.
--
-- Read-only. Every field here is one the runtime docs list for LuaSpacePlatform or its
-- hub, and nothing is invented. On a planet this is the list of that server's copies;
-- what to do with them is the manager's decision.
local function platforms()
    local out = {}
    for _, platform in pairs(main_force().platforms or {}) do
        out[#out + 1] = {
            name = platform.name,
            index = platform.index,
            state = tostring(platform.state),
            location = platform.space_location and platform.space_location.name or nil,
            connection = platform.space_connection and platform.space_connection.name or nil,
            distance = platform.distance,
            paused = platform.paused,
            bays = bay_count(platform),
            hub = platform.hub ~= nil,
            hub_destructible = (function()
                local ok, value = pcall(function()
                    return platform.hub and platform.hub.destructible
                end)
                if ok then
                    return value
                end
                return nil
            end)(),
            cargo_bay_destructible = (function()
                local surface = platform.surface
                if not surface then
                    return nil
                end
                local ok, bays = pcall(function()
                    return surface.find_entities_filtered{name = "cargo-bay"}
                end)
                if not ok or not bays or not bays[1] then
                    return nil
                end
                local ok2, value = pcall(function() return bays[1].destructible end)
                if ok2 then
                    return value
                end
                return nil
            end)(),
            hidden = platform.hidden,
            deleting_in = platform.scheduled_for_deletion,
            asteroids = (function()
                local ok, chunks = pcall(function() return #platform.find_asteroid_chunks_filtered{} end)
                return ok and chunks or nil
            end)(),
        }
    end

    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return {instance = instance(), platforms = out}
end

--------------------------------------------------------------------------------
-- API probes: ask the game, do not assume
--------------------------------------------------------------------------------

-- What the game actually offers, asked rather than assumed.
--
-- Everything here is read-only: names and counts, never a move, a pause or a creation.
-- The reading probes were enough to diagnose what this build does, and a probe that changes
-- a real platform is a world change driven over RCON, which is not safe with anybody
-- connected.
local function platform_api(name)
    local force = main_force()
    local tried = {}
    local function attempt(label, fn)
        local ok, value = pcall(fn)
        tried[label] = ok and ("ok: " .. tostring(value)) or ("error: " .. tostring(value))
    end

    -- The starter pack's item name, asked for rather than guessed: creation requires
    -- one, and a guessed item name would be the third guess today the game has had to
    -- correct. Whichever of these exists is the one to use.
    for _, name in ipairs({"space-platform-starter-pack", "space-platform-foundation",
                           "platform-starter-pack", "space-platform-hub",
                           "space-platform-starter", "cargo-landing-pad"}) do
        attempt("item:" .. name, function()
            local item = prototypes.item[name]
            return item and item.name or "no such item"
        end)
    end

    -- Which logistic member index a hub's requests are on, asked of the game rather than
    -- read out of the defines page: the names are the game's, not mine to remember.
    attempt("member index names", function()
        local names = {}
        for name, _ in pairs(defines.logistic_member_index) do
            names[#names + 1] = name
        end
        table.sort(names)
        return table.concat(names, ",")
    end)

    attempt("which member index answers", function()
        local first = nil
        for _, platform in pairs(force.platforms or {}) do
            first = platform
            break
        end
        if not first or not first.hub then
            return "no hub"
        end

        local answered = {}
        for name, value in pairs(defines.logistic_member_index) do
            local ok, point = pcall(function() return first.hub.get_logistic_point(value) end)
            if ok and point then
                local sections = 0
                pcall(function() sections = #point.sections end)
                answered[#answered + 1] = name .. "(sections=" .. tostring(sections) .. ")"
            end
        end
        table.sort(answered)
        return table.concat(answered, " | ")
    end)

    attempt("platforms", function() return #force.platforms end)

    return {instance = instance(), tried = tried, platforms = #force.platforms}
end

-- Which of the surface calls this build of the game actually has, and which way of
-- asking a surface for its entities finds them.
--
-- Everything here is asked under pcall, because that is the whole lesson: reading a key
-- an API object does not have is an error rather than a nil, and an error raised from
-- the boot-time handler quits the server. So the question is asked of the game instead
-- of assumed, and the answers come back as strings.
local function surface_api()
    local surface = game.surfaces[instance()] or game.surfaces[1]
    if not surface then
        return {instance = instance(), error = "no surface"}
    end

    local out = {}
    local function try(name, fn)
        local ok, value = pcall(fn)
        if not ok then
            out[name] = "ERROR: " .. tostring(value)
        elseif type(value) == "table" then
            out[name] = "table, " .. tostring(#value) .. " entries"
        else
            out[name] = type(value)
        end
    end

    for _, name in ipairs({"delete_chunk", "get_chunk", "get_chunks", "set_chunk_generated_status",
                           "find_entities", "find_entities_filtered", "get_map_bounds"}) do
        try(name, function() return surface[name] end)
    end

    try("find_entities_filtered{}", function() return surface.find_entities_filtered{} end)
    try("find_entities()", function() return surface.find_entities() end)
    try("find_entities_filtered{force=player}", function()
        return surface.find_entities_filtered{force = main_force().name}
    end)

    return {instance = instance(), surface = surface.name, calls = out}
end

return {
    mirror_platforms = mirror_platforms,
    rebuild_platforms = rebuild_platforms,
    adopt_native_platform = adopt_native_platform,
    retry_native_creates = retry_native_creates,
    settle_stray = settle_stray,
    watch_surface = watch_surface,
    tick = tick,
    create_ack = create_ack,
    is_pending_request = is_pending_request,
    starter_pack_requests = starter_pack_requests,
    watch = watch,
    create_platform = create_platform,
    remove_native_platform = remove_native_platform,
    is_copy = is_copy,
    platforms = platforms,
    platform_api = platform_api,
    surface_api = surface_api,
    layout_of = layout_of,
    layout_hash = layout_hash,
    bay_count = bay_count,
    bay_list = bay_list,
    all_bays = all_bays,
    is_base_bay = is_base_bay,
    is_base_offset = is_base_offset,
    ensure_base_grid = ensure_base_grid,
    ensure_bays = ensure_bays,
    destroy_copy = destroy_copy,
    asteroid_count = asteroid_count,
    other_entities = other_entities,
    cancel_copy_deconstruction = cancel_copy_deconstruction,
}
