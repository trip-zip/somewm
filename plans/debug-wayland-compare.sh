#!/bin/bash
# Compare Wayland protocol traces between sway and somewm
# Usage: ./plans/debug-wayland-compare.sh <app-command>
# Example: ./plans/debug-wayland-compare.sh "steam steam://rungameid/12345"
#
# This script captures wl_keyboard events to compare focus delivery.

APP="${1:-alacritty}"
LOGDIR="/tmp/somewm-debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

echo "=== Focus Protocol Debug ==="
echo "App: $APP"
echo "Logs: $LOGDIR"
echo ""

echo "--- Step 1: Capture somewm keyboard events ---"
echo "Run in a somewm session:"
echo "  WAYLAND_DEBUG=1 $APP 2>&1 | grep -E 'wl_keyboard|wl_seat.*(enter|leave)' > $LOGDIR/somewm-keyboard.log"
echo ""

echo "--- Step 2: Capture sway keyboard events (reference) ---"
echo "Run in a sway session:"
echo "  WAYLAND_DEBUG=1 $APP 2>&1 | grep -E 'wl_keyboard|wl_seat.*(enter|leave)' > $LOGDIR/sway-keyboard.log"
echo ""

echo "--- Step 3: Compare ---"
echo "  diff $LOGDIR/sway-keyboard.log $LOGDIR/somewm-keyboard.log"
echo ""

echo "--- Quick test: Focus state via IPC ---"
echo "  somewm-client 'return client.focus and client.focus.name or \"none\"'"
echo "  somewm-client 'return client.focus and tostring(client.focus.focusable) or \"N/A\"'"
echo ""

echo "--- XWayland focus check ---"
echo "  xprop -root _NET_ACTIVE_WINDOW"
echo "  xdotool getactivewindow getwindowname"
echo ""

echo "--- GPU info ---"
echo "  cat /sys/class/drm/card*/device/uevent | grep DRIVER"
echo "  echo \$WLR_RENDERER"
