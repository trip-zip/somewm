/**
 * test-fullscreen-client - Minimal XDG shell client for fullscreen protocol tests
 *
 * Creates an XDG toplevel that can request fullscreen/unfullscreen via signals,
 * letting Lua tests verify that the compositor correctly syncs protocol state
 * and restores geometry when the client exits fullscreen.
 *
 * - Starts with one XDG toplevel (app_id: "fullscreen_test")
 * - On SIGUSR1: requests fullscreen via xdg_toplevel_set_fullscreen()
 * - On SIGUSR2: requests unfullscreen via xdg_toplevel_unset_fullscreen()
 * - On SIGTERM: clean shutdown
 *
 * Usage: test-fullscreen-client
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
static volatile sig_atomic_t g_request_fullscreen = 0;
static volatile sig_atomic_t g_request_unfullscreen = 0;

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

static void handle_sigusr1(int sig) {
    (void)sig;
    g_request_fullscreen = 1;
}

static void handle_sigusr2(int sig) {
    (void)sig;
    g_request_unfullscreen = 1;
}

/* Create a simple shared memory buffer */
static struct wl_buffer *create_buffer(uint32_t w, uint32_t h, uint32_t color) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-fullscreen-XXXXXX";
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

    struct wl_buffer *buffer = create_buffer(g_width, g_height, 0xFF336699);
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
     * Use sigaction WITHOUT SA_RESTART so that wl_display_dispatch() returns
     * EINTR when a signal arrives. */
    struct sigaction sa_term = { .sa_handler = handle_sigterm };
    struct sigaction sa_usr1 = { .sa_handler = handle_sigusr1 };
    struct sigaction sa_usr2 = { .sa_handler = handle_sigusr2 };
    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_term, NULL);
    sigaction(SIGUSR1, &sa_usr1, NULL);
    sigaction(SIGUSR2, &sa_usr2, NULL);

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
    xdg_toplevel_set_app_id(g_toplevel, "fullscreen_test");
    xdg_toplevel_set_title(g_toplevel, "Fullscreen Test");

    /* Initial commit to get configure event */
    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-fullscreen-client] running (pid=%d)\n", getpid());

    /* Event loop using poll with timeout */
    while (g_running) {
        if (g_request_fullscreen) {
            g_request_fullscreen = 0;
            fprintf(stderr, "[test-fullscreen-client] requesting fullscreen\n");
            xdg_toplevel_set_fullscreen(g_toplevel, NULL);
            wl_surface_commit(g_surface);
            wl_display_flush(g_display);
        }

        if (g_request_unfullscreen) {
            g_request_unfullscreen = 0;
            fprintf(stderr, "[test-fullscreen-client] requesting unfullscreen\n");
            xdg_toplevel_unset_fullscreen(g_toplevel);
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

    fprintf(stderr, "[test-fullscreen-client] shutting down\n");

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
