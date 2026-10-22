-- server-connector-mod / control/convert.lua
--
-- What this server does to the world at runtime: the crash site, the surfaces this instance
-- owns, the spawn point, the asteroid sweep, and the custom surfaces the manager asks for.
-- Conversion -- cutting a world down to the one surface a server keeps -- is not here: that
-- belongs to the private converter mod the manager installs for the length of a conversion,
-- and the public mod has no way to start one.
--
-- Nothing here creates another server's surface. A planet owns exactly one, a custom instance
-- owns the ones declared for it, and the space server owns its platforms, which are built
-- rather than created.
--
-- Required as "__server-connector-mod__.control.convert".

local state = require("__server-connector-mod__.control.state")

local MOD = state.MOD
local known = state.known
local empty = state.empty
local instance = state.instance
local main_force = state.main_force
local owned_surfaces = state.owned_surfaces
local primary_surface = state.primary_surface

--------------------------------------------------------------------------------
-- no crash site, and no cutscene
--------------------------------------------------------------------------------

-- Space Age's freeplay scenario drops a crashed ship on the first player to join and plays
-- a cutscene over it. These worlds are made to be played in rather than started in, and a
-- pile of wreckage is entities the fleet would have to keep in step across six saves. The
-- scenario has its own switch for it, and it is the only one there is: the setting turns
-- the cutscene off with the crash site, which is why both go.
--
-- The call is made on load as well as at world creation, so a world made before this
-- existed is not left with the wreckage either.
local function disable_crash_site()
    if not known() then
        return
    end
    if not remote.interfaces.freeplay then
        -- Something else is running the world: a sandbox, a tutorial, a scenario of its
        -- own. Nothing here to switch off.
        return
    end

    local ok, err = pcall(function()
        remote.call("freeplay", "set_disable_crashsite", true)
    end)

    if not ok then
        log(string.format("[%s] could not disable the crash site: %s", MOD, tostring(err)))
    end
end

--------------------------------------------------------------------------------
-- every planet exists everywhere
--------------------------------------------------------------------------------

-- Remove the surfaces this instance does not own.
--
-- The old layout copied every planet into every save so a player could look at one. Those
-- copies are dead weight now that the map is the way across, and they are exactly what the
-- plan meant by "no more fake surfaces". Only the game's own delete, only with nobody
-- connected, and never a surface that still holds a character.
local function remove_foreign_surfaces()
    if not known() or not empty() then
        return
    end

    -- The space server owns its platforms, not a named planet. Everything that is not a
    -- platform is another server's world and does not belong in this save.
    if instance() == "space" then
        for name, surface in pairs(game.surfaces) do
            if not surface.platform and name ~= storage.spawn_surface then
                local ok, characters = pcall(function()
                    return surface.find_entities_filtered{type = "character"}
                end)
                if ok and type(characters) == "table" and #characters == 0 then
                    local deleted, err = pcall(function() return game.delete_surface(name) end)
                    if deleted then
                        log(string.format("[%s] removed foreign surface %s", instance(), name))
                    else
                        log(string.format("[%s] could not remove foreign surface %s: %s",
                            instance(), name, tostring(err)))
                    end
                end
            end
        end
        return
    end

    local keep = owned_surfaces()
    if next(keep) == nil then
        return
    end

    for name, surface in pairs(game.surfaces) do
        -- A platform belongs to the space server. Keeping it here was how a planet save
        -- still carried the fleet's platforms.
        if not keep[name] and name ~= storage.spawn_surface and not surface.platform then
            local ok, characters = pcall(function()
                return surface.find_entities_filtered{type = "character"}
            end)
            if ok and type(characters) == "table" and #characters == 0 then
                local deleted, err = pcall(function() return game.delete_surface(name) end)
                if deleted then
                    log(string.format("[%s] removed foreign surface %s", instance(), name))
                else
                    log(string.format("[%s] could not remove foreign surface %s: %s",
                        instance(), name, tostring(err)))
                end
            end
        end
    end
end

