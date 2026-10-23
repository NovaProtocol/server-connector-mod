-- server-connector-mod / control/platform_api.lua
--
-- The helper surface for platform logistics. Everything here reads or emits; the diffing,
-- aggregation and fan-out belong to the manager. The same functions are registered with the
-- RCON interface in rcon.lua and called from the scheduler in outbound.lua, so a manual
-- RCON call and a scheduled push are the same code path.
--
-- Two costs, separated on purpose:
--
--   meta()   cheap: identity, position, state, bay count, request hash. Safe at 10 Hz.
--   dump()   heavy: hub cargo and requests, paged by cursor. Only on demand or on change.
--
-- Required as "__server-connector-mod__.control.platform_api".

local state = require("__server-connector-mod__.control.state")

local instance = state.instance
local known = state.known
local main_force = state.main_force

-- A write to the game's API, said out loud when it fails. A refused write from a handler is
-- non-recoverable, and a silent refusal looks exactly like a successful one.
local function attempt(what, fn)
    local ok, value = pcall(fn)
    if not ok then
        log(string.format("[%s] %s failed: %s", instance(), what, tostring(value)))
        return nil
    end
    return value
end

local function find_platform(payload)
    payload = payload or {}
    local index = tonumber(payload.platform or payload.index)
    local name = payload.name
    if not name and type(payload.platform) == "string" then
        name = payload.platform
    end
    for _, platform in pairs(main_force().platforms or {}) do
        if (index ~= nil and platform.index == index) or (name ~= nil and platform.name == name) then
            return platform
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- inventories and requests, asked of the game rather than assumed
--------------------------------------------------------------------------------

-- Which inventory a platform hub keeps its cargo in, asked once and remembered.
--
-- The docs list the names but which one a hub answers is a build fact, and guessing it is
-- how this fleet got two outages. The probe reports the name it found, so the log says
-- which one this build uses.
local function hub_inventory(hub)
    if not hub or not hub.valid then
        return nil
    end

    if storage.hub_inventory_name then
        local name = storage.hub_inventory_name
        local value = defines.inventory[name]
        if value then
            local inventory = attempt("reading the hub inventory " .. name, function()
                return hub.get_inventory(value)
            end)
            if inventory then
                return inventory
            end
        end
    end

    -- The named candidates first; the whole table after them. get_inventory returns nil for
    -- a type the entity does not have, so a miss is an answer rather than an error.
    for _, name in ipairs({"cargo_unit", "cargo_landing_pad", "hub", "main", "chest"}) do
        local value = defines.inventory[name]
        if value then
            local ok, inventory = pcall(function() return hub.get_inventory(value) end)
            if ok and inventory then
                storage.hub_inventory_name = name
                log(string.format("[%s] the platform hub inventory is %s", instance(), name))
                return inventory
            end
        end
    end

    for name, value in pairs(defines.inventory) do
        local ok, inventory = pcall(function() return hub.get_inventory(value) end)
        if ok and inventory then
            storage.hub_inventory_name = name
            log(string.format("[%s] the platform hub inventory is %s (probed)", instance(), name))
            return inventory
        end
    end

    return nil
end

-- Which logistic point a hub's requests are on, asked once and remembered.
local function request_point(hub)
    if not hub or not hub.valid then
        return nil
    end

    if storage.request_member ~= nil then
        local point = attempt("reading the hub requests", function()
            return hub.get_logistic_point(storage.request_member)
        end)
        if point then
            return point
        end
        storage.request_member = nil
    end

    for name, value in pairs(defines.logistic_member_index) do
        local ok, point = pcall(function() return hub.get_logistic_point(value) end)
        if ok and point then
            storage.request_member = value
            log(string.format("[%s] the platform requests are on %s", instance(), name))
            return point
        end
    end

    return nil
end

local function quality_name(value)
    if type(value) == "table" then
        return value.name or "normal"
    end
    return value or "normal"
end

-- The hub's cargo, item by item, as the manager needs it. Read-only.
local function cargo_of(platform)
    local out = {}
    local inventory = hub_inventory(platform.hub)
    if not inventory then
        return out
    end

    for index = 1, #inventory do
        local stack = inventory[index]
        if stack and stack.valid_for_read and stack.count > 0 then
            out[#out + 1] = {
                item = stack.name,
                quality = quality_name(stack.quality),
                count = stack.count,
            }
        end
    end

    table.sort(out, function(a, b)
        if a.item ~= b.item then return a.item < b.item end
        if a.quality ~= b.quality then return a.quality < b.quality end
        return a.count < b.count
    end)
    return out
end

-- The hub's requests, as logistic filters the manager can compare and send back.
local function requests_of(platform)
    local out = {}
    local point = request_point(platform.hub)
    if not point then
        return out
    end

    for _, section in pairs(point.sections or {}) do
        for _, filter in pairs(section.filters or {}) do
            -- LogisticFilter in 2.0 is value/min/max, not the 1.1 name/count shape.
            local value = filter and filter.value
            if value and value.name then
                local count = filter.min or 0
                if count > 0 then
                    out[#out + 1] = {
                        item = value.name,
                        quality = quality_name(value.quality),
                        count = count,
                        max_count = filter.max or count,
                    }
                end
            end
        end
    end

    table.sort(out, function(a, b)
        if a.item ~= b.item then return a.item < b.item end
        return a.quality < b.quality
    end)
    return out
end

-- A stable hash of a stack list. The manager uses it to know whether a dump is new; it is
-- not a security hash and does not need to be.
local function hash(list)
    local value = 5381
    for _, entry in ipairs(list or {}) do
        local text = string.format("%s|%s|%d",
            tostring(entry.item or entry.name), tostring(entry.quality), tonumber(entry.count) or 0)
        for index = 1, #text do
            value = (value * 33 + string.byte(text, index)) % 4294967296
        end
    end
    return value
