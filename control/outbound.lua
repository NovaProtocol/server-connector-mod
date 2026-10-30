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

-- The transport lives in bus.lua so that platforms.lua can push without requiring this
-- module, which requires it. The names stay exported here: every caller outside this file
-- keeps using outbound.push, and the cycle has no way back.
local push = bus.push
local epoch = bus.epoch

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
    tick_research = tick_research,
    tick_heartbeat = tick_heartbeat,
    epoch = epoch,
}
