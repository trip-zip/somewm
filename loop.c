/*
 * loop.c - Main loop machinery: GLib integration and the refresh cycle
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>
#include <glib.h>
#include <wayland-server-core.h>

#include "loop.h"
#include "somewm.h"
#include "somewm_api.h"
#include "common/lualib.h"
#include "globalconf.h"
#include "luaa.h"
#include "stack.h"
#include "banning.h"
#include "animation.h"
#include "event_queue.h"
#include "input.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/signal.h"

/* ============================================================================
 * GLIB MAIN LOOP INTEGRATION - Matches AwesomeWM Architecture
 * ============================================================================
 * This section implements GLib as the primary event loop with Wayland
 * integration via GSource, exactly matching AwesomeWM's pattern of using
 * a custom poll function to handle refresh cycles before polling.
 */

/* GSource for Wayland event loop integration */
typedef struct {
	GSource source;
	GPollFD poll_fd;
	struct wl_event_loop *loop;
} WaylandSource;

/* Time tracking for performance monitoring (matches AwesomeWM) */
static struct timeval last_wakeup;
static float main_loop_iteration_limit = 0.1f;

/* Recursion guard for some_refresh() */
static bool in_refresh = false;

#include "bench.h"

/* WaylandSource prepare callback - called before polling */
static gboolean
wayland_source_prepare(GSource *source, gint *timeout)
{
	/* Don't force immediate dispatch, let GLib handle timeout.
	 * The custom poll function will handle refresh timing. */
	*timeout = -1;
	return FALSE;
}

/* WaylandSource check callback - check if fd has events */
static gboolean
wayland_source_check(GSource *source)
{
	WaylandSource *wl_source = (WaylandSource *)source;

	/* Check if our fd has events ready */
	return wl_source->poll_fd.revents & G_IO_IN;
}

/* WaylandSource dispatch callback - process Wayland events */
static gboolean
wayland_source_dispatch(GSource *source, GSourceFunc callback, gpointer user_data)
{
	WaylandSource *wl_source = (WaylandSource *)source;

	/* Dispatch all pending Wayland events (non-blocking)
	 * This processes backend events, client requests, etc. */
	wl_event_loop_dispatch(wl_source->loop, 0);

	return G_SOURCE_CONTINUE;
}

/* WaylandSource function table */
static GSourceFuncs wayland_source_funcs = {
	wayland_source_prepare,
	wayland_source_check,
	wayland_source_dispatch,
	NULL,  /* finalize */
	NULL,  /* closure_callback */
	NULL   /* closure_marshal */
};

/* Create GSource for Wayland event loop */
GSource *
create_wayland_source(struct wl_event_loop *loop)
{
	WaylandSource *wl_source;
	GSource *source;
	int fd;

	/* Get the Wayland event loop's aggregate file descriptor */
	fd = wl_event_loop_get_fd(loop);
	if (fd < 0) {
		fprintf(stderr, "ERROR: Failed to get Wayland event loop fd\n");
		return NULL;
	}

	/* Create our custom GSource */
	source = g_source_new(&wayland_source_funcs, sizeof(WaylandSource));
	wl_source = (WaylandSource *)source;
	wl_source->loop = loop;

	/* Set up poll fd for GLib to monitor */
	wl_source->poll_fd.fd = fd;
	wl_source->poll_fd.events = G_IO_IN | G_IO_ERR | G_IO_HUP;
	g_source_add_poll(source, &wl_source->poll_fd);

	return source;
}

/* RefreshSource - runs the refresh cycle in GLib's prepare phase.
 *
 * some_refresh() executes Lua (the "refresh" signal, gears.timer delayed
 * calls, coroutines resumed from them), which can arm new GLib timeout
 * sources. GLib computes the poll timeout during the prepare phase, and a
 * same-thread g_source_attach() does not wake an already-computed poll, so
 * a timer armed any later in the iteration is invisible to it: on an idle
 * session the loop sleeps indefinitely while the timer is due, until an
 * unrelated fd event happens to wake it. Running the refresh here, at a
 * higher priority than the default-priority timeout sources, means sources
 * it arms are inserted into buckets this same prepare pass visits
 * afterwards, so they are included in this iteration's poll timeout. */
static gboolean
refresh_source_prepare(GSource *source, gint *timeout)
{
	lua_State *L = globalconf_get_lua_State();

	some_refresh();

	/* Check Lua stack integrity (matches AwesomeWM) */
	if (L && lua_gettop(L) != 0) {
		fprintf(stderr, "WARNING: Something left %d items on Lua stack, this is a bug!\n",
		        lua_gettop(L));
		luaA_dumpstack(L);
		lua_settop(L, 0);
	}

	/* Never ready: this source only does work in prepare */
	*timeout = -1;
	return FALSE;
}

static gboolean
refresh_source_check(GSource *source)
{
	return FALSE;
}

static gboolean
refresh_source_dispatch(GSource *source, GSourceFunc callback, gpointer user_data)
{
	return G_SOURCE_CONTINUE;
}

static GSourceFuncs refresh_source_funcs = {
	refresh_source_prepare,
	refresh_source_check,
	refresh_source_dispatch,
	NULL,  /* finalize */
	NULL,  /* closure_callback */
	NULL   /* closure_marshal */
};

/* Create GSource for the refresh cycle.
 * G_PRIORITY_HIGH so it is prepared before the default-priority timeout
 * sources the refresh Lua may arm (see refresh_source_prepare). */
GSource *
create_refresh_source(void)
{
	GSource *source = g_source_new(&refresh_source_funcs, sizeof(GSource));

	g_source_set_priority(source, G_PRIORITY_HIGH);
	return source;
}

