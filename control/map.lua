-- server-connector-mod / control/map.lua
--
-- The server map: one button per other instance, shown while the map is open. This replaces
-- the old trigger, which routed a player when they looked at a fake copy of another planet's
-- surface. There are no copies now; a click is an explicit "send me there".
--
-- Required as "__server-connector-mod__.control.map".

local state = require("__server-connector-mod__.control.state")

local FRAME = "server-connector-map"

-- The last topology a player's map was built from. A module table, not storage: GUIs are not
-- saved, so neither is what they were built from.
local seen = {}

-- The map is the chart view. There is no event for opening it (render_mode is read-only), so
-- this is asked when the list is refreshed, and the frame is shown or hidden.
local function on_map(player)
    -- A remote viewer is looking at the world through the map-like controller; the server
    -- buttons are the way out of it, so they have to be visible there too.
    if player.controller_type == defines.controllers.remote then
        return true
    end

    local modes = defines.render_mode or {}
    if modes.chart ~= nil then
        return player.render_mode == modes.chart
    end
    if modes.game ~= nil then
        return player.render_mode ~= modes.game
    end
    -- A build that does not name the modes: show it rather than never show it.
    return true
end

local function signature()
    local parts = {}
    for _, destination in ipairs(state.destinations()) do
        parts[#parts + 1] = destination.id .. "=" .. destination.name .. "@" .. destination.address
    end
    return table.concat(parts, ",")
end

local function destroy(player)
    local frame = player.gui.screen[FRAME]
    if frame then
        frame.destroy()
    end
end

local function build(player)
    destroy(player)

    -- No caption: a frame with a title bar is a window the player can drag. This is a fixed
    -- strip pinned to the top of the screen.
    local frame = player.gui.screen.add{
        type = "frame",
        name = FRAME,
        direction = "vertical",
    }
    frame.location = {x = 16, y = 0}
    frame.add{type = "label", caption = "Servers"}

    local flow = frame.add{type = "flow", direction = "horizontal"}
    local count = 0

    for _, destination in ipairs(state.destinations()) do
        -- The server you are already on is not a place to send yourself.
        if destination.id ~= state.instance() then
            flow.add{
                type = "button",
                name = "server-" .. destination.id,
                caption = destination.name,
                tags = {instance = destination.id},
            }
            count = count + 1
        end
    end

    if count == 0 then
        flow.add{type = "label", caption = "No other servers."}
    end

    seen[player.index] = signature()
end

-- Build, rebuild or show/hide one player's map.
local function refresh(player)
    if not player or not player.valid then
        return
    end

    if not state.known() then
        destroy(player)
        return
    end

    local frame = player.gui.screen[FRAME]
    if not frame or seen[player.index] ~= signature() then
        build(player)
        frame = player.gui.screen[FRAME]
    end

    if frame then
        frame.visible = on_map(player)
    end
end

-- The map does not change on its own; it changes when a player opens the map.
local function tick()
    if not state.known() then
        return
    end

    for _, player in pairs(game.connected_players) do
        refresh(player)
    end
end

-- A button was clicked. Connect, and tell the manager where the body is going.
local function click(event)
    local element = event.element
    if not element or not element.valid then
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

    local player = game.get_player(event.player_index)
    if not player then
        return
    end

    -- Tell the manager where the body is going, then connect now. The manager's push follows;
    -- a target that has not heard yet shows the remote view for a moment, which is a working
    -- button, where a held connect looks like a dead one.
    state.note("connect", player, nil, target)
    local sent, err = pcall(function()
        player.connect_to_server{address = entry.address, name = entry.name or target}
    end)
    if not sent then
        log(string.format("[%s] could not send %s to %s: %s",
            state.instance(), player.name, target, tostring(err)))
    end
end

return {
    refresh = refresh,
    tick = tick,
    click = click,
}
