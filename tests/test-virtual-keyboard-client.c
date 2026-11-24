/**
 * test-virtual-keyboard-client - Press one key combo via zwp_virtual_keyboard_v1.
 *
 * Unlike root.fake_input("key_press"), which notifies the seat directly, the
 * events arrive through a real wlr_keyboard, so they traverse keypress() and
 * keybinding(): keygrabbers, shortcut inhibitors and the Lua key bindings.
 *
 * Usage: test-virtual-keyboard-client <Mod4|Mod1|Control|Shift> <keysym>
 *
 * Sends the default xkbcommon keymap, then modifier down, modifiers, key down,
 * key up, modifier up and cleared modifiers. Exits after a roundtrip.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *g_seat;
static struct zwp_virtual_keyboard_manager_v1 *g_manager;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void registry_global(void *data, struct wl_registry *reg,
        uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(interface, wl_seat_interface.name) == 0) {
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        g_manager = wl_registry_bind(reg, name,
            &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

struct key_search {
    xkb_keysym_t sym;
    xkb_keycode_t code;
};

static void find_key(struct xkb_keymap *keymap, xkb_keycode_t code, void *data) {
    struct key_search *search = data;
    const xkb_keysym_t *syms;
    if (!search->code
            && xkb_keymap_key_get_syms_by_level(keymap, code, 0, 0, &syms) > 0
            && syms[0] == search->sym)
        search->code = code;
}

/* Returns the evdev code of the first key whose base level is sym, or -1. */
static int evdev_code(struct xkb_keymap *keymap, const char *name) {
    struct key_search search = {
        .sym = xkb_keysym_from_name(name, XKB_KEYSYM_NO_FLAGS),
    };
    if (search.sym == XKB_KEY_NoSymbol) return -1;
    xkb_keymap_key_for_each(keymap, find_key, &search);
    return search.code ? (int)search.code - 8 : -1;
}

static void send_key(struct zwp_virtual_keyboard_v1 *kb, int code, uint32_t state) {
    zwp_virtual_keyboard_v1_key(kb, now_ms(), (uint32_t)code, state);
}

int main(int argc, char *argv[]) {
    static const char *const modifier_syms[][2] = {
        { "Mod4", "Super_L" }, { "Mod1", "Alt_L" },
        { "Control", "Control_L" }, { "Shift", "Shift_L" },
    };
    const char *modifier_sym = NULL;
    if (argc == 3) {
        for (size_t i = 0; i < sizeof(modifier_syms) / sizeof(*modifier_syms); i++)
            if (strcmp(argv[1], modifier_syms[i][0]) == 0)
                modifier_sym = modifier_syms[i][1];
    }
    if (!modifier_sym) {
        fprintf(stderr, "Usage: %s <Mod4|Mod1|Control|Shift> <keysym>\n", argv[0]);
        return 1;
    }

    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *keymap = context
        ? xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS)
        : NULL;
    if (!keymap) {
        fprintf(stderr, "Failed to compile the default keymap\n");
        return 1;
    }
    int mod_code = evdev_code(keymap, modifier_sym);
    int key_code = evdev_code(keymap, argv[2]);
    xkb_mod_index_t mod_index = xkb_keymap_mod_get_index(keymap, argv[1]);
    if (mod_code < 0 || key_code < 0 || mod_index == XKB_MOD_INVALID) {
        fprintf(stderr, "No key for %s+%s in the default keymap\n", argv[1], argv[2]);
        return 1;
    }

    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("test-virtual-keyboard-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, text, size) != (ssize_t)size) {
        perror("keymap memfd");
        return 1;
    }
    free(text);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (!g_seat || !g_manager) {
        fprintf(stderr, "Missing wl_seat or zwp_virtual_keyboard_manager_v1\n");
        return 1;
    }

    struct zwp_virtual_keyboard_v1 *kb =
        zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(g_manager, g_seat);
    zwp_virtual_keyboard_v1_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd);

    send_key(kb, mod_code, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_modifiers(kb, 1u << mod_index, 0, 0, 0);
    send_key(kb, key_code, WL_KEYBOARD_KEY_STATE_PRESSED);
    send_key(kb, key_code, WL_KEYBOARD_KEY_STATE_RELEASED);
    send_key(kb, mod_code, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(kb, 0, 0, 0, 0);

    int failed = wl_display_roundtrip(display) < 0;
    if (failed)
        fprintf(stderr, "Compositor rejected the virtual keyboard events\n");

    zwp_virtual_keyboard_v1_destroy(kb);
    zwp_virtual_keyboard_manager_v1_destroy(g_manager);
    wl_seat_destroy(g_seat);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return failed;
}
