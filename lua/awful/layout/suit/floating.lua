---------------------------------------------------------------------------
-- Compat shim: re-exports clay.floating so existing
-- `require("awful.layout.suit.floating")` callers in awful.placement,
-- awful.tag, and awful.mouse get the same table identity as
-- awful.layout.clay.floating. The actual layout (arrange,
-- mouse_resize_handler, resize_jump_to_corner, name) lives in
-- lua/awful/layout/clay/floating.lua.
---------------------------------------------------------------------------

return require("awful.layout.clay").floating
