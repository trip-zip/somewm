# Bundled wlroots

Upstream release: 0.20.2, the tarball named and checksummed in `subprojects/wlroots.wrap`.
Diff: `subprojects/packagefiles/wlroots-corners.diff`, named by `diff_files` in the wrap. Meson applies it with `patch -p1` after unpacking, so the paths in it are `a/...` and `b/...` relative to the unpacked tree. One diff, one ledger. No second hunk set lands without Jimmy's word.

What the diff adds: a scene buffer takes four corner radii and a list of rounded clips; a scene rect takes four corner radii, a rounded cutout (the hole a border ring leaves) and the same clip list; the gles2 and pixman render passes cut textures and rects by them. A buffer with every radius 0 and no clip takes the same calls it takes upstream: the same texture options, the same program and uniforms, the same pixman mask. A rect with every radius 0, no cutout and no clip takes the same `add_rect` call as upstream, the `glClear` shortcut included. The one change the flat path sees is a vertex varying it does not read.

Every radius goes through one rule, the one CSS gives `border-radius`: for each of the four edges, the edge length over the sum of the two radii on it; when the smallest ratio is below 1, all four radii shrink by it. Four equal radii beyond the box make a pill; 24,24,0,0 on a 1000 by 30 box stays 24.

Not patched: `render/vulkan`. The subproject is built with `renderers=gles2`, so that directory is not compiled and the new option fields are simply unread there.

## Regenerating the diff

Unpack the tarball twice, `a/` and `b/`, edit `b/`, then `diff -ruN a b > wlroots-corners.diff`. Prove it applies with `rm -rf subprojects/wlroots-0.20.2 build-test && make build-test`. Meson applies `diff_files` only when it unpacks the tarball, so a `subprojects/wlroots-0.20.2` unpacked before a change to the diff keeps the old source until it is removed.

## Every hunk, by file and function

### include/wlr/render/pass.h

- `struct wlr_render_rounded_clip` (new): a box and four radii (top-left, top-right, bottom-right, bottom-left), the one shape every clip, cutout and corner set below is written in. `WLR_RENDER_ROUNDED_CLIPS` 4: the most clips one node or one draw carries.
- `struct wlr_render_texture_options`: `corner_radii[4]` in destination pixels; `clips[4]` and `clips_len`, rounded clips in destination coordinates, every one of which a pixel must be inside. (Was one `clip_box` and `clip_radii[4]`; the list replaced them.)
- `struct wlr_render_rect_options`: `corner_radii[4]`, a `cutout` box with `cutout_radii[4]` (a rounded hole, width 0 for none), and `clips[4]` with `clips_len`, all as for a texture.

### include/wlr/render/interface.h, render/pass.c

- `wlr_render_texture_options_is_rounded`, `wlr_render_rect_options_is_rounded` (new): whether a radius, the cutout or a clip is set, shared by the gles2 and pixman passes and the scene.
- `wlr_render_fit_corner_radii` (new): the edge rule above, for a box of a given size. The pixman pass and the scene hit test call it; the shaders carry the same rule as `fit_radii`. somewm's `render.c` and `root.c` call it too, so input and `screen.content` agree with the output.

### include/wlr/types/wlr_scene.h

- `WLR_SCENE_ROUNDED_CLIPS`: `WLR_RENDER_ROUNDED_CLIPS`; the header includes `wlr/render/pass.h` for the clip struct.
- `struct wlr_scene_rect`: `corner_radii[4]` (logical pixels), `cutout_box` and `cutout_radii[4]` (node-local, width 0 for none), `clips[4]` and `clips_len` (node-local). Public fields: somewm's `root.c` reads them so `screen.content` draws what the output draws.
- `struct wlr_scene_buffer`: `corner_radii[4]` as before; `clips[4]` and `clips_len` replace `clip_box` and `clip_radii`.
- `wlr_scene_rect_set_corner_radii`, `wlr_scene_rect_set_cutout` (NULL clears), `wlr_scene_rect_set_rounded_clips` (new), `wlr_scene_buffer_set_corner_radii`, `wlr_scene_buffer_set_rounded_clips` (replacing `wlr_scene_buffer_set_rounded_clip`): the setters, declared beside the existing ones. A list longer than four is an assert.

### types/scene/wlr_scene.c

