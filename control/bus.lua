-- server-connector-mod / control/bus.lua
--
-- The UDP transport, and nothing else. The actual send/receive, chunking and RPC
-- implementation lives in the generic __udp-net__ library; this file supplies the
-- connector's identity and the event envelope its existing consumers expect.
--
-- Required after state and debug, before anything that pushes.

local state = require("__server-connector-mod__.control.state")
local debug = require("__server-connector-mod__.control.debug")
local net = require("__udp-net__.lib")

-- The one-container app listens here on loopback; the game is in the same network
-- namespace.
local UDP_PORT = 8999

net.install({
    port = UDP_PORT,
    identity = function()
        return state.instance()
    end,
})

local function epoch()
    return net.epoch()
end

-- A server-side event pushed to the app. Never for a player: this is the game telling
-- the app something happened, not a client action.
local function push(kind, payload)
    payload = payload or {}
    debug.push(kind, payload)
    return net.emit(kind, payload)
end

return {
    UDP_PORT = UDP_PORT,
    epoch = epoch,
    push = push,
    is_server = net.is_server,
    mark_server = net.mark_server,
    reset_epoch = net.reset_epoch,
}
