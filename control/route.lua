-- server-connector-mod / control/route.lua
--
-- Whose surface a player looks at, where that surface's server is, and the hand-over that
-- follows. The trigger is the game's own remote view: opening it onto another planet and
-- clicking changes the surface the player is *viewing*, which fires on_player_changed_surface
-- even though the body never moved.
--
-- What a player's body is and where it belongs is control/server.lua.
--
-- Required as "__server-connector-mod__.control.route".

local state = require("__server-connector-mod__.control.state")

local known = state.known
local instance = state.instance
local note = state.note
local destination_for = state.destination_for

--------------------------------------------------------------------------------
-- the trigger
--------------------------------------------------------------------------------

-- Fires after the player changes surfaces, including a change of what they are
-- viewing in remote view. If they have looked at a surface another server owns,
-- this is the moment to hand them over.
--
-- The address is the one a *client* dials. Pointing a player at an RCON port
-- produces a prompt that reads correctly and a client that sits at "connecting"
-- until it gives up, with nothing logged anywhere.
local function route_if_elsewhere(player)
    if not known() then
        return
    end
    local viewed = player.surface
    note("surface", player, viewed and viewed.name or nil)

    local target = destination_for(viewed)

    if not target then
        storage.routed[player.name] = nil
        return false
    end

    -- Already looking at where we would send them: nothing to do, and this is
    -- what stops the handler from bouncing a player every time it fires.
    if storage.routed[player.name] == target then
        -- Already handed over and still on their way. Nothing else is done for them: a
        -- teleport now would fight the connection that is being made.
        return true
    end

    local entry = storage.topology[target]
    if not entry or not entry.address then
        return false
    end
    storage.routed[player.name] = target

    log(string.format("[%s] %s looked at %s, sending them to %s",
        instance(), player.name, viewed.name, entry.name or target))

    local sent, err = pcall(function()
        player.connect_to_server{address = entry.address, name = entry.name or target}
    end)
    if not sent then
        -- Not recorded as handed over: the next surface change tries again rather than
        -- leaving them on a world they are not supposed to be on, with nothing said.
        storage.routed[player.name] = nil
        log(string.format("[%s] could not send %s to %s: %s",
            instance(), player.name, target, tostring(err)))
        return false
    end

    return true
end

--------------------------------------------------------------------------------
-- the decision, without a player to make it
--------------------------------------------------------------------------------

-- Where a player looking at a surface would be sent, without a player to send.
--
-- The decision is the one the controller handler makes, and this is how it can be
-- checked from outside: whether a platform goes to the space server, whether a planet
-- goes to itself, and whether looking at home is not a journey at all.
local function route_for(surface)
    local id = destination_for(game.surfaces[surface])

    return {
        instance = instance(),
        surface = surface,
        target = id,
        address = id and (storage.topology[id] or {}).address or nil,
    }
end

return {
    route_if_elsewhere = route_if_elsewhere,
    route_for = route_for,
}
