/* Shared scene-buffer compositing helper for the screenshot capture paths in
 * root.c (luaA_root_get_content) and objects/client.c (luaA_client_get_content).
 *
 * Walks an arbitrary subtree via wlr_scene_node_for_each_buffer() and reads
 * each buffer's pixels into a cairo target. Handles SHM directly and falls
 * back to a wlr_renderer GPU texture readback for DMA-BUF clients. Scales
 * per-buffer when the scene_buffer's dst_width/dst_height differ from the
 * underlying buffer's physical size, so HiDPI renders correctly.
 */
#ifndef SOMEWM_SCREENSHOT_COMPOSE_H
#define SOMEWM_SCREENSHOT_COMPOSE_H

#include <cairo/cairo.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_scene.h>

/* wlr_scene_node_for_each_buffer() reports (sx, sy) accumulated from the
 * starting node down INCLUDING the starting node's own position. Callers
 * that start from a non-root node must pass offset_x/y = -node->x/-node->y
 * to get subtree-relative coordinates. */
/* bound_w or bound_h of zero means unbounded; anything else is the layout
 * box the target covers, and a node that misses it is skipped before its
 * pixels are touched. That skip is what keeps a one-output capture from
 * reading back every client on the other outputs. */
struct screenshot_render_data {
	cairo_t *cr;
	struct wlr_renderer *renderer;
	int offset_x, offset_y;
	int bound_x, bound_y, bound_w, bound_h;
};

void composite_scene_buffer_to_cairo(struct wlr_scene_buffer *scene_buffer,
                                     int sx, int sy, void *data);

/* The whole subtree, buffers and rectangles alike, in stacking order. Reaches
 * what the renderer draws as a flat color, which for_each_buffer never sees: a
 * converted widget container's background, and the fullscreen backing. Unlike
 * for_each_buffer this reads each node's position from the scene root, so a
 * caller starting below the root still gets layout coordinates. */
void composite_scene_node_to_cairo(struct wlr_scene_node *node, void *data);

#endif
