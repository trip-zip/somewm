/**
 * test-layer-client - Minimal layer-shell client for deterministic testing
 *
 * Creates a layer surface, requests keyboard focus, exits on Escape or SIGTERM.
 * Unlike wofi, this starts instantly and behaves deterministically.
 *
 * Usage: test-layer-client [--namespace NAME] [--keyboard exclusive|on_demand|none]
 */

#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

/* Globals */
static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct wl_seat *g_seat;
static struct wl_keyboard *g_keyboard;
static struct zwlr_layer_shell_v1 *g_layer_shell;
static struct wl_surface *g_surface;
static struct zwlr_layer_surface_v1 *g_layer_surface;

static bool g_running = true;
static uint32_t g_width = 100, g_height = 100;

/* Config from args */
static const char *g_namespace = "test-layer";
static uint32_t g_keyboard_mode = 1; /* EXCLUSIVE */

/* Signal handler for clean shutdown */
static void handle_signal(int sig) {
    (void)sig;
    g_running = false;
}

/* Create a simple shared memory buffer */
static struct wl_buffer *create_buffer(void) {
    int stride = g_width * 4;
    int size = stride * g_height;

    char name[] = "/tmp/test-layer-XXXXXX";
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

    /* Fill with semi-transparent gray */
    memset(data, 0x80, size);
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, g_width, g_height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    return buffer;
}

/* Layer surface callbacks */
static void layer_surface_configure(void *data,
        struct zwlr_layer_surface_v1 *lsurface, uint32_t serial,
        uint32_t w, uint32_t h) {
    (void)data;
    g_width = w > 0 ? w : 100;
    g_height = h > 0 ? h : 100;
    zwlr_layer_surface_v1_ack_configure(lsurface, serial);

    struct wl_buffer *buffer = create_buffer();
    if (buffer) {
        wl_surface_attach(g_surface, buffer, 0, 0);
        wl_surface_commit(g_surface);
    }
}

static void layer_surface_closed(void *data,
        struct zwlr_layer_surface_v1 *lsurface) {
    (void)data;
    (void)lsurface;
    g_running = false;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = layer_surface_configure,
    .closed = layer_surface_closed,
};

/* Keyboard callbacks */
static void keyboard_keymap(void *data, struct wl_keyboard *kbd,
        uint32_t format, int fd, uint32_t size) {
    (void)data; (void)kbd; (void)format; (void)size;
    close(fd);
}

static void keyboard_enter(void *data, struct wl_keyboard *kbd,
        uint32_t serial, struct wl_surface *surf, struct wl_array *keys) {
    (void)data; (void)kbd; (void)serial; (void)surf; (void)keys;
    fprintf(stderr, "[test-layer-client] keyboard enter\n");
}

static void keyboard_leave(void *data, struct wl_keyboard *kbd,
        uint32_t serial, struct wl_surface *surf) {
    (void)data; (void)kbd; (void)serial; (void)surf;
    fprintf(stderr, "[test-layer-client] keyboard leave\n");
}

static void keyboard_key(void *data, struct wl_keyboard *kbd,
        uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)data; (void)kbd; (void)serial; (void)time;

    /* key 1 = Escape in evdev (key + 8 = xkb keycode, Escape = 9) */
    if (key == 1 && state == WL_KEYBOARD_KEY_STATE_PRESSED) {
        fprintf(stderr, "[test-layer-client] Escape pressed, exiting\n");
        g_running = false;
    }
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kbd,
        uint32_t serial, uint32_t mods_depressed, uint32_t mods_latched,
        uint32_t mods_locked, uint32_t group) {
    (void)data; (void)kbd; (void)serial;
    (void)mods_depressed; (void)mods_latched; (void)mods_locked; (void)group;
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *kbd,
        int32_t rate, int32_t delay) {
    (void)data; (void)kbd; (void)rate; (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

/* Seat callbacks */
static void seat_capabilities(void *data, struct wl_seat *st,
        uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !g_keyboard) {
        g_keyboard = wl_seat_get_keyboard(st);
        wl_keyboard_add_listener(g_keyboard, &keyboard_listener, NULL);
    }
}

static void seat_name(void *data, struct wl_seat *st, const char *name) {
    (void)data; (void)st; (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
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
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
        wl_seat_add_listener(g_seat, &seat_listener, NULL);
    } else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
        /* Use version 1 - we don't need any v2+ features */
        uint32_t bind_version = version < 1 ? version : 1;
        g_layer_shell = wl_registry_bind(reg, name,
            &zwlr_layer_shell_v1_interface, bind_version);
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

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s [OPTIONS]\n", prog);
    fprintf(stderr, "  --namespace NAME      Layer surface namespace (default: test-layer)\n");
    fprintf(stderr, "  --keyboard MODE       Keyboard interactivity: exclusive|on_demand|none\n");
    fprintf(stderr, "                        (default: exclusive)\n");
}

int main(int argc, char *argv[]) {
    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--namespace") == 0 && i + 1 < argc) {
            g_namespace = argv[++i];
        } else if (strcmp(argv[i], "--keyboard") == 0 && i + 1 < argc) {
            const char *mode = argv[++i];
            if (strcmp(mode, "exclusive") == 0) {
                g_keyboard_mode = ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE;
            } else if (strcmp(mode, "on_demand") == 0) {
                g_keyboard_mode = ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND;
            } else if (strcmp(mode, "none") == 0) {
                g_keyboard_mode = ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;
            } else {
                fprintf(stderr, "Unknown keyboard mode: %s\n", mode);
                print_usage(argv[0]);
                return 1;
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

    /* Setup signal handlers */
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    /* Connect to Wayland */
    g_display = wl_display_connect(NULL);
    if (!g_display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    wl_display_roundtrip(g_display);

    if (!g_compositor || !g_shm || !g_layer_shell) {
        fprintf(stderr, "Missing required Wayland globals\n");
        return 1;
    }

    /* Create surface */
    g_surface = wl_compositor_create_surface(g_compositor);

    /* Create layer surface */
    g_layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        g_layer_shell, g_surface, NULL,
        ZWLR_LAYER_SHELL_V1_LAYER_TOP, g_namespace);

    zwlr_layer_surface_v1_set_size(g_layer_surface, 100, 100);
    zwlr_layer_surface_v1_set_keyboard_interactivity(g_layer_surface, g_keyboard_mode);
    zwlr_layer_surface_v1_add_listener(g_layer_surface, &layer_surface_listener, NULL);

    /* Initial commit to get configure event */
    wl_surface_commit(g_surface);
    wl_display_roundtrip(g_display);

    fprintf(stderr, "[test-layer-client] running (namespace=%s, keyboard=%d)\n",
        g_namespace, g_keyboard_mode);

    /* Event loop */
    while (g_running && wl_display_dispatch(g_display) != -1) {
        /* keep running */
    }

    fprintf(stderr, "[test-layer-client] shutting down\n");

    /* Cleanup */
    if (g_layer_surface) zwlr_layer_surface_v1_destroy(g_layer_surface);
    if (g_surface) wl_surface_destroy(g_surface);
    if (g_keyboard) wl_keyboard_destroy(g_keyboard);
    if (g_seat) wl_seat_destroy(g_seat);
    if (g_shm) wl_shm_destroy(g_shm);
    if (g_compositor) wl_compositor_destroy(g_compositor);
    if (g_layer_shell) zwlr_layer_shell_v1_destroy(g_layer_shell);
    if (g_registry) wl_registry_destroy(g_registry);
    wl_display_disconnect(g_display);

    return 0;
}
