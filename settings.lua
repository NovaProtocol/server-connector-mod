-- Which planet (or "space") this server handles.
--
-- A startup setting, not a runtime one, because identity is a property of the
-- container: the manager writes it into the server's config/mod-settings.json
-- before launch, and it then survives every restart without anything having to
-- re-send it. It is readable from control.lua, so the mod knows who it is from
-- on_init. The rest of the topology is a different mechanism on purpose -- that
-- one is pushed over RCON, because it is a property of the stack rather than of
-- this container.
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
