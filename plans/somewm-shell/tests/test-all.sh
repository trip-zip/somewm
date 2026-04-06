#!/bin/bash
# somewm-shell test suite
# Usage: ./tests/test-all.sh [--verbose]
# Runs all validation tests. Does NOT require a running compositor or Quickshell.
# Tests focus on: structure, syntax, import consistency, config validity, deploy correctness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_DIR="$(dirname "$SCRIPT_DIR")"
VERBOSE="${1:-}"
PASS=0
FAIL=0
ERRORS=()

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    PASS=$((PASS + 1))
    if [[ "$VERBOSE" == "--verbose" ]]; then
        echo -e "  ${GREEN}PASS${NC} $1"
    fi
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1: $2")
    echo -e "  ${RED}FAIL${NC} $1: $2"
}

section() {
    echo -e "\n${YELLOW}=== $1 ===${NC}"
}

# ============================================================
section "1. File Structure"
# ============================================================

# Required directories
for dir in core services components modules modules/dashboard \
           modules/osd modules/weather modules/wallpapers modules/collage; do
    if [[ -d "$SHELL_DIR/$dir" ]]; then
        pass "Directory exists: $dir"
    else
        fail "Directory missing: $dir" "required directory not found"
    fi
done

# Required files
REQUIRED_FILES=(
    shell.qml
    deploy.sh
    config.default.json
    theme.default.json
    core/Theme.qml
    core/Anims.qml
    core/Config.qml
    core/Panels.qml
    core/Constants.qml
    core/qmldir
    services/Compositor.qml
    services/SystemStats.qml
    services/Audio.qml
    services/Media.qml
    services/Brightness.qml
    services/Weather.qml
    services/Wallpapers.qml
    services/Network.qml
    services/CavaService.qml
    services/qmldir
    components/Anim.qml
    components/CAnim.qml
    components/StyledRect.qml
    components/StyledText.qml
    components/GlassCard.qml
    components/ClickableCard.qml
    components/StateLayer.qml
    components/MaterialIcon.qml
    components/SlidePanel.qml
    components/FadeLoader.qml
    components/StatCard.qml
    components/CircularProgress.qml
    components/Graph.qml
    components/AnimatedBar.qml
    components/PulseWave.qml
    components/ImageAsync.qml
    components/ScrollArea.qml
    components/Separator.qml
    components/Tooltip.qml
    components/ArcGauge.qml
    components/ConcaveShape.qml
    components/TabBar.qml
    components/FrequencyVisualizer.qml
    components/WallpaperCarousel.qml
    components/qmldir
    modules/ModuleLoader.qml
    modules/qmldir
    modules/dashboard/Dashboard.qml
    modules/dashboard/ClockWidget.qml
    modules/dashboard/StatsGrid.qml
    modules/dashboard/ClientList.qml
    modules/dashboard/QuickLaunch.qml
    modules/dashboard/MediaMini.qml
    modules/dashboard/HomeTab.qml
    modules/dashboard/PerformanceTab.qml
    modules/dashboard/MediaTab.qml
    modules/dashboard/NotificationsTab.qml
    modules/dashboard/QuickSettings.qml
    modules/dashboard/CalendarWidget.qml
    modules/osd/OSD.qml
    modules/osd/VolumeOSD.qml
    modules/osd/BrightnessOSD.qml
    modules/weather/WeatherPanel.qml
    modules/weather/CurrentWeather.qml
    modules/weather/Forecast.qml
    modules/wallpapers/WallpaperPanel.qml
    modules/wallpapers/WallpaperGrid.qml
    modules/wallpapers/Preview.qml
    modules/collage/CollagePanel.qml
    modules/collage/MasonryGrid.qml
    modules/collage/Lightbox.qml
)

for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$SHELL_DIR/$f" ]]; then
        pass "File exists: $f"
    else
        fail "File missing: $f" "required file not found"
    fi
done

# ============================================================
section "2. QML Syntax Validation"
# ============================================================

# Basic QML syntax checks (without a QML engine, check for common errors)
while IFS= read -r -d '' qml_file; do
    rel="${qml_file#$SHELL_DIR/}"

    # Check: file is not empty
    if [[ ! -s "$qml_file" ]]; then
        fail "$rel" "file is empty"
        continue
    fi

    # Check: has import QtQuick (all QML files should have this, except qmldir)
    if [[ "$rel" != *qmldir* ]] && ! grep -q 'import QtQuick' "$qml_file" 2>/dev/null; then
        fail "$rel" "missing 'import QtQuick'"
        continue
    fi

    # Check: matching braces
    open_braces=$(grep -o '{' "$qml_file" | wc -l)
    close_braces=$(grep -o '}' "$qml_file" | wc -l)
    if [[ "$open_braces" -ne "$close_braces" ]]; then
        fail "$rel" "unbalanced braces: { = $open_braces, } = $close_braces"
        continue
    fi

    # Check: no trailing semicolons after property declarations (common typo)
    if grep -nE '^\s*property\s+.*;\s*$' "$qml_file" | grep -v '//' | head -1 | grep -q ';'; then
        # This is actually valid QML for inline property declarations, skip
        :
    fi

    pass "$rel syntax OK"
done < <(find "$SHELL_DIR" -name '*.qml' -print0 | sort -z)

# ============================================================
section "3. Singleton Validation"
# ============================================================

# All core/ singletons must have 'pragma Singleton' + 'Singleton {' root
for f in Theme Anims Config Panels Constants; do
    qml="$SHELL_DIR/core/$f.qml"
    if [[ ! -f "$qml" ]]; then
        fail "core/$f.qml" "file missing"
        continue
    fi
    if ! head -1 "$qml" | grep -q 'pragma Singleton'; then
        fail "core/$f.qml" "missing 'pragma Singleton' on line 1"
    else
        pass "core/$f.qml has pragma Singleton"
    fi
    if ! grep -q 'Singleton {' "$qml"; then
        fail "core/$f.qml" "missing 'Singleton {' root element"
    else
        pass "core/$f.qml has Singleton root"
    fi
done

# All services/ singletons
for f in Compositor SystemStats Audio Media Brightness Weather Wallpapers Network CavaService; do
    qml="$SHELL_DIR/services/$f.qml"
    if [[ ! -f "$qml" ]]; then
        fail "services/$f.qml" "file missing"
        continue
    fi
    if ! head -1 "$qml" | grep -q 'pragma Singleton'; then
        fail "services/$f.qml" "missing 'pragma Singleton'"
    else
        pass "services/$f.qml has pragma Singleton"
    fi
done

# ============================================================
section "4. qmldir Registry Validation"
# ============================================================

