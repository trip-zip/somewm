/**
 * test-disconnect-mid-map-client - XDG client that disconnects right after the
 * mapping commit. Used to reproduce the wl_display_flush_clients re-entrance
 * crash inside mapnotify (window.c).
 *
 * Sequence:
 *   1. Connect, bind compositor + shm + xdg_wm_base.
 *   2. Create xdg_surface + xdg_toplevel.
 *   3. Initial commit, wait for configure, ack.
 *   4. Attach a real SHM buffer and commit (mapping commit).
 *   5. Flush, then close the wl_display fd and _exit(0) without dispatching
 *      any further events. The compositor sees the EOF on the next poll
 *      and tears the client down. If the tear-down lands while the
 *      surface->events.map signal is still being emitted (mapnotify on the
 *      stack), wlroots aborts on
 *        assert(wl_list_empty(&surface->events.map.listener_list))
 *      in types/wlr_compositor.c:735.
 *
 * The race is timing-sensitive but reliably hit when the client is launched
 * many times in quick succession against a compositor that is otherwise idle.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_display *g_display;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct xdg_wm_base *g_xdg_wm_base;

static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;

static int g_configured = 0;
static uint32_t g_width = 64, g_height = 64;

static struct wl_buffer *
create_buffer(uint32_t w, uint32_t h)
{
	int stride = w * 4;
	int size = stride * h;

	char tmpl[] = "/tmp/test-disconnect-shm-XXXXXX";
	int fd = mkstemp(tmpl);
	if (fd < 0)
		return NULL;
	unlink(tmpl);

	if (ftruncate(fd, size) < 0) {
		close(fd);
		return NULL;
	}

	uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		close(fd);
		return NULL;
	}
	for (int i = 0; i < (int)(w * h); i++)
		data[i] = 0xFF223366;
	munmap(data, size);

	struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
	struct wl_buffer *buf = wl_shm_pool_create_buffer(
		pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	return buf;
}

static void
xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial)
{
	(void)data;
	xdg_surface_ack_configure(xs, serial);
	g_configured = 1;
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void
toplevel_configure(void *data, struct xdg_toplevel *t,
                   int32_t w, int32_t h, struct wl_array *states)
{
	(void)data; (void)t; (void)states;
	if (w > 0) g_width = w;
	if (h > 0) g_height = h;
}

static void toplevel_close(void *d, struct xdg_toplevel *t)
{ (void)d; (void)t; }
static void toplevel_configure_bounds(void *d, struct xdg_toplevel *t,
                                      int32_t w, int32_t h)
{ (void)d; (void)t; (void)w; (void)h; }
static void toplevel_wm_capabilities(void *d, struct xdg_toplevel *t,
                                     struct wl_array *caps)
{ (void)d; (void)t; (void)caps; }

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
	.configure_bounds = toplevel_configure_bounds,
	.wm_capabilities = toplevel_wm_capabilities,
};

static void
xdg_wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(b, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
	.ping = xdg_wm_base_ping,
};

static void
registry_global(void *data, struct wl_registry *reg,
                uint32_t name, const char *iface, uint32_t version)
{
	(void)data; (void)version;
	if (strcmp(iface, wl_compositor_interface.name) == 0)
		g_compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	else if (strcmp(iface, wl_shm_interface.name) == 0)
		g_shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		g_xdg_wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 5);
		xdg_wm_base_add_listener(g_xdg_wm_base, &xdg_wm_base_listener, NULL);
	}
}

static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{ (void)data; (void)reg; (void)name; }

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int
main(int argc, char **argv)
{
	(void)argc; (void)argv;

	g_display = wl_display_connect(NULL);
	if (!g_display) {
		fprintf(stderr, "connect failed\n");
		return 1;
	}

	struct wl_registry *reg = wl_display_get_registry(g_display);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(g_display);

	if (!g_compositor || !g_shm || !g_xdg_wm_base) {
		fprintf(stderr, "missing globals\n");
		return 1;
	}

	g_surface = wl_compositor_create_surface(g_compositor);
	g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
	xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);
	g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
	xdg_toplevel_add_listener(g_toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_app_id(g_toplevel, "somewm.test.disconnect_mid_map");
	xdg_toplevel_set_title(g_toplevel, "disconnect mid map");

	wl_surface_commit(g_surface);

	while (!g_configured) {
		if (wl_display_dispatch(g_display) < 0) {
			fprintf(stderr, "dispatch failed before configure\n");
			return 1;
		}
	}

	struct wl_buffer *buf = create_buffer(g_width, g_height);
	if (!buf) {
		fprintf(stderr, "buffer creation failed\n");
		return 1;
	}
	wl_surface_attach(g_surface, buf, 0, 0);
	wl_surface_damage_buffer(g_surface, 0, 0, g_width, g_height);
	wl_surface_commit(g_surface);

	wl_display_flush(g_display);

	int fd = wl_display_get_fd(g_display);
	if (fd >= 0)
		close(fd);

	_exit(0);
}
