#!/bin/bash
# Start somewm with debug logging
mkdir -p ~/.local/log

# Ensure /usr/local/lib is on library path (scenefx, lgi guard)
# ldconfig should handle this, but LD_LIBRARY_PATH is a safe fallback
if [[ ":${LD_LIBRARY_PATH:-}:" != *":/usr/local/lib:"* ]]; then
    export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Lgi closure guard for safe hot-reload
# somewm clears LD_PRELOAD in main() so children don't inherit it
LGI_GUARD=/usr/local/lib/liblgi_closure_guard.so
if [ -f "$LGI_GUARD" ]; then
    export LD_PRELOAD="${LGI_GUARD}${LD_PRELOAD:+:$LD_PRELOAD}"
    export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}verify_asan_link_order=0"
fi

exec dbus-run-session somewm -d 2>&1 | tee ~/.local/log/somewm-debug.log
