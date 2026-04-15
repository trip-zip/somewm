/*
 * somewm.c - Compositor initialization, event loop, and main entry point
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdbool.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <glib.h>
#include <glib-unix.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/backend/multi.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wlr/types/wlr_data_control_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_drm.h>
#include <wlr/types/wlr_export_dmabuf_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_gamma_control_v1.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_output_power_management_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_pointer_gestures_v1.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_virtual_pointer_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_server_decoration.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#ifdef XWAYLAND
#include <wlr/xwayland.h>
#include <xcb/xcb.h>
#endif

#include "somewm.h"
#include "somewm_types.h"
#include "somewm_api.h"
#include "common/util.h"
#include "common/lualib.h"
#include "wlr_compat.h"
#include "globalconf.h"
#include "luaa.h"
#include "stack.h"
#include "banning.h"
#include "animation.h"
#include "ipc.h"
#include "dbus.h"
#include "objects/spawn.h"
#include "objects/screen.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/signal.h"
#include "objects/mousegrabber.h"
#include "xwayland.h"
#include "protocols.h"
#include "monitor.h"
#include "input.h"
#include "window.h"
#include "focus.h"

/* macros */
#define TAGCOUNT (32)
#define TAGMASK                 ((TAGCOUNT >= 32) ? ~0u : ((1u << TAGCOUNT) - 1))

/* function declarations */
static void cleanup(void);
static void cleanuplisteners(void);
static void handlesig(int signo);
void printstatus(void);
void some_refresh(void);
static void run(char *startup_cmd);
static void setup(void);
void spawn(const Arg *arg);

/* variables */
static pid_t child_pid = -1;
uint32_t next_client_id = 1;

int locked;
int running = 1;
void *exclusive_focus;
struct wl_display *dpy;
struct wl_event_loop *event_loop;
struct wlr_backend *backend;
struct wlr_scene *scene;
struct wlr_scene_tree *layers[NUM_LAYERS];
struct wlr_scene_tree *drag_icon;
Client *drag_source_client;
/* Map from ZWLR_LAYER_SHELL_* constants to Lyr* enum */
const int layermap[] = { LyrBg, LyrBottom, LyrTop, LyrOverlay };
struct wlr_renderer *drw;
struct wlr_allocator *alloc;
struct wlr_compositor *compositor;
struct wlr_session *session;

struct wlr_xdg_shell *xdg_shell;
struct wlr_xdg_activation_v1 *activation;

static int sigchld_pipe[2] = {-1, -1};
struct wlr_xdg_decoration_manager_v1 *xdg_decoration_mgr;
struct wlr_idle_notifier_v1 *idle_notifier;
struct wlr_idle_inhibit_manager_v1 *idle_inhibit_mgr;
static bool last_idle_inhibited = false;
struct wlr_layer_shell_v1 *layer_shell;
struct wlr_output_manager_v1 *output_mgr;
struct wlr_virtual_keyboard_manager_v1 *virtual_keyboard_mgr;
struct wlr_virtual_pointer_manager_v1 *virtual_pointer_mgr;
struct wlr_cursor_shape_manager_v1 *cursor_shape_mgr;
struct wlr_output_power_manager_v1 *power_mgr;
struct wlr_foreign_toplevel_manager_v1 *foreign_toplevel_mgr;

struct wlr_pointer_constraints_v1 *pointer_constraints;
struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
struct wlr_pointer_constraint_v1 *active_constraint;

struct wlr_cursor *cursor;
struct wlr_xcursor_manager *cursor_mgr;
char* selected_root_cursor;

struct wlr_scene_rect *root_bg;
struct wlr_session_lock_manager_v1 *session_lock_mgr;
struct wlr_scene_rect *locked_bg;
struct wlr_session_lock_v1 *cur_lock;

struct wlr_seat *seat;
KeyboardGroup *kb_group;
/* cursor_mode: owned by input.c */
int new_client_placement = 0; /* 0 = master (default), 1 = slave */

struct wlr_output_layout *output_layout;
struct wlr_box sgeom;
struct wl_list mons;
struct wl_list tracked_pointers; /* For runtime libinput config */
Monitor *selmon;
/* in_updatemons, updatemons_pending: owned by monitor.c */

/* global event handlers */
static struct wl_listener new_idle_inhibitor = {.notify = createidleinhibitor};
static struct wl_listener new_layer_surface = {.notify = createlayersurface};
static struct wl_listener request_activate = {.notify = urgent};
static struct wl_listener new_session_lock = {.notify = locksession};

/* Pointer gesture manager */
struct wlr_pointer_gestures_v1 *pointer_gestures;
/* gesture_*_consumed: owned by input.c */

#ifdef XWAYLAND
struct wlr_xwayland *xwayland;
#endif

/* Helper functions to expose layouts array to somewm_api.c */
/* Layouts are now managed in Lua - no C layout functions needed */

/* Helper functions to expose tag system to somewm_api.c */
int
some_tagcount(void)
{
	return TAGCOUNT;
}

uint32_t
some_tagmask(void)
{
	return TAGMASK;
}

int
some_has_exclusive_focus(void)
{
	return exclusive_focus != NULL;
}

/* attempt to encapsulate suck into one file */
#include "client.h"

/* Synchronize client removal from globalconf arrays
 * NOTE: This function is currently unused as client_unmanage() handles removal.
 * Kept for reference or future use. */
static void __attribute__((unused))
sync_client_remove_from_arrays(Client *c)
{
	/* Safety check: if arrays not initialized yet, skip sync */
	if (!globalconf.clients.tab || !globalconf.stack.tab) {
		return;
	}

	/* Remove from clients array */
	foreach(elem, globalconf.clients) {
		if (*elem == c) {
			client_array_remove(&globalconf.clients, elem);
			break;
		}
	}

	/* Remove from stack array */
	foreach(elem, globalconf.stack) {
		if (*elem == c) {
			client_array_remove(&globalconf.stack, elem);
			break;
		}
	}

}

void
some_recompute_idle_inhibit(struct wlr_surface *exclude)
{
	bool inhibited = some_is_idle_inhibited(exclude) || some_is_lua_idle_inhibited();
	wlr_idle_notifier_v1_set_inhibited(idle_notifier, inhibited);
	some_idle_timers_set_inhibit(inhibited);

	if (inhibited != last_idle_inhibited) {
		last_idle_inhibited = inhibited;
		luaA_emit_signal_global("property::idle_inhibited");
	}
}

