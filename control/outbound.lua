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

local MARKER = "SCMOD"

local function emit(kind, payload)
    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        log(string.format("[%s] could not encode outbound %s: %s", state.instance(), kind, tostring(json)))
        return
    end
    log(MARKER .. "|" .. kind .. "|" .. json)
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
    tick = tick,
}
