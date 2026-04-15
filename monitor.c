/* monitor.c - Monitor/output management for somewm compositor */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_output_power_management_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/util/log.h>

#include "somewm.h"
#include "somewm_api.h"
#include "monitor.h"
#include "protocols.h"
#include "globalconf.h"
#include "client.h"
#include "common/luaobject.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/screen.h"
#include "objects/output.h"
#include "objects/layer_surface.h"
#include "objects/signal.h"
#include "banning.h"
#include "animation.h"

/* macros */

#include "focus.h"
#include "window.h"
#include "somewm_internal.h"
#include "bench.h"

/* Module-private state */
static int in_updatemons;
static int updatemons_pending;

/* forward declarations */
void cleanupmon(struct wl_listener *listener, void *data);
void closemon(Monitor *m);
void createmon(struct wl_listener *listener, void *data);
void gpureset(struct wl_listener *listener, void *data);
void outputmgrapply(struct wl_listener *listener, void *data);
void outputmgrapplyortest(struct wlr_output_configuration_v1 *config, int test);
void outputmgrtest(struct wl_listener *listener, void *data);
void powermgrsetmode(struct wl_listener *listener, void *data);
void rendermon(struct wl_listener *listener, void *data);
void requestmonstate(struct wl_listener *listener, void *data);
void updatemons(struct wl_listener *listener, void *data);

/* listener structs */
struct wl_listener gpu_reset = {.notify = gpureset};
struct wl_listener layout_change = {.notify = updatemons};
struct wl_listener new_output = {.notify = createmon};
struct wl_listener output_mgr_apply = {.notify = outputmgrapply};
struct wl_listener output_mgr_test = {.notify = outputmgrtest};
struct wl_listener output_power_mgr_set_mode = {.notify = powermgrsetmode};

void
cleanupmon(struct wl_listener *listener, void *data)
{
	Monitor *m = wl_container_of(listener, m, destroy);
	LayerSurface *l, *tmp;
	size_t i;

	wlr_log(WLR_ERROR, "[HOTPLUG] cleanupmon: %s remaining_mons=%d",
		m->wlr_output->name, wl_list_length(&mons) - 1);

	/* Find and remove screen BEFORE destroying monitor data (AwesomeWM pattern)
	 * This emits instance-level "removed" signal and relocates clients.
	 * Also emit viewports and primary_changed signals as needed. */
	if (globalconf_L) {
		screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
		if (screen) {
			/* Check if this screen was the primary before removing it */
			screen_t *old_primary = luaA_screen_get_primary_screen(globalconf_L);
			bool was_primary = (old_primary == screen);

			screen_removed(globalconf_L, screen);
			luaA_screen_emit_viewports(globalconf_L);

			/* If removed screen was primary, emit primary_changed on new primary */
			if (was_primary) {
				screen_t *new_primary = luaA_screen_get_primary_screen(globalconf_L);
				if (new_primary && new_primary != screen) {
					luaA_screen_emit_primary_changed(globalconf_L, new_primary);
				}
			}

			/* Emit property::screen on output (screen→nil) */
			if (m->output) {
				luaA_object_push(globalconf_L, m->output);
				luaA_object_emit_signal(globalconf_L, -1, "property::screen", 0);
				lua_pop(globalconf_L, 1);
			}
		}
	}

	/* Invalidate output Lua object before destroying monitor data */
	if (globalconf_L && m->output) {
		luaA_object_push(globalconf_L, m->output);
		luaA_class_emit_signal(globalconf_L, &output_class, "removed", 1);
		luaA_output_invalidate(globalconf_L, m->output);
		m->output = NULL;
	}

	/* m->layers[i] are intentionally not unlinked */
	for (i = 0; i < LENGTH(m->layers); i++) {
		wl_list_for_each_safe(l, tmp, &m->layers[i], link)
			wlr_layer_surface_v1_destroy(l->layer_surface);
	}

	wl_list_remove(&m->destroy.link);
	wl_list_remove(&m->frame.link);
	wl_list_remove(&m->link);
	wl_list_remove(&m->request_state.link);
	if (m->lock_surface)
		destroylocksurface(&m->destroy_lock_surface, NULL);
	m->wlr_output->data = NULL;
	/* Block updatemons() during output cleanup. wlr_output_layout_remove
	 * emits layout::change which triggers updatemons(). If updatemons runs,
	 * it does arrange/focus work that can indirectly add commit listeners
	 * (e.g. presentation_time, gamma) to the output being destroyed, causing
	 * wlr_output_finish() assertion failure. */
	in_updatemons = 1;
	wlr_scene_output_destroy(m->scene_output);
	wlr_output_layout_remove(output_layout, m->wlr_output);
	in_updatemons = 0;

	closemon(m);
	wlr_scene_node_destroy(&m->fullscreen_bg->node);
	free(m);

	if (updatemons_pending) {
		updatemons_pending = 0;
		updatemons(NULL, NULL);
	}
}

