#!/bin/bash
# Start somewm with debug logging
mkdir -p ~/.local/log

# Lgi closure guard for safe hot-reload
# somewm clears LD_PRELOAD in main() so children don't inherit it
LGI_GUARD=/usr/local/lib/liblgi_closure_guard.so
if [ -f "$LGI_GUARD" ]; then
    export LD_PRELOAD="${LGI_GUARD}${LD_PRELOAD:+:$LD_PRELOAD}"
    export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}verify_asan_link_order=0"
fi

exec dbus-run-session somewm -d 2>&1 | tee ~/.local/log/somewm-debug.log
