/**
 * test-pointer-logger - Minimal xdg_toplevel client that logs pointer events.
 *
 * Maps a normal toplevel (so the compositor gives it a titlebar) and appends a
 * line to a marker file for every wl_pointer event it receives, with decoded
 * surface-local coordinates:
 *
 *     enter <sx> <sy>
 *     motion <sx> <sy>
 *     leave
 *
 * Used by tests/test-titlebar-pointer-leak.lua (and ad-hoc) to assert that the
 * client receives NO pointer events while the cursor is over its titlebar, and
 * correct content-local coordinates while over its content.
 *
 * Usage: test-pointer-logger --app-id ID --marker PATH [--size WxH]
 */

#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct wl_seat *g_seat;
static struct wl_pointer *g_pointer;
static struct xdg_wm_base *g_xdg_wm_base;
static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;

static bool g_running = true;
static int g_width = 600, g_height = 400;

static const char *g_app_id = "pointer_logger";
static const char *g_marker = NULL;

static void handle_signal(int sig) {
    (void)sig;
    g_running = false;
}

/* Append one decoded pointer event to the marker file. */
static void log_event(const char *fmt, ...) {
    if (!g_marker)
        return;
    FILE *f = fopen(g_marker, "a");
    if (!f)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static struct wl_buffer *create_buffer(int w, int h) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-pointer-logger-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) {
        perror("mkstemp");
        return NULL;
    }
    unlink(name);

    if (ftruncate(fd, size) < 0) {
        perror("ftruncate");
        close(fd);
        return NULL;
    }

    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return NULL;
    }
    memset(data, 0xC0, size); /* opaque-ish solid fill */
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

/* Pointer */
static void pointer_enter(void *data, struct wl_pointer *ptr, uint32_t serial,
        struct wl_surface *surf, wl_fixed_t sx, wl_fixed_t sy) {
    (void)data; (void)ptr; (void)serial; (void)surf;
    log_event("enter %d %d", wl_fixed_to_int(sx), wl_fixed_to_int(sy));
}

static void pointer_leave(void *data, struct wl_pointer *ptr, uint32_t serial,
        struct wl_surface *surf) {
    (void)data; (void)ptr; (void)serial; (void)surf;
    log_event("leave");
}

static void pointer_motion(void *data, struct wl_pointer *ptr, uint32_t time,
        wl_fixed_t sx, wl_fixed_t sy) {
    (void)data; (void)ptr; (void)time;
    log_event("motion %d %d", wl_fixed_to_int(sx), wl_fixed_to_int(sy));
}

static void pointer_button(void *data, struct wl_pointer *ptr, uint32_t serial,
        uint32_t time, uint32_t button, uint32_t state) {
    (void)data; (void)ptr; (void)serial; (void)time;
    log_event("button %u %u", button, state);
}

static void pointer_axis(void *data, struct wl_pointer *ptr, uint32_t time,
        uint32_t axis, wl_fixed_t value) {
    (void)data; (void)ptr; (void)time;
    log_event("axis %u %d", axis, wl_fixed_to_int(value));
}

static void pointer_frame(void *data, struct wl_pointer *ptr) { (void)data; (void)ptr; }
static void pointer_axis_source(void *data, struct wl_pointer *ptr, uint32_t s) { (void)data; (void)ptr; (void)s; }
static void pointer_axis_stop(void *data, struct wl_pointer *ptr, uint32_t t, uint32_t a) { (void)data; (void)ptr; (void)t; (void)a; }
static void pointer_axis_discrete(void *data, struct wl_pointer *ptr, uint32_t a, int32_t d) { (void)data; (void)ptr; (void)a; (void)d; }

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
};

/* Seat */
static void seat_capabilities(void *data, struct wl_seat *st, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !g_pointer) {
        g_pointer = wl_seat_get_pointer(st);
        wl_pointer_add_listener(g_pointer, &pointer_listener, NULL);
    }
}

static void seat_name(void *data, struct wl_seat *st, const char *name) {
    (void)data; (void)st; (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

/* xdg_surface / toplevel / wm_base */
static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    struct wl_buffer *buffer = create_buffer(g_width, g_height);
    if (buffer) {
        wl_surface_attach(g_surface, buffer, 0, 0);
        wl_surface_damage_buffer(g_surface, 0, 0, g_width, g_height);
        wl_surface_commit(g_surface);
    }
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *t,
        int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    if (w > 0) g_width = w;
    if (h > 0) g_height = h;
}

static void toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)data; (void)t;
    g_running = false;
}

static void toplevel_configure_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h) {
    (void)data; (void)t; (void)w; (void)h;
}

static void toplevel_wm_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps) {
    (void)data; (void)t; (void)caps;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

/* Registry */
static void registry_global(void *data, struct wl_registry *reg,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        g_shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
        wl_seat_add_listener(g_seat, &seat_listener, NULL);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        g_xdg_wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 5);
        xdg_wm_base_add_listener(g_xdg_wm_base, &xdg_wm_base_listener, NULL);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s --app-id ID --marker PATH [--size WxH]\n", prog);
}

int main(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--app-id") == 0 && i + 1 < argc) {
            g_app_id = argv[++i];
        } else if (strcmp(argv[i], "--marker") == 0 && i + 1 < argc) {
            g_marker = argv[++i];
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            int w, h;
            if (sscanf(argv[++i], "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
                g_width = w;
                g_height = h;
            }
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    g_display = wl_display_connect(NULL);
    if (!g_display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    wl_display_roundtrip(g_display);

    if (!g_compositor || !g_shm || !g_xdg_wm_base) {
        fprintf(stderr, "Missing required Wayland globals\n");
        return 1;
    }

    g_surface = wl_compositor_create_surface(g_compositor);
    g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
    xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);
    g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
    xdg_toplevel_add_listener(g_toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(g_toplevel, g_app_id);
    xdg_toplevel_set_title(g_toplevel, "pointer-logger");

    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-pointer-logger] running (app_id=%s, marker=%s)\n",
        g_app_id, g_marker ? g_marker : "(none)");

    while (g_running && wl_display_dispatch(g_display) != -1) {
        /* keep running */
    }

    if (g_toplevel) xdg_toplevel_destroy(g_toplevel);
    if (g_xdg_surface) xdg_surface_destroy(g_xdg_surface);
    if (g_surface) wl_surface_destroy(g_surface);
    if (g_pointer) wl_pointer_destroy(g_pointer);
    if (g_seat) wl_seat_destroy(g_seat);
    if (g_shm) wl_shm_destroy(g_shm);
    if (g_compositor) wl_compositor_destroy(g_compositor);
    if (g_xdg_wm_base) xdg_wm_base_destroy(g_xdg_wm_base);
    if (g_registry) wl_registry_destroy(g_registry);
    wl_display_disconnect(g_display);
    return 0;
}
