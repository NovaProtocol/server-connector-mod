-- server-connector-mod / control/map.lua
--
-- The server list: one "Servers" button in the mod GUI, and a fixed 780x540 window split
-- into a sidebar and a detail panel. The sidebar groups the fleet into Planets, Space and
-- Custom; selecting a row rebuilds only the right-hand panel. The footer carries the only
-- Join button and a Cancel button. The window is built only when opened and rebuilt only
-- when the fields it displays change; the selection is kept in storage per player.
--
-- Required as "__server-connector-mod__.control.map".

local mod_gui = require("mod-gui")
local state = require("__server-connector-mod__.control.state")
local bus = require("__server-connector-mod__.control.bus")

local BUTTON = "server-connector-open"
local WINDOW = "server-connector-window"
local DETAIL = "server-connector-detail"
local SELECT = "server-connector-select"
local CLOSE = "server-connector-close"
local CANCEL = "server-connector-cancel"
local JOIN = "server-connector-join"
local LEGACY = "server-connector-map"

local SOLAR = {"nauvis", "vulcanus", "gleba", "fulgora", "aquilo", "solar-system-edge", "shattered-planet"}

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

-- A style name is not a runtime-checked value; an unknown one errors when the element is
-- added. Try the named style, then the documented fallback, then no style, so one missing
-- style cannot take the whole window down.
local function add_styled(parent, props, style, fallback)
    local function attempt(name)
        local copy = {}
        for key, value in pairs(props) do
            copy[key] = value
        end
        if name then
            copy.style = name
        end
        local ok, element = pcall(function() return parent.add(copy) end)
        if ok then
            return element
        end
        return nil
    end

    local element = attempt(style)
    if not element and fallback then
        element = attempt(fallback)
    end
    if not element then
        element = attempt(nil)
    end
    return element
end

local function valid_sprite(path)
    if type(path) ~= "string" then
        return false
    end
    if not helpers or type(helpers.is_valid_sprite_path) ~= "function" then
        return false
    end
    local ok, valid = pcall(helpers.is_valid_sprite_path, path)
    return ok and valid == true
end

local function add_sprite(parent, path, size, tooltip)
    if valid_sprite(path) then
        local sprite = parent.add{type = "sprite", sprite = path}
        sprite.style.width = size
        sprite.style.height = size
        if tooltip then
            sprite.tooltip = tooltip
        end
        return sprite
    end
    local empty = parent.add{type = "empty-widget"}
    empty.style.width = size
    empty.style.height = size
    if tooltip then
        empty.tooltip = tooltip
    end
    return empty
end

local function add_close(parent)
    if valid_sprite("utility/close") then
        return add_styled(parent, {
            type = "sprite-button",
            name = CLOSE,
            sprite = "utility/close",
        }, "frame_action_button")
    end
    return add_styled(parent, {
        type = "button",
        name = CLOSE,
        caption = "X",
    }, "frame_action_button", "button")
end

local function find_child(root, name)
    if not root then
        return nil
    end
    for _, child in ipairs(root.children or {}) do
        if child.name == name then
            return child
        end
        local found = find_child(child, name)
        if found then
            return found
        end
    end
    return nil
end

local function find_children(root, name)
    local out = {}
    local function walk(node)
        for _, child in ipairs(node.children or {}) do
            if child.name == name then
                out[#out + 1] = child
            end
            walk(child)
        end
    end
    if root then
        walk(root)
    end
    return out
end

local function sorted_ids()
    local ids = {}
    for id, entry in pairs(storage.topology or {}) do
        if type(entry) == "table" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        local an = tostring((storage.topology[a] and storage.topology[a].name) or a):lower()
        local bn = tostring((storage.topology[b] and storage.topology[b].name) or b):lower()
        if an ~= bn then
            return an < bn
        end
        return a < b
    end)
    return ids
end

local function bucket_of(id, entry)
    if entry.kind == "planet" then
        return "planets"
    end
    if id == "space" or entry.kind == "space" then
        return "space"
    end
    return "custom"
end

