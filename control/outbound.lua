-- server-connector-mod / control/outbound.lua
--
-- Mod -> app, by localhost UDP only.
--
-- There is no stdout/log path any more: the game writes nothing for the app to scrape. The
-- RCON channel stays for calls the app makes into the game; these pushes are the other
-- direction, for events and continuous state the game knows on its own. UDP needs
-- --enable-lua-udp on the game, which the node passes per instance.

local state = require("__server-connector-mod__.control.state")
local platforms = require("__server-connector-mod__.control.platforms")
local platform_api = require("__server-connector-mod__.control.platform_api")

local main_force = state.main_force

-- The one-container app listens here on its loopback; the game is in the same network
-- namespace.
local UDP_PORT = 8999

-- A server-side event pushed to the app. Never for a player: this is the game telling the
-- app something happened, not a client action.
-- A boot identity and a sequence number on every push.
--
-- UDP can duplicate and reorder, so the manager keys its stores by where a message came
-- from and what it is. An epoch change means the save restarted: the manager full-resyncs
-- instead of comparing against a sequence from another run.
local function epoch()
    if not storage.origin_epoch then
        storage.origin_epoch = string.format("%s-%d", tostring(state.instance()), game.tick)
    end
    return storage.origin_epoch
end

local function push(kind, payload)
    payload = payload or {}
    payload.kind = kind
    payload.origin = payload.origin or payload.instance or state.instance()
    payload.origin_epoch = epoch()
    storage.out_seq = (storage.out_seq or 0) + 1
    payload.seq = storage.out_seq

    local ok, json = pcall(helpers.table_to_json, payload)
    if not ok then
        return
    end
    local sent, err = pcall(function() helpers.send_udp(UDP_PORT, json) end)
    if not sent then
        log(string.format("[%s] udp %s failed: %s", state.instance(), kind, tostring(err)))
    end
end

-- Every platform's serialized position. `distance` is the fractional position along the
-- connection; `docked` is waiting at a planet rather than in transit.
local function positions()
    local out = {}
    for _, platform in pairs(main_force().platforms or {}) do
        out[#out + 1] = {
            name = platform.name,
            index = platform.index,
            state = tostring(platform.state),
            location = platform.space_location and platform.space_location.name or nil,
            connection = platform.space_connection and platform.space_connection.name or nil,
            distance = platform.distance,
            paused = platform.paused,
            docked = platform.state == defines.space_platform_state.waiting_for_departure,
        }
    end
    return out
end

-- Positions move continuously in transit, so they go every 6 ticks (10 Hz), from the
-- space server only.
local function tick_positions()
    if not state.known() or state.instance() ~= "space" then
        return
    end
    push("platform_positions", {
        instance = state.instance(),
        tick = game.tick,
        platforms = positions(),
    })
end

-- The cheap platform metadata, from every server: copies included. 10 Hz is enough for a
-- list and a position, and it costs no inventory read.
local function tick_meta()
    if not state.known() then
        return
    end
    local started = os.clock()
    push("platform_meta", {
        instance = state.instance(),
        tick = game.tick,
        platforms = platform_api.meta(),
    })
    local spent = os.clock() - started
    if spent > 0.005 then
        log(string.format("[%s] slow cheap meta: %.1f ms", state.instance(), spent * 1000))
    end
end

-- The full shape once a second: bay count, layout, asteroid/other counts and the request
-- hash. The manager's copy push reads these; it does not need them at 10 Hz.
local function tick_meta_full()
    if not state.known() then
        return
    end
    local started = os.clock()
    push("platform_meta", {
        instance = state.instance(),
        tick = game.tick,
        platforms = platform_api.meta_full(),
    })
    local spent = os.clock() - started
    if spent > 0.01 then
        log(string.format("[%s] slow full meta: %.1f ms", state.instance(), spent * 1000))
    end
end

