/*
 * See LICENSE file for copyright and license details.
 */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdbool.h>
#include <glib.h>
#include <libinput.h>
#include <linux/input-event-codes.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/libinput.h>
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
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_gamma_control_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_keyboard_group.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_output_power_management_v1.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_server_decoration.h>
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_virtual_pointer_v1.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <wlr/util/region.h>
#include <xkbcommon/xkbcommon.h>
#ifdef XWAYLAND
#include <wlr/xwayland.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>
#endif

#include "util.h"
#include "somewm_types.h"
#include "somewm_api.h"
#include "stack.h"
#include "wlr_compat.h"
#include "globalconf.h"        /* Global configuration structure (AwesomeWM pattern) */
#include "event.h"
#include "banning.h"            /* Client visibility management (banning) */
#include "objects/luaa.h"
#include "objects/spawn.h"  /* For spawn_child_exited */
#include "common/lualib.h"  /* For luaA_dumpstack */
#include "objects/signal.h"
#include "common/luaobject.h"  /* For luaA_object_emit_signal */
#include "objects/button.h"
#include "objects/drawin.h"
#include "objects/drawable.h"
#include "objects/screen.h"
#include "objects/tag.h"
#include "objects/keygrabber.h"
#include "objects/mousegrabber.h"
#include "objects/client.h"  /* AwesomeWM client_t (now aliased as Client) */
#include "objects/root.h"    /* Root button bindings */
#include "ewmh.h"            /* EWMH support for XWayland */
#include "property.h"         /* Property system for Wayland and XWayland */
#include "ipc.h"
#include "dbus.h"

/* macros */
/* MAX and MIN are defined in x11_compat.h (included via globalconf.h) */
#define CLEANMASK(mask)         (mask & ~WLR_MODIFIER_CAPS)
/* #define VISIBLEON(C, M)         ((M) && (C)->mon == (M) && ((C)->tags & (M)->tagset[(M)->seltags])) */
/* VISIBLEON macro replaced with client_on_selected_tags() for AwesomeWM compatibility */
#define LENGTH(X)               (sizeof X / sizeof X[0])

/* TAGCOUNT: Maximum tags supported (matches AwesomeWM limit of 32)
 * This is an architectural constant tied to uint32_t tag bitmasks.
 * Tags are created in Lua via awful.tag - this just defines the upper limit. */
#define TAGCOUNT (32)

/* TAGMASK: All bits set for TAGCOUNT tags. When TAGCOUNT=32, can't shift 1u<<32 (UB), use ~0u instead */
#define TAGMASK                 ((TAGCOUNT >= 32) ? ~0u : ((1u << TAGCOUNT) - 1))
#define LISTEN(E, L, H)         wl_signal_add((E), ((L)->notify = (H), (L)))
#define LISTEN_STATIC(E, H)     do { struct wl_listener *_l = ecalloc(1, sizeof(*_l)); _l->notify = (H); wl_signal_add((E), _l); } while (0)

/* Type definitions moved to somewm_types.h */

/* Tracked pointer device for runtime libinput configuration */
typedef struct {
	struct libinput_device *libinput_dev;
	struct wl_listener destroy;
	struct wl_list link;
} TrackedPointer;

/* function declarations */
static void applybounds(Client *c, struct wlr_box *bbox);
void arrange(Monitor *m);
static void arrangelayer(Monitor *m, struct wl_list *list,
		struct wlr_box *usable_area, int exclusive);
static void arrangelayers(Monitor *m);
static void axisnotify(struct wl_listener *listener, void *data);
static void buttonpress(struct wl_listener *listener, void *data);

/* Appearance helper functions */
static unsigned int get_border_width(void);
static const float *get_focuscolor(void);
static const float *get_bordercolor(void);
static const float *get_urgentcolor(void);

static void checkidleinhibitor(struct wlr_surface *exclude);
static void cleanup(void);
static void cleanupmon(struct wl_listener *listener, void *data);
static void cleanuplisteners(void);
static void closemon(Monitor *m);
static void commitlayersurfacenotify(struct wl_listener *listener, void *data);
void initialcommitnotify(struct wl_listener *listener, void *data);
void commitnotify(struct wl_listener *listener, void *data);
static void commitpopup(struct wl_listener *listener, void *data);
static void createdecoration(struct wl_listener *listener, void *data);
static void createidleinhibitor(struct wl_listener *listener, void *data);
static void createkeyboard(struct wlr_keyboard *keyboard);
static KeyboardGroup *createkeyboardgroup(void);
static void createlayersurface(struct wl_listener *listener, void *data);
static void createlocksurface(struct wl_listener *listener, void *data);
static void createmon(struct wl_listener *listener, void *data);
static void createnotify(struct wl_listener *listener, void *data);
static void createpointer(struct wlr_pointer *pointer);
static void createpointerconstraint(struct wl_listener *listener, void *data);
static void createpopup(struct wl_listener *listener, void *data);
static void cursorconstrain(struct wlr_pointer_constraint_v1 *constraint);
static void cursorframe(struct wl_listener *listener, void *data);
static void cursorwarptohint(void);
static void destroydecoration(struct wl_listener *listener, void *data);
static void destroydragicon(struct wl_listener *listener, void *data);
static void destroyidleinhibitor(struct wl_listener *listener, void *data);
static void destroylayersurfacenotify(struct wl_listener *listener, void *data);
static void destroylock(SessionLock *lock, int unlocked);
static void destroylocksurface(struct wl_listener *listener, void *data);
static void destroynotify(struct wl_listener *listener, void *data);
static void destroypointerconstraint(struct wl_listener *listener, void *data);
static void destroysessionlock(struct wl_listener *listener, void *data);
static void destroykeyboardgroup(struct wl_listener *listener, void *data);
static void destroytrackedpointer(struct wl_listener *listener, void *data);
Monitor *dirtomon(enum wlr_direction dir);
static void apply_input_settings_to_device(struct libinput_device *device);
void focusclient(Client *c, int lift);
void focusmon(const Arg *arg);
Client *focustop(Monitor *m);
static void fullscreennotify(struct wl_listener *listener, void *data);
static void foreign_toplevel_request_activate(struct wl_listener *listener, void *data);
static void foreign_toplevel_request_close(struct wl_listener *listener, void *data);
static void foreign_toplevel_request_fullscreen(struct wl_listener *listener, void *data);
static void foreign_toplevel_request_maximize(struct wl_listener *listener, void *data);
static void foreign_toplevel_request_minimize(struct wl_listener *listener, void *data);
static void gpureset(struct wl_listener *listener, void *data);
static void handlesig(int signo);
static void inputdevice(struct wl_listener *listener, void *data);
static int keybinding(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);
static void keypress(struct wl_listener *listener, void *data);
static void keypressmod(struct wl_listener *listener, void *data);
static int keyrepeat(void *data);
void killclient(const Arg *arg);
static void locksession(struct wl_listener *listener, void *data);
static void mapnotify(struct wl_listener *listener, void *data);
static void maximizenotify(struct wl_listener *listener, void *data);
void monocle(Monitor *m);
static void motionabsolute(struct wl_listener *listener, void *data);
static void motionnotify(uint32_t time, struct wlr_input_device *device, double sx,
		double sy, double sx_unaccel, double sy_unaccel);
static void motionrelative(struct wl_listener *listener, void *data);
/* moveresize() removed - move/resize now handled by Lua mousegrabber */
static void outputmgrapply(struct wl_listener *listener, void *data);
static void outputmgrapplyortest(struct wlr_output_configuration_v1 *config, int test);
static void outputmgrtest(struct wl_listener *listener, void *data);
static void pointerfocus(Client *c, struct wlr_surface *surface,
		double sx, double sy, uint32_t time);
void printstatus(void);
static void powermgrsetmode(struct wl_listener *listener, void *data);
static void rendermon(struct wl_listener *listener, void *data);
static void requestdecorationmode(struct wl_listener *listener, void *data);
static void requeststartdrag(struct wl_listener *listener, void *data);
static void requestmonstate(struct wl_listener *listener, void *data);
void resize(Client *c, struct wlr_box geo, int interact);
void apply_geometry_to_wlroots(Client *c);
static void client_geometry_refresh(void);
/* client_border_refresh() declared in objects/client.h */
static void some_refresh(void);
static void run(char *startup_cmd);
static void setcursor(struct wl_listener *listener, void *data);
static void setcursorshape(struct wl_listener *listener, void *data);
/* setfloating() removed - Lua manages floating state */
void setfullscreen(Client *c, int fullscreen);
void setlayout(const Arg *arg);
void setmon(Client *c, Monitor *m, uint32_t newtags);
static void setpsel(struct wl_listener *listener, void *data);
static void setsel(struct wl_listener *listener, void *data);
static void setup(void);
void spawn(const Arg *arg);
static void startdrag(struct wl_listener *listener, void *data);
void swapstack(const Arg *arg);
void tagmon(const Arg *arg);
void tile(Monitor *m);
void togglefloating(const Arg *arg);
static void unlocksession(struct wl_listener *listener, void *data);
static void unmaplayersurfacenotify(struct wl_listener *listener, void *data);
static void unmapnotify(struct wl_listener *listener, void *data);
static void updatemons(struct wl_listener *listener, void *data);
static void updatetitle(struct wl_listener *listener, void *data);
static void urgent(struct wl_listener *listener, void *data);
static void virtualkeyboard(struct wl_listener *listener, void *data);
static void virtualpointer(struct wl_listener *listener, void *data);
Monitor *xytomon(double x, double y);
void xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable, double *nx, double *ny);
void zoom(const Arg *arg);

/* variables */
static pid_t child_pid = -1;

static int locked;
int running = 1;  /* Non-static so somewm_api.c can access it */
static void *exclusive_focus;
struct wl_display *dpy;
struct wl_event_loop *event_loop;
static struct wlr_backend *backend;
struct wlr_scene *scene;
struct wlr_scene_tree *layers[NUM_LAYERS];
static struct wlr_scene_tree *drag_icon;
/* Map from ZWLR_LAYER_SHELL_* constants to Lyr* enum */
static const int layermap[] = { LyrBg, LyrBottom, LyrTop, LyrOverlay };
struct wlr_renderer *drw;
struct wlr_allocator *alloc;
static struct wlr_compositor *compositor;
static struct wlr_session *session;

static struct wlr_xdg_shell *xdg_shell;
struct wlr_xdg_activation_v1 *activation;

/* XDG Activation token tracking (Wayland startup notification) */
typedef struct {
	char *token;              /* XDG activation token string */
	char *app_id;             /* Application ID from spawn */
	uint32_t timeout_id;      /* GLib timeout source ID for cleanup */
} activation_token_t;

/* Deferred screen add for hotplug (matches AwesomeWM's screen_schedule_refresh pattern) */
typedef struct {
	screen_t *screen;
} deferred_screen_add_t;

/* Popup tracking structure for proper constraint handling */
typedef struct {
	struct wlr_xdg_popup *popup;
	struct wlr_scene_tree *root;  /* The toplevel's scene tree for coordinate calculation */
	struct wl_listener commit;
	struct wl_listener reposition;
	struct wl_listener destroy;
} Popup;

/* Pending activation tokens (matches AwesomeWM's sn_waits pattern) */
static activation_token_t *pending_tokens = NULL;
static size_t pending_tokens_len = 0;
static size_t pending_tokens_cap = 0;

/* Pipe for async SIGCHLD handling (AwesomeWM pattern) */
static int sigchld_pipe[2] = {-1, -1};
static struct wlr_xdg_decoration_manager_v1 *xdg_decoration_mgr;
static struct wlr_idle_notifier_v1 *idle_notifier;
static struct wlr_idle_inhibit_manager_v1 *idle_inhibit_mgr;
struct wlr_layer_shell_v1 *layer_shell;
static struct wlr_output_manager_v1 *output_mgr;
static struct wlr_virtual_keyboard_manager_v1 *virtual_keyboard_mgr;
static struct wlr_virtual_pointer_manager_v1 *virtual_pointer_mgr;
static struct wlr_cursor_shape_manager_v1 *cursor_shape_mgr;
static struct wlr_output_power_manager_v1 *power_mgr;
static struct wlr_foreign_toplevel_manager_v1 *foreign_toplevel_mgr;

static struct wlr_pointer_constraints_v1 *pointer_constraints;
static struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
static struct wlr_pointer_constraint_v1 *active_constraint;

struct wlr_cursor *cursor;
/* Non-static so mousegrabber.c can access it */
struct wlr_xcursor_manager *cursor_mgr;
/* Non-static so root.cursor() in root.c can change it */
char* selected_root_cursor;

static struct wlr_scene_rect *root_bg;
static struct wlr_session_lock_manager_v1 *session_lock_mgr;
static struct wlr_scene_rect *locked_bg;
static struct wlr_session_lock_v1 *cur_lock;

struct wlr_seat *seat;
KeyboardGroup *kb_group;
static unsigned int cursor_mode;
int new_client_placement = 0; /* 0 = master (default), 1 = slave */

struct wlr_output_layout *output_layout;
static struct wlr_box sgeom;
struct wl_list mons;
static struct wl_list tracked_pointers; /* For runtime libinput config */
Monitor *selmon;

/* global event handlers */
static struct wl_listener cursor_axis = {.notify = axisnotify};
static struct wl_listener cursor_button = {.notify = buttonpress};
static struct wl_listener cursor_frame = {.notify = cursorframe};
static struct wl_listener cursor_motion = {.notify = motionrelative};
static struct wl_listener cursor_motion_absolute = {.notify = motionabsolute};
static struct wl_listener gpu_reset = {.notify = gpureset};
static struct wl_listener layout_change = {.notify = updatemons};
static struct wl_listener new_idle_inhibitor = {.notify = createidleinhibitor};
static struct wl_listener new_input_device = {.notify = inputdevice};
static struct wl_listener new_virtual_keyboard = {.notify = virtualkeyboard};
static struct wl_listener new_virtual_pointer = {.notify = virtualpointer};
static struct wl_listener new_pointer_constraint = {.notify = createpointerconstraint};
static struct wl_listener new_output = {.notify = createmon};
static struct wl_listener new_xdg_toplevel = {.notify = createnotify};
static struct wl_listener new_xdg_popup = {.notify = createpopup};
static struct wl_listener new_xdg_decoration = {.notify = createdecoration};
static struct wl_listener new_layer_surface = {.notify = createlayersurface};
static struct wl_listener output_mgr_apply = {.notify = outputmgrapply};
static struct wl_listener output_mgr_test = {.notify = outputmgrtest};
static struct wl_listener output_power_mgr_set_mode = {.notify = powermgrsetmode};
static struct wl_listener request_activate = {.notify = urgent};
static struct wl_listener request_cursor = {.notify = setcursor};
static struct wl_listener request_set_psel = {.notify = setpsel};
static struct wl_listener request_set_sel = {.notify = setsel};
static struct wl_listener request_set_cursor_shape = {.notify = setcursorshape};
static struct wl_listener request_start_drag = {.notify = requeststartdrag};
static struct wl_listener start_drag = {.notify = startdrag};
static struct wl_listener new_session_lock = {.notify = locksession};

#ifdef XWAYLAND
static void activatex11(struct wl_listener *listener, void *data);
static void associatex11(struct wl_listener *listener, void *data);
static void configurex11(struct wl_listener *listener, void *data);
static void createnotifyx11(struct wl_listener *listener, void *data);
static void dissociatex11(struct wl_listener *listener, void *data);
static void sethints(struct wl_listener *listener, void *data);
static void xwaylandready(struct wl_listener *listener, void *data);
static struct wl_listener new_xwayland_surface = {.notify = createnotifyx11};
static struct wl_listener xwayland_ready = {.notify = xwaylandready};
static struct wlr_xwayland *xwayland;
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

/* function implementations */
void
applybounds(Client *c, struct wlr_box *bbox)
{
	/* set minimum possible */
	c->geometry.width = MAX(1 + 2 * (int)c->bw, c->geometry.width);
	c->geometry.height = MAX(1 + 2 * (int)c->bw, c->geometry.height);

	if (c->geometry.x >= bbox->x + bbox->width)
		c->geometry.x = bbox->x + bbox->width - c->geometry.width;
	if (c->geometry.y >= bbox->y + bbox->height)
		c->geometry.y = bbox->y + bbox->height - c->geometry.height;
	if (c->geometry.x + c->geometry.width <= bbox->x)
		c->geometry.x = bbox->x;
	if (c->geometry.y + c->geometry.height <= bbox->y)
		c->geometry.y = bbox->y;
}

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

/* Synchronize tiling order change (zoom operation) */
static void
sync_tiling_reorder(Client *c)
{
	/* Safety check: if arrays not initialized yet, skip sync */
	if (!globalconf.clients.tab) {
		return;
	}

	/* Remove from current position in clients list */
	foreach(elem, globalconf.clients) {
		if (*elem == c) {
			client_array_remove(&globalconf.clients, elem);
			break;
		}
	}

	/* Add to front of clients list (push = insert at position 0) */
	client_array_push(&globalconf.clients, c);

}

void
arrange(Monitor *m)
{
	lua_State *L;
	screen_t *screen;
	Client *c;

	if (!m || !m->wlr_output->enabled)
		return;

	/* Get Lua state */
	L = globalconf_get_lua_State();
	if (!L)
		return;

	/* WAYLAND-SPECIFIC: Always update scene node visibility, even during initialization.
	 * Unlike X11 where windows are visible by default, Wayland scene nodes start disabled.
	 * This MUST run before any early returns to ensure clients become visible. */
	foreach(client, globalconf.clients) {
		bool visible;
		c = *client;
		if (!c->mon || c->mon != m || !c->scene)
			continue;

		visible = client_on_selected_tags(c);
		wlr_scene_node_set_enabled(&c->scene->node, visible);
		client_set_suspended(c, !visible);
	}

	/* Safety check: if not initialized yet, skip Lua arrange but scene nodes are already updated */
	if (!globalconf.screens.tab) {
		return;
	}

	/* Find screen_t for this Monitor */
	screen = luaA_screen_get_by_monitor(L, m);
	if (!screen || !screen->valid) {
		return;
	}

	/* Call awful.layout.arrange(screen) in Lua */
	lua_getglobal(L, "awful");        /* Get awful module */
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		goto fallback;
	}

	lua_getfield(L, -1, "layout");    /* Get awful.layout */
	if (!lua_istable(L, -1)) {
		lua_pop(L, 2);
		goto fallback;
	}

	lua_getfield(L, -1, "arrange");   /* Get awful.layout.arrange */
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 3);
		goto fallback;
	}

	/* Push screen as argument */
	luaA_object_push(L, screen);

	/* Call awful.layout.arrange(screen) */
	if (lua_pcall(L, 1, 0, 0) != 0) {
		lua_pop(L, 1);
	}

	/* Clean up stack */
	lua_pop(L, 2);  /* Pop layout and awful */

fallback:
	/* Scene node visibility already updated at function start (Wayland-specific requirement) */

	/* Update fullscreen background */
	c = focustop(m);
	wlr_scene_node_set_enabled(&m->fullscreen_bg->node,
		c && c->fullscreen);

	motionnotify(0, NULL, 0, 0, 0, 0);
	checkidleinhibitor(NULL);
}

