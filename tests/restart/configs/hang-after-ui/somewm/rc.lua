-- Builds a tag and a visible drawin, then blocks past the compositor's 10
-- second config alarm. The point is to populate globalconf.tags and
-- globalconf.drawins before the abort: both arrays are C-side and survive
-- the lua_close(), so the recovery must drop them or root.tags() and every
-- EWMH update walk freed userdata. Bare capi keeps this independent of the
-- widget stack. Kept free of X11-looking patterns so the config prescan
-- does not reject it.
local t = tag{ name = "doomed" }
t.activated = true
t.selected = true

local d = drawin{}
d.width = 64
d.height = 64
d.visible = true

while true do end
