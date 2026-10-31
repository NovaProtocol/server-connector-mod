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
local platform_api = require("__server-connector-mod__.control.platform_api")
local connector = require("__server-connector-mod__.control.connector")
local demand = require("__server-connector-mod__.control.demand")
local requests = require("__server-connector-mod__.control.requests")
local debug = require("__server-connector-mod__.control.debug")
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

-- The connector queue: one pass per tick, and it does nothing unless an edit, a build or
-- a refund is waiting. The queue is empty in the common case, so this is a dispatch, not a
-- poll of the game.
every(1, "the connector queue", when_known(connector.tick))
every(1, "the demand queue", when_known(demand.tick))
every(18000, "the demand audit", when_known(function() demand.queue("audit") end))

-- Research progress is pushed over UDP only when it moved, once a second.
every(60, "outbound research", when_known(outbound.tick_research))

-- The server window's live rows: players, speed and version, once a second.
every(60, "the heartbeat", when_known(outbound.tick_heartbeat))

-- Re-send cargo-pod events for a minute. The queue write is on every peer (the tick is
-- deterministic); the manager de-duplicates by event id.
every(600, "the pod queue", pod.tick)

-- Re-send a carried platform request until the space server has it. The first message is
-- a datagram and can be dropped; the record lives until a copy of the platform exists
-- here again or the platform has been renamed.
every(600, "the native creates", when_known(platforms.retry_native_creates))

-- The space server's body stays peaceful, and chunks that generate around a player who
-- is standing on it are swept for ten seconds after a join. A no-op elsewhere.
every(60, "the body calm", when_known(function()
    convert.keep_body_calm()
    local left = tonumber(storage.body_clear) or 0
    if left > 0 then
        storage.body_clear = left - 60
        convert.clear_body_chunks()
    end
end))

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
        if rcon then
            storage.connector_ready_pending = true
        end
        log("[" .. MOD .. "] instance=" .. state.instance())
        convert.disable_crash_site()
        convert.ensure_surfaces()
        convert.keep_body_calm()
        connector.ensure_all()
        restore_speed()
        debug.boot()
    end)
end)

script.on_configuration_changed(function()
    guard("on_configuration_changed", function()
        state.ensure_storage()
        storage.schema = SCHEMA
        storage.platform_streams = nil
        storage.meta_seen = nil
        storage.meta_heartbeat = nil
        storage.hub_sent = nil
        storage.hub_weight = nil
        if rcon then
            storage.connector_ready_pending = true
        end
        convert.disable_crash_site()
        convert.ensure_surfaces()
        convert.keep_body_calm()
        connector.ensure_all()
        restore_speed()
        -- Every player in the save gets the new one-button server menu, and the old
        -- per-server frame is removed if this save still has one.
        map.refresh_all()
        debug.boot()
    end)
end)

-- on_load runs on every save load, unlike on_init, which only runs for a new save. It must
-- not touch game or storage: Factorio aborts the load when storage changes here. Marking
-- the boot is a module-local flag; the first connector tick sends connector_ready from the
-- server once the identity has arrived.
script.on_load(function()
    guard("on_load", function()
        if rcon then
            connector.mark_boot()
        end
    end)
end)

-- A join is the one moment a controller can be changed safely: the client runs the same
-- event. Nothing here moves a character to another surface -- a server-side teleport on join
-- is a world change the client does not see, and it desyncs.
-- A platform changing state is the server-side event the manager needs: docking, leaving,
-- arriving. It is pushed immediately over localhost UDP, not left for a poll.
-- A deconstruction order on the connector is allowed: the hub and the bays are the only
-- things that may exist, and mining a bay is how a player removes one. Nothing cancels it.

-- A building placed or removed on a connector changes its bay layout. Anything that is not
-- the hub or a cargo bay is refunded to the hub and removed, so the item is not lost.
script.on_event(defines.events.on_space_platform_built_entity, function(event)
    guard("a platform build", function()
        connector.guard_build(event)
    end)
end)

script.on_event(defines.events.on_space_platform_mined_entity, function(event)
    guard("a platform mine", function()
        connector.guard_mine(event)
    end)
end)

-- A native platform surface on a planet cannot be owned by that planet. The player's
-- request is carried to the space server, which is the only place a real platform lives.
local function reject_native_platform(surface, what)
    guard(what, function()
        -- A platform this mod is creating raises the same events. Let create_platform
        -- finish; its own checks and the next ensure handle the result.
        if storage.connector_creating or storage.creating_copy then
            return
        end
        local platform = surface and surface.platform
        if platform and platform.valid then
            if connector.is_connector(platform) then
                return
            end
            debug.dump("native platform", debug.platform_table(platform))
            -- A platform the game made natively on a planet is a request, not something
            -- that planet can own: it is destroyed here and asked for on the space server
            -- under the same name at the same planet. The space server leaves its own
            -- platforms exactly as they are (adopt_native_platform returns there).
            platforms.adopt_native_platform(platform, platform.name)
        end
        connector.ensure_all()
    end)
end