-- The heavy platform cargo, only when the hash moved and only one page at a time.
--
-- A platform can be built to any size, so this never sends a whole hub in one datagram: the
-- manager reassembles the pages by platform, hash and cursor. A server that is idle sends
-- nothing.
local function tick_hub()
    if not state.known() then
        return
    end
    local started = os.clock()

    storage.hub_sent = storage.hub_sent or {}

    for _, platform in pairs(main_force().platforms or {}) do
        local first = platform_api.dump({index = platform.index, cursor = 0, limit = 60})
        if first and first.ok then
            if storage.hub_sent[platform.index] ~= first.hash then
                local cursor = 0
                local pages = 0
                repeat
                    local page = platform_api.dump({index = platform.index, cursor = cursor, limit = 60})
                    if not page or not page.ok then
                        break
                    end

                    push("platform_hub_dump", {
                        instance = state.instance(),
                        tick = game.tick,
                        platform = page.platform,
                        cursor = page.cursor,
                        next = page.next,
                        total = page.total,
                        done = page.done,
                        hash = page.hash,
                        cargo = page.cargo,
                        requests = page.requests,
                        request_hash = page.request_hash,
                    })

                    pages = pages + 1
                    cursor = page.next
                until page.done or pages > 1000

                storage.hub_sent[platform.index] = first.hash
            end
        end
    end
    local spent = os.clock() - started
    if spent > 0.02 then
        log(string.format("[%s] slow hub dump: %.1f ms", state.instance(), spent * 1000))
    end
end

-- Every platform's raw item total, summed. The manager compares it with each copy's total
-- and reports the difference; a platform-to-platform move on the space server changes the
-- identity but not this total, which is the point.
local function tick_audit()
    if not state.known() then
        return
    end
    local started = os.clock()

    -- audit() returns {instance, tick, totals}; the push needs the totals table itself, not
    -- the wrapper. That mismatch was why the scheduled audit never reached the manager.
    local audit = platform_api.audit()
    local totals = audit and audit.totals or {}
    local keys = {}
    for key in pairs(totals) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    -- A full fleet's totals are larger than one comfortable datagram, so this is paged the
    -- same way a hub dump is. The manager reassembles by instance and chunk count.
    local per = 40
    local chunks = math.max(1, math.ceil(#keys / per))
    for chunk = 1, chunks do
        local page = {}
        for index = (chunk - 1) * per + 1, math.min(chunk * per, #keys) do
            page[keys[index]] = totals[keys[index]]
        end

        log(string.format("[%s] udp platform_audit %d/%d (%d stacks)",
            state.instance(), chunk, chunks, #page))
        push("platform_audit", {
            instance = state.instance(),
            tick = game.tick,
            totals = page,
            chunk = chunk,
            chunks = chunks,
        })
    end
    local spent = os.clock() - started
    if spent > 0.02 then
        log(string.format("[%s] slow audit: %.1f ms", state.instance(), spent * 1000))
    end
end

-- Research progress every second, only when it moved. The delta is what the others add;
-- `progress` is the absolute bar, so a receiver can resync from it.
local function tick_research()
    if not state.known() then
        return
    end

    local force = main_force()
    local technology = force.current_research
    local progress = force.research_progress or 0
    local last = storage.last_research or {}
    if technology and technology.name == last.tech and progress - (last.progress or 0) <= 0 then
        return
    end

    storage.last_research = {
        tech = technology and technology.name or nil,
        progress = progress,
    }

    push("research", {
        instance = state.instance(),
        tick = game.tick,
        tech = technology and technology.name or nil,
        progress = progress,
        delta = technology and technology.name == last.tech
            and math.max(0, progress - (last.progress or 0)) or progress,
        queue = (function()
            local out = {}
            for _, queued in pairs(force.research_queue or {}) do
                out[#out + 1] = queued.name
            end
            return out
        end)(),
    })
end

return {
    push = push,
    tick_positions = tick_positions,
    tick_meta = tick_meta,
    tick_meta_full = tick_meta_full,
    tick_hub = tick_hub,
    tick_audit = tick_audit,
    tick_research = tick_research,
    positions = positions,
    epoch = epoch,
}
