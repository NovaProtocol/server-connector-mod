-- server-connector-mod / control/convert.lua
--
-- What this server does to the world at runtime: the crash site, the surfaces every planet
-- needs, the spawn point, and the asteroid sweep. Conversion -- cutting a world down to the
-- one surface a server keeps -- is not here: that belongs to the private converter mod the
-- manager installs for the length of a conversion, and the public mod has no way to start
-- one.
--
-- The exception is the join fallback below: a player joining can generate chunks on a
-- surface this server does not own, and those are taken back off, because that is one join's
-- worth of work rather than a conversion.
--
-- Required as "__server-connector-mod__.control.convert".

local state = require("__server-connector-mod__.control.state")

local MOD = state.MOD
local known = state.known
local empty = state.empty
local instance = state.instance
local main_force = state.main_force

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

-- Each server has its own save, so a surface only exists on the server whose save made
-- it -- and the remote view that routing depends on has nothing to click on a planet this
-- server has never heard of. Creating the surface is enough: chunks are generated when
-- something needs them, so an unvisited planet stays fog until somebody goes there, and
-- nothing is charted or rendered by this.
--
-- It runs whenever the topology arrives, whenever this server learns which one it is, and
-- on load, so a server that is told anything late still ends up with all of them.
local function ensure_surfaces()
    if not known() then
        return
    end
    local unclassified = {}
    local force = main_force()

    for id, entry in pairs(storage.topology or {}) do
        if entry.kind == nil then
            unclassified[#unclassified + 1] = id
        end

        if entry.kind ~= "planet" then
            -- A space server's platforms are built, not created, so there is nothing here
            -- for it to make.
            goto continue
        end

        -- Its own planet counts most of all: a fresh save is always a nauvis world,
        -- whatever the server is for, so the planet this server exists to be is exactly
        -- the one that is missing.
        if not game.surfaces[id] then
            local planet = game.planets and game.planets[id]
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
        -- sees and travels to space locations it has unlocked, and normally the discovery
        -- research does that. A server with the surface and no unlock shows nothing in the
        -- space map -- the planet is simply not there as far as the game is concerned.
        if force.is_space_location_unlocked and not force.is_space_location_unlocked(id) then
            local ok, err = pcall(function() force.unlock_space_location(id) end)
            if ok then
                log(string.format("[%s] unlocked %s for this force", MOD, id))
            else
                log(string.format("[%s] could not unlock %s: %s", MOD, id, tostring(err)))
            end
        end

        ::continue::
    end

    -- Said out loud rather than skipped quietly: a topology with no kinds leaves every
    -- planet to be discovered the hard way, and a silent skip looks exactly like working.
    if #unclassified > 0 then
        log(string.format("[%s] %d destinations arrived with no kind, so no surface was created for %s",
            MOD, #unclassified, table.concat(unclassified, ", ")))
    end
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
        if not ok then
            return
        end

        if type(destroyed) == "number" and destroyed > 0 then
            log(string.format("[%s] took %d asteroid chunk(s) off %s", instance(), destroyed, platform.name))
        end
    end
end

--------------------------------------------------------------------------------
-- the join fallback
--------------------------------------------------------------------------------

-- Take everything off one surface, in one call.
--
-- destroy() answers false for the few entities that cannot be destroyed -- a rail under a
-- train is the example the API gives -- so only real destructions are counted. Characters
-- are somebody's body, and this runs with nobody connected, so one can only be a stray a
-- script left behind; skipping it is deliberate.
--
-- get_chunks hands back a LuaChunkIterator -- iterated, never indexed as a table -- whose
-- values carry their chunk coordinates as x/y.
local function clear_one(surface)
    local destroyed = 0

    local ok, batch = pcall(function() return surface.find_entities_filtered{} end)
    if ok and type(batch) == "table" then
        for _, entity in pairs(batch) do
            if entity.valid and entity.type ~= "character" then
                local removed, gone = pcall(function() return entity.destroy() end)
                if removed and gone then
                    destroyed = destroyed + 1
                end
            end
        end
    else
        log(string.format("[%s] could not look at %s: %s", instance(), surface.name, tostring(batch)))
    end

    local chunks = 0
    if type(surface.get_chunks) == "function" then
        local got, iter = pcall(function() return surface.get_chunks() end)
        if got and iter ~= nil then
            local walked = pcall(function()
                for chunk in iter do
                    if pcall(function()
                        return surface.delete_chunk({x = chunk.x, y = chunk.y})
                    end) then
                        chunks = chunks + 1
                    end
                end
            end)
            if not walked then
                log(string.format("[%s] could not walk %s's chunks", instance(), surface.name))
            end
        else
            log(string.format("[%s] could not ask %s for its chunks: %s",
                instance(), surface.name, tostring(iter)))
        end
    end

    return {entities = destroyed, chunks = chunks}
end

-- A joining player can generate chunks on a surface this server does not own. Take them
-- back off: it is one join's worth, so it is done at once rather than as a job, and it is
-- the only clearing this mod still does. The heavy conversion work lives in the private
-- converter the manager installs for a conversion.
--
-- The server and the client are comparing by the time this runs, so a change here is a
-- change the client was not told about. It is kept to the surfaces nobody should be on, and
-- to chunks a join has just made, which is as small as the fallback can be.
local function clear_foreign_chunks()
    if not known() then
        return
    end

    local cleared = {}

    for name, surface in pairs(game.surfaces) do
        local owned = name == instance() or (instance() == "space" and surface.platform ~= nil)

        if not owned then
            local chunks = 0
            if type(surface.get_chunks) == "function" then
                local ok, iter = pcall(function() return surface.get_chunks() end)
                if ok and iter ~= nil then
                    pcall(function()
                        for _ in iter do
                            chunks = chunks + 1
                        end
                    end)
                end
            end

            if chunks > 0 then
                local counts = clear_one(surface)
                cleared[name] = counts
                log(string.format("[%s] join fallback: cleared %s: %d entities, %d chunks",
                    instance(), name, counts.entities, counts.chunks))
            end
        end
    end

    storage.cleared = cleared
    return cleared
end

local function spawn_on_owned_surface()
    if not empty() then
        return
    end
    if not known() then
        return
    end
    local home = game.surfaces[instance()]
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

-- Make every planet this fleet knows about, and say what the world holds afterwards.
local function create_surfaces()
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
    clear_foreign_chunks = clear_foreign_chunks,
    spawn_on_owned_surface = spawn_on_owned_surface,

    create_surfaces = create_surfaces,
    surfaces = surfaces,
    settle = settle,
}
