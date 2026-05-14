/**
 * XDG shell wl_shm client that renders a 4-quadrant pattern at the
 * compositor's preferred buffer scale.
 *
 * Listens for wl_surface.preferred_buffer_scale events (wl_compositor v6+)
 * and re-renders the pattern at the new physical scale, calling
 * wl_surface_set_buffer_scale() before each commit.
 *
 * After every successful commit the integer scale is written to
 *   /tmp/test-content-pattern-<pid>.scale
 * so the test driver can poll until the buffer is at the expected scale
 * before sampling pixels via c.content.
 *
 * Pattern (split by physical buffer dimensions):
 *   TL = red    (0xFFFF0000)   TR = green  (0xFF00FF00)
 *   BL = blue   (0xFF0000FF)   BR = yellow (0xFFFFFF00)
 *
 * Lifecycle: SIGTERM/SIGINT for clean exit. App ID: "content_pattern_test".
 */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

/* Globals */
static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static uint32_t g_compositor_version = 0;
static struct wl_shm *g_shm;
static struct xdg_wm_base *g_xdg_wm_base;

static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;
static struct wl_buffer *g_current_buffer;

static int g_logical_w = 200, g_logical_h = 200;
static int g_pending_scale = 1;
static int g_current_scale = 0;     /* 0 = nothing committed yet */
static char g_marker_path[256];

static volatile sig_atomic_t g_running = 1;

static void handle_term(int sig) {
    (void)sig;
    g_running = 0;
}

/* Create an SHM-backed wl_buffer at the given physical dims, filled with the
 * 4-quadrant ARGB8888 pattern. Caller owns the returned buffer. */
static struct wl_buffer *create_pattern_buffer(int w, int h) {
    if (w <= 0 || h <= 0)
        return NULL;

    int stride = w * 4;
    size_t size = (size_t)stride * (size_t)h;

    char tmpl[] = "/tmp/test-content-pattern-buf-XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        perror("mkstemp");
        return NULL;
    }
    unlink(tmpl);

    if (ftruncate(fd, size) < 0) {
        perror("ftruncate");
        close(fd);
        return NULL;
    }

    uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return NULL;
    }

    int half_w = w / 2;
    int half_h = h / 2;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t color;
            if      (x <  half_w && y <  half_h) color = 0xFFFF0000; /* TL red    */
            else if (x >= half_w && y <  half_h) color = 0xFF00FF00; /* TR green  */
            else if (x <  half_w && y >= half_h) color = 0xFF0000FF; /* BL blue   */
            else                                 color = 0xFFFFFF00; /* BR yellow */
            data[y * w + x] = color;
        }
    }
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(
        pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    return buf;
}

/* Render the pattern at g_pending_scale and commit. After commit, write the
 * scale to the marker file so the test driver can detect this commit. */
static void render_pattern(void) {
    int scale = g_pending_scale > 0 ? g_pending_scale : 1;
    int phys_w = g_logical_w * scale;
    int phys_h = g_logical_h * scale;

    struct wl_buffer *buf = create_pattern_buffer(phys_w, phys_h);
    if (!buf) {
        fprintf(stderr, "[content-pattern-client] buffer alloc failed (%dx%d)\n",
                phys_w, phys_h);
        return;
    }

    wl_surface_set_buffer_scale(g_surface, scale);
    wl_surface_attach(g_surface, buf, 0, 0);
    wl_surface_damage_buffer(g_surface, 0, 0, phys_w, phys_h);
    wl_surface_commit(g_surface);
    wl_display_flush(g_display);

    /* Old buffer may still be in-use by the compositor; we leak it for the
     * lifetime of this short-lived test process rather than tracking
     * wl_buffer.release events. */
    g_current_buffer = buf;
    g_current_scale = scale;

    /* Marker write. A single small write to a regular file on Linux is
     * atomic, so no temp+rename dance is needed. */
    FILE *f = fopen(g_marker_path, "w");
    if (f) {
        fprintf(f, "%d\n", g_current_scale);
        fclose(f);
    }

    fprintf(stderr, "[content-pattern-client] committed scale=%d (%dx%d)\n",
            g_current_scale, phys_w, phys_h);
}

/* wl_surface listeners (v6+ for preferred_buffer_scale/transform) */
static void surface_enter(void *data, struct wl_surface *s, struct wl_output *o) {
    (void)data; (void)s; (void)o;
}

static void surface_leave(void *data, struct wl_surface *s, struct wl_output *o) {
    (void)data; (void)s; (void)o;
}