void
closemon(Monitor *m)
{
	/* update selmon if needed and
	 * move closed monitor's clients to the focused one */
	Client *c;
	int nclients = 0;

	if (wl_list_empty(&mons)) {
		selmon = NULL;
	} else if (m == selmon) {
		/* Find next enabled monitor (properly iterate the list) */
		Monitor *iter;
		selmon = NULL;
		wl_list_for_each(iter, &mons, link) {
			if (iter != m && iter->wlr_output->enabled) {
				selmon = iter;
				break;
			}
		}
	}

	foreach(client, globalconf.clients) {
		c = *client;
		if (some_client_get_floating(c) && c->geometry.x > m->m.width)
			resize(c, (struct wlr_box){.x = c->geometry.x - m->w.width, .y = c->geometry.y,
					.width = c->geometry.width, .height = c->geometry.height}, 0);
		if (c->mon == m) {
			nclients++;
			setmon(c, selmon, 0);
		}
	}

	wlr_log(WLR_ERROR, "[HOTPLUG] closemon: %s selmon=%s nclients=%d",
		m->wlr_output->name,
		selmon ? selmon->wlr_output->name : "NULL",
		nclients);

	focus_restore(selmon);
	printstatus();
}

void
createmon(struct wl_listener *listener, void *data)
{
	/* This event is raised by the backend when a new output (aka a display or
	 * monitor) becomes available. */
	struct wlr_output *wlr_output = data;
	size_t i;
	struct wlr_output_state state;
	Monitor *m;

	if (!wlr_output_init_render(wlr_output, alloc, drw))
		return;

	wlr_log(WLR_ERROR, "[HOTPLUG] createmon: %s enabled=%d mons=%d",
		wlr_output->name, wlr_output->enabled, wl_list_length(&mons));

	m = wlr_output->data = ecalloc(1, sizeof(*m));
	m->wlr_output = wlr_output;

	for (i = 0; i < LENGTH(m->layers); i++)
		wl_list_init(&m->layers[i]);

	wlr_output_state_init(&state);
	/* Apply safe defaults for monitor configuration (AwesomeWM pattern).
	 * Scale, transform, and position can be overridden from Lua via screen properties.
	 * Position is auto-configured by wlr_output_layout_add_auto() below. */
	m->m.x = -1;  /* Auto-position */
	m->m.y = -1;  /* Auto-position */
	/* mfact/nmaster are per-tag properties, set in Lua */
	/* Layouts are set from Lua, not C */
	wlr_output_state_set_scale(&state, 1.0);  /* Default 1:1 scale */
	wlr_output_state_set_transform(&state, WL_OUTPUT_TRANSFORM_NORMAL);  /* No rotation */

	/* The mode is a tuple of (width, height, refresh rate), and each
	 * monitor supports only a specific set of modes. We just pick the
	 * monitor's preferred mode; a more sophisticated compositor would let
	 * the user configure it. */
	wlr_output_state_set_mode(&state, wlr_output_preferred_mode(wlr_output));

	/* Set up event listeners */
	LISTEN(&wlr_output->events.frame, &m->frame, rendermon);
	LISTEN(&wlr_output->events.destroy, &m->destroy, cleanupmon);
	LISTEN(&wlr_output->events.request_state, &m->request_state, requestmonstate);

	wlr_output_state_set_enabled(&state, 1);
	wlr_output_commit_state(wlr_output, &state);
	wlr_output_state_finish(&state);

	wl_list_insert(&mons, &m->link);
	printstatus();

	/* Create output Lua object (persists from connect to disconnect).
	 * Signal emission is deferred to updatemons() so that o.screen is
	 * available in "added" handlers — eliminates a timing footgun. */
	if (globalconf_L) {
		m->output = luaA_output_new(globalconf_L, m);
		if (m->output) {
			lua_pop(globalconf_L, 1);  /* Pop userdata (tracked in output.c) */
			m->needs_output_added = 1;
		}
	}

	/* The xdg-protocol specifies:
	 *
	 * If the fullscreened surface is not opaque, the compositor must make
	 * sure that other screen content not part of the same surface tree (made
	 * up of subsurfaces, popups or similarly coupled surfaces) are not
	 * visible below the fullscreened surface.
	 *
	 */
	/* updatemons() will resize and set correct position */
	m->fullscreen_bg = wlr_scene_rect_create(layers[LyrFS], 0, 0, globalconf.appearance.fullscreen_bg);
	wlr_scene_node_set_enabled(&m->fullscreen_bg->node, 0);

	/* Adds this to the output layout in the order it was configured.
	 *
	 * The output layout utility automatically adds a wl_output global to the
	 * display, which Wayland clients can see to find out information about the
	 * output (such as DPI, scale factor, manufacturer, etc).
	 */
	m->scene_output = wlr_scene_output_create(scene, wlr_output);

	/* Create screen object BEFORE adding to layout.
	 * wlr_output_layout_add_auto() triggers updatemons() SYNCHRONOUSLY
	 * via layout::change signal. needs_screen_added must be set before
	 * that, so updatemons() can emit screen_added with correct geometry. */
	if (globalconf_L) {
		Monitor *tmp;
		int screen_index;
		screen_t *screen;

		screen_index = 1;

		/* Calculate screen index by counting existing monitors */
		wl_list_for_each(tmp, &mons, link) {
			if (tmp != m)
				screen_index++;
		}

		/* Create screen object (leaves it on Lua stack) */
		screen = luaA_screen_new(globalconf_L, m, screen_index);
		if (screen) {
			/* Pop the screen userdata from stack (it's tracked in screen.c globals) */
			lua_pop(globalconf_L, 1);

			/* If startup is complete, this is a hotplugged monitor.
			 * Set flag so updatemons() emits screen_added AFTER geometry
			 * is set but BEFORE orphaned clients are assigned.
			 * This ensures Lua tags/wibar exist when clients arrive. */
			if (luaA_screen_scanned_done()) {
				m->needs_screen_added = 1;
			}
		}
	}

	/* Add to output layout — triggers updatemons() synchronously.
	 * updatemons() will: set geometry → emit screen_added → assign orphans */
	if (m->m.x == -1 && m->m.y == -1)
		wlr_output_layout_add_auto(output_layout, wlr_output);
	else
		wlr_output_layout_add(output_layout, wlr_output, m->m.x, m->m.y);
}