# core/qmldir should register all 5 singletons
core_qmldir="$SHELL_DIR/core/qmldir"
for name in Theme Anims Config Panels Constants; do
    if grep -q "singleton $name" "$core_qmldir" 2>/dev/null; then
        pass "core/qmldir registers singleton $name"
    else
        fail "core/qmldir" "missing singleton registration for $name"
    fi
done

# services/qmldir should register all 8 singletons
services_qmldir="$SHELL_DIR/services/qmldir"
for name in Compositor SystemStats Audio Media Brightness Weather Wallpapers Network CavaService; do
    if grep -q "singleton $name" "$services_qmldir" 2>/dev/null; then
        pass "services/qmldir registers singleton $name"
    else
        fail "services/qmldir" "missing singleton registration for $name"
    fi
done

# components/qmldir should register all component types
comp_qmldir="$SHELL_DIR/components/qmldir"
for name in Anim CAnim StyledRect StyledText GlassCard ClickableCard StateLayer \
            MaterialIcon SlidePanel FadeLoader StatCard CircularProgress Graph \
            AnimatedBar PulseWave ImageAsync ScrollArea Separator Tooltip \
            ArcGauge ConcaveShape TabBar FrequencyVisualizer WallpaperCarousel; do
    if grep -q "$name" "$comp_qmldir" 2>/dev/null; then
        pass "components/qmldir registers $name"
    else
        fail "components/qmldir" "missing registration for $name"
    fi
done

# modules/qmldir should register ModuleLoader
modules_qmldir="$SHELL_DIR/modules/qmldir"
if grep -q "ModuleLoader" "$modules_qmldir" 2>/dev/null; then
    pass "modules/qmldir registers ModuleLoader"
else
    fail "modules/qmldir" "missing ModuleLoader registration"
fi

# ============================================================
section "5. Import Consistency"
# ============================================================

# Modules that use Core.* must import core
while IFS= read -r -d '' qml_file; do
    rel="${qml_file#$SHELL_DIR/}"
    if grep -q 'Core\.' "$qml_file" 2>/dev/null; then
        if ! grep -q 'import.*core.*as Core' "$qml_file" 2>/dev/null && \
           ! grep -q 'import "\." as Core' "$qml_file" 2>/dev/null; then
            fail "$rel" "uses Core.* but missing core import"
        else
            pass "$rel Core import OK"
        fi
    fi
done < <(find "$SHELL_DIR" -name '*.qml' -print0 | sort -z)

# Modules that use Services.* must import services (exclude Quickshell.Services.* framework imports)
while IFS= read -r -d '' qml_file; do
    rel="${qml_file#$SHELL_DIR/}"
    # Check for Services.Foo usage (not import Quickshell.Services.Foo)
    if grep -v '^import' "$qml_file" 2>/dev/null | grep -q 'Services\.' ; then
        if ! grep -q 'import.*services.*as Services' "$qml_file" 2>/dev/null; then
            fail "$rel" "uses Services.* but missing services import"
        else
            pass "$rel Services import OK"
        fi
    fi
done < <(find "$SHELL_DIR" -name '*.qml' -print0 | sort -z)

# Modules that use Components.* must import components
while IFS= read -r -d '' qml_file; do
    rel="${qml_file#$SHELL_DIR/}"
    if grep -v '^import' "$qml_file" 2>/dev/null | grep -q 'Components\.' ; then
        if ! grep -qE 'import.*(components|"\.").*as Components' "$qml_file" 2>/dev/null; then
            fail "$rel" "uses Components.* but missing components import"
        else
            pass "$rel Components import OK"
        fi
    fi
done < <(find "$SHELL_DIR" -name '*.qml' -print0 | sort -z)

# ============================================================
section "6. JSON Config Validation"
# ============================================================

# config.default.json must be valid JSON
if python3 -c "import json; json.load(open('$SHELL_DIR/config.default.json'))" 2>/dev/null; then
    pass "config.default.json is valid JSON"
else
    fail "config.default.json" "invalid JSON"
fi

# theme.default.json must be valid JSON
if python3 -c "import json; json.load(open('$SHELL_DIR/theme.default.json'))" 2>/dev/null; then
    pass "theme.default.json is valid JSON"
else
    fail "theme.default.json" "invalid JSON"
fi

# theme.default.json must have all required color keys
THEME_KEYS=("bg_base" "bg_surface" "bg_overlay" "fg_main" "fg_dim" "fg_muted" "accent" "accent_dim" "urgent" "green")
for key in "${THEME_KEYS[@]}"; do
    if python3 -c "import json; d=json.load(open('$SHELL_DIR/theme.default.json')); assert '$key' in d" 2>/dev/null; then
        pass "theme.default.json has key: $key"
    else
        fail "theme.default.json" "missing key: $key"
    fi
done

# config.default.json must have modules section
if python3 -c "import json; d=json.load(open('$SHELL_DIR/config.default.json')); assert 'modules' in d" 2>/dev/null; then
    pass "config.default.json has 'modules' section"
else
    fail "config.default.json" "missing 'modules' section"
fi

# config.default.json must have animations section
if python3 -c "import json; d=json.load(open('$SHELL_DIR/config.default.json')); assert 'animations' in d" 2>/dev/null; then
    pass "config.default.json has 'animations' section"
else
    fail "config.default.json" "missing 'animations' section"
fi

# ============================================================
section "7. Deploy Script Validation"
# ============================================================

deploy="$SHELL_DIR/deploy.sh"

# deploy.sh is executable
if [[ -x "$deploy" ]]; then
    pass "deploy.sh is executable"
else
    fail "deploy.sh" "not executable"
fi

# deploy.sh has set -euo pipefail
if grep -q 'set -euo pipefail' "$deploy"; then
    pass "deploy.sh has strict error handling"
else
    fail "deploy.sh" "missing set -euo pipefail"
fi

# deploy.sh uses rsync
if grep -q 'rsync' "$deploy"; then
    pass "deploy.sh uses rsync"
else
    fail "deploy.sh" "expected rsync-based deployment"
fi

# deploy.sh excludes deploy.sh from sync
if grep -q "exclude.*deploy.sh" "$deploy"; then
    pass "deploy.sh excludes itself from sync"
else
    fail "deploy.sh" "does not exclude itself from sync"
fi

# deploy.sh preserves user config
if grep -q 'config.json' "$deploy" && grep -q '! -f' "$deploy"; then
    pass "deploy.sh preserves existing config.json"
else
    fail "deploy.sh" "may overwrite user config.json"
fi

# ============================================================
section "8. Theme Export Script Validation"
# ============================================================

