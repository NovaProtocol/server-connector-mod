-- server-connector-mod / control/rcon.lua
--
-- The surface the node and the manager drive over RCON: one remote interface and one
-- command. Each entry is either glue over two domains (set_instance, set_topology,
-- set_body_location, set_paused, settle) or a reference to the function that owns it
-- (research, convert, platforms, state).
--
-- Required as "__server-connector-mod__.control.rcon". Required last: it is the only
-- module that reaches across all the others.

local state = require("__server-connector-mod__.control.state")
local convert = require("__server-connector-mod__.control.convert")
local server = require("__server-connector-mod__.control.server")
local platforms = require("__server-connector-mod__.control.platforms")
local research = require("__server-connector-mod__.control.research")
local map = require("__server-connector-mod__.control.map")

local MOD = state.MOD

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
    -- mod-settings.json route is not read on a headless server (see state.instance()).
    set_instance = function(id)
        if type(id) ~= "string" or id == "" then
            return {ok = false, error = "instance must be a non-empty string"}
        end
        state.ensure_storage()
        if storage.instance == id then
            if state.empty() then
                convert.ensure_surfaces()
            end
            return {instance = id, unchanged = true}
        end
        if not state.empty() then
            return {instance = state.instance(), skipped = "somebody is connected"}
        end
        state.set_instance(id)
        convert.ensure_surfaces()
        return {instance = state.instance()}
    end,

    -- Replace the whole destination table. Idempotent: sending the same set twice
    -- changes nothing, so a retried push is harmless.
    set_topology = function(topology)
        state.ensure_storage()
        local wanted = state.normalize_topology(topology)
        if state.same_topology(wanted, storage.topology) then
            if state.empty() then
                convert.ensure_surfaces()
                -- The forms are part of the unchanged topology too. A declared flat surface
                -- that already exists still has to be replaced, or an old mixed world is
                -- kept for ever because the manager keeps sending the same topology.
                local own = (storage.topology or {})[state.instance()]
                if own and type(own.forms) == "table" and #own.forms > 0 then
                    convert.create_custom_surfaces(own.forms)
                end
            end
            return {instance = state.instance(), destinations = #state.destinations(), unchanged = true}
        end
        if not state.empty() then
            -- Destinations are data, and a connected player needs the map buttons that use
            -- them. Only surface creation is a world change; that waits for an empty server,
            -- which the leave event picks up.
            state.set_topology(topology)
            storage.pending_surfaces = true
            for _, player in pairs(game.connected_players) do
                map.refresh(player)
            end
            return {
                instance = state.instance(),
                destinations = #state.destinations(),
                deferred = "surface changes wait for an empty server",
            }
        end
        state.set_topology(topology)
        convert.ensure_surfaces()

        -- The topology carries the surfaces this instance owns, with the form each was
        -- declared with. This is where a custom instance's declared surfaces come into
        -- existence: the manager creates the instance, the instance starts, and the first
        -- topology it receives makes them.
        local own = (storage.topology or {})[state.instance()]
        if own and type(own.forms) == "table" and #own.forms > 0 then
            convert.create_custom_surfaces(own.forms)
        end

        return {instance = state.instance(), destinations = #state.destinations()}
    end,

    -- Where a player's body is, and what that makes them on this server
    -- (server.set_body_location). The manager calls it by this name.
    set_body_location = server.set_body_location,

    -- One page of this server's researched technologies (research.research_state).
    research_state = research.research_state,

    -- Apply the shared tech tree (research.apply_research).
    apply_research = research.apply_research,

    -- Unlock everything, for a custom instance whose research mode is "all".
    research_all = research.research_all,

    -- Everything the game has told this mod since the last drain, so the manager
    -- can act on joins and surface changes it cannot see for itself.
    drain_events = function()
        state.ensure_storage()
        return state.drain()
    end,

    -- Hold the game still, or let it run. The fleet pauses together when one server stops
    -- answering, so that five worlds do not run on without the sixth.
    set_paused = function(paused)
        game.tick_paused = paused and true or false
        return {instance = state.instance(), paused = game.tick_paused}
    end,

    -- How fast this world runs. Set here rather than from the console because a console line
    -- that is not a command is chat: it reaches nobody, changes nothing, and only looks like
    -- it worked. The value is kept in storage as well, because the game writes its speed to
    -- nothing -- a restart is 1x until something sets it again, and this is that something.
    set_speed = function(speed)
        local value = tonumber(speed)
        if not value or value ~= value or value <= 0 then
            return {ok = false, error = "a speed has to be a positive number"}
        end

        game.speed = value
        storage.speed = value
        return {ok = true, speed = game.speed}
    end,

    -- Make this instance's surfaces. With a list, it is the custom surfaces the manager
    -- declared, with their generation forms (convert.create_custom_surfaces); without one, it
    -- is every owned surface that is missing.
    create_surfaces = function(entries)
        if not state.empty() then
            return {instance = state.instance(), skipped = "somebody is connected"}
        end
        return convert.create_surfaces(entries)
    end,

    -- Delete one custom surface. Refused while anybody is connected, and for the primary.
    delete_surface = function(name)
        return convert.delete_surface(name)
    end,

    -- What surfaces this world has (convert.surfaces).
    surfaces = convert.surfaces,

    -- Bring this world into line, as an order carried out only with nobody connected
    -- (convert.settle).
    settle = convert.settle,

    -- Make, keep or remove this server's copies of the fleet's platforms
    -- (platforms.mirror_platforms).
    mirror_platforms = platforms.mirror_platforms,

    -- What this server's platforms are (platforms.platforms).
    platforms = platforms.platforms,

    -- The creation call, tried rather than assumed (platforms.platform_api).
    platform_api = platforms.platform_api,

    -- Which surface calls this build actually has (platforms.surface_api).
    surface_api = platforms.surface_api,

    -- One poll's worth of state, for the manager's health board (state.report).
    report = state.report,
}

remote.add_interface(MOD, calls)

--------------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------------

commands.add_command(
    MOD .. "-status",
    "Report this server's identity, its topology size and its connected players as JSON.",
    function(event)
        -- A command error is as fatal as a handler error, so it is contained here too.
        local ok, err = pcall(function()
            local text = helpers.table_to_json(remote.call(MOD, "report"))
            if event.player_index and game.get_player(event.player_index) then
                game.get_player(event.player_index).print(text)
            elseif rcon then
                rcon.print(text)
            end
        end)
        if not ok then
            log(string.format("[%s] -status failed: %s", MOD, tostring(err)))
        end
    end
)

-- One entry point for everything above: the node sends {"fn": "...", "args": [...]}
-- and gets the result back as JSON. A single command rather than one per call, so
-- the surface the node depends on is one name that does not move.
commands.add_command(
    MOD .. "-call",
    "Internal: how the node reaches this mod's interface. Not for use by players.",
    function(event)
        if event.player_index then
            local caller = game.get_player(event.player_index)
            if caller then
                caller.print("This command is not available to players.")
            end
            return
        end

        -- The call itself is already wrapped. This is the last line: decoding the request and
        -- encoding the answer are the game's own helpers, and neither may quit the server.
        local handled, err = pcall(function()
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
        end)
        if not handled then
            log(string.format("[%s] -call failed: %s", MOD, tostring(err)))
        end
    end
)