Monitor *
dirtomon(enum wlr_direction dir)
{
	struct wlr_output *next;
	if (!wlr_output_layout_get(output_layout, selmon->wlr_output))
		return selmon;
	if ((next = wlr_output_layout_adjacent_output(output_layout,
			dir, selmon->wlr_output, selmon->m.x, selmon->m.y)))
		return next->data;
	if ((next = wlr_output_layout_farthest_output(output_layout,
			dir ^ (WLR_DIRECTION_LEFT|WLR_DIRECTION_RIGHT),
			selmon->wlr_output, selmon->m.x, selmon->m.y)))
		return next->data;
	return selmon;
}

void
focusmon(const Arg *arg)
{
	int i = 0, nmons = wl_list_length(&mons);
	if (nmons) {
		do /* don't switch to disabled mons */
			selmon = dirtomon(arg->i);
		while (!selmon->wlr_output->enabled && i++ < nmons);
	}
	focus_restore(selmon);
}

void
gpureset(struct wl_listener *listener, void *data)
{
	struct wlr_renderer *old_drw = drw;
	struct wlr_allocator *old_alloc = alloc;
	struct Monitor *m;
	if (!(drw = wlr_renderer_autocreate(backend)))
		die("couldn't recreate renderer");

	if (!(alloc = wlr_allocator_autocreate(backend, drw)))
		die("couldn't recreate allocator");

	wl_list_remove(&gpu_reset.link);
	wl_signal_add(&drw->events.lost, &gpu_reset);

	wlr_compositor_set_renderer(compositor, drw);

	wl_list_for_each(m, &mons, link) {
		wlr_output_init_render(m->wlr_output, alloc, drw);
	}

	wlr_allocator_destroy(old_alloc);
	wlr_renderer_destroy(old_drw);
}

