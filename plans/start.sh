#!/bin/bash
# Start somewm with debug logging
mkdir -p ~/.local/log
exec dbus-run-session somewm -d 2>&1 | tee ~/.local/log/somewm-debug.log
