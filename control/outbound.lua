-- server-connector-mod / control/outbound.lua
--
-- Mod -> app, by localhost UDP only.
--
-- There is no stdout/log path any more: the game writes nothing for the app to scrape. The
-- RCON channel stays for calls the app makes into the game; these pushes are the other
-- direction, for events and continuous state the game knows on its own. UDP needs
-- --enable-lua-udp on the game, which the node passes per instance.

local state = require("__server-connector-mod__.control.state")
local platforms = require("__server-connector-mod__.control.platforms")

local main_force = state.main_force

-- The one-container app listens here on its loopback; the game is in the same network
-- namespace.
local UDP_PORT = 8999

-- A server-side event pushed to the app. Never for a player: this is the game telling the
-- app something happened, not a client action.
local function push(kind, payload)
    payload = payload or {}
    payload.kind = kind
    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        return
    end
    pcall(function() helpers.send_udp(UDP_PORT, json) end)
end

-- Every platform's serialized position. `distance` is the fractional position along the
-- connection; `docked` is waiting at a planet rather than in transit.
local function positions()
    local out = {}
    for _, platform in pairs(main_force().platforms or {}) do
        out[#out + 1] = {
            name = platform.name,
            index = platform.index,
            state = tostring(platform.state),
            location = platform.space_location and platform.space_location.name or nil,
            connection = platform.space_connection and platform.space_connection.name or nil,
            distance = platform.distance,
            paused = platform.paused,
            docked = platform.state == defines.space_platform_state.waiting_for_departure,
        }
    end
    return out
end

-- Positions move continuously in transit, so they go every 6 ticks (10 Hz), from the
-- space server only.
local function tick_positions()
    if not state.known() or state.instance() ~= "space" then
        return
    end
    push("platform_positions", {
        instance = state.instance(),
        tick = game.tick,
        platforms = positions(),
    })
end

-- Research progress every second, only when it moved. The delta is what the others add;
-- `progress` is the absolute bar, so a receiver can resync from it.
local function tick_research()
    if not state.known() then
        return
    end

    local force = main_force()
    local technology = force.current_research
    local progress = force.research_progress or 0
    local last = storage.last_research or {}
    if technology and technology.name == last.tech and progress - (last.progress or 0) <= 0 then
        return
    end

    storage.last_research = {
        tech = technology and technology.name or nil,
        progress = progress,
    }

    push("research", {
        instance = state.instance(),
        tick = game.tick,
        tech = technology and technology.name or nil,
        progress = progress,
        delta = technology and technology.name == last.tech
            and math.max(0, progress - (last.progress or 0)) or progress,
        queue = (function()
            local out = {}
            for _, queued in pairs(force.research_queue or {}) do
                out[#out + 1] = queued.name
            end
            return out
        end)(),
    })
end

return {
    push = push,
    tick_positions = tick_positions,
    tick_research = tick_research,
    positions = positions,
}
