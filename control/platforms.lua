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

local MOD = state.MOD
local known = state.known
local instance = state.instance
local main_force = state.main_force

-- Required lazily: outbound.lua requires platforms.lua, so a top-level require here is a
-- cycle and Factorio refuses to load the mod. By the time a mirror runs, outbound is loaded.
local function report_platform_create(name, location)
    local outbound = require("__server-connector-mod__.control.outbound")
    outbound.push("platform_create", {
        instance = instance(),
        name = name,
        location = location,
        tick = game.tick,
    })
end

-- A write to a copy's position, said out loud when the game refuses it.
--
-- These were wrapped and silent, and a silent refusal looks exactly like a copy that
-- follows: the write happens, nothing changes, and nobody is told. Three bugs today were
-- hidden by the same pattern.
local function set_position(platform, field, value)
    if value == nil then
        return
    end

    local ok, err = pcall(function() platform[field] = value end)
    if not ok then
        log(string.format("[%s] could not set %s to %s on %s: %s",
            instance(), field, tostring(value), platform.name, tostring(err)))
    end
end

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

local function bay_list(platform)
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

local function bay_count(platform)
    local bays = bay_list(platform)
    return bays and #bays or nil
end

local function copy_is_protected(platform)
    local hub = platform.hub
    if hub and (hub.destructible or hub.minable_flag or hub.operable) then
        return false
    end
    for _, bay in ipairs(bay_list(platform) or {}) do
        if bay.destructible or bay.minable_flag or bay.operable then
            return false
        end
    end
    return true
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
            and entity.type ~= "asteroid-chunk" then
            count = count + 1
        end
    end
    return count
end

local function destroy_other(platform)
    local surface = platform.surface
    if not surface then
        return
    end
    local ok, entities = pcall(function()
        return surface.find_entities_filtered{}
    end)
    if not ok or not entities then
        return
    end
    for _, entity in ipairs(entities) do
        if entity.valid and entity.name ~= "space-platform-hub" and entity.name ~= "cargo-bay"
            and entity.type ~= "asteroid-chunk" then
            pcall(function() entity.destroy() end)
        end
    end
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
    for _, bay in ipairs(bay_list(platform) or {}) do
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

-- Remove a platform that the game created natively on a planet. The space server owns the
-- real one; the planet only gets a protected copy back from the normal mirror.
local function remove_native_platform(platform)
    if not platform or not platform.valid or is_copy(platform) then
        return false
    end
    return destroy_copy(platform)
end

