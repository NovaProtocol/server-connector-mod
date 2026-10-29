-- server-connector-mod / control/outbound.lua
--
-- Mod -> app, by localhost UDP only.
--
-- There is no stdout/log path any more: the game writes nothing for the app to scrape. The
-- RCON channel stays for calls the app makes into the game; these pushes are the other
-- direction, for events and continuous state the game knows on its own. UDP needs
-- --enable-lua-udp on the game, which the node passes per instance.

local state = require("__server-connector-mod__.control.state")
local bus = require("__server-connector-mod__.control.bus")
local platforms = require("__server-connector-mod__.control.platforms")
local platform_api = require("__server-connector-mod__.control.platform_api")

local main_force = state.main_force

-- The transport lives in bus.lua so that platforms.lua can push without requiring this
-- module, which requires it. The names stay exported here: every caller outside this file
-- keeps using outbound.push, and the cycle has no way back.
local push = bus.push
local epoch = bus.epoch

-- Every platform's serialized position. `distance` is the fractional position along the
-- connection; `docked` is waiting at a planet rather than in transit.
local function positions()
    local out = {}
    for _, platform in pairs(main_force().platforms or {}) do
        out[#out + 1] = platform_api.position_of(platform, true)
    end
    return out
end

-- Positions move continuously in transit, so they go every 30 ticks (2 Hz), from the
-- space server only.
local function streams_enabled()
    return storage.platform_streams ~= false
end

local function tick_positions()
    if not state.known() or state.instance() ~= "space" or not streams_enabled() then
        return
    end
    push("platform_positions", {
        instance = state.instance(),
        tick = game.tick,
        platforms = positions(),
    })
end

-- The cheap platform metadata, from every server: copies included. It is checked at 10 Hz
-- but sent only when a platform's identity/position changes. A full heartbeat every five
-- seconds gives the manager a complete list and lets it prune.
local function meta_signature(entry)
    return table.concat({
        tostring(entry.index or 0),
        tostring(entry.name or ""),
        tostring(entry.state or ""),
        tostring(entry.location or ""),
        tostring(entry.connection or ""),
        entry.paused and "1" or "0",
        tostring(entry.hub or 0),
    }, "|")
end

local function tick_meta()
    if not state.known() or not streams_enabled() then
        return
    end

    local entries = platform_api.meta()
    local previous = storage.meta_seen or {}
    local current = {}
    local changed = {}
    local missing = false

    for _, entry in ipairs(entries) do
        local key = tostring(entry.index or 0)
        local signature = meta_signature(entry)
        current[key] = signature
        if previous[key] ~= signature then
            changed[#changed + 1] = entry
        end
    end
    for key in pairs(previous) do
        if current[key] == nil then
            missing = true
            break
        end
    end

    local heartbeat = not storage.meta_heartbeat or game.tick - storage.meta_heartbeat >= 300
    storage.meta_seen = current

    if heartbeat or missing then
        storage.meta_heartbeat = game.tick
        push("platform_meta", {
            instance = state.instance(),
            tick = game.tick,
            platforms = entries,
            partial = false,
        })
    elseif #changed > 0 then
        push("platform_meta", {
            instance = state.instance(),
            tick = game.tick,
            platforms = changed,
            partial = true,
        })
    end
end

-- Logistic-only meta at 1 Hz: requests and their hash, no layout or bay walk. The full
-- shape still goes every five seconds; this keeps the request view current without paying
-- the full shape's cost ten times as often.
local function tick_logistic()
    if not state.known() or not streams_enabled() then
        return
    end
    push("platform_meta", {
        instance = state.instance(),
        tick = game.tick,
        platforms = platform_api.meta_logistic(),
    })
end

-- The heavy platform cargo, only when the hash moved and only one page at a time.
--
-- A platform can be built to any size, so this never sends a whole hub in one datagram: the
-- manager reassembles the pages by platform, hash and cursor. A server that is idle sends
-- nothing.
local function tick_hub()
    if not state.known() or not streams_enabled() then
        return
    end
    storage.hub_sent = storage.hub_sent or {}
    storage.hub_weight = storage.hub_weight or {}

    for _, platform in pairs(main_force().platforms or {}) do
        -- Weight is one engine-side scalar over the hub inventory. If it did not move,
        -- nothing can have entered or left, so the expensive per-stack dump is skipped.
        local inventory = platform_api.hub_inventory(platform.hub)
        if inventory then
            local weight = inventory.weight
            if storage.hub_weight[platform.index] ~= weight then
                storage.hub_weight[platform.index] = weight

                local page = platform_api.dump({index = platform.index, cursor = 0, limit = 60})
                if page and page.ok then
                    if storage.hub_sent[platform.index] ~= page.hash then
                        local cursor = 0
                        local pages = 0
                        repeat
                            if cursor ~= 0 then
                                page = platform_api.dump({index = platform.index, cursor = cursor, limit = 60})
                            end
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

                        storage.hub_sent[platform.index] = page.hash
                    end
                end
            end
        end
    end
end

-- Every platform's raw item total, summed. The manager compares it with each copy's total
-- and reports the difference; a platform-to-platform move on the space server changes the
-- identity but not this total, which is the point.
local function tick_audit()
    if not state.known() or not streams_enabled() then
        return
    end
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

-- One heartbeat a second, for the server window's live rows.
local function tick_heartbeat()
    local ok, err = pcall(function()
        local names = {}
        for _, player in pairs(game.connected_players) do
            names[#names + 1] = player.name
        end
        table.sort(names)
        push("server_heartbeat", {
            instance = state.instance(),
            tick = game.tick,
            speed = game.speed,
            players = #names,
            player_names = names,
            version = (script.active_mods or {})["base"],
            mod_version = (script.active_mods or {})["server-connector-mod"],
        })
    end)
    if not ok then
        log(string.format("[%s] heartbeat failed: %s", state.instance(), tostring(err)))
    end
end

return {
    push = push,
    streams_enabled = streams_enabled,
    tick_positions = tick_positions,
    tick_meta = tick_meta,
    tick_logistic = tick_logistic,
    tick_hub = tick_hub,
    tick_audit = tick_audit,
    tick_research = tick_research,
    tick_heartbeat = tick_heartbeat,
    positions = positions,
    epoch = epoch,
}
