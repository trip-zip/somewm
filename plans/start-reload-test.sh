#!/bin/bash
# Start somewm for reload testing — logs to both file and stdout
# Run from TTY, then from another TTY call: somewm-client reload
mkdir -p ~/.local/log

# Lgi closure guard for safe hot-reload
LGI_GUARD=/usr/local/lib/liblgi_closure_guard.so
if [ -f "$LGI_GUARD" ]; then
    export LD_PRELOAD="${LGI_GUARD}${LD_PRELOAD:+:$LD_PRELOAD}"
    export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}verify_asan_link_order=0"
fi

exec dbus-run-session somewm -d 2>&1 | tee /tmp/somewm-reload-test.log