void
arrangelayer(Monitor *m, struct wl_list *list, struct wlr_box *usable_area, int exclusive)
{
	LayerSurface *l;
	struct wlr_box full_area = m->m;

	wl_list_for_each(l, list, link) {
		struct wlr_layer_surface_v1 *layer_surface = l->layer_surface;

		if (!layer_surface->initialized)
			continue;

		if (exclusive != (layer_surface->current.exclusive_zone > 0))
			continue;

		wlr_scene_layer_surface_v1_configure(l->scene_layer, &full_area, usable_area);
		wlr_scene_node_set_position(&l->popups->node, l->scene->node.x, l->scene->node.y);
	}
}

void
arrangelayers(Monitor *m)
{
	int i;
	struct wlr_box usable_area = m->m;
	LayerSurface *l;
	uint32_t layers_above_shell[] = {
		ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
		ZWLR_LAYER_SHELL_V1_LAYER_TOP,
	};
	if (!m->wlr_output->enabled)
		return;

	/* Arrange exclusive surfaces from top->bottom */
	for (i = 3; i >= 0; i--)
		arrangelayer(m, &m->layers[i], &usable_area, 1);

	/* Apply drawin struts (from Lua wibars) to the usable area
	 * This must happen AFTER layer shell exclusive zones but BEFORE setting m->w */
	some_monitor_apply_drawin_struts(m, &usable_area);

	if (!wlr_box_equal(&usable_area, &m->w)) {
		lua_State *L;
		screen_t *screen;

		m->w = usable_area;

		/* Update Lua screen.workarea property to match the new usable area
		 * This emits property::workarea signal so layouts get the correct workarea */
		L = globalconf_get_lua_State();
		if (L && globalconf.screens.tab) {
			screen = luaA_screen_get_by_monitor(L, m);
			if (screen) {
				luaA_screen_update_workarea(L, screen, &usable_area);
			}
		}

		arrange(m);
	}

	/* Arrange non-exlusive surfaces from top->bottom */
	for (i = 3; i >= 0; i--)
		arrangelayer(m, &m->layers[i], &usable_area, 0);

	/* Find topmost keyboard interactive layer, if such a layer exists */
	for (i = 0; i < (int)LENGTH(layers_above_shell); i++) {
		wl_list_for_each_reverse(l, &m->layers[layers_above_shell[i]], link) {
			if (locked || !l->layer_surface->current.keyboard_interactive || !l->mapped)
				continue;
			/* Deactivate the focused client. */
			focusclient(NULL, 0);
			exclusive_focus = l;
			client_notify_enter(l->layer_surface->surface, wlr_seat_get_keyboard(seat));
			return;
		}
	}
}

void
axisnotify(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits an axis event,
	 * for example when you move the scroll wheel. */
	struct wlr_pointer_axis_event *event = data;
	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);

	/* If mousegrabber is active, route event to Lua callback */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];

		/* Get current button states */
		some_get_button_states(button_states);

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, button_states);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further */
	}

	/* Handle scroll wheel for mousebindings (AwesomeWM compatibility)
	 * Convert axis events to X11-style button 4/5/6/7 press+release events.
	 * In X11, each scroll tick generates a button press+release pair. */
	if (!locked && event->delta != 0) {
		lua_State *L = globalconf_get_lua_State();
		struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
		uint32_t mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;
		Client *c = NULL;
		drawin_t *drawin = NULL;
		drawable_t *titlebar_drawable = NULL;
		uint32_t button;
		int rel_x, rel_y;

		/* Determine button number based on axis orientation and direction:
		 * Vertical: button 4 = scroll up (delta < 0), button 5 = scroll down (delta > 0)
		 * Horizontal: button 6 = scroll left (delta < 0), button 7 = scroll right (delta > 0) */
		if (event->orientation == WL_POINTER_AXIS_VERTICAL_SCROLL) {
			button = (event->delta < 0) ? 4 : 5;
		} else {
			button = (event->delta < 0) ? 6 : 7;
		}

		/* Find what's under the cursor */
		xytonode(cursor->x, cursor->y, NULL, &c, NULL, &drawin, &titlebar_drawable, NULL, NULL);

		if (drawin) {
			/* Scroll on drawin (wibox) */
			rel_x = (int)cursor->x - drawin->x;
			rel_y = (int)cursor->y - drawin->y;

			/* Emit press then release (scroll is instantaneous) */
			luaA_drawin_button_check(drawin, rel_x, rel_y, button, CLEANMASK(mods), true);
			luaA_drawin_button_check(drawin, rel_x, rel_y, button, CLEANMASK(mods), false);
		} else if (c && (!client_is_unmanaged(c) || client_wants_focus(c))) {
			/* Scroll on client */
			rel_x = (int)cursor->x - c->geometry.x;
			rel_y = (int)cursor->y - c->geometry.y;

			/* Emit on titlebar drawable if applicable */
			if (titlebar_drawable) {
				luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, button,
				                          CLEANMASK(mods), true);
				luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, button,
				                          CLEANMASK(mods), false);
			}

			/* Emit on client (press + release) */
			luaA_client_button_check(c, rel_x, rel_y, button, CLEANMASK(mods), true);
			luaA_client_button_check(c, rel_x, rel_y, button, CLEANMASK(mods), false);
		} else {
			/* Scroll on root/empty space */
			luaA_root_button_check(L, button, CLEANMASK(mods), cursor->x, cursor->y, true);
			luaA_root_button_check(L, button, CLEANMASK(mods), cursor->x, cursor->y, false);
		}
	}

	/* Notify the client with pointer focus of the axis event. */
	wlr_seat_pointer_notify_axis(seat,
			event->time_msec, event->orientation, event->delta,
			event->delta_discrete, event->source, event->relative_direction);
}

void
buttonpress(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_button_event *event = data;
	struct wlr_keyboard *keyboard;
	uint32_t mods;
	Client *c;

	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);

	/* Update globalconf button state tracking FIRST, before any early returns.
	 * This ensures mousegrabber callbacks receive accurate button states.
	 * Map wlroots button codes (BTN_LEFT=0x110, etc.) to indices 0-4.
	 */
	{
		int idx = -1;
		switch (event->button) {
		case 0x110: idx = 0; break;  /* BTN_LEFT -> button 1 */
		case 0x111: idx = 1; break;  /* BTN_RIGHT -> button 2 */
		case 0x112: idx = 2; break;  /* BTN_MIDDLE -> button 3 */
		case 0x113: idx = 3; break;  /* BTN_SIDE -> button 4 */
		case 0x114: idx = 4; break;  /* BTN_EXTRA -> button 5 */
		}
		if (idx >= 0) {
			globalconf.button_state.buttons[idx] =
				(event->state == WL_POINTER_BUTTON_STATE_PRESSED);
		}
	}

	/* If mousegrabber is active, route event to Lua callback */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];

		/* Get current button states */
		some_get_button_states(button_states);

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, button_states);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further */
	}

	switch (event->state) {
	case WL_POINTER_BUTTON_STATE_PRESSED: {
		Monitor *mon;
		drawin_t *drawin = NULL;
		drawable_t *titlebar_drawable = NULL;
		int rel_x, rel_y;

		cursor_mode = CurPressed;
		if (locked)
			break;

		/* Change focus if the button was _pressed_ over a client */
		xytonode(cursor->x, cursor->y, NULL, &c, NULL, &drawin, &titlebar_drawable, NULL, NULL);

		/* Get keyboard modifiers */
		keyboard = wlr_seat_get_keyboard(seat);
		mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;

		/* Check if a drawin was clicked */
		if (drawin) {
			/* Calculate drawin-relative coordinates */
			rel_x = (int)cursor->x - drawin->x;
			rel_y = (int)cursor->y - drawin->y;

			/* Check drawin-specific button array (AwesomeWM-compatible two-stage emission) */
			if (luaA_drawin_button_check(drawin, rel_x, rel_y, event->button,
			                             CLEANMASK(mods), true)) {
				return;
			}

			/* Fall back to global button check */
			if (luaA_button_check(CLEANMASK(mods), event->button)) {
				return;
			}
		} else if (c && (!client_is_unmanaged(c) || client_wants_focus(c))) {
			/* Calculate client-relative coordinates */
			rel_x = (int)cursor->x - c->geometry.x;
			rel_y = (int)cursor->y - c->geometry.y;

			/* If click is on a titlebar drawable, emit button signal on it
			 * This matches AwesomeWM's event.c:76-84 where they call event_emit_button on titlebar drawable */
			if (titlebar_drawable) {
				luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, event->button,
				                          CLEANMASK(mods), true);
			}

			/* Check client button array (AwesomeWM-compatible two-stage emission)
			 * This enables awful.mouse.client.move() and resize() to work via
			 * client button bindings defined in rc.lua
			 * Note: Unlike root/drawin handlers, we don't return early here.
			 * AwesomeWM always passes clicks through to clients (XCB_ALLOW_REPLAY_POINTER),
			 * so button bindings act as transparent observers, not consumers. */
			luaA_client_button_check(c, rel_x, rel_y, event->button,
			                        CLEANMASK(mods), true);
		}

		/* Check root button bindings (ONLY for empty space, not client clicks) */
		if (!c) {
			lua_State *L = globalconf_get_lua_State();

			/* Check root button bindings */
			if (luaA_root_button_check(L, event->button, CLEANMASK(mods),
			                           cursor->x, cursor->y, true) > 0) {
				/* Root button binding matched and handled */
				return;
			}

			/* No root binding matched - update selmon based on cursor position */
			mon = xytomon(cursor->x, cursor->y);
			if (mon && mon != selmon) {
				selmon = mon;
				/* Emit signal so Lua knows monitor changed */
				luaA_emit_signal_global("screen::focus");
			}
		}

		/* All button bindings are handled via Lua (AwesomeWM pattern) */
		if (luaA_button_check(CLEANMASK(mods), event->button)) {
			return;
		}
		break;
	}
	case WL_POINTER_BUTTON_STATE_RELEASED: {
		drawin_t *drawin = NULL;
		drawable_t *titlebar_drawable = NULL;

		/* NOTE: C-level move/resize exit handling removed - Lua mousegrabber handles this now */
		cursor_mode = CurNormal;

		/* Check if a drawin was released over */
		if (!locked) {
			xytonode(cursor->x, cursor->y, NULL, &c, NULL, &drawin, &titlebar_drawable, NULL, NULL);

			/* Get keyboard modifiers */
			keyboard = wlr_seat_get_keyboard(seat);
			mods = keyboard ? wlr_keyboard_get_modifiers(keyboard) : 0;

			if (drawin) {
				/* Calculate drawin-relative coordinates */
				int rel_x = (int)cursor->x - drawin->x;
				int rel_y = (int)cursor->y - drawin->y;

				/* Emit button release signals (AwesomeWM-compatible) */
				if (luaA_drawin_button_check(drawin, rel_x, rel_y, event->button,
				                             CLEANMASK(mods), false)) {
					return;
				}
			} else if (c) {
				/* Released on client - check client button bindings */
				int rel_x = (int)cursor->x - c->geometry.x;
				int rel_y = (int)cursor->y - c->geometry.y;

				/* If release is on a titlebar drawable, emit button signal on it */
				if (titlebar_drawable) {
					luaA_drawable_button_emit(c, titlebar_drawable, rel_x, rel_y, event->button,
					                          CLEANMASK(mods), false);
				}

				/* Emit button release signals on client (AwesomeWM-compatible)
				 * Like press events, releases are passed through to the client. */
				luaA_client_button_check(c, rel_x, rel_y, event->button,
				                        CLEANMASK(mods), false);
			} else {
				/* Released on empty space - check root button bindings */
				lua_State *L = globalconf_get_lua_State();

				/* Check root button bindings for release event */
				if (luaA_root_button_check(L, event->button, CLEANMASK(mods),
				                           cursor->x, cursor->y, false) > 0) {
					/* Root button release binding matched and handled */
					return;
				}
			}
		}
		break;
	}
	}

	/* Don't forward button event to client if mousegrabber started during
	 * Lua callback processing (e.g., awful.mouse.client.move() grabbed it).
	 * This ensures symmetric handling: if the press was consumed by starting
	 * a mousegrabber, the client never sees either press or release. */
	if (mousegrabber_isrunning()) {
		return;
	}

	/* If the event wasn't handled by the compositor, notify the client with
	 * pointer focus that a button press has occurred */
	wlr_seat_pointer_notify_button(seat,
			event->time_msec, event->button, event->state);
}

void
checkidleinhibitor(struct wlr_surface *exclude)
{
	int inhibited = 0, unused_lx, unused_ly;
	struct wlr_idle_inhibitor_v1 *inhibitor;
	wl_list_for_each(inhibitor, &idle_inhibit_mgr->inhibitors, link) {
		struct wlr_surface *surface = wlr_surface_get_root_surface(inhibitor->surface);
		struct wlr_scene_tree *tree = surface->data;
		if (exclude != surface && (globalconf.appearance.bypass_surface_visibility || (!tree
				|| wlr_scene_node_coords(&tree->node, &unused_lx, &unused_ly)))) {
			inhibited = 1;
			break;
		}
	}

	wlr_idle_notifier_v1_set_inhibited(idle_notifier, inhibited);
}

void
cleanup(void)
{
	/* Emit exit signal while Lua alive (matches AwesomeWM pattern) */
	if (globalconf_L) {
		luaA_emit_signal_global("exit");
	}

	a_dbus_cleanup();
	ipc_cleanup();
	cleanuplisteners();

	/* Destroy Wayland clients while Lua is still alive so signal handlers work. */
	wl_display_destroy_clients(dpy);

	/* Close Lua after clients are destroyed (matches AwesomeWM pattern) */
	luaA_cleanup();

	/* Cleanup startup_errors buffer */
	buffer_wipe(&globalconf.startup_errors);

	/* Cleanup x11_fallback info */
	free(globalconf.x11_fallback.config_path);
	free(globalconf.x11_fallback.pattern_desc);
	free(globalconf.x11_fallback.suggestion);
	free(globalconf.x11_fallback.line_content);

#ifdef XWAYLAND
	if (xwayland) {
		wlr_xwayland_destroy(xwayland);
		xwayland = NULL;
	}
#endif

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
cleanupmon(struct wl_listener *listener, void *data)
{
	Monitor *m = wl_container_of(listener, m, destroy);
	LayerSurface *l, *tmp;
	size_t i;

	/* Find and remove screen BEFORE destroying monitor data (AwesomeWM pattern)
	 * This emits instance-level "removed" signal and relocates clients.
	 * Also emit viewports and primary_changed signals as needed. */
	if (globalconf_L) {
		screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
		if (screen) {
			/* Check if this screen was the primary before removing it */
			screen_t *old_primary = luaA_screen_get_primary_screen(globalconf_L);
			bool was_primary = (old_primary == screen);

			luaA_screen_removed(globalconf_L, screen);
			luaA_screen_emit_viewports(globalconf_L);

			/* If removed screen was primary, emit primary_changed on new primary */
			if (was_primary) {
				screen_t *new_primary = luaA_screen_get_primary_screen(globalconf_L);
				if (new_primary && new_primary != screen) {
					luaA_screen_emit_primary_changed(globalconf_L, new_primary);
				}
			}
		}
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
	wlr_output_layout_remove(output_layout, m->wlr_output);
	wlr_scene_output_destroy(m->scene_output);

	closemon(m);
	wlr_scene_node_destroy(&m->fullscreen_bg->node);
	free(m);
}

void
cleanuplisteners(void)
{
	wl_list_remove(&cursor_axis.link);
	wl_list_remove(&cursor_button.link);
	wl_list_remove(&cursor_frame.link);
	wl_list_remove(&cursor_motion.link);
	wl_list_remove(&cursor_motion_absolute.link);
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
#ifdef XWAYLAND
	wl_list_remove(&new_xwayland_surface.link);
	wl_list_remove(&xwayland_ready.link);
#endif
}

void
closemon(Monitor *m)
{
	/* update selmon if needed and
	 * move closed monitor's clients to the focused one */
	Client *c;
	int i = 0, nmons = wl_list_length(&mons);
	if (!nmons) {
		selmon = NULL;
	} else if (m == selmon) {
		do /* don't switch to disabled mons */
			selmon = wl_container_of(mons.next, selmon, link);
		while (!selmon->wlr_output->enabled && i++ < nmons);

		if (!selmon->wlr_output->enabled)
			selmon = NULL;
	}

	foreach(client, globalconf.clients) {
		c = *client;
		if (some_client_get_floating(c) && c->geometry.x > m->m.width)
			resize(c, (struct wlr_box){.x = c->geometry.x - m->w.width, .y = c->geometry.y,
					.width = c->geometry.width, .height = c->geometry.height}, 0);
		if (c->mon == m)
			setmon(c, selmon, 0);
	}
	focusclient(focustop(selmon), 1);
	printstatus();
}

void
commitlayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, surface_commit);
	struct wlr_layer_surface_v1 *layer_surface = l->layer_surface;
	struct wlr_scene_tree *scene_layer = layers[layermap[layer_surface->current.layer]];
	struct wlr_layer_surface_v1_state old_state;

	if (l->layer_surface->initial_commit) {
		client_set_scale(layer_surface->surface, l->mon->wlr_output->scale);

		/* Temporarily set the layer's current state to pending
		 * so that we can easily arrange it */
		old_state = l->layer_surface->current;
		l->layer_surface->current = l->layer_surface->pending;
		arrangelayers(l->mon);
		l->layer_surface->current = old_state;
		return;
	}

	if (layer_surface->current.committed == 0 && l->mapped == layer_surface->surface->mapped)
		return;
	l->mapped = layer_surface->surface->mapped;

	if (scene_layer != l->scene->node.parent) {
		wlr_scene_node_reparent(&l->scene->node, scene_layer);
		wl_list_remove(&l->link);
		wl_list_insert(&l->mon->layers[layer_surface->current.layer], &l->link);
		wlr_scene_node_reparent(&l->popups->node, (layer_surface->current.layer
				< ZWLR_LAYER_SHELL_V1_LAYER_TOP ? layers[LyrTop] : scene_layer));
	}

	arrangelayers(l->mon);
}

/* Handle initial XDG commit - sets scale, capabilities, size.
 * This listener is registered in createnotify before wlr_scene_xdg_surface_create. */
void
initialcommitnotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, initial_commit);
	Monitor *m;

	if (!c->surface.xdg->initial_commit)
		return;

	/* Get the monitor this client will be rendered on for initial scale setting.
	 * Final monitor/tags will be determined by Lua rules in mapnotify(). */
	m = c->mon ? c->mon : selmon;
	if (m) {
		client_set_scale(client_surface(c), m->wlr_output->scale);
	}

	wlr_xdg_toplevel_set_wm_capabilities(c->surface.xdg->toplevel,
			WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN);
	if (c->decoration)
		requestdecorationmode(&c->set_decoration_mode, c->decoration);
	wlr_xdg_toplevel_set_size(c->surface.xdg->toplevel, 0, 0);
}

/* Handle subsequent XDG commits - resizing and opacity.
 * This listener is registered in mapnotify AFTER wlr_scene_xdg_surface_create
 * so it fires AFTER wlroots' internal surface_reconfigure() which resets opacity. */
void
commitnotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, commit);

	/* Skip initial commit - handled by initialcommitnotify */
	if (c->surface.xdg->initial_commit)
		return;

	resize(c, c->geometry, (some_client_get_floating(c) && !c->fullscreen));

	/* mark a pending resize as completed */
	if (c->resize && c->resize <= c->surface.xdg->current.configure_serial)
		c->resize = 0;

	/* Re-apply opacity after wlroots' surface_reconfigure() resets it to 1.0.
	 * Our listener fires after wlroots' because we registered it after
	 * wlr_scene_xdg_surface_create() in mapnotify(). */
	if (c->opacity >= 0)
		client_apply_opacity_to_scene(c, (float)c->opacity);
}

