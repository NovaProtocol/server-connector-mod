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
local chunks = require("__server-connector-mod__.control.chunks")
local server = require("__server-connector-mod__.control.server")
local platforms = require("__server-connector-mod__.control.platforms")
local platform_api = require("__server-connector-mod__.control.platform_api")
local connector = require("__server-connector-mod__.control.connector")
local pod = require("__server-connector-mod__.control.pod")
local research = require("__server-connector-mod__.control.research")
local map = require("__server-connector-mod__.control.map")
local outbound = require("__server-connector-mod__.control.outbound")
local requests = require("__server-connector-mod__.control.requests")
local debug = require("__server-connector-mod__.control.debug")

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
                -- A restart keeps the identity in the save, so this is the branch that runs
                -- on every fleet start. The connector still has to be ensured here.
                connector.ensure_all()
            end
            debug.boot()
            return {instance = id, unchanged = true}
        end
        if not state.empty() then
            return {instance = state.instance(), skipped = "somebody is connected"}
        end
        state.set_instance(id)
        convert.ensure_surfaces()
        connector.ensure_all()
        debug.boot()
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
            debug.dump("topology deferred while connected", topology)
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
        debug.dump("topology applied", topology)
        convert.ensure_surfaces()
        connector.ensure_all()

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

    -- Create the real platform on the space server from a native one found on a planet
    -- (platforms.create_platform).
    platform_create = platforms.create_platform,
    platform_check = platform_api.check,
    rebuild_platforms = platforms.rebuild_platforms,

    -- What this server's platforms are (platforms.platforms).
    platforms = platforms.platforms,

    -- The connector platform: one per planet, mirrored both ways. The manager reads
    -- connector_state on both sides, applies the canonical one, and compares weights.
    connector_ensure = connector.ensure_all,
    connector_state = connector.state,
    connector_apply = connector.apply,
    connector_build_bay = connector.build_bay,
    connector_remove_bay = connector.remove_bay,
    connector_delete = connector.delete,
    connector_probe = connector.probe,
    connector_edit = connector.edit,
    connector_pad = connector.pad_requests,

    -- Pending platform requests named on the wrong planet server (requests).
    request_platform = requests.create,
    request_moved_ack = requests.ack,
    request_purge_mode = requests.set_mode,
    request_probe = requests.probe,

    -- The platform helper surface (platform_api). The node and the manager call these
    -- directly for a manual read, a full dump or a computed difference.
    platform_meta = platform_api.meta,
    platform_meta_page = platform_api.meta_page,
    platform_hub_dump = platform_api.dump,
    platform_audit = platform_api.audit,
    platform_cargo = platform_api.cargo,
    platform_requests = platform_api.requests,
    apply_cargo_delta = platform_api.apply_cargo_delta,
    apply_requests = platform_api.apply_requests,

    -- The creation call, tried rather than assumed (platforms.platform_api).
    platform_api = platforms.platform_api,

    -- Which surface calls this build actually has (platforms.surface_api).
    surface_api = platforms.surface_api,

    -- One foreign-chunk sweep now, rather than waiting for the minute pass
    -- (chunks.sweep). Returns how many chunks this pass removed.
    sweep_foreign = function()
        state.ensure_storage()
        return {instance = state.instance(), removed = chunks.sweep()}
    end,

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

