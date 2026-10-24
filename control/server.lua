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
local owned_surfaces = state.owned_surfaces
local primary_surface = state.primary_surface

-- A write to the game's own API, said out loud when it refuses.
--
-- Every one of these can throw: an entity that went invalid between two lines, a controller a
-- build does not accept, a surface that changed underneath. From an event handler that error
-- is non-recoverable, so a refused write is its own log line and the rule carries on.
local function attempt(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        log(string.format("[%s] %s failed: %s", instance(), what, tostring(err)))
    end
    return ok
end

--------------------------------------------------------------------------------
-- the surface a body belongs on
--------------------------------------------------------------------------------

-- The surface a player on this server belongs on.
--
-- A planet server owns its planet, and that is the whole answer. The space server owns no
-- planet: what its players belong on is a platform, which is built rather than named, so
-- where their body was the last time it was somewhere it should be is remembered instead.
local function owned_surface(player)
    if instance() == "space" then
        local remembered = storage.anchored[player.name]
        local surface = remembered and game.surfaces[remembered]
        if surface and surface.platform then
            return surface
        end
        return nil
    end

    -- A custom instance may own several surfaces. The one the player is standing on is home
    -- while they are on it; otherwise the declared primary is.
    local physical = player and player.physical_surface
    if physical and owned_surfaces()[physical.name] then
        return physical
    end
    return primary_surface()
end

-- Put a player who is standing somewhere they do not belong back where they do.
--
-- Journeys are the map's buttons now. This is what is left: a player standing on a surface
-- this instance does not own -- there are none of another server's surfaces here any more, so
-- this is a surface a script left behind, or a platform copy on a planet server -- is put back
-- on one this instance does own.
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

    -- Standing on any surface this instance owns is home; only a surface it does not own is
    -- somewhere to be moved from.
    if instance() ~= "space" and owned_surfaces()[physical.name] then
        return
    end

    local home = owned_surface(player)
    if not home or physical == home then
        return
    end

    local position = player.physical_position or {x = 0, y = 0}
    local found, spot = pcall(function()
        return home.find_non_colliding_position("character", position, 64, 1)
            or home.find_non_colliding_position("character", {x = 0, y = 0}, 64, 1)
            or position
    end)
    if not found or spot == nil then
        spot = position
    end

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

-- The surface a player's body belongs on. A player the manager has never spoken for is
-- parked on nauvis: give them that body rather than leaving them with nowhere to stand.
local function body_home(player)
    if storage.body_known and storage.body_known[player.name] then
        -- nil is a home on this very server; a known entry must not fall through to the
        -- fleet default, or a body that lives on this server reads as living on nauvis.
        return storage.body[player.name] or instance()
    end
    return "nauvis"
end

-- Whether this player's body is on another server.
local function body_is_elsewhere(player)
    return body_home(player) ~= instance()
end

-- Whether this surface is one this instance owns. A planet or custom instance owns the
-- surfaces the manager declared; the space server owns platforms, wherever they are.
local function surface_is_home(surface)
    if not surface then
        return false
    end
    if instance() == "space" then
        return surface.platform ~= nil
    end
    return owned_surfaces()[surface.name] == true
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

-- The remote controller: everything in reach, nothing owned. This is what a player with no
-- body here uses. If even that is refused, fall back to the observer rather than leave them
-- on a controller whose character is somewhere else.
local function put_remote(player)
    local ok = attempt("putting " .. player.name .. " in the remote controller", function()
        player.set_controller{
            type = defines.controllers.remote,
            surface = game.surfaces[instance()] or player.physical_surface,
            position = player.physical_position,
        }
    end)
    player.toggle_menu_leaves_remote_view = false
    if not ok then
        as_observer(player)
    end
end

-- What a player gets when they arrive, and whenever the manager says where their body is.
--
-- The only thing this mod does to a joining player is move their body onto the surface this
-- server exists to hold. It does not touch the controller, the character, the editor, the
-- remote or the inventory: the client already owns all of that, and every change to it here
-- was a world change the client did not make.
local function apply_join_rule(player)
    if not known() then
        return
    end

    local character = player.character
    if not character or not character.valid then
        return
    end

    local surface = game.surfaces[instance()] or player.physical_surface
    if not surface then
        return
    end

    if character.surface ~= surface then
        log(string.format("[%s] join: moving %s from %s to %s",
            instance(), player.name,
            character.surface and character.surface.name or "nil", surface.name))
        attempt("moving " .. player.name .. " to " .. surface.name, function()
            character.teleport(player.physical_position, surface)
        end)
    end
end

--------------------------------------------------------------------------------
-- the manager's push
--------------------------------------------------------------------------------

-- Where a player's body is. The manager owns this fact; the mod only obeys it.
--
-- Only the fact is stored. This arrives over RCON, and a controller or character change made
-- that way is a server-side world change the client never sees -- applying it to a player who
-- is connected is how a join desyncs. The stored body is applied by the join rule the next
-- time they join.
local function set_body_location(name, id)
    state.ensure_storage()
    state.set_body(name, id)

    return {name = name, body = storage.body[name] or instance(), stored = true}
end

return {
    owned_surface = owned_surface,
    enforce_surface = enforce_surface,
    apply_join_rule = apply_join_rule,
    set_body_location = set_body_location,
}
