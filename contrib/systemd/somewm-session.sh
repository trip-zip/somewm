#!/bin/sh
# somewm session wrapper with systemd integration
#
# Launch somewm as a systemd user service with proper session lifecycle.
# Display managers should use this as their Exec entry.

# Clean up any stale Wayland sockets before starting
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null

# Source environment.d configs for TTY parity with display manager sessions
for _conf in "$HOME/.config/environment.d/"*.conf; do
    [ -f "$_conf" ] || continue
    set -a
    . "$_conf"
    set +a
done
unset _conf

# If we're already being run as a systemd service, just exec the compositor
if [ -n "${MANAGERPID:-}" ] && [ "${SYSTEMD_EXEC_PID:-}" = "$$" ]; then
    case "$(ps -p "$MANAGERPID" -o cmd=)" in
    *systemd*--user*)
        exec somewm
        ;;
    esac
fi

# Make sure systemd is available
if ! hash systemctl >/dev/null 2>&1; then
    echo "systemd not found. Run somewm directly instead." >&2
    exit 1
fi

# Make sure there's no already running session
if systemctl --user -q is-active somewm.service; then
    echo "A somewm session is already running." >&2
    exit 1
fi

# Reset failed state of all user units
systemctl --user reset-failed

# Import session-relevant variables into systemd user manager
systemctl --user import-environment \
    DBUS_SESSION_BUS_ADDRESS \
    HOME \
    LANG \
    PATH \
    SHELL \
    SSH_AUTH_SOCK \
    XDG_RUNTIME_DIR \
    XDG_SEAT \
    XDG_SESSION_ID \
    XDG_VTNR

# Set compositor-specific variables
systemctl --user set-environment \
    XDG_CURRENT_DESKTOP=somewm \
    XDG_SESSION_TYPE=wayland

# D-Bus activation environment is independent from systemd
if hash dbus-update-activation-environment 2>/dev/null; then
    dbus-update-activation-environment --all
fi

# Start somewm and block until it exits
systemctl --user --wait start somewm.service

# Force stop graphical session services
systemctl --user start --job-mode=replace-irreversibly somewm-shutdown.target

# Clean up environment
systemctl --user unset-environment \
    WAYLAND_DISPLAY \
    DISPLAY \
    XDG_SESSION_TYPE \
    XDG_CURRENT_DESKTOP

# Clean up Wayland sockets
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null
