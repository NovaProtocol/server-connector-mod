-- server-connector-mod / control/bus.lua
--
-- The UDP transport, and nothing else.
--
-- This sits at the bottom of the dependency graph on purpose: it needs state and debug, and
-- knows nothing about platforms, requests or events. Both platforms.lua and outbound.lua
-- require it, which is what lets platforms send a push without requiring outbound — the
-- cycle that used to be "solved" by a require inside a function, which Factorio refuses with
-- "Require can't be used outside of control.lua parsing."
--
-- Required as "__server-connector-mod__.control.bus", after state and debug.

local state = require("__server-connector-mod__.control.state")
local debug = require("__server-connector-mod__.control.debug")

-- The one-container app listens here on its loopback; the game is in the same network
-- namespace.
local UDP_PORT = 8999

-- Local-only: a client without Lua UDP fails every push, and the failure is not part of
-- the simulation. Log it at most once a minute rather than at the stream's rate.
local last_udp_failure = -math.huge

-- A boot identity and a sequence number on every push.
--
-- UDP can duplicate and reorder, so the manager keys its stores by where a message came
-- from and what it is. An epoch change means the save restarted: the manager full-resyncs
-- instead of comparing against a sequence from another run.
local function epoch()
    if not storage.origin_epoch then
        storage.origin_epoch = string.format("%s-%d", tostring(state.instance()), game.tick)
    end
    return storage.origin_epoch
end

-- A server-side event pushed to the app. Never for a player: this is the game telling the
-- app something happened, not a client action.
local function push(kind, payload)
    payload = payload or {}
    payload.kind = kind
    payload.origin = payload.origin or payload.instance or state.instance()
    payload.origin_epoch = epoch()
    storage.out_seq = (storage.out_seq or 0) + 1
    payload.seq = storage.out_seq

    debug.push(kind, payload)

    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        return false
    end
    local sent, err = pcall(function() helpers.send_udp(UDP_PORT, json) end)
    if not sent and game.tick - last_udp_failure >= 3600 then
        last_udp_failure = game.tick
        log(string.format("[%s] udp %s failed: %s", state.instance(), kind, tostring(err)))
    end
    return sent
end

return {
    UDP_PORT = UDP_PORT,
    epoch = epoch,
    push = push,
}