void
outputmgrapply(struct wl_listener *listener, void *data)
{
	struct wlr_output_configuration_v1 *config = data;
	outputmgrapplyortest(config, 0);
}

void
outputmgrapplyortest(struct wlr_output_configuration_v1 *config, int test)
{
	/*
	 * Called when a client such as wlr-randr requests a change in output
	 * configuration. This is only one way that the layout can be changed,
	 * so any Monitor information should be updated by updatemons() after an
	 * output_layout.change event, not here.
	 */
	struct wlr_output_configuration_head_v1 *config_head;
	int ok = 1;

	wl_list_for_each(config_head, &config->heads, link) {
		struct wlr_output *wlr_output = config_head->state.output;
		Monitor *m = wlr_output->data;
		struct wlr_output_state state;

		/* Ensure displays previously disabled by wlr-output-power-management-v1
		 * are properly handled*/
		m->asleep = 0;

		wlr_output_state_init(&state);
		wlr_output_state_set_enabled(&state, config_head->state.enabled);
		if (!config_head->state.enabled)
			goto apply_or_test;

		if (config_head->state.mode)
			wlr_output_state_set_mode(&state, config_head->state.mode);
		else
			wlr_output_state_set_custom_mode(&state,
					config_head->state.custom_mode.width,
					config_head->state.custom_mode.height,
					config_head->state.custom_mode.refresh);

		wlr_output_state_set_transform(&state, config_head->state.transform);
		wlr_output_state_set_scale(&state, config_head->state.scale);
		wlr_output_state_set_adaptive_sync_enabled(&state,
				config_head->state.adaptive_sync_enabled);

apply_or_test:
		ok &= test ? wlr_output_test_state(wlr_output, &state)
				: wlr_output_commit_state(wlr_output, &state);

		/* Don't move monitors if position wouldn't change. This avoids
		 * wlroots marking the output as manually configured.
		 * wlr_output_layout_add does not like disabled outputs */
		if (!test && wlr_output->enabled && (m->m.x != config_head->state.x || m->m.y != config_head->state.y))
			wlr_output_layout_add(output_layout, wlr_output,
					config_head->state.x, config_head->state.y);

		wlr_output_state_finish(&state);
	}

	if (ok)
		wlr_output_configuration_v1_send_succeeded(config);
	else
		wlr_output_configuration_v1_send_failed(config);
	wlr_output_configuration_v1_destroy(config);

	/* Force monitor refresh after output config change */
	updatemons(NULL, NULL);
}

void
outputmgrtest(struct wl_listener *listener, void *data)
{
	struct wlr_output_configuration_v1 *config = data;
	outputmgrapplyortest(config, 1);
}

void
powermgrsetmode(struct wl_listener *listener, void *data)
{
	struct wlr_output_power_v1_set_mode_event *event = data;
	struct wlr_output_state state;
	Monitor *m = event->output->data;

	if (!m)
		return;

	wlr_output_state_init(&state);
	m->gamma_lut_changed = 1; /* Reapply gamma LUT when re-enabling the ouput */
	wlr_output_state_set_enabled(&state, event->mode);
	wlr_output_commit_state(m->wlr_output, &state);
	wlr_output_state_finish(&state);

	m->asleep = !event->mode;
	wlr_log(WLR_ERROR, "[HOTPLUG] powermgrsetmode: %s mode=%d asleep=%d",
		m->wlr_output->name, event->mode, m->asleep);
	updatemons(NULL, NULL);
}