static void surface_preferred_buffer_scale(void *data, struct wl_surface *s,
                                           int32_t scale) {
    (void)data; (void)s;
    if (scale < 1) scale = 1;
    fprintf(stderr, "[content-pattern-client] preferred_buffer_scale=%d\n", scale);
    g_pending_scale = scale;
    /* Re-render only if we've already drawn at least once and the scale
     * actually changes. The first render is driven by xdg_surface.configure. */
    if (g_current_scale != 0 && g_current_scale != scale)
        render_pattern();
}

static void surface_preferred_buffer_transform(void *data, struct wl_surface *s,
                                               uint32_t transform) {
    (void)data; (void)s; (void)transform;
}

static const struct wl_surface_listener surface_listener = {
    .enter = surface_enter,
    .leave = surface_leave,
    .preferred_buffer_scale = surface_preferred_buffer_scale,
    .preferred_buffer_transform = surface_preferred_buffer_transform,
};

/* xdg_surface */
static void xdg_surface_configure(void *data, struct xdg_surface *xs,
                                  uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    render_pattern();
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

/* xdg_toplevel */
static void toplevel_configure(void *data, struct xdg_toplevel *t,
                               int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    if (w > 0) g_logical_w = w;
    if (h > 0) g_logical_h = h;
}

static void toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)data; (void)t;
    g_running = 0;
}

static void toplevel_configure_bounds(void *data, struct xdg_toplevel *t,
                                      int32_t w, int32_t h) {
    (void)data; (void)t; (void)w; (void)h;
}

static void toplevel_wm_capabilities(void *data, struct xdg_toplevel *t,
                                     struct wl_array *caps) {
    (void)data; (void)t; (void)caps;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

/* xdg_wm_base */
static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base,
                             uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

/* Registry */
static void registry_global(void *data, struct wl_registry *reg,
                            uint32_t name, const char *interface, uint32_t version) {
    (void)data;

    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        /* v6 needed for preferred_buffer_scale events */
        uint32_t bind_ver = version >= 6 ? 6 : version;
        g_compositor = wl_registry_bind(reg, name, &wl_compositor_interface, bind_ver);
        g_compositor_version = bind_ver;
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        g_shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        g_xdg_wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 5);
        xdg_wm_base_add_listener(g_xdg_wm_base, &xdg_wm_base_listener, NULL);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg,
                                   uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    snprintf(g_marker_path, sizeof(g_marker_path),
             "/tmp/test-content-pattern-%d.scale", (int)getpid());
    unlink(g_marker_path);

    struct sigaction sa = { .sa_handler = handle_term };
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    g_display = wl_display_connect(NULL);
    if (!g_display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    wl_display_roundtrip(g_display);

    if (!g_compositor || !g_shm || !g_xdg_wm_base) {
        fprintf(stderr, "Missing required Wayland globals "
                        "(compositor=%p shm=%p xdg_wm_base=%p)\n",
                (void *)g_compositor, (void *)g_shm, (void *)g_xdg_wm_base);
        return 1;
    }

    g_surface = wl_compositor_create_surface(g_compositor);
    if (g_compositor_version >= 6)
        wl_surface_add_listener(g_surface, &surface_listener, NULL);

    g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
    xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);

    g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
    xdg_toplevel_add_listener(g_toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(g_toplevel, "content_pattern_test");
    xdg_toplevel_set_title(g_toplevel, "Content Pattern Test");

    /* Initial commit triggers configure -> render_pattern() */
    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[content-pattern-client] running (pid=%d, marker=%s, compositor_v=%u)\n",
            (int)getpid(), g_marker_path, g_compositor_version);

    while (g_running) {
        if (wl_display_dispatch_pending(g_display) == -1)
            break;

        if (wl_display_flush(g_display) == -1 && errno != EAGAIN)
            break;

        while (wl_display_prepare_read(g_display) != 0) {
            if (wl_display_dispatch_pending(g_display) == -1)
                goto done;
        }

        struct pollfd pfd = {
            .fd = wl_display_get_fd(g_display),
            .events = POLLIN,
        };
        int ret = poll(&pfd, 1, 100);

        if (ret > 0) {
            wl_display_read_events(g_display);
        } else {
            wl_display_cancel_read(g_display);
        }
    }
done:

    fprintf(stderr, "[content-pattern-client] shutting down\n");

    unlink(g_marker_path);

    if (g_toplevel)     xdg_toplevel_destroy(g_toplevel);
    if (g_xdg_surface)  xdg_surface_destroy(g_xdg_surface);
    if (g_surface)      wl_surface_destroy(g_surface);
    if (g_xdg_wm_base)  xdg_wm_base_destroy(g_xdg_wm_base);
    if (g_shm)          wl_shm_destroy(g_shm);
    if (g_compositor)   wl_compositor_destroy(g_compositor);
    if (g_registry)     wl_registry_destroy(g_registry);
    wl_display_disconnect(g_display);

    return 0;
}
