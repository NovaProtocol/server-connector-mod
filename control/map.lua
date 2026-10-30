-- server-connector-mod / control/map.lua
--
-- The server list: one "Servers" button in the mod GUI, and a content-sized window split
-- into a sidebar and a detail panel. The sidebar groups the fleet into Planets, Space and
-- Custom; selecting a row rebuilds only the right-hand scroll-pane. The footer carries the
-- only Join button and a Cancel button. The window is built only when opened and rebuilt
-- only when the fields it displays change; the selection is kept in storage per player.
--
-- Required as "__server-connector-mod__.control.map".

local mod_gui = require("mod-gui")
local state = require("__server-connector-mod__.control.state")
local bus = require("__server-connector-mod__.control.bus")

local BUTTON = "server-connector-open"
local WINDOW = "server-connector-window"
local DETAIL = "server-connector-detail"
local DETAIL_SCROLL = "server-connector-detail-scroll"
local LIST = "server-connector-list"
local PLAYERS = "server-connector-players"
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
        sprite.style.stretch_image_to_widget_size = true
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

-- The one status helper. The dot carries the state; the tooltip is the only place the
-- words appear, and a server never heard from is yellow "Unknown", not green.
local function status_of(entry)
    if entry and entry.online == false then
        return {sprite = "utility/status_not_working", text = "Offline"}
    end
    if not entry or not entry.address then
        return {sprite = "utility/status_yellow", text = "No address yet"}
    end
    if entry.online == nil then
        return {sprite = "utility/status_yellow", text = "Unknown"}
    end
    return {sprite = "utility/status_working", text = "Online"}
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

