-- The join rule: a planet moves the body, the space server is a viewer.
--
-- Runs under plain Lua: the Factorio `require` is stubbed, and only the pieces the rule
-- touches are faked. `lua tests/join_rule_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
        instance = function() return INSTANCE end,
        known = function() return true end,
        empty = function() return EMPTY end,
        owned_surfaces = function() return {vulcanus = true} end,
        primary_surface = function() return SURFACES.vulcanus end,
        ensure_storage = function() end,
        set_body = function() end,
    }
end

INSTANCE = "space"
EMPTY = false

defines = {controllers = {ghost = "ghost", character = "character", remote = "remote"}}
storage = {}
local LOG = {}
log = function(message) LOG[#LOG + 1] = tostring(message) end

local pieces = {teleported = 0, destroyed = 0, controllers = {}}

local function surface(name)
    return {
        name = name,
        valid = true,
        find_non_colliding_position = function() return {x = 0, y = 0} end,
    }
end

SURFACES = {vulcanus = surface("vulcanus"), nauvis = surface("nauvis")}

-- Declared first, then filled: a local is not in scope inside its own initializer, so the
-- methods below would otherwise write to a nil global.
local character
character = {
    valid = true,
    unit_number = 77,
    surface = SURFACES.nauvis,
    position = {x = 10, y = 10},
    -- Factorio API methods are dot-called: no implicit self.
    teleport = function(position, target)
        pieces.teleported = pieces.teleported + 1
        character.surface = target
        character.position = position
    end,
    destroy = function() pieces.destroyed = pieces.destroyed + 1 end,
}

local player = {
    name = "ProjectAlpha",
    valid = true,
    character = character,
    physical_surface = SURFACES.nauvis,
    physical_position = {x = 10, y = 10},
    toggle_menu_leaves_remote_view = true,
    set_controller = function(spec) pieces.controllers[#pieces.controllers + 1] = spec.type end,
}

game = {
    surfaces = SURFACES,
    connected_players = {player},
    get_entity_by_unit_number = function(unit)
        if unit == 77 and pieces.destroyed == 0 then
            return character
        end
        return nil
    end,
}

local server = dofile("control/server.lua")

-- space: remote controller, viewing recorded, body queued, nothing destroyed yet
server.apply_join_rule(player)

assert(pieces.controllers[1] == "remote", "space join should use the remote controller")
assert(storage.viewing and storage.viewing[player.name] == true, "space join should be marked viewing")
assert(storage.destroy_characters and storage.destroy_characters[player.name] == 77,
    "space join should queue the body for removal")
assert(pieces.destroyed == 0, "the body must not be destroyed while the player is connected")

-- the queue only runs when nobody is connected
EMPTY = false
assert(server.destroy_queued() == 0, "the queue must not drain while somebody is connected")
assert(pieces.destroyed == 0, "the body was destroyed with a player connected")

EMPTY = true
assert(server.destroy_queued() == 1, "the queue should drain when empty")
assert(pieces.destroyed == 1, "the queued body should be destroyed")
assert(storage.destroy_characters[player.name] == nil, "the queue entry should be gone")

-- planet: the body is moved onto the server's surface, no controller change
INSTANCE = "vulcanus"
player.character = character
character.valid = true
character.surface = SURFACES.nauvis
storage.viewing[player.name] = true

server.apply_join_rule(player)

assert(pieces.teleported == 1, "a planet join should move the body once")
assert(character.surface == SURFACES.vulcanus, "the body should be on the server's surface")
assert(storage.viewing[player.name] == nil, "a planet join should clear the viewing flag")
assert(pieces.controllers[1] == "remote", "a planet join must not change the controller")

-- The module logs a refused write instead of raising, so a swallowed fault is invisible
-- unless the test looks for it.
for _, message in ipairs(LOG) do
    assert(not message:find("failed"), "a call was swallowed: " .. message)
end

print("join rule: space is a viewer, planets hold the body")
