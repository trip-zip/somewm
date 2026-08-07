#!/usr/bin/env bash
#
# The globalconf pointer and binding cluster must not survive a reload.
#
# The README used to say this cluster had no cheap outside-visible probe. Two
# of its members do, and both are reachable from a single eval:
#
#  - awesome.lock()/awesome.locked read lua_locked, and the lock surface is an
#    ordinary wibox. Reloading while locked used to strand lua_locked=1 with
#    the lock UI destroyed, which is unrecoverable: no lock surface to
#    authenticate through, and keybindings, VT switch and terminate are all
#    skipped while the session reports locked.
#  - root._keys() is the C entry point, unlike root.keys which awful.root
#    replaces with a table. Assigning to it runs the reset loop that
#    luaA_object_unref's whatever globalconf.keys still holds, so a stale array
#    logs "Reference not found" once per old-state key object.
#
# The rest of the cluster (primary_screen, drawable_under_mouse, mouse_under,
# systray.parent) has no direct getter, so it is exercised rather than read:
# inject pointer motion, which is what dereferences drawable_under_mouse and
# mouse_under, and check the log.

. "$(dirname "$0")/lib.sh"

sw_start hr-gc --config "$ROOT_DIR/tests/rc.lua" || finish

MAKE_LOCK='local w = require("wibox")({ width=10, height=10, visible=true }); _G.LOCKW = w; awesome.set_lock_surface(w); awesome.add_lock_cover(w); return tostring(awesome.lock_surface ~= nil)'
SET_KEYS='local awful = require("awful"); root._keys({awful.key({}, "F13", function() end)}); return "assigned"'

check_eval hr-gc "root keys can be assigned before the reload" "$SET_KEYS" assigned
check_eval hr-gc "a lock surface can be registered" "$MAKE_LOCK" true
check_eval hr-gc "the session locks" 'return tostring(awesome.lock())' true
check_eval hr-gc "the session reports locked" 'return tostring(awesome.locked)' true
check_eval hr-gc "pointer motion before the reload" \
    'root.fake_input("motion_notify", false, 20, 20); return "moved"' moved

sw_reload hr-gc || finish

# The lock surface died with its scene tree, so staying locked would leave no
# way back in.
check_eval hr-gc "the session is not locked after the reload" \
    'return tostring(awesome.locked)' false
check_eval hr-gc "the lock surface is gone with the state that owned it" \
    'return tostring(awesome.lock_surface)' nil
log_has hr-gc "session was locked, forcing unlock" && \
    info "log: the reload reported the forced unlock"

check_eval hr-gc "root keys can be assigned after the reload" "$SET_KEYS" assigned
check_eval hr-gc "pointer motion after the reload" \
    'root.fake_input("motion_notify", false, 40, 40); return "moved"' moved

# luaA_object_unref logs this when handed a pointer it has no entry for, which
# is exactly what a stale globalconf.keys produces on reassignment.
if log_has hr-gc "Reference not found"; then
    fail "no stale object refs were unref'd against the new state" \
         "$(grep -F -- "Reference not found" "$(sw_log hr-gc)" | head -3)"
else
    pass "no stale object refs were unref'd against the new state"
fi

sw_check_log_clean hr-gc "post-reload log"

finish
