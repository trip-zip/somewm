/**
 * test-transient-client - Minimal XDG shell client for transient stacking tests
 *
 * Creates an XDG toplevel (parent), then on SIGUSR1 creates a second XDG
 * toplevel with xdg_toplevel_set_parent() (child/transient). This lets Lua
 * tests control timing: set above=true on parent BEFORE the transient appears.
 *
 * - Starts with one XDG toplevel (app_id: "transient_test_parent")
 * - On SIGUSR1: creates second toplevel with set_parent (app_id: "transient_test_child")
 * - On SIGTERM: clean shutdown
 *
 * Usage: test-transient-client
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
static bool g_spawn_child = false;

/* Parent toplevel */
static struct wl_surface *g_parent_surface;
static struct xdg_surface *g_parent_xdg_surface;
static struct xdg_toplevel *g_parent_toplevel;

/* Child toplevel (created on SIGUSR1) */
static struct wl_surface *g_child_surface;
static struct xdg_surface *g_child_xdg_surface;
static struct xdg_toplevel *g_child_toplevel;

static uint32_t g_width = 200, g_height = 200;

/* Signal handlers */
static void handle_sigterm(int sig) {
    (void)sig;
    g_running = false;
}

static void handle_sigusr1(int sig) {
    (void)sig;
    g_spawn_child = true;
}

/* Create a simple shared memory buffer */
static struct wl_buffer *create_buffer(uint32_t w, uint32_t h, uint32_t color) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-transient-XXXXXX";
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

    /* Fill with specified color */
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

    /* Attach buffer on first configure */
    struct wl_surface *surface = NULL;
    uint32_t color = 0xFF404040; /* dark gray */

    if (xdg_surface == g_parent_xdg_surface) {
        surface = g_parent_surface;
        color = 0xFF404040;
    } else if (xdg_surface == g_child_xdg_surface) {
        surface = g_child_surface;
        color = 0xFF804040; /* reddish for child */
    }

    if (surface) {
        struct wl_buffer *buffer = create_buffer(g_width, g_height, color);
        if (buffer) {
            wl_surface_attach(surface, buffer, 0, 0);
            wl_surface_commit(surface);
        }
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

/* Create the child toplevel as a transient of the parent */
static void create_child(void) {
    if (g_child_surface) return; /* Already created */

    fprintf(stderr, "[test-transient-client] creating child toplevel\n");

    g_child_surface = wl_compositor_create_surface(g_compositor);

    g_child_xdg_surface = xdg_wm_base_get_xdg_surface(
        g_xdg_wm_base, g_child_surface);
    xdg_surface_add_listener(g_child_xdg_surface, &xdg_surface_listener, NULL);

    g_child_toplevel = xdg_surface_get_toplevel(g_child_xdg_surface);
    xdg_toplevel_add_listener(g_child_toplevel, &toplevel_listener, NULL);

    /* Set parent relationship — this is the key part for transient stacking */
    xdg_toplevel_set_parent(g_child_toplevel, g_parent_toplevel);
    xdg_toplevel_set_app_id(g_child_toplevel, "transient_test_child");
    xdg_toplevel_set_title(g_child_toplevel, "Transient Child");

    /* Initial commit to trigger configure */
    wl_surface_commit(g_child_surface);
    wl_display_flush(g_display);

    fprintf(stderr, "[test-transient-client] child toplevel created\n");
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    /* Setup signal handlers.
     * Use sigaction WITHOUT SA_RESTART so that wl_display_dispatch() returns
     * EINTR when a signal arrives. glibc's signal() sets SA_RESTART, which
     * would cause dispatch to auto-restart and never check g_spawn_child. */
    struct sigaction sa_term = { .sa_handler = handle_sigterm };
    struct sigaction sa_usr1 = { .sa_handler = handle_sigusr1 };
    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_term, NULL);
    sigaction(SIGUSR1, &sa_usr1, NULL);

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

    /* Create parent surface + xdg toplevel */
    g_parent_surface = wl_compositor_create_surface(g_compositor);

    g_parent_xdg_surface = xdg_wm_base_get_xdg_surface(
        g_xdg_wm_base, g_parent_surface);
    xdg_surface_add_listener(g_parent_xdg_surface, &xdg_surface_listener, NULL);

    g_parent_toplevel = xdg_surface_get_toplevel(g_parent_xdg_surface);
    xdg_toplevel_add_listener(g_parent_toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(g_parent_toplevel, "transient_test_parent");
    xdg_toplevel_set_title(g_parent_toplevel, "Transient Parent");

    /* Initial commit to get configure event */
    wl_surface_commit(g_parent_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-transient-client] running (pid=%d)\n", getpid());

    /* Event loop using poll with timeout.
     * This allows us to check g_spawn_child between dispatches, since
     * SIGUSR1 may arrive while poll() is blocking. A short timeout ensures
     * we don't miss the signal flag. */
    while (g_running) {
        if (g_spawn_child) {
            g_spawn_child = false;
            create_child();
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

    fprintf(stderr, "[test-transient-client] shutting down\n");

    /* Cleanup child */
    if (g_child_toplevel) xdg_toplevel_destroy(g_child_toplevel);
    if (g_child_xdg_surface) xdg_surface_destroy(g_child_xdg_surface);
    if (g_child_surface) wl_surface_destroy(g_child_surface);

    /* Cleanup parent */
    if (g_parent_toplevel) xdg_toplevel_destroy(g_parent_toplevel);
    if (g_parent_xdg_surface) xdg_surface_destroy(g_parent_xdg_surface);
    if (g_parent_surface) wl_surface_destroy(g_parent_surface);

    /* Cleanup globals */
    if (g_xdg_wm_base) xdg_wm_base_destroy(g_xdg_wm_base);
    if (g_shm) wl_shm_destroy(g_shm);
    if (g_compositor) wl_compositor_destroy(g_compositor);
    if (g_registry) wl_registry_destroy(g_registry);
    wl_display_disconnect(g_display);

    return 0;
}