void
cleanup(void)
{
	/* Emit exit signal while Lua alive (matches AwesomeWM pattern) */
	if (globalconf_L) {
		lua_State *L = globalconf_get_lua_State();
		lua_pushboolean(L, false);
		luaA_signal_emit(L, "exit", 1);
	}

	a_dbus_cleanup();
	ipc_cleanup();

	xwayland_cleanup();

	cleanuplisteners();

	/* Destroy Wayland clients while Lua is still alive so signal handlers work. */
	wl_display_destroy_clients(dpy);

	/* Cleanup wallpaper cache before destroying scene */
	wallpaper_cache_cleanup();

	/* Free animations before Lua state (they hold registry refs) */
	animation_cleanup();

	/* Close Lua after clients are destroyed (matches AwesomeWM pattern) */
	luaA_cleanup();

	/* Cleanup startup_errors buffer */
	buffer_wipe(&globalconf.startup_errors);

	/* Cleanup x11_fallback info */
	free(globalconf.x11_fallback.config_path);
	free(globalconf.x11_fallback.pattern_desc);
	free(globalconf.x11_fallback.suggestion);
	free(globalconf.x11_fallback.line_content);

	if (child_pid > 0) {
		kill(-child_pid, SIGTERM);
		waitpid(child_pid, NULL, 0);
	}
	wlr_xcursor_manager_destroy(cursor_mgr);

	free(selected_root_cursor);

	destroykeyboardgroup(&kb_group->destroy, NULL);

	/* Remove backend listeners immediately before destroying backend.
	 * wlroots 0.19 asserts that all listeners are removed at destruction time. */
	wl_list_remove(&new_output.link);
	wl_list_remove(&new_input_device.link);

	/* If it's not destroyed manually, it will cause a use-after-free of wlr_seat.
	 * Destroy it until it's fixed on the wlroots side */
	wlr_backend_destroy(backend);

	wl_display_destroy(dpy);
	/* Destroy after the wayland display (when the monitors are already destroyed)
	   to avoid destroying them with an invalid scene output. */
	wlr_scene_node_destroy(&scene->tree.node);
}

void
cleanuplisteners(void)
{
	wl_list_remove(&cursor_axis.link);
	wl_list_remove(&cursor_button.link);
	wl_list_remove(&cursor_frame.link);
	wl_list_remove(&cursor_motion.link);
	wl_list_remove(&cursor_motion_absolute.link);
	wl_list_remove(&gesture_swipe_begin.link);
	wl_list_remove(&gesture_swipe_update.link);
	wl_list_remove(&gesture_swipe_end.link);
	wl_list_remove(&gesture_pinch_begin.link);
	wl_list_remove(&gesture_pinch_update.link);
	wl_list_remove(&gesture_pinch_end.link);
	wl_list_remove(&gesture_hold_begin.link);
	wl_list_remove(&gesture_hold_end.link);
	wl_list_remove(&gpu_reset.link);
	wl_list_remove(&new_idle_inhibitor.link);
	wl_list_remove(&layout_change.link);
	/* NOTE: new_input_device and new_output are removed in cleanup()
	 * immediately before wlr_backend_destroy() to satisfy wlroots 0.19
	 * assertions that require all backend listeners to be present until
	 * backend destruction. */
	wl_list_remove(&new_virtual_keyboard.link);
	wl_list_remove(&new_virtual_pointer.link);
	wl_list_remove(&new_pointer_constraint.link);
	wl_list_remove(&new_xdg_toplevel.link);
	wl_list_remove(&new_xdg_decoration.link);
	wl_list_remove(&new_xdg_popup.link);
	wl_list_remove(&new_layer_surface.link);
	wl_list_remove(&output_mgr_apply.link);
	wl_list_remove(&output_mgr_test.link);
	wl_list_remove(&output_power_mgr_set_mode.link);
	wl_list_remove(&request_activate.link);
	wl_list_remove(&request_cursor.link);
	wl_list_remove(&request_set_psel.link);
	wl_list_remove(&request_set_sel.link);
	wl_list_remove(&request_set_cursor_shape.link);
	wl_list_remove(&request_start_drag.link);
	wl_list_remove(&start_drag.link);
	wl_list_remove(&new_session_lock.link);
	/* NOTE: XWayland listeners are removed in cleanup() immediately before
	 * wlr_xwayland_destroy(), matching the backend listener pattern. */
}

/* ==========================================================================
 * Lua Lock API Implementation
 * ========================================================================== */

/* Stores the focused client before locking, for restoration on unlock */
static Client *pre_lock_focused_client = NULL;

/** Activate Lua-controlled lock mode
 * - Promotes lock surface and cover surfaces to LyrBlock
 * - Gives keyboard focus to lock surface
 */
void
some_activate_lua_lock(void)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	/* Save currently focused client for restoration on unlock. */
	pre_lock_focused_client = globalconf.focus.client;

	/* Clear current keyboard focus */
	wlr_seat_keyboard_notify_clear_focus(seat);

	/* Stop any active mousegrabber to prevent Lua callbacks executing
	 * during lock (e.g., client resize/move operations) */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		luaA_mousegrabber_stop(L);
	}

	/* Enable the compositor-level background rect in LyrBlock.
	 * This provides an opaque safety net behind all lock surfaces so that
	 * desktop content is never visible, even on screens that have no
	 * Lua-created cover wibox (e.g. hotplugged monitors). */
	wlr_scene_node_set_enabled(&locked_bg->node, 1);

	/* Promote all cover surfaces to LyrBlock so they hide desktop content
	 * on secondary monitors */
	for (int i = 0; i < cover_count; i++)
		some_promote_lock_cover(covers[i]);

	/* Promote lock surface to LyrBlock and raise above covers */
	if (lock_surface && lock_surface->scene_tree) {
		wlr_scene_node_reparent(&lock_surface->scene_tree->node, layers[LyrBlock]);
		wlr_scene_node_raise_to_top(&lock_surface->scene_tree->node);
	}
}

/** Deactivate Lua-controlled lock mode
 * - Restores lock surface and covers to normal layers
 * - Restores normal focus
 */
void
some_deactivate_lua_lock(void)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	/* Disable compositor-level lock background */
	wlr_scene_node_set_enabled(&locked_bg->node, 0);

	/* Move lock surface back to normal layer (LyrWibox) */
	if (lock_surface && lock_surface->scene_tree) {
		wlr_scene_node_reparent(&lock_surface->scene_tree->node, layers[LyrWibox]);
	}

	/* Move cover surfaces back to normal layers via stack_refresh() */
	for (int i = 0; i < cover_count; i++) {
		if (covers[i] && covers[i]->scene_tree) {
			wlr_scene_node_reparent(&covers[i]->scene_tree->node, layers[LyrWibox]);
		}
	}

	/* Let stack_refresh() sort everything back to proper layers */
	stack_refresh();

	/* Restore focus to pre-lock client if still valid, otherwise top client */
	if (pre_lock_focused_client && pre_lock_focused_client->scene) {
		focusclient(pre_lock_focused_client, 1);
	} else {
		focus_restore(selmon);
	}
	pre_lock_focused_client = NULL;
	motionnotify(0, NULL, 0, 0, 0, 0);
}

/** Promote a single cover to LyrBlock during an active lock.
 * Re-raises the interactive lock surface above the new cover so it
 * stays on top of all covers. */
void
some_promote_lock_cover(drawin_t *d)
{
	if (d && d->scene_tree) {
		wlr_scene_node_reparent(&d->scene_tree->node, layers[LyrBlock]);
		wlr_scene_node_raise_to_top(&d->scene_tree->node);
		drawin_t *lock_surface = some_get_lua_lock_surface();
		if (lock_surface && lock_surface->scene_tree)
			wlr_scene_node_raise_to_top(&lock_surface->scene_tree->node);
	}
}

