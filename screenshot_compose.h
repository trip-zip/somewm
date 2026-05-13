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

struct screenshot_render_data {
	cairo_t *cr;
	struct wlr_renderer *renderer;
	int offset_x, offset_y;
};

void composite_scene_buffer_to_cairo(struct wlr_scene_buffer *scene_buffer,
                                     int sx, int sy, void *data);

#endif
