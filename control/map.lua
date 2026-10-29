-- server-connector-mod / control/map.lua
--
-- The server list: one "Servers" button in the mod GUI, and a window that lists the fleet
-- grouped into Planets, Space and Custom. The button is the only control. It is created in
-- the mod-gui button flow, shown in both the normal view and map/remote view, and is never
-- moved or repositioned. A click opens or closes the window; Escape, the close button and a
-- second click all close it. The row for this server says "You are here"; every other row
-- has a Join button. The window is built only when opened, and rebuilt only when the
-- topology or a status field it displays changes.
--
-- Required as "__server-connector-mod__.control.map".

local mod_gui = require("mod-gui")
local state = require("__server-connector-mod__.control.state")
local bus = require("__server-connector-mod__.control.bus")

local BUTTON = "server-connector-open"
local WINDOW = "server-connector-window"
local LIST = "server-connector-list"
local CLOSE = "server-connector-close"
local JOIN = "server-connector-join"
local LEGACY = "server-connector-map"

local function destroy_legacy(player)
    if not player or not player.valid then
        return
    end
    local frame = player.gui.screen[LEGACY]
    if frame then
        frame.destroy()
    end
end

local function destroy_button(player)
    if not player or not player.valid then
        return
    end
    local flow = mod_gui.get_button_flow(player)
    local button = flow and flow[BUTTON]
    if button then
        button.destroy()
    end
end

local function ensure_button(player)
    if not player or not player.valid then
        return
    end
    destroy_legacy(player)

    if not state.known() then
        destroy_button(player)
        local window = player.gui.screen[WINDOW]
        if window then
            window.destroy()
        end
        return
    end

    local flow = mod_gui.get_button_flow(player)
    if flow and not flow[BUTTON] then
        flow.add{
            type = "button",
            name = BUTTON,
            caption = "Servers",
            style = mod_gui.button_style,
        }
    end
end

-- Everything the window shows, in a stable order. A field added to the window must be added
-- here or an open window will keep showing the old value until it is reopened.
local function signature()
    local ids = {}
    for id, entry in pairs(storage.topology or {}) do
        if type(entry) == "table" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)

    local parts = {state.instance()}
    for _, id in ipairs(ids) do
        local entry = storage.topology[id]
        parts[#parts + 1] = table.concat({
            tostring(id),
            tostring(entry.name or id),
            tostring(entry.address or ""),
            tostring(entry.kind or ""),
            tostring(entry.online),
            tostring(entry.players),
            tostring(entry.note or ""),
        }, "\31")
    end
    return table.concat(parts, "\30")
end

local function add_row(pane, id, entry)
    local row = pane.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"

    local name = entry.name or id
    local label = row.add{type = "label", caption = name}
    label.style.horizontally_stretchable = true
    label.style.single_line = true
    label.style.maximal_width = 300
    if entry.note and entry.note ~= "" then
        label.tooltip = name .. "\n" .. entry.note
    else
        label.tooltip = name
    end

    local status
    if entry.online == false then
        status = "Offline"
    elseif type(entry.players) == "number" then
        status = string.format("%d online", entry.players)
    end
    if status then
        row.add{type = "label", caption = status}
    end

    if id == state.instance() then
        row.add{type = "label", caption = "You are here"}
        return
    end

    local button = row.add{
        type = "button",
        name = JOIN,
        caption = "Join",
        tags = {instance = id},
    }
    if not entry.address then
        button.enabled = false
        button.tooltip = "No address yet"
    elseif entry.online == false then
        button.enabled = false
        button.tooltip = "Offline"
    end
end

