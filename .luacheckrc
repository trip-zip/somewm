-- Only allow symbols available in all Lua versions
std = "min"

-- Get rid of "unused argument self"-warnings
self = false

-- The unit tests can use busted
files["spec"].std = "+busted"

-- The default config may set global variables
files["somewmrc.lua"].allow_defined_top = true

-- The restart fixtures set globals on purpose: they are what the harness reads
-- back over IPC to see what a rebuilt state kept. Nothing in the file itself
-- reads them, hence 131 as well.
files["tests/restart/configs/*"].allow_defined_top = true
files["tests/restart/configs/*"].ignore = {"131"}

-- This file itself
files[".luacheckrc"].ignore = {"111", "112", "131"}

-- Theme files, ignore max line length
files["themes/*"].ignore = {"631"}

-- Global objects defined by the C code
read_globals = {
    "awesome",
    "button",
    "dbus",
    "drawable",
    "drawin",
    "key",
    "keygrabber",
    "mousegrabber",
    "selection",
    "tag",
    "window",
    "table.unpack",
    "math.atan2",
    -- LuaJIT / Lua 5.1 globals somewm actually runs on
    "unpack",
    "loadstring",
    -- somewm additions
    "layer_surface",
    "output",
    "systray_item",
    "_gesture",
    "_keygrabber",
    "_timer",
    "_ipc_broadcast",
    "_ipc_has_subscribers",
    "_ipc_send_response",
    "_ipc_subscribe",
}

-- screen may not be read-only, because newer luacheck versions complain about
-- screen[1].tags[1].selected = true.
-- The same happens with the following code:
--   local tags = mouse.screen.tags
--   tags[7].index = 4
-- client may not be read-only due to client.focus.
globals = {
    "screen",
    "mouse",
    "root",
    "client"
}

-- Enable cache (uses .luacheckcache relative to this rc file).
cache = true

-- Do not enable colors to make the CI output more readable.
color = false

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
