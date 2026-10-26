-- server-connector-mod / control/events.lua
--
-- Every event handler the mod registers, in one place. Loading this file is what arms the
-- mod; there is nothing to call.
--
-- The load-time check, as permanent handlers.
--
-- Each one is registered here, once, at load, and never removed.
--
-- It has to be that way. The game compares the event handlers a joining client has against
-- the server's, and a handler that registers itself on load and removes itself after
-- running leaves the two sets different the moment anybody connects: the client registers
-- it, the server no longer has it. Nothing can be registered or removed while the game is
-- running, and the whole mod is written that way.
--
-- Required as "__server-connector-mod__.control.events". Required last but for rcon, so
-- the domains it drives are already loaded.

local state = require("__server-connector-mod__.control.state")
local convert = require("__server-connector-mod__.control.convert")
local chunks = require("__server-connector-mod__.control.chunks")
local server = require("__server-connector-mod__.control.server")
local map = require("__server-connector-mod__.control.map")
local research = require("__server-connector-mod__.control.research")
local platforms = require("__server-connector-mod__.control.platforms")
local pod = require("__server-connector-mod__.control.pod")
local outbound = require("__server-connector-mod__.control.outbound")

local MOD = state.MOD
local SCHEMA = state.SCHEMA
local instance = state.instance

