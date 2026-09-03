-- tests/rc.lua plus a module reached by a dotless require().
--
-- "deepmod" has no dot in it, which the pre-scan used to read as a standard
-- library name and skip, so a config split across modules was never scanned
-- past its rc.lua. The module carries somewm's one CRITICAL pattern, and this
-- config still has to load: the scanner warns, it does not refuse.

-- A genuine X11 call. It is reported, and the config still loads: the
-- scanner warns, it does not refuse.
local x11_call = "xset s off"

-- A different program whose name starts the same way. It must not be
-- reported as the one above.
local x11_lookalike = "xsettingsd"

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

require("deepmod")

-- A library the scanner can now resolve, but must not read: findings in
-- somewm's own Lua are not the user's to fix.
require("awful")

return x11_call, x11_lookalike
