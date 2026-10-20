# server-connector-mod

Routing for a Factorio world split across several servers, one per planet plus one
for the space platforms. This mod runs inside **one** of those servers.

A mod cannot see past its own save, so everything outside this server belongs to the
manager: where each player's body is, and what the other servers are. The mod is an
interface to Lua and holds no policy of its own — what it does is report what only it
can see, and execute what the manager asks.

## Getting the manager's calls in

Two channels, both over RCON, both pushed rather than read from a setting:

| Call | Carries |
|---|---|
| `set_instance(id)` | Which planet (or `space`) this server handles |
| `set_topology(servers)` | Every server's id, name and client address |

**Identity is pushed, not configured.** The intended carrier was the startup setting
`server-connector-instance`, but a headless server does not import
`mod-settings.json` — it compiles `mod-settings.dat` from defaults and ignores the
JSON beside it, so the setting never arrives, whether the file sits in `config/` or
next to `mod-list.json`. The node pushes the id instead, and the setting stays as the
fallback for anyone who sets it by hand in the game.

Until `set_instance` lands the mod is `unconfigured` and routes nobody. That is the
safe direction: a wrong instance would send players to the wrong server.

## The call surface

One command, `server-connector-call`, taking `{"fn": "...", "args": [...]}` and
answering with JSON. One name that does not move as the interface grows.

**Nothing here is a script command, so using it never stops achievements.** `/c` and
`/sc` are script commands: they permanently mark the save as cheated and they echo
into the chat. A manager polling every few seconds would fill the screen of anyone
playing, which is why the node talks to this mod through its own command instead.

| `fn` | Does |
|---|---|
| `set_instance(id)` | Sets this server's identity. Returns `unchanged` for the id it already holds, and `skipped` while anybody is connected. |
| `set_topology(servers)` | Replaces the destination set. Returns `unchanged` for the same set, and `skipped` while anybody is connected. |
| `set_body_location(name, id)` | Tells this server where a player's body is. `nil` or this instance means "here". Reports `destroyed_character` when it removed one here. |
| `research_state({offset, limit})` | One page of this server's researched technologies, with the total. |
| `apply_research({researched})` or `{current, progress}` | Marks technologies done, and sets where the shared research stands. |
| `drain_events()` | Everything the game has told this mod since the last drain. |
| `set_paused(paused)` | Holds the game still, or lets it run. |
| `set_speed(speed)` | Sets the world's speed, and keeps it for a restart. |
| `create_surfaces(entries?)` | Makes this instance's surfaces. With a list, it creates the custom surfaces the manager declared, including their seed, cliffs and water. `skipped` while anybody is connected. |
| `research_all()` | Unlocks every technology on this force. For a custom instance in `all` mode. |
| `delete_surface(name)` | Removes one custom surface. Refuses the primary and anybody connected. |
| `surfaces()` | What surfaces this world has, and which of them are platforms. |
| `settle()` | Brings the world into line: crash site, surfaces, spawn point. Nobody connected only. |
| `mirror_platforms(entries)` | Makes, keeps or removes this server's copies of the fleet's platforms. Nobody connected only. |
| `platforms()` | What this server's platforms are. Read-only. |
| `platform_api()` | Which platform calls and names this build actually has. Read-only. |
| `surface_api()` | Which surface calls this build actually has. |
| `report()` | Instance, tick, bodies, speed, connected players, destinations, surfaces and unlocked planets. |

Three of these are orders that change the world. `set_instance`, `set_topology` and
`create_surfaces` answer `{skipped = "somebody is connected"}` and write nothing while a
player is connected: an RCON-driven change is not replicated to a client, so the next crc
comparison desyncs it. `set_instance` and `set_topology` also answer `{unchanged = true}`
when they are told what they already hold, which is what makes a retried push harmless. The
node retries an identity push until the answer names its instance, and the manager retries a
topology push until it is not skipped.

`research_state` is paged because the whole tree does not fit in one RCON frame once
enough of it is researched — the companion mod this stack replaced chunked its reports
at 4096 bytes for the same reason. Paging needs no snapshot: the manager unions what
it reads on every poll, so a technology that shifts across a page boundary and is
missed once is picked up on the next pass.

## The server map

There are no copies of another server's surface, so the game's remote view has nothing to
look at and no surface change to route on. The way across is the map: while the map view is
open, a frame lists one button per other instance, labelled with the name the manager gave it,
and a click calls `connect_to_server`. The instance you are already on is not in the list, so
there is no button to send yourself where you already are.

The vanilla space map is disabled (`disable_space_map`), because it would offer every planet
as a view with no surface behind it. The mod's map is the space map. It is rebuilt on join and
whenever the topology changes; there is no event for opening the map, so its visibility is
checked on the one-second pass.

**The address is the one a client dials.** Pointing a player at an RCON port produces
a prompt that reads perfectly correctly and a client that sits at "connecting" until
it gives up, with nothing logged anywhere. Game port, not RCON port.

## The join rule

A body exists on exactly one server. On every other one the player is a remote
viewer — the game's own remote controller, so no walking, no taking or changing
items, and blueprints still place as ghosts.

The remote controller is an *overlay* on a physical one, so leaving it returns the
player to that — and a bodyless player's physical controller is god mode. Leaving is
therefore disabled, which is load-bearing rather than a nicety.

A character in a save is only a body of that server when it stands on a surface the instance
owns: its planet, the custom surfaces the manager declared, or a platform on the space server.
The instance's topology entry names them, and `report().bodies` only names characters this
server actually holds.

## Faults

An error raised from an event handler quits the server, and the fleet's watchdog then stops
the other five. So no handler is allowed to raise: each one runs its work inside a wrapper
whose failure is a log line, and the writes inside the join and routing rules are wrapped
individually so one refused call does not skip the rest. The same applies to the two console
commands. A fault shows up as `[<instance>] <what> failed: <reason>` in the game log.

## Source layout

`control.lua` is the entry point and nothing else: it `require`s the runtime, which is a
package under `control/`, one file per concern.

| File | Holds |
|---|---|
| `control/state.lua` | constants, `storage`, identity, topology, the event queue, `report` |
| `control/convert.lua` | the crash site, owned surfaces, custom surfaces, the spawn point and the asteroid sweep |
| `control/server.lua` | the join rule: which controller a player gets, and where their body is |
| `control/map.lua` | the server map: one button per other instance, shown while the map is open |
| `control/platforms.lua` | the fleet's platform copies, and the API probes |
| `control/research.lua` | the shared tech tree: report and apply |
| `control/events.lua` | every event handler |
| `control/rcon.lua` | the calls the node drives, and the two commands |

Modules use Factorio's `require`, resolved from the mod root
(`__server-connector-mod__.control.<name>`). One spelling per module: Factorio caches a
required file by the exact string it was asked for, so two spellings would load it twice,
and two copies of a module are two different beliefs. `require` cannot run inside an event
handler or a `remote.call`, so every require is at load. `scripts/release.py` ships
`control/` whole and syntax-checks every file in it before building.

## Install

The manager distributes it: it fetches the zip from this repository's GitHub release
and tells each node to install it before its server starts, so an install needs no
mod-portal credentials. Installing by hand works too — drop the zip in the server's
`mods/` directory and list it in `mods/mod-list.json`, or its startup settings are
ignored.

## License

MIT, see [LICENSE](LICENSE).