local function build(player)
    local window = player.gui.screen[WINDOW]
    if window then
        window.destroy()
    end

    local frame = player.gui.screen.add{
        type = "frame",
        name = WINDOW,
        direction = "vertical",
    }
    frame.auto_center = true

    local title = frame.add{type = "flow", direction = "horizontal"}
    title.add{type = "label", caption = "Servers", style = "frame_title"}
    local drag = title.add{type = "empty-widget", style = "draggable_space_header"}
    drag.drag_target = frame
    drag.style.horizontally_stretchable = true
    drag.style.height = 24
    title.add{
        type = "sprite-button",
        name = CLOSE,
        style = "frame_action_button",
        sprite = "utility/close",
    }

    local pane = frame.add{type = "scroll-pane", name = LIST, direction = "vertical"}
    pane.style.maximal_height = 500
    pane.style.minimal_width = 360
    pane.style.maximal_width = 520
    pane.horizontal_scroll_policy = "never"

    local groups = {planets = {}, space = {}, custom = {}}
    for id, entry in pairs(storage.topology or {}) do
        if type(entry) == "table" then
            local bucket = "custom"
            if entry.kind == "planet" then
                bucket = "planets"
            elseif id == "space" or entry.kind == "space" then
                bucket = "space"
            end
            groups[bucket][#groups[bucket] + 1] = {id = id, entry = entry}
        end
    end

    local total = 0
    local function section(caption, rows)
        if #rows == 0 then
            return
        end
        pane.add{type = "label", caption = caption, style = "caption_label"}
        table.sort(rows, function(a, b)
            local an = tostring(a.entry.name or a.id):lower()
            local bn = tostring(b.entry.name or b.id):lower()
            if an ~= bn then
                return an < bn
            end
            return a.id < b.id
        end)
        for _, row in ipairs(rows) do
            add_row(pane, row.id, row.entry)
        end
        total = total + #rows
    end

    section("Planets", groups.planets)
    section("Space", groups.space)
    section("Custom", groups.custom)
    if total == 0 then
        pane.add{type = "label", caption = "No other servers."}
    end

    storage.map_seen = storage.map_seen or {}
    storage.map_seen[player.index] = signature()
    player.opened = frame
end

local function close(player)
    local window = player.gui.screen[WINDOW]
    if window then
        window.destroy()
    end
    if storage.map_seen then
        storage.map_seen[player.index] = nil
    end
end

local function open(player)
    close(player)
    build(player)
    pcall(function()
        bus.push("server_menu_open", {
            instance = state.instance(),
            player = player.name,
            tick = game.tick,
        })
    end)
end

-- Rebuild an already-open window if a field it displays changed. This never opens or
-- creates the window; it only keeps an open one current.
local function refresh(player)
    if not player or not player.valid then
        return
    end
    ensure_button(player)
    if not state.known() then
        return
    end

    local window = player.gui.screen[WINDOW]
    if not window then
        if storage.map_seen then
            storage.map_seen[player.index] = nil
        end
        return
    end

    local sig = signature()
    storage.map_seen = storage.map_seen or {}
    if storage.map_seen[player.index] ~= sig then
        build(player)
    end
end

-- Only players who currently have the window open. If nobody has it open this does nothing.
local function refresh_open()
    if not state.known() then
        return
    end
    for _, player in pairs(game.connected_players) do
        if player.gui.screen[WINDOW] then
            refresh(player)
        end
    end
end

-- The configuration-change path runs for every player in the save, connected or not.
local function refresh_all()
    for _, player in pairs(game.players) do
        local ok, err = pcall(refresh, player)
        if not ok then
            log(string.format("[%s] could not refresh the server menu for %s: %s",
                state.instance(), player.name, tostring(err)))
        end
    end
end

local function tick()
    refresh_open()
end

local function click(event)
    local element = event.element
    if not element or not element.valid then
        return
    end
    local player = game.get_player(event.player_index)
    if not player then
        return
    end

    if element.name == BUTTON then
        if player.gui.screen[WINDOW] then
            close(player)
        else
            open(player)
        end
        return
    end

    if element.name == CLOSE then
        close(player)
        return
    end

    if element.name ~= JOIN then
        return
    end

    local target = element.tags and element.tags.instance
    if type(target) ~= "string" or target == state.instance() then
        return
    end

    local entry = (storage.topology or {})[target]
    if not entry or not entry.address then
        return
    end

    -- The one connect path: tell the manager where the body is going, then connect now.
    state.note("connect", player, nil, target)
    local sent, err = pcall(function()
        player.connect_to_server{address = entry.address, name = entry.name or target}
    end)
    if not sent then
        log(string.format("[%s] could not send %s to %s: %s",
            state.instance(), player.name, target, tostring(err)))
    end
    close(player)
end

-- Escape closes the window because build() makes it player.opened.
local function closed(event)
    if not event or not event.element or event.element.name ~= WINDOW then
        return
    end
    local player = game.get_player(event.player_index)
    if player then
        close(player)
    end
end

return {
    refresh = refresh,
    refresh_all = refresh_all,
    refresh_open = refresh_open,
    tick = tick,
    click = click,
    closed = closed,
    open = open,
    close = close,
}