/* Unconstrain popup using proper scene node coordinates (River pattern) */
void
popup_unconstrain(Popup *p)
{
	LayerSurface *l = NULL;
	Client *c = NULL;
	struct wlr_box box;
	int root_lx, root_ly;
	int type;

	if (!p->root)
		return;

	type = toplevel_from_wlr_surface(p->popup->base->surface, &c, &l);
	if (type < 0)
		return;

	/* Get the output box */
	if (type == LayerShell) {
		if (!l || !l->mon)
			return;
		box = l->mon->m;
	} else {
		if (!c || !c->mon)
			return;
		box = c->mon->w;
	}

	/* Get global coordinates of the popup root scene tree */
	if (!wlr_scene_node_coords(&p->root->node, &root_lx, &root_ly))
		return;

	/* Convert output box to popup-relative coordinates */
	box.x -= root_lx;
	box.y -= root_ly;

	wlr_xdg_popup_unconstrain_from_box(p->popup, &box);
}

void
repositionpopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, reposition);
	popup_unconstrain(p);
}

void
destroypopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, destroy);
	wl_list_remove(&p->commit.link);
	wl_list_remove(&p->reposition.link);
	wl_list_remove(&p->destroy.link);
	free(p);
}

void
commitpopup(struct wl_listener *listener, void *data)
{
	Popup *p = wl_container_of(listener, p, commit);
	LayerSurface *l = NULL;
	Client *c = NULL;
	int type;

	if (!p->popup->base->initial_commit)
		return;

	type = toplevel_from_wlr_surface(p->popup->base->surface, &c, &l);
	if (!p->popup->parent || type < 0)
		return;

	/* Create scene surface for popup */
	p->popup->base->surface->data = wlr_scene_xdg_surface_create(
			p->popup->parent->data, p->popup->base);

	if ((l && !l->mon) || (c && !c->mon)) {
		wlr_xdg_popup_destroy(p->popup);
		return;
	}

	/* Set root scene tree for coordinate calculation */
	p->root = (type == LayerShell) ? l->popups : c->scene_surface;

	/* Apply initial constraint */
	popup_unconstrain(p);
}

void
createdecoration(struct wl_listener *listener, void *data)
{
	struct wlr_xdg_toplevel_decoration_v1 *deco = data;
	Client *c = deco->toplevel->base->data;
	c->decoration = deco;

	LISTEN(&deco->events.request_mode, &c->set_decoration_mode, requestdecorationmode);
	LISTEN(&deco->events.destroy, &c->destroy_decoration, destroydecoration);

	requestdecorationmode(&c->set_decoration_mode, deco);
}

void
createidleinhibitor(struct wl_listener *listener, void *data)
{
	struct wlr_idle_inhibitor_v1 *idle_inhibitor = data;
	LISTEN_STATIC(&idle_inhibitor->events.destroy, destroyidleinhibitor);

	checkidleinhibitor(NULL);
}

void
createkeyboard(struct wlr_keyboard *keyboard)
{
	/* Set the keymap to match the group keymap */
	wlr_keyboard_set_keymap(keyboard, kb_group->wlr_group->keyboard.keymap);

	/* Add the new keyboard to the group */
	wlr_keyboard_group_add_keyboard(kb_group->wlr_group, keyboard);
}

KeyboardGroup *
createkeyboardgroup(void)
{
	KeyboardGroup *group = ecalloc(1, sizeof(*group));
	struct xkb_context *context;
	struct xkb_keymap *keymap;
	struct xkb_rule_names rules;

	group->wlr_group = wlr_keyboard_group_create();
	group->wlr_group->data = group;

	/* Prepare an XKB keymap and assign it to the keyboard group. */
	context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

	/* Build XKB rules from globalconf (set via Lua or defaults) */
	rules.layout = globalconf.keyboard.xkb_layout;
	rules.variant = globalconf.keyboard.xkb_variant;
	rules.options = globalconf.keyboard.xkb_options;
	rules.rules = NULL;
	rules.model = NULL;

	if (!(keymap = xkb_keymap_new_from_names(context, &rules,
				XKB_KEYMAP_COMPILE_NO_FLAGS)))
		die("failed to compile keymap");

	wlr_keyboard_set_keymap(&group->wlr_group->keyboard, keymap);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);

	wlr_keyboard_set_repeat_info(&group->wlr_group->keyboard,
		globalconf.keyboard.repeat_rate, globalconf.keyboard.repeat_delay);

	/* Set up listeners for keyboard events */
	LISTEN(&group->wlr_group->keyboard.events.key, &group->key, keypress);
	LISTEN(&group->wlr_group->keyboard.events.modifiers, &group->modifiers, keypressmod);

	group->key_repeat_source = wl_event_loop_add_timer(event_loop, keyrepeat, group);

	/* A seat can only have one keyboard, but this is a limitation of the
	 * Wayland protocol - not wlroots. We assign all connected keyboards to the
	 * same wlr_keyboard_group, which provides a single wlr_keyboard interface for
	 * all of them. Set this combined wlr_keyboard as the seat keyboard.
	 */
	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	return group;
}

void
createlayersurface(struct wl_listener *listener, void *data)
{
	struct wlr_layer_surface_v1 *layer_surface = data;
	LayerSurface *l;
	struct wlr_surface *surface = layer_surface->surface;
	struct wlr_scene_tree *scene_layer = layers[layermap[layer_surface->pending.layer]];

	if (!layer_surface->output
			&& !(layer_surface->output = selmon ? selmon->wlr_output : NULL)) {
		wlr_layer_surface_v1_destroy(layer_surface);
		return;
	}

	l = layer_surface->data = ecalloc(1, sizeof(*l));
	l->type = LayerShell;
	LISTEN(&surface->events.commit, &l->surface_commit, commitlayersurfacenotify);
	LISTEN(&surface->events.unmap, &l->unmap, unmaplayersurfacenotify);
	LISTEN(&layer_surface->events.destroy, &l->destroy, destroylayersurfacenotify);

	l->layer_surface = layer_surface;
	l->mon = layer_surface->output->data;
	l->scene_layer = wlr_scene_layer_surface_v1_create(scene_layer, layer_surface);
	l->scene = l->scene_layer->tree;
	l->popups = surface->data = wlr_scene_tree_create(layer_surface->current.layer
			< ZWLR_LAYER_SHELL_V1_LAYER_TOP ? layers[LyrTop] : scene_layer);
	l->scene->node.data = l->popups->node.data = l;

	wl_list_insert(&l->mon->layers[layer_surface->pending.layer],&l->link);
	wlr_surface_send_enter(surface, layer_surface->output);
}

void
createlocksurface(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, new_surface);
	struct wlr_session_lock_surface_v1 *lock_surface = data;
	Monitor *m = lock_surface->output->data;
	struct wlr_scene_tree *scene_tree = lock_surface->surface->data
			= wlr_scene_subsurface_tree_create(lock->scene, lock_surface->surface);
	m->lock_surface = lock_surface;

	wlr_scene_node_set_position(&scene_tree->node, m->m.x, m->m.y);
	wlr_session_lock_surface_v1_configure(lock_surface, m->m.width, m->m.height);

	LISTEN(&lock_surface->events.destroy, &m->destroy_lock_surface, destroylocksurface);

	if (m == selmon)
		client_notify_enter(lock_surface->surface, wlr_seat_get_keyboard(seat));
}

/* Idle callback for deferred screen signal emission (AwesomeWM pattern).
 * This is called after the wlroots output event handler returns, when it's
 * safe to do complex Lua operations like creating wibars. */
static void
screen_added_idle(void *data)
{
	deferred_screen_add_t *d = data;
	screen_t *screen = d->screen;

	if (screen && screen->valid) {
		screen_t *old_primary = luaA_screen_get_primary_screen(globalconf_L);
		screen_t *new_primary;

		luaA_screen_added(globalconf_L, screen);
		luaA_screen_emit_list(globalconf_L);
		luaA_screen_emit_viewports(globalconf_L);

		new_primary = luaA_screen_get_primary_screen(globalconf_L);
		if (new_primary == screen && old_primary != screen) {
			luaA_screen_emit_primary_changed(globalconf_L, screen);
		}

		banning_refresh();
		some_refresh();
	}

	free(d);
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
	if (m->m.x == -1 && m->m.y == -1)
		wlr_output_layout_add_auto(output_layout, wlr_output);
	else
		wlr_output_layout_add(output_layout, wlr_output, m->m.x, m->m.y);

	/* Create screen object and emit signals.
	 * During startup: signal emission is deferred to luaA_screen_emit_all_added()
	 * During runtime (hotplug): emit _added immediately so wibar/tags are created */
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
			 * Defer signal emission to idle callback (AwesomeWM pattern).
			 * We can't emit signals directly from wlroots output event callback
			 * because complex Lua operations (wibar creation) may fail. */
			if (luaA_screen_scanned_done()) {
				deferred_screen_add_t *d = malloc(sizeof(*d));
				if (d) {
					d->screen = screen;
					wl_event_loop_add_idle(
						wl_display_get_event_loop(dpy),
						screen_added_idle,
						d);
				}
			}
		}
	}
}

void
createnotify(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client creates a new toplevel (application window).
	 *
	 * This function follows AwesomeWM's client_manage() pattern (first half):
	 * 1. Create Lua client object with client_new(L)
	 * 2. Link to protocol surface (Wayland XDG shell vs X11 window)
	 * 3. Register protocol event listeners
	 * 4. Add client to global clients array
	 * 5. Emit client::list signal
	 * 6. DO NOT emit manage signal yet - that happens in mapnotify()
	 */
	struct wlr_xdg_toplevel *toplevel = data;
	Client *c = NULL;
	lua_State *L;

	L = globalconf_get_lua_State();

	/* Create Lua client object (matches AwesomeWM client_manage line 2138) */
	c = client_new(L);
	/* client_new() leaves the client on the Lua stack at index -1 */

	/* Initialize opacity to -1 (unset) so commitnotify doesn't apply 0% opacity.
	 * -1 means "use default" (fully opaque). 0 would mean fully transparent. */
	c->opacity = -1;

	/* Link to Wayland surface (adapts X11 window linkage to Wayland) */
	toplevel->base->data = c;
	c->surface.xdg = toplevel->base;
	c->client_type = XDGShell;
	c->bw = get_border_width();

	/* Register Wayland event listeners (adapts X11 event masks to Wayland signals)
	 * Note: The main commit listener is registered in mapnotify() AFTER wlr_scene_xdg_surface_create()
	 * so our listener fires AFTER wlroots' internal surface_reconfigure() which resets opacity.
	 * We use a separate listener for the initial commit to handle pre-map setup. */
	LISTEN(&toplevel->base->surface->events.commit, &c->initial_commit, initialcommitnotify);
	LISTEN(&toplevel->base->surface->events.map, &c->map, mapnotify);
	LISTEN(&toplevel->base->surface->events.unmap, &c->unmap, unmapnotify);
	LISTEN(&toplevel->events.destroy, &c->destroy, destroynotify);
	LISTEN(&toplevel->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
	LISTEN(&toplevel->events.request_maximize, &c->maximize, maximizenotify);
	LISTEN(&toplevel->events.set_title, &c->set_title, updatetitle);

	/* Note: property_register_wayland_listeners() is called in mapnotify() after
	 * the client is fully registered in Lua. Calling it here would fail because
	 * luaA_object_push() can't find the client reference yet. */

	/* Add to global clients array (matches AwesomeWM client_manage line 2202)
	 * Duplicate client on stack, then take a reference for the array */
	lua_pushvalue(L, -1);
	client_array_push(&globalconf.clients, luaA_object_ref(L, -1));

	/* Add to stack (matches AwesomeWM client_manage) */
	stack_client_push(c);

	/* Emit client::list signal (matches AwesomeWM line 2266) */
	luaA_class_emit_signal(L, &client_class, "list", 0);

	/* Keep client on Lua stack - it will be used by mapnotify() later
	 * DO NOT emit manage signal here - AwesomeWM emits it at end of client_manage,
	 * which corresponds to our mapnotify() event (when the window is actually mapped) */
	lua_pop(L, 1);
}

/* Apply all input settings from globalconf to a single libinput device */
static void
apply_input_settings_to_device(struct libinput_device *device)
{
	if (libinput_device_config_tap_get_finger_count(device)) {
		/* Apply tap settings from globalconf (-1 = device default, don't set) */
		if (globalconf.input.tap_to_click >= 0)
			libinput_device_config_tap_set_enabled(device, globalconf.input.tap_to_click);
		if (globalconf.input.tap_and_drag >= 0)
			libinput_device_config_tap_set_drag_enabled(device, globalconf.input.tap_and_drag);
		if (globalconf.input.drag_lock >= 0)
			libinput_device_config_tap_set_drag_lock_enabled(device, globalconf.input.drag_lock);

		/* Convert tap_button_map string to enum */
		if (globalconf.input.tap_button_map) {
			enum libinput_config_tap_button_map map = LIBINPUT_CONFIG_TAP_MAP_LRM;
			if (strcmp(globalconf.input.tap_button_map, "lmr") == 0)
				map = LIBINPUT_CONFIG_TAP_MAP_LMR;
			libinput_device_config_tap_set_button_map(device, map);
		}
	}

	if (libinput_device_config_scroll_has_natural_scroll(device)
			&& globalconf.input.natural_scrolling >= 0)
		libinput_device_config_scroll_set_natural_scroll_enabled(device,
			globalconf.input.natural_scrolling);

	if (libinput_device_config_dwt_is_available(device)
			&& globalconf.input.disable_while_typing >= 0)
		libinput_device_config_dwt_set_enabled(device,
			globalconf.input.disable_while_typing);

	if (libinput_device_config_left_handed_is_available(device)
			&& globalconf.input.left_handed >= 0)
		libinput_device_config_left_handed_set(device,
			globalconf.input.left_handed);

	if (libinput_device_config_middle_emulation_is_available(device)
			&& globalconf.input.middle_button_emulation >= 0)
		libinput_device_config_middle_emulation_set_enabled(device,
			globalconf.input.middle_button_emulation);

	/* Convert scroll_method string to enum */
	if (libinput_device_config_scroll_get_methods(device) != LIBINPUT_CONFIG_SCROLL_NO_SCROLL
			&& globalconf.input.scroll_method) {
		enum libinput_config_scroll_method method = LIBINPUT_CONFIG_SCROLL_2FG;
		if (strcmp(globalconf.input.scroll_method, "no_scroll") == 0)
			method = LIBINPUT_CONFIG_SCROLL_NO_SCROLL;
		else if (strcmp(globalconf.input.scroll_method, "two_finger") == 0)
			method = LIBINPUT_CONFIG_SCROLL_2FG;
		else if (strcmp(globalconf.input.scroll_method, "edge") == 0)
			method = LIBINPUT_CONFIG_SCROLL_EDGE;
		else if (strcmp(globalconf.input.scroll_method, "button") == 0)
			method = LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN;
		libinput_device_config_scroll_set_method(device, method);
	}

	/* Convert click_method string to enum */
	if (libinput_device_config_click_get_methods(device) != LIBINPUT_CONFIG_CLICK_METHOD_NONE
			&& globalconf.input.click_method) {
		enum libinput_config_click_method method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
		if (strcmp(globalconf.input.click_method, "none") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_NONE;
		else if (strcmp(globalconf.input.click_method, "button_areas") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
		else if (strcmp(globalconf.input.click_method, "clickfinger") == 0)
			method = LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER;
		libinput_device_config_click_set_method(device, method);
	}

	/* Convert send_events_mode string to enum */
	if (libinput_device_config_send_events_get_modes(device)
			&& globalconf.input.send_events_mode) {
		uint32_t mode = LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
		if (strcmp(globalconf.input.send_events_mode, "disabled") == 0)
			mode = LIBINPUT_CONFIG_SEND_EVENTS_DISABLED;
		else if (strcmp(globalconf.input.send_events_mode, "disabled_on_external_mouse") == 0)
			mode = LIBINPUT_CONFIG_SEND_EVENTS_DISABLED_ON_EXTERNAL_MOUSE;
		libinput_device_config_send_events_set_mode(device, mode);
	}

	/* Convert accel_profile string to enum and apply accel_speed */
	if (libinput_device_config_accel_is_available(device)) {
		if (globalconf.input.accel_profile) {
			enum libinput_config_accel_profile profile = LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
			if (strcmp(globalconf.input.accel_profile, "flat") == 0)
				profile = LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT;
			libinput_device_config_accel_set_profile(device, profile);
		}
		libinput_device_config_accel_set_speed(device, globalconf.input.accel_speed);
	}
}

/* Apply input settings to all tracked pointer devices */
void
apply_input_settings_to_all_devices(void)
{
	TrackedPointer *tp;
	wl_list_for_each(tp, &tracked_pointers, link) {
		apply_input_settings_to_device(tp->libinput_dev);
	}
}

void
createpointer(struct wlr_pointer *pointer)
{
	struct libinput_device *device;
	TrackedPointer *tp;

	if (wlr_input_device_is_libinput(&pointer->base)
			&& (device = wlr_libinput_get_device_handle(&pointer->base))) {

		/* Apply settings from globalconf */
		apply_input_settings_to_device(device);

		/* Track this device for runtime reconfiguration */
		tp = ecalloc(1, sizeof(*tp));
		tp->libinput_dev = device;
		wl_list_insert(&tracked_pointers, &tp->link);
		LISTEN(&pointer->base.events.destroy, &tp->destroy, destroytrackedpointer);
	}

	wlr_cursor_attach_input_device(cursor, &pointer->base);
}

void
createpointerconstraint(struct wl_listener *listener, void *data)
{
	struct wlr_pointer_constraint_v1 *constraint = data;
	PointerConstraint *pointer_constraint = ecalloc(1, sizeof(*pointer_constraint));
	pointer_constraint->constraint = constraint;
	LISTEN(&pointer_constraint->constraint->events.destroy,
			&pointer_constraint->destroy, destroypointerconstraint);

	/* If this constraint's surface already has keyboard focus, activate it */
	if (constraint->surface == seat->keyboard_state.focused_surface)
		cursorconstrain(constraint);
}

void
createpopup(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client (either xdg-shell or layer-shell)
	 * creates a new popup. */
	struct wlr_xdg_popup *popup = data;
	Popup *p = ecalloc(1, sizeof(*p));

	p->popup = popup;
	p->root = NULL;  /* Set in commitpopup after finding toplevel */

	LISTEN(&popup->base->surface->events.commit, &p->commit, commitpopup);
	LISTEN(&popup->events.reposition, &p->reposition, repositionpopup);
	LISTEN(&popup->events.destroy, &p->destroy, destroypopup);
}

void
cursorconstrain(struct wlr_pointer_constraint_v1 *constraint)
{
	if (active_constraint == constraint)
		return;

	if (active_constraint)
		wlr_pointer_constraint_v1_send_deactivated(active_constraint);

	active_constraint = constraint;

	if (active_constraint)
		wlr_pointer_constraint_v1_send_activated(active_constraint);
}

void
cursorframe(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits a frame
	 * event. Frame events are sent after regular pointer events to group
	 * multiple events together. For instance, two axis events may happen at the
	 * same time, in which case a frame event won't be sent in between. */
	/* Notify the client with pointer focus of the frame event. */
	wlr_seat_pointer_notify_frame(seat);
}

void
cursorwarptohint(void)
{
	Client *c = NULL;
	double sx = active_constraint->current.cursor_hint.x;
	double sy = active_constraint->current.cursor_hint.y;

	toplevel_from_wlr_surface(active_constraint->surface, &c, NULL);
	if (c && active_constraint->current.cursor_hint.enabled) {
		wlr_cursor_warp(cursor, NULL, sx + c->geometry.x + c->bw, sy + c->geometry.y + c->bw);
		wlr_seat_pointer_warp(active_constraint->seat, sx, sy);
	}
}

void
destroydecoration(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, destroy_decoration);

	wl_list_remove(&c->destroy_decoration.link);
	wl_list_remove(&c->set_decoration_mode.link);
}

void
destroydragicon(struct wl_listener *listener, void *data)
{
	/* Focus enter isn't sent during drag, so refocus the focused node. */
	focusclient(focustop(selmon), 1);
	motionnotify(0, NULL, 0, 0, 0, 0);
	wl_list_remove(&listener->link);
	free(listener);
}

void
destroyidleinhibitor(struct wl_listener *listener, void *data)
{
	/* `data` is the wlr_surface of the idle inhibitor being destroyed,
	 * at this point the idle inhibitor is still in the list of the manager */
	checkidleinhibitor(wlr_surface_get_root_surface(data));
	wl_list_remove(&listener->link);
	free(listener);
}

void
destroylayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, destroy);

	wl_list_remove(&l->link);
	wl_list_remove(&l->destroy.link);
	wl_list_remove(&l->unmap.link);
	wl_list_remove(&l->surface_commit.link);
	wlr_scene_node_destroy(&l->scene->node);
	wlr_scene_node_destroy(&l->popups->node);
	free(l);
}

