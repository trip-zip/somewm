#!/usr/bin/env bash
#
# Unit test runner for somewm
#
# Runs busted tests from the spec/ directory

set -e

cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"

# Check if busted is installed
if ! command -v busted >/dev/null 2>&1; then
    echo "Error: busted not installed" >&2
    echo "Install with: sudo pacman -S luarocks && sudo luarocks install busted" >&2
    exit 1
fi

# Setup Lua path
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;;"

# Build busted arguments
BUSTED_ARGS=""
[ "$COVERAGE" = "1" ] && BUSTED_ARGS="--coverage"
[ "$VERBOSE" = "1" ] && BUSTED_ARGS="$BUSTED_ARGS --verbose"

# Run busted
echo "Running unit tests with busted..."
busted $BUSTED_ARGS spec/

# vim: filetype=sh:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
