#!/usr/bin/env bash
#
# Save the latest benchmark results as the baseline for the current branch.
#
# Usage: tests/bench/bench-save-baseline.sh [results-dir]

set -e

cd "$(dirname "$0")/../.."

if [ -n "$1" ]; then
    RESULTS_DIR="$1"
else
    RESULTS_DIR=""
    for dir in tests/bench/results/20*/; do
        [ -d "$dir" ] && RESULTS_DIR="$dir"
    done
fi

if [ -z "$RESULTS_DIR" ] || [ ! -d "$RESULTS_DIR" ]; then
    echo "Error: no results directory found. Run 'make bench-json' first." >&2
    exit 1
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
BASELINES_DIR="tests/bench/results/baselines"
mkdir -p "$BASELINES_DIR"

DEST="$BASELINES_DIR/$BRANCH"

# Copy results to baseline directory
rm -rf "$DEST"
cp -r "$RESULTS_DIR" "$DEST"

echo "Saved baseline for branch '$BRANCH': $DEST"
echo "  Source: $RESULTS_DIR"
echo "  Files: $(ls "$DEST"/*.json 2>/dev/null | wc -l) JSON files"
