-- Records the two flags as the config sees them. awesome.startup is computed
-- rather than latched, so reading it later always gives false: only a read
-- during the config load sees it true. awesome._restart is nil on a fresh start
-- and true once a reload has begun.

STARTUP_AT_LOAD = awesome.startup
RESTART_AT_LOAD = awesome._restart

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))
