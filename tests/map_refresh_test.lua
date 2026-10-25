-- Reproduces the client-side GUI rebuild. A joining client reloads the mod's Lua state
-- (and therefore any module table) but keeps the player's GUI and the save's storage.
-- The old map.lua kept its rebuild signature in a module table, so the first refresh after
-- the reload rebuilt the frame while the server did not: two extra builds over a hop.
package.preload["__server-connector-mod__.control.state"] = function()
    return {
        known = function() return true end,
        instance = function() return "vulcanus" end,
        destinations = function()
            return {
                {id = "aquilo", name = "Aquilo", address = "127.0.0.1:34204"},
                {id = "vulcanus", name = "Vulcanus", address = "127.0.0.1:34201"},
            }
        end,
    }
end

storage = {}
defines = {
    controllers = {remote = "remote"},
    render_mode = {chart = "chart", game = "game"},
}

local created = 0

local function element(definition)
    local node = {
        type = definition.type,
        name = definition.name,
        tags = definition.tags,
        visible = true,
        children = {},
    }
    function node.add(child)
        local made = element(child)
        node.children[#node.children + 1] = made
        return made
    end
    function node.destroy()
        if node.name and storage.screen then
            storage.screen[node.name] = nil
        end
    end
    return node
end

local screen = {}
function screen.add(definition)
    created = created + 1
    local made = element(definition)
    if definition.name then
        screen[definition.name] = made
    end
    return made
end

local player = {
    valid = true,
    index = 1,
    name = "ProjectAlpha",
    controller_type = "character",
    render_mode = "game",
    gui = {screen = screen},
}

local map = dofile("control/map.lua")
map.refresh(player)

assert(created == 1, "expected one GUI build, got " .. created)
assert(screen["server-connector-map"], "the map frame was not built")
assert(screen["server-connector-map"].visible, "the map frame was built but hidden")
assert(storage.map_seen and storage.map_seen[player.name], "the build signature was not stored")

-- A client joining again gets a fresh Lua state, but the saved storage and the GUI frame
-- are still there. It must not rebuild the frame.
map = dofile("control/map.lua")
map.refresh(player)

assert(created == 1, "the GUI was rebuilt after a client reload: " .. created)
print("map refresh is idempotent across a client reload")