end

--------------------------------------------------------------------------------
-- meta: the cheap call
--------------------------------------------------------------------------------

local function count_bays(platform)
    local ok, bays = pcall(function() return #platform.cargo_bays end)
    if ok and type(bays) == "number" then
        return bays
    end
    return nil
end

local function meta()
    local out = {}
    for _, platform in pairs(main_force().platforms or {}) do
        out[#out + 1] = {
            index = platform.index,
            name = platform.name,
            state = tostring(platform.state),
            location = platform.space_location and platform.space_location.name or nil,
            connection = platform.space_connection and platform.space_connection.name or nil,
            distance = platform.distance,
            paused = platform.paused,
            hub = platform.hub and platform.hub.unit_number or nil,
            bays = count_bays(platform),
            request_hash = hash(requests_of(platform)),
        }
    end

    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
end

--------------------------------------------------------------------------------
-- dump: the heavy call, one page at a time
--------------------------------------------------------------------------------

-- One page of one platform's hub cargo, plus its requests on the first page.
--
-- `cursor` is a stack offset, not a time: the manager walks pages until `done`. The whole
-- dump never goes in one datagram, because a platform can be built to any size.
local function dump(payload)
    payload = payload or {}
    local platform = find_platform(payload)
    if not platform then
        return {ok = false, error = "no such platform"}
    end

    local cargo = cargo_of(platform)
    local cursor = math.max(0, math.floor(tonumber(payload.cursor) or 0))
    local limit = math.max(1, math.min(100, math.floor(tonumber(payload.limit) or 60)))
    local total = #cargo

    local page = {}
    for index = cursor + 1, math.min(cursor + limit, total) do
        page[#page + 1] = cargo[index]
    end

    local requests = nil
    if cursor == 0 then
        requests = requests_of(platform)
    end

    local next_cursor = cursor + #page
    return {
        ok = true,
        instance = instance(),
        platform = {index = platform.index, name = platform.name},
        cursor = cursor,
        next = next_cursor,
        total = total,
        done = next_cursor >= total,
        hash = hash(cargo),
        cargo = page,
        requests = requests,
        request_hash = requests and hash(requests) or nil,
        tick = game.tick,
    }
end

--------------------------------------------------------------------------------
-- audit: the aggregate total, for the manager's drift report
--------------------------------------------------------------------------------

-- Every platform's raw item total, summed across platforms. Platform identity is
-- deliberately absent: a transfer between two real platforms must not look like a loss.
local function audit()
    local totals = {}
    for _, platform in pairs(main_force().platforms or {}) do
        for _, entry in ipairs(cargo_of(platform)) do
            local key = entry.item .. "|" .. entry.quality
            totals[key] = (totals[key] or 0) + entry.count
        end
    end

    return {
        instance = instance(),
        tick = game.tick,
        totals = totals,
    }
end

--------------------------------------------------------------------------------
-- mutations: the manager has already decided what changed
--------------------------------------------------------------------------------

-- Apply the manager's cargo difference to this server's copy.
--
-- Inventory writes are replicated by the game, so this is the one live-safe mutation. It
-- stays idempotent by being a difference, not a set: applying the same ops twice is what a
-- retry does, and the manager's snapshot is what stops it being sent twice at all.
local function apply_cargo_delta(payload)
    payload = payload or {}
    local platform = find_platform(payload)
    if not platform then
        return {ok = false, error = "no such platform"}
    end

    local inventory = hub_inventory(platform.hub)
    if not inventory then
        return {ok = false, error = "no hub inventory found"}
    end

    local applied = 0
    for _, operation in ipairs(payload.ops or {}) do
        local count = math.floor(tonumber(operation.count) or 0)
        if count ~= 0 then
            local item = {
                name = operation.item or operation.name,
                quality = operation.quality or "normal",
                count = math.abs(count),
            }
            local ok
            if count > 0 then
                ok = inventory.insert(item)
            else
                ok = inventory.remove(item)
            end
            if ok then
                applied = applied + 1
            end
        end
    end

    return {
        instance = instance(),
        platform = platform.index,
        applied = applied,
    }
end

-- Replace a copy's requests. This is a world change, so it waits for an empty server.
local function apply_requests(payload)
    payload = payload or {}
    if not state.empty() then
        return {ok = false, skipped = "somebody is connected"}
    end

    local platform = find_platform(payload)
    if not platform then
        return {ok = false, error = "no such platform"}
    end

    local point = request_point(platform.hub)
    if not point then
        return {ok = false, error = "no request point found"}
    end

    local filters = {}
    for _, request in ipairs(payload.requests or {}) do
        filters[#filters + 1] = {
            value = {
                type = "item",
                name = request.item or request.name,
                quality = request.quality or "normal",
            },
            min = request.count,
            max = request.max_count or request.count,
        }
    end

    local written, err = pcall(function()
        local sections = point.sections
        if sections and #sections > 0 then
            sections[1].filters = filters
        else
            point.sections = {{filters = filters}}
        end
    end)

    if not written then
        log(string.format("[%s] writing the platform requests failed: %s", instance(), tostring(err)))
        return {ok = false, error = "the game refused the requests: " .. tostring(err)}
    end

    return {instance = instance(), platform = platform.index, requests = #filters}
end

return {
    meta = meta,
    dump = dump,
    audit = audit,
    cargo = cargo_of,
    requests = requests_of,
    hash = hash,
    hub_inventory = hub_inventory,
    request_point = request_point,
    apply_cargo_delta = apply_cargo_delta,
    apply_requests = apply_requests,
}