/** Clear pre_lock_focused_client if it matches the given client.
 * Called from client_unmanage() to prevent use-after-free on unlock. */
void
some_clear_pre_lock_client(Client *c)
{
	if (c == pre_lock_focused_client)
		pre_lock_focused_client = NULL;
}

/** Check if ext-session-lock-v1 is currently active */
int
some_is_ext_session_locked(void)
{
	return locked;
}

void
handlesig(int signo)
{
	if (signo == SIGCHLD) {
		/* Write to pipe to wake up GLib main loop (AwesomeWM pattern).
		 * Child reaping is done in reap_children() callback. */
		if (sigchld_pipe[1] >= 0) {
			int res = write(sigchld_pipe[1], " ", 1);
			(void) res;  /* Ignore write errors in signal handler */
		}
	} else if (signo == SIGINT || signo == SIGTERM) {
		wl_display_terminate(dpy);
	}
}

/** GLib callback for SIGCHLD pipe (AwesomeWM pattern).
 * This is called when the SIGCHLD handler writes to the pipe.
 * We read from the pipe and reap all children with waitpid().
 */
static gboolean
reap_children(gint fd, GIOCondition condition, gpointer data)
{
	pid_t child;
	int status;
	char buffer[1024];
	ssize_t result;

	/* Read from pipe to clear it */
	result = read(sigchld_pipe[0], buffer, sizeof(buffer));
	if (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
		fprintf(stderr, "somewm: error reading from SIGCHLD pipe: %s\n",
		        strerror(errno));
	}

	/* Reap all exited children */
	while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
		spawn_child_exited(child, status);
	}

	if (child < 0 && errno != ECHILD) {
		fprintf(stderr, "somewm: waitpid(-1) failed: %s\n", strerror(errno));
	}

	return TRUE;  /* Keep watching */
}

/* ========== APPEARANCE HELPER FUNCTIONS ========== */
/* These functions read appearance settings from beautiful.* (Lua theme system)
 * with fallbacks to globalconf defaults. This achieves AwesomeWM compatibility:
 * themes can customize appearance without recompiling C code. */

/* ========== KEYBINDING SYSTEM ========== */

#include "objects/keybinding.h"

void
cursor_to_client_coordinates(Client *client, double *sx, double *sy) {
	double bw = client->bw;
	/* Compute coordinates (sx, sy) within the borderd geometry. */
	*sx = cursor->x - (client->geometry.x + bw);
	*sy = cursor->y - (client->geometry.y + bw);
}


/* moveresize() function removed - move/resize now handled by Lua mousegrabber
 * (awful.mouse.client.move/resize) via client button bindings in rc.lua */

void
printstatus(void)
{
	/* Status output removed - use Lua signals (client.connect_signal) instead */
}

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

/* Forward declaration */
void some_refresh(void);

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
static GSource *
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

/* Custom poll function - THE KEY INTEGRATION POINT
 *
 * This is called by GLib before every poll() syscall and is where we
 * implement AwesomeWM's refresh cycle pattern. By doing refresh here,
 * we ensure all deferred changes are applied before sleeping.
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
	lua_State *L = globalconf_get_lua_State();

	/* CRITICAL: Do all deferred work before sleeping
	 * This applies layout calculations from Lua to Wayland scene graph */
	some_refresh();

	/* Check Lua stack integrity (matches AwesomeWM) */
	if (L && lua_gettop(L) != 0) {
		fprintf(stderr, "WARNING: Something left %d items on Lua stack, this is a bug!\n",
		        lua_gettop(L));
		luaA_dumpstack(L);
		lua_settop(L, 0);
	}

	/* Flush pending Wayland client data before polling
	 * Clients won't receive data until we flush */
	wl_display_flush_clients(dpy);

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
	banning_refresh();

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

void
run(char *startup_cmd)
{
	struct wl_event_loop *loop;
	GSource *wayland_source;

	/* Add a Unix socket to the Wayland display. */
	const char *socket = wl_display_add_socket_auto(dpy);
	if (!socket)
		die("startup: display_add_socket_auto");
	setenv("WAYLAND_DISPLAY", socket, 1);

	/* Emit screen::scanning signal before backend starts creating monitors */
	if (globalconf_L) {
		screen_emit_scanning();
	}

	/* Start the backend. This will enumerate outputs and inputs, become the DRM
	 * master, etc. This will trigger createmon() for each detected output. */
	if (!wlr_backend_start(backend))
		die("startup: backend_start");

	/* Initialize tag objects after monitors are created */
	/* NOTE: Tags are now created entirely from Lua via awful.tag() in rc.lua (AwesomeWM-compatible)
	 * Removed C tag initialization to avoid creating duplicate tags without screen assignments */
	// luaA_tags_init(globalconf_L, TAGCOUNT, tag_names);

	/* Emit _added signals BEFORE rc.lua loads (AwesomeWM pattern).
	 * At this point, no handlers are connected, so these signals are effectively no-ops.
	 * This matches AwesomeWM's screen_scan() which emits _added before luaA_parserc().
	 * The ::connected mechanism in awful/screen.lua handles initial screens when
	 * rc.lua connects its handlers. */
	if (globalconf_L) {
		luaA_screen_emit_all_added(globalconf_L);
		luaA_loadrc();
		/* Emit screen::scanned AFTER rc.lua loads (matches AwesomeWM).
		 * This allows rc.lua handlers to be connected before scanned fires. */
		screen_emit_scanned();

		/* Emit client scanning signals - triggers awful.mouse to set up default mousebindings */
		client_emit_scanning();
		client_emit_scanned();

		/* Emit startup signal to initialize Lua modules (matches AwesomeWM) */
		luaA_emit_signal_global("startup");

		/* Ensure all drawables created during startup have their content
		 * pushed to scene buffers. This fixes the timing issue where wiboxes
		 * don't appear until an external event triggers some_refresh().
		 * In AwesomeWM, xcb_flush() sends everything immediately after config
		 * loads; in Wayland we need to explicitly refresh all drawables. */
		some_refresh();
	}

	/* Now that the socket exists and the backend is started, run the startup command */
	if (startup_cmd) {
		int piperw[2];
		if (pipe(piperw) < 0)
			die("startup: pipe:");
		if ((child_pid = fork()) < 0)
			die("startup: fork:");
		if (child_pid == 0) {
			setsid();
			dup2(piperw[0], STDIN_FILENO);
			close(piperw[0]);
			close(piperw[1]);
			execl("/bin/sh", "/bin/sh", "-c", startup_cmd, NULL);
			die("startup: execl:");
		}
		dup2(piperw[1], STDOUT_FILENO);
		close(piperw[1]);
		close(piperw[0]);
	}

	/* Mark stdout as non-blocking to avoid the startup script
	 * causing somewm to freeze when a user neither closes stdin
	 * nor consumes standard input in his startup script */

	if (fd_set_nonblock(STDOUT_FILENO) < 0)
		close(STDOUT_FILENO);

	printstatus();

	/* At this point the outputs are initialized, choose initial selmon based on
	 * cursor position, and set default cursor image */
	selmon = xytomon(cursor->x, cursor->y);

	/* TODO hack to get cursor to display in its initial location (100, 100)
	 * instead of (0, 0) and then jumping. Still may not be fully
	 * initialized, as the image/coordinates are not transformed for the
	 * monitor when displayed here */
	wlr_cursor_warp_closest(cursor, NULL, cursor->x, cursor->y);
	wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");

	/* ========================================================================
	 * RUN GLIB MAIN LOOP (Matches AwesomeWM Architecture)
	 * ========================================================================
	 *
	 * This replaces the manual event loop with GLib as the primary loop,
	 * using a custom poll function to handle the refresh cycle.
	 * Wayland events are integrated via a GSource.
	 *
	 * This is the SAME architecture as AwesomeWM:
	 * - GLib main loop is primary (g_main_loop_run)
	 * - Custom poll function (some_glib_poll) calls refresh before polling
	 * - Backend events (Wayland) integrated via GSource
	 * - D-Bus, timers, and other GLib sources work automatically
	 */

	/* Get Wayland event loop */
	loop = wl_display_get_event_loop(dpy);

	/* Create and attach Wayland GSource to GLib main context */
	wayland_source = create_wayland_source(loop);
	if (!wayland_source) {
		fprintf(stderr, "FATAL: Failed to create Wayland source\n");
		exit(EXIT_FAILURE);
	}
	g_source_attach(wayland_source, NULL);  /* Attach to default context */

	/* Record highest GLib source ID before Lua loads. During hot-reload,
	 * all sources above this baseline are removed to prevent stale Lgi
	 * FFI closures from firing with dead lua_State* pointers. */
	globalconf.glib_source_baseline = g_source_get_id(wayland_source);

	/* Set custom poll function - THE critical integration point
	 * This ensures some_refresh() is called before every poll() syscall,
	 * matching AwesomeWM's a_glib_poll() pattern */
	g_main_context_set_poll_func(g_main_context_default(), &some_glib_poll);
	gettimeofday(&last_wakeup, NULL);

	/* Create and run GLib main loop (matches AwesomeWM) */
	globalconf.loop = g_main_loop_new(NULL, FALSE);

	/* Check stack before entering main loop (matches AwesomeWM's pattern) */
	if (globalconf_L && lua_gettop(globalconf_L) != 0) {
		fprintf(stderr, "WARNING: Stack not empty before main loop! %d items, this is a bug.\n",
		        lua_gettop(globalconf_L));
		luaA_dumpstack(globalconf_L);
		lua_settop(globalconf_L, 0);
	}

	g_main_loop_run(globalconf.loop);

	/* Cleanup */
	g_source_destroy(wayland_source);
	g_main_loop_unref(globalconf.loop);
	globalconf.loop = NULL;

	/* Close SIGCHLD pipe */
	if (sigchld_pipe[0] >= 0) {
		close(sigchld_pipe[0]);
		sigchld_pipe[0] = -1;
	}
	if (sigchld_pipe[1] >= 0) {
		close(sigchld_pipe[1]);
		sigchld_pipe[1] = -1;
	}
}

