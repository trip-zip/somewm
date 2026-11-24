/**
 * test-session-lock-client - Minimal ext-session-lock-v1 client
 *
 * Locks the session, then draws one solid shm surface per wl_output.
 *
 * - Prints "locked" on stdout when the compositor confirms the lock
 * - Prints "surface <n>" on stdout for each output it has committed
 * - Prints "keyboard enter" / "keyboard leave" as its surfaces gain and lose
 *   keyboard focus
 * - On SIGUSR1 (or --unlock): sends unlock_and_destroy and exits
 * - On SIGTERM: exits without unlocking, the failed-client path
 *
 * --eager requests the lock surfaces in the same flush as the lock, before
 * `locked` arrives (Quickshell does this); by default they follow `locked`
 * (swaylock does this).
 *
 * Usage: test-session-lock-client [--unlock] [--eager]
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
#include "ext-session-lock-v1-client-protocol.h"

#define MAX_OUTPUTS 8

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_shm *g_shm;
static struct wl_seat *g_seat;
static struct wl_keyboard *g_keyboard;
static struct ext_session_lock_manager_v1 *g_manager;
static struct ext_session_lock_v1 *g_lock;

static struct wl_output *g_outputs[MAX_OUTPUTS];
static int g_output_count;

struct lock_output {
    struct wl_surface *surface;
    struct ext_session_lock_surface_v1 *lock_surface;
    bool committed;
};
static struct lock_output g_lock_outputs[MAX_OUTPUTS];

static bool g_running = true;
static bool g_unlock = false;
static bool g_locked = false;
static bool g_eager = false;

static void handle_sigterm(int sig) {
    (void)sig;
    g_running = false;
}

static void handle_sigusr1(int sig) {
    (void)sig;
    g_unlock = true;
}

/* A solid ARGB buffer of the configured size. */
static struct wl_buffer *create_buffer(uint32_t w, uint32_t h, uint32_t color) {
    int stride = w * 4;
    int size = stride * h;

    char name[] = "/tmp/test-session-lock-XXXXXX";
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

static void lock_surface_configure(void *data,
        struct ext_session_lock_surface_v1 *lock_surface, uint32_t serial,
        uint32_t width, uint32_t height) {
    struct lock_output *lo = data;

    ext_session_lock_surface_v1_ack_configure(lock_surface, serial);

    struct wl_buffer *buffer = create_buffer(width, height, 0xFF204080);
    if (!buffer)
        return;
    wl_surface_attach(lo->surface, buffer, 0, 0);
    wl_surface_damage_buffer(lo->surface, 0, 0, width, height);
    wl_surface_commit(lo->surface);
    if (!lo->committed) {
        lo->committed = true;
        printf("surface %d\n", (int)(lo - g_lock_outputs));
        fflush(stdout);
    }
}

static const struct ext_session_lock_surface_v1_listener lock_surface_listener = {
    .configure = lock_surface_configure,
};

static void create_lock_surfaces(void) {
    for (int i = 0; i < g_output_count; i++) {
        struct lock_output *lo = &g_lock_outputs[i];

        lo->surface = wl_compositor_create_surface(g_compositor);
        lo->lock_surface = ext_session_lock_v1_get_lock_surface(
            g_lock, lo->surface, g_outputs[i]);
        ext_session_lock_surface_v1_add_listener(lo->lock_surface,
            &lock_surface_listener, lo);
    }
    wl_display_flush(g_display);
}

static void lock_locked(void *data, struct ext_session_lock_v1 *lock) {
    (void)data; (void)lock;
    g_locked = true;
    printf("locked\n");
    fflush(stdout);
    if (!g_eager)
        create_lock_surfaces();
}

static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)data; (void)lock;
    fprintf(stderr, "[test-session-lock-client] lock finished\n");
    g_running = false;
}

static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked,
    .finished = lock_finished,
};

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
        uint32_t format, int32_t fd, uint32_t size) {
    (void)data; (void)kb; (void)format; (void)size;
    close(fd);
}

static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial,
        struct wl_surface *surface, struct wl_array *keys) {
    (void)data; (void)kb; (void)serial; (void)surface; (void)keys;
    printf("keyboard enter\n");
    fflush(stdout);
}

static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial,
        struct wl_surface *surface) {
    (void)data; (void)kb; (void)serial; (void)surface;
    printf("keyboard leave\n");
    fflush(stdout);
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
        uint32_t time, uint32_t key, uint32_t state) {
    (void)data; (void)kb; (void)serial; (void)time; (void)key; (void)state;
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
        uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked,
        uint32_t group) {
    (void)data; (void)kb; (void)serial; (void)depressed; (void)latched;
    (void)locked; (void)group;
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *kb,
        int32_t rate, int32_t delay) {
    (void)data; (void)kb; (void)rate; (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !g_keyboard) {
        g_keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(g_keyboard, &keyboard_listener, NULL);
    }
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void registry_global(void *data, struct wl_registry *registry,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_compositor = wl_registry_bind(registry, name,
            &wl_compositor_interface, 4);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        g_shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0 && !g_seat) {
        g_seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        wl_seat_add_listener(g_seat, &seat_listener, NULL);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        if (g_output_count < MAX_OUTPUTS)
            g_outputs[g_output_count++] = wl_registry_bind(registry, name,
                &wl_output_interface, 3);
    } else if (strcmp(interface,
            ext_session_lock_manager_v1_interface.name) == 0) {
        g_manager = wl_registry_bind(registry, name,
            &ext_session_lock_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
        uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int main(int argc, char **argv) {
    bool unlock_on_term = false;

    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--unlock") == 0)
            unlock_on_term = true;
        else if (strcmp(argv[i], "--eager") == 0)
            g_eager = true;

    signal(SIGTERM, handle_sigterm);
    signal(SIGINT, handle_sigterm);
    signal(SIGUSR1, handle_sigusr1);

    g_display = wl_display_connect(NULL);
    if (!g_display) {
        fprintf(stderr, "[test-session-lock-client] cannot connect\n");
        return 1;
    }
    g_registry = wl_display_get_registry(g_display);
    wl_registry_add_listener(g_registry, &registry_listener, NULL);
    wl_display_roundtrip(g_display);
    /* wl_output globals arrive with the first roundtrip; their events with
     * the second, which is also when a late global would show up. */
    wl_display_roundtrip(g_display);

    if (!g_compositor || !g_shm || !g_manager || g_output_count == 0) {
        fprintf(stderr, "[test-session-lock-client] missing globals\n");
        return 1;
    }

    g_lock = ext_session_lock_manager_v1_lock(g_manager);
    ext_session_lock_v1_add_listener(g_lock, &lock_listener, NULL);
    if (g_eager)
        create_lock_surfaces(); /* flushes the lock with them */
    else
        wl_display_flush(g_display);

    while (g_running) {
        if (g_unlock)
            break;

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
        if (poll(&pfd, 1, 100) > 0)
            wl_display_read_events(g_display);
        else
            wl_display_cancel_read(g_display);
    }
done:
    /* SIGUSR1, or SIGTERM with --unlock, releases the lock. A plain SIGTERM
     * leaves it behind: the compositor must keep the session locked with no
     * lock client. */
    if ((g_unlock || unlock_on_term) && g_lock && g_locked) {
        ext_session_lock_v1_unlock_and_destroy(g_lock);
        g_lock = NULL;
        wl_display_flush(g_display);
        wl_display_roundtrip(g_display);
    }

    fprintf(stderr, "[test-session-lock-client] shutting down\n");
    wl_display_disconnect(g_display);
    return 0;
}