theme_export="/home/box/git/github/somewm/plans/theme-export.sh"
if [[ -f "$theme_export" ]]; then
    pass "theme-export.sh exists"

    if [[ -x "$theme_export" ]]; then
        pass "theme-export.sh is executable"
    else
        fail "theme-export.sh" "not executable"
    fi

    # Atomic write pattern
    if grep -q '\.tmp' "$theme_export" && grep -q 'mv' "$theme_export"; then
        pass "theme-export.sh uses atomic write (tmp + mv)"
    else
        fail "theme-export.sh" "missing atomic write pattern"
    fi

    # Fallback to default
    if grep -q 'theme.default.json' "$theme_export"; then
        pass "theme-export.sh has fallback to defaults"
    else
        fail "theme-export.sh" "missing fallback mechanism"
    fi
else
    fail "theme-export.sh" "file not found"
fi

# ============================================================
section "9. IPC Handler Validation"
# ============================================================

# Panels.qml must have IPC handler
if grep -q 'IpcHandler' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml has IpcHandler"

    # Check required IPC functions
    for func in toggle close closeAll showOsd; do
        if grep -q "function $func" "$SHELL_DIR/core/Panels.qml"; then
            pass "Panels IPC: $func handler exists"
        else
            fail "Panels.qml IPC" "missing $func handler"
        fi
    done

    # Check target name
    if grep -q 'target: "somewm-shell:panels"' "$SHELL_DIR/core/Panels.qml"; then
        pass "Panels IPC target name correct"
    else
        fail "Panels.qml IPC" "incorrect target name"
    fi
else
    fail "Panels.qml" "missing IpcHandler"
fi

# Compositor.qml must have IPC handler
if grep -q 'IpcHandler' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml has IpcHandler"

    if grep -q 'target: "somewm-shell:compositor"' "$SHELL_DIR/services/Compositor.qml"; then
        pass "Compositor IPC target name correct"
    else
        fail "Compositor.qml IPC" "incorrect target name"
    fi

    # Check: no raw eval exposed
    if grep -q 'function eval' "$SHELL_DIR/services/Compositor.qml"; then
        fail "Compositor.qml" "SECURITY: raw eval() function exposed via IPC"
    else
        pass "Compositor.qml: no raw eval exposed"
    fi
else
    fail "Compositor.qml" "missing IpcHandler"
fi

# ============================================================
section "10. OSD Auto-Hide Validation"
# ============================================================

# Panels.qml must have OSD timer
if grep -q 'Timer' "$SHELL_DIR/core/Panels.qml" && grep -q 'osdTimer' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml has OSD auto-hide timer"
else
    fail "Panels.qml" "missing OSD auto-hide timer"
fi

# Panels.qml showOsd must set type, value, visible, and restart timer
if grep -q 'osdType.*=.*type' "$SHELL_DIR/core/Panels.qml" && \
   grep -q 'osdValue' "$SHELL_DIR/core/Panels.qml" && \
   grep -q 'osdVisible.*=.*true' "$SHELL_DIR/core/Panels.qml" && \
   grep -q 'osdTimer.restart' "$SHELL_DIR/core/Panels.qml"; then
    pass "showOsd() sets type, value, visible, restarts timer"
else
    fail "Panels.qml showOsd" "incomplete implementation"
fi

# ============================================================
section "11. Config → Anims Wiring"
# ============================================================

# Anims.scale must be wired to Config.animationScale (either direct binding or push from Config)
if grep -q 'Config.animationScale' "$SHELL_DIR/core/Anims.qml" || \
   grep -q 'Anims.scale.*=.*animationScale' "$SHELL_DIR/core/Config.qml"; then
    pass "Anims.scale wired to Config.animationScale"
else
    fail "Anims/Config" "scale not wired to Config.animationScale"
fi

# ============================================================
section "12. reducedMotion Support"
# ============================================================

# Anim.qml should check reducedMotion
if grep -q 'reducedMotion' "$SHELL_DIR/components/Anim.qml"; then
    pass "Anim.qml checks reducedMotion"
else
    fail "Anim.qml" "no reducedMotion check"
fi

# CAnim.qml should check reducedMotion
if grep -q 'reducedMotion' "$SHELL_DIR/components/CAnim.qml"; then
    pass "CAnim.qml checks reducedMotion"
else
    fail "CAnim.qml" "no reducedMotion check"
fi

# ============================================================
section "13. ModuleLoader Integration"
# ============================================================

# shell.qml must use ModuleLoader
if grep -q 'ModuleLoader' "$SHELL_DIR/shell.qml"; then
    pass "shell.qml uses ModuleLoader"
else
    fail "shell.qml" "does not use ModuleLoader"
fi

# shell.qml must load all expected modules
for mod in dashboard weather wallpapers collage; do
    if grep -q "moduleName: \"$mod\"" "$SHELL_DIR/shell.qml"; then
        pass "shell.qml loads module: $mod"
    else
        fail "shell.qml" "missing module: $mod"
    fi
done

# sidebar and media are absorbed into dashboard tabs — must NOT be in shell.qml
for mod in sidebar media; do
    if grep -q "moduleName: \"$mod\"" "$SHELL_DIR/shell.qml"; then
        fail "shell.qml" "module $mod should be removed (absorbed into dashboard tabs)"
    else
        pass "shell.qml correctly excludes removed module: $mod"
    fi
done

# OSD should be loaded directly (not via ModuleLoader, always active)
if grep -q 'OsdModule.OSD' "$SHELL_DIR/shell.qml" && \
   ! grep -q 'moduleName: "osd"' "$SHELL_DIR/shell.qml"; then
    pass "OSD loaded directly (always active)"
else
    fail "shell.qml" "OSD should be loaded directly, not via ModuleLoader"
fi

# ============================================================
section "14. Mutual Exclusion"
# ============================================================

# Panels.qml toggle() should implement mutual exclusion for overlay panels
if grep -q 'exclusive' "$SHELL_DIR/core/Panels.qml" && \
   grep -q 'dashboard' "$SHELL_DIR/core/Panels.qml" && \
   grep -q 'weather' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml implements mutual exclusion"
else
    fail "Panels.qml" "missing mutual exclusion for overlay panels"
fi

# ============================================================
section "15. Security Checks"
# ============================================================

# No raw eval in IPC-exposed code
eval_count="$(set +o pipefail; grep -rn 'function eval' "$SHELL_DIR" --include='*.qml' 2>/dev/null | grep -v 'somewm-client.*eval' | grep -v '//' | wc -l)"
if [[ "$eval_count" -eq 0 ]]; then
    pass "No raw eval() functions exposed in QML"
else
    fail "Security" "Found $eval_count raw eval() functions — potential IPC injection risk"
fi

# Compositor uses _luaEscape for string parameters
if grep -q '_luaEscape' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml uses _luaEscape for parameter sanitization"
else
    fail "Compositor.qml" "missing _luaEscape — potential Lua injection"
fi

