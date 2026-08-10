/**
 * test-csd-state-client - Minimal XDG shell client for CSD maximize/minimize tests
 *
 * Stands in for the client-side decoration buttons Gtk/Chromium draw
 * themselves, so Lua tests can verify the compositor honors
 * xdg_toplevel.set_maximized / unset_maximized / set_minimized.
 *
 * - Starts with one XDG toplevel (app_id: "csd_test")
 * - On SIGUSR1: xdg_toplevel_set_maximized()
 * - On SIGUSR2: xdg_toplevel_unset_maximized()
 * - On SIGHUP:  xdg_toplevel_set_minimized()
 * - On SIGTERM: clean shutdown
 *
 * Usage: test-csd-state-client
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

/* Globals */
static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct xdg_wm_base *g_xdg_wm_base;

static bool g_running = true;
/* Which state request to send on the next loop pass, as a signal number. */
static volatile sig_atomic_t g_pending;

/* Toplevel */
static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;

static uint32_t g_width = 200, g_height = 200;

/* Signal handlers */
static void handle_sigterm(int sig) {
    (void)sig;
    g_running = false;
}

static void handle_state_sig(int sig) {
    g_pending = sig;
}

/* Create a simple shared memory buffer */
static struct wl_buffer *create_buffer(uint32_t w, uint32_t h, uint32_t color) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-csd-state-XXXXXX";
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

/* xdg_surface callbacks */
static void xdg_surface_configure(void *data,
        struct xdg_surface *xdg_surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xdg_surface, serial);

    struct wl_buffer *buffer = create_buffer(g_width, g_height, 0xFF996633);
    if (buffer) {
        wl_surface_attach(g_surface, buffer, 0, 0);
        wl_surface_commit(g_surface);
    }
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

/* xdg_toplevel callbacks */
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

/* xdg_wm_base callbacks */
static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base,
        uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

/* Registry callbacks */
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

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    /* Setup signal handlers.
     * No SA_RESTART, so poll() returns EINTR and we act on the request
     * immediately instead of up to 100ms later. */
    struct sigaction sa_term = { .sa_handler = handle_sigterm };
    struct sigaction sa_state = { .sa_handler = handle_state_sig };
    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_term, NULL);
    sigaction(SIGUSR1, &sa_state, NULL);
    sigaction(SIGUSR2, &sa_state, NULL);
    sigaction(SIGHUP, &sa_state, NULL);

    /* Connect to Wayland */
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

    /* Create surface + xdg toplevel */
    g_surface = wl_compositor_create_surface(g_compositor);

    g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
    xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);

    g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
    xdg_toplevel_add_listener(g_toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(g_toplevel, "csd_test");
    xdg_toplevel_set_title(g_toplevel, "CSD State Test");

    /* Initial commit to get configure event */
    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-csd-state-client] running (pid=%d)\n", getpid());

    /* Event loop using poll with timeout */
    while (g_running) {
        if (g_pending) {
            int sig = g_pending;
            g_pending = 0;
            switch (sig) {
            case SIGUSR1:
                fprintf(stderr, "[test-csd-state-client] requesting maximize\n");
                xdg_toplevel_set_maximized(g_toplevel);
                break;
            case SIGUSR2:
                fprintf(stderr, "[test-csd-state-client] requesting unmaximize\n");
                xdg_toplevel_unset_maximized(g_toplevel);
                break;
            case SIGHUP:
                fprintf(stderr, "[test-csd-state-client] requesting minimize\n");
                xdg_toplevel_set_minimized(g_toplevel);
                break;
            }
            wl_surface_commit(g_surface);
            wl_display_flush(g_display);
        }

        /* Dispatch any pending events first */
        if (wl_display_dispatch_pending(g_display) == -1)
            break;

        /* Flush outgoing requests */
        if (wl_display_flush(g_display) == -1 && errno != EAGAIN)
            break;

        /* Prepare to read, dispatch pending if another thread beat us */
        while (wl_display_prepare_read(g_display) != 0) {
            if (wl_display_dispatch_pending(g_display) == -1)
                goto done;
        }

        /* Poll with 100ms timeout so we can check signal flags */
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

    fprintf(stderr, "[test-csd-state-client] shutting down\n");

    /* Cleanup */
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