if defines.events.on_surface_created then
    script.on_event(defines.events.on_surface_created, function(event)
        guard("a surface creation", function()
            debug.event("on_surface_created", event)
            local surface = game.get_surface(event.surface_index)
            if not surface then
                return
            end
            debug.dump("surface created", debug.surface_table(surface))

            -- Every creation is logged, including the one that has no platform attached yet.
            -- That was the silent case: a new platform surface can exist for a moment before
            -- surface.platform answers, and returning quietly left a launch with no trace.
            local platform = surface.platform
            log(string.format("[%s] surface created: %s (platform=%s, copy=%s)",
                state.instance(), surface.name,
                tostring(platform ~= nil),
                tostring(platform ~= nil and platforms.is_copy(platform))))

            reject_native_platform(surface, "a surface creation")
            convert.keep_body_calm()
        end)
    end)
end

if defines.events.on_space_platform_created then
    script.on_event(defines.events.on_space_platform_created, function(event)
        guard("a platform creation", function()
            debug.event("on_space_platform_created", event)
            local platform = event.platform
            if platform and platform.valid and connector.is_connector(platform) then
                return
            end
            reject_native_platform(platform and platform.surface, "a platform creation")
        end)
    end)
end


-- A logistic request change on a connector hub or the landing pad. This is the event the
-- old polling was standing in for. The whole connector state travels with it: the manager
-- applies it to the counterpart and compares the hub weight.
if defines.events.on_surface_deleted then
    script.on_event(defines.events.on_surface_deleted, function(event)
        guard("a surface deleted", function()
            if instance() == "space" then
                demand.queue("surface deleted")
            end
        end)
    end)
end

if defines.events.on_entity_logistic_slot_changed then
    script.on_event(defines.events.on_entity_logistic_slot_changed, function(event)
        guard("a logistic slot change", function()
            debug.event("on_entity_logistic_slot_changed", event)
            if (storage.connector_writing or 0) > 0 then
                return
            end
            if event.player_index == nil and game.tick - (storage.demand_last_write or -1000) <= 2 then
                return
            end
            local entity = event.entity
            if not entity or not entity.valid then
                return
            end

            if entity.name == "rocket-silo" then
                log(string.format("[%s] silo %s on %s: starter-pack requests now %d",
                    instance(), tostring(entity.unit_number),
                    entity.surface and entity.surface.name or "?",
                    platforms.starter_pack_requests(entity)))
                return
            end

            if entity.name == "cargo-landing-pad" then
                if instance() ~= "space" then
                    demand.queue("pad edit")
                end
                return
            end

            if entity.name ~= "space-platform-hub" then
                return
            end
            local platform = entity.surface and entity.surface.platform
            if not platform or not platform.valid then
                return
            end
            if connector.is_connector(platform) then
                demand.queue("hub edit")
            elseif instance() == "space" then
                demand.queue("platform edit")
            end
        end)
    end)
end

script.on_event(defines.events.on_space_platform_changed_state, function(event)
    guard("a platform state change", function()
        debug.event("on_space_platform_changed_state", event)
        connector.state_changed(event)
        connector.sweep(event.platform)
        -- A platform changing state can mean it is now scheduled for deletion.
        if instance() == "space" and event.platform and event.platform.valid
            and not connector.is_connector(event.platform) then
            demand.queue("platform state")
        end
    end)
end)

-- A hub that is mined or dies is the platform going away. Both are bound because which one
-- fires depends on how the player deleted it; connector dedupes the report.
script.on_event(defines.events.on_pre_player_mined_item, function(event)
    guard("a pre-mine", function()
        connector.guard_death(event)
    end)
end)

script.on_event(defines.events.on_entity_died, function(event)
    guard("a death", function()
        connector.guard_death(event)
    end)
end)

-- Planet <-> platform cargo. A pod leaving a copy hub is removed from the real hub; a pod
-- arriving at a copy hub is added. The real space hubs are native platform logistics and are
-- ignored. The queue is re-sent for a minute; the manager de-duplicates.
script.on_event(defines.events.on_cargo_pod_started_ascending, function(event)
    guard("a cargo pod start", function()
        debug.event("on_cargo_pod_started_ascending", event)
        pod.started(event)
    end)
end)

script.on_event(defines.events.on_cargo_pod_finished_ascending, function(event)
    guard("a cargo pod ascent", function()
        debug.event("on_cargo_pod_finished_ascending", event)
        pod.started(event)
    end)
end)

script.on_event(defines.events.on_cargo_pod_delivered_cargo, function(event)
    guard("a cargo pod delivery", function()
        debug.event("on_cargo_pod_delivered_cargo", event)
        pod.delivered(event)
    end)
end)

script.on_event(defines.events.on_player_created, function(event)
    guard("a player creation", function()
        map.refresh(game.get_player(event.player_index))
    end)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    guard("a join", function()
        debug.event("on_player_joined_game", event)
        local player = game.get_player(event.player_index)
        if player then
            state.note("joined", player)
            server.apply_join_rule(player)
            map.refresh(player)
            -- Ten seconds of sweeping the body's freshly generated chunks. The pass itself
            -- does nothing on an instance that has no body.
            storage.body_clear = 600
        end
    end)
end)

-- A topology that arrived while somebody was connected applied its destinations but left
-- its surface changes for later. The last player leaving is that later.
script.on_event(defines.events.on_player_left_game, function(event)
    guard("a leave", function()
        debug.event("on_player_left_game", event)
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

-- Escape closes the server window because the window is player.opened while it is shown.
script.on_event(defines.events.on_gui_closed, function(event)
    guard("a menu close", function()
        map.closed(event)
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