-- The surface a save only has when this server made it.
--
-- A fresh save is always a nauvis world, whatever the server is for, so the planet this
-- instance exists to be is exactly the one that can be missing. Only owned surfaces are
-- created: there are no copies of another server's planet any more, and the map is the way
-- to reach one.
--
-- A custom surface is created by create_custom_surfaces below, with its generation form. If
-- one is missing here it is made again from its declared form, so a surface is never silently
-- absent.
local function ensure_surfaces()
    if not known() then
        return
    end
    local force = main_force()

    for id in pairs(owned_surfaces()) do
        if not game.surfaces[id] then
            local okp, planet = pcall(function() return game.planets and game.planets[id] end)
            if not okp then planet = nil end
            if planet then
                local ok, surface = pcall(function() return planet.create_surface() end)
                if ok and surface then
                    log(string.format("[%s] created the surface for %s", MOD, id))
                else
                    log(string.format("[%s] could not create the surface for %s: %s",
                        MOD, id, tostring(surface)))
                end
            end
        end

        -- Having the surface is not the same as the planet being reachable: a force only
        -- sees and travels to space locations it has unlocked. A custom surface has no space
        -- location, and the call simply refuses it, which is caught.
        local oku, unlocked = pcall(function() return force.is_space_location_unlocked(id) end)
        if oku and not unlocked then
            local ok, err = pcall(function() force.unlock_space_location(id) end)
            if ok then
                log(string.format("[%s] unlocked %s for this force", MOD, id))
            else
                log(string.format("[%s] could not unlock %s: %s", MOD, id, tostring(err)))
            end
        end
    end

    remove_foreign_surfaces()
end

--------------------------------------------------------------------------------
-- a copy has no asteroids, ever
--------------------------------------------------------------------------------

-- Take the asteroids off this server's platforms.
--
-- Only a planet server's: the space server's platforms are real, and asteroids are part of
-- what a real one is. A copy sits at a space location, though, and spawns them whether
-- anybody wants them or not -- one sweep when the copy is made is not enough, which is what
-- the copies showed when they first existed.
--
-- There is no switch for this: asteroid spawning comes from the space location the platform
-- is at, and a platform has to be at one to exist. So the sweep runs, every second, and is
-- cheap because there is nothing there to destroy.
local function sweep_asteroids()
    if instance() == "space" then
        return
    end

    for _, platform in pairs(main_force().platforms or {}) do
        local ok, destroyed = pcall(function() return platform.destroy_asteroid_chunks{} end)
        if ok and type(destroyed) == "number" and destroyed > 0 then
            log(string.format("[%s] took %d asteroid chunk(s) off %s", instance(), destroyed, platform.name))
        end
    end
end

--------------------------------------------------------------------------------
-- custom surfaces, on order
--------------------------------------------------------------------------------

-- Apply the form a surface was described with. Everything here is a property the game
-- exposes on a surface created at runtime; the two that belong to a planet prototype --
-- lightning and the Aquilo heating mechanic -- are not pretended.
local function apply_surface_options(surface, generation)
    generation = generation or {}

    local function set(what, fn)
        local ok, err = pcall(fn)
        if not ok then
            log(string.format("[%s] could not set %s on %s: %s",
                instance(), what, surface.name, tostring(err)))
        end
    end

    set("peaceful mode", function() surface.peaceful_mode = generation.peaceful == true end)
    set("no enemies", function() surface.no_enemies_mode = generation.noEnemies == true end)
    set("always day", function() surface.always_day = generation.alwaysDay == true end)

    if type(generation.ticksPerDay) == "number" and generation.ticksPerDay > 0 then
        set("day length", function() surface.ticks_per_day = math.floor(generation.ticksPerDay) end)
    end
    if type(generation.solarMultiplier) == "number" then
        set("solar multiplier", function() surface.solar_power_multiplier = generation.solarMultiplier end)
    end
    if type(generation.windSpeed) == "number" then
        set("wind speed", function() surface.wind_speed = generation.windSpeed end)
    end

    -- The full Aquilo heating mechanic is a planet-prototype property. What a runtime
    -- surface can have is the cold property, so that is what this does.
    if generation.freezing == true then
        set("temperature", function() surface.set_property("temperature", 0) end)
    end
end

