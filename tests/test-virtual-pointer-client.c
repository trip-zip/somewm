/**
 * test-virtual-pointer-client - Inject pointer input via zwlr_virtual_pointer_v1.
 *
 * Moves the cursor to an absolute layout position and performs one left click
 * or scroll tick. Unlike root.fake_input("button_press"), the injected events
 * arrive through a real wlr_input_device, so they traverse the compositor's
 * full buttonpress()/axisnotify() path: mousegrabber routing, client button
 * bindings, and seat notification.
 *
 * Usage: test-virtual-pointer-client <move|click|scroll> <x> <y>
 *                                     <x_extent> <y_extent>
 *                                     [left|middle|right|side|extra|up|down]
 *
 * x/y are layout coordinates; x_extent/y_extent the layout size (normally the
 * screen geometry). "move" only positions the cursor; "click" also presses and
 * releases the given button (left by default); "scroll" sends one discrete
 * vertical wheel tick (down by default). Exits after the events are flushed.
 */

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *g_seat;
static struct zwlr_virtual_pointer_manager_v1 *g_manager;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void sleep_ms(long ms) {
    struct timespec ts = { .tv_sec = 0, .tv_nsec = ms * 1000000 };
    nanosleep(&ts, NULL);
}

static void registry_global(void *data, struct wl_registry *reg,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(interface, wl_seat_interface.name) == 0) {
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        g_manager = wl_registry_bind(reg, name,
            &zwlr_virtual_pointer_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static uint32_t button_code(const char *name) {
    if (strcmp(name, "left") == 0) return BTN_LEFT;
    if (strcmp(name, "middle") == 0) return BTN_MIDDLE;
    if (strcmp(name, "right") == 0) return BTN_RIGHT;
    if (strcmp(name, "side") == 0) return BTN_SIDE;
    if (strcmp(name, "extra") == 0) return BTN_EXTRA;
    if (strcmp(name, "forward") == 0) return BTN_FORWARD;
    if (strcmp(name, "back") == 0) return BTN_BACK;
    return 0;
}

int main(int argc, char *argv[]) {
    if ((argc != 6 && argc != 7)
            || (strcmp(argv[1], "move") != 0 && strcmp(argv[1], "click") != 0
                && strcmp(argv[1], "scroll") != 0)) {
        fprintf(stderr, "Usage: %s <move|click|scroll> <x> <y> <x_extent> "
                "<y_extent> [left|middle|right|side|extra|up|down]\n", argv[0]);
        return 1;
    }
    int click = strcmp(argv[1], "click") == 0;
    int scroll = strcmp(argv[1], "scroll") == 0;
    uint32_t btn = BTN_LEFT;
    int32_t scroll_dir = 1; /* wl_pointer convention: positive = down */
    if (argc == 7) {
        if (scroll) {
            if (strcmp(argv[6], "up") == 0) {
                scroll_dir = -1;
            } else if (strcmp(argv[6], "down") != 0) {
                fprintf(stderr, "Unknown direction: %s (expected up or down)\n",
                        argv[6]);
                return 1;
            }
        } else {
            btn = button_code(argv[6]);
            if (!btn) {
                fprintf(stderr, "Unknown button: %s (expected left, middle, "
                        "right, side or extra)\n", argv[6]);
                return 1;
            }
        }
    }
    uint32_t x = (uint32_t)strtoul(argv[2], NULL, 10);
    uint32_t y = (uint32_t)strtoul(argv[3], NULL, 10);
    uint32_t x_extent = (uint32_t)strtoul(argv[4], NULL, 10);
    uint32_t y_extent = (uint32_t)strtoul(argv[5], NULL, 10);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (!g_seat || !g_manager) {
        fprintf(stderr, "Missing wl_seat or zwlr_virtual_pointer_manager_v1\n");
        return 1;
    }

    struct zwlr_virtual_pointer_v1 *pointer =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer(g_manager, g_seat);

    /* Workaround, sent twice: motionnotify hit-tests at the pre-move cursor
     * position, so pointer focus catches up one event late. Drop the second
     * send once hit-testing follows the move (input.c motionnotify). */
    for (int i = 0; i < 2; i++) {
        zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), x, y,
                                                x_extent, y_extent);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
        sleep_ms(30);
    }

    if (click) {
        sleep_ms(50);
        zwlr_virtual_pointer_v1_button(pointer, now_ms(), btn,
                                       WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
        sleep_ms(50);
        zwlr_virtual_pointer_v1_button(pointer, now_ms(), btn,
                                       WL_POINTER_BUTTON_STATE_RELEASED);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
    } else if (scroll) {
        sleep_ms(50);
        /* One discrete wheel click; wlroots scales discrete to value120 */
        zwlr_virtual_pointer_v1_axis_discrete(pointer, now_ms(),
                WL_POINTER_AXIS_VERTICAL_SCROLL,
                wl_fixed_from_int(scroll_dir * 15), scroll_dir);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
    }

    zwlr_virtual_pointer_v1_destroy(pointer);
    zwlr_virtual_pointer_manager_v1_destroy(g_manager);
    wl_seat_destroy(g_seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}