local function sorted_names(names)
    local out = {}
    if type(names) ~= "table" then
        return out
    end
    for _, name in pairs(names) do
        out[#out + 1] = tostring(name)
    end
    table.sort(out)
    return out
end

local function live_players()
    local names = {}
    for _, player in pairs(game.connected_players) do
        names[#names + 1] = player.name
    end
    table.sort(names)
    return names
end

local function info_rows(entry, id, current)
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

    local players = current and #game.connected_players or entry.players
    push("Players", players)

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

    local speed = current and game.speed or entry.game_speed
    if type(speed) == "number" then
        push("Game speed", string.format("%.1fx", speed))
    else
        push("Game speed", nil)
    end

    local tick = current and game.tick or entry.game_tick
    push("Game tick", tick)
    return rows
end

-- LAYOUT: every size in the window comes from these constants. Do not put a number anywhere
-- else in the window code.
local WINDOW_WIDTH = 760
local SIDEBAR_WIDTH = 320
local PAD = 8
local ROW_H = 32
local ICON_CELL = 28
local BUTTON_W = 220
local DOT_CELL = 16
local DOT = 12
local HEADER_PIC = 64
local SOLAR_BTN_SIZE = 44
local MIN_H = 360
local MAX_H = 460
local LABEL_W = 110
local SOLAR_BUTTON = "server-connector-solar"

-- A fixed-size holder. Icons and dots live in one, so a row's height and a column's width
-- come from the cell and not from whatever is inside it. The icon fills the cell's width
-- exactly, so its left edge is the cell's left edge and lines up with the text above it.
local function add_cell(parent, width, height)
    local cell = parent.add{type = "flow", direction = "horizontal"}
    cell.style.width = width
    cell.style.height = height
    cell.style.horizontal_align = "center"
    cell.style.vertical_align = "center"
    return cell
end

local function add_info_table(parent, rows)
    local grid = parent.add{type = "table", column_count = 2}
    grid.style.horizontal_spacing = 16
    grid.style.vertical_spacing = 6
    for _, row in ipairs(rows) do
        local left = add_styled(grid, {type = "label", caption = row.label}, "caption_label")
        left.style.width = LABEL_W
        local right = grid.add{type = "label", caption = row.value}
        right.style.single_line = false
        right.style.maximal_width = 250
        if row.color then
            right.style.font_color = row.color
        end
    end
end

local function add_player_list(parent, names)
    if #names == 0 then
        return
    end
    add_styled(parent, {type = "label", caption = "Players online"}, "caption_label")
    local pane = add_styled(parent, {type = "scroll-pane", name = PLAYERS}, "naked_scroll_pane")
    pane.horizontal_scroll_policy = "never"
    pane.style.maximal_height = 140
    pane.style.horizontally_stretchable = true
    local list = pane.add{type = "flow", direction = "vertical"}
    list.style.vertical_spacing = 2
    for _, name in ipairs(names) do
        list.add{type = "label", caption = name}
    end
end

-- The solar strip. Sprite-buttons centre their own icon, so nothing here positions a
-- picture. Clicking one selects that server when it is part of the fleet; otherwise it is
-- disabled.
local function build_solar(parent, selected)
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
    local strip = parent.add{type = "table", column_count = #valid}
    strip.style.horizontal_spacing = 6
    for _, item in ipairs(valid) do
        local member = (storage.topology or {})[item.name]
        local button = add_styled(strip, {
            type = "sprite-button",
            name = SOLAR_BUTTON,
            sprite = item.path,
            tags = {instance = item.name},
            tooltip = (member and member.name) or item.name,
        }, "slot_button", "button")
        if button then
            button.style.width = SOLAR_BTN_SIZE
            button.style.height = SOLAR_BTN_SIZE
            button.toggled = item.name == selected
            button.enabled = member ~= nil
        end
    end
end

local function build_detail(player, id)
    local window = player.gui.screen[WINDOW]
    local scroll = window and find_child(window, DETAIL_SCROLL)
    if not scroll then
        return
    end
    scroll.clear()

    local entry = (storage.topology or {})[id] or {}
    local full = entry.name or id or "?"
    local current = id == state.instance()
    local status = status_of(entry)

    local content = scroll.add{type = "flow", direction = "vertical"}
    content.style.vertical_spacing = 8
    content.style.horizontally_stretchable = true

    -- Header: [picture][name + kind][dot]. Picture and dot are fixed cells of the same
    -- height as the picture, so the three line up on one centre line.
    local header = content.add{type = "flow", direction = "horizontal"}
    header.style.horizontally_stretchable = true
    header.style.horizontal_spacing = 12
    header.style.vertical_align = "center"

    local pic = add_cell(header, HEADER_PIC, HEADER_PIC)
    local icon = sprite_for(entry, id)
    if icon then
        add_sprite(pic, icon, HEADER_PIC, full)
    end

    local text = header.add{type = "flow", direction = "vertical"}
    text.style.horizontally_stretchable = true
    text.style.vertical_spacing = 0
    text.style.vertical_align = "center"
    text.style.height = HEADER_PIC
    local name_label = add_styled(text, {type = "label", caption = full}, "heading_1_label", "caption_label")
    name_label.style.single_line = true
    name_label.style.maximal_width = 260
    local kind = text.add{type = "label", caption = kind_text(entry)}
    kind.style.font_color = {r = 0.7, g = 0.7, b = 0.7}

    local dot_cell = add_cell(header, DOT_CELL, HEADER_PIC)
    add_sprite(dot_cell, status.sprite, DOT, status.text)

    content.add{type = "line", direction = "horizontal"}
    add_info_table(content, info_rows(entry, id, current))
    add_player_list(content, current and live_players() or sorted_names(entry.player_names))
    build_solar(content, id)
end

-- One sidebar row = exactly three table cells: [icon cell][button][dot cell]. Every row in
-- every section has the same three widths, so the buttons and dots form straight columns.
local function add_sidebar_row(grid, id, entry, selected)
    local status = status_of(entry)
    local full = entry.name or id
    local current = id == state.instance()

    local icon_cell = add_cell(grid, ICON_CELL, ROW_H)
    local icon = sprite_for(entry, id)
    if icon then
        add_sprite(icon_cell, icon, ICON_CELL, full)
    end

    local caption = display_name(entry, id)
    if current then
        caption = caption .. " (Current Location)"
    end
    local button = add_styled(grid, {
        type = "button",
        name = SELECT,
        caption = caption,
        tags = {instance = id},
        tooltip = full,
    }, current and "green_button" or "list_box_item", "confirm_button")
    if button then
        button.style.width = BUTTON_W
        button.style.height = ROW_H
        button.style.horizontal_align = "left"
        button.toggled = id == selected
    end

    local dot_cell = add_cell(grid, DOT_CELL, ROW_H)
    add_sprite(dot_cell, status.sprite, DOT, status.text)
end

-- Returns how many rows it added, so the caller can tell whether anything was shown.
local function add_sidebar_section(list, caption, rows, selected, first)
    if #rows == 0 then
        return 0
    end
    local header = add_styled(list, {type = "label", caption = caption}, "caption_label")
    header.style.top_margin = first and 0 or 6
    local grid = list.add{type = "table", column_count = 3}
    grid.style.horizontal_spacing = 6
    grid.style.vertical_spacing = 4
    for _, row in ipairs(rows) do
        add_sidebar_row(grid, row.id, row.entry, selected)
    end
    return #rows
end

local function build_sidebar(list, player)
    local groups = grouped()
    local selected = storage.map_selected and storage.map_selected[player.index]
    local shown = 0
    shown = shown + add_sidebar_section(list, "Planets", groups.planets, selected, shown == 0)
    shown = shown + add_sidebar_section(list, "Space", groups.space, selected, shown == 0)
    shown = shown + add_sidebar_section(list, "Custom", groups.custom, selected, shown == 0)
    if shown == 0 then
        list.add{type = "label", caption = "No servers."}
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

-- Walks the whole list, so it does not care how deep the buttons sit.
local function update_toggled(player)
    local window = player.gui.screen[WINDOW]
    local list = window and find_child(window, LIST)
    if not list then
        return
    end
    local selected = selected_for(player)
    local function walk(root)
        for _, child in ipairs(root.children or {}) do
            if child.name == SELECT then
                child.toggled = (child.tags and child.tags.instance) == selected
            else
                walk(child)
            end
        end
    end
    walk(list)
end

-- Everything the window shows that the manager can change. The current server's live speed,
-- tick and players are deliberately absent: including them would rebuild the whole window
-- every tick. Player names are included in full so the list stays right past twelve.
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
            table.concat(sorted_names(entry.player_names), "\28"),
            tostring(entry.ups),
            tostring(entry.game_speed),
            tostring(entry.game_tick),
        }, "\31")
    end
    return table.concat(parts, "\30")
end

local function build(player)
    local old = player.gui.screen[WINDOW]
    if old then
        old.destroy()
    end

    local selected = selected_for(player)

    local frame = player.gui.screen.add{type = "frame", name = WINDOW, direction = "vertical"}
    frame.auto_center = true
    frame.style.width = WINDOW_WIDTH

    -- Title bar.
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

    -- Body: two frames with IDENTICAL padding and identical minimal height, so the first
    -- line of each side starts at the same y and the same inset.
    local body = frame.add{type = "flow", direction = "horizontal"}
    body.style.horizontally_stretchable = true
    body.style.vertical_align = "top"
    body.style.horizontal_spacing = 8

    local left = add_styled(body, {type = "frame", direction = "vertical"}, "inside_shallow_frame")
    left.style.width = SIDEBAR_WIDTH
    left.style.minimal_height = MIN_H
    left.style.padding = PAD
    local pane = add_styled(left, {type = "scroll-pane"}, "naked_scroll_pane")
    pane.horizontal_scroll_policy = "never"
    pane.style.maximal_height = MAX_H
    pane.style.horizontally_stretchable = true
    local list = pane.add{type = "flow", name = LIST, direction = "vertical"}
    list.style.horizontally_stretchable = true

    local right = add_styled(body, {type = "frame", name = DETAIL, direction = "vertical"}, "inside_shallow_frame")
    right.style.horizontally_stretchable = true
    right.style.minimal_height = MIN_H
    right.style.padding = PAD
    local scroll = add_styled(right, {type = "scroll-pane", name = DETAIL_SCROLL}, "naked_scroll_pane")
    scroll.horizontal_scroll_policy = "never"
    scroll.style.maximal_height = MAX_H
    scroll.style.horizontally_stretchable = true

    build_sidebar(list, player)
    build_detail(player, selected)

    -- Footer.
    local footer = frame.add{type = "flow", direction = "horizontal"}
    footer.style.horizontally_stretchable = true
    footer.style.horizontal_align = "right"
    footer.style.horizontal_spacing = 8

    local cancel = add_styled(footer, {type = "button", name = CANCEL, caption = "Cancel"}, "back_button", "button")
    if cancel then
        cancel.style.width = 100
    end
    local join = add_styled(footer, {type = "button", name = JOIN, caption = "Join"}, "confirm_button", "button")
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

    if element.name == SELECT or element.name == SOLAR_BUTTON then
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
