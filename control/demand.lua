-- server-connector-mod / control/demand.lua
--
-- THE MODEL
--   Planet server : landing pads  -> this planet's hub, group Incoming. The planet side OWNS Incoming.
--   Space server  : real platforms -> each planet's hub, group Outgoing. The space side OWNS Outgoing.
--   The OTHER side's copy of a group is written only by the manager, from the owner's list.
--   Buffer is edited by people on a hub, mirrored to the other hub, and never recalculated.
--   Everything is recalculated and rewritten IN FULL every time. There is no delta anywhere.
--
-- Required after connector, before events and rcon.

local state = require("__server-connector-mod__.control.state")
local platform_api = require("__server-connector-mod__.control.platform_api")
local connector = require("__server-connector-mod__.control.connector")

local INSTANCE = state.instance
local MAX_RUNS_PER_SECOND = 20
local MAX_LIST = 500
local MAX_COUNT = 2000000000

local function safe(fn, default)
    local ok, value = pcall(fn)
    if ok and value ~= nil then
        return value
    end
    return default
end

local function name_of(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    return safe(function() return value.name end, nil)
end

local function valid_item(name)
    return safe(function() return prototypes.item[name] ~= nil end, false)
end

local function valid_quality(name)
    return safe(function() return prototypes.quality[name] ~= nil end, false)
end

local function note_seen(kind, value)
    storage.demand_seen = storage.demand_seen or {}
    local key = kind .. "=" .. tostring(value)
    if not storage.demand_seen[key] then
        storage.demand_seen[key] = true
        log(string.format("[%s] demand: first %s value seen: %s", INSTANCE(), kind, tostring(value)))
    end
end

-- Every active manual section of one logistic point, flattened to entries.
local function read_point(point, notes)
    local entries = {}
    for _, section in pairs(point.sections or {}) do
        local active = safe(function() return section.active end, true)
        local multiplier = tonumber(safe(function() return section.multiplier end, 1)) or 1
        if section.is_manual and active ~= false and multiplier > 0 then
            for _, filter in pairs(section.filters or {}) do
                local value = filter and filter.value
                local minimum = tonumber(filter and filter.min) or 0
                if value and value.name and minimum > 0 then
                    local quality = name_of(value.quality) or "normal"
                    if value.type ~= nil and value.type ~= "item" then
                        notes[#notes + 1] = "not an item: " .. tostring(value.name)
                    elseif not valid_item(value.name) then
                        notes[#notes + 1] = "unknown item: " .. tostring(value.name)
                    elseif not valid_quality(quality) then
                        notes[#notes + 1] = "unknown quality: " .. tostring(quality)
                    else
                        if value.comparator ~= nil and value.comparator ~= "=" then
                            notes[#notes + 1] = "quality comparator " .. tostring(value.comparator)
                                .. " counted as " .. quality .. ": " .. value.name
                        end
                        entries[#entries + 1] = {
                            item = value.name,
                            quality = quality,
                            count = math.floor(minimum * multiplier),
                            request_from = name_of(filter.request_from),
                            import_from = name_of(filter.import_from),
                        }
                    end
                end
            end
        end
    end
    return entries
end

local function add(totals, entry)
    if entry.count <= 0 then
        return
    end
    local key = entry.item .. "|" .. entry.quality
    local slot = totals[key]
    if not slot then
        slot = {item = entry.item, quality = entry.quality, count = 0}
        totals[key] = slot
    end
    slot.count = slot.count + entry.count
end

local function to_list(totals)
    local out = {}
    for _, slot in pairs(totals) do
        if slot.count > 0 then
            out[#out + 1] = {item = slot.item, quality = slot.quality, count = math.min(slot.count, MAX_COUNT)}
        end
    end
    table.sort(out, function(a, b)
        if a.item ~= b.item then return a.item < b.item end
        return a.quality < b.quality
    end)
    return out
end

-- Which planets' Outgoing groups a platform request belongs to. Returns a list of planets,
-- or nil and a reason.
local function planets_for(entry, totals)
    local source = entry.request_from
    if source ~= nil and string.lower(source) ~= "planet" then
        return nil, "not from a planet"
    end
    local target = entry.import_from
    local lowered = target ~= nil and string.lower(target) or nil
    if target == nil or target == "" or lowered == "any" or lowered == "all" then
        local all = {}
        for planet in pairs(totals) do
            all[#all + 1] = planet
        end
        table.sort(all)
        if #all == 0 then
            return nil, "no planets"
        end
        return all
    end
    if not totals[target] then
        return nil, "no hub for " .. tostring(target)
    end
    return {target}
end

-- The whole picture, computed one way for the live recalculation AND the manager's read.
local function collect()
    if not state.known() then
        return {ok = false, error = "no identity"}
    end
    local skipped, sources, totals = {}, {}, {}
    local role = connector.role()

    if role == "planet" then
        local planet = INSTANCE()
        totals[planet] = {}
        for _, pad in ipairs(connector.pads()) do
            if pad.valid then
                local point = connector.pad_point(pad)
                if not point then
                    return {ok = false, error = "a landing pad has no logistic point"}
                end
                local notes = {}
                local ok, entries = pcall(read_point, point, notes)
                if not ok then
                    return {ok = false, error = "reading a landing pad failed: " .. tostring(entries)}
                end
                for _, entry in ipairs(entries) do
                    add(totals[planet], entry)
                end
                for _, note in ipairs(notes) do
                    skipped[#skipped + 1] = "pad: " .. note
                end
                sources[#sources + 1] = {kind = "pad", id = pad.unit_number, name = pad.name, planet = planet, entries = entries}
            end
        end
    else
        local planets = connector.planets()
        if #planets == 0 then
            return {ok = false, error = "no topology"}
        end
        for _, planet in ipairs(planets) do
            totals[planet] = {}
        end
        for _, platform in pairs(state.main_force().platforms or {}) do
            if platform.valid and not connector.is_connector(platform)
                and (platform.scheduled_for_deletion or 0) == 0 then
                local hub = platform.hub
                if hub and hub.valid then
                    local point = platform_api.request_point(hub)
                    if not point then
                        return {ok = false, error = "a platform has no request point: " .. tostring(platform.name)}
                    end
                    local notes = {}
                    local ok, entries = pcall(read_point, point, notes)
                    if not ok then
                        return {ok = false, error = "reading " .. tostring(platform.name) .. " failed: " .. tostring(entries)}
                    end
                    for _, note in ipairs(notes) do
                        skipped[#skipped + 1] = platform.name .. ": " .. note
                    end
                    for _, entry in ipairs(entries) do
                        note_seen("request_from", entry.request_from)
                        note_seen("import_from", entry.import_from)
                        local targets, why = planets_for(entry, totals)
                        if targets then
                            for _, planet in ipairs(targets) do
                                add(totals[planet], entry)
                            end
                        else
                            skipped[#skipped + 1] = string.format("%s: %s x%d (%s)",
                                platform.name, entry.item, entry.count, why)
                        end
                    end
                    local location = safe(function() return platform.space_location end, nil)
                    sources[#sources + 1] = {
                        kind = "platform", id = platform.index, name = platform.name,
                        planet = location and name_of(location) or nil, entries = entries,
                    }
                end
            end
        end
    end

    local derived = {}
    for planet, planet_totals in pairs(totals) do
        derived[planet] = to_list(planet_totals)
    end
    local result = {ok = true, role = role, instance = INSTANCE(), derived = derived, sources = sources}
    if #skipped > 0 then
        result.skipped = skipped
    end
    return result
end

local function same(a, b)
    local function keyed(list)
        local map, count = {}, 0
        for _, entry in ipairs(list or {}) do
            map[tostring(entry.item or entry.name) .. "|" .. tostring(entry.quality or "normal")] =
                math.floor(tonumber(entry.count) or 0)
            count = count + 1
        end
        return map, count
    end
    local left, left_count = keyed(a)
    local right, right_count = keyed(b)
    if left_count ~= right_count then
        return false
    end
    for key, count in pairs(left) do
        if right[key] ~= count then
            return false
        end
    end
    return true
end

local function write(result, why)
    local report = {}
    for planet, list in pairs(result.derived) do
        local lists, group = {}, nil
        if result.role == "planet" then
            lists.incoming, group = list, "incoming"
        else
            lists.outgoing, group = list, "outgoing"
        end
        local ok, err = connector.set_groups(planet, lists, why)
        local actual = connector.read_groups(planet)
        report[planet] = {
            ok = ok, error = err, count = #list,
            verified = ok and actual.exists and same(actual[group], list) or false,
        }
    end
    return report
end

local function queue(why)
    storage.demand_pending = why or "queued"
end

local function fail(why, reason)
    storage.demand_tries = (storage.demand_tries or 0) + 1
    if storage.demand_tries >= 3 then
        storage.demand_tries = 0
        log(string.format("[%s] demand: giving up after 3 tries (%s): %s", INSTANCE(), tostring(why), tostring(reason)))
        return
    end
    storage.demand_pending = why
    storage.demand_not_before = game.tick + 60
end

local function tick()
    local why = storage.demand_pending
    if not why or not state.known() then
        return
    end
    if game.tick < (storage.demand_not_before or 0) then
        return
    end
    local window = storage.demand_window
    if not window or game.tick - window.start >= 60 then
        window = {start = game.tick, runs = 0}
        storage.demand_window = window
    end
    window.runs = window.runs + 1
    if window.runs > MAX_RUNS_PER_SECOND then
        storage.demand_pending = nil
        storage.demand_not_before = game.tick + 300
        log(string.format("[%s] demand: loop breaker tripped, paused for 300 ticks", INSTANCE()))
        return
    end

    storage.demand_pending = nil
    local result = collect()
    if not result.ok then
        fail(why, result.error)
        return
    end
    local report = write(result, why)
    storage.demand_last_write = game.tick
    for planet, row in pairs(report) do
        if not row.verified and row.error ~= "no connector hub" then
            fail(why, "readback mismatch on " .. planet)
            return
        end
    end
    storage.demand_tries = 0
end

---------------------------------------------------------------------------
-- the manager's calls: one per kind of data, each prechecked, each verified
---------------------------------------------------------------------------
local function resolve_planet(planet)
    if connector.role() == "planet" then
        return INSTANCE()
    end
    for _, id in ipairs(connector.planets()) do
        if id == planet then
            return planet
        end
    end
    return nil, "unknown planet " .. tostring(planet)
end

local function validate_list(name, list, with_sources)
    if type(list) ~= "table" then
        return name .. " is not a list"
    end
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" then
            return name .. " is not a plain list"
        end
        count = count + 1
    end
    if count > MAX_LIST then
        return name .. " is longer than " .. MAX_LIST
    end
    local seen = {}
    for index, entry in ipairs(list) do
        if type(entry) ~= "table" then
            return string.format("%s[%d] is not an entry", name, index)
        end
        local item = entry.item or entry.name
        local quality = entry.quality or "normal"
        local amount = entry.count
        if type(item) ~= "string" or not valid_item(item) then
            return string.format("%s[%d] has an unknown item", name, index)
        end
        if type(quality) ~= "string" or not valid_quality(quality) then
            return string.format("%s[%d] has an unknown quality", name, index)
        end
        if type(amount) ~= "number" or amount ~= math.floor(amount) or amount < 1 or amount > MAX_COUNT then
            return string.format("%s[%d] has a bad count", name, index)
        end
        local key = item .. "|" .. quality
        if seen[key] then
            return string.format("%s[%d] repeats %s", name, index, key)
        end
        seen[key] = true
        if with_sources then
            if entry.request_from ~= nil and entry.request_from ~= "planet" and entry.request_from ~= "platforms" then
                return string.format("%s[%d] has a bad request_from", name, index)
            end
            if entry.import_from ~= nil and type(entry.import_from) ~= "string" then
                return string.format("%s[%d] has a bad import_from", name, index)
            end
        end
    end
    return nil
end

local function sync_info()
    local planets = {}
    for _, planet in ipairs(connector.role() == "planet" and {INSTANCE()} or connector.planets()) do
        planets[#planets + 1] = {planet = planet, exists = connector.find_connector(planet) ~= nil}
    end
    return {
        ok = true, instance = INSTANCE(), known = state.known(), role = connector.role(),
        version = (script.active_mods and script.active_mods["server-connector-mod"]) or "unknown",
        protocol = state.PROTOCOL, tick = game.tick, planets = planets,
        buffer_migrated = storage.buffer_migrated or {},
    }
end

local function sync_read_groups(planet)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    local result = connector.read_groups(id)
    result.ok = true
    result.planet = id
    return result
end

local function sync_read_cargo(planet)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    local result = connector.read_cargo(id)
    result.ok = true
    result.planet = id
    return result
end

local function sync_read_layout(planet)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    local result = connector.read_layout(id)
    result.ok = true
    result.planet = id
    return result
end

local function sync_apply_groups(planet, payload)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    if type(payload) ~= "table" then return {ok = false, error = "payload is not a table"} end
    local role = connector.role()
    if role == "planet" and payload.incoming ~= nil then
        return {ok = false, error = "the planet side owns incoming"}
    end
    if role == "space" and payload.outgoing ~= nil then
        return {ok = false, error = "the space side owns outgoing"}
    end
    for _, name in ipairs({"incoming", "outgoing", "buffer"}) do
        if payload[name] ~= nil then
            local problem = validate_list(name, payload[name], name == "buffer")
            if problem then return {ok = false, error = problem} end
        end
    end
    local platform = connector.find_connector(id)
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = false, error = "no connector hub"}
    end
    local lists = {incoming = payload.incoming, outgoing = payload.outgoing, buffer = payload.buffer}
    local ok, write_error = connector.set_groups(id, lists, "sync", true)
    if payload.mark_buffer_migrated then
        storage.buffer_migrated = storage.buffer_migrated or {}
        storage.buffer_migrated[id] = true
    end
    local actual = connector.read_groups(id)
    local verified = ok and actual.exists
    for _, name in ipairs({"incoming", "outgoing", "buffer"}) do
        if lists[name] ~= nil then
            verified = verified and same(actual[name], lists[name])
        end
    end
    local result = {ok = ok, verified = verified and true or false, error = write_error}
    if not result.verified then
        result.actual = actual
    end
    return result
end

local function sync_apply_cargo(planet, list)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    local problem = validate_list("cargo", list, false)
    if problem then return {ok = false, error = problem} end
    local platform = connector.find_connector(id)
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = false, error = "no connector hub"}
    end
    local applied = connector.apply({planet = id, has_cargo = true, cargo = list})
    local actual = connector.read_cargo(id)
    local verified = applied.ok and same(actual.cargo, list)
    return {ok = applied.ok, verified = verified and true or false, shortfalls = applied.shortfalls}
end

local function sync_apply_layout(planet, bays, layout)
    local id, err = resolve_planet(planet)
    if not id then return {ok = false, error = err} end
    if bays ~= nil and (type(bays) ~= "number" or bays ~= math.floor(bays) or bays < 0 or bays > 500) then
        return {ok = false, error = "bad bay count"}
    end
    if layout ~= nil and type(layout) ~= "string" then
        return {ok = false, error = "bad layout"}
    end
    local platform = connector.find_connector(id)
    if not platform or not platform.hub or not platform.hub.valid then
        return {ok = false, error = "no connector hub"}
    end
    local applied = connector.apply({planet = id, bays = bays, layout = layout})
    local actual = connector.read_layout(id)
    local verified = applied.ok and (layout == nil or layout == "" or actual.layout == layout)
    return {ok = applied.ok, verified = verified and true or false, bays = actual.bays, layout = actual.layout}
end

return {
    queue = queue,
    tick = tick,
    collect = collect,
    sync_info = sync_info,
    sync_read_sources = collect,
    sync_read_groups = sync_read_groups,
    sync_read_cargo = sync_read_cargo,
    sync_read_layout = sync_read_layout,
    sync_apply_groups = sync_apply_groups,
    sync_apply_cargo = sync_apply_cargo,
    sync_apply_layout = sync_apply_layout,
}