-- Paint a bounded starting area with one tile. A flat sandbox is a starting area, not a
-- whole planet generated a tile at a time.
local function paint_flat(surface, tile)
    if type(tile) ~= "string" or tile == "" then
        return
    end

    local tiles = {}
    for x = -32, 32 do
        for y = -32, 32 do
            tiles[#tiles + 1] = {name = tile, position = {x = x, y = y}}
        end
    end

    local ok, err = pcall(function() surface.set_tiles(tiles, true) end)
    if not ok then
        log(string.format("[%s] could not paint %s: %s", instance(), surface.name, tostring(err)))
    end
end

-- Create the surfaces the manager declared for this instance. Nobody connected: these are
-- world changes, and a client that is connected would desync on the next comparison.
local function create_custom_surfaces(entries)
    if not known() then
        return {instance = instance(), skipped = "no identity"}
    end
    if not empty() then
        return {instance = instance(), skipped = "somebody is connected"}
    end

    local made, failed = {}, {}

    -- A declared flat surface that already exists is an old world carried forward in the
    -- save: the create branch below only ever runs for a missing surface, so without this
    -- the flat form would never be applied. Replace it once, while nobody is connected —
    -- the marker is what stops every topology push from wiping the surface again.
    storage.flat_replaced = storage.flat_replaced or {}
    for _, entry in pairs(entries or {}) do
        local id = type(entry) == "table" and entry.id or nil
        local generation = type(entry) == "table" and (entry.generation or {}) or {}
        if type(id) == "string" and id ~= "" and generation.flat == true
            and game.surfaces[id] and not storage.flat_replaced[id] then
            local ok, err = pcall(function() return game.delete_surface(id) end)
            if ok then storage.flat_replaced[id] = true end
            if ok then
                log(string.format("[%s] replaced %s with the declared flat surface", instance(), id))
            else
                log(string.format("[%s] could not replace %s: %s", instance(), id, tostring(err)))
            end
        end
    end

    for _, entry in pairs(entries or {}) do
        local id = type(entry) == "table" and entry.id or nil
        if type(id) == "string" and id ~= "" and not game.surfaces[id] then
            local generation = entry.generation or {}

            local settings = {}

            if generation.flat == true then
                -- The flat area is painted below; the settings only have to make it empty.
                settings.property_expression_names = {
                    elevation = 0, cliffiness = 0, roughness = 0,
                    temperature = 0, moisture = 0, aux = 0,
                }
            else
                local name = generation.planet
                local okp, planet = pcall(function()
                    return name and game.planets and game.planets[name]
                end)
                if okp and planet and planet.prototype and planet.prototype.map_gen_settings then
                    -- Copied, not referenced: the prototype's table belongs to the game, and
                    -- writing a seed or a water control into it would change every surface
                    -- made from that planet afterwards.
                    for key, value in pairs(planet.prototype.map_gen_settings) do
                        settings[key] = value
                    end
                end
            end

            -- The form's own choices, applied on top of whichever base generation was used.
            settings.peaceful_mode = generation.peaceful == true
            settings.no_enemies_mode = generation.noEnemies == true

            if type(generation.seed) == "number" then
                settings.seed = math.floor(generation.seed) % 4294967296
            end
            if generation.cliffs == false then
                settings.property_expression_names = settings.property_expression_names or {}
                settings.property_expression_names.cliffiness = 0
            end
            if generation.water == "none" or generation.water == "high" then
                -- Water is an autoplace control, not a property expression: the map gen's
                -- water size is what the slider in the game changes.
                settings.autoplace_controls = settings.autoplace_controls or {}
                settings.autoplace_controls.water = {
                    frequency = "normal",
                    size = generation.water == "none" and "none" or "high",
                    richness = "normal",
                }
            end

            local ok, surface = pcall(function() return game.create_surface(id, settings) end)
            if ok and surface then
                apply_surface_options(surface, generation)
                if generation.flat == true then
                    pcall(function()
                        surface.request_to_generate_chunks({x = 0, y = 0}, 2)
                        surface.force_generate_chunk_requests()
                    end)
                    paint_flat(surface, generation.tile)
                end
                made[#made + 1] = id
                log(string.format("[%s] created custom surface %s", instance(), id))
            else
                failed[#failed + 1] = {id = id, error = tostring(surface)}
                log(string.format("[%s] could not create custom surface %s: %s",
                    instance(), id, tostring(surface)))
            end
        end
    end

    ensure_surfaces()

    return {instance = instance(), made = made, failed = failed}
end

-- Delete one custom surface. Never the primary, never while somebody is connected.
local function delete_surface(name)
    if not known() then
        return {instance = instance(), skipped = "no identity"}
    end
    if not empty() then
        return {instance = instance(), skipped = "somebody is connected"}
    end

    local entry = (storage.topology or {})[instance()]
    if not owned_surfaces()[name] then
        return {instance = instance(), skipped = "not this instance's surface"}
    end
    if name == (entry and entry.primary) or name == instance() then
        return {instance = instance(), skipped = "the primary surface cannot be deleted"}
    end

    local ok, err = pcall(function() game.delete_surface(name) end)
    if not ok then
        return {instance = instance(), error = tostring(err)}
    end

    log(string.format("[%s] deleted custom surface %s", instance(), name))
    return {instance = instance(), deleted = name}
end

local function spawn_on_owned_surface()
    if not empty() then
        return
    end
    if not known() then
        return
    end
    local home = primary_surface()
    if not home then
        return false
    end

    -- Set, not compared. The game answers a spawn-position query for whichever surface it
    -- is asked about, so there is no "which surface does this force spawn on" to read back
    -- -- and asking it with no argument at all is a non-recoverable error that quits the
    -- server, which is how 0.18.0 came to not start. Setting it again is free.
    local spot = home.find_non_colliding_position("character", {x = 0, y = 0}, 64, 1) or {x = 0, y = 0}
    main_force().set_spawn_position(spot, home)
    storage.spawn_surface = home.name

    log(string.format("[%s] the spawn point is on %s", instance(), home.name))
    return true
end

--------------------------------------------------------------------------------
-- the boot-time order, run on request
--------------------------------------------------------------------------------

-- The load-time check, as a list of steps.
--
-- Every step is wrapped, and that is not caution for its own sake: one of these took
-- the whole fleet down at boot -- an argument count the API refused, raised from a tick
-- handler, which is non-recoverable -- and a server that will not start is worse than a
-- surface left uncleared.
local function settle_steps()
    local steps = {
        {"the crash site", disable_crash_site},
        {"the surfaces", ensure_surfaces},
        {"the spawn point", spawn_on_owned_surface},
    }

    for _, step in ipairs(steps) do
        local ok, err = pcall(step[2])
        if not ok then
            log(string.format("[%s] %s could not be done: %s", instance(), step[1], tostring(err)))
        end
    end
end

-- What surfaces this world has, for the node to walk one by one.
local function surfaces()
    local names, platforms = {}, {}
    for name, surface in pairs(game.surfaces) do
        names[#names + 1] = name
        if surface.platform then
            platforms[#platforms + 1] = name
        end
    end
    table.sort(names)
    table.sort(platforms)

    -- The platforms are told apart from the planets: a space server keeps its platforms,
    -- and they cannot be named in advance because they are built.
    return {
        instance = instance(),
        surfaces = table.concat(names, ","),
        platforms = table.concat(platforms, ","),
    }
end

-- Make this instance's surfaces, and say what the world holds afterwards.
--
-- With a list, the list is the custom surfaces to create, with their generation forms; without
-- one, it is every owned surface that is missing (a planet's own, after an upgrade).
local function create_surfaces(entries)
    if type(entries) == "table" and #entries > 0 then
        local result = create_custom_surfaces(entries)
        local names = {}
        for name, _ in pairs(game.surfaces) do
            names[#names + 1] = name
        end
        table.sort(names)
        result.surfaces = names
        return result
    end

    ensure_surfaces()

    local out = {}
    for name, _ in pairs(game.surfaces) do
        out[#out + 1] = name
    end
    table.sort(out)

    return {instance = instance(), surfaces = out}
end

-- Bring this world into line: every planet's surface and the spawn point.
--
-- An order, and only ever carried out with nobody connected. These are world changes,
-- they are not replicated to clients, and a client that is joining still counts as a
-- player.
local function settle()
    if not known() then
        return {instance = instance(), skipped = "no identity"}
    end
    if not empty() then
        return {instance = instance(), skipped = "somebody is connected"}
    end

    settle_steps()

    local names = {}
    for name, _ in pairs(game.surfaces) do
        names[#names + 1] = name
    end
    table.sort(names)

    return {instance = instance(), settled = true, surfaces = table.concat(names, ",")}
end

return {
    disable_crash_site = disable_crash_site,
    ensure_surfaces = ensure_surfaces,
    settle_steps = settle_steps,
    sweep_asteroids = sweep_asteroids,
    spawn_on_owned_surface = spawn_on_owned_surface,

    create_custom_surfaces = create_custom_surfaces,
    delete_surface = delete_surface,
    create_surfaces = create_surfaces,
    surfaces = surfaces,
    settle = settle,
}
