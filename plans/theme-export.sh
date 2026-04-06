#!/bin/bash
# theme-export.sh — atomic write, no cjson dependency, full export
# Exports somewm Lua theme colors to theme.json for somewm-shell consumption.
# Falls back to committed default if compositor is not running.

set -euo pipefail

THEME_JSON="$HOME/.config/somewm/themes/default/theme.json"
THEME_TMP="${THEME_JSON}.tmp"
FALLBACK="/home/box/git/github/somewm/plans/somewm-shell/theme.default.json"

# Ensure target directory exists
mkdir -p "$(dirname "$THEME_JSON")"

# Try live export from running compositor
if somewm-client eval '
    local b = require("beautiful")
    local parts = {}
    local function add(k,v) parts[#parts+1] = string.format("  %q: %q", k, tostring(v or "")) end
    add("bg_base", b.bg_normal)
    add("bg_surface", b.bg_focus)
    add("bg_overlay", b.bg_minimize)
    add("fg_main", b.fg_focus)
    add("fg_dim", b.fg_normal)
    add("fg_muted", b.fg_minimize)
    add("accent", b.border_color_active)
    add("accent_dim", b.border_color_marked)
    add("urgent", b.bg_urgent)
    add("green", "#98c379")
    add("font_ui", "Geist")
    add("font_mono", "Geist Mono")
    add("widget_cpu", b.widget_cpu_color)
    add("widget_gpu", b.widget_gpu_color)
    add("widget_memory", b.widget_memory_color)
    add("widget_disk", b.widget_disk_color)
    add("widget_network", b.widget_network_color)
    add("widget_volume", b.widget_volume_color)
    return "{\n" .. table.concat(parts, ",\n") .. "\n}"
' > "$THEME_TMP" 2>/dev/null; then
    mv "$THEME_TMP" "$THEME_JSON"  # atomic!
    echo "Exported theme to $THEME_JSON"
else
    echo "Compositor not running, using fallback theme"
    # Fallback: copy committed default theme.json
    cp "$FALLBACK" "$THEME_JSON" 2>/dev/null
fi