/* setfloating() removed - floating state is now managed entirely by Lua property system.
 * Scene graph layer changes happen via arrange() when Lua updates property::floating.
 * This matches AwesomeWM's approach where C doesn't manage floating state. */

void
setup(void)
{
	int i, sig[] = {SIGCHLD, SIGINT, SIGTERM, SIGPIPE};
	struct sigaction sa = {.sa_flags = SA_RESTART, .sa_handler = handlesig};
	sigemptyset(&sa.sa_mask);

	/* Setup pipe for SIGCHLD processing (AwesomeWM pattern).
	 * The signal handler writes to the pipe, and a GLib IO watch
	 * reads from it and calls reap_children(). */
	if (pipe(sigchld_pipe) < 0)
		die("failed to create SIGCHLD pipe");
	/* Make read end non-blocking */
	fcntl(sigchld_pipe[0], F_SETFL, O_NONBLOCK);

	/* Setup GLib watch for SIGCHLD pipe */
	g_unix_fd_add(sigchld_pipe[0], G_IO_IN, reap_children, NULL);

	for (i = 0; i < (int)LENGTH(sig); i++)
		sigaction(sig[i], &sa, NULL);
	wlr_log_init(globalconf.log_level, NULL);


	/* The Wayland display is managed by libwayland. It handles accepting
	 * clients from the Unix socket, manging Wayland globals, and so on. */
	dpy = wl_display_create();
	event_loop = wl_display_get_event_loop(dpy);

	/* The backend is a wlroots feature which abstracts the underlying input and
	 * output hardware. The autocreate option will choose the most suitable
	 * backend based on the current environment, such as opening an X11 window
	 * if an X11 server is running. */
	if (!(backend = wlr_backend_autocreate(event_loop, &session)))
		die("couldn't create backend");

	/* Initialize the scene graph used to lay out windows */
	scene = wlr_scene_create();
	root_bg = wlr_scene_rect_create(&scene->tree, 0, 0, globalconf.appearance.rootcolor);
	for (i = 0; i < NUM_LAYERS; i++)
		layers[i] = wlr_scene_tree_create(&scene->tree);
	drag_icon = wlr_scene_tree_create(&scene->tree);
	wlr_scene_node_place_below(&drag_icon->node, &layers[LyrBlock]->node);

	/* Autocreates a renderer, either Pixman, GLES2 or Vulkan for us. The user
	 * can also specify a renderer using the WLR_RENDERER env var.
	 * The renderer is responsible for defining the various pixel formats it
	 * supports for shared memory, this configures that for clients. */
	if (!(drw = wlr_renderer_autocreate(backend)))
		die("couldn't create renderer\n"
			"Try setting WLR_RENDERER=gles2 or WLR_RENDERER=pixman\n"
			"Run with WLR_DEBUG=1 for more details");
	wl_signal_add(&drw->events.lost, &gpu_reset);

	/* Create shm, drm and linux_dmabuf interfaces by ourselves.
	 * The simplest way is to call:
	 *      wlr_renderer_init_wl_display(drw);
	 * but we need to create the linux_dmabuf interface manually to integrate it
	 * with wlr_scene. */
	wlr_renderer_init_wl_shm(drw, dpy);

	if (wlr_renderer_get_texture_formats(drw, WLR_BUFFER_CAP_DMABUF)) {
		wlr_drm_create(dpy, drw);
		wlr_scene_set_linux_dmabuf_v1(scene,
				wlr_linux_dmabuf_v1_create_with_renderer(dpy, 5, drw));
	}

	{
		int drm_fd;
		if ((drm_fd = wlr_renderer_get_drm_fd(drw)) >= 0 && drw->features.timeline
				&& backend->features.timeline)
			wlr_linux_drm_syncobj_manager_v1_create(dpy, 1, drm_fd);
	}

	/* Autocreates an allocator for us.
	 * The allocator is the bridge between the renderer and the backend. It
	 * handles the buffer creation, allowing wlroots to render onto the
	 * screen */
	if (!(alloc = wlr_allocator_autocreate(backend, drw)))
		die("couldn't create allocator");

	/* This creates some hands-off wlroots interfaces. The compositor is
	 * necessary for clients to allocate surfaces and the data device manager
	 * handles the clipboard. Each of these wlroots interfaces has room for you
	 * to dig your fingers in and play with their behavior if you want. Note that
	 * the clients cannot set the selection directly without compositor approval,
	 * see the setsel() function. */
	compositor = wlr_compositor_create(dpy, 6, drw);
	wlr_subcompositor_create(dpy);
	wlr_data_device_manager_create(dpy);
	wlr_export_dmabuf_manager_v1_create(dpy);
	wlr_screencopy_manager_v1_create(dpy);
	wlr_data_control_manager_v1_create(dpy);
	wlr_primary_selection_v1_device_manager_create(dpy);
	wlr_viewporter_create(dpy);
	wlr_single_pixel_buffer_manager_v1_create(dpy);
	wlr_fractional_scale_manager_v1_create(dpy, 1);
	COMPAT_PRESENTATION_CREATE(dpy, backend);
	wlr_alpha_modifier_v1_create(dpy);
	pointer_gestures = wlr_pointer_gestures_v1_create(dpy);

	/* Initializes the interface used to implement urgency hints */
	activation = wlr_xdg_activation_v1_create(dpy);
	wl_signal_add(&activation->events.request_activate, &request_activate);

	wlr_scene_set_gamma_control_manager_v1(scene, wlr_gamma_control_manager_v1_create(dpy));

	power_mgr = wlr_output_power_manager_v1_create(dpy);
	wl_signal_add(&power_mgr->events.set_mode, &output_power_mgr_set_mode);

	/* Creates an output layout, which is a wlroots utility for working with an
	 * arrangement of screens in a physical layout. */
	output_layout = wlr_output_layout_create(dpy);
	wl_signal_add(&output_layout->events.change, &layout_change);

    wlr_xdg_output_manager_v1_create(dpy, output_layout);

	/* Configure a listener to be notified when new outputs are available on the
	 * backend. */
	wl_list_init(&mons);
	wl_list_init(&tracked_pointers);
	wl_signal_add(&backend->events.new_output, &new_output);

	/* Set up our client lists, the xdg-shell and the layer-shell. The xdg-shell is a
	 * Wayland protocol which is used for application windows. For more
	 * detail on shells, refer to the article:
	 *
	 * https://drewdevault.com/2018/07/29/Wayland-shells.html
	 */

	xdg_shell = wlr_xdg_shell_create(dpy, 6);
	wl_signal_add(&xdg_shell->events.new_toplevel, &new_xdg_toplevel);
	wl_signal_add(&xdg_shell->events.new_popup, &new_xdg_popup);

	layer_shell = wlr_layer_shell_v1_create(dpy, 3);
	wl_signal_add(&layer_shell->events.new_surface, &new_layer_surface);

	idle_notifier = wlr_idle_notifier_v1_create(dpy);

	idle_inhibit_mgr = wlr_idle_inhibit_v1_create(dpy);
	wl_signal_add(&idle_inhibit_mgr->events.new_inhibitor, &new_idle_inhibitor);

	session_lock_mgr = wlr_session_lock_manager_v1_create(dpy);
	wl_signal_add(&session_lock_mgr->events.new_lock, &new_session_lock);
	locked_bg = wlr_scene_rect_create(layers[LyrBlock], sgeom.width, sgeom.height,
			(float [4]){0.1f, 0.1f, 0.1f, 1.0f});
	wlr_scene_node_set_enabled(&locked_bg->node, 0);

	/* Use decoration protocols to negotiate server-side decorations */
	wlr_server_decoration_manager_set_default_mode(
			wlr_server_decoration_manager_create(dpy),
			WLR_SERVER_DECORATION_MANAGER_MODE_SERVER);
	xdg_decoration_mgr = wlr_xdg_decoration_manager_v1_create(dpy);
	wl_signal_add(&xdg_decoration_mgr->events.new_toplevel_decoration, &new_xdg_decoration);

	pointer_constraints = wlr_pointer_constraints_v1_create(dpy);
	wl_signal_add(&pointer_constraints->events.new_constraint, &new_pointer_constraint);

	relative_pointer_mgr = wlr_relative_pointer_manager_v1_create(dpy);

	/* Foreign toplevel management - allows external tools like rofi to
	 * list windows and request actions (activate, close, etc.) */
	foreign_toplevel_mgr = wlr_foreign_toplevel_manager_v1_create(dpy);

	/*
	 * Creates a cursor, which is a wlroots utility for tracking the cursor
	 * image shown on screen.
	 */
	cursor = wlr_cursor_create();
	wlr_cursor_attach_output_layout(cursor, output_layout);

	/* Creates an xcursor manager, another wlroots utility which loads up
	 * Xcursor themes to source cursor images from and makes sure that cursor
	 * images are available at all scale factors on the screen (necessary for
	 * HiDPI support). Scaled cursors will be loaded with each output. */
	const char *cursor_theme = getenv("XCURSOR_THEME");
	const char *cursor_size_str = getenv("XCURSOR_SIZE");
	int cursor_size = 24;
	if (cursor_size_str) {
		int parsed = atoi(cursor_size_str);
		if (parsed > 0) {
			cursor_size = parsed;
		}
	}
	cursor_mgr = wlr_xcursor_manager_create(cursor_theme, cursor_size);

	/*
	 * wlr_cursor *only* displays an image on screen. It does not move around
	 * when the pointer moves. However, we can attach input devices to it, and
	 * it will generate aggregate events for all of them. In these events, we
	 * can choose how we want to process them, forwarding them to clients and
	 * moving the cursor around. More detail on this process is described in
	 * https://drewdevault.com/2018/07/17/Input-handling-in-wlroots.html
	 *
	 * And more comments are sprinkled throughout the notify functions above.
	 */
	wl_signal_add(&cursor->events.motion, &cursor_motion);
	wl_signal_add(&cursor->events.motion_absolute, &cursor_motion_absolute);
	wl_signal_add(&cursor->events.button, &cursor_button);
	wl_signal_add(&cursor->events.axis, &cursor_axis);
	wl_signal_add(&cursor->events.frame, &cursor_frame);

	wl_signal_add(&cursor->events.swipe_begin, &gesture_swipe_begin);
	wl_signal_add(&cursor->events.swipe_update, &gesture_swipe_update);
	wl_signal_add(&cursor->events.swipe_end, &gesture_swipe_end);
	wl_signal_add(&cursor->events.pinch_begin, &gesture_pinch_begin);
	wl_signal_add(&cursor->events.pinch_update, &gesture_pinch_update);
	wl_signal_add(&cursor->events.pinch_end, &gesture_pinch_end);
	wl_signal_add(&cursor->events.hold_begin, &gesture_hold_begin);
	wl_signal_add(&cursor->events.hold_end, &gesture_hold_end);

	cursor_shape_mgr = wlr_cursor_shape_manager_v1_create(dpy, 1);
	wl_signal_add(&cursor_shape_mgr->events.request_set_shape, &request_set_cursor_shape);

	/*
	 * Configures a seat, which is a single "seat" at which a user sits and
	 * operates the computer. This conceptually includes up to one keyboard,
	 * pointer, touch, and drawing tablet device. We also rig up a listener to
	 * let us know when new input devices are available on the backend.
	 */
	wl_signal_add(&backend->events.new_input, &new_input_device);
	virtual_keyboard_mgr = wlr_virtual_keyboard_manager_v1_create(dpy);
	wl_signal_add(&virtual_keyboard_mgr->events.new_virtual_keyboard,
			&new_virtual_keyboard);
	virtual_pointer_mgr = wlr_virtual_pointer_manager_v1_create(dpy);
    wl_signal_add(&virtual_pointer_mgr->events.new_virtual_pointer,
            &new_virtual_pointer);

	seat = wlr_seat_create(dpy, "seat0");
	wl_signal_add(&seat->events.request_set_cursor, &request_cursor);
	wl_signal_add(&seat->events.request_set_selection, &request_set_sel);
	wl_signal_add(&seat->events.request_set_primary_selection, &request_set_psel);
	wl_signal_add(&seat->events.request_start_drag, &request_start_drag);
	wl_signal_add(&seat->events.start_drag, &start_drag);

	/* Initialize runtime configuration with C defaults (before Lua loads).
	 * These defaults provide sane fallbacks if rc.lua doesn't set values.
	 * Lua can override any of these via beautiful.* or awesome.* properties.
	 */

	/* Appearance defaults (from config.h) */
	globalconf.appearance.border_width = 1;
	globalconf.appearance.rootcolor[0] = 0x22/255.0f;
	globalconf.appearance.rootcolor[1] = 0x22/255.0f;
	globalconf.appearance.rootcolor[2] = 0x22/255.0f;
	globalconf.appearance.rootcolor[3] = 1.0f;
	globalconf.appearance.bordercolor[0] = 0x44/255.0f;
	globalconf.appearance.bordercolor[1] = 0x44/255.0f;
	globalconf.appearance.bordercolor[2] = 0x44/255.0f;
	globalconf.appearance.bordercolor[3] = 1.0f;
	globalconf.appearance.focuscolor[0] = 0x00/255.0f;
	globalconf.appearance.focuscolor[1] = 0x55/255.0f;
	globalconf.appearance.focuscolor[2] = 0x77/255.0f;
	globalconf.appearance.focuscolor[3] = 1.0f;
	globalconf.appearance.urgentcolor[0] = 1.0f;
	globalconf.appearance.urgentcolor[1] = 0.0f;
	globalconf.appearance.urgentcolor[2] = 0.0f;
	globalconf.appearance.urgentcolor[3] = 1.0f;
	globalconf.appearance.fullscreen_bg[0] = 0.0f;
	globalconf.appearance.fullscreen_bg[1] = 0.0f;
	globalconf.appearance.fullscreen_bg[2] = 0.0f;
	globalconf.appearance.fullscreen_bg[3] = 1.0f;
	globalconf.appearance.bypass_surface_visibility = 0;  /* Idle inhibitors only when visible */

	/* Shadow defaults (disabled by default, theme enables via beautiful.shadow_*) */
	globalconf.shadow.client.enabled = false;
	globalconf.shadow.client.radius = 12;
	globalconf.shadow.client.offset_x = -15;
	globalconf.shadow.client.offset_y = -15;
	globalconf.shadow.client.opacity = 0.75f;
	globalconf.shadow.client.color[0] = 0.0f;  /* Black */
	globalconf.shadow.client.color[1] = 0.0f;
	globalconf.shadow.client.color[2] = 0.0f;
	globalconf.shadow.client.color[3] = 1.0f;
	globalconf.shadow.client.clip_directional = true;
	/* Drawin defaults (same as client initially) */
	globalconf.shadow.drawin = globalconf.shadow.client;

	/* Keyboard defaults (NULL = system defaults) */
	globalconf.keyboard.xkb_layout = NULL;
	globalconf.keyboard.xkb_variant = NULL;
	globalconf.keyboard.xkb_options = NULL;
	globalconf.keyboard.repeat_rate = 25;
	globalconf.keyboard.repeat_delay = 600;

	/* Input device defaults (-1 = use device default) */
	globalconf.input.tap_to_click = -1;
	globalconf.input.tap_and_drag = -1;
	globalconf.input.drag_lock = -1;
	globalconf.input.natural_scrolling = -1;
	globalconf.input.disable_while_typing = -1;
	globalconf.input.left_handed = -1;
	globalconf.input.middle_button_emulation = -1;
	globalconf.input.scroll_method = NULL;  /* String property - set via Lua */
	globalconf.input.click_method = NULL;   /* String property - set via Lua */
	globalconf.input.send_events_mode = NULL;  /* String property - set via Lua */
	globalconf.input.accel_profile = NULL;  /* String property - set via Lua */
	globalconf.input.accel_speed = 0.0;
	globalconf.input.tap_button_map = NULL;  /* String property - set via Lua */

	/* Logging defaults (only set if not already set by -d flag) */
	if (globalconf.log_level == 0)
		globalconf.log_level = 1;  /* WLR_ERROR - can be changed via -d flag or awesome.log_level */

	kb_group = createkeyboardgroup();
	wl_list_init(&kb_group->destroy.link);

	output_mgr = wlr_output_manager_v1_create(dpy);
	wl_signal_add(&output_mgr->events.apply, &output_mgr_apply);
	wl_signal_add(&output_mgr->events.test, &output_mgr_test);

	/* Make sure XWayland clients don't connect to the parent X server,
	 * e.g when running in the x11 backend or the wayland backend and the
	 * compositor has Xwayland support */
	unsetenv("DISPLAY");
	/* Initialise the XWayland X server (no-op if XWAYLAND is not enabled).
	 * It will be started when the first X client is started. */
	xwayland_setup();

	luaA_init();

	/* Initialize animation subsystem (must be AFTER luaA_init for Lua state) */
	animation_init(event_loop);
	animation_setup(globalconf_get_lua_State());

	/* Initialize wallpaper cache (must be AFTER luaA_init which zeroes globalconf) */
	wallpaper_cache_init();

	/* Initialize D-Bus for notifications (AwesomeWM compatibility) */
	a_dbus_init();

	/* Initialize IPC socket for CLI commands */
	if (ipc_init(event_loop) < 0)
		fprintf(stderr, "Warning: Failed to initialize IPC socket\n");
}

