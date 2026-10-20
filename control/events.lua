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

local MOD = state.MOD
local SCHEMA = state.SCHEMA

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

-- Entering or leaving remote view, or boarding a platform, still goes through the controller,
-- and a player can end up standing somewhere this instance does not own. There is no journey
-- decision here any more: the map's buttons are the journeys.
script.on_event(defines.events.on_player_controller_changed, function(event)
    guard("a controller change", function()
        local player = game.get_player(event.player_index)
        if player then
            server.enforce_surface(player)
        end
    end)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    guard("a join", function()
        local player = game.get_player(event.player_index)
        if player then
            state.note("joined", player)
            server.apply_join_rule(player)
            -- Put them on this server's own surface as they arrive, rather than waiting for
            -- them to change surface before anything happens. Joining a server is an answer
            -- about where they belong: whichever server they reached, they meant to be on its
            -- planet.
            --
            -- enforce_surface returns without doing anything when they are already standing
            -- on a surface this instance owns. Journeys are the map's buttons now, not a
            -- surface change.
            server.enforce_surface(player)
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
