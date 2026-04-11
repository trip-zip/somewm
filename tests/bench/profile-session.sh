#!/usr/bin/env bash
#
# Profile your live compositor session.
#
# Attaches perf to the running somewm process while you use it normally.
# Produces a flamegraph and optionally a Lua-level profile via jit.p.
#
# Usage:
#   tests/bench/profile-session.sh              # 30s profile
#   tests/bench/profile-session.sh 60           # 60s profile
#   tests/bench/profile-session.sh --lua        # Also capture Lua profile
#   tests/bench/profile-session.sh --save main  # Save with label
#   tests/bench/profile-session.sh --diff main  # Diff against saved profile
#
# Requires: perf, FlameGraph tools (stackcollapse-perf.pl, flamegraph.pl)

set -e

SOMEWM_CLIENT="${SOMEWM_CLIENT:-./build-bench/somewm-client}"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/tools/FlameGraph}"
RESULTS_DIR="tests/bench/results"
DURATION=30
LUA_PROFILE=0
SAVE_LABEL=""
DIFF_LABEL=""

cd "$(dirname "$0")/../.."

# Pre-flight: verify FlameGraph tools
for tool in stackcollapse-perf.pl flamegraph.pl; do
    if [ ! -x "$FLAMEGRAPH_DIR/$tool" ]; then
        echo "Error: $tool not found at $FLAMEGRAPH_DIR/" >&2
        echo "Set FLAMEGRAPH_DIR to your FlameGraph checkout" >&2
        exit 1
    fi
done

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --lua) LUA_PROFILE=1; shift ;;
        --save) SAVE_LABEL="$2"; shift 2 ;;
        --diff) DIFF_LABEL="$2"; shift 2 ;;
        [0-9]*) DURATION="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Find compositor PID
SOMEWM_PID=""
for pid in $(pidof somewm 2>/dev/null); do
    if [ -d "/proc/$pid" ]; then
        SOMEWM_PID="$pid"
        break
    fi
done

if [ -z "$SOMEWM_PID" ]; then
    echo "Error: somewm not running" >&2
    exit 1
fi

# Warn if binary was replaced (causes unresolved symbols)
BINARY_PATH=$(readlink "/proc/$SOMEWM_PID/exe" 2>/dev/null || true)
if echo "$BINARY_PATH" | grep -q "(deleted)"; then
    echo "WARNING: somewm binary was replaced since this process started." >&2
    echo "C function names will show as raw addresses in the flamegraph." >&2
    echo "Restart the compositor to get readable output." >&2
    echo "" >&2
fi

# Use debuginfod for system library symbols (pixman, wlroots, cairo, etc.)
export DEBUGINFOD_URLS="${DEBUGINFOD_URLS:-https://debuginfod.archlinux.org}"

echo "Profiling somewm PID $SOMEWM_PID for ${DURATION}s"
echo "  Use the compositor normally during this time."
echo ""

# Start Lua profiling if requested
if [ "$LUA_PROFILE" = 1 ]; then
    echo "Starting Lua profiler (jit.p)..."
    "$SOMEWM_CLIENT" eval "require('jit.p').start('Gli1', '/tmp/somewm-lua-profile.txt')" 2>/dev/null || {
        echo "WARNING: jit.p not available, skipping Lua profiling" >&2
        LUA_PROFILE=0
    }
fi

# Record perf profile
PERF_DATA=$(mktemp --suffix=.perf.data)
FOLDED=""
cleanup_temps() {
    rm -f "$PERF_DATA" "$FOLDED"
}
trap cleanup_temps EXIT

perf record -g --call-graph dwarf -e cpu-clock -p "$SOMEWM_PID" -o "$PERF_DATA" -- sleep "$DURATION"

# Stop Lua profiling
if [ "$LUA_PROFILE" = 1 ]; then
    "$SOMEWM_CLIENT" eval "require('jit.p').stop()" 2>/dev/null || true
fi

echo ""
echo "Processing profile..."

FOLDED=$(mktemp --suffix=.folded)
perf script -i "$PERF_DATA" | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" > "$FOLDED"
SAMPLES=$(wc -l < "$FOLDED")
echo "  $SAMPLES unique stacks"

mkdir -p "$RESULTS_DIR"

# Generate differential flamegraph if requested
if [ -n "$DIFF_LABEL" ]; then
    BASELINE="$RESULTS_DIR/profile-${DIFF_LABEL}.folded"
    if [ ! -f "$BASELINE" ]; then
        echo "Error: no saved profile '$DIFF_LABEL' at $BASELINE" >&2
        exit 1
    fi

    DIFF_SVG="$RESULTS_DIR/profile-diff-${DIFF_LABEL}-vs-current.svg"
    "$FLAMEGRAPH_DIR/difffolded.pl" "$BASELINE" "$FOLDED" \
        | "$FLAMEGRAPH_DIR/flamegraph.pl" > "$DIFF_SVG"

    echo ""
    echo "Differential flamegraph: $DIFF_SVG"
    echo "  Red = hotter (more CPU in current)"
    echo "  Blue = cooler (less CPU in current)"
fi

# Save or generate timestamped output
if [ -n "$SAVE_LABEL" ]; then
    cp "$FOLDED" "$RESULTS_DIR/profile-${SAVE_LABEL}.folded"
    "$FLAMEGRAPH_DIR/flamegraph.pl" < "$FOLDED" > "$RESULTS_DIR/profile-${SAVE_LABEL}.svg"
    echo ""
    echo "Saved profile '$SAVE_LABEL':"
    echo "  Flamegraph: $RESULTS_DIR/profile-${SAVE_LABEL}.svg"
    echo "  Folded:     $RESULTS_DIR/profile-${SAVE_LABEL}.folded"
else
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    "$FLAMEGRAPH_DIR/flamegraph.pl" < "$FOLDED" > "$RESULTS_DIR/profile-${TIMESTAMP}.svg"
    cp "$FOLDED" "$RESULTS_DIR/profile-${TIMESTAMP}.folded"
    echo ""
    echo "Flamegraph: $RESULTS_DIR/profile-${TIMESTAMP}.svg"
    echo "Folded:     $RESULTS_DIR/profile-${TIMESTAMP}.folded"
fi

# Lua profile output
if [ "$LUA_PROFILE" = 1 ] && [ -f /tmp/somewm-lua-profile.txt ]; then
    LUA_SVG="$RESULTS_DIR/lua-profile-$(date +%Y%m%d-%H%M%S).svg"
    "$FLAMEGRAPH_DIR/flamegraph.pl" --title "Lua Profile" \
        < /tmp/somewm-lua-profile.txt > "$LUA_SVG" 2>/dev/null || true

    echo ""
    echo "Lua profile:"
    echo "  Raw:        /tmp/somewm-lua-profile.txt"
    if [ -f "$LUA_SVG" ]; then
        echo "  Flamegraph: $LUA_SVG"
    fi
    echo ""
    echo "  Top Lua functions:"
    sort -t' ' -k2 -rn /tmp/somewm-lua-profile.txt | head -10 | while read -r line; do
        echo "    $line"
    done
fi

# Top self-time functions from C profile
echo ""
echo "Top C functions by self-time:"
perf report -i "$PERF_DATA" --stdio --no-children --percent-limit 0.5 -g none 2>/dev/null \
    | grep -E "^\s+[0-9]" | head -15
