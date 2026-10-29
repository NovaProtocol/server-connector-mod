-- server-connector-mod / control/state.lua
--
-- The foundation the rest of control/ is built on: the constants, the storage schema,
-- this server's identity, the fleet topology, and the in-game event queue the node
-- drains. It depends on nothing else in control/, so everything may depend on it.
--
-- Required by the other modules as "__server-connector-mod__.control.state". Factorio
-- caches a required file by the exact string it was asked for, so that one spelling is
-- the only spelling used anywhere: a second spelling of this file would be a second copy,
-- and two copies of the state helpers would be two different beliefs.

local MOD = "server-connector"
local SCHEMA = 3

--------------------------------------------------------------------------------
-- storage
--------------------------------------------------------------------------------

local function ensure_storage()
    storage.schema = storage.schema or SCHEMA
    storage.topology = storage.topology or {}   -- instance id -> {name, address}
    storage.body = storage.body or {}           -- player name -> instance id
    storage.body_known = storage.body_known or {} -- player name -> true once the manager has spoken
    storage.viewing = storage.viewing or {}     -- player name -> true, for the join rule
    storage.routed = storage.routed or {}       -- player name -> last surface routed from
    storage.anchored = storage.anchored or {}   -- player name -> the platform they belong on
    storage.cleared = storage.cleared or {}     -- surface name -> what was taken off it
    storage.hub_sent = storage.hub_sent or {}   -- platform index -> the cargo hash last sent
    storage.out_seq = storage.out_seq or 0      -- the sequence number of the last UDP push
end

--------------------------------------------------------------------------------
-- identity and topology
--------------------------------------------------------------------------------

-- Identity is a property of the container. The startup setting is the intended
-- carrier, but a headless server does not import mod-settings.json: it compiles
-- mod-settings.dat from defaults and ignores the .json beside it, so the setting
-- never arrives. The node therefore pushes it, and the setting is kept as the
-- fallback for anyone who sets it by hand in the game.
local function instance()
    if storage and storage.instance then
        return storage.instance
    end
    local setting = settings.startup[MOD .. "-instance"]
    return setting and setting.value or "unconfigured"
end

-- Whether the node has told this server what it is yet.
--
-- This mod is a driver. It reaches into the game's own components -- surfaces, players, the
-- scenario -- and the node decides what is done with them; the order comes in over stdin
-- and the event goes out over stdout, and neither happens without the other end being
-- there. That division is also what makes it safe to have loaded at all: a server that
-- never hears from a node -- somebody's own save, a server that has nothing to do with this
-- fleet -- never gets an identity, and every action in this mod does nothing. Installing
-- it changes nothing, unless somebody sets `server-connector-instance` by hand: then the
-- setting is the identity, because instance() already falls back to it.
local function known()
    if storage ~= nil and storage.instance ~= nil then
        return true
    end
    local setting = settings.startup[MOD .. "-instance"]
    return setting ~= nil and setting.value ~= "unconfigured"
end

-- Whether the fleet is empty of players.
--
-- World changes driven from outside the game -- orders arriving over RCON -- are NOT
-- replicated to clients. The server cuts a surface down and the client, which was never
-- told, keeps it, and the next crc comparison fails: a desync on join, every time. So
-- anything that changes the world runs only with nobody connected, and again when the last
-- player leaves.
local function empty()
    local players = game.connected_players
    return players == nil or #players == 0
end

