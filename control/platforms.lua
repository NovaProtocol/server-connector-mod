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
local empty = state.empty
local instance = state.instance
local main_force = state.main_force

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

-- A fake platform must not be deleted by an asteroid chunk that survives the sweep.
--
-- The engine has no per-platform asteroid spawn switch: LuaSpacePlatform.hidden only
-- removes it from the remote-view list, and paused only stops thrust and schedule. The
-- only control is LuaEntity::destructible, and the hub is what keeps a platform alive;
-- the cargo bays carry the copy's cargo, so they are protected too.
local function protect_copy(platform, name)
    local function protect(entity, what)
        if not entity or not entity.valid then
            return
        end
        local ok, err = pcall(function() entity.destructible = false end)
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

--------------------------------------------------------------------------------
-- the fleet's platforms, as copies
--------------------------------------------------------------------------------

-- Give a copy the same number of cargo bays as the real platform.
--
-- A copy is a hub and its cargo bays -- the bays are what a platform's cargo capacity is
-- made of, and a copy showing only the hub reads as a different platform. Only missing
-- bays are added: a copy is a view, and tearing a bay off one risks the cargo it holds.
local function ensure_bays(platform, count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count == 0 then
        return
    end

    local surface = platform.surface
    if not surface then
        return
    end

    local ok, existing = pcall(function()
        return surface.find_entities_filtered{name = "cargo-bay"}
    end)
    local have = (ok and existing) and #existing or 0
    local force = main_force()

    for index = have + 1, count do
        local angle = (index - 1) * (2 * math.pi / math.max(count, 1))
        local radius = 4 + math.floor((index - 1) / 8) * 2
        local position = {x = math.cos(angle) * radius, y = math.sin(angle) * radius}
        pcall(function()
            surface.create_entity{name = "cargo-bay", position = position, force = force.name}
        end)
    end
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

    -- Making or removing a platform from an order is a world change with no counterpart
    -- on a client, which is a desync by construction.
    if not empty() then
        return {instance = instance(), skipped = "somebody is connected"}
    end

    if instance() == "space" then
        return {instance = instance(), skipped = "the real platforms live here"}
    end

    local own = (storage.topology or {})[instance()]
    if not own or own.kind ~= "planet" then
        return {instance = instance(), skipped = "not a planet"}
    end

    entries = entries or {}

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
        for index = keep + 1, #group do
            local platform = group[index]
            if pcall(function() platform.destroy() end) then
                removed[#removed + 1] = name
                log(string.format("[%s] %s is gone from the fleet, removing the copy", instance(), name))
            else
                log(string.format("[%s] could not remove the copy of %s", instance(), name))
            end
        end
        if keep == 0 then
            existing[name] = nil
        end
    end

    for name, group in pairs(by_name) do
        local have = existing[name] or {}
        for index = 1, #group do
            local entry = group[index]
            local platform = have[index]

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

                ensure_bays(platform, entry.bays)
            else
                local planet = entry.location or instance()
                -- Both required fields, named as the game names them: `planet` is a space
                -- location and `starter_pack` is the item the game itself uses for one
                -- (asked for with plate, not guessed -- the probe reports it). The starter
                -- pack is also what gives the copy its hub.
                local ok, created = pcall(function()
                    return force.create_space_platform{
                        planet = planet,
                        name = name,
                        starter_pack = "space-platform-starter-pack",
                    }
                end)

                if ok and created then
                    if not pcall(function() created.apply_starter_pack(true) end) then
                        log(string.format("[%s] %s was made without its hub", instance(), name))
                    end

                    -- Never asteroids: they belong to the space server, and a planet server
                    -- spawning them would be running a platform.
                    pcall(function() created.destroy_asteroid_chunks{} end)
                    ensure_bays(created, entry.bays)
                    protect_copy(created, name)

                    made[#made + 1] = name
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

    log(string.format("[%s] the fleet sent %d platform(s), %d of them usable, %d copy(ies) here",
        instance(), seen, wanted, copies))

    return {
        instance = instance(),
        seen = seen,
        wanted = wanted,
        copies = copies,
        made = table.concat(made, ","),
        kept = table.concat(kept, ","),
        removed = table.concat(removed, ","),
    }
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
            bays = (function()
                local surface = platform.surface
                if not surface then
                    return nil
                end
                local ok, bays = pcall(function()
                    return surface.find_entities_filtered{name = "cargo-bay"}
                end)
                if ok and bays then
                    return #bays
                end
                return nil
            end)(),
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
    platforms = platforms,
    platform_api = platform_api,
    surface_api = surface_api,
}
