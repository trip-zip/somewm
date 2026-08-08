#!/usr/bin/env bash
#
# After a config timeout, the user must be told about it.
#
# The compositor records "Config loading timed out" as a startup error and
# naughty emits request::display_error once rc.lua is up. The C side then
# rebuilds the Lua state while the screen refs still point at the closed one, so
# the compositor reports screens that no notification can be placed on:
# naughty's register() used to die on assert(s), logged only as "error in error
# handling", and the message the fallback exists to deliver never appeared.
#
# This one needs the real somewmrc.lua as the fallback, because the handler
# under test is the request::display_error wiring in it. The other two
# config-timeout tests deliberately use the minimal tests/rc.lua instead.

. "$(dirname "$0")/lib.sh"

# somewmrc.lua themes itself from gears.filesystem.get_themes_dir(), which is
# the installed DATADIR. Point it at the tree under test, the same reason the
# sandbox carries a ./lua symlink: a machine with no somewm installed must run
# this test the same way as one that has.
export AWESOME_THEMES_PATH="$ROOT_DIR/themes"

sw_start_hung_config hr-d16 "$ROOT_DIR/somewmrc.lua" || finish

# sw_check_log_clean covers "error in error handling" on its own, but name it
# here too: it is the whole signature of the defect.
check_log_count hr-d16 "the error handler did not die" "error in error handling" 0

check_eval hr-d16 "the timeout is reported as a startup error" \
    'return tostring(awesome.startup_errors ~= nil and awesome.startup_errors:match("timed out") ~= nil)' \
    true

check_eval hr-d16 "the startup error is displayed" \
    'local a = require("naughty").active; local n = a[1]; return #a .. "|" .. tostring(n and n.title)' \
    '1|Oops, an error happened during startup!'

sw_check_log_clean hr-d16

finish