void
destroylock(SessionLock *lock, int unlock)
{
	wlr_seat_keyboard_notify_clear_focus(seat);
	if ((locked = !unlock))
		goto destroy;

	wlr_scene_node_set_enabled(&locked_bg->node, 0);

	focusclient(focustop(selmon), 0);
	motionnotify(0, NULL, 0, 0, 0, 0);

destroy:
	wl_list_remove(&lock->new_surface.link);
	wl_list_remove(&lock->unlock.link);
	wl_list_remove(&lock->destroy.link);

	wlr_scene_node_destroy(&lock->scene->node);
	cur_lock = NULL;
	free(lock);
}

void
destroylocksurface(struct wl_listener *listener, void *data)
{
	Monitor *m = wl_container_of(listener, m, destroy_lock_surface);
	struct wlr_session_lock_surface_v1 *surface, *lock_surface = m->lock_surface;

	m->lock_surface = NULL;
	wl_list_remove(&m->destroy_lock_surface.link);

	if (lock_surface->surface != seat->keyboard_state.focused_surface)
		return;

	if (locked && cur_lock && !wl_list_empty(&cur_lock->surfaces)) {
		surface = wl_container_of(cur_lock->surfaces.next, surface, link);
		client_notify_enter(surface->surface, wlr_seat_get_keyboard(seat));
	} else if (!locked) {
		focusclient(focustop(selmon), 1);
	} else {
		wlr_seat_keyboard_clear_focus(seat);
	}
}

void
destroynotify(struct wl_listener *listener, void *data)
{
	/* Called when the xdg_toplevel is destroyed. */
	Client *c = wl_container_of(listener, c, destroy);
	bool already_unmanaged;
	int i;


	/* Safety: If Lua state destroyed during cleanup, skip client_unmanage()
	 * which emits signals. This should never happen with correct cleanup
	 * order, but guards against race conditions. */
	if (!globalconf_L) {
		/* Minimal cleanup: remove listeners only */
		wl_list_remove(&c->destroy.link);
		wl_list_remove(&c->set_title.link);
		wl_list_remove(&c->request_fullscreen.link);
#ifdef XWAYLAND
		if (c->client_type != XDGShell) {
			wl_list_remove(&c->activate.link);
			wl_list_remove(&c->associate.link);
			wl_list_remove(&c->configure.link);
			wl_list_remove(&c->dissociate.link);
			wl_list_remove(&c->set_hints.link);
			/* If associate was called, map/unmap listeners need cleanup */
			if (c->map.link.prev && c->map.link.next) {
				wl_list_remove(&c->map.link);
				wl_list_remove(&c->unmap.link);
			}
			/* Note: commit listener is NOT registered for XWayland clients,
			 * so no cleanup needed here. See mapnotify(). */
		} else
#endif
		{
			wl_list_remove(&c->initial_commit.link);
			/* commit.link is removed in unmapnotify for XDG clients.
			 * Only remove here if unmapnotify didn't run (c->scene still set). */
			if (c->scene) {
				wl_list_remove(&c->commit.link);
			}
			wl_list_remove(&c->map.link);
			wl_list_remove(&c->unmap.link);
			wl_list_remove(&c->maximize.link);
		}
		return;  // Skip client_unmanage()
	}

	/* client_unmanage() will handle invalidation at the proper time (AFTER signals are emitted).
	 * This matches AwesomeWM's pattern where c->window = XCB_NONE happens at the END of client_unmanage(). */

	/* Check if client is still in the clients array.
	 * For normal lifecycle: unmap → unmapnotify calls client_unmanage → destroy → destroynotify (skip unmanage).
	 * For edge case: destroy without unmap → client still in array, destroynotify must call client_unmanage. */
	already_unmanaged = true;
	for (i = 0; i < globalconf.clients.len; i++) {
		if (globalconf.clients.tab[i] == c) {
			already_unmanaged = false;  /* Found in array = NOT yet unmanaged */
			break;
		}
	}

	if (already_unmanaged) {
		/* Client already removed from array by unmapnotify, skip client_unmanage */
	} else {
		/* Edge case: client still in array (destroyed without unmap), need to unmanage */
		client_unmanage(c, CLIENT_UNMANAGE_DESTROYED);
	}

	/* Clean up Wayland-specific listeners (not handled by client_unmanage) */
	wl_list_remove(&c->destroy.link);
	wl_list_remove(&c->set_title.link);
	wl_list_remove(&c->request_fullscreen.link);
#ifdef XWAYLAND
	if (c->client_type != XDGShell) {
		wl_list_remove(&c->activate.link);
		wl_list_remove(&c->associate.link);
		wl_list_remove(&c->configure.link);
		wl_list_remove(&c->dissociate.link);
		wl_list_remove(&c->set_hints.link);
		/* If associate was called, map/unmap listeners were registered.
		 * Check if they're still active (dissociate wasn't called) by checking
		 * if the list link is part of a list (non-null prev/next). */
		if (c->map.link.prev && c->map.link.next) {
			wl_list_remove(&c->map.link);
			wl_list_remove(&c->unmap.link);
		}
		/* Note: commit listener is NOT registered for XWayland clients,
		 * so no cleanup needed here. See mapnotify(). */
	} else
#endif
	{
		wl_list_remove(&c->initial_commit.link);
		/* commit.link is removed in unmapnotify for XDG clients.
		 * Only remove here if unmapnotify didn't run (c->scene still set). */
		if (c->scene) {
			wl_list_remove(&c->commit.link);
		}
		wl_list_remove(&c->map.link);
		wl_list_remove(&c->unmap.link);
		wl_list_remove(&c->maximize.link);
	}

	/* Note: Do NOT free(c) or metadata here - client_unmanage() called luaA_object_unref(),
	 * Lua GC will call client_wipe() to free metadata and eventually free(c).
	 * Manual free() bypasses Lua ref counting and causes use-after-free bugs. */
}

void
destroypointerconstraint(struct wl_listener *listener, void *data)
{
	PointerConstraint *pointer_constraint = wl_container_of(listener, pointer_constraint, destroy);

	if (active_constraint == pointer_constraint->constraint) {
		cursorwarptohint();
		active_constraint = NULL;
	}

	wl_list_remove(&pointer_constraint->destroy.link);
	free(pointer_constraint);
}

static void
destroytrackedpointer(struct wl_listener *listener, void *data)
{
	TrackedPointer *tp = wl_container_of(listener, tp, destroy);
	wl_list_remove(&tp->destroy.link);
	wl_list_remove(&tp->link);
	free(tp);
}

void
destroysessionlock(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, destroy);
	destroylock(lock, 0);
}

void
destroykeyboardgroup(struct wl_listener *listener, void *data)
{
	KeyboardGroup *group = wl_container_of(listener, group, destroy);
	wl_event_source_remove(group->key_repeat_source);
	wl_list_remove(&group->key.link);
	wl_list_remove(&group->modifiers.link);
	wl_list_remove(&group->destroy.link);
	wlr_keyboard_group_destroy(group->wlr_group);
	free(group);
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
focusclient(Client *c, int lift)
{
	struct wlr_surface *old = seat->keyboard_state.focused_surface;
	int unused_lx, unused_ly, old_client_type;
	Client *old_c = NULL;
	LayerSurface *old_l = NULL;
	struct wlr_surface *surface;
	struct wlr_keyboard *kb;

	if (locked)
		return;

	/* Raise client in stacking order if requested */
	if (c && lift) {
		if (!client_is_unmanaged(c))
			stack_client_append(c);
		else
			wlr_scene_node_raise_to_top(&c->scene->node);
	}

	if (c && client_surface(c) == old)
		return;

	if ((old_client_type = toplevel_from_wlr_surface(old, &old_c, &old_l)) == XDGShell) {
		struct wlr_xdg_popup *popup, *tmp;
		wl_list_for_each_safe(popup, tmp, &old_c->surface.xdg->popups, link)
			wlr_xdg_popup_destroy(popup);
	}

	/* Put the new client atop the focus stack and select its monitor */
	if (c && !client_is_unmanaged(c)) {
		/* Remove from current position in focus stack */
		foreach(elem, globalconf.stack) {
			if (*elem == c) {
				client_array_remove(&globalconf.stack, elem);
				break;
			}
		}
		/* Add to front of stack (most recent = index 0) */
		client_array_push(&globalconf.stack, c);

		selmon = c->mon;
		/* Clear urgent flag via proper API to emit property::urgent signal */
		luaA_object_push(globalconf_L, c);
		client_set_urgent(globalconf_L, -1, false);
		lua_pop(globalconf_L, 1);

		/* Don't change border color if there is an exclusive focus or we are
		 * handling a drag operation */
		if (!exclusive_focus && !seat->drag)
			client_set_border_color(c, get_focuscolor());
	}

	/* Deactivate old client if focus is changing */
	if (old && (!c || client_surface(c) != old)) {
		/* If an overlay is focused, don't focus or activate the client,
		 * but only update its position in the focus stack to render its border with focuscolor
		 * and focus it after the overlay is closed. */
		if (old_client_type == LayerShell && wlr_scene_node_coords(
					&old_l->scene->node, &unused_lx, &unused_ly)
				&& old_l->layer_surface->current.layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP) {
			return;
		} else if (old_c && old_c == exclusive_focus && client_wants_focus(old_c)) {
			return;
		} else if (old_c && !client_is_unmanaged(old_c)) {
			/* Only do protocol-level deactivation if new client doesn't want focus.
			 * Skipping this avoids issues with winecfg and similar clients. */
			if (!c || !client_wants_focus(c)) {
				client_activate_surface(old, 0);
				if (old_c->toplevel_handle)
					wlr_foreign_toplevel_handle_v1_set_activated(old_c->toplevel_handle, false);
			}
		}
	}

	/* Unfocus old client from globalconf (AwesomeWM pattern) - this emits proper signals */
	if (c && globalconf.focus.client && globalconf.focus.client != c &&
	    !client_is_unmanaged(globalconf.focus.client)) {
		client_set_border_color(globalconf.focus.client, get_bordercolor());
		luaA_object_push(globalconf_L, globalconf.focus.client);
		lua_pushboolean(globalconf_L, false);
		luaA_object_emit_signal(globalconf_L, -2, "property::active", 1);
		luaA_object_emit_signal(globalconf_L, -1, "unfocus", 0);
		lua_pop(globalconf_L, 1);
		luaA_emit_signal_global("client::unfocus");
	}
	printstatus();

	if (!c) {
		/* With no client, all we have left is to clear focus (deferred pattern) */
		globalconf.focus.client = NULL;
		globalconf.focus.need_update = true;
		return;
	}

	/* Change cursor surface */
	motionnotify(0, NULL, 0, 0, 0, 0);

	/* Set pending focus change for AwesomeWM compatibility (Lua code may check this) */
	globalconf.focus.client = c;
	globalconf.focus.need_update = true;

	/* Activate the new client */
	client_activate_surface(client_surface(c), 1);

	if (c->toplevel_handle)
		wlr_foreign_toplevel_handle_v1_set_activated(c->toplevel_handle, true);

	/* CRITICAL: Apply keyboard focus IMMEDIATELY while surface is valid (not deferred)
	 * AwesomeWM defers this, but Wayland surface pointers can become invalid by the time
	 * client_focus_refresh() runs. We must apply focus now. */
	surface = client_surface(c);

	if (surface && surface->mapped) {
		kb = wlr_seat_get_keyboard(seat);
		if (kb) {
			wlr_seat_keyboard_notify_enter(seat, surface,
			                                kb->keycodes,
			                                kb->num_keycodes,
			                                &kb->modifiers);
		}

		/* Update pointer constraint for newly focused surface.
		 * Games like Minecraft need the constraint to follow keyboard focus. */
		cursorconstrain(wlr_pointer_constraints_v1_constraint_for_surface(
			pointer_constraints, surface, seat));
	}

	/* Emit property::active = true for border updates (AwesomeWM pattern) */
	if (!client_is_unmanaged(c)) {
		luaA_object_push(globalconf_L, c);
		lua_pushboolean(globalconf_L, true);
		luaA_object_emit_signal(globalconf_L, -2, "property::active", 1);
		lua_pop(globalconf_L, 1);
	}

	luaA_emit_signal_global("client::focus");

	/* Refresh stacking order (affects fullscreen layer) */
	stack_refresh();
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
	focusclient(focustop(selmon), 1);
}

/* We probably should change the name of this: it sounds like it
 * will focus the topmost client of this mon, when actually will
 * only return that client */
Client *
focustop(Monitor *m)
{
	foreach(c, globalconf.stack) {
		if (client_on_selected_tags(*c) && (*c)->mon == m)
			return *c;
	}
	return NULL;
}

void
fullscreennotify(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, request_fullscreen);
	setfullscreen(c, client_wants_fullscreen(c));
}

/* Foreign toplevel management handlers - allow external tools like rofi
 * to list windows and request actions on them */
void
foreign_toplevel_request_activate(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, foreign_request_activate);
	focusclient(c, 1);
}

void
foreign_toplevel_request_close(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, foreign_request_close);
	client_send_close(c);
}

void
foreign_toplevel_request_fullscreen(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_fullscreen_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_fullscreen);
	setfullscreen(c, event->fullscreen);
}

void
foreign_toplevel_request_maximize(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_maximized_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_maximize);
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_maximized(L, -1, event->maximized);
	lua_pop(L, 1);
}

void
foreign_toplevel_request_minimize(struct wl_listener *listener, void *data)
{
	struct wlr_foreign_toplevel_handle_v1_minimized_event *event = data;
	Client *c = wl_container_of(listener, c, foreign_request_minimize);
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	client_set_minimized(L, -1, event->minimized);
	lua_pop(L, 1);
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
reap_children(GIOChannel *channel, GIOCondition condition, gpointer user_data)
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

void
inputdevice(struct wl_listener *listener, void *data)
{
	/* This event is raised by the backend when a new input device becomes
	 * available. */
	struct wlr_input_device *device = data;
	uint32_t caps;

	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		createkeyboard(wlr_keyboard_from_input_device(device));
		break;
	case WLR_INPUT_DEVICE_POINTER:
		createpointer(wlr_pointer_from_input_device(device));
		break;
	default:
		/* TODO handle other input device types */
		break;
	}

	/* We need to let the wlr_seat know what our capabilities are, which is
	 * communiciated to the client. In somewm we always have a cursor, even if
	 * there are no pointer devices, so we always include that capability. */
	/* TODO do we actually require a cursor? */
	caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&kb_group->wlr_group->devices))
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	wlr_seat_set_capabilities(seat, caps);
}

/* ========== APPEARANCE HELPER FUNCTIONS ========== */
/* These functions read appearance settings from beautiful.* (Lua theme system)
 * with fallbacks to globalconf defaults. This achieves AwesomeWM compatibility:
 * themes can customize appearance without recompiling C code. */

/** Get border width from beautiful.border_width or globalconf default */
static unsigned int
get_border_width(void)
{
	lua_State *L = globalconf_get_lua_State();
	if (!L) return globalconf.appearance.border_width;

	/* Try beautiful.border_width */
	lua_getglobal(L, "beautiful");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "border_width");
		if (lua_isnumber(L, -1)) {
			unsigned int val = lua_tointeger(L, -1);
			lua_pop(L, 2);
			return val;
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	return globalconf.appearance.border_width;
}

