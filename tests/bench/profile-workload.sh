#!/usr/bin/env bash
#
# Scripted profiling workload for somewm.
#
# Drives a repeatable sequence of compositor operations via IPC while
# perf records a CPU profile. Produces a flamegraph and saves folded
# stacks for later differential comparison.
#
# Usage:
#   tests/bench/profile-workload.sh                  # Profile live session
#   tests/bench/profile-workload.sh --save baseline  # Save with label
#   tests/bench/profile-workload.sh --diff baseline   # Diff against saved profile
#
# Requires: perf, FlameGraph tools (stackcollapse-perf.pl, flamegraph.pl, difffolded.pl)

set -e

SOMEWM_CLIENT="${SOMEWM_CLIENT:-./build-bench/somewm-client}"
FLAMEGRAPH_DIR="${FLAMEGRAPH_DIR:-$HOME/tools/FlameGraph}"
RESULTS_DIR="tests/bench/results"
PERF_DURATION=${PERF_DURATION:-15}

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
SAVE_LABEL=""
DIFF_LABEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save) SAVE_LABEL="$2"; shift 2 ;;
        --diff) DIFF_LABEL="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Find compositor PID
SOMEWM_PID=""
for pid in $(pidof somewm 2>/dev/null); do
    if [ -d "/proc/$pid" ] && [ -f "/proc/$pid/exe" ]; then
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
    echo "C function names will show as raw addresses. Restart to fix." >&2
    echo "" >&2
fi

# Use debuginfod for system library symbols
export DEBUGINFOD_URLS="${DEBUGINFOD_URLS:-https://debuginfod.archlinux.org}"

echo "Profiling somewm PID $SOMEWM_PID for ${PERF_DURATION}s"

eval_cmd() {
    "$SOMEWM_CLIENT" eval "$1" 2>/dev/null || true
}

# The workload: a repeatable sequence of compositor operations
run_workload() {
    # Wait for perf to attach
    sleep 0.5

    echo "  Phase 1: Tag switching (cycling all tags 3x)"
    for round in 1 2 3; do
        for tag in 1 2 3 4 5 6 7 8 9; do
            eval_cmd "screen[1].tags[${tag}]:view_only()"
        done
    done

    echo "  Phase 2: Focus cycling"
    for i in $(seq 1 30); do
        eval_cmd "local cls = client.get(); if #cls > 0 then client.focus = cls[($i % #cls) + 1] end"
    done

    echo "  Phase 3: Geometry changes"
    for i in $(seq 1 20); do
        eval_cmd "for _, c in ipairs(client.get()) do local g = c:geometry(); c:geometry({ x = g.x + ($i % 5) - 2, y = g.y + ($i % 3) - 1 }) end"
    done

    echo "  Phase 4: Property toggles"
    for i in $(seq 1 20); do
        eval_cmd "for _, c in ipairs(client.get()) do c.ontop = not c.ontop; c.sticky = not c.sticky end"
    done

    echo "  Phase 5: Restore state"
    eval_cmd "screen[1].tags[1]:view_only()"

    echo "  Workload complete, waiting for perf to finish..."
}

# Run perf and workload in parallel
PERF_DATA=$(mktemp --suffix=.perf.data)
FOLDED=""
cleanup_temps() {
    rm -f "$PERF_DATA" "$FOLDED"
}
trap cleanup_temps EXIT

run_workload &
WORKLOAD_PID=$!

perf record -g --call-graph dwarf -e cpu-clock -p "$SOMEWM_PID" -o "$PERF_DATA" -- sleep "$PERF_DURATION"

wait "$WORKLOAD_PID" 2>/dev/null || true

echo ""
echo "Processing profile..."

FOLDED=$(mktemp --suffix=.folded)
perf script -i "$PERF_DATA" | "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" > "$FOLDED"
SAMPLES=$(wc -l < "$FOLDED")
echo "  $SAMPLES unique stacks"

mkdir -p "$RESULTS_DIR"

if [ -n "$DIFF_LABEL" ]; then
    # Differential flamegraph against saved baseline
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

if [ -n "$SAVE_LABEL" ]; then
    # Save folded stacks and flamegraph with label
    cp "$FOLDED" "$RESULTS_DIR/profile-${SAVE_LABEL}.folded"
    "$FLAMEGRAPH_DIR/flamegraph.pl" < "$FOLDED" > "$RESULTS_DIR/profile-${SAVE_LABEL}.svg"
    echo ""
    echo "Saved profile '$SAVE_LABEL':"
    echo "  Flamegraph: $RESULTS_DIR/profile-${SAVE_LABEL}.svg"
    echo "  Folded:     $RESULTS_DIR/profile-${SAVE_LABEL}.folded"
else
    # Just generate a flamegraph with timestamp
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    "$FLAMEGRAPH_DIR/flamegraph.pl" < "$FOLDED" > "$RESULTS_DIR/profile-${TIMESTAMP}.svg"
    cp "$FOLDED" "$RESULTS_DIR/profile-${TIMESTAMP}.folded"
    echo ""
    echo "Flamegraph: $RESULTS_DIR/profile-${TIMESTAMP}.svg"
    echo "Folded:     $RESULTS_DIR/profile-${TIMESTAMP}.folded"
fi

# Also dump top self-time functions
echo ""
echo "Top functions by self-time:"
perf report -i "$PERF_DATA" --stdio --no-children --percent-limit 0.3 -g none 2>/dev/null \
    | grep -E "^\s+[0-9]" | head -15

# Temp files cleaned up by trap