void
spawn(const Arg *arg)
{
	if (fork() == 0) {
		dup2(STDERR_FILENO, STDOUT_FILENO);
		setsid();
		execvp(((char **)arg->v)[0], (char **)arg->v);
		die("somewm: execvp %s failed:", ((char **)arg->v)[0]);
	}
}


/* Search paths for Lua modules - set via -L/--search flag */
#define MAX_SEARCH_PATHS 16
static const char *search_paths[MAX_SEARCH_PATHS];
static int num_search_paths = 0;

/* Declared in luaa.c */
void luaA_add_search_paths(const char **paths, int count);
void luaA_set_confpath(const char *path);

/* Get distro name from /etc/os-release */
static const char *
get_distro_name(void)
{
	static char distro[256] = "unknown";
	char line[256];
	FILE *f;

	f = fopen("/etc/os-release", "r");
	if (!f)
		return distro;

	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
			char *start = line + 12;
			size_t len;
			/* Strip leading quote */
			if (*start == '"') start++;
			len = strlen(start);
			/* Strip trailing newline and quote */
			while (len > 0 && (start[len-1] == '\n' || start[len-1] == '"'))
				start[--len] = '\0';
			snprintf(distro, sizeof(distro), "%s", start);
			break;
		}
	}
	fclose(f);
	return distro;
}

