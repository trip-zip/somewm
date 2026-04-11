#!/usr/bin/env bash
#
# Benchmark runner for somewm performance profiling.
# Runs benchmarks against the currently running compositor session.
#
# Options:
#   JSON=1:     Capture JSON output to results directory
#   RUNS=N:     Number of iterations per benchmark (default: 5)
#
# Usage:
#   tests/bench/run-all.sh                    # Run all benchmarks
#   tests/bench/run-all.sh bench-focus-cycle   # Single benchmark
#   JSON=1 tests/bench/run-all.sh             # With JSON capture

set -e

export LC_NUMERIC=C

SOMEWM_CLIENT="${SOMEWM_CLIENT:-./somewm-client}"
RUNS=${RUNS:-5}
JSON=${JSON:-0}

cd "$(dirname "$0")/../.."
ROOT_DIR="$PWD"

BENCH_DIR="$ROOT_DIR/tests/bench"

# Set up JSON results directory if requested
if [ "$JSON" = 1 ]; then
    GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    RUN_ID="$(date +%Y%m%d-%H%M%S)-${GIT_COMMIT}"
    RESULTS_DIR="$BENCH_DIR/results/$RUN_ID"
    mkdir -p "$RESULTS_DIR"
fi

# Determine which benchmarks to run
if [ -n "$1" ]; then
    BENCHMARKS=("$BENCH_DIR/$1.lua")
else
    BENCHMARKS=("$BENCH_DIR"/bench-*.lua)
fi

# Filter out helpers (not a benchmark)
FILTERED=()
for b in "${BENCHMARKS[@]}"; do
    case "$(basename "$b")" in
        bench-helpers.lua|bench-stats.lua|bench-memory-trend.lua) continue ;;
    esac
    FILTERED+=("$b")
done
BENCHMARKS=("${FILTERED[@]}")

# Validate benchmarks exist
for b in "${BENCHMARKS[@]}"; do
    if [ ! -f "$b" ]; then
        echo "Error: benchmark not found: $b" >&2
        exit 1
    fi
done

# Extract JSON block from benchmark output
extract_json() {
    sed -n '/^---JSON-START---$/,/^---JSON-END---$/{/^---JSON/d;p;}'
}

# Run a single benchmark and optionally capture JSON
run_bench() {
    local bench="$1"
    local name=$(basename "$bench" .lua)
    echo "--- $name (${RUNS} runs) ---"

    for run in $(seq 1 "$RUNS"); do
        echo -n "[run $run/$RUNS] "
        local output
        output=$("$SOMEWM_CLIENT" eval "return dofile('$bench')" 2>/dev/null) || {
            echo "FAILED"
            continue
        }

        # Check if benchmark is async (returns "ASYNC ..." and stores result in global)
        if echo "$output" | grep -q "^OK" && echo "$output" | grep -q "ASYNC"; then
            # Derive the result key from the benchmark name (bench-tag-switch -> tag_switch)
            local result_key
            result_key=$(echo "$name" | sed 's/^bench-//; s/-/_/g')

            # Poll for completion
            local attempts=0
            local max_attempts=600  # 60 seconds at 100ms intervals
            while [ $attempts -lt $max_attempts ]; do
                output=$("$SOMEWM_CLIENT" eval "return _bench_results.${result_key} or 'PENDING'" 2>/dev/null)
                if ! echo "$output" | grep -q "PENDING"; then
                    break
                fi
                sleep 0.1
                attempts=$((attempts + 1))
            done

            if [ $attempts -ge $max_attempts ]; then
                echo "TIMEOUT"
                "$SOMEWM_CLIENT" eval "_bench_results.${result_key} = nil" 2>/dev/null || true
                continue
            fi

            # Clean up global for next run
            "$SOMEWM_CLIENT" eval "_bench_results.${result_key} = nil" 2>/dev/null || true
        fi

        # Strip IPC framing ("OK\n" prefix, "OK (no return value)" lines)
        output=$(echo "$output" | sed '/^OK$/d; /^OK (no return value)$/d')

        # Print human-readable part (everything before JSON sentinel)
        echo "$output" | sed '/^---JSON-START---$/,$d'

        # Capture JSON if requested
        if [ "$JSON" = 1 ]; then
            local json
            json=$(echo "$output" | extract_json)
            if [ -n "$json" ]; then
                echo "$json" > "$RESULTS_DIR/${name}-run${run}.json"
            fi
        fi
        echo ""
    done
}

echo "=== Running against live session ==="
echo ""

for bench in "${BENCHMARKS[@]}"; do
    run_bench "$bench"
done

# Print frame stats at end
"$SOMEWM_CLIENT" eval "if awesome.bench_stats then local s = awesome.bench_stats(); print('=== frame timing ==='); print(string.format('refresh_count: %d', s.refresh_count)); print(string.format('refresh_avg_us: %.1f', s.refresh_avg_us)); print(string.format('refresh_p99_us: %.1f', s.refresh_p99_us)); print(string.format('refresh_max_us: %.1f', s.refresh_max_us)); if s.crossings_per_frame then print(string.format('crossings_per_frame_avg: %.1f', s.crossings_per_frame.avg)); print(string.format('crossings_per_frame_max: %d', s.crossings_per_frame.max)) end end" 2>/dev/null || true

# Write manifest
if [ "$JSON" = 1 ]; then
    cat > "$RESULTS_DIR/manifest.json" << MANIFESTEOF
{
  "run_id": "$RUN_ID",
  "git_commit": "$GIT_COMMIT",
  "git_branch": "$GIT_BRANCH",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "runs": $RUNS
}
MANIFESTEOF

    echo ""
    echo "JSON results: $RESULTS_DIR"
fi
