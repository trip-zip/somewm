-- Deterministic fallback for the config-timeout tests.
--
-- The compositor is started with cwd here, so ./somewmrc.lua is what it finds
-- after the hanging XDG config aborts. It loads the minimal test config rather
-- than the real somewmrc.lua, whose wibars, lockscreen and naughty wiring would
-- make a dropped-callback or dead-D-Bus failure ambiguous.
-- Unambiguous marker: awesome.conffile only reports "./somewmrc.lua", which
-- says nothing about whose somewmrc.lua won.
SOMEWM_TEST_FALLBACK = true

dofile(assert(os.getenv("SOMEWM_TEST_FALLBACK_RC"),
    "SOMEWM_TEST_FALLBACK_RC must point at the config to load"))