/* Get GPU info from /sys/class/drm */
static const char *
get_gpu_info(void)
{
	static char gpu[256] = "unknown";
	char path[64];
	char line[128];
	char driver[64] = "";
	char pci_id[32] = "";
	FILE *f;
	int i;

	/* Try card0, card1, etc. */
	for (i = 0; i < 4; i++) {
		snprintf(path, sizeof(path), "/sys/class/drm/card%d/device/uevent", i);
		f = fopen(path, "r");
		if (!f)
			continue;

		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "DRIVER=", 7) == 0) {
				char *start = line + 7;
				size_t len = strlen(start);
				if (len > 0 && start[len-1] == '\n')
					start[len-1] = '\0';
				snprintf(driver, sizeof(driver), "%s", start);
			} else if (strncmp(line, "PCI_ID=", 7) == 0) {
				char *start = line + 7;
				size_t len = strlen(start);
				if (len > 0 && start[len-1] == '\n')
					start[len-1] = '\0';
				snprintf(pci_id, sizeof(pci_id), "%s", start);
			}
		}
		fclose(f);

		if (driver[0]) {
			snprintf(gpu, sizeof(gpu), "%s%s%s%s", driver,
				pci_id[0] ? " (" : "", pci_id,
				pci_id[0] ? ")" : "");
			break;
		}
	}
	return gpu;
}

