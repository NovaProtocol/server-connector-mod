-- server-connector-mod / control/research.lua
--
-- The tech tree is one tree in Space Age, but this stack runs one save per planet, so
-- every server has its own copy of it and they drift apart immediately. The manager owns
-- the shared state; this module reports what this server has and applies what it is told,
-- which is the same split as everything else here.
--
-- Required as "__server-connector-mod__.control.research".

local state = require("__server-connector-mod__.control.state")
local outbound = require("__server-connector-mod__.control.outbound")

local instance = state.instance
local main_force = state.main_force

-- A research event, for the manager: which research, and when the game says it happened.
local function note_research(kind, name)
    if not name then
        return
    end
    state.record_event({
        kind = kind,
        tech = name,
        tick = game.tick,
    })

    -- Queue and selection changes go over UDP at once: the manager has to put the same
    -- research (and queue) on every planet, not wait for its next poll.
    outbound.push("research_event", {
        instance = instance(),
        tick = game.tick,
        event = kind,
        tech = name,
        queue = (function()
            local out = {}
            for _, queued in pairs(main_force().research_queue or {}) do
                out[#out + 1] = queued.name
            end
            return out
        end)(),
    })
end

-- Which research this server is on, right now.
--
-- Read from the force rather than from the event: a technology can be cancelled, reversed
-- or replaced, and the event's own name is then the one that *was* being researched. What
-- the manager needs is what this server is on afterwards.
local function current_name()
    local research = main_force().current_research
    return research and research.name or nil
end

-- What this server's tech tree looks like, a page at a time.
--
-- The whole tree does not fit in one RCON frame once enough of it is
-- researched, and it only grows as the save progresses. The companion mod this
-- stack replaced had to chunk its reports at 4096 bytes for the same reason, so
-- this asks for a slice and the node assembles the pages.
--
-- Paging is safe without a snapshot because the manager unions what it reads on
-- every poll: a technology that shifts across a page boundary and is missed once
-- is picked up on the next pass.
local function research_state(payload)
    state.ensure_storage()
    payload = payload or {}

    local force = main_force()
    local all = {}
    for name, technology in pairs(force.technologies) do
        if technology.researched then
            all[#all + 1] = name
        end
    end
    table.sort(all)

    local total = #all
    local offset = tonumber(payload.offset) or 0
    local limit = tonumber(payload.limit) or 64
    if offset < 0 then offset = 0 end
    if limit < 1 then limit = 1 end

    local items = {}
    local count = 0
    for index = offset + 1, math.min(offset + limit, total) do
        items[#items + 1] = all[index]
        count = count + 1
    end

    return {
        instance = instance(),
        items = items,
        count = count,
        total = total,
        current = force.current_research and force.current_research.name or nil,
        -- An infinite research keeps its name as it levels, and its bar restarts each
        -- time. Without the level, one level's progress is indistinguishable from the
        -- next and the manager cannot tell a level-up from a bar going backwards.
        level = force.current_research and force.current_research.level or 0,
        progress = force.research_progress,
        tick = game.tick,
    }
end

-- Apply the shared research: technologies to mark done, and where the research
-- in progress stands. The manager sends this, because no server can know what
-- the others have researched.
local function apply_research(payload)
    state.ensure_storage()
    payload = payload or {}

    local force = main_force()
    local applied = 0

    for _, name in ipairs(payload.researched or {}) do
        local technology = force.technologies[name]
        if technology and not technology.researched then
            -- A technology the game is currently researching cannot be marked done
            -- directly: the assignment is dropped and the research keeps running, so
            -- a fleet could never finish anything it had started. Cancelling the
            -- research first is the supported way to abandon it, and the technology
            -- takes the flag once nothing is running.
            if force.current_research == technology then
                pcall(function() force.cancel_current_research() end)
            end

            technology.researched = true

            -- Counted only when it took. Reporting a change the game refused is how
            -- the manager comes to believe a server has something it does not.
            if technology.researched then
                applied = applied + 1
            end
        end
    end

    if payload.current then
        local technology = force.technologies[payload.current]
        if technology and not technology.researched then
            -- current_research is read only in 2.1 ("is read only" is the error an
            -- assignment gets), so a research is started through add_research.
            --
            -- add_research puts a technology at the *back of the queue*, so with
            -- something already running it is only queued behind it and never becomes
            -- the current research: a planet could never be moved onto the fleet's
            -- research, and would sit on its own while the manager reported the
            -- shared bar. Cancelling first is what makes the switch take, and a
            -- technology the game refuses (its prerequisites unmet) is skipped
            -- rather than failing the whole sync.
            if force.current_research ~= technology then
                pcall(function() force.cancel_current_research() end)
                pcall(function() force.add_research(technology) end)
            end

            local progress = tonumber(payload.progress)
            if progress then
                force.research_progress = math.max(0, math.min(1, progress))
            end

            applied = applied + 1
        end
    end

    return {instance = instance(), applied = applied}
end

-- Unlock the whole tree on this force.
--
-- A sandbox asks for this instead of the fleet's tree: it wants everything available, and it
-- is never a source, so nothing it unlocks travels back to the planets.
local function research_all()
    if not state.known() then
        return {skipped = "no identity"}
    end

    local force = main_force()
    local ok, err = pcall(function() force.research_all_technologies() end)
    if not ok then
        return {instance = instance(), error = tostring(err)}
    end

    return {instance = instance(), all = true}
end

return {
    note_research = note_research,
    current_name = current_name,
    research_state = research_state,
    apply_research = apply_research,
    research_all = research_all,
}
