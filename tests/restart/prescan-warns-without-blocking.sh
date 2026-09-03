#!/usr/bin/env bash
#
# The config pre-scan reports X11 patterns without refusing the config.
#
# Two faults used to compound here. Any require() whose name had no dot was
# treated as a standard library and skipped, so a config split across modules
# was never read past its rc.lua. And any pattern that did match refused the
# whole config, so one reported call was enough to lose the config.
#
# A config that genuinely hangs is caught by the load alarm instead.

. "$(dirname "$0")/lib.sh"

sw_start hr-prescan --config "$RESTART_DIR/configs/prescan/rc.lua" || finish

check_eval hr-prescan "the module behind the dotless require ran" \
    'return tostring(PRESCAN_DEEP_LOADED == true)' true
check_eval hr-prescan "and the compositor serves the API" \
    'return tostring(screen.count())' 1

check_log hr-prescan "the X11 call in rc.lua was reported" \
    "xset display settings"
check_log_count hr-prescan "but the lookalike name was not" "xsettingsd" 0
check_log hr-prescan "the scanner reached the required module" "deepmod.lua"
check_log hr-prescan "and reported the pattern it found there" \
    "GDK initialization deadlock"
check_log_count hr-prescan "but not into somewm's own libraries" "awful/client.lua" 0
check_log_count hr-prescan "no config was skipped" "Skipping this config" 0

finish
