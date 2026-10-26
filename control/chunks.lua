-- server-connector-mod / control/chunks.lua
--
-- Chunks on a surface this server is not supposed to have.
--
-- A join can leave one behind. The game creates the joining body at the force's spawn before
-- the join rule moves it, and the map generator fills the ground around it; if the spawn still
-- points at a planet this server does not own, that is a chunk here that belongs to nobody.
--
-- Nauvis cannot be deleted -- the API refuses the primary surface -- so this cannot be a
-- surface deletion. Deleting the chunks in the join handler is the change the changelog
-- records as a join-tick desync (0.33.5), so the sweep runs on the one-minute pass instead,
-- where both peers execute the same code from the same state.
--
-- A chunk with a body in it is never deleted, connected or not: that body is either the player
-- who just joined or a copy this save carries from another server. Everything else on a
-- foreign surface goes, map generation included, which is the point.
--
-- Required as "__server-connector-mod__.control.chunks".

local state = require("__server-connector-mod__.control.state")

local CHUNK = 32
local EXAMINE = 512 -- chunks looked at per surface per pass
local REMOVE = 64   -- chunks deleted per surface per pass

-- A surface this instance is not supposed to have.
--
-- A planet or custom instance owns the surfaces the manager named; the space instance owns
-- its platforms. Everything else -- nauvis on a non-nauvis server, a leftover planet on the
-- space server -- is foreign.
local function foreign(surface)
    if not surface or not surface.valid or surface.platform then
        return false
    end
    if state.instance() == "space" then
        return true
    end
    return state.owned_surfaces()[surface.name] ~= true
end

-- The chunks holding a body, as a set of "x,y" keys.
--
-- One query for the whole surface rather than one per chunk: a surface can carry thousands of
-- chunks and a character search per chunk would cost more than the deletion it guards.
local function bodies(surface)
    local blocked = {}
    local ok, characters = pcall(function()
        return surface.find_entities_filtered{type = "character"}
    end)
    if not ok or type(characters) ~= "table" then
        return blocked
    end
    for _, character in ipairs(characters) do
        local position = character.position
        if position then
            blocked[math.floor(position.x / CHUNK) .. "," .. math.floor(position.y / CHUNK)] = true
        end
    end
    return blocked
end

-- The generated chunks on a surface, up to the per-pass cap.
--
-- Collected first: deleting while iterating get_chunks() would mutate the thing being walked.
local function collected(surface)
    local positions = {}
    local ok = pcall(function()
        for chunk in surface.get_chunks() do
            if type(chunk.x) == "number" and type(chunk.y) == "number" then
                positions[#positions + 1] = {x = chunk.x, y = chunk.y}
                if #positions >= EXAMINE then
                    break
                end
            end
        end
    end)
    if not ok then
        return nil
    end
    return positions
end

local function sweep_surface(surface)
    local blocked = bodies(surface)
    local positions = collected(surface)
    if not positions then
        return 0
    end

    local removed = 0
    for _, position in ipairs(positions) do
        if removed >= REMOVE then
            break
        end
        if not blocked[position.x .. "," .. position.y] then
            local ok = pcall(function()
                surface.delete_chunk(position)
            end)
            if ok then
                removed = removed + 1
            end
        end
    end
    return removed
end

-- One pass over every foreign surface. Returns how many chunks this pass removed.
local function sweep()
    if not state.known() then
        return 0
    end

    local removed = 0
    for _, surface in pairs(game.surfaces) do
        if foreign(surface) then
            removed = removed + sweep_surface(surface)
        end
    end

    storage.foreign_swept = (storage.foreign_swept or 0) + removed
    storage.foreign_last = removed
    if removed > 0 then
        log(string.format("[%s] removed %d chunk(s) from surfaces this server does not own",
            state.instance(), removed))
    end
    return removed
end

return {
    sweep = sweep,
    foreign = foreign,
}
