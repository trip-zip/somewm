/* Minimal DMA-BUF Wayland client for verifying c.content's GPU readback path.
 *
 * Allocates a single linear ARGB8888 buffer via gbm, fills it with a
 * 4-quadrant pattern (TL=red, TR=green, BL=blue, BR=yellow), imports it as
 * a wl_buffer through zwp_linux_dmabuf_v1, and attaches it to an
 * xdg_toplevel. Used by test-client-content-dmabuf.lua to assert c.content
 * returns real pixels for DMA-BUF clients (issue #539).
 *
 * Buffer is intentionally a DMA-BUF (not SHM) so the compositor exercises
 * its scene-tree walk + GPU texture readback path inside
 * composite_scene_buffer_to_cairo().
 *
 * Lifecycle: SIGTERM/SIGINT for clean exit. App ID: "dmabuf_pattern_test".
 */

#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "linux-dmabuf-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#define WIDTH  200
#define HEIGHT 200

static struct wl_display *g_display;
static struct wl_compositor *g_compositor;
static struct xdg_wm_base *g_xdg_wm_base;
static struct zwp_linux_dmabuf_v1 *g_dmabuf;

static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;
static struct wl_buffer *g_buffer;

static int g_drm_fd = -1;
static struct gbm_device *g_gbm_dev;
static struct gbm_bo *g_bo;

static volatile sig_atomic_t g_running = 1;
static bool g_committed = false;

static void on_signal(int sig) { (void)sig; g_running = 0; }

/* Pattern: top-left=red, top-right=green, bottom-left=blue, bottom-right=yellow */
static uint32_t pattern_color(int x, int y) {
	bool right  = x >= WIDTH  / 2;
	bool bottom = y >= HEIGHT / 2;
	if (!right && !bottom) return 0xFFFF0000u; /* red */
	if ( right && !bottom) return 0xFF00FF00u; /* green */
	if (!right &&  bottom) return 0xFF0000FFu; /* blue */
	return 0xFFFFFF00u; /* yellow */
}

static void
xdg_wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener xdg_wm_base_listener = {
	.ping = xdg_wm_base_ping,
};

static void
xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
	(void)data;
	xdg_surface_ack_configure(s, serial);
	if (g_buffer && !g_committed) {
		wl_surface_attach(g_surface, g_buffer, 0, 0);
		wl_surface_damage_buffer(g_surface, 0, 0, WIDTH, HEIGHT);
		wl_surface_commit(g_surface);
		g_committed = true;
	}
}
static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void
xdg_toplevel_configure(void *data, struct xdg_toplevel *t,
                       int32_t w, int32_t h, struct wl_array *states) {
	(void)data; (void)t; (void)w; (void)h; (void)states;
}
static void
xdg_toplevel_close(void *data, struct xdg_toplevel *t) {
	(void)data; (void)t;
	g_running = 0;
}
static void
xdg_toplevel_configure_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h) {
	(void)data; (void)t; (void)w; (void)h;
}
static void
xdg_toplevel_wm_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps) {
	(void)data; (void)t; (void)caps;
}
static const struct xdg_toplevel_listener xdg_toplevel_listener = {
	.configure         = xdg_toplevel_configure,
	.close             = xdg_toplevel_close,
	.configure_bounds  = xdg_toplevel_configure_bounds,
	.wm_capabilities   = xdg_toplevel_wm_capabilities,
};

static void
params_created(void *data, struct zwp_linux_buffer_params_v1 *p, struct wl_buffer *buf) {
	(void)data;
	g_buffer = buf;
	zwp_linux_buffer_params_v1_destroy(p);
}
static void
params_failed(void *data, struct zwp_linux_buffer_params_v1 *p) {
	(void)data; (void)p;
	fprintf(stderr, "dmabuf params failed\n");
	g_running = 0;
}
static const struct zwp_linux_buffer_params_v1_listener params_listener = {
	.created = params_created,
	.failed  = params_failed,
};