/** Get focus color from beautiful.border_focus or globalconf default */
static const float *
get_focuscolor(void)
{
	/* TODO: Add beautiful.border_focus parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.focuscolor;
}

/** Get border color from beautiful.border_normal or globalconf default */
static const float *
get_bordercolor(void)
{
	/* TODO: Add beautiful.border_normal parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.bordercolor;
}

/** Get urgent color from beautiful.border_urgent or globalconf default */
static const float *
get_urgentcolor(void)
{
	/* TODO: Add beautiful.border_urgent parsing (hex string to RGBA)
	 * For now, just return globalconf default */
	return globalconf.appearance.urgentcolor;
}

/* ========== KEYBINDING SYSTEM ========== */

/* Forward declarations for AwesomeWM-compatible Lua keybinding system */
extern int luaA_key_check_and_emit(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);
extern int luaA_client_key_check_and_emit(client_t *c, uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym);

int
keybinding(uint32_t mods, uint32_t keycode, xkb_keysym_t sym, xkb_keysym_t base_sym)
{
	client_t *focused;
	struct wlr_surface *surface;
	extern Client *some_client_from_surface(struct wlr_surface *surface);

	/*
	 * Here we handle compositor keybindings. This is when the compositor is
	 * processing keys, rather than passing them on to the client for its own
	 * processing.
	 *
	 * AwesomeWM pattern: check client-specific keybindings first (they receive
	 * the client as argument), then check global keybindings.
	 */

	/* Get the client that has keyboard focus from the Wayland seat.
	 * This matches AwesomeWM's pattern of using the X11 event window
	 * (event.c:781: client_getbywin(ev->event)) rather than internal
	 * focus state. We don't modify globalconf.focus.client here to
	 * avoid emitting focus signals during keybinding dispatch. */
	surface = seat->keyboard_state.focused_surface;
	focused = surface ? some_client_from_surface(surface) : NULL;

	/* Check client-specific Lua key objects first (AwesomeWM pattern)
	 * Client keybindings pass the client as argument to the "press" signal */
	if (focused && luaA_client_key_check_and_emit(focused, CLEANMASK(mods), keycode, sym, base_sym))
		return 1;

	/* Check global Lua key objects (AwesomeWM pattern) */
	if (luaA_key_check_and_emit(CLEANMASK(mods), keycode, sym, base_sym))
		return 1;

	/* Hardcoded VT switching (compositor-level, non-configurable)
	 * These are standard Linux keybindings that must work even if Lua crashes.
	 * VT switching allows recovering from compositor hangs/crashes via Ctrl-Alt-F2.
	 */
	if (CLEANMASK(mods) == (WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT)) {
		/* Ctrl-Alt-Backspace: Terminate compositor */
		if (sym == XKB_KEY_Terminate_Server) {
			wl_display_terminate(dpy);
			return 1;
		}
		/* Ctrl-Alt-F1..F12: Switch to VT 1-12 */
		if (sym >= XKB_KEY_XF86Switch_VT_1 && sym <= XKB_KEY_XF86Switch_VT_12) {
			unsigned int vt = sym - XKB_KEY_XF86Switch_VT_1 + 1;
			wlr_session_change_vt(session, vt);
			return 1;
		}
	}

	return 0;
}

void
keypress(struct wl_listener *listener, void *data)
{
	int i;
	uint32_t keycode;
	const xkb_keysym_t *syms;
	int nsyms;
	int handled = 0;
	uint32_t mods;
	xkb_keysym_t base_sym;
	/* This event is raised when a key is pressed or released. */
	KeyboardGroup *group = wl_container_of(listener, group, key);
	struct wlr_keyboard_key_event *event = data;

	/* Translate libinput keycode -> xkbcommon */
	keycode = event->keycode + 8;
	/* Get a list of keysyms based on the keymap for this keyboard */
	nsyms = xkb_state_key_get_syms(
			group->wlr_group->keyboard.xkb_state, keycode, &syms);

	mods = wlr_keyboard_get_modifiers(&group->wlr_group->keyboard);

	/* Get the base keysym (level 0, ignoring Shift/Lock modifiers).
	 * This is what the key produces without any modifiers applied.
	 * We use this for keybinding matching so that users can bind to
	 * "2" instead of "at" when using Shift+2. */
	base_sym = xkb_state_key_get_one_sym(
			group->wlr_group->keyboard.xkb_state, keycode);
	/* If Shift or Lock is active, get the unmodified keysym */
	if (mods & (WLR_MODIFIER_SHIFT | WLR_MODIFIER_CAPS)) {
		/* Get layout index (usually 0 for QWERTY) */
		xkb_layout_index_t layout = xkb_state_key_get_layout(
				group->wlr_group->keyboard.xkb_state, keycode);
		/* Get level 0 (base) keysym for this layout */
		const xkb_keysym_t *base_syms;
		int n = xkb_keymap_key_get_syms_by_level(
				group->wlr_group->keyboard.keymap, keycode, layout, 0, &base_syms);
		if (n > 0)
			base_sym = base_syms[0];
	}

	wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);

	/* Check if keygrabber is active - if so, route event to Lua callback */
	if (!locked && event->state == WL_KEYBOARD_KEY_STATE_PRESSED && some_keygrabber_is_running()) {
		/* Get the key name from the keysym */
		char keyname[64];
		xkb_keysym_get_name(base_sym, keyname, sizeof(keyname));

		/* Route to keygrabber callback */
		if (some_keygrabber_handle_key(mods, base_sym, keyname)) {
			/* Keygrabber handled the event, disable key repeat and return */
			group->nsyms = 0;
			wl_event_source_timer_update(group->key_repeat_source, 0);
			return;
		}
	}

	/* On _press_ if there is no active screen locker,
	 * attempt to process a compositor keybinding. */
	if (!locked && event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		for (i = 0; i < nsyms; i++)
			handled = keybinding(mods, keycode, syms[i], base_sym) || handled;
	}

	if (handled && group->wlr_group->keyboard.repeat_info.delay > 0) {
		group->mods = mods;
		group->keycode = keycode;
		group->keysyms = syms;
		group->nsyms = nsyms;
		group->base_sym = base_sym;
		wl_event_source_timer_update(group->key_repeat_source,
				group->wlr_group->keyboard.repeat_info.delay);
	} else {
		group->nsyms = 0;
		wl_event_source_timer_update(group->key_repeat_source, 0);
	}

	if (handled)
		return;

	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	/* Pass unhandled keycodes along to the client. */
	wlr_seat_keyboard_notify_key(seat, event->time_msec,
			event->keycode, event->state);
}

void
keypressmod(struct wl_listener *listener, void *data)
{
	/* This event is raised when a modifier key, such as shift or alt, is
	 * pressed. We simply communicate this to the client. */
	KeyboardGroup *group = wl_container_of(listener, group, modifiers);
	xkb_layout_index_t current_group;

	wlr_seat_set_keyboard(seat, &group->wlr_group->keyboard);
	/* Send modifiers to the client. */
	wlr_seat_keyboard_notify_modifiers(seat,
			&group->wlr_group->keyboard.modifiers);

	/* Check for layout group change (e.g., from Alt+Shift toggle) */
	current_group = xkb_state_serialize_layout(
		group->wlr_group->keyboard.xkb_state,
		XKB_STATE_LAYOUT_EFFECTIVE);

	if (current_group != globalconf.xkb.last_group) {
		globalconf.xkb.last_group = current_group;
		some_xkb_schedule_group_changed();
	}
}

int
keyrepeat(void *data)
{
	KeyboardGroup *group = data;
	int i;
	if (!group->nsyms || group->wlr_group->keyboard.repeat_info.rate <= 0)
		return 0;

	wl_event_source_timer_update(group->key_repeat_source,
			1000 / group->wlr_group->keyboard.repeat_info.rate);

	for (i = 0; i < group->nsyms; i++)
		keybinding(group->mods, group->keycode, group->keysyms[i], group->base_sym);

	return 0;
}

void
killclient(const Arg *arg)
{
	Client *sel = focustop(selmon);
	if (sel)
		client_send_close(sel);
}

void
locksession(struct wl_listener *listener, void *data)
{
	struct wlr_session_lock_v1 *session_lock = data;
	SessionLock *lock;
	wlr_scene_node_set_enabled(&locked_bg->node, 1);
	if (cur_lock) {
		wlr_session_lock_v1_destroy(session_lock);
		return;
	}
	lock = session_lock->data = ecalloc(1, sizeof(*lock));
	focusclient(NULL, 0);

	lock->scene = wlr_scene_tree_create(layers[LyrBlock]);
	cur_lock = lock->lock = session_lock;
	locked = 1;

	LISTEN(&session_lock->events.new_surface, &lock->new_surface, createlocksurface);
	LISTEN(&session_lock->events.destroy, &lock->destroy, destroysessionlock);
	LISTEN(&session_lock->events.unlock, &lock->unlock, unlocksession);

	wlr_session_lock_v1_send_locked(session_lock);
}

void
mapnotify(struct wl_listener *listener, void *data)
{
	/* Called when the surface is mapped, or ready to display on-screen. */
	Client *p = NULL;
	Client *w, *c = wl_container_of(listener, c, map);
	Monitor *m;
	int i;
	lua_State *L;
	tag_t *tag;

	/* Create scene tree for this client and its border */
	c->scene = client_surface(c)->data = wlr_scene_tree_create(layers[LyrTile]);
	/* Enabled later by a call to arrange() */
	wlr_scene_node_set_enabled(&c->scene->node, client_is_unmanaged(c));
	c->scene_surface = c->client_type == XDGShell
			? wlr_scene_xdg_surface_create(c->scene, c->surface.xdg)
			: wlr_scene_subsurface_tree_create(c->scene, client_surface(c));

	/* Handle scene surface creation failure (can happen with XWayland/Electron apps) */
	if (!c->scene_surface) {
		warn("Failed to create scene surface for client (type=%d)", c->client_type);
		wlr_scene_node_destroy(&c->scene->node);
		c->scene = NULL;
		client_surface(c)->data = NULL;
		return;
	}

	c->scene->node.data = c->scene_surface->node.data = c;

	/* Register commit listener AFTER wlr_scene_xdg_surface_create() so our listener
	 * fires AFTER wlroots' internal surface_reconfigure() which resets opacity to 1.0.
	 * This allows our compositor-controlled opacity to take effect.
	 * Only for XDG clients - commitnotify references XDG-specific fields.
	 * XWayland uses configurex11 for resize, not commits. */
	if (c->client_type == XDGShell) {
		LISTEN(&client_surface(c)->events.commit, &c->commit, commitnotify);
	}

	client_get_geometry(c, &c->geometry);

	/* Handle unmanaged clients first so we can return prior create borders */
	if (client_is_unmanaged(c)) {
		/* Unmanaged clients always are floating */
		wlr_scene_node_reparent(&c->scene->node, layers[LyrFloat]);
		wlr_scene_node_set_position(&c->scene->node, c->geometry.x, c->geometry.y);
		client_set_size(c, c->geometry.width, c->geometry.height);
		if (client_wants_focus(c)) {
			focusclient(c, 1);
			exclusive_focus = c;
		}
		goto unset_fullscreen;
	}

	for (i = 0; i < 4; i++) {
		c->border[i] = wlr_scene_rect_create(c->scene, 0, 0,
				c->urgent ? get_urgentcolor() : get_bordercolor());
		c->border[i]->node.data = c;
	}

	/* Create foreign toplevel handle for external tools (rofi, taskbars, etc.) */
	if (foreign_toplevel_mgr) {
		c->toplevel_handle = wlr_foreign_toplevel_handle_v1_create(foreign_toplevel_mgr);
		if (c->toplevel_handle) {
			const char *title = client_get_title(c);
			const char *app_id = client_get_appid(c);
			if (title)
				wlr_foreign_toplevel_handle_v1_set_title(c->toplevel_handle, title);
			if (app_id)
				wlr_foreign_toplevel_handle_v1_set_app_id(c->toplevel_handle, app_id);
			wlr_foreign_toplevel_handle_v1_set_maximized(c->toplevel_handle, c->maximized);
			wlr_foreign_toplevel_handle_v1_set_minimized(c->toplevel_handle, c->minimized);
			wlr_foreign_toplevel_handle_v1_set_fullscreen(c->toplevel_handle, c->fullscreen);
			if (c->mon && c->mon->wlr_output)
				wlr_foreign_toplevel_handle_v1_output_enter(c->toplevel_handle, c->mon->wlr_output);
			LISTEN(&c->toplevel_handle->events.request_activate, &c->foreign_request_activate, foreign_toplevel_request_activate);
			LISTEN(&c->toplevel_handle->events.request_close, &c->foreign_request_close, foreign_toplevel_request_close);
			LISTEN(&c->toplevel_handle->events.request_fullscreen, &c->foreign_request_fullscreen, foreign_toplevel_request_fullscreen);
			LISTEN(&c->toplevel_handle->events.request_maximize, &c->foreign_request_maximize, foreign_toplevel_request_maximize);
			LISTEN(&c->toplevel_handle->events.request_minimize, &c->foreign_request_minimize, foreign_toplevel_request_minimize);
		}
	}

	/* Initialize client geometry with room for border */
	c->geometry.width += 2 * c->bw;
	c->geometry.height += 2 * c->bw;

	/* Client was already added to arrays in createnotify() (matches AwesomeWM pattern)
	 * No need to add again here - doing so would create duplicates */

	/* Set initial monitor, tags, floating status, and focus:
	 * we always consider floating, clients that have parent and thus
	 * we set the same tags and monitor as its parent.
	 * If there is no parent, apply rules */
	if ((p = client_get_parent(c))) {
		/* Wayland transient windows should be treated as dialogs.
		 * XDG shell doesn't have explicit window type hints like X11's _NET_WM_WINDOW_TYPE,
		 * so we infer dialog type from the transient_for relationship.
		 * This makes Lua's update_implicitly_floating() detect them as floating,
		 * allowing user placement code in request::manage to work correctly. */
		c->type = WINDOW_TYPE_DIALOG;

		/* Set transient_for so Lua code can access c.transient_for property.
		 * This is needed for placement rules like awful.placement.centered(c, {parent = c.transient_for}) */
		L = globalconf_get_lua_State();
		luaA_object_push(L, c);
		client_set_transient_for(L, -1, p);
		lua_pop(L, 1);

		/* Copy tags from parent client (array-based)
		 * Note: Floating is managed by Lua property system now.
		 * Transient/dialog windows are detected via update_implicitly_floating() */

		/* Tag child with all tags that parent is tagged with */
		for (i = 0; i < globalconf.tags.len; i++) {
			tag = globalconf.tags.tab[i];
			if (is_client_tagged(p, tag)) {
				luaA_object_push(L, tag);
				tag_client(L, c);
			}
		}

		/* c->tags removed - tags managed by arrays */

		/* Set monitor (setmon will handle resize, arrange, etc.) */
		setmon(c, p->mon, 0);

		/* Emit property and manage signals for transient clients too.
		 * This is needed for Lua rules and placement code to work. */
		luaA_object_push(L, c);
		luaA_object_emit_signal(L, -1, "property::x", 0);
		luaA_object_emit_signal(L, -1, "property::y", 0);
		luaA_object_emit_signal(L, -1, "property::width", 0);
		luaA_object_emit_signal(L, -1, "property::height", 0);
		luaA_object_emit_signal(L, -1, "property::geometry", 0);
		luaA_object_emit_signal(L, -1, "property::type", 0);

		lua_pushstring(L, "new");
		lua_newtable(L);
		luaA_object_emit_signal(L, -3, "request::manage", 2);
		luaA_object_emit_signal(L, -1, "manage", 0);
		lua_pop(L, 1);

		/* Apply geometry BEFORE enabling scene node to send configure event.
		 * Fixes Firefox tiling issue (#10).
		 * Reset c->resize to force re-send configure even if setmon()->resize()
		 * already sent one (unflushed). This ensures the configure is flushed
		 * before we enable the scene node. */
		c->resize = 0;
		apply_geometry_to_wlroots(c);
		wl_display_flush_clients(dpy);

		/* Enable scene node for transient client */
		if (client_on_selected_tags(c)) {
			wlr_scene_node_set_enabled(&c->scene->node, true);
		}
	} else {
		Monitor *target_mon;
		screen_t *target_screen;

		/* Apply rules via Lua awful.rules system (AwesomeWM pattern) */
		L = globalconf_get_lua_State();

		/* Fetch initial properties using new property system.
		 * This calls client_set_*() which emits property::* signals on the client object.
		 * Both Wayland and XWayland use proper signal emission now. */
		if (c->client_type == XDGShell) {
			property_register_wayland_listeners(c);
		}
#ifdef XWAYLAND
		else {
			property_update_xwayland_properties(c);
		}
#endif

		/* Initialize window type (matches AwesomeWM client_manage line 2173)
		 * Default to NORMAL for all Wayland windows.
		 * TODO: Detect dialogs/utility windows via XDG shell hints */
		c->type = WINDOW_TYPE_NORMAL;

		/* Determine target monitor (but don't set c->mon yet - setmon() needs to do that) */
		target_mon = xytomon(c->geometry.x, c->geometry.y);
		if (!target_mon)
			target_mon = selmon;
		target_screen = luaA_screen_get_by_monitor(L, target_mon);

		/* Set default tags BEFORE emitting manage signal (AwesomeWM pattern)
		 * Tag client with all currently selected tags on the target monitor.
		 * Lua rules can then modify this via tag_client()/untag_client() calls. */
		for (i = 0; i < globalconf.tags.len; i++) {
			tag = globalconf.tags.tab[i];
			/* Check if tag is selected using array system */
			if (tag->selected && tag->screen == target_screen) {
				/* Push tag to Lua stack */
				luaA_object_push(L, tag);
				/* Tag the client (pops tag from stack, takes reference) */
				tag_client(L, c);
			}
		}

		/* c->tags removed - tags managed by arrays */

		/* Set the client's monitor BEFORE emitting signals (matches AwesomeWM line 2206).
		 * This ensures the client has a screen when signal handlers run. */
		target_mon = c->mon ? c->mon : xytomon(c->geometry.x, c->geometry.y);
		if (!target_mon)
			target_mon = selmon;
		setmon(c, target_mon, 0);

		/* Push client to Lua stack for signal emission */
		luaA_object_push(L, c);

		/* Emit property signals (matches AwesomeWM client_manage lines 2215-2228)
		 * These notify Lua code that initial client properties are set */
		luaA_object_emit_signal(L, -1, "property::x", 0);
		luaA_object_emit_signal(L, -1, "property::y", 0);
		luaA_object_emit_signal(L, -1, "property::width", 0);
		luaA_object_emit_signal(L, -1, "property::height", 0);
		luaA_object_emit_signal(L, -1, "property::window", 0);
		luaA_object_emit_signal(L, -1, "property::geometry", 0);
		luaA_object_emit_signal(L, -1, "property::size_hints_honor", 0);
		luaA_object_emit_signal(L, -1, "property::type", 0);

		/* Emit request::manage with context and hints (matches AwesomeWM line 2278)
		 * This is the modern AwesomeWM signal for client management */
		lua_pushstring(L, "new");  /* context */
		lua_newtable(L);            /* hints table (empty for now) */
		luaA_object_emit_signal(L, -3, "request::manage", 2);

		/* Emit legacy "manage" signal for backwards compatibility (matches AwesomeWM line 2281)
		 * Note: AwesomeWM comment says "TODO v6: remove this" */
		luaA_object_emit_signal(L, -1, "manage", 0);

		/* Pop client from Lua stack */
		lua_pop(L, 1);

		/* Apply geometry BEFORE enabling scene node to send configure event.
		 * Without this, client may render a frame at wrong size before receiving
		 * the tiled geometry configure event. Fixes Firefox tiling issue (#10).
		 * Reset c->resize to force re-send configure even if setmon()->resize()
		 * already sent one (unflushed). This ensures the configure is flushed
		 * before we enable the scene node. */
		c->resize = 0;
		apply_geometry_to_wlroots(c);

		/* Flush configure event to client immediately so it receives the tiled
		 * geometry before we make it visible. Without this, the configure is
		 * queued but not sent until the next poll cycle. */
		wl_display_flush_clients(dpy);

		/* Enable scene node for new client if on selected tags (Wayland-specific).
		 * Unlike AwesomeWM, we don't call arrange() here - that's triggered by Lua signals.
		 * We only need to make the client visible in the scene graph.
		 * AwesomeWM's client_manage() (objects/client.c:2278-2294) does NOT call arrange()
		 * after request::manage - layout is handled by the Lua signal system.
		 * Calling arrange() here would overwrite geometry set by Lua placement code. */
		if (client_on_selected_tags(c)) {
			wlr_scene_node_set_enabled(&c->scene->node, true);
		}
	}
	printstatus();

unset_fullscreen:
	m = c->mon ? c->mon : xytomon(c->geometry.x, c->geometry.y);
	foreach(client, globalconf.clients) {
		w = *client;
		/* Use array-based tag overlap check */
		if (w != c && w != p && w->fullscreen && m == w->mon && clients_share_tags(w, c))
			setfullscreen(w, 0);
	}

	luaA_emit_signal_global("client::map");
}

void
maximizenotify(struct wl_listener *listener, void *data)
{
	/* This event is raised when a client would like to maximize itself,
	 * typically because the user clicked on the maximize button on
	 * client-side decorations. somewm doesn't support maximization, but
	 * to conform to xdg-shell protocol we still must send a configure.
	 * Since xdg-shell protocol v5 we should ignore request of unsupported
	 * capabilities, just schedule a empty configure when the client uses <5
	 * protocol version
	 * wlr_xdg_surface_schedule_configure() is used to send an empty reply. */
	Client *c = wl_container_of(listener, c, maximize);
	if (c->surface.xdg->initialized
			&& wl_resource_get_version(c->surface.xdg->toplevel->resource)
					< XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION)
		wlr_xdg_surface_schedule_configure(c->surface.xdg);
}

void
motionabsolute(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits an _absolute_
	 * motion event, from 0..1 on each axis. This happens, for example, when
	 * wlroots is running under a Wayland window rather than KMS+DRM, and you
	 * move the mouse over the window. You could enter the window from any edge,
	 * so we have to warp the mouse there. Also, some hardware emits these events. */
	struct wlr_pointer_motion_absolute_event *event = data;
	double lx, ly, dx, dy;

	if (!event->time_msec) /* this is 0 with virtual pointers */
		wlr_cursor_warp_absolute(cursor, &event->pointer->base, event->x, event->y);

	wlr_cursor_absolute_to_layout_coords(cursor, &event->pointer->base, event->x, event->y, &lx, &ly);
	dx = lx - cursor->x;
	dy = ly - cursor->y;
	motionnotify(event->time_msec, &event->pointer->base, dx, dy, dx, dy);
}

/* Helper function to emit mouse::leave on the object that previously had the mouse.
 * Also clears drawable_under_mouse tracking to emit leave on the drawable. */
static void
mouse_emit_leave(lua_State *L)
{
	if (globalconf.mouse_under.type == UNDER_CLIENT) {
		client_t *c = globalconf.mouse_under.ptr.client;
		luaA_object_push(L, c);
		luaA_object_emit_signal(L, -1, "mouse::leave", 0);
		lua_pop(L, 1);
	} else if (globalconf.mouse_under.type == UNDER_DRAWIN) {
		drawin_t *d = globalconf.mouse_under.ptr.drawin;
		luaA_object_push(L, d);
		if (lua_isnil(L, -1)) {
			warn("mouse::leave on unregistered drawin %p", (void*)d);
		}
		luaA_object_emit_signal(L, -1, "mouse::leave", 0);
		lua_pop(L, 1);
	}
	globalconf.mouse_under.type = UNDER_NONE;

	/* Also clear drawable tracking - emit leave on drawable if any */
	if (globalconf.drawable_under_mouse != NULL) {
		luaA_object_push(L, globalconf.drawable_under_mouse);
		luaA_object_emit_signal(L, -1, "mouse::leave", 0);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}
}

/* Helper function to emit mouse::enter on a client */
static void
mouse_emit_client_enter(lua_State *L, client_t *c)
{
	luaA_object_push(L, c);
	luaA_object_emit_signal(L, -1, "mouse::enter", 0);
	lua_pop(L, 1);
	globalconf.mouse_under.type = UNDER_CLIENT;
	globalconf.mouse_under.ptr.client = c;
}

/* Helper function to emit mouse::enter on a drawin */
static void
mouse_emit_drawin_enter(lua_State *L, drawin_t *d)
{
	luaA_object_push(L, d);
	if (lua_isnil(L, -1)) {
		warn("mouse::enter on unregistered drawin %p", (void*)d);
	}
	luaA_object_emit_signal(L, -1, "mouse::enter", 0);
	lua_pop(L, 1);
	globalconf.mouse_under.type = UNDER_DRAWIN;
	globalconf.mouse_under.ptr.drawin = d;
}

/** Record that the given drawable contains the pointer.
 * Emits mouse::enter/leave signals on drawables for widget hover events.
 */
void
event_drawable_under_mouse(lua_State *L, int ud)
{
	void *d;

	/* luaA_object_ref pops, so push a copy first */
	lua_pushvalue(L, ud);
	d = luaA_object_ref(L, -1);

	if (d == globalconf.drawable_under_mouse) {
		luaA_object_unref(L, d);
		return;
	}

	if (globalconf.drawable_under_mouse != NULL) {
		luaA_object_push(L, globalconf.drawable_under_mouse);
		luaA_object_emit_signal(L, -1, "mouse::leave", 0);
		lua_pop(L, 1);
		luaA_object_unref(L, globalconf.drawable_under_mouse);
		globalconf.drawable_under_mouse = NULL;
	}

	if (d != NULL) {
		globalconf.drawable_under_mouse = d;
		luaA_object_emit_signal(L, ud, "mouse::enter", 0);
	}
}

void
motionnotify(uint32_t time, struct wlr_input_device *device, double dx, double dy,
		double dx_unaccel, double dy_unaccel)
{
	double sx = 0, sy = 0, sx_confined, sy_confined;
	Client *c = NULL, *w = NULL;
	LayerSurface *l = NULL;
	struct wlr_surface *surface = NULL;

	/* Find the client under the pointer and send the event along. */
	xytonode(cursor->x, cursor->y, &surface, &c, NULL, NULL, NULL, &sx, &sy);

	if (cursor_mode == CurPressed && !seat->drag
			&& surface != seat->pointer_state.focused_surface
			&& toplevel_from_wlr_surface(seat->pointer_state.focused_surface, &w, &l) >= 0) {
		c = w;
		surface = seat->pointer_state.focused_surface;
		sx = cursor->x - (l ? l->scene->node.x : w->geometry.x);
		sy = cursor->y - (l ? l->scene->node.y : w->geometry.y);
	}

	/* time is 0 in internal calls meant to restore pointer focus. */
	if (time) {
		wlr_relative_pointer_manager_v1_send_relative_motion(
				relative_pointer_mgr, seat, (uint64_t)time * 1000,
				dx, dy, dx_unaccel, dy_unaccel);

		/* Note: Constraint selection is done in focusclient(), not here.
		 * dwl/somewm previously iterated all constraints here which caused
		 * the "last constraint wins" bug breaking games like Minecraft. */

		if (active_constraint) {
			toplevel_from_wlr_surface(active_constraint->surface, &c, NULL);
			if (c && active_constraint->surface == seat->pointer_state.focused_surface) {
				sx = cursor->x - c->geometry.x - c->bw;
				sy = cursor->y - c->geometry.y - c->bw;
				if (wlr_region_confine(&active_constraint->region, sx, sy,
						sx + dx, sy + dy, &sx_confined, &sy_confined)) {
					dx = sx_confined - sx;
					dy = sy_confined - sy;
				}

				if (active_constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED)
					return;
			}
		}

		wlr_cursor_move(cursor, device, dx, dy);
		wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
	}

	/* Update drag icon's position */
	wlr_scene_node_set_position(&drag_icon->node, (int)round(cursor->x), (int)round(cursor->y));

	/* If mousegrabber is active, route event to Lua callback (AwesomeWM behavior:
	 * check mousegrabber BEFORE enter/leave signals to filter them during grabs) */
	if (mousegrabber_isrunning()) {
		lua_State *L = globalconf_get_lua_State();
		int button_states[5];

		/* Get current button states */
		some_get_button_states(button_states);

		/* Push coords table to Lua stack */
		mousegrabber_handleevent(L, cursor->x, cursor->y, button_states);

		/* Get the callback from registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, globalconf.mousegrabber);

		/* Push coords table as argument */
		lua_pushvalue(L, -2);

		/* Call callback(coords) */
		if (lua_pcall(L, 1, 1, 0) == 0) {
			/* Check return value */
			int continue_grab = lua_toboolean(L, -1);
			lua_pop(L, 1); /* Pop return value */

			if (!continue_grab) {
				/* Callback returned false, stop grabbing */
				luaA_mousegrabber_stop(L);
			}
		} else {
			/* Error in callback */
			fprintf(stderr, "somewm: mousegrabber callback error: %s\n",
				lua_tostring(L, -1));
			lua_pop(L, 1);
			luaA_mousegrabber_stop(L);
		}

		lua_pop(L, 1); /* Pop coords table */
		return; /* Don't process event further (skip enter/leave signals, pointerfocus) */
	}

	/* Track which object is under the cursor and emit enter/leave/move signals
	 * (only when mousegrabber is NOT active - filtered above) */
	if (time && !globalconf.mouse_under.ignore_next_enter_leave) {
		lua_State *L = globalconf_get_lua_State();
		Client *current_client = NULL;
		drawin_t *current_drawin = NULL;
		bool client_valid = false;

		/* Find what's under cursor */
		xytonode(cursor->x, cursor->y, NULL, &current_client, NULL, &current_drawin, NULL, NULL, NULL);

		/* Validate client pointer - xytonode can return stale pointers from scene graph
		 * if a node's data field wasn't cleared when the client was destroyed */
		if (current_client) {
			foreach(elem, globalconf.clients) {
				if (*elem == current_client) {
					client_valid = true;
					break;
				}
			}
			if (!client_valid) {
				current_client = NULL;  /* Ignore stale/invalid client pointer */
			}
		}

		if (current_client) {
			/* Mouse is over a client */
			if (globalconf.mouse_under.type != UNDER_CLIENT ||
			    globalconf.mouse_under.ptr.client != current_client) {
				/* Different object - emit leave on old, enter on new */
				mouse_emit_leave(L);
				mouse_emit_client_enter(L, current_client);
			}

			/* Always emit mouse::move on current client */
			luaA_object_push(L, current_client);
			if (lua_isnil(L, -1)) {
				warn("mouse::move on unregistered client %p", (void*)current_client);
			}
			lua_pushinteger(L, (int)(cursor->x - current_client->geometry.x));
			lua_pushinteger(L, (int)(cursor->y - current_client->geometry.y));
			luaA_object_emit_signal(L, -3, "mouse::move", 2);
			lua_pop(L, 1);

		} else if (current_drawin) {
			/* Mouse over drawin - emit signals on drawable for widget hover */
			if (globalconf.mouse_under.type != UNDER_DRAWIN ||
			    globalconf.mouse_under.ptr.drawin != current_drawin) {
				mouse_emit_leave(L);
				mouse_emit_drawin_enter(L, current_drawin);
			}

			luaA_object_push(L, current_drawin);
			if (lua_isnil(L, -1)) {
				warn("mouse event on unregistered drawin %p", (void*)current_drawin);
				lua_pop(L, 1);
			} else {
				luaA_object_push_item(L, -1, current_drawin->drawable);
				event_drawable_under_mouse(L, -1);

				lua_pushinteger(L, (int)cursor->x - current_drawin->x);
				lua_pushinteger(L, (int)cursor->y - current_drawin->y);
				luaA_object_emit_signal(L, -3, "mouse::move", 2);

				lua_pop(L, 2);
			}

		} else {
			/* Mouse is over empty space - emit leave if we were over something */
			if (globalconf.mouse_under.type != UNDER_NONE) {
				mouse_emit_leave(L);
			}
		}
	}

	/* Reset the ignore flag after processing */
	if (globalconf.mouse_under.ignore_next_enter_leave) {
		globalconf.mouse_under.ignore_next_enter_leave = false;
	}

	/* If there's no client surface under the cursor, set the cursor image.
	 * Check if pointer is over a drawin with a custom cursor first. */
	if (!surface && !seat->drag) {
		drawin_t *hover_drawin = NULL;
		xytonode(cursor->x, cursor->y, NULL, NULL, NULL, &hover_drawin, NULL, NULL, NULL);
		if (hover_drawin && hover_drawin->cursor)
			wlr_cursor_set_xcursor(cursor, cursor_mgr, hover_drawin->cursor);
		else
			wlr_cursor_set_xcursor(cursor, cursor_mgr, selected_root_cursor ? selected_root_cursor : "default");
	}

	pointerfocus(c, surface, sx, sy, time);
}

void
motionrelative(struct wl_listener *listener, void *data)
{
	/* This event is forwarded by the cursor when a pointer emits a _relative_
	 * pointer motion event (i.e. a delta) */
	struct wlr_pointer_motion_event *event = data;
	/* The cursor doesn't move unless we tell it to. The cursor automatically
	 * handles constraining the motion to the output layout, as well as any
	 * special configuration applied for the specific input device which
	 * generated the event. You can pass NULL for the device if you want to move
	 * the cursor around without any input. */
	motionnotify(event->time_msec, &event->pointer->base, event->delta_x, event->delta_y,
			event->unaccel_dx, event->unaccel_dy);
}

/* moveresize() function removed - move/resize now handled by Lua mousegrabber
 * (awful.mouse.client.move/resize) via client button bindings in rc.lua */

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
pointerfocus(Client *c, struct wlr_surface *surface, double sx, double sy,
		uint32_t time)
{
	struct timespec now;

	/* If surface is NULL, clear pointer focus */
	if (!surface) {
		wlr_seat_pointer_notify_clear_focus(seat);
		return;
	}

	if (!time) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		time = now.tv_sec * 1000 + now.tv_nsec / 1000000;
	}

	/* Let the client know that the mouse cursor has entered one
	 * of its surfaces. wlroots makes this a no-op if surface is already focused.
	 * Focus behavior is now handled in Lua via mouse::enter signal (AwesomeWM pattern). */
	wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
	wlr_seat_pointer_notify_motion(seat, time, sx, sy);
}