local function destinations()
    local out = {}
    for id, entry in pairs(storage.topology or {}) do
        if id ~= instance() and type(entry) == "table" and entry.address then
            out[#out + 1] = {id = id, name = entry.name or id, address = entry.address}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- The surfaces this instance owns, as a set.
--
-- The manager names them in this instance's topology entry: a planet owns its planet
-- surface, a custom instance owns the surfaces declared for it, and the space instance owns
-- its platforms (which are handled separately, because they are built rather than declared).
-- There are no copies of another server's surface any more, so this set is also "everything
-- on this world I am allowed to have".
local function owned_surfaces()
    local entry = (storage.topology or {})[instance()]
    local out = {}
    if entry and type(entry.surfaces) == "table" then
        for _, name in ipairs(entry.surfaces) do
            if type(name) == "string" and name ~= "" then
                out[name] = true
            end
        end
    end

    -- An older manager sends no list: the instance's own surface is the fallback. A space
    -- server owns no planet surface, and its platforms are not in the list.
    if next(out) == nil and instance() ~= "space" then
        out[instance()] = true
    end

    return out
end

-- The surface a player on this instance is put back on. A planet has exactly one; a custom
-- instance marks one primary.
local function primary_surface()
    local entry = (storage.topology or {})[instance()]
    if entry and type(entry.primary) == "string" and entry.primary ~= "" then
        return game.surfaces[entry.primary]
    end
    if instance() ~= "space" then
        return game.surfaces[instance()]
    end
    return nil
end

-- The force everything here acts on. It is defined before anything that uses it: a local
-- function is only visible from the line after its own, so one defined below its callers
-- is a nil global to them, and that is a runtime error the game reports and the parser
-- cannot.
local function main_force()
    return game.forces.player or game.forces[1]
end

--------------------------------------------------------------------------------
-- the event queue
--------------------------------------------------------------------------------

-- Append one entry to the in-game event queue.
--
-- Bounded on purpose: a queue nobody reads must not grow without limit.
local function record_event(entry)
    storage.events = storage.events or {}
    storage.events[#storage.events + 1] = entry
    while #storage.events > 64 do
        table.remove(storage.events, 1)
    end
end

-- Record what happened, for the manager to read.
--
-- The mod cannot push: it has no network, and it only runs when the game calls
-- it. So the in-game events it cannot avoid seeing are queued here, and the node
-- drains them over RCON. This is the half of "an interface to Lua" that would
-- otherwise be missing -- without it the manager cannot know a player joined or
-- looked somewhere.
local function note(kind, player, surface, target)
    record_event({
        kind = kind,
        player = player.name,
        surface = surface or (player.surface and player.surface.name) or nil,
        body = storage.body[player.name],
        target = target,
        tick = game.tick,
    })
end

-- Which server this is. Pushed by the node at startup, because the
-- mod-settings.json route is not read on a headless server (see instance()).
--
-- The surfaces are not created here: that is convert's job, and the caller re-runs it.
local function set_instance(id)
    local changed = storage.instance ~= id
    storage.instance = id
    if changed then
        -- Anything recorded against the old identity is meaningless now.
        storage.body = {}
        storage.body_known = {}
        storage.viewing = {}
        storage.routed = {}
        storage.anchored = {}
        storage.hub_sent = {}
        storage.out_seq = 0
        storage.origin_epoch = nil
    end
    log("[" .. MOD .. "] instance=" .. tostring(id))
end

local function normalize_topology(topology)
    local out = {}
    for id, entry in pairs(topology or {}) do
        if type(entry) == "table" then
            local surfaces = {}
            local forms = {}
            if type(entry.surfaces) == "table" then
                for _, item in ipairs(entry.surfaces) do
                    if type(item) == "string" and item ~= "" then
                        surfaces[#surfaces + 1] = item
                    elseif type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
                        surfaces[#surfaces + 1] = item.id
                        forms[#forms + 1] = item
                    end
                end
                table.sort(surfaces)
            end

            out[id] = {
                name = entry.name or id,
                address = entry.address,
                kind = entry.kind,
                editor = entry.editor == true,
                primary = entry.primary,
                surfaces = surfaces,
                forms = forms,
                -- Optional live fields. Stored as sent: the server list shows them, and the
                -- manager can update only these with set_server_status.
                online = entry.online,
                players = entry.players,
                note = entry.note,
            }
        end
    end
    return out
end

local function same_list(a, b)
    a, b = a or {}, b or {}
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Two surface forms are the same when the JSON the game would print is the same. A form is a
-- table with a generation table inside it, so a field-by-field walk here would have to know
-- every option the manager can add; the serializer does not.
local function same_forms(a, b)
    local oka, ja = pcall(function() return helpers.table_to_json(a or {}) end)
    local okb, jb = pcall(function() return helpers.table_to_json(b or {}) end)
    return oka and okb and ja == jb
end

local function same_topology(a, b)
    a, b = a or {}, b or {}
    for id, x in pairs(a) do
        local y = b[id]
        if not y or x.name ~= y.name or x.address ~= y.address or x.kind ~= y.kind
            or (x.editor == true) ~= (y.editor == true)
            or x.primary ~= y.primary
            or x.online ~= y.online
            or x.players ~= y.players
            or x.note ~= y.note
            or not same_list(x.surfaces, y.surfaces)
            or not same_forms(x.forms, y.forms) then
            return false
        end
    end
    for id in pairs(b) do
        if not a[id] then
            return false
        end
    end
    return true
end

-- Replace the whole destination table. Idempotent: sending the same set twice
-- changes nothing, so a retried push is harmless.
local function set_topology(topology)
    -- Which kind of server it is decides whether this one has a surface
    -- to create for it: a planet does, a space server does not.
    storage.topology = normalize_topology(topology)
end

-- Where a player's body is. The manager owns this fact; the mod only obeys it.
local function set_body(name, id)
    storage.body_known = storage.body_known or {}
    if id == nil then
        -- No body at all: forget the location and go back to the fleet default.
        storage.body[name] = nil
        storage.body_known[name] = nil
    elseif id == instance() then
        -- This server is the home. nil is how a home is stored (the join rule reads it as
        -- "here"), but the known flag is what tells it apart from never having been told.
        storage.body[name] = nil
        storage.body_known[name] = true
    else
        storage.body[name] = id
        storage.body_known[name] = true
    end
end

-- Everything the game has told this mod since the last drain, so the manager
-- can act on joins and surface changes it cannot see for itself.
local function drain()
    local events = storage.events or {}
    storage.events = {}
    return events
end

--------------------------------------------------------------------------------
-- one poll's worth of state, for the manager's health board
--------------------------------------------------------------------------------

local function report()
    local force = main_force()
    local viewing = storage.viewing or {}
    local players = {}
    for _, player in pairs(game.connected_players) do
        players[#players + 1] = {
            name = player.name,
            admin = player.admin,
            viewing = viewing[player.name] == true,
            viewing_surface = player.surface and player.surface.name or nil,
            -- Whether this world holds their body. The manager takes a body's home from this
            -- rather than from a player not being in remote view, which any join used to look
            -- like -- and that is what put a body on every server the owner joined.
            has_body = player.character ~= nil,
        }
    end
    local surfaces = {}
    for name, _ in pairs(game.surfaces) do
        -- nauvis exists in every converted save because the homeworld cannot be deleted; it
        -- is stripped to nothing there. It is a surface this server serves only on the
        -- nauvis server, so it is not listed anywhere else.
        if name ~= "nauvis" or instance() == "nauvis" then
            surfaces[#surfaces + 1] = name
        end
    end
    table.sort(surfaces)

    -- Only planets, and only through a pcall: a name that is not a space location --
    -- the space server's own id, for one -- makes the call error, and one bad name here
    -- would take the whole report down with it and leave the manager with no telemetry
    -- at all.
    local unlocked = {}
    for id, entry in pairs(storage.topology or {}) do
        if entry.kind == "planet" then
            local ok, is_unlocked = pcall(function()
                return force.is_space_location_unlocked and force.is_space_location_unlocked(id)
            end)
            if ok and is_unlocked then
                unlocked[#unlocked + 1] = id
            end
        end
    end
    table.sort(unlocked)

    -- The bodies this world *owns*, whoever is connected: the manager takes a body's home from
    -- this rather than from whichever planet a player happened to join first. A save can hold
    -- a character on another planet's surface -- the fleet's saves are copies -- and that
    -- character is not a body here. Claiming it made the manager state a home the character
    -- was not standing on, and the join rule then refused to attach it, which the game does
    -- not recover from.
    local bodies = {}
    local home = instance()
    local owned = owned_surfaces()
    for _, player in pairs(game.players) do
        local character = player.character
        if character and character.valid and character.surface then
            local here
            if home == "space" then
                here = character.surface.platform ~= nil
            else
                here = owned[character.surface.name] == true
            end
            if here then
                bodies[#bodies + 1] = player.name
            end
        end
    end
    table.sort(bodies)

    return {
        instance = instance(),
        tick = game.tick,
        bodies = bodies,
        -- The speed itself, and what it asks for. The manager shows both: the speed is what
        -- game.speed is, the target says how many ticks a second that is.
        speed = game.speed,
        ups_target = game.speed * 60,
        players = players,
        destinations = #destinations(),
        paused = game.tick_paused,
        surfaces = surfaces,
        unlocked = unlocked,
        spawn = storage.spawn_surface,
        foreign = storage.cleared or {},
        foreign_last = storage.foreign_last or 0,
        foreign_swept = storage.foreign_swept or 0,
        schema = storage.schema,
    }
end

return {
    MOD = MOD,
    SCHEMA = SCHEMA,

    ensure_storage = ensure_storage,
    instance = instance,
    known = known,
    empty = empty,
    main_force = main_force,
    destinations = destinations,
    owned_surfaces = owned_surfaces,
    primary_surface = primary_surface,

    record_event = record_event,
    note = note,

    set_instance = set_instance,
    set_topology = set_topology,
    normalize_topology = normalize_topology,
    same_topology = same_topology,
    set_body = set_body,
    drain = drain,

    report = report,
}
