-- Fails to compile, so the compositor falls back to ./somewmrc.lua. The
-- string below is an X11 call the config prescan reports.
local x11_call = "xset s off"
if true then
