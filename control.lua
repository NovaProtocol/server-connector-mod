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
    if surface.platform then
        return storage.topology["space"] and "space" or nil
    end
    return storage.topology[surface.name] and surface.name or nil
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
end)

script.on_configuration_changed(function()
    ensure_storage()
    storage.schema = SCHEMA
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
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

remote.add_interface(MOD, {
    -- Which server this is. Pushed by the node at startup, because the
    -- mod-settings.json route is not read on a headless server (see instance()).
    set_instance = function(id)
        ensure_storage()
        storage.instance = id
        -- Anything recorded against the old identity is meaningless now.
        storage.body = {}
        log("[" .. MOD .. "] instance=" .. tostring(id))
        return {instance = instance()}
    end,

    -- Replace the whole destination table. Idempotent: sending the same set twice
    -- changes nothing, so a retried push is harmless.
    set_topology = function(topology)
        ensure_storage()
        storage.topology = {}
        for id, entry in pairs(topology or {}) do
            if type(entry) == "table" and entry.address then
                storage.topology[id] = {name = entry.name or id, address = entry.address}
            end
        end
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
        local players = {}
        for _, player in pairs(game.connected_players) do
            players[#players + 1] = {
                name = player.name,
                admin = player.admin,
                viewing = storage.viewing[player.name] == true,
                viewing_surface = player.surface and player.surface.name or nil,
            }
        end
        return {
            instance = instance(),
            tick = game.tick,
            ups_target = game.speed * 60,
            players = players,
            destinations = #destinations(),
            schema = storage.schema,
        }
    end,
})