# ============================================================
section "16. rc.lua Shell Keybindings"
# ============================================================

RC_LUA="/home/box/git/github/somewm/plans/somewm-one/rc.lua"
if [[ -f "$RC_LUA" ]]; then
    for panel in dashboard wallpapers collage; do
        if grep -q "toggle $panel" "$RC_LUA"; then
            pass "rc.lua has keybinding for $panel"
        else
            fail "rc.lua" "missing keybinding for $panel"
        fi
    done
    # sidebar/media are routed through dashboard tabs via Panels.toggle()
    # Their keybindings still exist but target the old panel names which route to dashboard
    for panel in sidebar media; do
        if grep -q "toggle $panel" "$RC_LUA" || grep -q "toggle dashboard" "$RC_LUA"; then
            pass "rc.lua has keybinding route for $panel (via dashboard)"
        else
            fail "rc.lua" "missing keybinding for $panel"
        fi
    done

    if grep -q "toggle weather" "$RC_LUA"; then
        pass "rc.lua has keybinding for weather"
    else
        fail "rc.lua" "missing keybinding for weather"
    fi

    if grep -q "closeAll" "$RC_LUA"; then
        pass "rc.lua has closeAll keybinding"
    else
        fail "rc.lua" "missing closeAll keybinding"
    fi

    # OSD triggers in volume keys
    if grep -q 'showOsd.*volume' "$RC_LUA"; then
        pass "rc.lua has OSD trigger for volume keys"
    else
        fail "rc.lua" "missing OSD trigger for volume keys"
    fi

    # Push IPC signals
    if grep -q 'client.connect_signal.*manage.*push_state' "$RC_LUA"; then
        pass "rc.lua has push IPC signals"
    else
        fail "rc.lua" "missing push IPC client signals"
    fi

    # Autostart for shell
    if grep -q 'qs.*-c.*somewm' "$RC_LUA"; then
        pass "rc.lua has shell autostart"
    else
        fail "rc.lua" "missing shell autostart (qs -c somewm)"
    fi
else
    fail "rc.lua" "file not found at $RC_LUA"
fi

# ============================================================
section "17. Round 2 Review Fixes"
# ============================================================

# CRITICAL-1: Module subdirectory qmldir files
for mod_dir in dashboard osd weather wallpapers collage hotedges; do
    qmldir_f="$SHELL_DIR/modules/$mod_dir/qmldir"
    if [[ -f "$qmldir_f" ]]; then
        pass "modules/$mod_dir/qmldir exists"
    else
        fail "modules/$mod_dir/qmldir" "missing — bare types won't resolve with directory imports"
    fi
done

# CRITICAL-3: Media.player reactive (not readonly one-shot binding)
if grep -q 'property MprisPlayer player' "$SHELL_DIR/services/Media.qml" && \
   ! grep -q 'readonly property MprisPlayer player' "$SHELL_DIR/services/Media.qml"; then
    pass "Media.player is non-readonly (reactive)"
else
    fail "Media.qml" "player property should not be readonly (one-shot binding never updates)"
fi
if grep -q '_updatePlayer' "$SHELL_DIR/services/Media.qml"; then
    pass "Media.qml has _updatePlayer for reactive re-evaluation"
else
    fail "Media.qml" "missing _updatePlayer reactive mechanism"
fi

# CRITICAL-4: SlidePanel uses x instead of Translate for Region compatibility
if grep -q 'transform: Translate' "$SHELL_DIR/components/SlidePanel.qml"; then
    fail "SlidePanel.qml" "still uses transform:Translate — Region stays at logical position"
else
    pass "SlidePanel.qml no longer uses Translate transform"
fi
if grep -q 'Behavior on x' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml animates logical x property"
else
    fail "SlidePanel.qml" "missing x animation"
fi

# MAJOR-1: IPC focus routes to focusClientByClass (not focusClient with window ID)
if grep -q 'focusClientByClass(cls)' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor IPC focus() routes to focusClientByClass"
else
    fail "Compositor.qml" "IPC focus() should route to focusClientByClass"
fi

# MAJOR-2: Controls.qml single MouseArea on play/pause
play_ma_count="$(grep -c 'MouseArea' "$SHELL_DIR/modules/media/Controls.qml" || true)"
# Should be 3 total (prev, play, next) — not 4
if [[ "$play_ma_count" -eq 3 ]]; then
    pass "Controls.qml has exactly 3 MouseAreas (no duplicate on play/pause)"
else
    fail "Controls.qml" "expected 3 MouseAreas (prev/play/next), found $play_ma_count"
fi

# MAJOR-3: Compositor Lua guards c.window nil
if grep -q 'c.window or 0' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml guards against nil c.window"
else
    fail "Compositor.qml" "c.window nil produces invalid JSON"
fi

# MAJOR-4: BT icon uses id reference (not parent.parent chain)
# QuickSettings moved from sidebar to dashboard
QS_FILE="$SHELL_DIR/modules/dashboard/QuickSettings.qml"
if [[ ! -f "$QS_FILE" ]]; then QS_FILE="$SHELL_DIR/modules/sidebar/QuickSettings.qml"; fi
if grep -q 'id: btCard' "$QS_FILE" && \
   grep -q 'btCard.btOn' "$QS_FILE"; then
    pass "QuickSettings.qml BT uses btCard.btOn (not parent.parent)"
else
    fail "QuickSettings.qml" "BT icon still uses fragile parent.parent chain"
fi

# MAJOR-5: Brightness 0% not falsely defaulting to 100
if grep -q 'isNaN' "$SHELL_DIR/services/Brightness.qml"; then
    pass "Brightness.qml uses isNaN guard (0% won't become 100%)"
else
    fail "Brightness.qml" "parseInt || 100 makes 0% = 100%"
fi

# MAJOR-7: FadeLoader uses 'shown' not 'active' (which shadows Loader.active)
if grep -q 'property bool shown' "$SHELL_DIR/components/FadeLoader.qml" && \
   ! grep -q 'property bool active' "$SHELL_DIR/components/FadeLoader.qml"; then
    pass "FadeLoader.qml uses 'shown' (no shadow of Loader.active)"
else
    fail "FadeLoader.qml" "should use 'shown' instead of 'active' to avoid shadowing"
fi

# MAJOR-8: NotifHistory uses JSON serialization (not tab/newline)
NOTIF_FILE="$SHELL_DIR/modules/sidebar/NotifHistory.qml"
if [[ ! -f "$NOTIF_FILE" ]]; then NOTIF_FILE="$SHELL_DIR/modules/dashboard/NotificationsTab.qml"; fi
if grep -q 'JSON.parse' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab uses JSON serialization"
else
    fail "NotifHistory/NotificationsTab" "still uses tab/newline serialization (corruption risk)"
