# server-connector-mod

Routing for a Factorio world split across several servers, one per planet plus one
for the space platforms. This mod runs inside **one** of those servers.

A mod cannot see past its own save, so everything outside this server belongs to the
manager: where each player's body is, and what the other servers are. The mod takes
those in over two deliberately different channels.

## Identity

Which planet (or `space`) this server handles is a **startup setting**,
`server-connector-instance`. The manager writes it into the server's
`config/mod-settings.json` before launch, so it is known from `on_init`, survives every
restart on its own, and never races a server that has not finished starting.

Identity is a property of the container. That is why it is static.

## Topology

What the *other* servers are, and where they live, is pushed over **RCON** once this
server is up:

```lua
remote.call("server-connector", "set_topology", {
  nauvis   = {name = "Nauvis Server",   address = "192.168.18.63:34200"},
  vulcanus = {name = "Vulcanus Server", address = "192.168.18.63:34201"},
})
```

The call is idempotent, so a retried push is harmless. Until one arrives the travel
menu says so rather than offering nothing, and the mod never guesses at an address.

**The address is the one a client dials.** Pointing a player at an RCON port instead
produces a prompt that reads perfectly correctly and a client that sits at
"connecting" until it gives up, with nothing logged anywhere. Game port, not RCON port.

## Remote interface

Available to the manager over RCON; nothing here is a script command, so using it never
stops achievements.

| Call | Does |
|---|---|
| `set_topology(topology)` | Replaces the destination set. Returns the instance and how many destinations it now has. |
| `set_body_location(name, id)` | Tells this server where a player's body is. `nil` or this instance means "here". |
| `open_menu(name)` | Opens the travel menu for a player. |
| `report()` | Instance, tick, target speed, connected players and destination count, as a table. |

## What a player sees

- **A travel menu**, from the `Travel` button in the top bar or the
  `server-connector-travel` command, listing every destination and calling
  `connect_to_server` when one is picked.
- **Remote view** when their body is elsewhere: the game's own remote controller, so no
  walking, no taking or changing items, blueprints still place as ghosts. Leaving it is
  disabled, because the remote controller sits on a physical one and a bodyless player's
  physical controller is god mode.

## Install

The manager installs it, fetching the zip from this repository's GitHub release, so it
needs no mod-portal credentials. Installing by hand works too: drop the zip in the
server's `mods/` directory.

## License

MIT, see [LICENSE](LICENSE).
