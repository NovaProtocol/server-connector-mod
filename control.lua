-- server-connector-mod: routing for a Factorio world split across servers.
--
-- The trigger is the game's own remote view, not a menu this mod draws. Opening
-- remote view onto another planet and clicking it changes the surface the player
-- is *viewing*, and that fires on_player_changed_surface even though the body
-- never moved. So the picker is the interface the game already has, and this mod
-- only has to notice where the player looked and send them there.
--
-- Everything outside this server -- where each player's body is, and what the
-- other servers are -- comes from the manager, because a mod cannot see past its
-- own save. It is an interface to Lua: it holds no policy of its own.
--
--   identity  remote.call("server-connector","set_instance", ...), pushed by the
--             node once this server is up. A headless server does not import
--             mod-settings.json, so a startup setting never arrives.
--   topology  remote.call("server-connector","set_topology", ...), pushed by the
--             manager: the other servers' ids, names and client addresses.
--
-- Nothing here is a script command, so using it never stops achievements.

local MOD = "server-connector"
local SCHEMA = 2

--------------------------------------------------------------------------------
-- storage
--------------------------------------------------------------------------------

local function ensure_storage()
    storage.schema = storage.schema or SCHEMA
    storage.topology = storage.topology or {}   -- instance id -> {name, address}
    storage.body = storage.body or {}           -- player name -> instance id
    storage.viewing = storage.viewing or {}     -- player name -> true, for the join rule
    storage.routed = storage.routed or {}       -- player name -> last surface routed from
    storage.anchored = storage.anchored or {}   -- player name -> the platform they belong on
    storage.cleared = storage.cleared or {}     -- surface name -> what was taken off it
end

--------------------------------------------------------------------------------
-- identity and topology
--------------------------------------------------------------------------------

-- Identity is a property of the container. The startup setting is the intended
-- carrier, but a headless server does not import mod-settings.json: it compiles
-- mod-settings.dat from defaults and ignores the .json beside it, so the setting
-- never arrives. The node therefore pushes it, and the setting is kept as the
-- fallback for anyone who sets it by hand in the game.
local function instance()
    if storage and storage.instance then
        return storage.instance
    end
    local setting = settings.startup[MOD .. "-instance"]
    return setting and setting.value or "unconfigured"
end

