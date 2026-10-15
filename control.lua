-- server-connector-mod: routing for a Factorio world split across servers.
--
-- This server handles exactly one planet (or the space platforms). Everything
-- outside it -- where each player's body is, and what the other servers are --
-- belongs to the manager, because a mod cannot see past its own save.
--
-- Two channels carry that in:
--
--   identity  a startup setting, written into config/mod-settings.json by the
--             manager before launch. Known from on_init, survives restarts, no
--             race with a server that has not finished starting.
--   topology  remote.call("server-connector", "set_topology", ...) over RCON
--             once this server is up. Runtime, so the set can change without
--             restarting anything. Absent means "no destinations", never a
--             guess at an address.
--
-- Nothing here is a script command, so using it never stops achievements.

local MOD = "server-connector"
local SCHEMA = 1

local GUI_TOP_BUTTON = MOD .. "-open"
local GUI_FRAME = MOD .. "-menu"

--------------------------------------------------------------------------------
-- storage
--------------------------------------------------------------------------------

local function ensure_storage()
    storage.schema = storage.schema or SCHEMA
    storage.topology = storage.topology or {}   -- instance id -> {name, address}
    storage.body = storage.body or {}           -- player name -> instance id
    storage.viewing = storage.viewing or {}     -- player name -> true, for §4.1
end

--------------------------------------------------------------------------------
-- identity and topology
--------------------------------------------------------------------------------

-- Identity is a property of the container. The startup setting is the intended
-- carrier, but a headless server does not import mod-settings.json: it compiles
-- mod-settings.dat from defaults and ignores the .json beside it, so the setting
-- never arrives. The manager therefore pushes the instance over the same RCON
-- channel as the topology, and the setting is kept as the fallback for anyone
-- who sets it by hand in the game.
local function instance()
    if storage and storage.instance then
        return storage.instance
    end
    local setting = settings.startup[MOD .. "-instance"]
    return setting and setting.value or "unconfigured"
end

