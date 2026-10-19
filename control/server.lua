-- server-connector-mod / control/server.lua
--
-- What this server does with a player who is connected to it: which controller they get, where
-- their body belongs, and where they are put back when they are standing somewhere they do not.
--
-- Spectator by default, and by design. A joining player is a `ghost` -- the game's own
-- waiting-to-respawn view -- until something says a body of theirs is here. The manager says it
-- (`set_body_location`), and this save can also settle it by itself: a character in this world
-- *is* a body this server holds, and no inference is needed to see it.
--
-- The three controllers, and why each one:
--
--   ghost      by default. Observe only: no interact, no inventory, and not the god mode a
--              bodyless physical controller would otherwise be.
--   character  their body is here: play normally, with the character attached.
--   remote     their body is another server's: "can't move/change items but can build ghosts and
--              change settings". This is the fleet's ghost-only, for looking at another planet.
--
-- The remote controller is an *overlay* on a physical one, so leaving it returns the player to
-- that -- and a bodyless player's physical controller is god mode. `toggle_menu_leaves_remote_view
-- = false` is therefore load-bearing, not a nicety.
--
-- Required as "__server-connector-mod__.control.server".

local state = require("__server-connector-mod__.control.state")

local instance = state.instance
local known = state.known

--------------------------------------------------------------------------------
-- the surface a body belongs on
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
-- the join rule
--------------------------------------------------------------------------------

-- Whether the manager has said this player's body is on another server.
local function body_is_elsewhere(player)
    return storage.body[player.name] ~= nil
end

-- The waiting-to-respawn controller: observe, touch nothing. Not every build accepts it from
-- set_controller, so a refusal falls back to the remote one, which is the closest thing that
-- exists everywhere: no items, no movement, ghosts only.
local function as_observer(player)
    local ok = pcall(function()
        player.set_controller{type = defines.controllers.ghost}
    end)
    if ok then
        return
    end

    local fell_back = pcall(function()
        player.set_controller{
            type = defines.controllers.remote,
            surface = game.surfaces[instance()] or player.physical_surface,
            position = player.physical_position,
        }
    end)
    if not fell_back then
        log(string.format("[%s] could not put %s in the observer controller", instance(), player.name))
    end
end

-- What a player gets when they arrive, and whenever the manager says where their body is.
--
-- The order matters: another server's body wins over anything this world holds, because a
-- character here would be a phantom the game made when they joined.
local function apply_join_rule(player)
    if not known() then
        return
    end

    if body_is_elsewhere(player) then
        -- Every joining player is handed a character by the game. On a server that is not
        -- their body's home that character is a second body with an inventory, so it is
        -- removed rather than left standing around.
        if player.character and player.character.valid then
            local items = "unknown"
            pcall(function()
                local inv = player.character.get_inventory(defines.inventory.character_main)
                items = inv and inv.get_item_count() or 0
            end)
            log(string.format("[%s] destroying %s's character here (main inventory items: %s)",
                instance(), player.name, tostring(items)))
            player.character.destroy()
        end

        storage.viewing[player.name] = true
        player.set_controller{
            type = defines.controllers.remote,
            surface = game.surfaces[instance()] or player.physical_surface,
            position = player.physical_position,
        }
        player.toggle_menu_leaves_remote_view = false
        player.disable_space_map = true
        return
    end

    storage.viewing[player.name] = nil
    player.toggle_menu_leaves_remote_view = true
    player.disable_space_map = false

    if player.character and player.character.valid then
        -- Their body is here. Put the controller back on it: a player who was a viewer a
        -- moment ago is still in the remote one, and the character would sit unattended.
        --
        -- The character this save holds can be on a different surface from the one the player
        -- joined on: the fleet's saves are copies, and a body that moved last session is not
        -- necessarily where the client came back to. set_controller refuses an entity from
        -- another surface, and that error quits the server, so the body is put where it
        -- belongs first and the controller is only attached once the two surfaces agree.
        if player.character.surface ~= player.physical_surface then
            enforce_surface(player)
        end
        if player.controller_type ~= defines.controllers.character
            and player.character and player.character.valid
            and player.character.surface == player.physical_surface then
            player.set_controller{
                type = defines.controllers.character,
                character = player.character,
            }
        end
        return
    end

    -- Nothing has said where their body is, and this world holds no character for them: leave
    -- them observing.
    player.toggle_menu_leaves_remote_view = false
    as_observer(player)
end

--------------------------------------------------------------------------------
-- the manager's push
--------------------------------------------------------------------------------

-- Where a player's body is. The manager owns this fact; the mod only obeys it.
--
-- A player already in the world is converted now rather than at their next join: a body that
-- moved while they were connected -- they boarded a rocket, another server reported where they
-- really are -- has to change what they can do, not only what they get next time.
local function set_body_location(name, id)
    state.ensure_storage()
    state.set_body(name, id)

    local player = game.get_player(name)
    local destroyed = false
    if player and player.connected then
        destroyed = storage.body[name] ~= nil and player.character ~= nil and player.character.valid
        apply_join_rule(player)
    end

    local out = {name = name, body = storage.body[name] or instance()}
    if destroyed then
        out.destroyed_character = true
    end
    return out
end

return {
    owned_surface = owned_surface,
    enforce_surface = enforce_surface,
    apply_join_rule = apply_join_rule,
    set_body_location = set_body_location,
}
