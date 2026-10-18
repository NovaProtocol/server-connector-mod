-- server-connector-mod / control/route.lua
--
-- Whose surface a player looks at, where that surface's server is, and which surface a
-- player's body belongs on. The trigger is the game's own remote view: opening it onto
-- another planet and clicking changes the surface the player is *viewing*, which fires
-- on_player_changed_surface even though the body never moved.
--
-- Required as "__server-connector-mod__.control.route".

local state = require("__server-connector-mod__.control.state")

local known = state.known
local instance = state.instance
local note = state.note
local destination_for = state.destination_for

--------------------------------------------------------------------------------
-- nobody stands on a surface this server does not own
--------------------------------------------------------------------------------

-- The surface a player on this server belongs on.
--
-- A planet server owns its planet, and that is the whole answer. The space server owns no
-- planet: what its players belong on is a platform, which is built rather than named, so
-- where their body was the last time it was somewhere it should be is remembered instead.
local function owned_surface(player)
    if instance() ~= "space" then
        return game.surfaces[instance()]
    end

    local remembered = storage.anchored[player.name]
    local surface = remembered and game.surfaces[remembered]
    if surface and surface.platform then
        return surface
    end

    return nil
end

-- Put a player who is standing somewhere they do not belong back where they do.
--
-- Sending them to another server comes first, in route_if_elsewhere: looking at a planet
-- another server owns is a journey, and the game's own connect_to_server takes them. This
-- is what is left when no journey applies -- the player is standing *on* a surface this
-- server does not own, and there is nowhere to send them, because every other server's
-- planet exists here as an empty duplicate nobody should be standing on at all.
local function enforce_surface(player)
    if not known() then
        return
    end
    -- A remote viewer is looking at this server from wherever they really are. Their body
    -- is not here and moving them would be moving somebody else's character.
    if storage.viewing[player.name] then
        return
    end

    local physical = player.physical_surface
    if not physical then
        return
    end

    -- A platform is a space server's home ground, so remember it while they are on one.
    if physical.platform then
        storage.anchored[player.name] = physical.name
        if instance() == "space" then
            return
        end
    end

    local home = owned_surface(player)
    if not home or physical == home then
        return
    end

    local position = player.physical_position or {x = 0, y = 0}
    local spot = home.find_non_colliding_position("character", position, 64, 1)
        or home.find_non_colliding_position("character", {x = 0, y = 0}, 64, 1)
        or position

    log(string.format("[%s] %s was standing on %s, putting them back on %s",
        instance(), player.name, physical.name, home.name))

    local ok, err = pcall(function() player.teleport(spot, home) end)
    if not ok then
        log(string.format("[%s] could not move %s: %s", instance(), player.name, tostring(err)))
    end
end

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
    storage.routed[player.name] = target

    log(string.format("[%s] %s looked at %s, sending them to %s",
        instance(), player.name, viewed.name, entry.name or target))

    player.connect_to_server{address = entry.address, name = entry.name or target}
    return true
end

--------------------------------------------------------------------------------
-- the join rule
--------------------------------------------------------------------------------

-- The body exists on exactly one server. On every other one the player is a
-- remote viewer: the game's own remote controller, which already cannot move,
-- cannot take or change items, and still lets blueprints place as ghosts.
--
-- The remote controller is an *overlay* on a physical one, so leaving it returns
-- the player to that -- and a bodyless player's physical controller is god mode.
-- toggle_menu_leaves_remote_view = false is therefore load-bearing, not a nicety.
local function apply_join_rule(player)
    if not known() then
        return
    end
    local here = storage.body[player.name]
    if not here or here == instance() then
        storage.viewing[player.name] = nil
        player.toggle_menu_leaves_remote_view = true
        player.disable_space_map = false
        return
    end

    storage.viewing[player.name] = true
    player.set_controller{
        type = defines.controllers.remote,
        surface = game.surfaces[instance()] or player.physical_surface,
        position = player.physical_position,
    }
    player.toggle_menu_leaves_remote_view = false
    player.disable_space_map = true
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
    local id = destination_for(game.surfaces[surface] or (game.surfaces[1] and nil))

    return {
        instance = instance(),
        surface = surface,
        target = id,
        address = id and (storage.topology[id] or {}).address or nil,
    }
end

return {
    owned_surface = owned_surface,
    enforce_surface = enforce_surface,
    route_if_elsewhere = route_if_elsewhere,
    apply_join_rule = apply_join_rule,
    route_for = route_for,
}