local function destinations()
    local out = {}
    for id, entry in pairs(storage.topology) do
        if id ~= instance() and type(entry) == "table" and entry.address then
            out[#out + 1] = {id = id, name = entry.name or id, address = entry.address}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Which server owns a surface the player is looking at.
--
-- A planet surface is named after its planet, so the instance id and the surface
-- name are the same string for the five planets, and the topology lookup finds it
-- directly. Anything with a platform is the space server, because every platform
-- lives there regardless of which one the player picked.
local function destination_for(surface)
    if not surface then
        return nil
    end

    local id = nil
    if surface.platform then
        id = "space"
    elseif storage.topology[surface.name] then
        id = surface.name
    end

    -- Looking at the surface this server already owns is not a journey. Returning
    -- the local id here is what prompted a player to connect to the server they
    -- were standing on, and it is also what made the last-viewed planet sticky:
    -- every surface change toward home looked like a hop that was never taken.
    if id == nil or id == instance() then
        return nil
    end

    return id
end

-- The force everything here acts on. It is defined before anything that uses it: a local
-- function is only visible from the line after its own, so one defined below its callers
-- is a nil global to them, and that is a runtime error the game reports and the parser
-- cannot.
local function main_force()
    return game.forces.player or game.forces[1]
end

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
-- nobody stands on a surface this server does not own
--------------------------------------------------------------------------------

-- The surface a player on this server belongs on.
--
-- A planet server owns its planet, and that is the whole answer. The space server owns no
-- planet: what its players belong on is a platform, which is built rather than named, so
-- where their body was the last time it was somewhere it should be is remembered instead.
local function owned_surface(player)
    if instance() ~= "space" then
        return game.surfaces[instance()]
    end

    local remembered = storage.anchored[player.name]
    local surface = remembered and game.surfaces[remembered]
    if surface and surface.platform then
        return surface
    end

    return nil
end

-- Put a player who is standing somewhere they do not belong back where they do.
--
-- Sending them to another server comes first, in route_if_elsewhere: looking at a planet
-- another server owns is a journey, and the game's own connect_to_server takes them. This
-- is what is left when no journey applies -- the player is standing *on* a surface this
-- server does not own, and there is nowhere to send them, because every other server's
-- planet exists here as an empty duplicate nobody should be standing on at all.
local function enforce_surface(player)
    -- A remote viewer is looking at this server from wherever they really are. Their body
    -- is not here and moving them would be moving somebody else's character.
    if storage.viewing[player.name] then
        return
    end

    local physical = player.physical_surface
    if not physical then
        return
    end

    -- A platform is a space server's home ground, so remember it while they are on one.
    if physical.platform then
        storage.anchored[player.name] = physical.name
        if instance() == "space" then
            return
        end
    end

    local home = owned_surface(player)
    if not home or physical == home then
        return
    end

    local position = player.physical_position or {x = 0, y = 0}
    local spot = home.find_non_colliding_position("character", position, 64, 1)
        or home.find_non_colliding_position("character", {x = 0, y = 0}, 64, 1)
        or position

    log(string.format("[%s] %s was standing on %s, putting them back on %s",
        instance(), player.name, physical.name, home.name))

    local ok, err = pcall(function() player.teleport(spot, home) end)
    if not ok then
        log(string.format("[%s] could not move %s: %s", instance(), player.name, tostring(err)))
    end
end

--------------------------------------------------------------------------------
-- a surface nobody plays on costs nothing
--------------------------------------------------------------------------------

-- How far out chunks are looked for, in chunks. The spawn area is a few chunks wide and
-- nothing visits an unowned surface to generate more, so this covers what is there; a save
-- carried in from elsewhere can have explored further, and what that leaves behind is
-- caught by the sweep of entities below, which is not bounded.
local CLEAR_WINDOW = 64

-- Take everything off the surfaces this server does not own.
--
-- A fleet server's save is a nauvis world whatever planet the server is for, so nauvis is
-- generated -- spawn area, biters, the lot -- before anybody arrives, and on five of the
-- six servers nobody ever goes there. Those biters are a UPS cost paid on every tick by a
-- server whose players are somewhere else entirely.
--
-- Deleting a chunk takes what is in it, which is the cost, and leaves the map: if anything
-- ever does need that surface, the game generates it again. Characters are left alone --
-- a player standing there is somebody's body, not tax.
-- What clearing one surface amounts to.
--
-- Entities anywhere on it, which is the part that costs UPS on every tick, and then the
-- chunks themselves, so the map is not kept in memory for a surface nobody plays on.
-- Characters are left alone: a player standing there is somebody's body, not tax.
local function clear_one(surface)
    local destroyed = 0
    for _, entity in pairs(surface.find_entities_filtered{}) do
        if entity.valid and entity.type ~= "character" then
            entity.destroy()
            destroyed = destroyed + 1
        end
    end

    local chunks = 0
    for cx = -CLEAR_WINDOW, CLEAR_WINDOW do
        for cy = -CLEAR_WINDOW, CLEAR_WINDOW do
            local chunk = surface.get_chunk(cx, cy)
            if chunk and chunk.generated then
                if pcall(function() return surface.delete_chunk({x = cx, y = cy}) end) then
                    chunks = chunks + 1
                end
            end
        end
    end

    return {entities = destroyed, chunks = chunks}
end

-- Take everything off the surfaces this server does not own.
--
-- A fleet server's save is a nauvis world whatever planet the server is for, so nauvis is
-- generated -- spawn area, biters, the lot -- before anybody arrives, and on five of the
-- six servers nobody ever goes there. Those biters are a UPS cost paid on every tick by a
-- server whose players are somewhere else entirely.
--
-- Nothing is deleted from a surface this server owns, and nothing is deleted at all unless
-- there is something to delete.
local function clear_foreign_surfaces()
    local cleared = {}

    for name, surface in pairs(game.surfaces) do
        local owned = name == instance() or (instance() == "space" and surface.platform ~= nil)

        if not owned then
            -- Wrapped, because this runs on every load: a wrong call here would take the
            -- whole server down at boot rather than leave one surface uncleared.
            local ok, counts = pcall(function()
                return clear_one(surface)
            end)

            if not ok then
                log(string.format("[%s] could not clear %s: %s", instance(), name, tostring(counts)))
            elseif counts.entities > 0 or counts.chunks > 0 then
                cleared[name] = counts
                log(string.format("[%s] cleared %s: %d entities, %d chunks",
                    instance(), name, counts.entities, counts.chunks))
            end
        end
    end

    storage.cleared = cleared
    return cleared
end

local function spawn_on_owned_surface()
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
-- the trigger
--------------------------------------------------------------------------------

-- Record what happened, for the manager to read.
--
-- The mod cannot push: it has no network, and it only runs when the game calls
-- it. So the in-game events it cannot avoid seeing are queued here, and the node
-- drains them over RCON. This is the half of "an interface to Lua" that would
-- otherwise be missing -- without it the manager cannot know a player joined or
-- looked somewhere.
--
-- Bounded on purpose: a queue nobody reads must not grow without limit.
local function note(kind, player, surface)
    storage.events = storage.events or {}
    storage.events[#storage.events + 1] = {
        kind = kind,
        player = player.name,
        surface = surface or (player.surface and player.surface.name) or nil,
        body = storage.body[player.name],
        tick = game.tick,
    }
    while #storage.events > 64 do
        table.remove(storage.events, 1)
    end
end

-- Fires after the player changes surfaces, including a change of what they are
-- viewing in remote view. If they have looked at a surface another server owns,
-- this is the moment to hand them over.
--
-- The address is the one a *client* dials. Pointing a player at an RCON port
-- produces a prompt that reads correctly and a client that sits at "connecting"
-- until it gives up, with nothing logged anywhere.
local function route_if_elsewhere(player)
    local viewed = player.surface
    note("surface", player, viewed and viewed.name or nil)

    local target = destination_for(viewed)

    if not target then
        storage.routed[player.name] = nil
        return false
    end

    -- Already looking at where we would send them: nothing to do, and this is
    -- what stops the handler from bouncing a player every time it fires.
    if storage.routed[player.name] == target then
        -- Already handed over and still on their way. Nothing else is done for them: a
        -- teleport now would fight the connection that is being made.
        return true
    end

    local entry = storage.topology[target]
    storage.routed[player.name] = target

    log(string.format("[%s] %s looked at %s, sending them to %s",
        instance(), player.name, viewed.name, entry.name or target))

    player.connect_to_server{address = entry.address, name = entry.name or target}
    return true
end

--------------------------------------------------------------------------------
-- the join rule
--------------------------------------------------------------------------------

-- The body exists on exactly one server. On every other one the player is a
-- remote viewer: the game's own remote controller, which already cannot move,
-- cannot take or change items, and still lets blueprints place as ghosts.
--
-- The remote controller is an *overlay* on a physical one, so leaving it returns
-- the player to that -- and a bodyless player's physical controller is god mode.
-- toggle_menu_leaves_remote_view = false is therefore load-bearing, not a nicety.
local function apply_join_rule(player)
    local here = storage.body[player.name]
    if not here or here == instance() then
        storage.viewing[player.name] = nil
        player.toggle_menu_leaves_remote_view = true
        player.disable_space_map = false
        return
    end

    storage.viewing[player.name] = true
    player.set_controller{
        type = defines.controllers.remote,
        surface = game.surfaces[instance()] or player.physical_surface,
        position = player.physical_position,
    }
    player.toggle_menu_leaves_remote_view = false
    player.disable_space_map = true
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

-- The load-time check, as two permanent handlers.
--
-- An existing save never fires on_init again, so the check runs on the ticks after every
-- load as well. on_load may not touch the world, which is why it happens on a tick -- but
-- what does it is registered here, once, at load, and never removed.
--
-- It has to be that way. The game compares the event handlers a joining client has against
-- the server's, and a handler that registers itself on load and removes itself after
-- running leaves the two sets different the moment anybody connects: the client registers
-- it, the server no longer has it. Nothing can be registered or removed while the game is
-- running, and the whole mod is written that way.
local settle_now, settle_later = false, false

local function settle()
    -- Every step is wrapped, and that is not caution for its own sake: one of these took
    -- the whole fleet down at boot -- an argument count the API refused, raised from a tick
    -- handler, which is non-recoverable -- and a server that will not start is worse than a
    -- surface left uncleared.
    local steps = {
        {"the crash site", disable_crash_site},
        {"the surfaces", ensure_surfaces},
        {"the spawn point", spawn_on_owned_surface},
        {"the surfaces this server does not own", clear_foreign_surfaces},
    }

    for _, step in ipairs(steps) do
        local ok, err = pcall(step[2])
        if not ok then
            log(string.format("[%s] %s could not be done: %s", instance(), step[1], tostring(err)))
        end
    end
end

script.on_nth_tick(60, function()
    if not settle_now then
        return
    end
    settle_now = false
    settle()
end)

script.on_nth_tick(600, function()
    if not settle_later then
        return
    end
    settle_later = false
    settle()
end)

script.on_init(function()
    ensure_storage()
    log("[" .. MOD .. "] instance=" .. instance())
    disable_crash_site()
    ensure_surfaces()
    settle_now, settle_later = true, true
end)

script.on_load(function()
    -- Twice: a node pushes this server's identity a moment after the game is up, and until
    -- that arrives there is no topology to check.
    settle_now, settle_later = true, true
end)

script.on_configuration_changed(function()
    ensure_storage()
    storage.schema = SCHEMA
    disable_crash_site()
    ensure_surfaces()
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
    local player = game.get_player(event.player_index)
    if player and not route_if_elsewhere(player) then
        -- Nowhere to send them, so put them back: the redirect is the first answer, and
        -- standing on a planet this server does not own is the case it does not cover.
        enforce_surface(player)
    end
end)

-- Entering or leaving remote view changes what a player is looking at without changing
-- which surface their body is on, and entering a space platform goes through the
-- controller too, so the routing decision is taken again here.
script.on_event(defines.events.on_player_controller_changed, function(event)
    local player = game.get_player(event.player_index)
    if player and not route_if_elsewhere(player) then
        enforce_surface(player)
    end
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    local player = game.get_player(event.player_index)
    if player then
        note("joined", player)
        apply_join_rule(player)
    end
end)

--------------------------------------------------------------------------------
-- research
--------------------------------------------------------------------------------

-- The tech tree is one tree in Space Age, but this stack runs one save per planet,
-- so every server has its own copy of it and they drift apart immediately. The
-- manager owns the shared state; the mod reports what it has and applies what it
-- is told, which is the same split as everything else here.


-- A research event, for the manager: which research, and when the game says it happened.
local function note_research(kind, name)
    if not name then
        return
    end
    storage.events = storage.events or {}
    storage.events[#storage.events + 1] = {
        kind = kind,
        tech = name,
        tick = game.tick,
    }
    while #storage.events > 64 do
        table.remove(storage.events, 1)
    end
end

-- Which research this server is on, right now.
--
-- Read from the force rather than from the event: a technology can be cancelled, reversed
-- or replaced, and the event's own name is then the one that *was* being researched. What
-- the manager needs is what this server is on afterwards.
local function current_name()
    local research = main_force().current_research
    return research and research.name or nil
end

-- A research changes by more routes than labs finishing.
--
-- A player picks one, a script sets one, a technology is reversed, a queue is reordered,
-- and any of those is a decision the fleet has to hear about -- because the manager
-- learns the fleet's research from the games rather than inferring it from a poll. Every
-- one of the six events is reported, named, for that reason.
script.on_event(defines.events.on_research_started, function(event)
    note_research("research-started",
        (event.research and event.research.name) or current_name())
end)

script.on_event(defines.events.on_research_finished, function(event)
    note_research("researched", event.research and event.research.name)
    -- Whatever the game moved on to, if anything was queued behind it.
    note_research("research-started", current_name())
end)

script.on_event(defines.events.on_research_cancelled, function(event)
    note_research("research-cancelled",
        (event.research and event.research.name) or current_name())
end)

script.on_event(defines.events.on_research_reversed, function(event)
    note_research("research-reversed", event.research and event.research.name)
end)

script.on_event(defines.events.on_research_queued, function(event)
    note_research("research-queued",
        (event.research and event.research.name) or current_name())
end)

script.on_event(defines.events.on_research_moved, function(event)
    note_research("research-moved", event.research and event.research.name)
end)

--------------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------------

commands.add_command(
    MOD .. "-status",
    "Report this server's identity, its topology size and its connected players as JSON.",
    function(event)
        local text = helpers.table_to_json(remote.call(MOD, "report"))
        if event.player_index and game.get_player(event.player_index) then
            game.get_player(event.player_index).print(text)
        elseif rcon then
            rcon.print(text)
        end
    end
)

--------------------------------------------------------------------------------
-- what the node and the manager drive over RCON
--------------------------------------------------------------------------------

-- The calls the node makes, registered both as a remote interface and as one plain
-- command -- and the node uses the command.
--
-- The obvious route is `/c remote.call(...)`, and that is what this started as.
-- It is wrong twice over: `/c` is a *script* command, which permanently marks the
-- save as cheated, and it echoes into the chat, so a manager polling every few
-- seconds fills the screen a player is trying to play on. A mod's own command does
-- neither, which is the whole reason the companion mod did it this way.
local calls = {
    -- Which server this is. Pushed by the node at startup, because the
    -- mod-settings.json route is not read on a headless server (see instance()).
    set_instance = function(id)
        ensure_storage()
        storage.instance = id
        -- Anything recorded against the old identity is meaningless now.
        storage.body = {}
        log("[" .. MOD .. "] instance=" .. tostring(id))
        ensure_surfaces()
        return {instance = instance()}
    end,

    -- Replace the whole destination table. Idempotent: sending the same set twice
    -- changes nothing, so a retried push is harmless.
    set_topology = function(topology)
        ensure_storage()
        storage.topology = {}
        for id, entry in pairs(topology or {}) do
            if type(entry) == "table" and entry.address then
                storage.topology[id] = {
                    name = entry.name or id,
                    address = entry.address,
                    -- Which kind of server it is decides whether this one has a surface
                    -- to create for it: a planet does, a space server does not.
                    kind = entry.kind,
                }
            end
        end
        ensure_surfaces()
        return {instance = instance(), destinations = #destinations()}
    end,

    -- Where a player's body is. The manager owns this fact; the mod only obeys it.
    set_body_location = function(name, id)
        ensure_storage()
        if id == nil or id == instance() then
            storage.body[name] = nil
        else
            storage.body[name] = id
        end
        local player = game.get_player(name)
        if player then
            apply_join_rule(player)
        end
        return {name = name, body = storage.body[name] or instance()}
    end,

    -- What this server's tech tree looks like, a page at a time.
    --
    -- The whole tree does not fit in one RCON frame once enough of it is
    -- researched, and it only grows as the save progresses. The companion mod this
    -- stack replaced had to chunk its reports at 4096 bytes for the same reason, so
    -- this asks for a slice and the node assembles the pages.
    --
    -- Paging is safe without a snapshot because the manager unions what it reads on
    -- every poll: a technology that shifts across a page boundary and is missed once
    -- is picked up on the next pass.
    research_state = function(payload)
        ensure_storage()
        payload = payload or {}

        local force = main_force()
        local all = {}
        for name, technology in pairs(force.technologies) do
            if technology.researched then
                all[#all + 1] = name
            end
        end
        table.sort(all)

        local total = #all
        local offset = tonumber(payload.offset) or 0
        local limit = tonumber(payload.limit) or 64
        if offset < 0 then offset = 0 end
        if limit < 1 then limit = 1 end

        local items = {}
        local count = 0
        for index = offset + 1, math.min(offset + limit, total) do
            items[#items + 1] = all[index]
            count = count + 1
        end

        return {
            instance = instance(),
            items = items,
            count = count,
            total = total,
            current = force.current_research and force.current_research.name or nil,
            -- An infinite research keeps its name as it levels, and its bar restarts each
            -- time. Without the level, one level's progress is indistinguishable from the
            -- next and the manager cannot tell a level-up from a bar going backwards.
            level = force.current_research and force.current_research.level or 0,
            progress = force.research_progress,
            tick = game.tick,
        }
    end,

    -- Apply the shared research: technologies to mark done, and where the research
    -- in progress stands. The manager sends this, because no server can know what
    -- the others have researched.
    apply_research = function(payload)
        ensure_storage()
        payload = payload or {}

        local force = main_force()
        local applied = 0

        for _, name in ipairs(payload.researched or {}) do
            local technology = force.technologies[name]
            if technology and not technology.researched then
                -- A technology the game is currently researching cannot be marked done
                -- directly: the assignment is dropped and the research keeps running, so
                -- a fleet could never finish anything it had started. Cancelling the
                -- research first is the supported way to abandon it, and the technology
                -- takes the flag once nothing is running.
                if force.current_research == technology then
                    pcall(function() force.cancel_current_research() end)
                end

                technology.researched = true

                -- Counted only when it took. Reporting a change the game refused is how
                -- the manager comes to believe a server has something it does not.
                if technology.researched then
                    applied = applied + 1
                end
            end
        end

        if payload.current then
            local technology = force.technologies[payload.current]
            if technology and not technology.researched then
                -- current_research is read only in 2.1 ("is read only" is the error an
                -- assignment gets), so a research is started through add_research.
                --
                -- add_research puts a technology at the *back of the queue*, so with
                -- something already running it is only queued behind it and never becomes
                -- the current research: a planet could never be moved onto the fleet's
                -- research, and would sit on its own while the manager reported the
                -- shared bar. Cancelling first is what makes the switch take, and a
                -- technology the game refuses (its prerequisites unmet) is skipped
                -- rather than failing the whole sync.
                if force.current_research ~= technology then
                    pcall(function() force.cancel_current_research() end)
                    pcall(function() force.add_research(technology) end)
                end

                if payload.progress then
                    force.research_progress = payload.progress
                end

                applied = applied + 1
            end
        end

        return {instance = instance(), applied = applied}
    end,

    -- Everything the game has told this mod since the last drain, so the manager
    -- can act on joins and surface changes it cannot see for itself.
    drain_events = function()
        ensure_storage()
        local events = storage.events or {}
        storage.events = {}
        return events
    end,

    -- Hold the game still, or let it run. The fleet pauses together when one server stops
    -- answering, so that five worlds do not run on without the sixth.
    set_paused = function(paused)
        game.tick_paused = paused and true or false
        return {instance = instance(), paused = game.tick_paused}
    end,

    -- Cut a world down to what this server keeps.
    --
    -- Two different things have to happen, because the game allows two different things. A
    -- platform or a mod's surface can be deleted, and is. A planet's surface cannot: it
    -- belongs to the planet system, so it exists in every save of that world whether
    -- anybody wants it or not. Those are emptied instead -- every entity destroyed, the
    -- planet left bare -- which is exactly what the fleet's own saves look like: all five
    -- planets present, one of them with a factory on it.
    strip_surfaces = function(payload)
        payload = payload or {}

        local keep_set = {}
        for _, name in ipairs(payload.surfaces or {}) do
            keep_set[name] = true
        end

        local keep_platforms = payload.platforms and true or false

        local removed, emptied = {}, {}

        for name, surface in pairs(game.surfaces) do
            local wanted = keep_set[name] or (keep_platforms and surface.platform ~= nil)
            if wanted then
                goto continue
            end

            if surface.deletable then
                if pcall(function() game.delete_surface(name) end) then
                    removed[#removed + 1] = name
                else
                    log(string.format("[%s] could not delete the surface %s", MOD, name))
                end
            else
                local destroyed = 0
                for _, entity in pairs(surface.find_entities()) do
                    if entity.valid then
                        entity.destroy()
                        destroyed = destroyed + 1
                    end
                end
                emptied[name] = destroyed
                log(string.format("[%s] emptied %s: %d entities destroyed", MOD, name, destroyed))
            end

            ::continue::
        end

        table.sort(removed)

        local surfaces = {}
        for name, _ in pairs(game.surfaces) do
            surfaces[#surfaces + 1] = name
        end
        table.sort(surfaces)

        log(string.format("[%s] cut down: removed %d, emptied %d", MOD, #removed, (function()
            local count = 0
            for _ in pairs(emptied) do count = count + 1 end
            return count
        end)()))

        -- joined with commas rather than left as a list: an empty Lua table leaves JSON as
        -- an object, not an array, and a reply whose shape changes is a reply somebody has
        -- to guess at.
        return {instance = instance(), removed = table.concat(removed, ","),
                emptied = emptied, surfaces = surfaces}
    end,

    -- Make every planet this fleet knows about, and say what the world holds afterwards.
    --
    -- A conversion needs this before it strips anything: a save made before a planet existed
    -- holds only what it was made with, and every server has to hold every planet or the
    -- fleet is not one world -- the missing surface is exactly the thing nobody should ever
    -- run into.
    create_surfaces = function()
        ensure_surfaces()

        local out = {}
        for name, _ in pairs(game.surfaces) do
            out[#out + 1] = name
        end
        table.sort(out)

        return {instance = instance(), surfaces = out}
    end,

    -- Take everything off the surfaces this server does not own, and say what was taken.
    -- The manager can ask for it after loading a save, which is exactly the moment a server
    -- can come back holding a world it does not play on.
    clear_surfaces = function()
        local cleared = clear_foreign_surfaces()
        spawn_on_owned_surface()

        local out = {}
        for name, counts in pairs(cleared) do
            out[#out + 1] = string.format("%s(%d entities, %d chunks)", name, counts.entities, counts.chunks)
        end
        table.sort(out)

        return {instance = instance(), cleared = table.concat(out, ", ")}
    end,

    -- Where a player looking at a surface would be sent, without a player to send.
    --
    -- The decision is the one the controller handler makes, and this is how it can be
    -- checked from outside: whether a platform goes to the space server, whether a planet
    -- goes to itself, and whether looking at home is not a journey at all.
    route_for = function(surface)
        local id = destination_for(game.surfaces[surface] or (game.surfaces[1] and nil))

        return {
            instance = instance(),
            surface = surface,
            target = id,
            address = id and (storage.topology[id] or {}).address or nil,
        }
    end,

    -- One poll's worth of state, for the manager's health board.
    report = function()
        local force = main_force()
        local players = {}
        for _, player in pairs(game.connected_players) do
            players[#players + 1] = {
                name = player.name,
                admin = player.admin,
                viewing = storage.viewing[player.name] == true,
                viewing_surface = player.surface and player.surface.name or nil,
            }
        end
        local surfaces = {}
        for name, _ in pairs(game.surfaces) do
            surfaces[#surfaces + 1] = name
        end
        table.sort(surfaces)

        -- Only planets, and only through a pcall: a name that is not a space location --
        -- the space server's own id, for one -- makes the call error, and one bad name here
        -- would take the whole report down with it and leave the manager with no telemetry
        -- at all.
        local unlocked = {}
        for id, entry in pairs(storage.topology or {}) do
            if entry.kind == "planet" then
                local ok, is_unlocked = pcall(function()
                    return force.is_space_location_unlocked and force.is_space_location_unlocked(id)
                end)
                if ok and is_unlocked then
                    unlocked[#unlocked + 1] = id
                end
            end
        end
        table.sort(unlocked)

        return {
            instance = instance(),
            tick = game.tick,
            ups_target = game.speed * 60,
            players = players,
            destinations = #destinations(),
            paused = game.tick_paused,
            surfaces = surfaces,
            unlocked = unlocked,
            spawn = storage.spawn_surface,
            foreign = storage.cleared or {},
            schema = storage.schema,
        }
    end,
}

remote.add_interface(MOD, calls)

-- One entry point for everything above: the node sends {"fn": "...", "args": [...]}
-- and gets the result back as JSON. A single command rather than one per call, so
-- the surface the node depends on is one name that does not move.
commands.add_command(
    MOD .. "-call",
    "Internal: how the node reaches this mod's interface. Not for use by players.",
    function(event)
        local out = {ok = false}

        local decodedOk, payload = pcall(function()
            return helpers.json_to_table(event.parameter)
        end)

        if decodedOk and type(payload) == "table" and type(payload.fn) == "string" and calls[payload.fn] then
            local called, result = pcall(calls[payload.fn], table.unpack(payload.args or {}))
            if called then
                out = result or {ok = true}
            else
                out = {ok = false, error = tostring(result)}
            end
        else
            out = {ok = false, error = "unknown call"}
        end

        -- rcon.print reaches the RCON client and nobody else, which is the point.
        if rcon then
            rcon.print(helpers.table_to_json(out))
        end
    end
)
