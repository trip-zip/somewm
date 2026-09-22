#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Pristine Clay e6cc36941ab2af5d81107617039d6f527a1c660b; no network/build dependencies.
printf '%s\n' '54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728  vendor/clay.h' | sha256sum -c -
proof_build=$(mktemp -d "${TMPDIR:-/tmp}/somewm-clay-proof.XXXXXX")
trap 'rm -rf "$proof_build"' EXIT HUP INT TERM
# CFLAGS is intentionally word-split to accept ordinary compiler options.
${CC:-cc} -std=c99 -isystem vendor -Wall -Wextra -Werror ${CFLAGS:--O2} basic-desktop.c -lm -o "$proof_build/basic-desktop"
"$proof_build/basic-desktop" "${1:-basic-desktop.tsv}"
# A geometry-equivalent forbidden declaration must fail structural acceptance.
# The binary uses status 2 for unexpected geometry/structure failures.
negative_status=0
"$proof_build/basic-desktop" "${1:-basic-desktop.tsv}" --external-fixed || negative_status=$?
if [ "$negative_status" -ne 1 ]; then
    printf 'External-FIXED negative: expected exit 1, got %s\n' "$negative_status" >&2
    exit 1
fi
