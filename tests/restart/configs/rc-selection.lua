-- tests/rc.lua plus a clipboard watcher, for the selection restart test.

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

SEL_WATCHER = selection.watcher("CLIPBOARD")
SEL_WATCHER.active = true

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
