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
        return
    end

    -- Already looking at where we would send them: nothing to do, and this is
    -- what stops the handler from bouncing a player every time it fires.
    if storage.routed[player.name] == target then
        return
    end

    local entry = storage.topology[target]
    storage.routed[player.name] = target

    log(string.format("[%s] %s looked at %s, sending them to %s",
        instance(), player.name, viewed.name, entry.name or target))

    player.connect_to_server{address = entry.address, name = entry.name or target}
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

script.on_init(function()
    ensure_storage()
    log("[" .. MOD .. "] instance=" .. instance())
    disable_crash_site()
    ensure_surfaces()
end)

-- An existing save never fires on_init again, so the check is scheduled on every load
-- too. on_load may not touch the world -- it may only re-register handlers -- so the work
-- happens on the next tick instead. It runs twice: a node pushes this server's identity a
-- moment after the game is up, and until that arrives there is no topology to check.
script.on_load(function()
    for _, delay in ipairs({60, 600}) do
        script.on_nth_tick(delay, function()
            script.on_nth_tick(delay, nil)
            disable_crash_site()
            ensure_surfaces()
        end)
    end
end)

script.on_configuration_changed(function()
    ensure_storage()
    storage.schema = SCHEMA
    disable_crash_site()
    ensure_surfaces()
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
    local player = game.get_player(event.player_index)
    if player then
        route_if_elsewhere(player)
    end
end)

-- Entering or leaving remote view changes what a player is looking at without changing
-- which surface their body is on, and entering a space platform goes through the
-- controller too, so the routing decision is taken again here.
script.on_event(defines.events.on_player_controller_changed, function(event)
    local player = game.get_player(event.player_index)
    if player then
        route_if_elsewhere(player)
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

        local unlocked = {}
        if force.is_space_location_unlocked then
            for id, _ in pairs(storage.topology or {}) do
                if force.is_space_location_unlocked(id) then
                    unlocked[#unlocked + 1] = id
                end
            end
            table.sort(unlocked)
        end

        return {
            instance = instance(),
            tick = game.tick,
            ups_target = game.speed * 60,
            players = players,
            destinations = #destinations(),
            surfaces = surfaces,
            unlocked = unlocked,
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
