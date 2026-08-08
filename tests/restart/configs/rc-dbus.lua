-- tests/rc.lua plus naughty, for the restart tests that assert D-Bus behaviour.
--
-- NOTIF_COUNT is the corroborating half of the notification tests: gdbus alone
-- only proves that something on the bus answered, and dbus-run-session still
-- honours /usr/share/dbus-1/services, so a real notification daemon can be
-- activated on the "private" bus. This counter proves the call reached this
-- compositor's Lua.

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

local naughty = require("naughty")

NOTIF_COUNT = 0
NOTIF_LAST = ""

naughty.connect_signal("request::display", function(n)
    NOTIF_COUNT = NOTIF_COUNT + 1
    NOTIF_LAST = n.title or ""
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
