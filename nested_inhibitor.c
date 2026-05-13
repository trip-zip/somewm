#define _GNU_SOURCE

#include "nested_inhibitor.h"
#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>
#include <wlr/backend.h>
#include <wlr/backend/multi.h>
#include <wlr/backend/wayland.h>
#include <wlr/types/wlr_output.h>

enum status {
	S_NOT_APPLICABLE,
	S_UNAVAILABLE,
	S_ACTIVE,
};

static struct {
	struct wl_display *outer_display;
	struct wl_event_queue *probe_queue;
	struct zwp_keyboard_shortcuts_inhibit_manager_v1 *manager;
	struct wl_seat *outer_seat;
	enum status status;
} state = { .status = S_NOT_APPLICABLE };

static void
registry_global(void *data, struct wl_registry *reg, uint32_t name,
                const char *interface, uint32_t version)
{
	(void)data;
	if (strcmp(interface, zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name) == 0) {
		state.manager = wl_registry_bind(reg, name,
			&zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0 && !state.outer_seat) {
		uint32_t v = version > 4 ? 4 : version;
		state.outer_seat = wl_registry_bind(reg, name, &wl_seat_interface, v);
	}
}

static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static void
find_wl_backend(struct wlr_backend *backend, void *data)
{
	struct wlr_backend **out = data;
	if (*out)
		return;
	if (wlr_backend_is_wl(backend))
		*out = backend;
}

static void
write_status_file(void)
{
	const char *dir = getenv("SOMEWM_TEST_STATE_DIR");
	if (!dir || !*dir)
		return;
	char path[4096];
	int n = snprintf(path, sizeof(path), "%s/keybinds_status", dir);
	if (n <= 0 || (size_t)n >= sizeof(path))
		return;
	FILE *f = fopen(path, "w");
	if (!f)
		return;
	fprintf(f, "%s\n", nested_inhibitor_status());
	fclose(f);
}

/* Tell the test_marker Lua module to swap Mod4 -> Mod1. nested_inhibitor
 * is the only place that knows both the user's --keybinds mode and the
 * negotiated inhibitor result, so it's responsible for deciding. */
static void
arm_lua_remap(void)
{
	setenv("SOMEWM_TEST_KEYBINDS_REMAP", "1", 1);
}

void
nested_inhibitor_init(struct wlr_backend *backend)
{
	const char *mode = getenv("SOMEWM_TEST_KEYBINDS_MODE");
	if (mode && !strcmp(mode, "none")) {
		state.status = S_NOT_APPLICABLE;
		write_status_file();
		return;
	}
	if (mode && !strcmp(mode, "remap")) {
		state.status = S_NOT_APPLICABLE;
		arm_lua_remap();
		write_status_file();
		return;
	}

	struct wlr_backend *wl_backend = NULL;
	if (wlr_backend_is_wl(backend)) {
		wl_backend = backend;
	} else if (wlr_backend_is_multi(backend)) {
		wlr_multi_for_each_backend(backend, find_wl_backend, &wl_backend);
	}
	if (!wl_backend) {
		state.status = S_NOT_APPLICABLE;
		write_status_file();
		return;
	}

	struct wl_display *outer = wlr_wl_backend_get_remote_display(wl_backend);
	if (!outer) {
		state.status = S_NOT_APPLICABLE;
		write_status_file();
		return;
	}
	state.outer_display = outer;
	state.probe_queue = wl_display_create_queue(outer);

	struct wl_registry *reg = wl_display_get_registry(outer);
	wl_proxy_set_queue((struct wl_proxy *)reg, state.probe_queue);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip_queue(outer, state.probe_queue);
	wl_registry_destroy(reg);

	if (state.manager && state.outer_seat) {
		state.status = S_ACTIVE;
		fprintf(stderr,
		        "[nested-inhibitor] outer compositor advertised "
		        "zwp_keyboard_shortcuts_inhibit_manager_v1; Mod4 combos "
		        "will pass through to this nested somewm\n");
	} else {
		state.status = S_UNAVAILABLE;
		fprintf(stderr,
		        "[nested-inhibitor] outer compositor did not advertise "
		        "the shortcut inhibitor protocol; host will intercept Mod4 combos\n");
		/* mode == NULL (treated as auto) or "auto" remaps as a fallback.
		 * mode == "inhibit" was a hard request, so we honor it by not
		 * arming the Lua remap; the user gets the shortcut grab. */
		if (!mode || !strcmp(mode, "auto"))
			arm_lua_remap();
	}

	write_status_file();
}

void
nested_inhibitor_attach_output(struct wlr_output *output)
{
	if (state.status != S_ACTIVE)
		return;
	if (!wlr_output_is_wl(output))
		return;
	struct wl_surface *surface = wlr_wl_output_get_surface(output);
	if (!surface)
		return;
	zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(
		state.manager, surface, state.outer_seat);
}

const char *
nested_inhibitor_status(void)
{
	switch (state.status) {
	case S_ACTIVE:      return "active";
	case S_UNAVAILABLE: return "unavailable";
	default:            return "not-applicable";
	}
}
