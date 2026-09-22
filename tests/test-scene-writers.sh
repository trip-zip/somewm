#!/usr/bin/env bash
# Exercise symbol rejection and failures of the object inspection itself.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/objects" "$scratch/bin" "$scratch/empty"
guard="$root/tests/check-scene-writers.sh"
compile() {
    printf 'extern void %s(void); void probe(void) { %s(); }\n' "$1" "$1" |
        "${CC:-cc}" -x c -c -o "$scratch/objects/$2.c.o" -
}
reject() {
    if "$@" > "$scratch/result" 2>&1; then
        echo "scene-writers negative control unexpectedly passed: $*" >&2
        exit 1
    fi
}
compile wlr_scene_rect_create render
compile wlr_scene_subsurface_tree_create resource
"$guard" "$scratch/objects"
for symbol in wlr_scene_rect_create wlr_scene_buffer_create \
    wlr_scene_node_set_position wlr_scene_node_raise_to_top \
    wlr_scene_node_lower_to_bottom wlr_scene_node_place_above \
    wlr_scene_node_place_below wlr_scene_node_reparent \
    wlr_scene_node_set_enabled wlr_scene_rect_set_size \
    wlr_scene_buffer_set_opacity wlr_scene_node_at; do
    compile "$symbol" forbidden
    reject "$guard" "$scratch/objects"
    grep -Fq "$symbol" "$scratch/result"
    echo "rejected $symbol"
done
rm "$scratch/objects/forbidden.c.o"
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
rm "$scratch/objects/render.c.o"
reject "$guard" "$scratch/objects"
echo 'passed renderer/resource allowances and missing, empty, invalid and failed inspection controls'