-- Make, keep or remove this server's copies of the fleet's platforms.
--
-- An order, not a decision: the list comes from the manager, which is the only thing
-- that can see the real platforms wherever they are. A planet server's copy is a hub and
-- cargo bays -- the starter pack and nothing else, no asteroid collectors, no chemical
-- plants -- with no asteroids and nothing that can damage it, because nothing here runs a
-- platform. It is a place to look at and to launch to.
--
-- Only a planet gets copies: the space server is where the real platforms live, and a
-- custom world has no business holding one. Called over RCON, so only the server runs it.
local function mirror_platforms(entries)
    if not known() then
        return {instance = instance(), skipped = "no identity"}
    end

    -- Applied even while a player is connected. The join desync was the per-client GUI
    -- rebuild counter, not the platform mirror; refusing here left a starter-pack platform
    -- waiting forever whenever its owner was standing on the planet or the space server.
    if instance() == "space" then
        return {instance = instance(), skipped = "the real platforms live here"}
    end

    local own = (storage.topology or {})[instance()]
    if not own or own.kind ~= "planet" then
        return {instance = instance(), skipped = "not a planet"}
    end

    entries = entries or {}
    storage.fleet_platforms = entries

    -- Either an array or a table keyed by something else: the JSON is decoded by the
    -- game's own helper, and which shape comes back is the helper's business, not
    -- something to be assumed. The count is reported for the same reason.
    --
    -- Grouped by name, because platform names are not unique: the fleet has several
    -- platforms called [item=calcite] and one called LOL. Keying by name collapsed them
    -- and left the planet short of copies. Within a name, the real index orders them, so
    -- the nth real platform pairs with the nth copy and the pairing is the same on every
    -- push and after a restart.
    local seen = 0
    local by_name = {}
    local wanted = 0
    for _, entry in pairs(entries) do
        seen = seen + 1
        if type(entry) == "table" and entry.name then
            -- The manager's JSON always carries these keys. An empty string is what a
            -- docked or in-transit platform has, and Lua treats it as true, so it would
            -- be written as a location name and the copy would fail with "Unknown
            -- space-location name: ". Missing means missing.
            if entry.location == "" then
                entry.location = nil
            end
            if entry.connection == "" then
                entry.connection = nil
            end
            by_name[entry.name] = by_name[entry.name] or {}
            table.insert(by_name[entry.name], entry)
            wanted = wanted + 1
        end
    end

    -- An empty order is not an order to remove everything: the calls that fire at boot
    -- and on a mod change pass no list, and acting on that would wipe the copies. The
    -- manager is the only caller that prunes, and it always sends the real list.
    if seen == 0 then
        return {instance = instance(), skipped = "no list"}
    end

    for _, group in pairs(by_name) do
        table.sort(group, function(a, b)
            return (tonumber(a.index) or 0) < (tonumber(b.index) or 0)
        end)
    end

    local force = main_force()
    local made, kept, removed = {}, {}, {}
    local bad_layout, bad_other, bad_asteroids, unprotected = 0, 0, 0, 0

    local existing = {}
    for _, platform in pairs(force.platforms or {}) do
        existing[platform.name] = existing[platform.name] or {}
        table.insert(existing[platform.name], platform)
    end
    for _, group in pairs(existing) do
        table.sort(group, function(a, b) return a.index < b.index end)
    end

    -- Gone from the list means gone here: the real platform was deleted or destroyed,
    -- and a copy of something that no longer exists is a lie players can stand on. A
    -- duplicate name keeps only as many copies as the fleet has of that name.
    for name, group in pairs(existing) do
        local keep = by_name[name] and #by_name[name] or 0

        if keep == 0 then
            -- A platform here that the fleet list does not know about is either a stale
            -- copy or a native one a player just made. A stale copy is removed; a native
            -- platform is removed too, and the space server is asked to create the real one
            -- under the same name. The next mirror returns a protected copy.
            for _, platform in ipairs(group) do
                -- A copy the mod made and the fleet no longer lists is stale: remove it.
                -- Anything else is a native platform; remove it and create the real one on
                -- the space server.
                if storage.copies and storage.copies[name] then
                    if destroy_copy(platform) then
                        removed[#removed + 1] = name
                        storage.copies[name] = nil
                        log(string.format("[%s] %s left the fleet, removing the copy", instance(), name))
                    else
                        log(string.format("[%s] could not remove the copy of %s", instance(), name))
                    end
                else
                    local location = platform.space_location and platform.space_location.name or instance()
                    if destroy_copy(platform) then
                        report_platform_create(name, location)
                        log(string.format("[%s] removed native %s and asked the space server to create it", instance(), name))
                    else
                        log(string.format("[%s] could not remove native %s", instance(), name))
                    end
                end
            end
            if keep == 0 then
                existing[name] = nil
            end
        else
            for index = keep + 1, #group do
                local platform = group[index]
                if storage.copies and storage.copies[name] then
                    if destroy_copy(platform) then
                        removed[#removed + 1] = name
                        log(string.format("[%s] %s has no place in the fleet, removing the extra copy", instance(), name))
                    else
                        log(string.format("[%s] could not remove the extra copy of %s", instance(), name))
                    end
                else
                    local location = platform.space_location and platform.space_location.name or instance()
                    if destroy_copy(platform) then
                        report_platform_create(name, location)
                        log(string.format("[%s] removed extra native %s and asked the space server to create it", instance(), name))
                    else
                        log(string.format("[%s] could not remove extra native %s", instance(), name))
                    end
                end
            end
        end
    end

    for name, group in pairs(by_name) do
        local have = existing[name] or {}
        for index = 1, #group do
            local entry = group[index]
            local platform = have[index]

            if platform and (not platform.valid or not platform.hub) then
                -- A copy without its hub cannot be repaired. Everything else -- a moved or
                -- missing bay, a player's building -- is repaired in place below; destroying
                -- and recreating on every difference left two sets of copies on the server.
                log(string.format("[%s] rebuilding the copy of %s: it has no hub", instance(), name))
                destroy_copy(platform)
                platform = nil
            end

            if platform then
                kept[#kept + 1] = name

                -- Where it is and where it is going, from the real one. Each write is
                -- wrapped and only made when it differs: these are the game's own setters
                -- on a platform that is, here, only a copy, and a copy that cannot be
                -- moved is still a copy.
                if entry.connection and (platform.space_connection == nil
                    or platform.space_connection.name ~= entry.connection) then
                    set_position(platform, "space_connection", entry.connection)
                end

                if entry.location and (platform.space_location == nil
                    or platform.space_location.name ~= entry.location) then
                    set_position(platform, "space_location", entry.location)
                end

                -- After the connection: writing one sets the distance to 0.5.
                if type(entry.distance) == "number" and platform.distance ~= entry.distance then
                    set_position(platform, "distance", entry.distance)
                end

                if entry.paused ~= nil and platform.paused ~= entry.paused then
                    set_position(platform, "paused", entry.paused)
                end

                ensure_bays(platform, entry.bays, entry.layout)
                destroy_other(platform)
                pcall(function() platform.destroy_asteroid_chunks{} end)
                protect_copy(platform, name)
                if not copy_is_protected(platform) then
                    unprotected = unprotected + 1
                end
                if entry.layout and entry.layout ~= "" and layout_of(platform) ~= entry.layout then
                    bad_layout = bad_layout + 1
                end
                if (other_entities(platform) or 0) ~= 0 then
                    bad_other = bad_other + 1
                end
                if (asteroid_count(platform) or 0) ~= 0 then
                    bad_asteroids = bad_asteroids + 1
                end
            else
                local planet = entry.location or instance()
                -- Both required fields, named as the game names them: `planet` is a space
                -- location and `starter_pack` is the item the game itself uses for one
                -- (asked for with plate, not guessed -- the probe reports it). The starter
                -- pack is also what gives the copy its hub.
                storage.creating_copy = name
                local ok, created = pcall(function()
                    return force.create_space_platform{
                        planet = planet,
                        name = name,
                        starter_pack = "space-platform-starter-pack",
                    }
                end)
                storage.creating_copy = nil

                if ok and created then
                    if not pcall(function() created.apply_starter_pack(true) end) then
                        log(string.format("[%s] %s was made without its hub", instance(), name))
                    end

                    -- Never asteroids: they belong to the space server, and a planet server
                    -- spawning them would be running a platform.
                    pcall(function() created.destroy_asteroid_chunks{} end)
                    ensure_bays(created, entry.bays, entry.layout)
                    destroy_other(created)
                    protect_copy(created, name)
                    if not copy_is_protected(created) then
                        unprotected = unprotected + 1
                    end
                    if entry.layout and entry.layout ~= "" and layout_of(created) ~= entry.layout then
                        bad_layout = bad_layout + 1
                    end
                    if (other_entities(created) or 0) ~= 0 then
                        bad_other = bad_other + 1
                    end
                    if (asteroid_count(created) or 0) ~= 0 then
                        bad_asteroids = bad_asteroids + 1
                    end

                    made[#made + 1] = name
                    storage.copies = storage.copies or {}
                    storage.copies[name] = true
                    log(string.format("[%s] made a copy of %s, at %s", instance(), name, planet))
                else
                    log(string.format("[%s] could not make a copy of %s: %s", instance(), name, tostring(created)))
                end
            end
        end
    end

    table.sort(made)
    table.sort(kept)
    table.sort(removed)

    local copies = 0
    for _ in pairs(force.platforms or {}) do
        copies = copies + 1
    end

    log(string.format(
        "[%s] the fleet sent %d platform(s), %d of them usable, %d copy(ies) here, %d layout mismatch(es), %d with other entities, %d with asteroids, %d unprotected",
        instance(), seen, wanted, copies, bad_layout, bad_other, bad_asteroids, unprotected))

    return {
        instance = instance(),
        seen = seen,
        wanted = wanted,
        copies = copies,
        layout_mismatches = bad_layout,
        with_other = bad_other,
        with_asteroids = bad_asteroids,
        unprotected = unprotected,
        made = table.concat(made, ","),
        kept = table.concat(kept, ","),
        removed = table.concat(removed, ","),
    }
end

-- Drop this server's copies so the next mirror push rebuilds them from the fleet's own data.
-- The manager calls this and pushes the platform list a moment later, so doing both here
-- would need entries it has not sent yet. An empty mirror list is exactly "remove every copy".
local function rebuild_platforms()
    return mirror_platforms({})
end

-- How many starter-pack requests a rocket silo holds.
--
-- Nothing in this mod touches a silo's requests; this exists so a launch that goes nowhere
-- leaves a trace. A count going 1 then 0 with no rocket launched is the report we need, and a
-- count that is -1 means the silo's request point was not readable at all.
local function starter_pack_requests(silo)
    if not silo or not silo.valid or silo.name ~= "rocket-silo" then
        return -1
    end

    local ok, point = pcall(function()
        return silo.get_logistic_point(defines.logistic_member_index.rocket_silo_rocket)
    end)
    if not ok or not point then
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

-- A real platform, created where the platforms really live.
--
-- The planet mirror asks for this when a player launches a starter pack: the native
-- platform exists in the planet's save, but the space server is the authority and has to
-- create the real one. Idempotent by name. It runs while players are connected: the join
-- desync was the GUI rebuild, and waiting for an empty space server meant a starter pack
-- launched while somebody watched the platform screen was never adopted.
local function create_platform(entry)
    if instance() ~= "space" then
        return {ok = false, error = "only the space server creates real platforms"}
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return {ok = false, error = "a platform needs a name"}
    end
    local force = main_force()
    for _, platform in pairs(force.platforms or {}) do
        if platform.name == entry.name then
            return {ok = true, name = entry.name, existed = true}
        end
    end

    local planet = entry.location
    if type(planet) ~= "string" or planet == "" or planet == "space" then
        planet = "nauvis"
    end

    local ok, created = pcall(function()
        return force.create_space_platform{
            planet = planet,
            name = entry.name,
            starter_pack = "space-platform-starter-pack",
        }
    end)
    if not ok or not created then
        return {ok = false, error = tostring(created)}
    end

    local hub = pcall(function() created.apply_starter_pack(true) end)
    log(string.format("[%s] created platform %s at %s", instance(), entry.name, planet))
    return {ok = true, name = entry.name, location = planet, hub = hub}
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
    starter_pack_requests = starter_pack_requests,
    create_platform = create_platform,
    remove_native_platform = remove_native_platform,
    is_copy = is_copy,
    platforms = platforms,
    platform_api = platform_api,
    surface_api = surface_api,
    layout_of = layout_of,
    layout_hash = layout_hash,
    bay_count = bay_count,
    asteroid_count = asteroid_count,
    other_entities = other_entities,
    cancel_copy_deconstruction = cancel_copy_deconstruction,
}
