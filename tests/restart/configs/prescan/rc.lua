-- tests/rc.lua plus a module reached by a dotless require().
--
-- "deepmod" has no dot in it, which the pre-scan used to read as a standard
-- library name and skip, so a config split across modules was never scanned
-- past its rc.lua. The module carries somewm's one CRITICAL pattern, and this
-- config still has to load: the scanner warns, it does not refuse.

-- A path that only looks like an X11 tool: the scanner matches its xset
-- pattern inside this name. Refusing a config over that is what warn-only
-- fixes. Keep the pattern out of this comment: only the first occurrence
-- of a pattern in a file is examined, so a comment above would mask it.
local x11_lookalike = "xsettingsd"

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

require("deepmod")

return x11_lookalike