-- Test the planet <-> platform cargo bridge with a real cargo pod, or with a synthetic queue
-- event when there is no landing pad to launch from.
commands.add_command(
    MOD .. "-podtest",
    "Cargo bridge test: planet_to_platform|platform_to_planet <platform> <item> <count>, or synthetic_add|synthetic_remove <platform> <item> <count>.",
    function(event)
        local args = {}
        for word in string.gmatch(event.parameter or "", "%S+") do
            args[#args + 1] = word
        end
        local ok, result = pcall(pod.test, args[1], args[2], args[3], tonumber(args[4]) or 1)
        if not ok then
            result = {ok = false, error = tostring(result)}
        end
        local text = helpers.table_to_json(result)
        log(string.format("[%s] podtest result: %s", MOD, text))
        if event.player_index and game.get_player(event.player_index) then
            game.get_player(event.player_index).print(text)
        elseif rcon then
            rcon.print(text)
        end
    end
)

-- Measure the scheduled readers with the game's own profiler. This is a diagnostic
-- command, not a control surface: it calls each reader once and prints its measured cost.
commands.add_command(
    MOD .. "-profile",
    "Profile the platform metadata, position, logistic, hub and map readers once.",
    function(event)
        local function measure(label, fn)
            local profiler = helpers.create_profiler()
            fn()
            profiler.stop()
            local text = {"", label .. ": ", profiler}
            if event.player_index and game.get_player(event.player_index) then
                game.get_player(event.player_index).print(text)
            elseif rcon then
                rcon.print(text)
            end
        end

        local ok, err = pcall(function()
            measure("platform_meta full table", platform_api.meta)
            measure("platform_meta change-driven", outbound.tick_meta)
            measure("platform_positions", outbound.tick_positions)
            measure("platform_logistic", outbound.tick_logistic)
            measure("platform_hub", outbound.tick_hub)
            measure("map_tick", map.tick)
        end)
        if not ok then
            log(string.format("[%s] -profile failed: %s", MOD, tostring(err)))
        end
    end
)

-- A diagnostic switch for the platform UDP streams. Off makes the manager stop receiving
-- platform updates; everything else the mod does (console, mirror, join rules) keeps
-- working. Turn it back on when done.
commands.add_command(
    MOD .. "-streams",
    "Turn this server's platform UDP streams on or off. Usage: /server-connector-mod-streams on|off",
    function(event)
        local value = string.lower(event.parameter or "")
        if value ~= "on" and value ~= "off" then
            if rcon then rcon.print("usage: on|off") end
            return
        end
        storage.platform_streams = value == "on"
        if rcon then rcon.print("platform streams " .. value) end
    end
)

-- A read-only check for the copies: hub/bay layout, bay count, asteroid count and any
-- other entity on the platform. The layout hash is the same value on the real ship and a
-- copy of it, so the two can be compared without moving positions over the wire.
commands.add_command(
    MOD .. "-platforms",
    "Report each platform's hub/bay layout hash, bay count, asteroid count and other entities as JSON.",
    function(event)
        local ok, err = pcall(function()
            local list = {}
            for _, platform in pairs(state.main_force().platforms or {}) do
                list[#list + 1] = {
                    name = platform.name,
                    index = platform.index,
                    bays = platforms.bay_count(platform),
                    layout_hash = platforms.layout_hash(platform),
                    asteroids = platforms.asteroid_count(platform),
                    other = platforms.other_entities(platform),
                }
            end
            local text = helpers.table_to_json(list)
            if event.player_index and game.get_player(event.player_index) then
                game.get_player(event.player_index).print(text)
            elseif rcon then
                rcon.print(text)
            end
        end)
        if not ok then
            log(string.format("[%s] -platforms failed: %s", MOD, tostring(err)))
        end
    end
)

-- The connector probe: the platform state, the two groups, the pad and the last events.
-- This is the one-shot check the owner runs after an edit, and the record of which events
-- actually fired for a section add/delete/rename.
commands.add_command(
    MOD .. "-connector",
    "Report the connector platform, its groups, the landing pad and the last events as JSON.",
    function(event)
        local ok, err = pcall(function()
            local text = helpers.table_to_json(connector.probe())
            if event.player_index and game.get_player(event.player_index) then
                game.get_player(event.player_index).print(text)
            elseif rcon then
                rcon.print(text)
            end
        end)
        if not ok then
            log(string.format("[%s] -connector failed: %s", MOD, tostring(err)))
        end
    end
)

-- The request probe: every platform with the two verdicts the purge uses (is_pending and the
-- planet it is for), plus the pack. This is what says whether a pending request is visible at
-- all on a server, which is the first question when a launch goes nowhere.
commands.add_command(
    MOD .. "-requests",
    "Report every platform with its pending-request verdict, planet and starter pack as JSON.",
    function(event)
        local ok, err = pcall(function()
            local text = helpers.table_to_json(requests.probe())
            if event.player_index and game.get_player(event.player_index) then
                game.get_player(event.player_index).print(text)
            elseif rcon then
                rcon.print(text)
            end
        end)
        if not ok then
            log(string.format("[%s] -requests failed: %s", MOD, tostring(err)))
        end
    end
)

-- What each surface actually contains: entities, ghosts and deconstruction orders. Read-only.
-- A planet can look "ghosted" while the count says whether they are unbuilt ghosts or orders.
local function surface_report()
    local out = {}
    for _, surface in pairs(game.surfaces) do
        local function count(filters)
            local ok, value = pcall(function()
                return surface.count_entities_filtered(filters)
            end)
            return ok and value or -1
        end
        out[#out + 1] = {
            name = surface.name,
            platform = surface.platform ~= nil,
            entities = count({}),
            ghosts = count({type = "entity-ghost"}),
            marked = count({to_be_deconstructed = true}),
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return {ok = true, instance = state.instance(), surfaces = out}
end

-- Added after the definition: the calls table is built above this function.
calls.surface_report = surface_report

-- Save this server's world under a name the manager chooses, so an archive can say which
-- file is which without inferring it from the current save's name.
local function save(args)
    args = args or {}
    local name = args.name
    if type(name) ~= "string" or name == "" then
        return {ok = false, error = "a save name is required"}
    end
    if #name > 200 or name:find("[/\\]") then
        return {ok = false, error = "bad save name"}
    end
    local ok, err = pcall(function()
        game.server_save(name)
    end)
    if not ok then
        return {ok = false, error = tostring(err)}
    end
    return {ok = true, name = name, instance = state.instance(), tick = game.tick}
end

calls.save = save

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

            local calledName = "?"
            local calledArgs = nil
            if decodedOk and type(payload) == "table" then
                calledName = payload.fn or "?"
                calledArgs = payload.args
            end
            debug.call(calledName, calledArgs, out)

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