static void
registry_global(void *data, struct wl_registry *reg, uint32_t name,
                const char *interface, uint32_t version) {
	(void)data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		g_compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		g_xdg_wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(g_xdg_wm_base, &xdg_wm_base_listener, NULL);
	} else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {
		uint32_t v = version > 3 ? 3 : version;
		g_dmabuf = wl_registry_bind(reg, name, &zwp_linux_dmabuf_v1_interface, v);
	}
}
static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
	(void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener registry_listener = {
	.global         = registry_global,
	.global_remove  = registry_global_remove,
};

static int
open_render_node(void) {
	int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (fd < 0) fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	return fd;
}

static int
create_dmabuf(void) {
	g_drm_fd = open_render_node();
	if (g_drm_fd < 0) {
		fprintf(stderr, "failed to open DRM render node: %s\n", strerror(errno));
		return -1;
	}
	g_gbm_dev = gbm_create_device(g_drm_fd);
	if (!g_gbm_dev) {
		fprintf(stderr, "failed to create gbm device\n");
		return -1;
	}
	g_bo = gbm_bo_create(g_gbm_dev, WIDTH, HEIGHT, GBM_FORMAT_ARGB8888,
	                     GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
	if (!g_bo) {
		fprintf(stderr, "failed to create gbm bo\n");
		return -1;
	}

	void *map_data = NULL;
	uint32_t stride = 0;
	void *mapped = gbm_bo_map(g_bo, 0, 0, WIDTH, HEIGHT,
	                          GBM_BO_TRANSFER_WRITE, &stride, &map_data);
	if (!mapped) {
		fprintf(stderr, "failed to map gbm bo\n");
		return -1;
	}
	for (int y = 0; y < HEIGHT; y++) {
		uint32_t *row = (uint32_t *)((char *)mapped + (size_t)y * stride);
		for (int x = 0; x < WIDTH; x++) {
			row[x] = pattern_color(x, y);
		}
	}
	gbm_bo_unmap(g_bo, map_data);

	int dma_fd = gbm_bo_get_fd(g_bo);
	if (dma_fd < 0) {
		fprintf(stderr, "failed to get dma-buf fd\n");
		return -1;
	}
	uint64_t modifier = gbm_bo_get_modifier(g_bo);

	struct zwp_linux_buffer_params_v1 *params =
		zwp_linux_dmabuf_v1_create_params(g_dmabuf);
	zwp_linux_buffer_params_v1_add_listener(params, &params_listener, NULL);
	zwp_linux_buffer_params_v1_add(params, dma_fd, 0, 0, stride,
	                               (uint32_t)(modifier >> 32),
	                               (uint32_t)(modifier & 0xffffffff));
	zwp_linux_buffer_params_v1_create(params, WIDTH, HEIGHT,
	                                  GBM_FORMAT_ARGB8888, 0);
	close(dma_fd);

	wl_display_roundtrip(g_display);
	if (!g_buffer) {
		fprintf(stderr, "buffer creation never confirmed\n");
		return -1;
	}
	return 0;
}

int
main(void) {
	signal(SIGTERM, on_signal);
	signal(SIGINT,  on_signal);

	g_display = wl_display_connect(NULL);
	if (!g_display) {
		fprintf(stderr, "failed to connect to wayland display\n");
		return 1;
	}

	struct wl_registry *reg = wl_display_get_registry(g_display);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(g_display);

	if (!g_compositor || !g_xdg_wm_base || !g_dmabuf) {
		fprintf(stderr, "missing required globals (compositor=%p wm_base=%p dmabuf=%p)\n",
		        (void *)g_compositor, (void *)g_xdg_wm_base, (void *)g_dmabuf);
		return 1;
	}

	if (create_dmabuf() < 0) return 1;

	g_surface = wl_compositor_create_surface(g_compositor);
	g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
	xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);
	g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
	xdg_toplevel_add_listener(g_toplevel, &xdg_toplevel_listener, NULL);
	xdg_toplevel_set_app_id(g_toplevel, "dmabuf_pattern_test");
	xdg_toplevel_set_title(g_toplevel, "dmabuf-pattern");
	wl_surface_commit(g_surface);

	while (g_running && wl_display_dispatch(g_display) >= 0) { }

	if (g_buffer)        wl_buffer_destroy(g_buffer);
	if (g_bo)            gbm_bo_destroy(g_bo);
	if (g_gbm_dev)       gbm_device_destroy(g_gbm_dev);
	if (g_drm_fd >= 0)   close(g_drm_fd);
	if (g_toplevel)      xdg_toplevel_destroy(g_toplevel);
	if (g_xdg_surface)   xdg_surface_destroy(g_xdg_surface);
	if (g_surface)       wl_surface_destroy(g_surface);
	wl_display_disconnect(g_display);
	return 0;
}
