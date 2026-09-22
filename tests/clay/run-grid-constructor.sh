#!/bin/sh
set -eu
cd "$(dirname "$0")"
printf '%s\n' '54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728  vendor/clay.h' | sha256sum -c -
grid_build=$(mktemp -d "${TMPDIR:-/tmp}/somewm-grid-proof.XXXXXX")
trap 'rm -rf "$grid_build"' EXIT HUP INT TERM
${CC:-cc} -std=c99 -isystem vendor -Wall -Wextra -Werror ${CFLAGS:--O2} grid-constructor.c -lm -o "$grid_build/grid-constructor"
"$grid_build/grid-constructor" "$@"
