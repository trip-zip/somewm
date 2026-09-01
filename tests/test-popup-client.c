/**
 * test-popup-client - XDG toplevel that opens a real xdg_popup on demand
 *
 * The popup is anchored off the parent's bottom-right corner, so it covers
 * screen area the parent's own content does not. That is the only place a
 * pointer can land on the popup's scene subtree: popups are parented under
 * Client::popups, a sibling of the content tree, and hit-testing returns the
 * topmost node.
 *
 * - Starts with one XDG toplevel (app_id: "popup_test")
 * - On SIGUSR1: creates an xdg_popup on that toplevel
 * - On SIGTERM: clean shutdown
 *
 * Usage: test-popup-client
 */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

/* Popup geometry, in surface-local coordinates of the parent. */
#define POPUP_SIZE 120

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct xdg_wm_base *g_xdg_wm_base;

static bool g_running = true;
static bool g_spawn_popup = false;

static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;

static struct wl_surface *g_popup_surface;
static struct xdg_surface *g_popup_xdg_surface;
static struct xdg_popup *g_popup;

static uint32_t g_width = 200, g_height = 200;

static void handle_sigterm(int sig) {
    (void)sig;
    g_running = false;
}

static void handle_sigusr1(int sig) {
    (void)sig;
    g_spawn_popup = true;
}

static struct wl_buffer *create_buffer(uint32_t w, uint32_t h, uint32_t color) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-popup-XXXXXX";
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

    uint32_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return NULL;
    }

    for (int i = 0; i < (int)(w * h); i++)
        data[i] = color;
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    return buffer;
}

static void xdg_surface_configure(void *data,
        struct xdg_surface *xdg_surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xdg_surface, serial);

    struct wl_surface *surface = NULL;
    uint32_t w = g_width, h = g_height;
    uint32_t color = 0xFF404040; /* dark gray */

    if (xdg_surface == g_xdg_surface) {
        surface = g_surface;
    } else if (xdg_surface == g_popup_xdg_surface) {
        surface = g_popup_surface;
        w = h = POPUP_SIZE;
        color = 0xFF4080C0; /* blue, so a screenshot tells them apart */
    }

    if (surface) {
        struct wl_buffer *buffer = create_buffer(w, h, color);
        if (buffer) {
            wl_surface_attach(surface, buffer, 0, 0);
            wl_surface_commit(surface);
        }
    }
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
        int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)toplevel; (void)states;
    if (w > 0) g_width = w;
    if (h > 0) g_height = h;
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel;
    g_running = false;
}

static void toplevel_configure_bounds(void *data,
        struct xdg_toplevel *toplevel, int32_t w, int32_t h) {
    (void)data; (void)toplevel; (void)w; (void)h;
}

static void toplevel_wm_capabilities(void *data,
        struct xdg_toplevel *toplevel, struct wl_array *caps) {
    (void)data; (void)toplevel; (void)caps;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

static void popup_configure(void *data, struct xdg_popup *popup,
        int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)data; (void)popup;
    fprintf(stderr, "[test-popup-client] popup configured at %d,%d %dx%d\n",
        x, y, w, h);
}

static void popup_done(void *data, struct xdg_popup *popup) {
    (void)data; (void)popup;
    fprintf(stderr, "[test-popup-client] popup dismissed\n");
}

static void popup_repositioned(void *data, struct xdg_popup *popup,
        uint32_t token) {
    (void)data; (void)popup; (void)token;
}

static const struct xdg_popup_listener popup_listener = {
    .configure = popup_configure,
    .popup_done = popup_done,
    .repositioned = popup_repositioned,
};

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base,
        uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

static void registry_global(void *data, struct wl_registry *reg,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;

    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_compositor = wl_registry_bind(reg, name,
            &wl_compositor_interface, 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        g_shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        g_xdg_wm_base = wl_registry_bind(reg, name,
            &xdg_wm_base_interface, 5);
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

/* Open an xdg_popup hanging off the parent's bottom-right corner.
 * No constraint adjustment: the compositor must leave it where we asked, so
 * the test can aim a pointer at it. */
static void create_popup(void) {
    if (g_popup_surface) return; /* Already created */

    fprintf(stderr, "[test-popup-client] creating popup\n");

    struct xdg_positioner *positioner =
        xdg_wm_base_create_positioner(g_xdg_wm_base);
    xdg_positioner_set_size(positioner, POPUP_SIZE, POPUP_SIZE);
    xdg_positioner_set_anchor_rect(positioner, 0, 0, g_width, g_height);
    xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
    xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
    xdg_positioner_set_constraint_adjustment(positioner,
        XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_NONE);

    g_popup_surface = wl_compositor_create_surface(g_compositor);
    g_popup_xdg_surface = xdg_wm_base_get_xdg_surface(
        g_xdg_wm_base, g_popup_surface);
    xdg_surface_add_listener(g_popup_xdg_surface, &xdg_surface_listener, NULL);

    g_popup = xdg_surface_get_popup(g_popup_xdg_surface, g_xdg_surface,
        positioner);
    xdg_popup_add_listener(g_popup, &popup_listener, NULL);
    xdg_positioner_destroy(positioner);

    wl_surface_commit(g_popup_surface);
    wl_display_flush(g_display);

    fprintf(stderr, "[test-popup-client] popup created\n");
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    /* sigaction without SA_RESTART, so dispatch returns EINTR and the loop
     * gets a chance to see g_spawn_popup. */
    struct sigaction sa_term = { .sa_handler = handle_sigterm };
    struct sigaction sa_usr1 = { .sa_handler = handle_sigusr1 };
    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_term, NULL);
    sigaction(SIGUSR1, &sa_usr1, NULL);

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
    xdg_toplevel_set_app_id(g_toplevel, "popup_test");
    xdg_toplevel_set_title(g_toplevel, "Popup Parent");

    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-popup-client] running (pid=%d)\n", getpid());

    while (g_running) {
        if (g_spawn_popup) {
            g_spawn_popup = false;
            create_popup();
        }

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

    fprintf(stderr, "[test-popup-client] shutting down\n");

    if (g_popup) xdg_popup_destroy(g_popup);
    if (g_popup_xdg_surface) xdg_surface_destroy(g_popup_xdg_surface);
    if (g_popup_surface) wl_surface_destroy(g_popup_surface);

    if (g_toplevel) xdg_toplevel_destroy(g_toplevel);
    if (g_xdg_surface) xdg_surface_destroy(g_xdg_surface);
    if (g_surface) wl_surface_destroy(g_surface);

    if (g_xdg_wm_base) xdg_wm_base_destroy(g_xdg_wm_base);
    if (g_shm) wl_shm_destroy(g_shm);
    if (g_compositor) wl_compositor_destroy(g_compositor);
    if (g_registry) wl_registry_destroy(g_registry);
    wl_display_disconnect(g_display);

    return 0;
}
