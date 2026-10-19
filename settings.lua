-- Which planet (or "space") this server handles.
--
-- A hand-set fallback only. The manager does not write this: a headless server compiles
-- mod-settings.dat from defaults and ignores the mod-settings.json beside it, so the node
-- pushes the identity over RCON instead. A value set by hand in the game is still read, and
-- is what the mod falls back to when nothing has pushed one. The default, unconfigured,
-- leaves the mod inert. The rest of the topology is a different mechanism on purpose --
-- that one is pushed over RCON, because it is a property of the stack rather than of this
-- container.
data:extend({
  {
    type = "string-setting",
    name = "server-connector-instance",
    setting_type = "startup",
    default_value = "unconfigured",
    allow_blank = false,
    order = "a",
  },
})
