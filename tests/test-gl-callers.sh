#!/usr/bin/env bash
# Exercise forbidden calls, allowed calls, and failed object inspection.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/objects" "$scratch/bin" "$scratch/empty"
guard="$root/tests/check-gl-callers.sh"
compile() {
    printf 'extern void %s(void); void probe(void) { %s(); }\n' "$1" "$1" |
        "${CC:-cc}" -x c -c -o "$scratch/objects/$2.c.o" -
}
reject() {
    if "$@" > "$scratch/result" 2>&1; then
        echo "gl-callers negative control unexpectedly passed: $*" >&2
        exit 1
    fi
}
compile glDrawArrays paint
compile eglMakeCurrent monitor
"$guard" "$scratch/objects"
for symbol in glDrawArrays glBindFramebuffer eglMakeCurrent eglGetDisplay wlr_scene_create; do
    compile "$symbol" forbidden
    reject "$guard" "$scratch/objects"
    grep -Fq "$symbol" "$scratch/result"
    echo "rejected $symbol"
done
rm "$scratch/objects/forbidden.c.o"
compile eglGetDisplay monitor
reject "$guard" "$scratch/objects"
compile eglMakeCurrent monitor
compile wlr_scene_create paint
reject "$guard" "$scratch/objects"
compile glDrawArrays paint
reject "$guard" "$scratch/empty"
reject "$guard" "$scratch/missing"
printf 'invalid object\n' > "$scratch/objects/invalid.c.o"
reject "$guard" "$scratch/objects"
grep -q 'cannot inspect' "$scratch/result"
rm "$scratch/objects/invalid.c.o"
printf '#!/bin/sh\nexit 1\n' > "$scratch/bin/nm"
chmod +x "$scratch/bin/nm"
reject env PATH="$scratch/bin:$PATH" "$guard" "$scratch/objects"
grep -q 'cannot inspect' "$scratch/result"
rm "$scratch/objects/paint.c.o"
reject "$guard" "$scratch/objects"
echo 'passed allowed calls and object inspection controls'
