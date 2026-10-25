package.preload["__server-connector-mod__.control.state"] = function()
    return {
        known = function() return true end,
        instance = function() return "vulcanus" end,
        main_force = function() return { platforms = {} } end,
        primary_surface = function() return { name = "vulcanus" } end,
    }
end

package.preload["__server-connector-mod__.control.platform_api"] = function()
    return {}
end

local pushed = nil
package.preload["__server-connector-mod__.control.outbound"] = function()
    return {
        push = function(kind, payload)
            pushed = { kind = kind, payload = payload }
        end,
    }
end

storage = {}
game = {
    tick = 100,
    get_player = function() return { name = "ProjectAlpha" } end,
}
defines = { logistic_member_index = { rocket_silo_rocket = 1 } }
log = function() end

local platforms = dofile("control/platforms.lua")

local removed = false
local filters = { { name = "space-platform-starter-pack", count = 1 } }
local section = {
    filters = filters,
    set_filter = function(self, index, value)
        if value == nil then
            removed = true
            self.filters[index] = nil
        end
    end,
}
local silo = {
    valid = true,
    name = "rocket-silo",
    surface = { name = "vulcanus" },
    get_logistic_point = function()
        return { sections = { section } }
    end,
}

platforms.move_launch_request({ entity = silo, player_index = 1 })

assert(removed, "the starter-pack filter was not removed from the local silo")
assert(pushed, "the manager was not notified")
assert(pushed.kind == "platform_launch_request", "wrong event: " .. tostring(pushed.kind))
assert(pushed.payload.surface == "vulcanus", "wrong source surface")
assert(pushed.payload.player == "ProjectAlpha", "the player was not identified")

-- The production server queues the request in its own silo.
local queued = false
local queued_section = {
    filters = {},
    set_filter = function(self, index, value)
        queued = value and value.name == "space-platform-starter-pack"
        self.filters[index] = value
    end,
}
local main_silo = {
    valid = true,
    unit_number = 42,
    get_logistic_point = function()
        return { sections = { queued_section } }
    end,
}
local main = {
    name = "nauvis",
    find_entities_filtered = function() return { main_silo } end,
}
package.preload["__server-connector-mod__.control.state"] = function()
    return {
        known = function() return true end,
        instance = function() return "vulcanus" end,
        main_force = function() return { platforms = {} } end,
        primary_surface = function() return main end,
    }
end
package.loaded["__server-connector-mod__.control.state"] = nil
platforms = dofile("control/platforms.lua")
local result = platforms.queue_launch_request({})
assert(result.ok, "queue_launch_request failed: " .. tostring(result.error))
assert(queued, "nauvis silo was not given the starter-pack request")
print("launch request removed locally and handed to the manager; nauvis request queued")
