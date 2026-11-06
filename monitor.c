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
#include <EGL/egl.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/swapchain.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_gamma_control_v1.h>
#include <wlr/util/transform.h>
#include "paint.h"
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/util/log.h>

#include "somewm.h"
#include "somewm_api.h"
#include "declare.h"
#include "input.h"
#include "monitor.h"
#include "nested_inhibitor.h"
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

/* macros */

#include "focus.h"
#include "window.h"
#include "somewm_internal.h"
#include "event_queue.h"
#include "bench.h"

/* Module-private state */
static void output_needs_frame(struct wl_listener *, void *);
static void output_committed(struct wl_listener *, void *);
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
	wl_list_remove(&m->needs_frame.link);
	wl_list_remove(&m->output_commit.link);
	if (m->lock_surface)
		destroylocksurface(&m->destroy_lock_surface, NULL);
	m->wlr_output->data = NULL;
	/* Block updatemons() during output cleanup. wlr_output_layout_remove
	 * emits layout::change which triggers updatemons(). If updatemons runs,
	 * it does arrange/focus work that can indirectly add commit listeners
	 * (e.g. presentation_time, gamma) to the output being destroyed, causing
	 * wlr_output_finish() assertion failure. */
	in_updatemons = 1;
	window_surface_sweep(m, true);
	wlr_damage_ring_finish(&m->damage);
	wlr_output_layout_remove(output_layout, m->wlr_output);
	in_updatemons = 0;

	closemon(m);
	monitor_make_current();
	declare_output_destroy(m->declare);
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

	if (wlr_output->data) {
		wlr_log(WLR_ERROR, "[HOTPLUG] createmon duplicate ignored: %s already has monitor data",
			wlr_output->name);
		return;
	}

	if (wlr_output_layout_get(output_layout, wlr_output)) {
		wlr_log(WLR_ERROR, "[HOTPLUG] createmon duplicate ignored: %s already in layout",
			wlr_output->name);
		return;
	}

	if (!wlr_output_init_render(wlr_output, alloc, drw))
		return;

	/* Inhibit host shortcuts for this output when nested. */
	nested_inhibitor_attach_output(wlr_output);

	wlr_log(WLR_ERROR, "[HOTPLUG] createmon: %s enabled=%d mons=%d",
		wlr_output->name, wlr_output->enabled, wl_list_length(&mons));

	m = wlr_output->data = ecalloc(1, sizeof(*m));
	m->wlr_output = wlr_output;
	wlr_damage_ring_init(&m->damage);
	wlr_damage_ring_add_whole(&m->damage);

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
	LISTEN(&wlr_output->events.needs_frame, &m->needs_frame, output_needs_frame);
	LISTEN(&wlr_output->events.commit, &m->output_commit, output_committed);
	LISTEN(&wlr_output->events.frame, &m->frame, rendermon);
	LISTEN(&wlr_output->events.destroy, &m->destroy, cleanupmon);
	LISTEN(&wlr_output->events.request_state, &m->request_state, requestmonstate);

	wlr_output_state_set_enabled(&state, 1);
	if (!wlr_output_commit_state(wlr_output, &state)) {
		wlr_log(WLR_ERROR, "[HOTPLUG] createmon: %s commit FAILED, aborting",
			wlr_output->name);
		wlr_output_state_finish(&state);
		wl_list_remove(&m->frame.link);
		wl_list_remove(&m->destroy.link);
		wl_list_remove(&m->request_state.link);
	wl_list_remove(&m->needs_frame.link);
	wl_list_remove(&m->output_commit.link);
		wlr_output->data = NULL;
		wlr_damage_ring_finish(&m->damage);
		free(m);
		return;
	}
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

	/* Adds this to the output layout in the order it was configured.
	 *
	 * The output layout utility automatically adds a wl_output global to the
	 * display, which Wayland clients can see to find out information about the
	 * output (such as DPI, scale factor, manufacturer, etc).
	 */
	m->declare = declare_output_create(wlr_output);

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
    monitor_make_current();
    wl_list_for_each(m, &mons, link) declare_reset_paint(m->declare);
    paint_destroy(painter);
	if (!(drw = wlr_renderer_autocreate(backend)))
		die("couldn't recreate renderer");
    if (!wlr_renderer_is_gles2(drw)) die("somewm draws with GLES2; WLR_RENDERER=pixman is not supported");
    monitor_make_current();
    painter = paint_create();
    if (!painter) die("couldn't recreate paint renderer");
    paint_generation++;

	if (!(alloc = wlr_allocator_autocreate(backend, drw)))
		die("couldn't recreate allocator");

	wl_list_remove(&gpu_reset.link);
	wl_signal_add(&drw->events.lost, &gpu_reset);

	wlr_compositor_set_renderer(compositor, drw);

	wl_list_for_each(m, &mons, link) {
		wlr_output_init_render(m->wlr_output, alloc, drw);
		wlr_damage_ring_add_whole(&m->damage);
		wlr_output_schedule_frame(m->wlr_output);
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

		/* Orphan output: createmon bailed (commit or render init failed).
		 * Skip; there is no Monitor to reconfigure. */
		if (!m)
			continue;

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

static void sample_surfaces(Monitor *m)
{
    int width, height;
    wlr_output_transformed_resolution(m->wlr_output, &width, &height);
    struct render_draw_params params = {.scale = m->wlr_output->scale,
        .width = width, .height = height};
    m->sample_generation++;
    Monitor *band;
    wl_list_for_each(band, &mons, link) {
        if (!band->wlr_output->enabled) continue;
        params.origin_x = band->m.x - m->m.x;
        params.origin_y = band->m.y - m->m.y;
        declare_draw(band->declare, NULL, m, &params);
    }
    window_surface_sweep(m, false);
}

void monitor_update_surfaces(void)
{
    Monitor *m;
    wl_list_for_each(m, &mons, link)
        if (m->wlr_output->enabled) sample_surfaces(m);
    some_recompute_idle_inhibit();
}

void
rendermon(struct wl_listener *listener, void *data)
{
    Monitor *m = wl_container_of(listener, m, frame);
    struct wlr_output *o = m->wlr_output;
    struct timespec now;
    if (!m->declare || !o->enabled) return;
    foreach(client, globalconf.clients) {
        Client *c = *client;
        if (c->resize && !some_client_get_floating(c) && c->mon == m && !client_is_stopped(c))
            goto done;
    }
    monitor_make_current();
    if (declare_output_frame(m->declare, m) > 0) motionnotify(0, NULL, 0, 0, 0, 0);
    Monitor *band;
    wl_list_for_each(band, &mons, link) declare_damage(band->declare, band->m.x, band->m.y);
    int width, height;
    wlr_output_transformed_resolution(o, &width, &height);
    struct render_draw_params params = {.scale = o->scale, .width = width, .height = height};
    sample_surfaces(m);
    some_recompute_idle_inhibit();
    if (!pixman_region32_not_empty(&m->damage.current) && !m->gamma_lut_changed && !o->needs_frame) goto done;
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    struct wlr_buffer *buffer = NULL;
    pixman_region32_t damage;
    pixman_region32_init(&damage);
    if (!wlr_output_configure_primary_swapchain(o, &state, &o->swapchain)
            || !(buffer = wlr_swapchain_acquire(o->swapchain))) goto failed;
    monitor_make_current();
    unsigned int fbo = wlr_gles2_renderer_get_buffer_fbo(drw, buffer);
    wlr_damage_ring_rotate_buffer(&m->damage, buffer, &damage);
    int count;
    pixman_box32_t *rects = pixman_region32_rectangles(&damage, &count);
    struct paint_box *boxes = ecalloc(count ? count : 1, sizeof(*boxes));
    for (int i = 0; i < count; i++)
        boxes[i] = (struct paint_box){rects[i].x1, rects[i].y1,
            rects[i].x2 - rects[i].x1, rects[i].y2 - rects[i].y1};
    bool began = paint_begin(painter, fbo, buffer->width, buffer->height, o->transform, boxes, count);
    free(boxes);
    if (!began) goto failed;
    paint_clear(painter, (struct paint_color){0, 0, 0, 1});
    wl_list_for_each(band, &mons, link) {
        if (!band->wlr_output->enabled) continue;
        params.origin_x = band->m.x - m->m.x;
        params.origin_y = band->m.y - m->m.y;
        declare_draw(band->declare, painter, m, &params);
    }
    bool painted = paint_end(painter);
    wl_list_for_each(band, &mons, link) declare_finish(band->declare);
    if (!painted) goto failed;
    wlr_output_state_set_buffer(&state, buffer);
    wlr_output_state_set_damage(&state, &damage);
    if (m->gamma_lut_changed) {
        struct wlr_gamma_control_v1 *control = wlr_gamma_control_manager_v1_get_control(gamma_manager, o);
        if (!wlr_gamma_control_v1_apply(control, &state) && control)
            wlr_gamma_control_v1_send_failed_and_destroy(control);
    }
    if (!wlr_output_commit_state(o, &state)) goto failed;
    m->gamma_lut_changed = false;
    globalconf.frame_commit_count++;
    goto finish;
failed:
    wlr_damage_ring_add_whole(&m->damage);
finish:
    if (buffer) wlr_buffer_unlock(buffer);
    pixman_region32_fini(&damage);
    wlr_output_state_finish(&state);
done:
    clock_gettime(CLOCK_MONOTONIC, &now);
    window_surface_frame_done(m, &now);
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

	/* Queue property::* signals on the output object so Lua stays in sync
	 * when external tools (wlr-randr, kanshi) change output state. */
	if (globalconf_L) {
		Monitor *m = event->output->data;
		if (m && m->output) {
			luaA_object_push(globalconf_L, m->output);
			if (committed & WLR_OUTPUT_STATE_ENABLED)
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_ENABLED);
			if (committed & WLR_OUTPUT_STATE_SCALE) {
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_SCALE);
				/* Also emit on screen for backward compat */
				screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
				if (screen) {
					luaA_object_push(globalconf_L, screen);
					some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_SCALE);
					lua_pop(globalconf_L, 1);
				}
			}
			if (committed & WLR_OUTPUT_STATE_TRANSFORM)
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_TRANSFORM);
			if (committed & WLR_OUTPUT_STATE_MODE)
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_MODE);
			if (committed & WLR_OUTPUT_STATE_ADAPTIVE_SYNC_ENABLED)
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_ADAPTIVE_SYNC);
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
	 * them. */
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
			window_surface_sweep(m, true);
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

	wl_list_for_each(m, &mons, link) {
		if (!m->wlr_output->enabled)
			continue;
		config_head = wlr_output_configuration_head_v1_create(config, m->wlr_output);

		/* Get the effective monitor geometry to use for surfaces */
		wlr_output_layout_get_box(output_layout, m->wlr_output, &m->m);
		m->w = m->m;
		wlr_damage_ring_add_whole(&m->damage);
		declare_output_update(m->declare, m->m.x, m->m.y);

		if (m->lock_surface)
			wlr_session_lock_surface_v1_configure(m->lock_surface, m->m.width, m->m.height);

		layer_keyboard_focus(m);
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

			/* Queue property::screen on the output (nil→screen) */
			if (m->output) {
				luaA_object_push(globalconf_L, m->output);
				some_event_queue_signal0(globalconf_L, -1, SIG_PROPERTY_SCREEN);
				lua_pop(globalconf_L, 1);
			}

			some_refresh();
		}
	}

	/* Queue deferred output "added" signals. Done AFTER screen_added so that
	 * o.screen is available in "added" handlers. */
	wl_list_for_each(m, &mons, link) {
		if (!m->needs_output_added)
			continue;
		m->needs_output_added = 0;
		if (m->output && globalconf_L) {
			luaA_object_push(globalconf_L, m->output);
			some_event_queue_class_args(globalconf_L, &output_class,
					SIG_OUTPUT_ADDED, 1);
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

	/* Keep the pointer inside the new layout. It does not generate a
	 * wl_pointer.motion event for the clients. */
	wlr_cursor_move(cursor, NULL, 0, 0);
	declare_cursor_changed();

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

void monitor_make_current(void)
{
    struct wlr_egl *egl = wlr_gles2_renderer_get_egl(drw);
    if (!eglMakeCurrent(wlr_egl_get_display(egl), EGL_NO_SURFACE, EGL_NO_SURFACE,
                wlr_egl_get_context(egl))) die("couldn't bind paint context");
}

void monitor_damage_device(Monitor *m, struct render_box b)
{
    if (b.width <= 0 || b.height <= 0) return;
    struct wlr_output *o = m->wlr_output;
    int width, height;
    wlr_output_transformed_resolution(o, &width, &height);
    struct wlr_box box = {floorf(b.x), floorf(b.y),
        ceilf(b.x + b.width) - floorf(b.x), ceilf(b.y + b.height) - floorf(b.y)};
    struct wlr_box bounds = {0, 0, width, height};
    if (!wlr_box_intersection(&box, &box, &bounds)) return;
    wlr_box_transform(&box, &box, wlr_output_transform_invert(o->transform), width, height);
    wlr_damage_ring_add_box(&m->damage, &box);
    if (o->enabled) wlr_output_schedule_frame(o);
}

void monitor_damage_box(Monitor *m, struct render_box b)
{
    b.x = (b.x - m->m.x) * m->wlr_output->scale;
    b.y = (b.y - m->m.y) * m->wlr_output->scale;
    b.width *= m->wlr_output->scale;
    b.height *= m->wlr_output->scale;
    monitor_damage_device(m, b);
}

static void output_needs_frame(struct wl_listener *listener, void *data)
{
    Monitor *m = wl_container_of(listener, m, needs_frame);
    wlr_output_schedule_frame(m->wlr_output);
}

static void output_committed(struct wl_listener *listener, void *data)
{
    Monitor *m = wl_container_of(listener, m, output_commit);
    struct wlr_output_event_commit *event = data;
    if (!(event->state->committed & (WLR_OUTPUT_STATE_MODE | WLR_OUTPUT_STATE_SCALE
                    | WLR_OUTPUT_STATE_TRANSFORM | WLR_OUTPUT_STATE_ENABLED))) return;
    wlr_damage_ring_add_whole(&m->damage);
    if (m->wlr_output->enabled) {
        m->gamma_lut_changed = true;
        wlr_output_schedule_frame(m->wlr_output);
    } else window_surface_sweep(m, true);
}

void monitor_gamma_changed(struct wl_listener *listener, void *data)
{
    struct wlr_gamma_control_manager_v1_set_gamma_event *event = data;
    Monitor *m = event->output->data;
    if (!m) return;
    m->gamma_lut_changed = true;
    wlr_output_schedule_frame(event->output);
}

static cairo_surface_t *capture(int x, int y, int width, int height,
        bool preserve_alpha, Client *client)
{
    if (width <= 0 || height <= 0) return NULL;
    monitor_make_current();
    struct paint_target *target = paint_target_create(painter, width, height);
    if (!target) return NULL;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    struct render_state *rs = NULL;
    bool ok = cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS
        && paint_begin(painter, paint_target_fbo(target), width, height, 0, NULL, 0);
    Monitor *m;
    if (ok) {
        paint_clear(painter, (struct paint_color){0, 0, 0, preserve_alpha ? 0 : 1});
        if (client) {
            rs = render_create();
            render_draw_surface(rs, painter, client_surface(client), width, height,
                client->surface_origin, client->surface_radii);
        } else {
            wl_list_for_each(m, &mons, link) {
                if (!m->wlr_output->enabled) continue;
                struct render_draw_params params = {.scale = 1,
                    .origin_x = m->m.x - x, .origin_y = m->m.y - y,
                    .skip_cursor = true, .skip_wallpaper = preserve_alpha,
                    .width = width, .height = height};
                declare_draw(m->declare, painter, NULL, &params);
            }
        }
        ok = paint_end(painter);
        if (ok) ok = paint_readback(painter, (struct paint_box){0, 0, width, height},
            cairo_image_surface_get_stride(surface), cairo_image_surface_get_data(surface));
    }
    if (rs) render_destroy(rs, NULL);
    wl_list_for_each(m, &mons, link) declare_finish(m->declare);
    paint_target_destroy(target);
    if (!ok) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_surface_mark_dirty(surface);
    return surface;
}

cairo_surface_t *monitor_capture(int x, int y, int width, int height, bool preserve_alpha)
{
    return capture(x, y, width, height, preserve_alpha, NULL);
}

cairo_surface_t *monitor_capture_client(Client *c, int width, int height)
{
    return client_is_mapped(c) ? capture(0, 0, width, height, true, c) : NULL;
}