/* Get Lua runtime version string */
static const char *
get_lua_runtime_version(lua_State *L)
{
	static char version[128];

	/* Check for LuaJIT first */
	lua_getglobal(L, "jit");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "version");
		if (lua_isstring(L, -1)) {
			snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
			lua_pop(L, 2);
			return version;
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	/* Fall back to standard Lua _VERSION */
	lua_getglobal(L, "_VERSION");
	if (lua_isstring(L, -1)) {
		snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
	} else {
		snprintf(version, sizeof(version), "unknown");
	}
	lua_pop(L, 1);
	return version;
}

/* Get LGI version */
static const char *
get_lgi_version(lua_State *L)
{
#ifdef LGI_VERSION
	/* Use compile-time detected version */
	(void)L;
	return LGI_VERSION;
#else
	/* Fallback to runtime detection */
	static char version[64] = "unknown";

	/* Try: require('lgi.version') */
	if (luaL_dostring(L, "return require('lgi.version')") == 0) {
		if (lua_isstring(L, -1)) {
			snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
		}
	}
	lua_pop(L, 1);
	return version;
#endif
}

/* Add search paths to a Lua state's package.path and package.cpath */
static void
add_search_paths_to_lua(lua_State *L, const char **paths, int count)
{
	const char *cur_path;

	for (int i = 0; i < count; i++) {
		const char *dir = paths[i];

		/* Add to package.path */
		lua_getglobal(L, "package");
		lua_getfield(L, -1, "path");
		cur_path = lua_tostring(L, -1);
		lua_pop(L, 1);
		lua_pushfstring(L, "%s/?.lua;%s/?/init.lua;%s", dir, dir, cur_path);
		lua_setfield(L, -2, "path");

		/* Add to package.cpath */
		lua_getfield(L, -1, "cpath");
		cur_path = lua_tostring(L, -1);
		lua_pop(L, 1);
		lua_pushfstring(L, "%s/?.so;%s", dir, cur_path);
		lua_setfield(L, -2, "cpath");

		lua_pop(L, 1); /* pop package table */
	}
}

/* Print comprehensive version info in markdown format */
static void
print_version_info(const char **paths, int num_paths)
{
	struct utsname uts;
	lua_State *L;
	const char *wayland_display, *xdg_session_type;
	int is_nested;

	/* Get kernel/arch info */
	if (uname(&uts) < 0) {
		strcpy(uts.sysname, "unknown");
		strcpy(uts.release, "unknown");
		strcpy(uts.machine, "unknown");
	}

	/* Create Lua state for version detection */
	L = luaL_newstate();
	luaL_openlibs(L);

	/* Apply any -L search paths so we can find lgi */
	if (num_paths > 0)
		add_search_paths_to_lua(L, paths, num_paths);

	/* Detect session environment */
	wayland_display = getenv("WAYLAND_DISPLAY");
	xdg_session_type = getenv("XDG_SESSION_TYPE");
	is_nested = (wayland_display != NULL);

	/* Print markdown-formatted version info */
	printf("## somewm version info\n\n");

	printf("**somewm:** %s (%s)\n", VERSION, COMMIT_DATE);
	printf("**wlroots:** %s\n", WLROOTS_VERSION);
	printf("**Lua:** %s (compiled: %s)\n", get_lua_runtime_version(L), LUA_RELEASE);
	printf("**LGI:** %s\n", get_lgi_version(L));

#ifdef WITH_DBUS
	printf("**Build:** D-Bus=yes");
#else
	printf("**Build:** D-Bus=no");
#endif
#ifdef XWAYLAND
	printf(", XWayland=yes\n");
#else
	printf(", XWayland=no\n");
#endif

	printf("\n**System:**\n");
	printf("- Distro: %s\n", get_distro_name());
	printf("- Kernel: %s\n", uts.release);
	printf("- Arch: %s\n", uts.machine);
	printf("- GPU: %s\n", get_gpu_info());
	printf("- Session: %s (nested: %s)\n",
		xdg_session_type ? xdg_session_type : "unknown",
		is_nested ? "yes" : "no");

	lua_close(L);
	exit(EXIT_SUCCESS);
}

/* ========================================================================
 * Test helpers — headless output hotplug simulation
 * ======================================================================== */

static struct wlr_backend *test_headless_backend;

static void
find_headless_cb(struct wlr_backend *b, void *data)
{
	if (wlr_backend_is_headless(b))
		*(struct wlr_backend **)data = b;
}

const char *
some_test_add_output(unsigned int width, unsigned int height)
{
	if (!test_headless_backend) {
		if (wlr_backend_is_headless(backend)) {
			test_headless_backend = backend;
		} else if (wlr_backend_is_multi(backend)) {
			/* Search for existing headless sub-backend */
			wlr_multi_for_each_backend(backend, find_headless_cb,
				&test_headless_backend);
			if (!test_headless_backend) {
				/* Create one and add it to the multi-backend */
				test_headless_backend =
					wlr_headless_backend_create(event_loop);
				if (!test_headless_backend)
					return NULL;
				wlr_multi_backend_add(backend,
					test_headless_backend);
				if (!wlr_backend_start(test_headless_backend))
					return NULL;
			}
		} else {
			return NULL;
		}
	}

	struct wlr_output *output =
		wlr_headless_add_output(test_headless_backend, width, height);
	if (!output)
		return NULL;

	return output->name;
}

/** Find liblgi_closure_guard.so by searching multiple paths.
 * Returns a pointer to a static buffer containing the path, or NULL. */
