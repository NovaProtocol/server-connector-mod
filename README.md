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
| `set_instance(id)` | Sets this server's identity and clears anything recorded against the old one. |
| `set_topology(servers)` | Replaces the destination set. Idempotent, so a retried push is harmless. |
| `set_body_location(name, id)` | Tells this server where a player's body is. `nil` or this instance means "here". |
| `research_state({offset, limit})` | One page of this server's researched technologies, with the total. |
| `apply_research({researched})` or `{current, progress}` | Marks technologies done, and sets where the shared research stands. |
| `drain_events()` | Everything the game has told this mod since the last drain. |
| `report()` | Instance, tick, target speed, connected players and destination count. |

`research_state` is paged because the whole tree does not fit in one RCON frame once
enough of it is researched — the companion mod this stack replaced chunked its reports
at 4096 bytes for the same reason. Paging needs no snapshot: the manager unions what
it reads on every poll, so a technology that shifts across a page boundary and is
missed once is picked up on the next pass.

## Routing a player

The trigger is the game's own remote view, not a menu this mod draws. Opening remote
view onto another planet and clicking it changes the surface the player is *viewing*,
which fires `on_player_changed_surface` even though their body never moved. The mod
notices where they looked and calls `connect_to_server`.

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

## Install

The manager distributes it: it fetches the zip from this repository's GitHub release
and tells each node to install it before its server starts, so an install needs no
mod-portal credentials. Installing by hand works too — drop the zip in the server's
`mods/` directory and list it in `mods/mod-list.json`, or its startup settings are
ignored.

## License

MIT, see [LICENSE](LICENSE).
