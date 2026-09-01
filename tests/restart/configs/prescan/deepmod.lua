-- Reached only through a dotless require() in the fixture rc.lua next to this
-- file, which the pre-scan used to skip outright.
--
-- The X11 pattern below sits in a string that is never executed, so the only
-- thing that can report it is the scanner reading this file.

PRESCAN_DEEP_LOADED = true

local example = 'lgi.require("Gdk", "3.0")'

return { example = example }
