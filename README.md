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
| `sweep_foreign()` | One pass over the chunks on surfaces this instance does not own. Returns how many it removed. |
| `request_platform({planet, name, starter_pack, quality})` | Recreate a pending platform request on the planet's own server. Idempotent by name. |
| `request_moved_ack({id})` | Mark a moved request acknowledged, so the origin stops re-sending it. |
| `request_purge_mode({live})` | Arm or disarm the wrong-planet request purge. Dry-run unless armed. |
| `request_probe()` | Every platform with its pending verdict, planet and starter pack. |
| `surfaces()` | What surfaces this world has, and which of them are platforms. |
| `settle()` | Brings the world into line: crash site, surfaces, spawn point. Nobody connected only. |
| `mirror_platforms(entries)` | Makes, keeps or removes this server's copies of the fleet's platforms: hub, matching cargo bays, no asteroids. Called over RCON, nobody connected only. |
| `platforms()` | What this server's platforms are. Read-only. |
| `platform_meta()` | Cheap platform metadata: index, name, state, position fields, cargo-bay count from the surface and the request hash. No inventory. |
| `platform_hub_dump({index, cursor, limit})` | One page of a hub's cargo and requests, with `next`, `total`, `hash` and `done`. |
| `platform_cargo(index)` / `platform_requests(index)` | The unpaged hub read, for a manual call. |
| `platform_audit()` | Raw item totals summed across every platform on this server. |
| `apply_cargo_delta({platform, ordinal, ops})` | Applies a manager-computed cargo difference; positive inserts, negative removes. `ordinal` selects among platforms that share a name. |
| `apply_requests({platform, ordinal, requests})` | Replaces a copy's requests, selected the same way; refused while anybody is connected. |
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

A planet server moves the joining body onto the surface it owns and leaves everything else
alone: no controller, character, editor, remote or inventory change, because each of those is a
world change the client did not make.

The space server is a viewer. It owns no body, so a join gets the game's remote controller
(no walking, no taking or changing items, blueprints still place as ghosts), and the body the
game created is queued for removal on the next window with nobody connected. Destroying it in
the join handler desynced joins (0.32.3), which is why it waits.

The remote controller is an *overlay* on a physical one, so leaving it returns the player to
that — and a bodyless player's physical controller is god mode. Leaving is therefore disabled,
which is load-bearing rather than a nicety.

A character in a save is only a body of that server when it stands on a surface the instance
owns: its planet, the custom surfaces the manager declared, or a platform on the space server.
The instance's topology entry names them, and `report().bodies` only names characters this
server actually holds.

## Chunks a join should not leave behind

The game creates a joining body at the force's spawn before the join rule can move it. If that
spawn is still on a planet this server does not own, the map generates a chunk there. Two
things deal with it:

- The spawn point is set to the owned surface at boot, before the foreign-surface cleanup, so
  new joins do not create the chunk at all.
- Once a minute, every chunk on a surface this instance does not own is deleted unless a body
  is standing in it. Nauvis cannot be deleted (the game refuses the primary surface), so chunks
  are the only tool there. `sweep_foreign()` runs a pass on demand.

Every second, a connected player standing somewhere this instance does not own is put back on
its surface, and the spawn point is re-asserted if it drifted.

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
| `control/chunks.lua` | chunks on surfaces this server does not own |
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

## Releasing

`info.json` carries the version, and the manager pins it in `manager/src/api/modset.go`. A
release is **two channels at once**, because they serve different clients:

| Channel | Who installs from it |
|---|---|
| GitHub release | the manager, onto every server |
| mod portal | a player's client when it syncs with a server |

```bash
export GITHUB_TOKEN=... MOD_PORTAL_KEY=...   # see agent_stuff/tokens.md
scripts/release.py --tag v0.36.53
```

The portal upload runs first: it is the half that fails on a stale key, and a GitHub-only
release is the one nobody can join. The script refuses if either token is missing.

A local fleet can still run without the GitHub release, because the manager prefers its own
copy of the exact archive; every other fleet cannot, and the manager logs
`drawing server-connector-mod answered 404` on each start until the release exists. That log
line is the reminder that the release step was skipped.

Verify both channels:

```bash
curl -sIL "https://github.com/NovaProtocol/server-connector-mod/releases/download/v0.36.53/server-connector-mod_0.36.53.zip" | head -1
curl -s https://mods.factorio.com/api/mods/server-connector-mod/full | jq -r '.releases[].version' | grep -x 0.36.53
```

## License

MIT, see [LICENSE](LICENSE).
