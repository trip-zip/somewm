#!/usr/bin/env bash
# GL state belongs to paint.c. monitor.c binds the renderer's EGL context.
set -euo pipefail
shopt -s nullglob
objdir=${1:?object dir}
objects=("$objdir"/*.o)
if (( ${#objects[@]} == 0 )) || [[ ! -f "$objdir/paint.c.o" ]]; then
    echo "check-gl-callers: missing compositor objects or paint.c.o in $objdir" >&2
    exit 1
fi
fail=0
for obj in "${objects[@]}"; do
    if ! undefined=$(nm --undefined-only "$obj"); then
        echo "check-gl-callers: cannot inspect $obj" >&2
        exit 1
    fi
    hits=$(awk -v object="$(basename "$obj")" '
        $NF ~ /^wlr_scene/ { print $NF; next }
        $NF ~ /^(gl|egl)[A-Z]/ {
            if (object == "paint.c.o") next
            if (object == "monitor.c.o" && $NF == "eglMakeCurrent") next
            print $NF
        }' <<< "$undefined")
    if [[ -n "$hits" ]]; then
        echo "check-gl-callers: $obj references forbidden symbols: $hits" >&2
        fail=1
    fi
done
exit "$fail"