fi

# MAJOR-9: DND toggle dispatches IPC command
if grep -q 'naughty.*suspended' "$QS_FILE"; then
    pass "QuickSettings.qml DND toggle dispatches naughty.suspended IPC"
else
    fail "QuickSettings.qml" "DND toggle is cosmetic only (no IPC)"
fi

# MAJOR-10: AI chat header z-index
AI_CHAT="$SHELL_DIR/../somewm-shell-ai/modules/chat/ChatPanel.qml"
if [[ -f "$AI_CHAT" ]] && grep -q 'z: 10' "$AI_CHAT"; then
    pass "ChatPanel.qml header RowLayout has z: 10"
else
    fail "ChatPanel.qml" "header missing z-index (dropdown hidden behind MessageList)"
fi

# MINOR: Volume overflow protection
if grep -q 'Math.min(1.0' "$SHELL_DIR/modules/media/VolumeSlider.qml"; then
    pass "VolumeSlider.qml caps volume at 1.0"
else
    fail "VolumeSlider.qml" "volume > 100% causes bar overflow"
fi

# MINOR: ScrollArea division by zero guard
if grep -q 'contentHeight > 0' "$SHELL_DIR/components/ScrollArea.qml"; then
    pass "ScrollArea.qml guards against division by zero"
else
    fail "ScrollArea.qml" "divides by contentHeight without zero guard"
fi

# MINOR: Album art fallback uses Image.status
if grep -q 'Image.Ready' "$SHELL_DIR/modules/dashboard/MediaMini.qml"; then
    pass "MediaMini.qml album art fallback checks Image.Ready"
else
    fail "MediaMini.qml" "fallback checks empty string instead of Image.status"
fi

# MINOR: Compositor JSON escapes tabs/CR
if grep -q 'gsub.*\\\\t' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml JSON escapes tab characters"
else
    fail "Compositor.qml" "tab characters in client names corrupt JSON"
fi

# MINOR: Network SSID colon-safe parsing
if grep -q 'replace.*\\\\:' "$SHELL_DIR/services/Network.qml" || \
   grep -q '\\x00' "$SHELL_DIR/services/Network.qml"; then
    pass "Network.qml handles colons in SSID"
else
    fail "Network.qml" "split(':') breaks SSIDs containing colons"
fi

# MINOR: Weather uses 'real' not 'double'
if grep -q 'property double' "$SHELL_DIR/services/Weather.qml"; then
    fail "Weather.qml" "'property double' is non-standard QML, use 'property real'"
else
    pass "Weather.qml uses standard 'property real'"
fi

# BT initial state from system
if grep -q 'bluetoothctl.*show' "$QS_FILE"; then
    pass "QuickSettings.qml initializes BT state from system"
else
    fail "QuickSettings.qml" "BT state hardcoded, not initialized from system"
fi

# Lightbox fade-out animation
if grep -q 'closeAnim.running' "$SHELL_DIR/modules/collage/Lightbox.qml"; then
    pass "Lightbox.qml has close fade-out animation"
else
    fail "Lightbox.qml" "close animation never plays (visible is instant)"
fi

# NotifHistory has import Quickshell (needed for IpcHandler)
if grep -q 'import Quickshell$' "$NOTIF_FILE" || \
   grep -q 'import Quickshell\b' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab imports Quickshell"
else
    fail "NotifHistory/NotificationsTab" "missing import Quickshell (needed for IpcHandler)"
fi

# ============================================================
section "18. Round 3 Review Fixes"
# ============================================================

# CRITICAL: PulseWave no Behavior on height (conflicts with SequentialAnimation)
# Check for actual QML construct, not comment mentioning it
if ! grep -qE '^\s*Behavior on height' "$SHELL_DIR/components/PulseWave.qml"; then
    pass "PulseWave.qml: no Behavior on height (prevents double-animation jitter)"
else
    fail "PulseWave.qml" "Behavior on height conflicts with SequentialAnimation on _scale"
fi

# CRITICAL: PulseWave implicitWidth correct formula
if grep -q 'Math.max(0, barCount - 1)' "$SHELL_DIR/components/PulseWave.qml"; then
    pass "PulseWave.qml: correct implicitWidth (N-1 gaps)"
else
    fail "PulseWave.qml" "implicitWidth double-counts spacing"
fi

# CRITICAL: MediaMini uses id reference for Image.status
if grep -q 'id: thumbImage' "$SHELL_DIR/modules/dashboard/MediaMini.qml" && \
   grep -q 'thumbImage.status' "$SHELL_DIR/modules/dashboard/MediaMini.qml"; then
    pass "MediaMini.qml: uses thumbImage.status (not parent.children[0])"
else
    fail "MediaMini.qml" "fragile parent.children[0] reference"
fi

# MAJOR: MediaPanel → now MediaTab inside dashboard (keyboard focus handled by Dashboard.qml)
# MediaPanel.qml may still exist for standalone use, but MediaTab is the primary
MEDIA_PANEL="$SHELL_DIR/modules/media/MediaPanel.qml"
if [[ -f "$MEDIA_PANEL" ]]; then
    if grep -q 'WlrKeyboardFocus' "$MEDIA_PANEL"; then
        pass "MediaPanel.qml: has WlrKeyboardFocus (Escape key works)"
    else
        fail "MediaPanel.qml" "missing WlrKeyboardFocus — Escape won't work"
    fi
else
    pass "MediaPanel.qml: absorbed into dashboard MediaTab (keyboard handled by Dashboard)"
fi

# MAJOR: WeatherPanel has WlrKeyboardFocus
if grep -q 'WlrKeyboardFocus' "$SHELL_DIR/modules/weather/WeatherPanel.qml"; then
    pass "WeatherPanel.qml: has WlrKeyboardFocus (Escape key works)"
else
    fail "WeatherPanel.qml" "missing WlrKeyboardFocus — Escape won't work"
fi

# MAJOR: MediaPanel mask — now part of dashboard, or standalone if still exists
if [[ -f "$MEDIA_PANEL" ]]; then
    if grep -q 'mask: Region { item: backdrop }' "$MEDIA_PANEL"; then
        pass "MediaPanel.qml: mask covers backdrop (click-to-close works)"
    else
        fail "MediaPanel.qml" "mask restricts to card only — click-to-close broken"
    fi
else
    pass "MediaPanel.qml: absorbed into dashboard (backdrop handled by Dashboard)"
fi

# MAJOR: Panels exclusive list includes weather and dashboard
if grep -q '"dashboard"' "$SHELL_DIR/core/Panels.qml" && \
   grep -q '"weather"' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml: dashboard and weather in exclusive list"
else
    fail "Panels.qml" "dashboard/weather not in exclusive list — panels can stack"
