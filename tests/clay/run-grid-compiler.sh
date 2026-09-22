#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
printf '%s\n' '54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728  tests/clay/vendor/clay.h' | sha256sum -c -
grid_build=$(mktemp -d "${TMPDIR:-/tmp}/somewm-grid-compiler.XXXXXX")
trap 'rm -rf "$grid_build"' EXIT HUP INT TERM
export GRID_CONSTRUCTOR_EVIDENCE=${GRID_CONSTRUCTOR_EVIDENCE:-$grid_build}
${CC:-cc} -std=c99 -isystem tests/clay/vendor -Wall -Wextra -Werror ${CFLAGS:--O2} tests/clay/grid-constructor.c -lm -o "$grid_build/proof"
export GRID_HELPER_SOLVER="$grid_build/proof"
export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;;"
busted53=/usr/lib/luarocks/rocks-5.3/busted/2.3.0-1/bin/busted
if command -v lua5.3 >/dev/null 2>&1 && [ -f "$busted53" ]; then
    lua5.3 "$busted53" --helper spec/preload.lua spec/wibox/grid_constructor_spec.lua
else
    busted --helper spec/preload.lua spec/wibox/grid_constructor_spec.lua
fi
