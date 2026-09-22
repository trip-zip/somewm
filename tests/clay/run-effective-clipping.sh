#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Pristine Clay e6cc36941ab2af5d81107617039d6f527a1c660b; offline standalone proof.
printf '%s\n' '54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728  vendor/clay.h' | sha256sum -c -
proof_build=$(mktemp -d "${TMPDIR:-/tmp}/somewm-clay-clipping.XXXXXX")
trap 'rm -rf "$proof_build"' EXIT HUP INT TERM
# CFLAGS is intentionally word-split to accept ordinary compiler options.
${CC:-cc} -std=c99 -isystem vendor -Wall -Wextra -Werror ${CFLAGS:--O2} effective-clipping.c -lm -o "$proof_build/effective-clipping"
"$proof_build/effective-clipping"
