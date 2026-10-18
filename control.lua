-- server-connector-mod: routing for a Factorio world split across servers.
--
-- The trigger is the game's own remote view, not a menu this mod draws. Opening
-- remote view onto another planet and clicking it changes the surface the player
-- is *viewing*, and that fires on_player_changed_surface even though the body
-- never moved. So the picker is the interface the game already has, and this mod
-- only has to notice where the player looked and send them there.
--
-- Everything outside this server -- where each player's body is, and what the
-- other servers are -- comes from the manager, because a mod cannot see past its
-- own save. It is an interface to Lua: it holds no policy of its own.
--
--   identity  remote.call("server-connector","set_instance", ...), pushed by the
--             node once this server is up. A headless server does not import
--             mod-settings.json, so a startup setting never arrives.
--   topology  remote.call("server-connector","set_topology", ...), pushed by the
--             manager: the other servers' ids, names and client addresses.
--
-- Nothing here is a script command, so using it never stops achievements.
--
-- The runtime is a package under control/, one file per concern; this file is only the
-- index that loads them, in dependency order. state is the base every other module is
-- built on, the domains follow it, and the last two arm the mod: events registers the
-- handlers and rcon opens the interface the node calls.
--
--   control/state.lua      constants, storage, identity, topology, event notes, report
--   control/convert.lua    surfaces: crash site, create, clear, strip, spawn, settle
--   control/route.lua      destination decision, hand-over, surface enforcement, join rule
--   control/platforms.lua  the fleet's platform copies, and the API probes
--   control/research.lua   the shared tech tree: report and apply
--   control/events.lua     every event handler
--   control/rcon.lua       the calls the node drives, and the two commands
--
-- Each module is required by its absolute path under the mod. Factorio caches a required
-- file by the exact string it was asked for, so every require of a given module uses one
-- spelling: a second spelling would be a second copy, and two copies of a module are two
-- different beliefs.
--
-- Nothing can be required from inside an event handler or a remote.call -- only at load --
-- which is why every require is here and none is below.

require("__server-connector-mod__.control.state")
require("__server-connector-mod__.control.convert")
require("__server-connector-mod__.control.route")
require("__server-connector-mod__.control.platforms")
require("__server-connector-mod__.control.research")
require("__server-connector-mod__.control.events")
require("__server-connector-mod__.control.rcon")
