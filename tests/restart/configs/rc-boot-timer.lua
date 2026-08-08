-- tests/rc.lua plus a gears.timer armed while the config loads.
--
-- The timing is the whole point. timers-after-restart arms its timer from an
-- eval, after startup finished; this arms one during the config itself, which
-- is where the sweep used to be blind and where real configs put them (a
-- textclock arms its timer while the wibar is being built).

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

BOOT_TICKS = 0
BOOT_TIMER = require("gears.timer").start_new(0.1, function()
    BOOT_TICKS = BOOT_TICKS + 1
    return true
end)

-- The shipped arrangement, not just the minimal one: somewmrc.lua builds a
-- textclock, which arms its timer through weak_start_new and re-arms it from
-- its own callback with :again().
BOOT_CLOCK = require("wibox.widget.textclock")()