static const char *
find_lgi_guard(void)
{
	static char found[PATH_MAX];
	const char *name = "/liblgi_closure_guard.so";

	/* 1. Compiled-in libdir (fast path) */
	snprintf(found, sizeof(found), "%s%s", SOMEWM_LIBDIR, name);
	if (access(found, R_OK) == 0)
		return found;

	/* 2. Relative to the running binary (handles any prefix) */
	char self[PATH_MAX];
	ssize_t len = readlink("/proc/self/exe", self, sizeof(self) - 1);
	if (len > 0) {
		self[len] = '\0';
		/* Strip binary name to get bindir, then try ../lib, ../lib64,
		 * and bindir itself (for running directly from build/) */
		char *slash = strrchr(self, '/');
		if (slash) {
			*slash = '\0';
			const char *suffixes[] = { "/../lib", "/../lib64", "" };
			for (size_t i = 0; i < 3; i++) {
				int n = snprintf(found, sizeof(found), "%s%s%s",
					self, suffixes[i], name);
				if (n > 0 && (size_t)n < sizeof(found)
				    && access(found, R_OK) == 0)
					return found;
			}
		}
	}

	/* 3. Common system paths */
	const char *search[] = {
		"/usr/local/lib64", "/usr/local/lib",
		"/usr/lib64", "/usr/lib",
	};
	for (size_t i = 0; i < sizeof(search) / sizeof(search[0]); i++) {
		snprintf(found, sizeof(found), "%s%s", search[i], name);
		if (access(found, R_OK) == 0)
			return found;
	}

	return NULL;
}

/** Ensure the Lgi closure guard is loaded for safe hot-reload.
 * If the guard .so is installed but not yet preloaded, re-exec with
 * LD_PRELOAD so users never have to set it manually. */
static void
ensure_lgi_guard(int argc, char *argv[])
{
	/* Already loaded? */
	if (dlsym(RTLD_DEFAULT, "lgi_guard_bump_generation"))
		return;

	const char *guard_path = find_lgi_guard();
	if (!guard_path) {
		fprintf(stderr, "somewm: WARNING: liblgi_closure_guard.so not found, "
			"hot-reload may crash\n");
		return;
	}

	/* Prepend to LD_PRELOAD and re-exec */
	const char *existing = getenv("LD_PRELOAD");
	char buf[PATH_MAX + 256];
	if (existing && existing[0])
		snprintf(buf, sizeof(buf), "%s:%s", guard_path, existing);
	else
		snprintf(buf, sizeof(buf), "%s", guard_path);
	setenv("LD_PRELOAD", buf, 1);

	/* Suppress ASAN link-order complaint when guard is built without it */
	const char *asan_opts = getenv("ASAN_OPTIONS");
	if (asan_opts) {
		char asan_buf[4096];
		snprintf(asan_buf, sizeof(asan_buf), "%s:verify_asan_link_order=0", asan_opts);
		setenv("ASAN_OPTIONS", asan_buf, 1);
	} else {
		setenv("ASAN_OPTIONS", "verify_asan_link_order=0", 1);
	}

	execvp(argv[0], argv);
	/* If exec fails, continue without the guard */
}

int
main(int argc, char *argv[])
{
	ensure_lgi_guard(argc, argv);
	unsetenv("LD_PRELOAD");  /* Guard is loaded; don't leak to children */

	char *startup_cmd = NULL;
	char *check_config = NULL;
	int check_level = -1;  /* -1 = unset (default: warning) */
	int show_version = 0;
	int c;

	/* Store argv for restart capability (AwesomeWM API parity).
	 * Uses static storage in luaa.c so memset of globalconf can't clobber it. */
	luaA_set_argv(argv);

	const struct option long_options[] = {
		{"help",    no_argument,       0, 'h'},
		{"version", no_argument,       0, 'v'},
		{"verbose", no_argument,       0, 256},  /* info-level logging */
		{"debug",   no_argument,       0, 'd'},
		{"config",  required_argument, 0, 'c'},
		{"search",  required_argument, 0, 'L'},
		{"startup", required_argument, 0, 's'},
		{"check",       required_argument, 0, 'k'},
		{"check-level", required_argument, 0, 257},
		{0, 0, 0, 0}
	};

	while ((c = getopt_long(argc, argv, "c:s:L:hdvk:", long_options, NULL)) != -1) {
		switch (c) {
		case 'c':
			luaA_set_confpath(optarg);
			break;
		case 's':
			startup_cmd = optarg;
			break;
		case 'k':
			check_config = optarg;
			break;
		case 'L':
			if (num_search_paths < MAX_SEARCH_PATHS) {
				search_paths[num_search_paths++] = optarg;
			} else {
				fprintf(stderr, "Warning: too many search paths, ignoring %s\n", optarg);
			}
			break;
		case 'd':
			globalconf.log_level = 3;  /* WLR_DEBUG */
			break;
		case 256:  /* --verbose */
			globalconf.log_level = 2;  /* WLR_INFO */
			break;
		case 'v':
			show_version = 1;
			break;
		case 257:  /* --check-level */
			if (strcmp(optarg, "critical") == 0)
				check_level = 2;
			else if (strcmp(optarg, "warning") == 0)
				check_level = 1;
			else if (strcmp(optarg, "info") == 0)
				check_level = 0;
			else {
				fprintf(stderr, "Error: --check-level must be 'critical', 'warning', or 'info'\n");
				goto usage;
			}
			break;
		default:
			goto usage;
		}
	}
	if (optind < argc)
		goto usage;

	/* Show version after all args parsed so -L paths are available */
	if (show_version)
		print_version_info(search_paths, num_search_paths);

	/* Check mode: scan config for compatibility issues without starting compositor */
	if (check_config) {
		bool use_color = isatty(STDOUT_FILENO);
		int level = (check_level >= 0) ? check_level : 1;  /* default: warning */
		int result = luaA_check_config(check_config, use_color, level);
		return result;
	}

	/* Wayland requires XDG_RUNTIME_DIR for creating its communications socket */
	if (!getenv("XDG_RUNTIME_DIR"))
		die("XDG_RUNTIME_DIR must be set");

	/* Pass search paths to Lua init */
	if (num_search_paths > 0)
		luaA_add_search_paths(search_paths, num_search_paths);

	/* Store argc/argv in globalconf for hot-reload and debug logging */
	globalconf.argc = argc;
	globalconf.argv = argv;

	setup();
	run(startup_cmd);
	cleanup();
	return EXIT_SUCCESS;

usage:
	die("Usage: %s [-v] [-d] [--verbose] [-c config] [-L search_path] [-s startup_command] [-k config]\n"
	    "  -v, --version      Show version and diagnostic info\n"
	    "      --verbose      Enable info-level logging (more output)\n"
	    "  -d, --debug        Enable debug logging (maximum output)\n"
	    "  -c, --config FILE  Use specified config file (AwesomeWM compatible)\n"
	    "  -L, --search DIR   Add directory to Lua module search path\n"
	    "  -s, --startup CMD  Run command after startup\n"
	    "  -k, --check CONFIG       Check config for Wayland compatibility issues\n"
	    "      --check-level LEVEL   Minimum severity for non-zero exit: critical, warning (default), info", argv[0]);
}