void
printstatus(void)
{
	Monitor *m = NULL;
	Client *c;

	/* Status output for external status bars */
	wl_list_for_each(m, &mons, link) {
		if ((c = focustop(m))) {
			printf("%s title %s\n", m->wlr_output->name, client_get_title(c));
			printf("%s appid %s\n", m->wlr_output->name, client_get_appid(c));
			printf("%s fullscreen %d\n", m->wlr_output->name, c->fullscreen);
			printf("%s floating %d\n", m->wlr_output->name, some_client_get_floating(c));
		} else {
			printf("%s title \n", m->wlr_output->name);
			printf("%s appid \n", m->wlr_output->name);
			printf("%s fullscreen \n", m->wlr_output->name);
			printf("%s floating \n", m->wlr_output->name);
		}

		printf("%s selmon %u\n", m->wlr_output->name, m == selmon);
		/* Note: Tag bitmask output removed - use AwesomeWM wibox widgets instead */
		/* Layout is now managed in Lua */
	}
	fflush(stdout);
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

	/* Render if no XDG clients have an outstanding resize and are visible on
	 * this monitor. */
	foreach(client, globalconf.clients) {
		c = *client;
		if (c->resize && !some_client_get_floating(c) && client_is_rendered_on_mon(c, m) && !client_is_stopped(c))
			goto skip;
	}

	wlr_scene_output_commit(m->scene_output, NULL);

skip:
	/* Let clients know a frame has been rendered */
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(m->scene_output, &now);
}

