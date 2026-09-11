#!/usr/bin/env bash
#
# The renderer is the only code that positions, orders, shows or hides a
# scene node: Clay solves the tree, and render.c realizes the command array
# it produces. Any other object file referencing a scene mutation symbol is
# a side channel that places or draws something outside that array. The
# scene hit test is in the list too: input walks the declared tree
# (declare_hit_at), never the scene.
#
# Usage: check-scene-writers.sh <object dir>   (meson's somewm.p)

set -u

objdir=${1:?object dir}
symbols='wlr_scene_node_set_position
wlr_scene_node_raise_to_top
wlr_scene_node_lower_to_bottom
wlr_scene_node_place_above
wlr_scene_node_place_below
wlr_scene_node_reparent
wlr_scene_node_set_enabled
wlr_scene_rect_set_size
wlr_scene_buffer_set_opacity
wlr_scene_node_at'

fail=0
for obj in "$objdir"/*.o; do
    case $(basename "$obj") in
        render.c.o) continue ;;
    esac
    hits=$(nm --undefined-only "$obj" | awk '{print $NF}' | grep -Fx "$symbols")
    if [ -n "$hits" ]; then
        echo "check-scene-writers: $(basename "$obj" .c.o).c writes the scene outside the renderer:"
        echo "$hits" | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