void
rendermon(struct wl_listener *listener, void *data)
{
	/* This function is called every time an output is ready to display a frame,
	 * generally at the output's refresh rate (e.g. 60Hz). */
	Monitor *m = wl_container_of(listener, m, frame);
	Client *c;
	struct timespec now;

	/* Safety: scene_output may not exist yet if frame fires before createmon
	 * finishes (possible on NVIDIA), or output may be disabled */
	if (!m->scene_output)
		return;
	if (!m->wlr_output->enabled)
		goto skip;

	/* Render if no XDG clients have an outstanding resize and are visible on
	 * this monitor. */
	foreach(client, globalconf.clients) {
		c = *client;
		if (c->resize && !some_client_get_floating(c) && c->mon == m && !client_is_stopped(c))
			goto skip;
	}

#ifdef SOMEWM_BENCH
	struct timespec bench_render_start, bench_render_end;
	clock_gettime(CLOCK_MONOTONIC, &bench_render_start);
#endif
	if (!wlr_scene_output_commit(m->scene_output, NULL))
		wlr_log(WLR_DEBUG, "[HOTPLUG] rendermon commit failed: %s",
			m->wlr_output->name);
#ifdef SOMEWM_BENCH
	else {
		clock_gettime(CLOCK_MONOTONIC, &bench_render_end);
		bench_render_record(timespec_diff_ns(&bench_render_start, &bench_render_end));
		bench_input_commit_flush();
	}
#endif

skip:
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(m->scene_output, &now);
}

void
requestmonstate(struct wl_listener *listener, void *data)
{
	struct wlr_output_event_request_state *event = data;
	uint32_t committed = event->state->committed;

	wlr_log(WLR_ERROR, "[HOTPLUG] requestmonstate: %s", event->output->name);
	if (!wlr_output_commit_state(event->output, event->state)) {
		wlr_log(WLR_ERROR, "[HOTPLUG] requestmonstate commit FAILED: %s",
			event->output->name);
		updatemons(NULL, NULL);
		return;
	}

	/* Emit property::* signals on the output object so Lua stays in sync
	 * when external tools (wlr-randr, kanshi) change output state. */
	if (globalconf_L) {
		Monitor *m = event->output->data;
		if (m && m->output) {
			luaA_object_push(globalconf_L, m->output);
			if (committed & WLR_OUTPUT_STATE_ENABLED)
				luaA_object_emit_signal(globalconf_L, -1, "property::enabled", 0);
			if (committed & WLR_OUTPUT_STATE_SCALE) {
				luaA_object_emit_signal(globalconf_L, -1, "property::scale", 0);
				/* Also emit on screen for backward compat */
				screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
				if (screen) {
					luaA_object_push(globalconf_L, screen);
					luaA_object_emit_signal(globalconf_L, -1, "property::scale", 0);
					lua_pop(globalconf_L, 1);
				}
			}
			if (committed & WLR_OUTPUT_STATE_TRANSFORM)
				luaA_object_emit_signal(globalconf_L, -1, "property::transform", 0);
			if (committed & WLR_OUTPUT_STATE_MODE)
				luaA_object_emit_signal(globalconf_L, -1, "property::mode", 0);
			if (committed & WLR_OUTPUT_STATE_ADAPTIVE_SYNC_ENABLED)
				luaA_object_emit_signal(globalconf_L, -1, "property::adaptive_sync", 0);
			lua_pop(globalconf_L, 1);
		}
	}

	updatemons(NULL, NULL);
}

