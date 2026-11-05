-- server-connector-mod / control/players.lua
--
-- Read-only player detail for the manager's runtime page: where the player is, whether this
-- world owns their body, and what their main inventory holds. It never moves a player, changes
-- a body or edits an inventory.

local state = require("__server-connector-mod__.control.state")

local function contents(inventory)
    local out = {}
    if not inventory then
        return out
    end
    for index = 1, #inventory do
        local stack = inventory[index]
        if stack and stack.valid_for_read and stack.count > 0 then
            out[#out + 1] = {
                item = stack.name,
                quality = stack.quality and stack.quality.name or "normal",
                count = stack.count,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.item ~= b.item then
            return a.item < b.item
        end
        return a.quality < b.quality
    end)
    return out
end

local function inventory_of(player, names)
    for _, name in ipairs(names) do
        local ok, inventory = pcall(function()
            return player.get_inventory(defines.inventory[name])
        end)
        if ok and inventory then
            return contents(inventory)
        end
    end
    return {}
end

local function detail(name)
    local player = game.get_player(name)
    if not player then
        return {ok = false, error = "no such player"}
    end

    return {
        ok = true,
        instance = state.instance(),
        player = player.name,
        online = player.connected == true,
        has_body = player.character ~= nil,
        surface = player.surface and player.surface.name or nil,
        server = state.instance(),
        inventory = inventory_of(player, {"character_main", "main"}),
        armor = inventory_of(player, {"character_armor", "armor"}),
    }
end

return {
    detail = detail,
}