- The file includes `wlr/render/interface.h` for the fit rule.
- `radii_set`, `scene_buffer_has_corners`, `scene_rect_is_rounded` (new): whether any radius, the cutout or a clip is set. Every other hunk branches on them, so an uncut node takes the upstream path.
- `set_rounded_clips` (new): stores a clip list, zeroing the unused entries; whether it changed. Both list setters use it.
- `box_inside_corners` (new): a box inset past its corner arcs, the largest plain rectangle no arc reaches, one rect. An opaque region only has to lie inside the opaque pixels, so the thin bands beside the arcs are given up: one rect costs no allocation, where a per-corner `pixman_region32_subtract` allocates on every commit for every rounded node.
- `subtract_rounded` (new): keeps a buffer's region inside its box less its corners and inside each clip's box less the clip's, by `pixman_region32_intersect_rect`.
- `scene_node_opaque_region`: a buffer's copied opaque region and an opaque buffer's full box go through `subtract_rounded`. A rect with radii, a cutout or clips counts nothing as opaque, as the cairo raster it replaces did: any region it reported, exact bands or an inset rect, split the regions of the nodes under it into strips on every commit (E110 saw 24 to 28 pixman allocations per text frame against 16 before the rect primitive), and a ring's hole shows what is below. A plain rect keeps upstream's full box.
- `transform_corner_radii` (as before), `render_rounded_box`, `render_corners` (new): a node-local box and its radii moved into the buffer-pixel space of the destination box, the box through `transform_output_box` and each corner's radius through `wlr_box_transform` of a unit square; the node's radii and every clip for the render pass.
- `wlr_scene_rect_set_corner_radii`, `wlr_scene_rect_set_cutout`, `wlr_scene_rect_set_rounded_clips`, `wlr_scene_buffer_set_corner_radii`, `wlr_scene_buffer_set_rounded_clips` (new): return early when unchanged, then `scene_node_update(node, NULL)` as `wlr_scene_rect_set_size` and `wlr_scene_buffer_set_dest_size` do, which damages and recomputes visibility.
- `point_in_rounded_box` (new), `point_in_rounded_clips` (new), `scene_node_at_iterator`: a point in a cut corner or outside any clip is not a hit on a buffer, checked before `point_accepts_input` so the surface's input region still applies inside the arc; a rect branch (new) refuses a point in a cut corner, inside the cutout or outside any clip. The radii are fitted by the edge rule first.
- `scene_entry_render`: the rect branch's `wlr_render_pass_add_rect` options become a named struct, filled with the radii, the cutout and the clips through `render_corners` and `render_rounded_box` only when `scene_rect_is_rounded`; the buffer branch fills the radii and the list through `render_corners` only when `scene_buffer_has_corners`.
- `construct_render_list_iterator`: the opaque black rect that upstream leaves out of the render list (the cleared output is black already) stays in it when it is rounded, since what is below shows through its cut parts.
- `scene_entry_try_direct_scanout`: `SCANOUT_INELIGIBLE` when `scene_buffer_has_corners`, beside the buffer checks.
- `scene_node_invisible` is unchanged: a ring with a visible colour is visible.

### render/gles2/shaders

- `common.vert`: a `v_pos` varying carrying `pos`, the position inside the destination box from 0 to 1. The flat programs do not read it, and the linker drops an unread varying.
- `quad_round.frag` (new): the quad program's colour times the coverage of the box with its radii, times every clip's coverage, times one minus the cutout's. Uniforms: `color`, `size` (the box in pixels), `radii`, `cutout_box` and `cutout_radii` (relative to the box origin, width 0 for none), `clip_count`, `clip_boxes[4]` and `clip_radii[4]` (relative to the box origin).
- `tex_rgba_round.frag`, `tex_rgbx_round.frag`, `tex_external_round.frag`: the matching upstream shader multiplied by `round_coverage`: the box's coverage times every clip's. Uniforms: `size`, `radii`, `clip_count`, `clip_boxes[4]`, `clip_radii[4]`.
- In every round shader, `fit_radii` is the edge rule, `arc_alpha` one corner's coverage with a one pixel `smoothstep` on its arc, and `corner_alpha` the box's edge coverage times its four corners'; highp when the device has it. The functions are copied into each file because `embed.sh` embeds one file per program and the external shader's `#extension` line must come first.
- `meson.build`: the four new names in the shader list.

### include/render/gles2.h

- `struct wlr_gles2_round_uniforms` (new): the `size`, `radii`, `clip_count`, `clip_boxes` and `clip_radii` locations every round program has.
- `struct wlr_gles2_tex_shader`: a `round` member of that struct, set on the round programs only.
- `struct wlr_gles2_renderer.shaders`: `quad_round` (program, `proj`, `color`, `pos_attrib`, `cutout_box`, `cutout_radii` and `round`), `tex_rgba_round`, `tex_rgbx_round`, `tex_ext_round`.

