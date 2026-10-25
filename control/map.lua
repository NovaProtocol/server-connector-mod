-- server-connector-mod / control/map.lua
--
-- The server map: one button per other instance, shown while the map is open. This replaces
-- the old trigger, which routed a player when they looked at a fake copy of another planet's
-- surface. There are no copies now; a click is an explicit "send me there".
--
-- Required as "__server-connector-mod__.control.map".

local state = require("__server-connector-mod__.control.state")

local FRAME = "server-connector-map"

-- The topology a player's map was built from is kept in storage, keyed by name. A module
-- table is not saved: a joining client starts with an empty one on every map load and would
-- rebuild the GUI while the server, whose Lua state persists, would not. That is two extra
-- builds on the client, and the custom-GUI element counters in the desync report.

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

local function build(player, sig)
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

    storage.map_seen = storage.map_seen or {}
    storage.map_seen[player.name] = sig
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

    local sig = signature()
    local frame = player.gui.screen[FRAME]
    local previous = storage.map_seen and storage.map_seen[player.name]
    if not frame or previous ~= sig then
        build(player, sig)
        frame = player.gui.screen[FRAME]
    end

    if frame then
        -- Always visible. The server's view of the client's render_mode is not reliable
        -- enough to gate the strip: a wrong reading hides the only way to change servers.
        frame.visible = true
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
