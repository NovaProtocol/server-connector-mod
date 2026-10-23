-- server-connector-mod / control/outbound.lua
--
-- Mod -> node, without RCON.
--
-- RCON is a request/response channel: the node asks, the mod answers. Everything the mod
-- knows on its own -- telemetry, the platforms, the events it saw -- used to wait for the
-- node's next poll. These are read-only facts and writing them does not touch the game, so
-- they go out as one marked line on stdout instead. The node's read of that pipe is
-- sub-millisecond and has no effect on the simulation, unlike a script command.
--
-- Inbound stays RCON: the node still has to call into the game for identity, topology,
-- bodies, mirrors and the converter. This file is only the outbound half.

local state = require("__server-connector-mod__.control.state")
local platforms = require("__server-connector-mod__.control.platforms")

local main_force = state.main_force

local MARKER = "SCMOD"

-- The one-container manager listens for server-side events on this port; the game reaches
-- it on the container's loopback because both live in the same network namespace. This
-- needs --enable-lua-udp on the game.
local UDP_PORT = 8999

-- A server-side event pushed to the app. Never for a player: this is the game telling the
-- manager something happened (a platform docked), not a client action.
local function push(kind, payload)
    payload = payload or {}
    payload.kind = kind
    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        return
    end
    pcall(function() helpers.send_udp(UDP_PORT, json) end)
end

-- Every platform's serialized position, for the space server only. `distance` is the
-- fractional position along the connection between `location` and `connection`; `docked`
-- is the platform waiting at a planet rather than in transit.
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

local function emit(kind, payload)
    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        log(string.format("[%s] could not encode outbound %s: %s", state.instance(), kind, tostring(json)))
        return
    end
    log(MARKER .. "|" .. kind .. "|" .. json)
end

-- Positions are pushed every 6 ticks, only by the space server, because only it has the
-- real platforms.
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
-- `progress` is the absolute bar, so a new receiver can resync from it.
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

-- One pass: the same facts the node used to pull, plus the queued events.
local function tick()
    if not state.known() then
        return
    end

    emit("report", state.report())
    emit("platforms", platforms.platforms())

    local events = state.drain()
    if next(events) ~= nil then
        emit("events", events)
    end
end

return {
    emit = emit,
    push = push,
    tick = tick,
    tick_positions = tick_positions,
    tick_research = tick_research,
    positions = positions,
}