-- Everything a handler does is wrapped in this.
--
-- An error raised from an event handler is non-recoverable in Factorio: the server quits,
-- and the fleet's watchdog then stops the other five without saving. A field one build does
-- not have, one entity that went invalid between two lines, must not be able to do that. So
-- a handler's work is a function whose failure is a log line, and the handler returns.
local function guard(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        log(string.format("[%s] %s failed: %s", state.instance(), what, tostring(err)))
    end
end

-- Every nth-tick handler is collected here and registered by a single dispatcher per
-- interval at the end of this file. Factorio keeps only one handler per interval; two
-- script.on_nth_tick(60, ...) calls silently replaced each other, which is how the asteroid
-- sweep, map refresh and research push stopped running.
local intervals = {}

local function every(ticks, name, fn)
    local handlers = intervals[ticks]
    if not handlers then
        handlers = {}
        intervals[ticks] = handlers
    end
    for _, handler in ipairs(handlers) do
        if handler.name == name then
            log(string.format("[%s] duplicate nth_tick handler %s at %d ticks", state.instance(), name, ticks))
            return
        end
    end
    handlers[#handlers + 1] = {name = name, fn = fn}
end

local function when_known(fn)
    return function()
        if state.known() then
            fn()
        end
    end
end

-- A planet server and asteroids, once a second.
every(60, "the asteroid sweep", when_known(convert.sweep_asteroids))

-- The surface check, once a second: a body standing where this instance does not own it is
-- put back, a queued space body is removed when the server is empty, and the spawn point is
-- re-asserted if it drifted. Every one of these is a no-op in the common case.
every(60, "the surface check", when_known(function()
    for _, player in pairs(game.connected_players) do
        server.enforce_surface(player)
    end
    server.destroy_queued()
    convert.spawn_on_owned_surface()
end))

-- Chunks on a surface this server does not own, once a minute. Per chunk, and a chunk with a
-- body in it is kept: that is the joining player or a copy from another save.
every(3600, "the foreign chunks", when_known(chunks.sweep))

-- Silo starter-pack counts and platform names, once a minute, logged only when they change.
-- The logistic-slot event does not cover every edit the game makes, so this is the trace that
-- cannot be missed.
every(60, "the platform watch", when_known(platforms.watch))

-- The map is shown only while the map view is open, and there is no event for opening it,
-- so the list is refreshed (and shown or hidden) on this pass.
every(60, "the server map", when_known(map.tick))

-- Research progress is pushed over UDP only when it moved, once a second.
every(60, "outbound research", when_known(outbound.tick_research))

-- There is deliberately no periodic layout/bay push here. A build or mine on the real
-- platform carries the new layout at once, and a server boot gets the full snapshot.
-- Re-sending every platform's shape on a timer was periodic building traffic.

-- Platform positions move continuously in transit; 2 Hz is enough for the board. Ten hertz
-- was seven datagrams a second across the fleet for a UI that redraws far slower.
-- Cheap metadata from every server, copies included: identity, position and state only.
-- It reads no inventory, so it can run at 10 Hz. Positions are a separate, heavier stream
-- and stay at 2 Hz.
every(6, "outbound platform meta", outbound.tick_meta)

every(30, "outbound platform positions", outbound.tick_positions)

-- Requests are the expensive part of the full meta, so they get their own 1 Hz stream.
every(60, "outbound platform logistic", outbound.tick_logistic)

-- The heavy hub cargo, only when it changed, and the aggregate audit. Both are reads plus
-- one localhost datagram; neither changes the world. The dump is every 30 s, the audit
-- every five minutes.
-- Cargo changes do not need a 10 s stream; 30 s keeps the manager current without reading
-- every hub five times more often than the audit.
every(1800, "outbound platform hubs", outbound.tick_hub)

-- The aggregate audit is a safety net, not a live feed. Five minutes leaves the per-pod
-- path and the resync in charge of ordinary cargo.
every(18000, "outbound platform audit", outbound.tick_audit)

-- Re-send cargo-pod events for a minute. The queue write is on every peer (the tick is
-- deterministic); the manager de-duplicates by event id.
every(600, "the pod queue", pod.tick)

-- The speed this world is kept at, put back on the game as the world comes up. The game
-- writes its speed to nothing, so without this a restart is 1x until the manager says
-- otherwise, and the manager is a poll away.
local function restore_speed()
    -- A save taken while tick-paused carries that flag. The manager also clears it after a
    -- start, but the save itself should never open frozen; clearing here covers a manual
    -- game start and the manager's own boot path.
    game.tick_paused = false
    local speed = tonumber(storage.speed)
    if speed and speed > 0 then
        game.speed = speed
    end
end

script.on_init(function()
    guard("on_init", function()
        state.ensure_storage()
        log("[" .. MOD .. "] instance=" .. state.instance())
        convert.disable_crash_site()
        convert.ensure_surfaces()
        restore_speed()
    end)
end)

script.on_configuration_changed(function()
    guard("on_configuration_changed", function()
        state.ensure_storage()
        storage.schema = SCHEMA
        convert.disable_crash_site()
        convert.ensure_surfaces()
        restore_speed()
    end)
end)

-- A join is the one moment a controller can be changed safely: the client runs the same
-- event. Nothing here moves a character to another surface -- a server-side teleport on join
-- is a world change the client does not see, and it desyncs.
-- A platform changing state is the server-side event the manager needs: docking, leaving,
-- arriving. It is pushed immediately over localhost UDP, not left for a poll.
-- A copy is a view. If a player marks one of its entities for deconstruction, cancel it;
-- the entity is also minable=false and operable=false, so the order should not have got
-- far, but an order can be placed before a mirror push re-applies the flags.
script.on_event(defines.events.on_marked_for_deconstruction, function(event)
    guard("a deconstruction order", function()
        platforms.cancel_copy_deconstruction(event.entity)
    end)
end)

-- A building placed or removed on the real space platform changes the bay layout. Tell
-- the manager at once rather than waiting for the next poll; the manager pushes the new
-- list, and each planet applies it at its next empty window.
local function announce_platform_layout(event, what)
    guard(what, function()
        if state.instance() ~= "space" then
            return
        end
        local platform = event.platform
        if not platform and event.entity and event.entity.valid then
            platform = event.entity.surface and event.entity.surface.platform
        end
        if not platform or not platform.valid then
            return
        end
        outbound.push("platform_layout", {
            instance = state.instance(),
            tick = game.tick,
            name = platform.name,
            index = platform.index,
            bays = platforms.bay_count(platform),
            layout = platforms.layout_of(platform),
            layout_hash = platforms.layout_hash(platform),
        })
    end)
end

script.on_event(defines.events.on_space_platform_built_entity, function(event)
    announce_platform_layout(event, "a platform build")
end)

script.on_event(defines.events.on_space_platform_mined_entity, function(event)
    announce_platform_layout(event, "a platform mine")
end)

-- A native platform surface on a planet is a duplicate. The space server owns the real
-- platform, so delete this one and ask the manager to create it there under the same name.
-- The normal platform mirror then puts a protected copy back on every planet.
local function reject_native_platform(surface, what)
    guard(what, function()
        if instance() == "space" or not surface or not surface.valid then
            return
        end
        local platform = surface.platform
        if not platform or not platform.valid or platforms.is_copy(platform) then
            return
        end

        local name = platform.name
        local location = platform.space_location and platform.space_location.name or instance()
        if not platforms.remove_native_platform(platform) then
            log(string.format("[%s] could not remove native platform %s", instance(), name))
            return
        end

        outbound.push("platform_create", {
            instance = instance(),
            name = name,
            location = location,
            tick = game.tick,
        })
        log(string.format("[%s] removed native platform %s; the space server will create it", instance(), name))
    end)
end

if defines.events.on_surface_created then
    script.on_event(defines.events.on_surface_created, function(event)
        reject_native_platform(game.get_surface(event.surface_index), "a surface creation")
    end)
end

if defines.events.on_space_platform_created then
    script.on_event(defines.events.on_space_platform_created, function(event)
        local platform = event.platform
        reject_native_platform(platform and platform.surface, "a platform creation")
    end)
end

-- A logistic request change on a platform hub. This is the event the polling was standing
-- in for: the hub's request filters changed, so the copies need the new set and their
-- logistics can queue the rockets.
if defines.events.on_entity_logistic_slot_changed then
    script.on_event(defines.events.on_entity_logistic_slot_changed, function(event)
        guard("a logistic slot change", function()
            local entity = event.entity
            if not entity or not entity.valid then
                return
            end
            local surface = entity.surface

            -- A rocket silo is the only place a new platform starts from. This mod no longer
            -- touches its requests, so a request that disappears with no launch is either the
            -- game or the client; this line is what tells the two apart.
            if entity.name == "rocket-silo" then
                log(string.format("[%s] silo %s on %s: starter-pack requests now %d",
                    instance(), tostring(entity.unit_number),
                    surface and surface.name or "?", platforms.starter_pack_requests(entity)))
            end

            local platform = surface and surface.platform
            if not platform or not platform.valid then
                return
            end

            -- A copy is a view. Its requests come from the real platform through the mirror,
            -- so an edit here is not news: forwarding it made the manager resync from a copy
            -- and then write the real list back over it, which looked like the request being
            -- removed a few seconds after it was made.
            if platforms.is_copy(platform) then
                log(string.format("[%s] ignoring a logistic change on the copy of %s",
                    instance(), platform.name))
                return
            end

            outbound.push("platform_requests", {
                instance = instance(),
                name = platform.name,
                index = platform.index,
                tick = game.tick,
            })
        end)
    end)
end

script.on_event(defines.events.on_space_platform_changed_state, function(event)
    guard("a platform state change", function()
        local platform = event.platform
        if not platform or not platform.valid then
            return
        end

        outbound.push("platform", {
            instance = state.instance(),
            name = platform.name,
            index = platform.index,
            state = tostring(platform.state),
            location = platform.space_location and platform.space_location.name or nil,
            connection = platform.space_connection and platform.space_connection.name or nil,
            distance = platform.distance,
        })
    end)
end)

-- Planet <-> platform cargo. A pod leaving a copy hub is removed from the real hub; a pod
-- arriving at a copy hub is added. The real space hubs are native platform logistics and are
-- ignored. The queue is re-sent for a minute; the manager de-duplicates.
script.on_event(defines.events.on_cargo_pod_started_ascending, function(event)
    guard("a cargo pod start", function() pod.started(event) end)
end)

script.on_event(defines.events.on_cargo_pod_finished_ascending, function(event)
    guard("a cargo pod ascent", function() pod.started(event) end)
end)

script.on_event(defines.events.on_cargo_pod_delivered_cargo, function(event)
    guard("a cargo pod delivery", function() pod.delivered(event) end)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    guard("a join", function()
        local player = game.get_player(event.player_index)
        if player then
            state.note("joined", player)
            server.apply_join_rule(player)
            map.refresh(player)
        end
    end)
end)

-- A topology that arrived while somebody was connected applied its destinations but left
-- its surface changes for later. The last player leaving is that later.
script.on_event(defines.events.on_player_left_game, function()
    guard("a leave", function()
        if not state.empty() then
            return
        end

        -- The last player leaving is also the window for the queued space bodies and the
        -- foreign chunks: no client can be missing a change made here.
        server.destroy_queued()
        chunks.sweep()

        -- The last player leaving is the safe window for a deferred surface change.
        if not storage.pending_surfaces then
            return
        end
        storage.pending_surfaces = nil
        convert.ensure_surfaces()
        local own = (storage.topology or {})[state.instance()]
        if own and type(own.forms) == "table" and #own.forms > 0 then
            convert.create_custom_surfaces(own.forms)
        end
        for _, player in pairs(game.connected_players) do
            map.refresh(player)
        end
    end)
end)

-- The server map's buttons.

script.on_event(defines.events.on_gui_click, function(event)
    guard("a map click", function()
        map.click(event)
    end)
end)

--------------------------------------------------------------------------------
-- research
--------------------------------------------------------------------------------

-- A research changes by more routes than labs finishing.
--
-- A player picks one, a script sets one, a technology is reversed, a queue is reordered,
-- and any of those is a decision the fleet has to hear about -- because the manager
-- learns the fleet's research from the games rather than inferring it from a poll. Every
-- one of the six events is reported, named, for that reason.
script.on_event(defines.events.on_research_started, function(event)
    guard("a research start", function()
        research.note_research("research-started",
            (event.research and event.research.name) or research.current_name())
    end)
end)

script.on_event(defines.events.on_research_finished, function(event)
    guard("a finished research", function()
        research.note_research("researched", event.research and event.research.name)
        -- Whatever the game moved on to, if anything was queued behind it.
        research.note_research("research-started", research.current_name())
    end)
end)

script.on_event(defines.events.on_research_cancelled, function(event)
    guard("a cancelled research", function()
        research.note_research("research-cancelled",
            (event.research and event.research.name) or research.current_name())
    end)
end)

script.on_event(defines.events.on_research_reversed, function(event)
    guard("a reversed research", function()
        research.note_research("research-reversed", event.research and event.research.name)
    end)
end)

script.on_event(defines.events.on_research_queued, function(event)
    guard("a queued research", function()
        research.note_research("research-queued",
            (event.research and event.research.name) or research.current_name())
    end)
end)

script.on_event(defines.events.on_research_moved, function(event)
    guard("a moved research", function()
        research.note_research("research-moved", event.research and event.research.name)
    end)
end)

--------------------------------------------------------------------------------
-- nth-tick dispatch
--------------------------------------------------------------------------------

local ordered_intervals = {}
for ticks in pairs(intervals) do
    ordered_intervals[#ordered_intervals + 1] = ticks
end
table.sort(ordered_intervals)

local fired = {}
for _, ticks in ipairs(ordered_intervals) do
    local handlers = intervals[ticks]
    local names = {}
    for _, handler in ipairs(handlers) do
        names[#names + 1] = handler.name
    end
    log(string.format("[%s] nth_tick %d: %s", instance(), ticks, table.concat(names, ", ")))

    script.on_nth_tick(ticks, function()
        for _, handler in ipairs(handlers) do
            if not fired[handler.name] then
                fired[handler.name] = true
                log(string.format("[%s] nth_tick %d fired: %s", instance(), ticks, handler.name))
            end
            guard(handler.name, handler.fn)
        end
    end)
end