/* Custom poll function - called by GLib before every poll() syscall.
 * The refresh cycle itself runs in refresh_source_prepare() so that timers
 * it arms count toward this iteration's poll timeout; what remains here is
 * the work that must happen after every prepare and right before sleeping.
 *
 * Matches AwesomeWM's awesome.c:a_glib_poll()
 */
static gint
some_glib_poll(GPollFD *ufds, guint nfsd, gint timeout)
{
	guint res;
	struct timeval now, length_time;
	float length;
	int saved_errno;

	/* Flush pending Wayland client data before polling
	 * Clients won't receive data until we flush */
	wl_display_flush_clients(dpy);

	/* Drain wlroots idle sources before sleeping. wlr_output_schedule_frame()
	 * (called by drawin_refresh_drawable() when a wibox redraws) queues the frame
	 * as a wl_event_loop idle, and idles only run inside wl_event_loop_dispatch().
	 * That otherwise happens solely when the loop fd is readable from input or
	 * client traffic (via wayland_source_dispatch), so a timer-driven redraw (e.g.
	 * textclock / awful.widget.watch) updates the scene buffer but is never
	 * committed on an idle session and the widget freezes until the next input.
	 * dispatch_idle runs exactly the queued idles (not fd sources, which stay with
	 * the GSource), presenting those frames every iteration. */
	wl_event_loop_dispatch_idle(wl_display_get_event_loop(dpy));

	/* Check iteration performance (matches AwesomeWM) */
	gettimeofday(&now, NULL);
	timersub(&now, &last_wakeup, &length_time);
	length = (float)length_time.tv_sec + length_time.tv_usec * 1.0f / 1e6f;
	if (length > main_loop_iteration_limit) {
		fprintf(stderr, "WARNING: Last iteration took %.6f seconds (limit: %.6f)\n",
		        length, main_loop_iteration_limit);
		main_loop_iteration_limit = length;
	}

	/* Actually do the polling (matches AwesomeWM) */
	res = g_poll(ufds, nfsd, timeout);
	saved_errno = errno;
	gettimeofday(&last_wakeup, NULL);
	errno = saved_errno;

	return res;
}

/* Install some_glib_poll() as the default context's poll function, and seed
 * the iteration timer it measures against. Matches AwesomeWM's a_glib_poll(). */
void
some_loop_install_poll_func(void)
{
	g_main_context_set_poll_func(g_main_context_default(), &some_glib_poll);
	gettimeofday(&last_wakeup, NULL);
}

/** Main refresh cycle (AwesomeWM pattern).
 *
 * This implements AwesomeWM's awesome_refresh() pattern for Wayland.
 * Called before every event loop iteration to apply all pending changes.
 *
 * Matches AwesomeWM's awesome.c a_glib_poll() which calls:
 *   awesome_refresh() -> client_refresh() -> client_geometry_refresh()
 *
 * Without this, geometry changes calculated in Lua never reach Wayland!
 */
void
some_refresh(void)
{
	/* Prevent recursive refresh calls (matches AwesomeWM pattern) */
	if (in_refresh)
		return;
	in_refresh = true;

#ifdef SOMEWM_BENCH
	struct timespec bench_ts[BENCH_STAGE_COUNT + 1];
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[0]);
#endif

	/* Step 0: Drain queued events - dispatch batched signals to Lua.
	 * Must happen before the refresh signal so Lua handlers see
	 * up-to-date state when layout runs.
	 * Included in the lua_refresh stage timing. */
	some_event_queue_drain(globalconf_L);

	/* Step 1: Emit refresh signal - triggers Lua layout calculations */
	luaA_emit_signal_global("refresh");

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[1]);
#endif

	/* Step 1.5: Tick frame-synced animations - tick callbacks that modify
	 * client geometry will have their changes applied by client_refresh()
	 * in the same cycle. */
	animation_tick_all();

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[2]);
#endif

	/* Step 2: Refresh drawins (wibox/panels) FIRST - matches AwesomeWM order
	 * AwesomeWM calls drawin_refresh() BEFORE client_refresh() in awesome_refresh().
	 * This ensures wibar geometry is applied before client layout calculations. */
	drawin_refresh();

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[3]);
#endif

	/* Step 3: Apply client changes (geometry, borders, focus)
	 * This matches AwesomeWM's client_refresh() which handles all client updates. */
	client_refresh();

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[4]);
#endif

	/* Step 4: Update client visibility (banning) */
	bool banning_pending = globalconf.need_lazy_banning;
	banning_refresh();

	/* Step 4.5: Re-evaluate pointer focus after visibility changes.
	 * When scene nodes are disabled (banned) wlroots sends wl_pointer.leave,
	 * but re-enabling them does not automatically send wl_pointer.enter.
	 * Without this, clients (notably Chromium) that were unbanned under a
	 * stationary cursor never regain pointer focus and stop receiving all
	 * input until the user moves the mouse. */
	if (banning_pending)
		motionnotify(0, NULL, 0, 0, 0, 0);

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[5]);
#endif

	/* Step 5: Update window stacking (Z-order)
	 * This matches AwesomeWM's awesome_refresh() which calls stack_refresh() */
	stack_refresh();

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[6]);
#endif

	/* Step 6: Destroy windows queued for deferred destruction (XWayland only)
	 * This matches AwesomeWM's deferred destruction pattern to avoid race conditions */
	client_destroy_later();

#ifdef SOMEWM_BENCH
	clock_gettime(CLOCK_MONOTONIC, &bench_ts[7]);
	for (int i = 0; i < BENCH_STAGE_COUNT; i++)
		bench_stage_record(i, timespec_diff_ns(&bench_ts[i], &bench_ts[i + 1]));
	bench_record_frame_time(timespec_diff_ns(&bench_ts[0], &bench_ts[7]));
#endif

	in_refresh = false;
}