void
updatemons(struct wl_listener *listener, void *data)
{
	/*
	 * Called whenever the output layout changes: adding or removing a
	 * monitor, changing an output's mode or position, etc. This is where
	 * the change officially happens and we update geometry, window
	 * positions, focus, and the stored configuration in wlroots'
	 * output-manager implementation.
	 */
	/* Guard against re-entrancy: wlr_output_layout_remove/add_auto below
	 * emit layout::change which would call us again, causing
	 * use-after-free in wlroots output_layout_add().
	 * Also used by cleanupmon() to prevent updatemons during output destruction. */
	if (in_updatemons) {
		updatemons_pending = 1;
		return;
	}
	in_updatemons = 1;

	struct wlr_output_configuration_v1 *config
			= wlr_output_configuration_v1_create();
	Client *c;
	struct wlr_output_configuration_head_v1 *config_head;
	Monitor *m;

	/* Add disabled monitors to the config. For those still in the layout
	 * (transitioning to disabled), properly remove the screen and close.
	 * Already-disabled monitors just get a config_head so output manager
	 * clients (wlr-randr, wlopm, kanshi) can still see and re-enable
	 * them. Fixes #269. */
	wl_list_for_each(m, &mons, link) {
		if (m->wlr_output->enabled || m->asleep)
			continue;
		config_head = wlr_output_configuration_head_v1_create(config, m->wlr_output);
		config_head->state.enabled = 0;
		if (wlr_output_layout_get(output_layout, m->wlr_output)) {
			wlr_log(WLR_ERROR, "[HOTPLUG] updatemons disable: %s",
				m->wlr_output->name);

			/* Properly remove the screen object so Lua tears down
			 * tags/wibars. On re-enable, a fresh screen is created
			 * and screen_added triggers request::desktop_decoration. */
			if (globalconf_L) {
				screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
				if (screen) {
					screen_t *old_primary = luaA_screen_get_primary_screen(globalconf_L);
					bool was_primary = (old_primary == screen);

					screen_removed(globalconf_L, screen);
					luaA_screen_emit_viewports(globalconf_L);

					if (was_primary) {
						screen_t *new_primary = luaA_screen_get_primary_screen(globalconf_L);
						if (new_primary && new_primary != screen)
							luaA_screen_emit_primary_changed(globalconf_L, new_primary);
					}
				}

				/* Emit property::screen on output (screen→nil) */
				if (m->output) {
					luaA_object_push(globalconf_L, m->output);
					luaA_object_emit_signal(globalconf_L, -1, "property::screen", 0);
					lua_pop(globalconf_L, 1);
				}
			}

			/* Remove this output from the layout to avoid cursor enter inside it */
			wlr_output_layout_remove(output_layout, m->wlr_output);
			closemon(m);
			m->m = m->w = (struct wlr_box){0};
		}
	}
	/* Insert outputs that need to */
	wl_list_for_each(m, &mons, link) {
		if (m->wlr_output->enabled
				&& !wlr_output_layout_get(output_layout, m->wlr_output))
			wlr_output_layout_add_auto(output_layout, m->wlr_output);
	}

	/* Now that we update the output layout we can get its box */
	wlr_output_layout_get_box(output_layout, NULL, &sgeom);

	wlr_scene_node_set_position(&root_bg->node, sgeom.x, sgeom.y);
	wlr_scene_rect_set_size(root_bg, sgeom.width, sgeom.height);

	/* Make sure the clients are hidden when somewm is locked */
	wlr_scene_node_set_position(&locked_bg->node, sgeom.x, sgeom.y);
	wlr_scene_rect_set_size(locked_bg, sgeom.width, sgeom.height);

	wl_list_for_each(m, &mons, link) {
		if (!m->wlr_output->enabled)
			continue;
		config_head = wlr_output_configuration_head_v1_create(config, m->wlr_output);

		/* Get the effective monitor geometry to use for surfaces */
		wlr_output_layout_get_box(output_layout, m->wlr_output, &m->m);
		m->w = m->m;
		wlr_scene_output_set_position(m->scene_output, m->m.x, m->m.y);

		wlr_scene_node_set_position(&m->fullscreen_bg->node, m->m.x, m->m.y);
		wlr_scene_rect_set_size(m->fullscreen_bg, m->m.width, m->m.height);

		if (m->lock_surface) {
			struct wlr_scene_tree *scene_tree = client_surface_get_scene_tree(m->lock_surface->surface);
			wlr_scene_node_set_position(&scene_tree->node, m->m.x, m->m.y);
			wlr_session_lock_surface_v1_configure(m->lock_surface, m->m.width, m->m.height);
		}

		/* Calculate the effective monitor geometry to use for clients */
		arrangelayers(m);
		/* Update screen object geometry and emit property:: signals if changed */
		{
			screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
			if (!screen && globalconf_L) {
				/* Re-enabled monitor has no screen (removed during disable).
				 * Create a fresh one — treated like a hotplug. */
				Monitor *tmp;
				int screen_index = 1;
				wl_list_for_each(tmp, &mons, link) {
					if (tmp != m && luaA_screen_get_by_monitor(globalconf_L, tmp))
						screen_index++;
				}
				screen = luaA_screen_new(globalconf_L, m, screen_index);
				if (screen) {
					lua_pop(globalconf_L, 1);
					m->needs_screen_added = 1;
				}
			}
			if (screen) {
				if (m->needs_screen_added) {
					/* New screen: cache geometry silently.
					 * Don't emit property::geometry before _added —
					 * Lua handlers (naughty) expect init_screen() to
					 * have run first. screen_added() fires in the
					 * add loop below and sets workarea = geometry. */
					some_monitor_get_geometry(m, &screen->geometry);
					screen->workarea = screen->geometry;
				} else {
					luaA_screen_update_geometry(globalconf_L, screen);
				}
			}
		}
		/* Don't move clients to the left output when plugging monitors */
		arrange(m);
		/* make sure fullscreen clients have the right size */
		if ((c = focustop(m)) && c->fullscreen)
			resize(c, m->m, 0);

		/* Try to re-set the gamma LUT when updating monitors,
		 * it's only really needed when enabling a disabled output, but meh. */
		m->gamma_lut_changed = 1;

		config_head->state.x = m->m.x;
		config_head->state.y = m->m.y;

		wlr_log(WLR_ERROR, "[HOTPLUG] updatemons geom: %s %d,%d %dx%d",
			m->wlr_output->name, m->m.x, m->m.y, m->m.width, m->m.height);

		if (!selmon) {
			selmon = m;
		}
	}

	/* Emit screen_added for newly hotplugged monitors.
	 * Done AFTER geometry loop (m->m is set), BEFORE orphaned clients
	 * are assigned, so Lua tags and wibar exist when clients arrive.
	 * Separate loop from geometry to avoid reentrancy issues —
	 * screen_added triggers Lua callbacks that may cause layout changes.
	 * in_updatemons=1 prevents recursive updatemons calls. */
	wl_list_for_each(m, &mons, link) {
		if (!m->needs_screen_added || !m->wlr_output->enabled)
			continue;
		m->needs_screen_added = 0;

		screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
		if (screen && screen->valid) {
			wlr_log(WLR_ERROR, "[HOTPLUG] updatemons screen_added: %s",
				m->wlr_output->name);

			screen_t *old_primary = luaA_screen_get_primary_screen(globalconf_L);
			screen_added(globalconf_L, screen);
			luaA_screen_emit_list(globalconf_L);
			luaA_screen_emit_viewports(globalconf_L);

			screen_t *new_primary = luaA_screen_get_primary_screen(globalconf_L);
			if (new_primary == screen && old_primary != screen)
				luaA_screen_emit_primary_changed(globalconf_L, screen);

			/* Emit property::screen on the output (nil→screen) */
			if (m->output) {
				luaA_object_push(globalconf_L, m->output);
				luaA_object_emit_signal(globalconf_L, -1, "property::screen", 0);
				lua_pop(globalconf_L, 1);
			}

			banning_refresh();
			some_refresh();
		}
	}

	/* Emit deferred output "added" signals. Done AFTER screen_added so that
	 * o.screen is available in "added" handlers. */
	wl_list_for_each(m, &mons, link) {
		if (!m->needs_output_added)
			continue;
		m->needs_output_added = 0;
		if (m->output && globalconf_L) {
			luaA_object_push(globalconf_L, m->output);
			luaA_class_emit_signal(globalconf_L, &output_class, "added", 1);
		}
	}

	if (selmon && selmon->wlr_output->enabled) {
		struct wlr_surface *surf;
		foreach(client, globalconf.clients) {
			c = *client;
			if (!c->mon && (surf = client_surface(c)) && surf->mapped) {
				wlr_log(WLR_ERROR, "[HOTPLUG] updatemons orphan: %s → %s",
					client_get_title(c) ? client_get_title(c) : "?",
					selmon->wlr_output->name);
				setmon(c, selmon, 0);
			}
		}
		focus_restore(selmon);
		if (selmon->lock_surface) {
			client_notify_enter(selmon->lock_surface->surface,
					wlr_seat_get_keyboard(seat));
			client_activate_surface(selmon->lock_surface->surface, 1);
		}
	}

	wlr_log(WLR_ERROR, "[HOTPLUG] updatemons exit selmon=%s",
		selmon ? selmon->wlr_output->name : "NULL");

	/* FIXME: figure out why the cursor image is at 0,0 after turning all
	 * the monitors on.
	 * Move the cursor image where it used to be. It does not generate a
	 * wl_pointer.motion event for the clients, it's only the image what it's
	 * at the wrong position after all. */
	wlr_cursor_move(cursor, NULL, 0, 0);

	in_updatemons = 0;
	wlr_output_manager_v1_set_configuration(output_mgr, config);
	in_updatemons = 0;

	if (updatemons_pending) {
		updatemons_pending = 0;
		updatemons(NULL, NULL);
	}
}

Monitor *
xytomon(double x, double y)
{
	struct wlr_output *o = wlr_output_layout_output_at(output_layout, x, y);
	return o ? o->data : NULL;
}