local function grouped()
    local groups = {planets = {}, space = {}, custom = {}}
    for _, id in ipairs(sorted_ids()) do
        local entry = storage.topology[id]
        groups[bucket_of(id, entry)][#groups[bucket_of(id, entry)] + 1] = {id = id, entry = entry}
    end
    return groups
end

local function display_name(entry, id)
    local full = (entry and entry.name) or id or "?"
    local caption = full:gsub(" Server$", "")
    if caption == "" then
        return full
    end
    return caption
end

local function sprite_for(entry, id)
    if not entry then
        return nil
    end
    if entry.kind == "planet" then
        return "space-location/" .. id
    end
    if id == "space" or entry.kind == "space" then
        return "space-location/solar-system-edge"
    end
    return nil
end

local function status_sprite(entry)
    if not entry.address then
        return "utility/status_yellow"
    end
    if entry.online == false then
        return "utility/status_not_working"
    end
    return "utility/status_working"
end

local function kind_text(entry)
    if entry.kind == "planet" then
        return "Planet server"
    end
    if entry.kind == "space" then
        return "Space server"
    end
    return "Custom server"
end

local function status_text(entry)
    if entry.online == nil then
        return "Unknown"
    end
    if entry.online == false then
        return "Offline"
    end
    return "Online"
end

local function status_color(entry)
    if entry.online == nil then
        return {r = 0.7, g = 0.7, b = 0.7}
    end
    if entry.online == false then
        return {r = 1, g = 0.4, b = 0.4}
    end
    return {r = 0.55, g = 0.9, b = 0.45}
end

local function format_uptime(seconds)
    local total = math.floor(tonumber(seconds) or 0)
    local days = math.floor(total / 86400)
    local hours = math.floor((total % 86400) / 3600)
    local mins = math.floor((total % 3600) / 60)
    if days > 0 then
        return string.format("%dd %dh %dm", days, hours, mins)
    end
    if hours > 0 then
        return string.format("%dh %dm", hours, mins)
    end
    return string.format("%dm", mins)
end

local function player_names_text(names)
    if type(names) ~= "table" or #names == 0 then
        return nil
    end
    local shown = {}
    local limit = math.min(#names, 12)
    for index = 1, limit do
        shown[index] = tostring(names[index])
    end
    local text = table.concat(shown, ", ")
    if #names > 12 then
        text = text .. " and " .. tostring(#names - 12) .. " more"
    end
    return text
end

local function info_rows(entry, id)
    local rows = {}
    local function push(label, value, color)
        rows[#rows + 1] = {
            label = label,
            value = value == nil and "—" or tostring(value),
            color = color,
        }
    end

    local address = entry.address
    if storage.hide_addresses == true then
        address = "hidden"
    end
    push("Address", address)
    push("Server id", id)

    local players = entry.players
    local players_value = players ~= nil and (tostring(players) .. " online") or nil
    local names = player_names_text(entry.player_names)
    if names then
        players_value = (players_value or "—") .. "\n" .. names
    end
    push("Players", players_value)

    if type(entry.ups) == "number" then
        local color
        if entry.ups < 30 then
            color = {r = 1, g = 0.4, b = 0.4}
        elseif entry.ups < 55 then
            color = {r = 1, g = 0.9, b = 0.2}
        end
        push("UPS", string.format("%.1f", entry.ups), color)
    else
        push("UPS", nil)
    end

    push("Version", entry.version)
    if type(entry.uptime_seconds) == "number" then
        push("Uptime", format_uptime(entry.uptime_seconds))
    else
        push("Uptime", nil)
    end
    push("Description", entry.description or entry.note)
    return rows
end

local function live_rows()
    return {
        {label = "Game tick", value = tostring(game.tick)},
        {label = "Game speed", value = tostring(game.speed)},
        {label = "Connected", value = tostring(#game.connected_players)},
    }
end

local function add_info_table(parent, rows)
    local grid = parent.add{type = "table", column_count = 2}
    grid.style.column_alignments[1] = "left"
    grid.style.horizontal_spacing = 16
    grid.style.vertical_spacing = 6

    for _, row in ipairs(rows) do
        local left = add_styled(grid, {type = "label", caption = row.label}, "caption_label")
        if left then
            left.style.width = 140
        end
        local right = grid.add{type = "label", caption = row.value}
        right.style.single_line = false
        right.style.maximal_width = 420
        if row.color then
            right.style.font_color = row.color
        end
    end
end

local function build_solar(parent, id)
    local valid = {}
    for _, name in ipairs(SOLAR) do
        local path = "space-location/" .. name
        if valid_sprite(path) then
            valid[#valid + 1] = {name = name, path = path}
        end
    end
    if #valid < 2 then
        return
    end

    parent.add{type = "line", direction = "horizontal"}
    add_styled(parent, {type = "label", caption = "Solar system"}, "caption_label")
    local flow = parent.add{type = "flow", direction = "horizontal"}
    flow.style.horizontal_spacing = 6
    for _, item in ipairs(valid) do
        local style = item.name == id and "inside_deep_frame" or "inside_shallow_frame"
        local frame = add_styled(flow, {type = "frame"}, style)
        add_sprite(frame, item.path, 40, item.name)
    end
end

local function build_detail(player, id)
    local window = player.gui.screen[WINDOW]
    local container = window and find_child(window, DETAIL)
    if not container then
        return
    end
    container.clear()

    local entry = (storage.topology or {})[id] or {}
    local full = entry.name or id or "?"
    local current = id == state.instance()

    local header = container.add{type = "flow", direction = "horizontal"}
    header.style.vertical_align = "center"
    header.style.horizontal_spacing = 12

    local icon = sprite_for(entry, id)
    if icon then
        add_sprite(header, icon, 96, full)
    else
        local empty = header.add{type = "empty-widget"}
        empty.style.width = 96
        empty.style.height = 96
    end

    local text = header.add{type = "flow", direction = "vertical"}
    add_styled(text, {type = "label", caption = full}, "heading_1_label", "caption_label")
    local kind = text.add{type = "label", caption = kind_text(entry)}
    kind.style.font_color = {r = 0.7, g = 0.7, b = 0.7}

    local stretch = header.add{type = "empty-widget"}
    stretch.style.horizontally_stretchable = true

    local status = header.add{type = "label", caption = status_text(entry)}
    status.style.font_color = status_color(entry)

    container.add{type = "line", direction = "horizontal"}
    add_info_table(container, info_rows(entry, id))
    if current then
        add_info_table(container, live_rows())
    end
    build_solar(container, id)
end

local function add_sidebar_row(pane, id, entry, selected)
    local row = pane.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"

    local icon = sprite_for(entry, id)
    if icon then
        add_sprite(row, icon, 24, entry.name or id)
    else
        local empty = row.add{type = "empty-widget"}
        empty.style.width = 24
        empty.style.height = 24
    end

    local full = entry.name or id
    local button = add_styled(row, {
        type = "button",
        name = SELECT,
        caption = display_name(entry, id),
        tags = {instance = id},
    }, "list_box_item", "button")
    if button then
        button.style.horizontally_stretchable = true
        button.style.height = 36
        button.style.horizontal_align = "left"
        button.toggled = id == selected
        button.tooltip = full
    end

    if id == state.instance() then
        local you = row.add{type = "label", caption = "(you)"}
        you.style.font_color = {r = 0.55, g = 0.9, b = 0.45}
    end

    add_sprite(row, status_sprite(entry), 12)
end

local function build_sidebar(pane, player)
    local groups = grouped()
    local selected = storage.map_selected and storage.map_selected[player.index]
    local total = 0

    local function section(caption, rows)
        if #rows == 0 then
            return
        end
        local header = add_styled(pane, {type = "label", caption = caption}, "caption_label")
        if header then
            header.style.top_margin = 4
        end
        for _, row in ipairs(rows) do
            add_sidebar_row(pane, row.id, row.entry, selected)
        end
        total = total + #rows
    end

    section("Planets", groups.planets)
    section("Space", groups.space)
    section("Custom", groups.custom)
    if total == 0 then
        pane.add{type = "label", caption = "No servers."}
    end
end

local function select_initial(player)
    storage.map_selected = storage.map_selected or {}
    local stored = storage.map_selected[player.index]
    if stored then
        for _, destination in ipairs(state.destinations()) do
            if destination.id == stored then
                return stored
            end
        end
    end
    local instance = state.instance()
    if instance and instance ~= "" then
        return instance
    end
    local ids = sorted_ids()
    return ids[1]
end

local function selected_for(player)
    storage.map_selected = storage.map_selected or {}
    local id = storage.map_selected[player.index]
    if not id then
        id = select_initial(player)
        storage.map_selected[player.index] = id
    end
    return id
end

local function update_join(player)
    local window = player.gui.screen[WINDOW]
    local join = window and find_child(window, JOIN)
    if not join then
        return
    end

    local id = selected_for(player)
    local entry = id and (storage.topology or {})[id] or nil
    local full = (entry and (entry.name or id)) or id or "?"
    local enabled = true
    local tooltip = "Connect to " .. full

    if id == state.instance() then
        enabled = false
        tooltip = "You are already on this server"
    elseif not entry or not entry.address then
        enabled = false
        tooltip = "No address yet"
    elseif entry.online == false then
        enabled = false
        tooltip = "Server is offline"
    end

    join.enabled = enabled
    join.tooltip = tooltip
end

local function update_toggled(player)
    local window = player.gui.screen[WINDOW]
    if not window then
        return
    end
    local selected = selected_for(player)
    for _, button in ipairs(find_children(window, SELECT)) do
        local id = button.tags and button.tags.instance
        button.toggled = id == selected
    end
end

-- Everything the window shows that the manager can change. The current server's live rows
-- (tick, speed, connected) are deliberately absent: including them would rebuild the whole
-- window every tick. Uptime is bucketed to the minute for the same reason.
local function signature()
    local parts = {tostring(state.instance()), tostring(storage.hide_addresses)}
    for _, id in ipairs(sorted_ids()) do
        local entry = storage.topology[id]
        parts[#parts + 1] = table.concat({
            tostring(id),
            tostring(entry.name or id),
            tostring(entry.kind or ""),
            tostring(entry.address or ""),
            tostring(entry.online),
            tostring(entry.players),
            tostring(player_names_text(entry.player_names) or ""),
            tostring(entry.ups),
            tostring(entry.version),
            tostring(math.floor((tonumber(entry.uptime_seconds) or 0) / 60)),
            tostring(entry.description or entry.note or ""),
        }, "\31")
    end
    return table.concat(parts, "\30")
end

local function build(player)
    local window = player.gui.screen[WINDOW]
    if window then
        window.destroy()
    end

    local selected = selected_for(player)

    local frame = player.gui.screen.add{
        type = "frame",
        name = WINDOW,
        direction = "vertical",
    }
    frame.auto_center = true
    frame.style.width = 780
    frame.style.height = 540

    local title = frame.add{type = "flow", direction = "horizontal"}
    local title_label = add_styled(title, {type = "label", caption = "Servers"}, "frame_title")
    if title_label then
        title_label.ignored_by_interaction = true
    end
    local drag = add_styled(title, {type = "empty-widget"}, "draggable_space_header")
    if drag then
        drag.drag_target = frame
        drag.style.horizontally_stretchable = true
        drag.style.height = 24
        drag.ignored_by_interaction = true
    end
    add_close(title)

    local body = frame.add{type = "flow", direction = "horizontal"}
    body.style.horizontally_stretchable = true
    body.style.vertically_stretchable = true
    body.style.horizontal_spacing = 8

    local left = add_styled(body, {type = "frame"}, "inside_shallow_frame")
    left.style.width = 250
    left.style.vertically_stretchable = true
    local pane = left.add{type = "scroll-pane", direction = "vertical"}
    pane.horizontal_scroll_policy = "never"
    pane.style.vertically_stretchable = true

    local right = add_styled(body, {
        type = "frame",
        name = DETAIL,
        direction = "vertical",
    }, "inside_shallow_frame_with_padding")
    right.style.horizontally_stretchable = true
    right.style.vertically_stretchable = true

    build_sidebar(pane, player)
    build_detail(player, selected)

    local footer = frame.add{type = "flow", direction = "horizontal"}
    footer.style.horizontally_stretchable = true
    footer.style.horizontal_align = "right"
    footer.style.horizontal_spacing = 8

    local stretch = footer.add{type = "empty-widget"}
    stretch.style.horizontally_stretchable = true

    local cancel = add_styled(footer, {
        type = "button",
        name = CANCEL,
        caption = "Cancel",
    }, "back_button", "button")
    if cancel then
        cancel.style.width = 100
    end
    local join = add_styled(footer, {
        type = "button",
        name = JOIN,
        caption = "Join",
    }, "confirm_button", "button")
    if join then
        join.style.width = 100
    end

    update_join(player)

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
    storage.map_selected = storage.map_selected or {}
    storage.map_selected[player.index] = select_initial(player)
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
-- creates the window; the selection is preserved.
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

    if element.name == CLOSE or element.name == CANCEL then
        close(player)
        return
    end

    if element.name == SELECT then
        local id = element.tags and element.tags.instance
        if type(id) ~= "string" or not (storage.topology or {})[id] then
            return
        end
        storage.map_selected = storage.map_selected or {}
        storage.map_selected[player.index] = id
        update_toggled(player)
        build_detail(player, id)
        update_join(player)
        return
    end

    if element.name ~= JOIN then
        return
    end

    local id = selected_for(player)
    if not id or id == state.instance() then
        return
    end
    local entry = (storage.topology or {})[id]
    if not entry or not entry.address or entry.online == false then
        return
    end

    -- The one connect path: tell the manager where the body is going, then connect now.
    state.note("connect", player, nil, id)
    local sent, err = pcall(function()
        player.connect_to_server{address = entry.address, name = entry.name or id}
    end)
    if not sent then
        log(string.format("[%s] could not send %s to %s: %s",
            state.instance(), player.name, id, tostring(err)))
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