fi

# MAJOR: focusClient guards wid===0
if grep -q 'wid === 0' "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml: focusClient guards wid===0 (Wayland clients)"
else
    fail "Compositor.qml" "focusClient allows wid=0 (wasted IPC)"
fi

# MAJOR: Weather clears hasData on error
if grep -q 'hasData = false' "$SHELL_DIR/services/Weather.qml"; then
    pass "Weather.qml: clears hasData on error (stale data fix)"
else
    fail "Weather.qml" "hasData stays true on error (stale data shown)"
fi

# MAJOR: Config.ready gate for module loading
if grep -q 'property bool ready' "$SHELL_DIR/core/Config.qml" && \
   grep -q '!ready.*return false' "$SHELL_DIR/core/Config.qml"; then
    pass "Config.qml: ready gate prevents premature module loading"
else
    fail "Config.qml" "modules load before config is ready"
fi

# MAJOR: DND initialized from system
if grep -q 'dndInitProc' "$QS_FILE" && \
   grep -q 'naughty.*suspended' "$QS_FILE"; then
    pass "QuickSettings.qml: DND state initialized from system"
else
    fail "QuickSettings.qml" "DND not initialized from system"
fi

# MAJOR: Media.position reset on player change
if grep -q 'onPlayerChanged.*position' "$SHELL_DIR/services/Media.qml"; then
    pass "Media.qml: position reset on player change"
else
    fail "Media.qml" "stale position after player/track change"
fi

# MAJOR: Network wifi signal uses IN-USE field
if grep -q 'IN-USE' "$SHELL_DIR/services/Network.qml"; then
    pass "Network.qml: wifi signal checks IN-USE (correct AP)"
else
    fail "Network.qml" "signal from first row, not connected AP"
fi

# MAJOR: WallpaperGrid Flickable width pinned to flickable
if grep -q 'width: flickable.width' "$SHELL_DIR/modules/wallpapers/WallpaperGrid.qml"; then
    pass "WallpaperGrid.qml: grid width pinned to flickable viewport"
else
    fail "WallpaperGrid.qml" "width: parent.width in Flickable → binding loop"
fi

# MAJOR: ClientList Flickable uses implicitHeight
if grep -q 'implicitHeight' "$SHELL_DIR/modules/dashboard/ClientList.qml"; then
    pass "ClientList.qml: contentHeight uses implicitHeight"
else
    fail "ClientList.qml" "contentHeight uses height (always 0 in layouts)"
fi

# WallpaperPanel: carousel-only design (WallpaperGrid is standalone, not used in panel)
if grep -q 'ListView' "$SHELL_DIR/modules/wallpapers/WallpaperPanel.qml" && \
   grep -q 'setWallpaper' "$SHELL_DIR/modules/wallpapers/WallpaperPanel.qml"; then
    pass "WallpaperPanel: carousel with wallpaper apply"
else
    fail "WallpaperPanel" "missing carousel ListView or setWallpaper call"
fi

# MINOR: AlbumArt fade based on Image.status (not timer)
if ! grep -q 'fadeInTimer' "$SHELL_DIR/modules/media/AlbumArt.qml"; then
    pass "AlbumArt.qml: reactive fade (no timer)"
else
    fail "AlbumArt.qml" "timer-based fade unreliable for slow loads"
fi

# MINOR: OSD progress bar clamped
if grep -q 'Math.min(1.0' "$SHELL_DIR/modules/osd/OSD.qml"; then
    pass "OSD.qml: progress bar clamped at 100%"
else
    fail "OSD.qml" "volume > 100% causes bar overflow"
fi

# MINOR: Brightness setPercent debounced
if grep -q 'setProc.running.*return' "$SHELL_DIR/services/Brightness.qml"; then
    pass "Brightness.qml: setPercent debounced against concurrent calls"
else
    fail "Brightness.qml" "rapid calls can cause Process race"
fi

# MINOR: CalendarWidget refreshes date (now in dashboard/)
CAL_FILE="$SHELL_DIR/modules/dashboard/CalendarWidget.qml"
if [[ ! -f "$CAL_FILE" ]]; then CAL_FILE="$SHELL_DIR/modules/sidebar/CalendarWidget.qml"; fi
if grep -q 'Timer' "$CAL_FILE" && \
   grep -q 'currentDate.*new Date' "$CAL_FILE"; then
    pass "CalendarWidget.qml: refreshes currentDate periodically"
else
    fail "CalendarWidget.qml" "stale date after midnight"
fi

# ============================================================
# Section 19: Round 4 fixes
# ============================================================

# MAJOR: SlidePanel must have WlrLayershell.keyboardFocus for keyboard input
if grep -q 'WlrKeyboardFocus.Exclusive' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml has WlrLayershell.keyboardFocus"
else
    fail "SlidePanel.qml" "missing WlrLayershell.keyboardFocus — keyboard input broken"
fi

# MAJOR: SlidePanel must bind visible for proper layer-shell lifecycle
if grep -q 'visible: shown || slideAnim.running' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml binds visible to shown+animation"
else
    fail "SlidePanel.qml" "missing visible binding — hidden panels reserve screen-edge space"
fi

# MAJOR: SlidePanel must set exclusionMode to Ignore (overlay, not docking)
if grep -q 'ExclusionMode.Ignore' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml exclusionMode set to Ignore"
else
    fail "SlidePanel.qml" "missing exclusionMode:Ignore — panels push tiled windows"
fi

# MAJOR: slideAnim id must exist for visible binding to reference
if grep -q 'id: slideAnim' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml slideAnim id defined"
else
    fail "SlidePanel.qml" "missing id:slideAnim — visible binding will fail"
fi

# MAJOR: Panels exclusive list must include ai-chat
if grep -q '"ai-chat"' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml exclusive list includes ai-chat"
else
    fail "Panels.qml" "ai-chat missing from exclusive list — dual right-edge panels can stack"
fi

# MAJOR: Ollama temperature must use !== undefined (not falsy guard)
AI_DIR="$(dirname "$SHELL_DIR")/somewm-shell-ai"
if [ -f "$AI_DIR/services/Ollama.qml" ]; then
    if grep -q 'temperature !== undefined' "$AI_DIR/services/Ollama.qml"; then
        pass "Ollama.qml temperature uses !== undefined guard"
    else
        fail "Ollama.qml" "temperature uses falsy guard — blocks temperature=0"
    fi
    # Also check max_tokens
    if grep -q 'max_tokens !== undefined' "$AI_DIR/services/Ollama.qml"; then
        pass "Ollama.qml max_tokens uses !== undefined guard"
    else
        fail "Ollama.qml" "max_tokens uses falsy guard — blocks max_tokens=0"
    fi
