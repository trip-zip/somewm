#!/usr/bin/env bash
#
# A reload reports only its own config load.
#
# A hot reload keeps the process, and the compositor used to keep the startup
# errors and the X11 prescan finding of every earlier load. Once a load had
# failed, every later reload showed the old error again, even with the config
# fixed.

. "$(dirname "$0")/lib.sh"

sw_start_sandboxed hr-load-report "$ROOT_DIR/tests/rc.lua" reload-report || finish

check_eval hr-load-report "the broken config fell back and reported its error and X11 call" \
    'return tostring(SOMEWM_TEST_FALLBACK) .. "|" .. tostring(awesome.startup_errors ~= nil and awesome.startup_errors:find("'"'end'"' expected", 1, true) ~= nil) .. "|" .. tostring(awesome.x11_fallback_info ~= nil)' \
    'true|true|true'

echo 'dofile(assert(os.getenv("SOMEWM_TEST_FALLBACK_RC")))' > "$SW_TIMEOUT_CONFIG/somewm/rc.lua"
sw_reload hr-load-report || finish

check_eval hr-load-report "the fixed config loads and reports nothing" \
    'return tostring(SOMEWM_TEST_FALLBACK) .. "|" .. tostring(awesome.startup_errors) .. "|" .. tostring(awesome.x11_fallback_info)' \
    'nil|nil|nil'

sw_check_log_clean hr-load-report

finish
