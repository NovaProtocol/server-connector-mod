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
local route = require("__server-connector-mod__.control.route")
local research = require("__server-connector-mod__.control.research")

local MOD = state.MOD
local SCHEMA = state.SCHEMA

script.on_nth_tick(60, function()
    if not state.known() then
        return
    end

    -- A planet server and asteroids, once a second. Wrapped, because a fault here would run
    -- every second forever.
    pcall(convert.sweep_asteroids)
end)

script.on_init(function()
    state.ensure_storage()
    log("[" .. MOD .. "] instance=" .. state.instance())
    convert.disable_crash_site()
    convert.ensure_surfaces()
end)

script.on_configuration_changed(function()
    state.ensure_storage()
    storage.schema = SCHEMA
    convert.disable_crash_site()
    convert.ensure_surfaces()
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
    local player = game.get_player(event.player_index)
    if player and not route.route_if_elsewhere(player) then
        -- Nowhere to send them, so put them back: the redirect is the first answer, and
        -- standing on a planet this server does not own is the case it does not cover.
        route.enforce_surface(player)
    end
end)

-- Entering or leaving remote view changes what a player is looking at without changing
-- which surface their body is on, and entering a space platform goes through the
-- controller too, so the routing decision is taken again here.
script.on_event(defines.events.on_player_controller_changed, function(event)
    local player = game.get_player(event.player_index)
    if player and not route.route_if_elsewhere(player) then
        route.enforce_surface(player)
    end
end)

-- Registered at load like every other handler, and it runs on both sides identically: when
-- the last player leaves, the world work that was skipped is armed again.
script.on_event(defines.events.on_player_left_game, function()
    if not state.known() then
        return
    end

    if state.empty() then
    end
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    local player = game.get_player(event.player_index)
    if player then
        state.note("joined", player)
        route.apply_join_rule(player)
        -- A join can generate chunks on a surface this server does not own; take them back
        -- off. One join's worth, done at once -- the only clearing the public mod still does.
        convert.clear_foreign_chunks()
    end
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
    research.note_research("research-started",
        (event.research and event.research.name) or research.current_name())
end)

script.on_event(defines.events.on_research_finished, function(event)
    research.note_research("researched", event.research and event.research.name)
    -- Whatever the game moved on to, if anything was queued behind it.
    research.note_research("research-started", research.current_name())
end)

script.on_event(defines.events.on_research_cancelled, function(event)
    research.note_research("research-cancelled",
        (event.research and event.research.name) or research.current_name())
end)

script.on_event(defines.events.on_research_reversed, function(event)
    research.note_research("research-reversed", event.research and event.research.name)
end)

script.on_event(defines.events.on_research_queued, function(event)
    research.note_research("research-queued",
        (event.research and event.research.name) or research.current_name())
end)

script.on_event(defines.events.on_research_moved, function(event)
    research.note_research("research-moved", event.research and event.research.name)
end)