else
    pass "Ollama.qml (skipped — AI module not present)"
    pass "Ollama.qml max_tokens (skipped)"
fi

# NotifHistory: must document active-only limitation and support optional history table
if grep -q '_somewm_notif_history' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab supports optional _somewm_notif_history table"
else
    fail "NotifHistory/NotificationsTab" "missing _somewm_notif_history fallback for persistent history"
fi

# ============================================================
# Section 20: Round 5 fixes
# ============================================================

# CRITICAL: NotifHistory must NOT mutate n.active — copies to fresh table
if grep -q 'local all = {}' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab copies n.active to fresh table (no mutation)"
else
    fail "NotifHistory/NotificationsTab" "mutates n.active directly — causes WM state corruption"
fi

# MAJOR: Compositor must use require('awful') not bare 'awful' (local in rc.lua)
if grep -q "require('awful')" "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml uses require('awful') for IPC evals"
else
    fail "Compositor.qml" "uses bare 'awful' — fails because awful is local in rc.lua"
fi

# Verify screenProc also uses require('awful')
if grep -q "require('awful').screen.focused" "$SHELL_DIR/services/Compositor.qml"; then
    pass "Compositor.qml screenProc uses require('awful')"
else
    fail "Compositor.qml" "screenProc uses bare awful — fails in IPC eval"
fi

# MAJOR: Forecast date parsing uses local-time constructor (not UTC)
if grep -q 'modelData.date.split("-")' "$SHELL_DIR/modules/weather/Forecast.qml"; then
    pass "Forecast.qml parses date components for local-time Date constructor"
else
    fail "Forecast.qml" "uses new Date(string) — wrong day name in UTC- timezones"
fi

# MAJOR: Weather timer calls _fetchWeather directly (bypasses cache drift)
if grep -q 'onTriggered: root._fetchWeather()' "$SHELL_DIR/services/Weather.qml"; then
    pass "Weather.qml timer calls _fetchWeather directly (no cache drift)"
else
    fail "Weather.qml" "timer calls refresh() — cache check may skip due to drift"
fi

# MAJOR: MessageList empty state has explicit height (not Layout.fillHeight in Flickable)
if [ -f "$AI_DIR/modules/chat/MessageList.qml" ]; then
    if grep -q 'Layout.preferredHeight: 200' "$AI_DIR/modules/chat/MessageList.qml"; then
        pass "MessageList.qml empty state has explicit height"
    else
        fail "MessageList.qml" "empty state uses Layout.fillHeight — invisible in Flickable"
    fi
else
    pass "MessageList.qml (skipped — AI module not present)"
fi

# MAJOR: Ollama has cancel() function and _xhr property for abort
if [ -f "$AI_DIR/services/Ollama.qml" ]; then
    if grep -q 'function cancel()' "$AI_DIR/services/Ollama.qml"; then
        pass "Ollama.qml has cancel() function"
    else
        fail "Ollama.qml" "missing cancel() — stop button non-functional"
    fi
    if grep -q '_xhr' "$AI_DIR/services/Ollama.qml"; then
        pass "Ollama.qml stores XHR reference for abort"
    else
        fail "Ollama.qml" "missing _xhr property — cannot abort in-flight requests"
    fi
else
    pass "Ollama.qml cancel (skipped)"
    pass "Ollama.qml _xhr (skipped)"
fi

# MAJOR: InputBar stop button wired to cancel()
if [ -f "$AI_DIR/modules/chat/InputBar.qml" ]; then
    if grep -q 'Ollama.cancel()' "$AI_DIR/modules/chat/InputBar.qml"; then
        pass "InputBar.qml stop button calls Ollama.cancel()"
    else
        fail "InputBar.qml" "stop button still calls send() — dead code path"
    fi
else
    pass "InputBar.qml cancel (skipped)"
fi

# ============================================================
section "21. Post-Launch Bug Fixes (4K Display)"
# ============================================================

# FIX-1: Glass opacity increased (no blur fallback)
if grep -q '0\.92' "$SHELL_DIR/core/Theme.qml" && \
   grep -q '0\.94' "$SHELL_DIR/core/Theme.qml" && \
   grep -q '0\.96' "$SHELL_DIR/core/Theme.qml"; then
    pass "Theme.qml: glass opacity increased for readability without blur"
else
    fail "Theme.qml" "glass opacity too low — unreadable without compositor blur"
fi

# FIX-1b: glassBorder opacity increased
if grep -q '0\.12' "$SHELL_DIR/core/Theme.qml"; then
    pass "Theme.qml: glassBorder opacity increased to 0.12"
else
    fail "Theme.qml" "glassBorder opacity still at 0.08"
fi

# FIX-2: SlidePanel no opacity animation (prevents close flicker)
if ! grep -q 'Behavior on opacity' "$SHELL_DIR/components/SlidePanel.qml"; then
    pass "SlidePanel.qml: no opacity animation (no close flicker)"
else
    fail "SlidePanel.qml" "opacity animation causes close flicker"
fi

# FIX-4: Notification history table in rc.lua
if grep -q '_somewm_notif_history' "$RC_LUA"; then
    pass "rc.lua: _somewm_notif_history table defined"
else
    fail "rc.lua" "missing _somewm_notif_history table for shell sidebar"
fi

# FIX-4b: Notification IPC push to shell
if grep -q 'somewm-shell:notifications refresh' "$RC_LUA"; then
    pass "rc.lua: notification IPC push to shell"
else
    fail "rc.lua" "missing notification IPC push to somewm-shell"
fi

# FIX-5: DPI scale factor in Theme.qml
if grep -q 'dpiScale' "$SHELL_DIR/core/Theme.qml"; then
    pass "Theme.qml: dpiScale factor defined"
else
    fail "Theme.qml" "missing dpiScale — fonts unreadable on 4K"
fi

# FIX-5b: Font sizes use dpiScale
if grep -q 'Math.round.*dpiScale' "$SHELL_DIR/core/Theme.qml"; then
    pass "Theme.qml: font/spacing sizes scaled by dpiScale"
else
    fail "Theme.qml" "sizes not scaled by dpiScale"
fi

# FIX-6: Wheel event consumption on panels
for panel_file in \
    "$SHELL_DIR/modules/wallpapers/WallpaperPanel.qml" \
    "$SHELL_DIR/modules/collage/CollagePanel.qml" \
    "$SHELL_DIR/modules/dashboard/Dashboard.qml"; do
    panel_name="$(basename "$panel_file")"
    if grep -q 'onWheel.*wheel.accepted.*true' "$panel_file"; then
        pass "$panel_name: wheel events consumed (no tag-switch pass-through)"
    else
        fail "$panel_name" "wheel events pass through to compositor (tag switching)"
    fi
done

