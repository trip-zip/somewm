-- Records awesome.startup as the config sees it. The property is computed from
-- the main loop rather than latched, so reading it later always gives false:
-- only a read during the config load distinguishes a start from a reload.

STARTUP_AT_LOAD = awesome.startup

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))
