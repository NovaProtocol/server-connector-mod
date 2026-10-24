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

script.on_nth_tick(60, function()
    if not state.known() then
        return
    end

    -- A planet server and asteroids, once a second. Guarded, because a fault here would run
    -- every second forever.
    guard("the asteroid sweep", convert.sweep_asteroids)

    -- The map is shown only while the map view is open, and there is no event for opening
    -- it, so the list is refreshed (and shown or hidden) on this pass.
    guard("the server map", map.tick)

    -- Research progress is pushed over UDP only when it moved, once a second.
    guard("outbound research", outbound.tick_research)

    -- The full platform shape: bay count, layout and copy checks. A build/mine event
    -- carries the new layout at once, so five seconds is enough for the periodic refresh;
    -- at 10 Hz it was walking every bay and every entity on the space server.
    if game.tick % 300 == 0 then
        guard("outbound platform meta full", outbound.tick_meta_full)
    end
end)

-- Platform positions move continuously in transit; 2 Hz is enough for the board. Ten hertz
-- was seven datagrams a second across the fleet for a UI that redraws far slower.
-- Cheap metadata from every server, copies included: identity, position and state only.
-- It reads no inventory, so it can run at 10 Hz. Positions are a separate, heavier stream
-- and stay at 2 Hz.
script.on_nth_tick(6, function()
    guard("outbound platform meta", outbound.tick_meta)
end)

script.on_nth_tick(30, function()
    guard("outbound platform positions", outbound.tick_positions)
end)

-- The heavy hub cargo, only when it changed, and the aggregate audit. Both are reads plus
-- one localhost datagram; neither changes the world. The dump is every 30 s, the audit
-- every five minutes.
-- Cargo changes do not need a 10 s stream; 30 s keeps the manager current without reading
-- every hub five times more often than the audit.
script.on_nth_tick(1800, function()
    guard("outbound platform hubs", outbound.tick_hub)
end)

-- The aggregate audit is a safety net, not a live feed. Five minutes leaves the per-pod
-- path and the resync in charge of ordinary cargo.
script.on_nth_tick(18000, function()
    guard("outbound platform audit", outbound.tick_audit)
end)

-- Re-send cargo-pod events for a minute. The queue write is on every peer (the tick is
-- deterministic); the manager de-duplicates by event id.
script.on_nth_tick(600, function()
    guard("the pod queue", pod.tick)
end)

-- The speed this world is kept at, put back on the game as the world comes up. The game
-- writes its speed to nothing, so without this a restart is 1x until the manager says
-- otherwise, and the manager is a poll away.
local function restore_speed()
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

-- A starter pack creates a platform immediately, and that platform must be the real
-- one on the space server. Handling creation directly avoids waiting for the planet
-- mirror to notice an unknown hub, which was the path that kept losing it.
local function report_new_platform(platform)
    if instance() == "space" then
        return
    end
    if not platform or not platform.valid then
        return
    end
    local location = platform.space_location and platform.space_location.name or instance()
    outbound.push("platform_create", {
        instance = instance(),
        name = platform.name,
        location = location,
        tick = game.tick,
    })
end

if defines.events.on_space_platform_created then
    script.on_event(defines.events.on_space_platform_created, function(event)
        guard("a platform creation", function()
            report_new_platform(event.platform)
        end)
    end)
end

-- A backstop for a build that does not fire on_space_platform_created: a rocket launch
-- re-checks this world's platforms against the fleet list and reports anything new.
script.on_event(defines.events.on_rocket_launched, function()
    guard("a rocket launch", function()
        if instance() == "space" then
            return
        end
        local known = {}
        for _, entry in pairs(storage.fleet_platforms or {}) do
            if type(entry) == "table" and entry.name then
                known[entry.name] = true
            end
        end
        for _, platform in pairs(state.main_force().platforms or {}) do
            if not known[platform.name] then
                report_new_platform(platform)
            end
        end
    end)
end)

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
            local platform = surface and surface.platform
            if not platform or not platform.valid then
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