void
requestdecorationmode(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_decoration_mode);
	if (c->surface.xdg->initialized)
		wlr_xdg_toplevel_decoration_v1_set_mode(c->decoration,
				WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

void
requeststartdrag(struct wl_listener *listener, void *data)
{
	struct wlr_seat_request_start_drag_event *event = data;

	if (wlr_seat_validate_pointer_grab_serial(seat, event->origin,
			event->serial))
		wlr_seat_start_pointer_drag(seat, event->drag, event->serial);
	else
		wlr_data_source_destroy(event->drag->source);
}

void
requestmonstate(struct wl_listener *listener, void *data)
{
	struct wlr_output_event_request_state *event = data;
	wlr_output_commit_state(event->output, event->state);
	updatemons(NULL, NULL);
}

/** Refresh all client geometries (AwesomeWM pattern).
 *
 * This implements AwesomeWM's client_geometry_refresh() for Wayland.
 * Loops through all clients and applies their c->geometry to the wlroots scene graph.
 *
 * This is THE CRITICAL function that makes tiling work:
 * - Lua layout code calculates positions via c:geometry({...})
 * - Those changes update c->geometry in the C struct
 * - But without this function, wlroots never sees the new positions
 * - This function applies queued geometry changes to the actual scene nodes
 *
 * Called from some_refresh() in the event loop (matching AwesomeWM's awesome_refresh).
 */
static void
client_geometry_refresh(void)
{
	Client *c;
	int count = 0;

	foreach(client, globalconf.clients) {
		c = *client;
		if (!c || !c->mon)
			continue;

		count++;
		/* Apply c->geometry to wlroots scene graph */
		apply_geometry_to_wlroots(c);
	}

	if (count > 0) {
	}
}

/* Apply geometry to wlroots scene graph - Wayland-specific rendering layer.
 * This function ONLY updates wlroots; it does NOT modify c->geometry or emit signals.
 * Called by resize() for interactive resize and client_resize_do() for Lua-initiated resize.
 */
void
apply_geometry_to_wlroots(Client *c)
{
	struct wlr_box clip;
	int titlebar_left, titlebar_top;

	if (!c->scene || !client_surface(c) || !client_surface(c)->mapped)
		return;

	/* Get titlebar sizes - they occupy space inside geometry */
	titlebar_left = c->titlebar[CLIENT_TITLEBAR_LEFT].size;
	titlebar_top = c->titlebar[CLIENT_TITLEBAR_TOP].size;

	/* Update scene-graph position and borders */
	wlr_scene_node_set_position(&c->scene->node, c->geometry.x, c->geometry.y);
	/* Offset scene_surface by titlebar sizes (titlebars occupy space in geometry) */
	wlr_scene_node_set_position(&c->scene_surface->node, c->bw + titlebar_left, c->bw + titlebar_top);
	wlr_scene_rect_set_size(c->border[0], c->geometry.width, c->bw);
	wlr_scene_rect_set_size(c->border[1], c->geometry.width, c->bw);
	wlr_scene_rect_set_size(c->border[2], c->bw, c->geometry.height - 2 * c->bw);
	wlr_scene_rect_set_size(c->border[3], c->bw, c->geometry.height - 2 * c->bw);
	wlr_scene_node_set_position(&c->border[1]->node, 0, c->geometry.height - c->bw);
	wlr_scene_node_set_position(&c->border[2]->node, 0, c->bw);
	wlr_scene_node_set_position(&c->border[3]->node, c->geometry.width - c->bw, c->bw);

	/* Update titlebar positions - they depend on current geometry */
	client_update_titlebar_positions(c);

	/* Request size change from client (subtract borders AND titlebars from geometry)
	 * CRITICAL: Only send configure if there's no pending resize waiting for client commit.
	 * Without this check, we flood the client with configure events on every refresh cycle,
	 * which crashes Firefox and other clients that can't handle rapid configure floods. */
	if (!c->resize) {
		c->resize = client_set_size(c,
				c->geometry.width - 2 * c->bw - titlebar_left - c->titlebar[CLIENT_TITLEBAR_RIGHT].size,
				c->geometry.height - 2 * c->bw - titlebar_top - c->titlebar[CLIENT_TITLEBAR_BOTTOM].size);
	}
	client_get_clip(c, &clip);
	wlr_scene_subsurface_tree_set_clip(&c->scene_surface->node, &clip);
}

void
resize(Client *c, struct wlr_box geo, int interact)
{
	struct wlr_box *bbox;

	if (!c->mon || !client_surface(c)->mapped)
		return;

	bbox = interact ? &sgeom : &c->mon->w;

	client_set_bounds(c, geo.width, geo.height);
	c->geometry = geo;
	applybounds(c, bbox);

	/* Apply to wlroots rendering */
	apply_geometry_to_wlroots(c);

	/* Emit signal for geometry change listeners */
	luaA_emit_signal_global("client::property::geometry");
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

/* Forward declaration */
static void some_refresh(void);

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
static void
some_refresh(void)
{
	/* Prevent recursive refresh calls (matches AwesomeWM pattern) */
	if (in_refresh)
		return;
	in_refresh = true;


	/* Step 1: Emit refresh signal - triggers Lua layout calculations */
	luaA_emit_signal_global("refresh");

	/* Step 2: Refresh drawins (wibox/panels) FIRST - matches AwesomeWM order
	 * AwesomeWM calls drawin_refresh() BEFORE client_refresh() in awesome_refresh().
	 * This ensures wibar geometry is applied before client layout calculations. */
	drawin_refresh();

	/* Step 3: Apply geometry changes to Wayland scene graph
	 * Lua layout code calculates positions, but without this they never
	 * get applied to wlroots scene nodes. */
	client_geometry_refresh();

	/* Step 4: Apply pending border changes (AwesomeWM deferred pattern)
	 * Border updates (width/color) are deferred until refresh cycle */
	client_border_refresh();

	/* Step 5: Update client visibility (banning) */
	banning_refresh();

	/* Step 6: Update window stacking (Z-order)
	 * This matches AwesomeWM's awesome_refresh() which calls stack_refresh() */
	stack_refresh();

	/* Step 7: Apply pending keyboard focus changes
	 * This matches AwesomeWM's awesome_refresh() deferred focus pattern */
	client_focus_refresh();

	/* Step 8: Destroy windows queued for deferred destruction (XWayland only)
	 * This matches AwesomeWM's deferred destruction pattern to avoid race conditions */
	client_destroy_later();


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
		luaA_screen_emit_scanning(globalconf_L);
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
		luaA_screen_emit_scanned(globalconf_L);

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

	fprintf(stderr, "somewm: Starting GLib main loop (AwesomeWM architecture)\n");
	g_main_loop_run(globalconf.loop);
	fprintf(stderr, "somewm: GLib main loop exited\n");

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

void
setcursor(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client provides a cursor image */
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	/* If we're "grabbing" the cursor, don't use the client's image, we will
	 * restore it after "grabbing" sending a leave event, followed by a enter
	 * event, which will result in the client requesting set the cursor surface */
	if (cursor_mode != CurNormal && cursor_mode != CurPressed)
		return;
	/* This can be sent by any client, so we check to make sure this one
	 * actually has pointer focus first. If so, we can tell the cursor to
	 * use the provided surface as the cursor image. It will set the
	 * hardware cursor on the output that it's currently on and continue to
	 * do so as the cursor moves between outputs. */
	if (event->seat_client == seat->pointer_state.focused_client)
		wlr_cursor_set_surface(cursor, event->surface,
				event->hotspot_x, event->hotspot_y);
}

void
setcursorshape(struct wl_listener *listener, void *data)
{
	struct wlr_cursor_shape_manager_v1_request_set_shape_event *event = data;
	if (cursor_mode != CurNormal && cursor_mode != CurPressed)
		return;
	/* This can be sent by any client, so we check to make sure this one
	 * actually has pointer focus first. If so, we can tell the cursor to
	 * use the provided cursor shape. */
	if (event->seat_client == seat->pointer_state.focused_client)
		wlr_cursor_set_xcursor(cursor, cursor_mgr,
				wlr_cursor_shape_v1_name(event->shape));
}

/* setfloating() removed - floating state is now managed entirely by Lua property system.
 * Scene graph layer changes happen via arrange() when Lua updates property::floating.
 * This matches AwesomeWM's approach where C doesn't manage floating state. */

void
setfullscreen(Client *c, int fullscreen)
{
	c->fullscreen = fullscreen;
	if (!c->mon || !client_surface(c)->mapped)
		return;

	/* Fullscreen is mutually exclusive with maximized states */
	if (fullscreen && (c->maximized || c->maximized_horizontal || c->maximized_vertical)) {
		c->maximized = 0;
		c->maximized_horizontal = 0;
		c->maximized_vertical = 0;
		/* Clear XDG toplevel maximize state if applicable */
		if (c->client_type == XDGShell && c->surface.xdg->toplevel)
			wlr_xdg_toplevel_set_maximized(c->surface.xdg->toplevel, 0);
	}

	c->bw = fullscreen ? 0 : get_border_width();
	client_set_fullscreen_internal(c, fullscreen);
	wlr_scene_node_reparent(&c->scene->node, layers[c->fullscreen ? LyrFS : LyrTile]);

	if (fullscreen) {
		c->prev = c->geometry;
		resize(c, c->mon->m, 0);
	} else {
		/* restore previous size instead of arrange for floating windows since
		 * client positions are set by the user and cannot be recalculated */
		resize(c, c->prev, 0);
	}
	arrange(c->mon);
	printstatus();

	/* Refresh stacking order (fullscreen layer changes) */
	stack_refresh();

	luaA_emit_signal_global("client::property::fullscreen");
}

void
setmon(Client *c, Monitor *m, uint32_t newtags)
{
	Monitor *oldmon = c->mon;
	screen_t *old_screen;
	lua_State *L;

	if (oldmon == m)
		return;

	L = globalconf_get_lua_State();
	old_screen = c->screen;  /* Capture before update */

	c->mon = m;
	c->prev = c->geometry;

	/* Update c->screen to match c->mon for Lua property access */
	c->screen = luaA_screen_get_by_monitor(L, m);

	/* Emit property::screen signal if screen changed (AwesomeWM pattern).
	 * This triggers Lua tag management (awful/tag.lua) to assign client
	 * to tags on the new screen via request::tag signal. */
	if (c->screen != old_screen) {
		luaA_object_push(L, c);
		if (old_screen != NULL)
			luaA_object_push(L, old_screen);
		else
			lua_pushnil(L);
		luaA_object_emit_signal(L, -2, "property::screen", 1);
		lua_pop(L, 1);
	}

	if (c->toplevel_handle) {
		if (oldmon && oldmon->wlr_output)
			wlr_foreign_toplevel_handle_v1_output_leave(c->toplevel_handle, oldmon->wlr_output);
		if (m && m->wlr_output)
			wlr_foreign_toplevel_handle_v1_output_enter(c->toplevel_handle, m->wlr_output);
	}

	/* Scene graph sends surface leave/enter events on move and resize */
	if (oldmon)
		arrange(oldmon);
	if (m) {
		/* Make sure window actually overlaps with the monitor */
		resize(c, c->geometry, 0);
		/* Tags managed by Lua/arrays, no c->tags assignment needed */
		/* Mark that client visibility needs refresh when moving monitors */
		banning_need_update();
		setfullscreen(c, c->fullscreen); /* This will call arrange(c->mon) */
		/* Note: setfloating() removed - Lua manages floating state via property system */
	}
	/* Note: focusclient() removed - Lua handles focus via request::activate signals */
}

void
setpsel(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client wants to set the selection,
	 * usually when the user copies something. wlroots allows compositors to
	 * ignore such requests if they so choose, but in somewm we always honor them
	 */
	struct wlr_seat_request_set_primary_selection_event *event = data;
	wlr_seat_set_primary_selection(seat, event->source, event->serial);
}

void
setsel(struct wl_listener *listener, void *data)
{
	/* This event is raised by the seat when a client wants to set the selection,
	 * usually when the user copies something. wlroots allows compositors to
	 * ignore such requests if they so choose, but in somewm we always honor them
	 */
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(seat, event->source, event->serial);
}

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

	/* Setup GLib IO watch for SIGCHLD pipe */
	{
		GIOChannel *channel = g_io_channel_unix_new(sigchld_pipe[0]);
		g_io_add_watch(channel, G_IO_IN, reap_children, NULL);
		g_io_channel_unref(channel);
	}

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
		die("couldn't create renderer");
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
	cursor_mgr = wlr_xcursor_manager_create(NULL, 24);
	setenv("XCURSOR_SIZE", "24", 1);

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
#ifdef XWAYLAND
	/*
	 * Initialise the XWayland X server.
	 * It will be started when the first X client is started.
	 */
	if ((xwayland = wlr_xwayland_create(dpy, compositor, 1))) {
		wl_signal_add(&xwayland->events.ready, &xwayland_ready);
		wl_signal_add(&xwayland->events.new_surface, &new_xwayland_surface);

		setenv("DISPLAY", xwayland->display_name, 1);
	} else {
		fprintf(stderr, "failed to setup XWayland X server, continuing without it\n");
	}
#endif

	luaA_init();

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

void
startdrag(struct wl_listener *listener, void *data)
{
	struct wlr_drag *drag = data;
	if (!drag->icon)
		return;

	drag->icon->data = &wlr_scene_drag_icon_create(drag_icon, drag->icon)->node;
	LISTEN_STATIC(&drag->icon->events.destroy, destroydragicon);
}

void
swapstack(const Arg *arg)
{
	Client *sel = focustop(selmon);
	int sel_idx = -1;
	int target_idx = -1;
	int i;
	Client *tmp;
	lua_State *L;

	if (!sel)
		return;

	if (globalconf.clients.len < 2)
		return;

	/* Find sel's position in clients array */
	for (i = 0; i < globalconf.clients.len; i++) {
		if (globalconf.clients.tab[i] == sel) {
			sel_idx = i;
			break;
		}
	}

	if (sel_idx == -1)
		return; /* Should never happen */

	/* Find next/prev client on selected tags */
	if (arg->i > 0) {
		/* Search forward */
		for (i = sel_idx + 1; i < globalconf.clients.len; i++) {
			if (client_on_selected_tags(globalconf.clients.tab[i])) {
				target_idx = i;
				break;
			}
		}
	} else {
		/* Search backward */
		for (i = sel_idx - 1; i >= 0; i--) {
			if (client_on_selected_tags(globalconf.clients.tab[i])) {
				target_idx = i;
				break;
			}
		}
	}

	if (target_idx == -1)
		return; /* No client found to swap with */

	/* Swap the two clients in the array */
	tmp = globalconf.clients.tab[sel_idx];
	globalconf.clients.tab[sel_idx] = globalconf.clients.tab[target_idx];
	globalconf.clients.tab[target_idx] = tmp;

	/* Emit signals (matches AwesomeWM swap()) */
	L = globalconf_get_lua_State();
	if (L) {
		Client *c = globalconf.clients.tab[target_idx]; /* original sel */
		Client *swap = globalconf.clients.tab[sel_idx]; /* original target */

		luaA_class_emit_signal(L, &client_class, "list", 0);

		/* First swapped signal on c (is_source=true) */
		luaA_object_push(L, c);
		luaA_object_push(L, swap);
		lua_pushboolean(L, true);
		luaA_object_emit_signal(L, -4, "swapped", 2);

		/* Second swapped signal on swap (is_source=false) */
		luaA_object_push(L, swap);
		luaA_object_push(L, c);
		lua_pushboolean(L, false);
		luaA_object_emit_signal(L, -3, "swapped", 2);
	}

	arrange(selmon);
}

void
tagmon(const Arg *arg)
{
	Client *sel = focustop(selmon);
	if (sel) {
		setmon(sel, dirtomon(arg->i), 0);
		focusclient(focustop(selmon), 1);
	}
}

void
togglefloating(const Arg *arg)
{
	Client *sel = focustop(selmon);
	lua_State *L;
	int is_floating;

	/* return if fullscreen */
	if (!sel || sel->fullscreen)
		return;

	/* Call Lua to toggle floating: awful.client.floating.toggle(c)
	 * This matches AwesomeWM's approach where C doesn't manage floating state */
	L = globalconf_get_lua_State();
	if (!L)
		return;

	/* Push client */
	luaA_object_push(L, sel);

	/* Get current floating state */
	lua_getfield(L, -1, "floating");
	is_floating = lua_toboolean(L, -1);
	lua_pop(L, 1);

	/* Set new floating state */
	lua_pushboolean(L, !is_floating);
	lua_setfield(L, -2, "floating");

	lua_pop(L, 1); /* pop client */
}

void
unlocksession(struct wl_listener *listener, void *data)
{
	SessionLock *lock = wl_container_of(listener, lock, unlock);
	destroylock(lock, 1);
}

void
unmaplayersurfacenotify(struct wl_listener *listener, void *data)
{
	LayerSurface *l = wl_container_of(listener, l, unmap);

	l->mapped = 0;
	wlr_scene_node_set_enabled(&l->scene->node, 0);
	if (l == exclusive_focus)
		exclusive_focus = NULL;
	if (l->layer_surface->output && (l->mon = l->layer_surface->output->data))
		arrangelayers(l->mon);
	if (l->layer_surface->surface == seat->keyboard_state.focused_surface)
		focusclient(focustop(selmon), 1);
	motionnotify(0, NULL, 0, 0, 0, 0);
}

void
unmapnotify(struct wl_listener *listener, void *data)
{
	/* Called when the surface is unmapped, and should no longer be shown. */
	Client *c = wl_container_of(listener, c, unmap);

	/* Safety: If scene was never created (mapnotify failed), nothing to clean up */
	if (!c->scene) {
		return;
	}

	/* Safety: If Lua destroyed during cleanup, skip Lua-dependent operations */
	if (!globalconf_L) {
		wlr_scene_node_destroy(&c->scene->node);
		return;
	}

	luaA_emit_signal_global("client::unmap");

	if (c->toplevel_handle) {
		wl_list_remove(&c->foreign_request_activate.link);
		wl_list_remove(&c->foreign_request_close.link);
		wl_list_remove(&c->foreign_request_fullscreen.link);
		wl_list_remove(&c->foreign_request_maximize.link);
		wl_list_remove(&c->foreign_request_minimize.link);
		wlr_foreign_toplevel_handle_v1_destroy(c->toplevel_handle);
		c->toplevel_handle = NULL;
	}

	/* CRITICAL: If this is the focused client, clear focus immediately
	 * to prevent client_focus_refresh() from accessing dangling surface pointers */
	if (globalconf.focus.client == c) {
		globalconf.focus.client = NULL;
		globalconf.focus.need_update = true;
	}

	if (client_is_unmanaged(c)) {
		if (c == exclusive_focus) {
			exclusive_focus = NULL;
			focusclient(focustop(selmon), 1);
		}
	} else {
		setmon(c, NULL, 0);
		focusclient(focustop(selmon), 1);

		/* Do NOT call client_unmanage() here - let destroynotify() handle it.
		 * For Wayland: unmap → destroy happens quickly, destroynotify() will call client_unmanage().
		 * This avoids trying to run XCB operations on windows that are already being torn down. */
	}

	/* Remove commit listener before destroying scene - only registered for XDG clients.
	 * Must be done before surface destruction as wlroots asserts listener lists are empty. */
	if (c->client_type == XDGShell) {
		wl_list_remove(&c->commit.link);
	}

	wlr_scene_node_destroy(&c->scene->node);
	c->scene = NULL;  /* Mark as cleaned up so destroynotify won't double-remove */

	/* Clear titlebar scene buffer pointers - they were children of c->scene
	 * and are now freed. Prevents use-after-free in refresh callbacks. */
	for (client_titlebar_t bar = CLIENT_TITLEBAR_TOP; bar < CLIENT_TITLEBAR_COUNT; bar++) {
		c->titlebar[bar].scene_buffer = NULL;
	}

	printstatus();
	motionnotify(0, NULL, 0, 0, 0, 0);
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
	struct wlr_output_configuration_v1 *config
			= wlr_output_configuration_v1_create();
	Client *c;
	struct wlr_output_configuration_head_v1 *config_head;
	Monitor *m;

	/* First remove from the layout the disabled monitors */
	wl_list_for_each(m, &mons, link) {
		if (m->wlr_output->enabled || m->asleep)
			continue;
		config_head = wlr_output_configuration_head_v1_create(config, m->wlr_output);
		config_head->state.enabled = 0;
		/* Remove this output from the layout to avoid cursor enter inside it */
		wlr_output_layout_remove(output_layout, m->wlr_output);
		closemon(m);
		m->m = m->w = (struct wlr_box){0};
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
			struct wlr_scene_tree *scene_tree = m->lock_surface->surface->data;
			wlr_scene_node_set_position(&scene_tree->node, m->m.x, m->m.y);
			wlr_session_lock_surface_v1_configure(m->lock_surface, m->m.width, m->m.height);
		}

		/* Calculate the effective monitor geometry to use for clients */
		arrangelayers(m);
		/* Update screen object geometry and emit property:: signals if changed */
		{
			screen_t *screen = luaA_screen_get_by_monitor(globalconf_L, m);
			if (screen) {
				luaA_screen_update_geometry(globalconf_L, screen);
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

		if (!selmon) {
			selmon = m;
		}
	}

	if (selmon && selmon->wlr_output->enabled) {
		struct wlr_surface *surf;
		foreach(client, globalconf.clients) {
			c = *client;
			if (!c->mon && (surf = client_surface(c)) && surf->mapped)
				setmon(c, selmon, 0);
		}
		focusclient(focustop(selmon), 1);
		if (selmon->lock_surface) {
			client_notify_enter(selmon->lock_surface->surface,
					wlr_seat_get_keyboard(seat));
			client_activate_surface(selmon->lock_surface->surface, 1);
		}
	}

	/* FIXME: figure out why the cursor image is at 0,0 after turning all
	 * the monitors on.
	 * Move the cursor image where it used to be. It does not generate a
	 * wl_pointer.motion event for the clients, it's only the image what it's
	 * at the wrong position after all. */
	wlr_cursor_move(cursor, NULL, 0, 0);

	wlr_output_manager_v1_set_configuration(output_mgr, config);
}

void
updatetitle(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_title);
	lua_State *L;

	/* Use new property system for both Wayland and XWayland clients
	 * Both call client_set_name() which emits property::name signal */
	if (c->client_type == XDGShell) {
		property_handle_toplevel_title(listener, data);
	} else {
		/* XWayland: extract title from xwayland surface */
		L = globalconf_get_lua_State();
		luaA_object_push(L, c);
		client_set_name(L, -1, c->surface.xwayland->title
			? strdup(c->surface.xwayland->title) : NULL);
		lua_pop(L, 1);
	}

	if (c == focustop(c->mon))
		printstatus();

	if (c->toplevel_handle) {
		const char *title = client_get_title(c);
		if (title)
			wlr_foreign_toplevel_handle_v1_set_title(c->toplevel_handle, title);
	}
}

static gboolean
activation_token_timeout(gpointer user_data)
{
	char *token;
	size_t i;
	
	token = (char *)user_data;
	
	/* Find and remove the token */
	for (i = 0; i < pending_tokens_len; i++) {
		if (strcmp(pending_tokens[i].token, token) == 0) {
			/* Emit spawn::timeout signal (matches AwesomeWM spawn.c:115) */
			luaA_emit_signal_global_with_table("spawn::timeout", 2,
				"id", token);
			free(pending_tokens[i].token);
			free(pending_tokens[i].app_id);
			
			/* Shift remaining tokens */
			memmove(&pending_tokens[i], &pending_tokens[i + 1],
				(pending_tokens_len - i - 1) * sizeof(activation_token_t));
			pending_tokens_len--;
			break;
		}
	}
	
	free(token);
	return G_SOURCE_REMOVE;  /* One-shot timer */
}

/* Create activation token and store it */
char *activation_token_create(const char *app_id)
{
	struct wlr_xdg_activation_token_v1 *token;
	const char *token_name;
	size_t new_cap;
	activation_token_t *new_tokens;
	activation_token_t *slot;
	
	if (!activation)
		return NULL;
	
	token = wlr_xdg_activation_token_v1_create(activation);
	if (!token)
		return NULL;
	
	/* Commit the token to get the token string */
	token_name = wlr_xdg_activation_token_v1_get_name(token);
	if (!token_name)
		return NULL;
	
	/* Grow array if needed */
	if (pending_tokens_len >= pending_tokens_cap) {
		new_cap = pending_tokens_cap == 0 ? 8 : pending_tokens_cap * 2;
		new_tokens = realloc(pending_tokens, new_cap * sizeof(activation_token_t));
		if (!new_tokens)
			return NULL;
		pending_tokens = new_tokens;
		pending_tokens_cap = new_cap;
	}
	
	/* Store token with metadata */
	slot = &pending_tokens[pending_tokens_len++];
	slot->token = strdup(token_name);
	slot->app_id = app_id ? strdup(app_id) : NULL;
	
	/* Setup 20-second timeout (matches AwesomeWM) */
	slot->timeout_id = g_timeout_add_seconds(20, activation_token_timeout, 
		strdup(token_name));
	
	
	return slot->token;
}

/* Cleanup token (called from urgent handler on match) */
void activation_token_cleanup(const char *token)
{
	size_t i;
	
	if (!token)
		return;
	
	for (i = 0; i < pending_tokens_len; i++) {
		if (strcmp(pending_tokens[i].token, token) == 0) {
			/* Cancel timeout */
			g_source_remove(pending_tokens[i].timeout_id);
			
			
			free(pending_tokens[i].token);
			free(pending_tokens[i].app_id);
			
			/* Shift remaining tokens */
			memmove(&pending_tokens[i], &pending_tokens[i + 1],
				(pending_tokens_len - i - 1) * sizeof(activation_token_t));
			pending_tokens_len--;
			return;
		}
	}
}
void urgent(struct wl_listener *listener, void *data)
{
	struct wlr_xdg_activation_v1_request_activate_event *event;
	Client *c;
	const char *token_name;
	bool token_matched;
	lua_State *L;
	
	event = data;
	c = NULL;
	token_matched = false;
	
	toplevel_from_wlr_surface(event->surface, &c, NULL);
	if (!c)
		return;

	/* Extract token from activation event */
	token_name = event->token ? wlr_xdg_activation_token_v1_get_name(event->token) : NULL;
	
	/* Validate token against pending tokens */
	if (token_name) {
		size_t i;
		for (i = 0; i < pending_tokens_len; i++) {
			if (strcmp(pending_tokens[i].token, token_name) == 0) {
				token_matched = true;

				/* Set startup_id on client (matches AwesomeWM pattern) */
				if (c->startup_id)
					free(c->startup_id);
				c->startup_id = strdup(token_name);

				/* Clean up matched token */
				activation_token_cleanup(token_name);

				/* Emit spawn::completed signal (matches AwesomeWM spawn.c:167) */
				luaA_emit_signal_global_with_table("spawn::completed", 2,
					"id", token_name);
				break;
			}
		}
	}

	/* Emit request::activate signal to Lua (matches AwesomeWM) */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	lua_pushstring(L, token_matched ? "startup" : "client");  /* context */
	luaA_object_emit_signal(L, -2, "request::activate", 1);
	lua_pop(L, 1);

	/* Set urgent flag if not already focused (via proper API for signal emission) */
	if (c != focustop(selmon)) {
		luaA_object_push(L, c);
		client_set_urgent(L, -1, true);
		lua_pop(L, 1);
		printstatus();
	}
}

void
virtualkeyboard(struct wl_listener *listener, void *data)
{
	struct wlr_virtual_keyboard_v1 *kb = data;
	/* virtual keyboards shouldn't share keyboard group */
	KeyboardGroup *group = createkeyboardgroup();
	/* Set the keymap to match the group keymap */
	wlr_keyboard_set_keymap(&kb->keyboard, group->wlr_group->keyboard.keymap);
	LISTEN(&kb->keyboard.base.events.destroy, &group->destroy, destroykeyboardgroup);

	/* Add the new keyboard to the group */
	wlr_keyboard_group_add_keyboard(group->wlr_group, &kb->keyboard);
}

void
virtualpointer(struct wl_listener *listener, void *data)
{
	struct wlr_virtual_pointer_v1_new_pointer_event *event = data;
	struct wlr_input_device *device = &event->new_pointer->pointer.base;

	wlr_cursor_attach_input_device(cursor, device);
	if (event->suggested_output)
		wlr_cursor_map_input_to_output(cursor, device, event->suggested_output);
}

Monitor *
xytomon(double x, double y)
{
	struct wlr_output *o = wlr_output_layout_output_at(output_layout, x, y);
	return o ? o->data : NULL;
}

/** Check if a drawin accepts input at a given point (relative to drawin).
 * Returns true if input should be accepted, false if it should pass through.
 * Used for implementing click-through regions via shape_input and shape_bounding.
 *
 * In X11/AwesomeWM, shape_bounding affects both visual AND input regions.
 * shape_input takes precedence if set; otherwise shape_bounding is used.
 */
static bool
drawin_accepts_input_at(drawin_t *d, double local_x, double local_y)
{
	cairo_surface_t *shape;
	int width, height;
	unsigned char *data;
	int stride;
	int px, py;
	int byte_offset, bit_offset;

	if (!d)
		return true;

	/* shape_input takes precedence over shape_bounding */
	shape = d->shape_input;

	/* If no shape_input, fall back to shape_bounding (X11 compatibility) */
	if (!shape)
		shape = d->shape_bounding;

	/* No shape = accept all input */
	if (!shape)
		return true;

	/* Get shape dimensions */
	width = cairo_image_surface_get_width(shape);
	height = cairo_image_surface_get_height(shape);

	/* 0x0 surface means pass through ALL input (AwesomeWM convention) */
	if (width == 0 || height == 0)
		return false;

	/* Convert coordinates to integers */
	px = (int)local_x;
	py = (int)local_y;

	/* Bounds check - outside shape = don't accept */
	if (px < 0 || py < 0 || px >= width || py >= height)
		return false;

	/* Get pixel data (A1 format: 1 bit per pixel, packed) */
	cairo_surface_flush(shape);
	data = cairo_image_surface_get_data(shape);
	stride = cairo_image_surface_get_stride(shape);

	/* A1 format: pixels packed 8 per byte, LSB first */
	byte_offset = (py * stride) + (px / 8);
	bit_offset = px % 8;

	return (data[byte_offset] >> bit_offset) & 1;
}

void
xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable, double *nx, double *ny)
{
	struct wlr_scene_node *node, *pnode;
	struct wlr_surface *surface = NULL;
	Client *c = NULL;
	LayerSurface *l = NULL;
	drawin_t *d = NULL;
	drawable_t *titlebar_drawable = NULL;
	int layer;


	for (layer = NUM_LAYERS - 1; !surface && layer >= 0; layer--) {
		if (!(node = wlr_scene_node_at(&layers[layer]->node, x, y, nx, ny)))
			continue;


		if (node->type == WLR_SCENE_NODE_BUFFER) {
			struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(node);
			struct wlr_scene_surface *scene_surface = wlr_scene_surface_try_from_buffer(buffer);


			if (scene_surface) {
				surface = scene_surface->surface;
			} else {
				/* Check if this buffer belongs to a drawin or titlebar */

				/* node->data now stores drawable pointer (AwesomeWM pattern) */
				if (node->data) {
					drawable_t *drawable = (drawable_t *)node->data;

					if (drawable->owner_type == DRAWABLE_OWNER_DRAWIN) {
						/* This is a drawin's drawable */
						drawin_t *candidate = drawable->owner.drawin;
						/* Check shape_input to see if input passes through */
						if (drawin_accepts_input_at(candidate, x - candidate->x, y - candidate->y)) {
							d = candidate;
							/* For drawins, we found what we need - skip client check */
							goto found;
						}
						/* Input passes through this drawin, continue searching */
					} else if (drawable->owner_type == DRAWABLE_OWNER_CLIENT) {
						/* This is a titlebar drawable - store it and set client
						 * Matches AwesomeWM event.c:76-77 client_get_drawable_offset() */
						c = drawable->owner.client;
						titlebar_drawable = drawable;
						/* Continue to found label with client and titlebar_drawable set */
					}
				}
			}
		}
		/* Walk the tree to find a node that knows the client */
		for (pnode = node; pnode && !c && !d; pnode = &pnode->parent->node) {
			/* Check if this node has a drawin */
			if (pnode->data && layer == LyrWibox) {
				drawin_t *candidate = (drawin_t *)pnode->data;
				/* Check shape_input to see if input passes through */
				if (drawin_accepts_input_at(candidate, x - candidate->x, y - candidate->y)) {
					d = candidate;
					break;
				}
				/* Input passes through, continue searching */
				continue;
			}
			c = pnode->data;
		}
		/* Check type at offset 0 - LayerSurface has 'type' as first field,
		 * but Client has WINDOW_OBJECT_HEADER before client_type.
		 * LayerSurface.type is at offset 0 and set to LayerShell. */
		if (c && *((unsigned int *)c) == LayerShell) {
			l = (LayerSurface *)c;
			c = NULL;
		}
	}

found:
	if (psurface) *psurface = surface;
	if (pc) *pc = c;
	if (pl) *pl = l;
	if (pd) *pd = d;
	if (pdrawable) *pdrawable = titlebar_drawable;
}

void
zoom(const Arg *arg)
{
	Client *c, *sel = focustop(selmon);
	int found_idx = -1;
	int i;

	if (!sel || !selmon || some_client_get_floating(sel))
		return;

	/* Search for the first tiled window that is not sel, marking sel as
	 * NULL if we pass it along the way */
	for (i = 0; i < globalconf.clients.len; i++) {
		c = globalconf.clients.tab[i];
		if (client_on_selected_tags(c) && !some_client_get_floating(c)) {
			if (c != sel) {
				found_idx = i;
				break;
			}
			sel = NULL;
		}
	}

	/* Return if no other tiled window was found */
	if (found_idx == -1)
		return;

	/* If we passed sel, move c to the front; otherwise, move sel to the
	 * front */
	if (!sel)
		sel = c;

	/* Remove sel from array and push to front */
	sync_tiling_reorder(sel);

	focusclient(sel, 1);
	arrange(selmon);
}

#ifdef XWAYLAND
void
activatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, activate);

	/* Only "managed" windows can be activated */
	if (!client_is_unmanaged(c))
		wlr_xwayland_surface_activate(c->surface.xwayland, 1);
}