local function destinations()
    local out = {}
    for id, entry in pairs(storage.topology) do
        if id ~= instance() and type(entry) == "table" and entry.address then
            out[#out + 1] = {id = id, name = entry.name or id, address = entry.address}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--------------------------------------------------------------------------------
-- the join rule
--------------------------------------------------------------------------------

-- The body exists on exactly one server. On every other one the player is a
-- remote viewer: the game's own remote controller, which already cannot move,
-- cannot take or change items, and still lets blueprints place as ghosts.
--
-- The remote controller is an *overlay* on a physical one, so leaving it returns
-- the player to that -- and a bodyless player's physical controller is god mode.
-- toggle_menu_leaves_remote_view = false is therefore load-bearing, not a
-- nicety: without it the spectator can drop into free build and generate chunks.
local function apply_join_rule(player)
    local here = storage.body[player.name]
    if not here or here == instance() then
        storage.viewing[player.name] = nil
        player.toggle_menu_leaves_remote_view = true
        player.disable_space_map = false
        return
    end

    storage.viewing[player.name] = true
    player.set_controller{
        type = defines.controllers.remote,
        surface = game.surfaces[instance()] or player.physical_surface,
        position = player.physical_position,
    }
    player.toggle_menu_leaves_remote_view = false
    player.disable_space_map = true
    player.print("Your body is on another server. Looking only: no walking, no items. Blueprints place as ghosts.")
end

--------------------------------------------------------------------------------
-- the menu
--------------------------------------------------------------------------------

local function close_menu(player)
    local frame = player.gui.screen[GUI_FRAME]
    if frame and frame.valid then
        frame.destroy()
    end
end

local function build_menu(player)
    close_menu(player)

    local frame = player.gui.screen.add{
        type = "frame",
        name = GUI_FRAME,
        direction = "vertical",
        caption = "Travel",
    }
    frame.auto_center = true

    frame.add{
        type = "label",
        caption = "This server is " .. instance() .. ". Your body is on " ..
            (storage.body[player.name] or "an unknown server") .. ".",
    }

    local list = destinations()
    if #list == 0 then
        -- No topology yet. Say so plainly rather than offering nothing.
        frame.add{
            type = "label",
            caption = "No destinations configured yet. The manager has not sent the topology.",
        }
    else
        for _, destination in ipairs(list) do
            local row = frame.add{type = "flow", name = MOD .. "-row-" .. destination.id, direction = "horizontal"}
            row.add{
                type = "button",
                name = MOD .. "-go-" .. destination.id,
                caption = destination.name,
                style = "button",
            }
            row.add{type = "label", caption = destination.address}
        end
    end

    frame.add{type = "button", name = MOD .. "-close", caption = "Close"}
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

local function on_init()
    ensure_storage()
    log("[" .. MOD .. "] instance=" .. instance())
end

script.on_init(on_init)

script.on_configuration_changed(function(data)
    ensure_storage()
    storage.schema = SCHEMA
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    local player = game.get_player(event.player_index)
    if player then
        apply_join_rule(player)
        build_menu(player) -- rebuild so the caption reflects the current topology
    end
end)

script.on_event(defines.events.on_player_created, function(event)
    local player = game.get_player(event.player_index)
    if player and not player.gui.top[GUI_TOP_BUTTON] then
        player.gui.top.add{type = "button", name = GUI_TOP_BUTTON, caption = "Travel"}
    end
end)

script.on_event(defines.events.on_gui_click, function(event)
    local element = event.element
    if not element or not element.valid then
        return
    end

    local player = game.get_player(event.player_index)
    if not player then
        return
    end

    if element.name == GUI_TOP_BUTTON then
        build_menu(player)
        return
    end

    if element.name == MOD .. "-close" then
        close_menu(player)
        return
    end

    local target = element.name:match("^" .. MOD .. "%-go%-(.+)$")
    if target and storage.topology[target] then
        local entry = storage.topology[target]
        -- The address must be the address a *client* dials. Pointing a player at
        -- an RCON port produces a prompt that looks right and a client that sits
        -- at "connecting" forever, with nothing logged anywhere.
        player.connect_to_server{address = entry.address, name = entry.name or target}
        close_menu(player)
    end
end)

--------------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------------

commands.add_command(
    MOD .. "-travel",
    "Open the travel menu.",
    function(event)
        local player = event.player_index and game.get_player(event.player_index)
        if player then
            build_menu(player)
        elseif rcon then
            rcon.print("run this from in-game, or use remote.call('" .. MOD .. "', 'open_menu', <player>)")
        end
    end
)

commands.add_command(
    MOD .. "-status",
    "Report this server's identity, topology size, and connected players as JSON.",
    function(event)
        local text = helpers.table_to_json(remote.call(MOD, "report"))
        if event.player_index then
            local player = game.get_player(event.player_index)
            if player then
                player.print(text)
                return
            end
        end
        if rcon then
            rcon.print(text)
        end
    end
)

--------------------------------------------------------------------------------
-- what the manager drives over RCON
--------------------------------------------------------------------------------

remote.add_interface(MOD, {
    -- Which server this is. Pushed by the manager at startup, because the
    -- mod-settings.json route is not read on a headless server (see instance()).
    set_instance = function(id)
        ensure_storage()
        storage.instance = id
        storage.body = storage.body or {}
        -- Anything recorded against the old identity is meaningless now.
        storage.body = {}
        log("[" .. MOD .. "] instance=" .. tostring(id))
        return {instance = instance()}
    end,

    -- Replace the whole destination table. Idempotent: sending the same set
    -- twice changes nothing, so a retried push is harmless.
    set_topology = function(topology)
        ensure_storage()
        storage.topology = {}
        for id, entry in pairs(topology or {}) do
            if type(entry) == "table" and entry.address then
                storage.topology[id] = {name = entry.name or id, address = entry.address}
            end
        end
        -- Refresh any open menu so it shows the new set immediately.
        for _, player in pairs(game.connected_players) do
            if player.gui.screen[GUI_FRAME] then
                build_menu(player)
            end
        end
        return {instance = instance(), destinations = #destinations()}
    end,

    -- Where a player's body is. The manager owns this fact; the mod only obeys it.
    set_body_location = function(name, id)
        ensure_storage()
        if id == nil or id == instance() then
            storage.body[name] = nil
        else
            storage.body[name] = id
        end
        local player = game.get_player(name)
        if player then
            apply_join_rule(player)
        end
        return {name = name, body = storage.body[name] or instance()}
    end,

    open_menu = function(name)
        local player = game.get_player(name)
        if not player then
            return {error = "no player named " .. tostring(name) .. " on this server"}
        end
        build_menu(player)
        return {ok = true}
    end,

    -- One poll's worth of state, for the manager's health page.
    report = function()
        local players = {}
        for _, player in pairs(game.connected_players) do
            players[#players + 1] = {
                name = player.name,
                admin = player.admin,
                viewing = storage.viewing[player.name] == true,
            }
        end
        return {
            instance = instance(),
            tick = game.tick,
            ups_target = game.speed * 60,
            players = players,
            destinations = #destinations(),
            schema = storage.schema,
        }
    end,
})