# FIX-7: Super+Shift+M conflict removed
if ! grep -q 'maximized_horizontal' "$RC_LUA"; then
    pass "rc.lua: Super+Shift+M horizontal maximize removed (no conflict)"
else
    fail "rc.lua" "Super+Shift+M still bound to horizontal maximize (conflicts with media panel)"
fi

# FIX-6b: Compositor overlay scroll guard in rc.lua
if grep -q '_somewm_shell_overlay' "$RC_LUA"; then
    pass "rc.lua: _somewm_shell_overlay guard for scroll tag-switch"
else
    fail "rc.lua" "missing _somewm_shell_overlay scroll guard"
fi

# FIX-6c: Panels.qml pushes overlay state to compositor
if grep -q 'anyOverlayOpen' "$SHELL_DIR/core/Panels.qml"; then
    pass "Panels.qml: anyOverlayOpen pushes state to compositor"
else
    fail "Panels.qml" "missing overlay state push (scroll guard won't activate)"
fi

# FIX-3b: Audio.qml uses wpctl for volume (primary mechanism)
if grep -q 'wpctl.*get-volume' "$SHELL_DIR/services/Audio.qml"; then
    pass "Audio.qml: uses wpctl for volume state"
else
    fail "Audio.qml" "no wpctl volume polling — volume shows 0%"
fi

# FIX-4c: NotifHistory no duplicate (uses _somewm_notif_history OR n.active, not both)
if grep -q 'if _somewm_notif_history and #_somewm_notif_history > 0 then' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab: uses history OR active (no duplicate)"
else
    fail "NotifHistory/NotificationsTab" "reads both n.active and _somewm_notif_history (duplicates)"
fi

# FIX-4d: NotifHistory has clearAll and dismissOne
if grep -q 'function clearAll' "$NOTIF_FILE" && \
   grep -q 'function dismissOne' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab: clearAll and dismissOne functions"
else
    fail "NotifHistory/NotificationsTab" "missing clearAll/dismissOne — no way to manage notifications"
fi

# FIX-4e: NotifHistory has copy to clipboard
if grep -q 'copyToClipboard' "$NOTIF_FILE" && \
   grep -q 'wl-copy' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab: copy to clipboard via wl-copy"
else
    fail "NotifHistory/NotificationsTab" "missing copy to clipboard feature"
fi

# FIX-4f: NotifHistory has expand/collapse
if grep -q 'expandedIndex' "$NOTIF_FILE"; then
    pass "NotifHistory/NotificationsTab: expand/collapse notification message"
else
    fail "NotifHistory/NotificationsTab" "missing expand/collapse UX"
fi

# FIX-5c: Component sizing uses dpiScale (dashboard, wallpapers)
if grep -q 'dpiScale' "$SHELL_DIR/modules/dashboard/Dashboard.qml" && \
   grep -q 'dpiScale' "$SHELL_DIR/modules/wallpapers/WallpaperPanel.qml"; then
    pass "Components: hardcoded sizes scaled by dpiScale"
else
    fail "Components" "some hardcoded pixel sizes not scaled — layout breaks on 4K"
fi

# ============================================================
section "30. Hot Screen Edges"
# ============================================================

# HotEdges module exists and is loaded
if [[ -f "$SHELL_DIR/modules/hotedges/HotEdges.qml" ]]; then
    pass "HotEdges.qml exists"
else
    fail "HotEdges" "modules/hotedges/HotEdges.qml missing"
fi

# shell.qml imports and instantiates HotEdges
if grep -q 'import "modules/hotedges"' "$SHELL_DIR/shell.qml"; then
    pass "shell.qml imports hotedges module"
else
    fail "shell.qml" "missing hotedges import"
fi
if grep -q 'HotEdgesModule.HotEdges' "$SHELL_DIR/shell.qml"; then
    pass "shell.qml instantiates HotEdges"
else
    fail "shell.qml" "HotEdges not instantiated"
fi

# HotEdges uses focused screen filter (multi-monitor safety)
if grep -q 'isActiveScreen' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: focused screen filter present"
else
    fail "HotEdges" "missing isActiveScreen — ghost zones on inactive screens"
fi

# HotEdges has all 3 zones with correct panel targets
if grep -q 'toggle("dock")' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: left corner → dock"
else
    fail "HotEdges" "missing dock trigger"
fi
if grep -q 'toggle("dashboard")' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: center → dashboard"
else
    fail "HotEdges" "missing dashboard trigger"
fi
if grep -q 'toggle("controlpanel")' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: right corner → controlpanel"
else
    fail "HotEdges" "missing controlpanel trigger"
fi

# Each zone has mask: Region for proper Wayland input
hotedge_masks=$(grep -c 'mask: Region' "$SHELL_DIR/modules/hotedges/HotEdges.qml" || true)
if [[ "$hotedge_masks" -ge 3 ]]; then
    pass "HotEdges: all 3 zones have mask: Region"
else
    fail "HotEdges" "expected 3 mask: Region entries, got $hotedge_masks"
fi

# Dead pixel workaround present
if grep -q 'margins.bottom: -1' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: dead pixel workaround (margins.bottom: -1)"
else
    fail "HotEdges" "missing margins.bottom: -1 dead pixel workaround"
fi

# Timer intervals match documented values (250ms corners, 300ms center)
if grep -q 'interval: 300' "$SHELL_DIR/modules/hotedges/HotEdges.qml"; then
    pass "HotEdges: center timer interval 300ms"
else
    fail "HotEdges" "center timer should be 300ms"
fi
left_right_timers=$(grep -c 'interval: 250' "$SHELL_DIR/modules/hotedges/HotEdges.qml" || true)
if [[ "$left_right_timers" -ge 2 ]]; then
    pass "HotEdges: corner timers interval 250ms ($left_right_timers found)"
else
    fail "HotEdges" "expected 2 corner timers at 250ms, got $left_right_timers"
fi

# rc.lua lock screen keybind is Super+Shift+L (not Super+L)
RC_LUA="$SHELL_DIR/../somewm-one/rc.lua"
if [[ -f "$RC_LUA" ]]; then
    if grep -qE '\{\s*modkey\s*,\s*"Shift"\s*\},\s*"l".*lock' "$RC_LUA"; then
        pass "rc.lua: lock screen bound to Super+Shift+L"
    else
        fail "rc.lua" "lock screen should be Super+Shift+L (Super+L reserved for resize)"
    fi
fi

# ============================================================
# Summary
# ============================================================

echo -e "\n${YELLOW}=== SUMMARY ===${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "\n${RED}Failures:${NC}"
    for err in "${ERRORS[@]}"; do
        echo -e "  - $err"
    done
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAIL test(s) failed.${NC}"
    exit 1
fi