void
associatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, associate);
	struct wlr_surface *surface = client_surface(c);

	if (!surface) {
		return;
	}

	LISTEN(&surface->events.map, &c->map, mapnotify);
	LISTEN(&surface->events.unmap, &c->unmap, unmapnotify);
}

void
configurex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, configure);
	struct wlr_xwayland_surface_configure_event *event = data;
	if (!client_surface(c) || !client_surface(c)->mapped) {
		wlr_xwayland_surface_configure(c->surface.xwayland,
				event->x, event->y, event->width, event->height);
		return;
	}
	if (client_is_unmanaged(c)) {
		wlr_scene_node_set_position(&c->scene->node, event->x, event->y);
		wlr_xwayland_surface_configure(c->surface.xwayland,
				event->x, event->y, event->width, event->height);
		return;
	}
	if (some_client_get_floating(c)) {
		resize(c, (struct wlr_box){.x = event->x - c->bw,
				.y = event->y - c->bw, .width = event->width + c->bw * 2,
				.height = event->height + c->bw * 2}, 0);
	} else {
		arrange(c->mon);
	}
}

void
createnotifyx11(struct wl_listener *listener, void *data)
{
	/* XWayland client creation - follows same pattern as createnotify()
	 * but adapts for XWayland-specific protocols */
	struct wlr_xwayland_surface *xsurface = data;
	Client *c;
	lua_State *L;

	L = globalconf_get_lua_State();

	/* Create Lua client object (matches AwesomeWM client_manage line 2138) */
	c = client_new(L);
	/* client_new() leaves the client on the Lua stack at index -1 */

	/* Link to XWayland surface (adapts X11 window linkage to XWayland) */
	xsurface->data = c;
	c->surface.xwayland = xsurface;
	c->client_type = X11;
	/* Set the window ID for EWMH/X11 property lookups */
	c->window = xsurface->window_id;
	c->bw = client_is_unmanaged(c) ? 0 : get_border_width();

	/* NOTE: Do NOT call ewmh_client_check_hints() here!
	 * At this point the XWayland surface exists but may not be fully initialized.
	 * Making XCB property queries here can interfere with the XWayland protocol.
	 * EWMH hints will be read in mapnotify() when the surface is ready. */

	/* Register XWayland event listeners */
	LISTEN(&xsurface->events.associate, &c->associate, associatex11);
	LISTEN(&xsurface->events.destroy, &c->destroy, destroynotify);
	LISTEN(&xsurface->events.dissociate, &c->dissociate, dissociatex11);
	LISTEN(&xsurface->events.request_activate, &c->activate, activatex11);
	LISTEN(&xsurface->events.request_configure, &c->configure, configurex11);
	LISTEN(&xsurface->events.request_fullscreen, &c->request_fullscreen, fullscreennotify);
	LISTEN(&xsurface->events.set_hints, &c->set_hints, sethints);
	LISTEN(&xsurface->events.set_title, &c->set_title, updatetitle);

	/* Add to global clients array (matches AwesomeWM client_manage line 2202) */
	lua_pushvalue(L, -1);
	client_array_push(&globalconf.clients, luaA_object_ref(L, -1));

	/* Add to stack (matches AwesomeWM client_manage) */
	stack_client_push(c);

	/* Emit client::list signal (matches AwesomeWM line 2266) */
	luaA_class_emit_signal(L, &client_class, "list", 0);

	/* Pop the client from the Lua stack */
	lua_pop(L, 1);
}

void
dissociatex11(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, dissociate);
	wl_list_remove(&c->map.link);
	wl_list_remove(&c->unmap.link);
}

void
sethints(struct wl_listener *listener, void *data)
{
	Client *c = wl_container_of(listener, c, set_hints);
	xcb_icccm_wm_hints_t *hints = c->surface.xwayland->hints;
	lua_State *L;
	bool dominated;

	if (!hints)
		return;

	/* Check if this client is currently focused (dominated by focus) */
	dominated = (c == focustop(selmon));

	/* Get Lua state for signal emission */
	L = globalconf_get_lua_State();
	luaA_object_push(L, c);

	/* Handle urgency (AwesomeWM pattern: use client_set_urgent for property::urgent signal)
	 * Only process urgency if client is not focused */
	if (!dominated) {
		bool urgent = xcb_icccm_wm_hints_get_urgency(hints);
		if (c->urgent != urgent) {
			client_set_urgent(L, -1, urgent);
		}
	}

	/* Handle input focus hint (XCB_ICCCM_WM_HINT_INPUT)
	 * If input hint is set and false, client should not receive focus */
	if (hints->flags & XCB_ICCCM_WM_HINT_INPUT)
		c->nofocus = !hints->input;

	/* Handle window group (XCB_ICCCM_WM_HINT_WINDOW_GROUP) */
	if (hints->flags & XCB_ICCCM_WM_HINT_WINDOW_GROUP)
		client_set_group_window(L, -1, hints->window_group);

	/* TODO: Handle icon pixmaps (only if no EWMH icon already set)
	 * XCB_ICCCM_WM_HINT_ICON_PIXMAP and optionally XCB_ICCCM_WM_HINT_ICON_MASK
	 * Requires client_set_icon_from_pixmaps() to be properly declared and tested.
	 * Most modern apps use EWMH icons (_NET_WM_ICON) instead of WM_HINTS pixmaps. */

	lua_pop(L, 1);
	printstatus();
}

void
xwaylandready(struct wl_listener *listener, void *data)
{
	struct wlr_xcursor *xcursor;
	xcb_connection_t *conn;
	const xcb_setup_t *setup;
	xcb_screen_iterator_t iter;

	/* assign the one and only seat */
	wlr_xwayland_set_seat(xwayland, seat);

	/* Set the default XWayland cursor to match the rest of somewm. */
	if ((xcursor = wlr_xcursor_manager_get_xcursor(cursor_mgr, "default", 1)))
		wlr_xwayland_set_cursor(xwayland,
				xcursor->images[0]->buffer, xcursor->images[0]->width * 4,
				xcursor->images[0]->width, xcursor->images[0]->height,
				xcursor->images[0]->hotspot_x, xcursor->images[0]->hotspot_y);

	/* Initialize XCB connection for EWMH support (AwesomeWM pattern) */
	conn = xcb_connect(xwayland->display_name, NULL);
	if (xcb_connection_has_error(conn)) {
		fprintf(stderr, "somewm: Failed to connect to XWayland display %s\n",
		        xwayland->display_name);
		return;
	}
	globalconf.connection = conn;

	/* Set up X11 screen structure for EWMH (AwesomeWM pattern) */
	setup = xcb_get_setup(conn);
	iter = xcb_setup_roots_iterator(setup);
	if (!iter.rem) {
		fprintf(stderr, "somewm: XWayland setup has no screens\n");
		return;
	}

	/* Allocate and populate screen structure */
	globalconf.screen = calloc(1, sizeof(*globalconf.screen));
	if (!globalconf.screen) {
		fprintf(stderr, "somewm: Failed to allocate screen structure\n");
		return;
	}
	globalconf.screen->root = iter.data->root;
	globalconf.screen->black_pixel = iter.data->black_pixel;
	globalconf.screen->root_depth = iter.data->root_depth;
	globalconf.screen->root_visual = iter.data->root_visual;

	/* Initialize EWMH atoms (must be done before ewmh_init) */
	init_ewmh_atoms(conn);

	/* Initialize EWMH support on root window */
	ewmh_init(conn, 0);

	/* Connect Lua signals for automatic EWMH property updates */
	ewmh_init_lua();

	fprintf(stderr, "somewm: EWMH support initialized for XWayland\n");
}
#endif

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
			strncpy(distro, start, sizeof(distro) - 1);
			distro[sizeof(distro) - 1] = '\0';
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
				strncpy(driver, start, sizeof(driver) - 1);
				driver[sizeof(driver) - 1] = '\0';
			} else if (strncmp(line, "PCI_ID=", 7) == 0) {
				char *start = line + 7;
				size_t len = strlen(start);
				if (len > 0 && start[len-1] == '\n')
					start[len-1] = '\0';
				strncpy(pci_id, start, sizeof(pci_id) - 1);
				pci_id[sizeof(pci_id) - 1] = '\0';
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

int
main(int argc, char *argv[])
{
	char *startup_cmd = NULL;
	char *check_config = NULL;
	int show_version = 0;
	int c;

	static struct option long_options[] = {
		{"help",    no_argument,       0, 'h'},
		{"version", no_argument,       0, 'v'},
		{"debug",   no_argument,       0, 'd'},
		{"config",  required_argument, 0, 'c'},
		{"search",  required_argument, 0, 'L'},
		{"startup", required_argument, 0, 's'},
		{"check",   required_argument, 0, 'k'},
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
		case 'v':
			show_version = 1;
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
		int result = luaA_check_config(check_config, use_color);
		return result;
	}

	/* Wayland requires XDG_RUNTIME_DIR for creating its communications socket */
	if (!getenv("XDG_RUNTIME_DIR"))
		die("XDG_RUNTIME_DIR must be set");

	/* Pass search paths to Lua init */
	if (num_search_paths > 0)
		luaA_add_search_paths(search_paths, num_search_paths);

	setup();
	run(startup_cmd);
	cleanup();
	return EXIT_SUCCESS;

usage:
	die("Usage: %s [-v] [-d] [-c config] [-L search_path] [-s startup_command] [-k config]\n"
	    "  -v, --version      Show version and diagnostic info\n"
	    "  -d, --debug        Enable debug logging\n"
	    "  -c, --config FILE  Use specified config file (AwesomeWM compatible)\n"
	    "  -L, --search DIR   Add directory to Lua module search path\n"
	    "  -s, --startup CMD  Run command after startup\n"
	    "  -k, --check CONFIG Check config for Wayland compatibility issues", argv[0]);
}