### render/gles2/renderer.c

- The four generated shader headers are included.
- `get_round_uniforms` (new): the five shared locations of one program.
- `link_round_tex_program` (new): links one round texture program and looks up its locations. The sampler is looked up as `tex` like the plain programs, which the external shader names `texture0`; upstream has the same mismatch at its `tex_ext` lookup (the location is -1 and the sampler keeps unit 0). Not fixed here.
- `gles2_renderer_create`: links the three round texture programs after the existing four, the external one only with `OES_egl_image_external`, then `quad_round`, all with the same `goto error`.
- the `error:` path and `gles2_destroy`: `glDeleteProgram` on the four.

### render/gles2/pass.c

- `set_round_uniforms` (new): the box size, its radii and the clip arrays relative to the box origin, for one program.
- `render_pass_add_texture`: picks the round program for the texture's target when `wlr_render_texture_options_is_rounded`; blends premultiplied then, since a cut corner is transparent whatever the texture is; sets the round uniforms after the existing ones. Otherwise the same program, blending and uniforms as upstream.
- `render_pass_add_rect`: when `wlr_render_rect_options_is_rounded`, blends premultiplied, uses `quad_round` with its projection, colour, round uniforms and cutout, and returns before the `glClear` shortcut. Otherwise the upstream code, untouched.

### include/render/pixman.h, render/pixman/renderer.c

- `struct wlr_pixman_corner_tiles` (new) and `wlr_pixman_renderer.corner_tiles`: the A8 coverage tiles cached per radius in device pixels, one per corner. Initialised in `wlr_pixman_renderer_create`, freed in `pixman_destroy`.
- `struct wlr_pixman_rounded_mask_key`, `struct wlr_pixman_rounded_mask` (new), `WLR_PIXMAN_ROUNDED_MASKS` 64, and `wlr_pixman_renderer.rounded_masks` with `rounded_masks_len`: the rounded masks cached by what they were built from (the box size, its radii, the cutout and the clips relative to the box, the alpha), newest first. The list holds one reference per mask. Initialised in `wlr_pixman_renderer_create`; `pixman_destroy` unrefs and frees every entry.

### render/pixman/pass.c

- `corner_tile` (new): the radius by radius A8 tile of one corner, filled on first use from the same distance and `smoothstep` as the shaders' `arc_alpha`.
- `mask_cut_corners` (new): multiplies each nonzero corner's tile into a mask at the corners of a box (`PIXMAN_OP_IN`), the radii fitted to the box first.
- `box_mask` (new): an opaque A8 mask of a size with its corners cut.
- `rounded_mask_key` (new): the key of a mask, every box relative to the mask's own, zeroed before it is filled so it compares bytewise.
- `build_rounded_mask` (new): an A8 mask of the key's size: opaque, the corners cut, less the cutout (a `box_mask` of the hole taken out with `PIXMAN_OP_OUT_REVERSE`, so its corners are exact where they overlap), zero outside each clip with the clip's corners multiplied in, then times the alpha when it is not 1.
- `rounded_mask` (new): the cache lookup. A hit returns the cached image referenced; a miss builds it, inserts it at the head of `rounded_masks` and drops the oldest entry past `WLR_PIXMAN_ROUNDED_MASKS`, then returns it referenced. Both passes unref their use after the composite, so an unchanged rounded rect or texture allocates nothing per frame.
- `render_pass_add_texture`: the mask argument becomes that image when `wlr_render_texture_options_is_rounded`, with mask x,y 0,0 in both composite calls as before, and the operator becomes `PIXMAN_OP_OVER`. Otherwise the solid alpha mask or no mask, as upstream.
- `render_pass_add_rect`: when `wlr_render_rect_options_is_rounded` and the box is not empty, the fill is composited through that mask with `PIXMAN_OP_OVER` and the mask is dropped. Otherwise the upstream composite, untouched.

## Rebasing

The touched functions move little between point releases. On a major release re-read `scene_entry_render`, `scene_node_opaque_region`, `construct_render_list_iterator` and `scene_entry_try_direct_scanout` first: the render site, the opaque region and the render list are where upstream churns; then `render_pass_add_rect` in both passes, which the diff wraps rather than edits. The pixel tests (`tests/test-client-corner-radius.lua` and `tests/test-clay-background-shape.lua` on the pixman and gles2 lanes, `tests/test-clay-rounded-popup-resize.lua` for the raster counts) and `tests/test-render.c` are the proof after a rebase.
