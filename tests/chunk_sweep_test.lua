-- The foreign-chunk sweep: only surfaces this instance does not own, never a chunk with a
-- body in it, bounded per pass.
--
-- Runs under plain Lua with the state module stubbed.
-- `lua tests/chunk_sweep_test.lua` from the mod root.

package.preload["__server-connector-mod__.control.state"] = function()
    return {
        instance = function() return INSTANCE end,
        known = function() return KNOWN end,
        owned_surfaces = function() return {vulcanus = true} end,
    }
end

INSTANCE = "vulcanus"
KNOWN = true

storage = {}
local LOG = {}
log = function(message) LOG[#LOG + 1] = tostring(message) end
local deleted = {}

local function make_surface(name, chunk_list, characters)
    return {
        name = name,
        valid = true,
        platform = nil,
        get_chunks = function()
            local index = 0
            return function()
                index = index + 1
                return chunk_list[index]
            end
        end,
        -- Factorio API methods are dot-called: the filter / position is the first argument.
        find_entities_filtered = function(_filter)
            return characters or {}
        end,
        delete_chunk = function(position)
            deleted[#deleted + 1] = string.format("%s:%d,%d", name, position.x, position.y)
        end,
    }
end

local owned_chunks = {}
for x = 0, 9 do
    owned_chunks[#owned_chunks + 1] = {x = x, y = 0}
end
local foreign_chunks = {}
for x = 0, 99 do
    foreign_chunks[#foreign_chunks + 1] = {x = x, y = 0}
end

local body = {valid = true, position = {x = 1, y = 1}}

game = {
    surfaces = {
        vulcanus = make_surface("vulcanus", owned_chunks, {}),
        nauvis = make_surface("nauvis", foreign_chunks, {body}),
    },
}

local chunks = dofile("control/chunks.lua")

-- an unowned surface is foreign, an owned one is not
assert(chunks.foreign(game.surfaces.nauvis) == true, "nauvis should be foreign here")
assert(chunks.foreign(game.surfaces.vulcanus) == false, "the owned surface is not foreign")

local removed = chunks.sweep()

-- the chunk holding the body is chunk 0,0; the rest of this pass is capped
assert(#deleted > 0, "the sweep deleted nothing")
assert(#deleted <= 64, "the sweep exceeded its per-surface batch: " .. #deleted)
assert(deleted[1] ~= "nauvis:0,0", "the chunk with a body in it was deleted")
for _, key in ipairs(deleted) do
    assert(key:sub(1, 7) == "nauvis:", "the sweep touched an owned surface: " .. key)
end
assert(removed == #deleted, "the reported count should match the deletions")
assert(storage.foreign_swept == removed, "the running counter was not updated")

-- unknown identity: nothing happens
KNOWN = false
local before = #deleted
assert(chunks.sweep() == 0, "an unknown instance must not sweep")
assert(#deleted == before, "an unknown instance deleted a chunk")

-- the space instance treats every non-platform surface as foreign
KNOWN = true
INSTANCE = "space"
deleted = {}
assert(chunks.foreign(game.surfaces.vulcanus) == true, "space owns platforms, not planets")

for _, message in ipairs(LOG) do
    assert(not message:find("failed"), "a call was swallowed: " .. message)
end

print("chunk sweep: foreign surfaces only, bodies protected, bounded")
