/*
 * somewm_api.c - Public API implementation for somewm compositor
 *
 * This file implements the public API for interacting with the somewm
 * compositor from external modules (e.g., Lua bindings).
 */

#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#include <math.h>
#include <glib.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_seat.h>

#include "somewm_api.h"
#include "objects/signal.h"
#include "objects/screen.h"
#include "stack.h"
#include "banning.h"
#include "globalconf.h"

/* Declare seat extern before including client.h */
extern struct wlr_seat *seat;

/* External reference to globalconf (defined in somewm.c) */
extern awesome_t globalconf;

/* Include client.h for inline helper functions */
#include "client.h"

/*
 * External references to somewm.c globals and functions
 * These must be made non-static in somewm.c
 */
extern struct wl_list mons;
extern struct wlr_cursor *cursor;
extern Monitor *selmon;
extern KeyboardGroup *kb_group;

/* Functions from somewm.c that need to be made non-static */
extern void focusclient(Client *c, int lift);
/* setfloating() removed - Lua manages floating state */
extern void setfullscreen(Client *c, int fullscreen);
extern void arrange(Monitor *m);
extern void resize(Client *c, struct wlr_box geo, int interact);
extern Client *focustop(Monitor *m);
extern Monitor *xytomon(double x, double y);
extern void setmon(Client *c, Monitor *m, uint32_t newtags);
extern void xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, double *nx, double *ny);
extern Monitor *dirtomon(enum wlr_direction dir);
extern void focusmon(const Arg *arg);
extern void killclient(const Arg *arg);
extern void spawn(const Arg *arg);
extern void tile(Monitor *m);
extern void monocle(Monitor *m);
/* NOTE: moveresize() removed - move/resize now handled by Lua mousegrabber */
extern void togglefloating(const Arg *arg);
extern void setlayout(const Arg *arg);
extern void printstatus(void);
extern void zoom(const Arg *arg);
extern void swapstack(const Arg *arg);
extern void tagmon(const Arg *arg);

/* Settings from somewm.c */
extern int new_client_placement;

/* Scene & compositor state from somewm.c */
extern struct wlr_scene *scene;
extern struct wlr_scene_tree *layers[];
extern struct wlr_output_layout *output_layout;
extern struct wl_display *dpy;
extern struct wl_event_loop *event_loop;
extern struct wlr_layer_shell_v1 *layer_shell;
extern struct wlr_renderer *drw;
extern struct wlr_allocator *alloc;

/* Layouts now managed in Lua - no C layout functions needed */

/* Tag system helper functions from somewm.c */
extern int some_tagcount(void);
extern uint32_t some_tagmask(void);

/* Rules and MonitorRules helper functions from somewm.c */
extern size_t some_rules_length(void);
extern const Rule *some_get_rule_ptr(size_t index);
extern size_t some_monrules_length(void);
extern const MonitorRule *some_get_monrule_ptr(size_t index);

/*
 * Client API Implementation
 */

const char *
some_client_get_title(Client *c)
{
	if (!c)
		return NULL;
	return client_get_title(c);
}

const char *
some_client_get_appid(Client *c)
{
	if (!c)
		return NULL;
	return client_get_appid(c);
}

int
some_client_get_fullscreen(Client *c)
{
	return c ? c->fullscreen : 0;
}

int
some_client_get_urgent(Client *c)
{
	return c ? c->urgent : 0;
}

Monitor *
some_client_get_monitor(Client *c)
{
	return c ? c->mon : NULL;
}

void
some_client_get_geometry(Client *c, struct wlr_box *geom)
{
	if (!c || !geom)
		return;
	client_get_geometry(c, geom);
}

void
some_client_set_floating(Client *c, int floating)
{
	lua_State *L;

	if (!c)
		return;

	/* Set floating via Lua property system (AwesomeWM-compatible) */
	L = globalconf_get_lua_State();
	if (!L)
		return;

	luaA_object_push(L, c);
	lua_pushboolean(L, floating);
	lua_setfield(L, -2, "floating");
	lua_pop(L, 1);
}

void
some_client_set_fullscreen(Client *c, int fullscreen)
{
	if (!c)
		return;
	setfullscreen(c, fullscreen);
}

void
some_client_focus(Client *c, int lift)
{
	focusclient(c, lift);
}

void
some_client_close(Client *c)
{
	if (!c)
		return;
	client_send_close(c);
}

void
some_client_resize(Client *c, struct wlr_box geom, int interact)
{
	if (!c)
		return;
	resize(c, geom, interact);
}

void
some_client_kill(Client *c)
{
	Arg arg;
	if (!c)
		return;
	arg = (Arg){.v = (void *)c};
	killclient(&arg);
}

void
some_client_move_to_monitor(Client *c, Monitor *m, uint32_t tags)
{
	/* Simplified - tags parameter ignored */
	(void)tags;
	if (!c || !m)
		return;
	setmon(c, m, 0);
}

void
some_client_set_geometry(Client *c, int x, int y, int w, int h)
{
	struct wlr_box geom = {.x = x, .y = y, .width = w, .height = h};
	if (!c)
		return;
	resize(c, geom, 0);
}

void
some_client_move(Client *c, int x, int y)
{
	struct wlr_box geom;
	if (!c)
		return;
	some_client_get_geometry(c, &geom);
	geom.x = x;
	geom.y = y;
	resize(c, geom, 0);
}

void
some_client_zoom(void)
{
	Arg arg = {0};
	zoom(&arg);
}

void
some_client_swapstack(int direction)
{
	Arg arg = {.i = direction};
	swapstack(&arg);
}

Client *
some_get_focused_client(void)
{
	return focustop(selmon);
}

Client *
some_client_at(double lx, double ly)
{
	/* This is a simplified version - real implementation would need
	 * to use wlr_scene functions to find the client at coordinates */
	foreach(client, globalconf.clients) {
		Client *c = *client;
		if (c->geometry.x <= lx && lx < c->geometry.x + c->geometry.width &&
		    c->geometry.y <= ly && ly < c->geometry.y + c->geometry.height) {
			return c;
		}
	}
	return NULL;
}

/*
 * Monitor API Implementation
 */

void
some_monitor_get_geometry(Monitor *m, struct wlr_box *geom)
{
	if (!m || !geom)
		return;
	*geom = m->m;
}

void
some_monitor_get_window_area(Monitor *m, struct wlr_box *geom)
{
	if (!m || !geom)
		return;
	*geom = m->w;
}

void
some_monitor_arrange(Monitor *m)
{
	if (!m)
		return;
	arrange(m);
}

Monitor *
some_get_focused_monitor(void)
{
	return selmon;
}

struct wl_list *
some_get_monitors(void)
{
	return &mons;
}

Monitor *
some_monitor_at(double lx, double ly)
{
	return xytomon(lx, ly);
}

Monitor *
some_monitor_from_direction(Monitor *from, enum wlr_direction dir)
{
	if (!from)
		from = selmon;
	return dirtomon(dir);
}

void
some_focus_monitor(Monitor *m)
{
	Client *c;
	if (!m)
		return;
	/* Focus the topmost client on the monitor */
	c = focustop(m);
	if (c) {
		focusclient(c, 1);
	}
	selmon = m;
}

void
some_focus_monitor_direction(enum wlr_direction dir)
{
	Arg arg;
	arg.i = dir;
	focusmon(&arg);
}

void
some_move_client_to_monitor_direction(enum wlr_direction dir)
{
	Arg arg;
	arg.i = dir;
	tagmon(&arg);
}

/*
 * Spawn API Implementation
 */

void
some_spawn_command(const char *cmd)
{
	Arg arg;
	if (!cmd)
		return;
	arg = (Arg){.v = (const char *[]){ "/bin/sh", "-c", cmd, NULL }};
	spawn(&arg);
}

/*
 * Settings API Implementation
 */

int
some_get_new_client_placement(void)
{
	return new_client_placement;
}

void
some_set_new_client_placement(int placement)
{
	new_client_placement = placement;
}

/*
 * Layout API Implementation
 */

/* Layout functions removed - layouts now managed in Lua */

void
some_arrange_all(void)
{
	Monitor *m;
	wl_list_for_each(m, &mons, link)
		arrange(m);
}

/*
 * Global state accessors
 */

struct wlr_seat *
some_get_seat(void)
{
	return seat;
}

struct wlr_cursor *
some_get_cursor(void)
{
	return cursor;
}

struct wl_list *
some_get_keyboard_groups(void)
{
	/* kb_group is a single KeyboardGroup, not a list, but included for API completeness */
	return NULL;
}

/*
 * Scene & compositor state accessors
 */

struct wlr_scene *
some_get_scene(void)
{
	return scene;
}

struct wlr_scene_tree **
some_get_layers(void)
{
	return layers;
}

struct wlr_output_layout *
some_get_output_layout(void)
{
	return output_layout;
}

struct wl_display *
some_get_display(void)
{
	return dpy;
}

struct wl_event_loop *
some_get_event_loop(void)
{
	return event_loop;
}

struct wlr_layer_shell_v1 *
some_get_layer_shell(void)
{
	return layer_shell;
}

struct wlr_renderer *
some_get_renderer(void)
{
	return drw;
}

struct wlr_allocator *
some_get_allocator(void)
{
	return alloc;
}

/*
 * Compositor Control API Implementation
 */

void
some_compositor_quit(void)
{
	fprintf(stderr, "[COMPOSITOR_QUIT] Quitting GLib main loop\n");
	if (globalconf.loop) {
		g_main_loop_quit(globalconf.loop);
	}
	wl_display_terminate(dpy);
}

/*
 * Enhanced Client API
 */

/* Client hierarchy */
Client *
some_client_get_parent(Client *c)
{
	if (!c)
		return NULL;
	return client_get_parent(c);
}

int
some_client_has_children(Client *c)
{
	if (!c)
		return 0;
	return client_has_children(c);
}

/* Visibility & state */
int
some_client_is_visible(Client *c, Monitor *m)
{
	/* Use array-based check instead of bitmask for AwesomeWM compatibility.
	 * Note: monitor parameter is kept for API compatibility, but the function
	 * now gets the monitor from the client itself. */
	(void)m; /* Unused - kept for API compatibility */
	return client_on_selected_tags(c) ? 1 : 0;
}

int
some_client_is_focused(Client *c)
{
	if (!c || !selmon)
		return 0;
	/* Check if this client is the top of the focus stack on the selected monitor */
	return (focustop(selmon) == c);
}

int
some_client_is_stopped(Client *c)
{
	if (!c)
		return 0;
	return client_is_stopped(c);
}

int
some_client_is_float_type(Client *c)
{
	if (!c)
		return 0;
	return client_is_float_type(c);
}

/* Get the floating state from Lua's authoritative property system.
 * This matches AwesomeWM's approach: C doesn't store floating state,
 * it always queries the Lua property which computes (explicit || implicit).
 * Returns 1 if floating, 0 if not, -1 on error.
 */
int
some_client_get_floating(Client *c)
{
	lua_State *L;
	int result = 0;

	if (!c)
		return 0;

	L = globalconf_get_lua_State();
	if (!L)
		return 0;

	/* Push client object onto stack */
	luaA_object_push(L, c);
	if (!lua_isuserdata(L, -1)) {
		lua_pop(L, 1);
		return 0;
	}

	/* Get the "floating" property: c.floating */
	lua_getfield(L, -1, "floating");
	if (lua_isboolean(L, -1)) {
		result = lua_toboolean(L, -1);
	} else if (lua_isnil(L, -1)) {
		/* floating property not set yet, assume false */
		result = 0;
	}

	/* Clean up stack */
	lua_pop(L, 2); /* pop boolean and client */

	return result;
}

/* Properties */
void
some_client_set_urgent(Client *c, int urgent)
{
	if (!c)
		return;
	c->urgent = urgent;
	printstatus();
}

void
some_client_set_border_width(Client *c, unsigned int bw)
{
	if (!c)
		return;
	c->bw = bw;
}

void
some_client_set_border_color(Client *c, const float color[4])
{
	if (!c || !color)
		return;
	client_set_border_color(c, color);
}

void
some_client_set_ontop(Client *c, int ontop)
{
	if (!c)
		return;
	c->ontop = ontop;
	stack_refresh();
}

void
some_client_set_above(Client *c, int above)
{
	if (!c)
		return;
	c->above = above;
	stack_refresh();
}

void
some_client_set_below(Client *c, int below)
{
	if (!c)
		return;
	c->below = below;
	stack_refresh();
}

void
some_client_set_window_type(Client *c, window_type_t window_type)
{
	if (!c)
		return;
	c->type = window_type;
	stack_refresh();
}

int
some_client_get_ontop(Client *c)
{
	return c ? c->ontop : 0;
}

int
some_client_get_above(Client *c)
{
	return c ? c->above : 0;
}

int
some_client_get_below(Client *c)
{
	return c ? c->below : 0;
}

window_type_t
some_client_get_window_type(Client *c)
{
	return c ? c->type : WINDOW_TYPE_NORMAL;
}

Client *
some_client_get_transient_for(Client *c)
{
	return c ? c->transient_for : NULL;
}


void
some_client_set_sticky(Client *c, int sticky)
{
	Monitor *m;

	if (!c || c->sticky == sticky)
		return;

	c->sticky = sticky;

	/* Sticky clients are visible on all tags, so arrange all monitors */
	wl_list_for_each(m, some_get_monitors(), link)
		arrange(m);

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::sticky", c);
}

int
some_client_get_sticky(Client *c)
{
	return c ? c->sticky : 0;
}

void
some_client_set_minimized(Client *c, int minimized)
{
	if (!c || c->minimized == minimized)
		return;

	c->minimized = minimized;

	/* Minimized clients are unmapped from scene */
	if (c->scene && c->scene->node.enabled != !minimized)
		wlr_scene_node_set_enabled(&c->scene->node, !minimized);

	/* Update arrangements */
	if (c->mon)
		arrange(c->mon);

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::minimized", c);
}

int
some_client_get_minimized(Client *c)
{
	return c ? c->minimized : 0;
}

void
some_client_set_hidden(Client *c, int hidden)
{
	if (!c || c->hidden == hidden)
		return;

	c->hidden = hidden;

	/* Hidden clients are not shown in scene */
	if (c->scene && c->scene->node.enabled != !hidden)
		wlr_scene_node_set_enabled(&c->scene->node, !hidden);

	/* Update arrangements */
	if (c->mon)
		arrange(c->mon);

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::hidden", c);
}

int
some_client_get_hidden(Client *c)
{
	return c ? c->hidden : 0;
}

void
some_client_set_modal(Client *c, int modal)
{
	if (!c || c->modal == modal)
		return;

	c->modal = modal;

	/* Modal windows affect stacking */
	stack_refresh();

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::modal", c);
}

int
some_client_get_modal(Client *c)
{
	return c ? c->modal : 0;
}

void
some_client_set_skip_taskbar(Client *c, int skip_taskbar)
{
	if (!c || c->skip_taskbar == skip_taskbar)
		return;

	c->skip_taskbar = skip_taskbar;

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::skip_taskbar", c);
}

int
some_client_get_skip_taskbar(Client *c)
{
	return c ? c->skip_taskbar : 0;
}

void
some_client_set_focusable(Client *c, int focusable)
{
	if (!c)
		return;

	c->focusable = focusable;
	c->focusable_set = 1;

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::focusable", c);
}

int
some_client_get_focusable(Client *c)
{
	if (!c)
		return 0;

	/* If explicitly set, use that value */
	if (c->focusable_set)
		return c->focusable;

	/* Default: most clients are focusable */
	return 1;
}

void
some_client_set_maximized(Client *c, int maximized)
{
	if (!c || c->maximized == maximized)
		return;

	c->maximized = maximized;

	if (maximized) {
		/* Maximized sets both horizontal and vertical */
		c->maximized_horizontal = 1;
		c->maximized_vertical = 1;

		/* Maximized is mutually exclusive with fullscreen */
		if (c->fullscreen)
			some_client_set_fullscreen(c, 0);

		/* Set XDG toplevel maximize state if applicable */
		if (c->client_type == XDGShell && c->surface.xdg->toplevel)
			wlr_xdg_toplevel_set_maximized(c->surface.xdg->toplevel, 1);
	} else {
		c->maximized_horizontal = 0;
		c->maximized_vertical = 0;

		/* Clear XDG toplevel maximize state if applicable */
		if (c->client_type == XDGShell && c->surface.xdg->toplevel)
			wlr_xdg_toplevel_set_maximized(c->surface.xdg->toplevel, 0);
	}

	/* Rearrange monitor to apply new geometry */
	if (c->mon)
		arrange(c->mon);

	/* Emit property change signals */
	luaA_emit_signal_global_with_client("client::property::maximized", c);
	luaA_emit_signal_global_with_client("client::property::maximized_horizontal", c);
	luaA_emit_signal_global_with_client("client::property::maximized_vertical", c);
}

int
some_client_get_maximized(Client *c)
{
	return c ? c->maximized : 0;
}

void
some_client_set_maximized_horizontal(Client *c, int maximized_horizontal)
{
	if (!c || c->maximized_horizontal == maximized_horizontal)
		return;

	c->maximized_horizontal = maximized_horizontal;

	/* Update combined maximized state */
	c->maximized = c->maximized_horizontal && c->maximized_vertical;

	if (maximized_horizontal && c->fullscreen)
		some_client_set_fullscreen(c, 0);

	/* Rearrange monitor to apply new geometry */
	if (c->mon)
		arrange(c->mon);

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::maximized_horizontal", c);
	if (c->maximized)
		luaA_emit_signal_global_with_client("client::property::maximized", c);
}

int
some_client_get_maximized_horizontal(Client *c)
{
	return c ? c->maximized_horizontal : 0;
}

void
some_client_set_maximized_vertical(Client *c, int maximized_vertical)
{
	if (!c || c->maximized_vertical == maximized_vertical)
		return;

	c->maximized_vertical = maximized_vertical;

	/* Update combined maximized state */
	c->maximized = c->maximized_horizontal && c->maximized_vertical;

	if (maximized_vertical && c->fullscreen)
		some_client_set_fullscreen(c, 0);

	/* Rearrange monitor to apply new geometry */
	if (c->mon)
		arrange(c->mon);

	/* Emit property change signal */
	luaA_emit_signal_global_with_client("client::property::maximized_vertical", c);
	if (c->maximized)
		luaA_emit_signal_global_with_client("client::property::maximized", c);
}

int
some_client_get_maximized_vertical(Client *c)
{
	return c ? c->maximized_vertical : 0;
}

/* Stack manipulation */
void
some_client_raise(Client *c)
{
	if (!c)
		return;
	stack_client_push(c);
	stack_refresh();
}

void
some_client_lower(Client *c)
{
	if (!c)
		return;
	stack_client_append(c);
	stack_refresh();
}

/* Surface access */
struct wlr_surface *
some_client_get_surface(Client *c)
{
	if (!c)
		return NULL;
	return client_surface(c);
}

const char *
some_client_get_name(Client *c)
{
	if (!c)
		return NULL;
	return c->name;
}

const char *
some_client_get_class(Client *c)
{
	if (!c)
		return NULL;
	return c->class;
}

const char *
some_client_get_instance(Client *c)
{
	if (!c)
		return NULL;
	return c->instance;
}

const char *
some_client_get_role(Client *c)
{
	if (!c)
		return NULL;
	return c->role;
}

const char *
some_client_get_machine(Client *c)
{
	if (!c)
		return NULL;
	return c->machine;
}

const char *
some_client_get_startup_id(Client *c)
{
	if (!c)
		return NULL;
	return c->startup_id;
}

const char *
some_client_get_icon_name(Client *c)
{
	if (!c)
		return NULL;
	return c->icon_name;
}

uint32_t
some_client_get_pid(Client *c)
{
	return c ? c->pid : 0;
}

/** some_client_update_metadata - Update cached metadata from surface
 * This should be called when a client is created or when surface properties change.
 * Reads properties from the underlying Wayland/X11 surface and caches them.
 */
void
some_client_update_metadata(Client *c)
{
	struct wlr_xdg_toplevel *toplevel;

	if (!c)
		return;

	/* Free old cached values */
	free(c->name);
	free(c->class);
	free(c->instance);
	free(c->role);
	free(c->machine);
	free(c->startup_id);
	free(c->icon_name);
	c->name = c->class = c->instance = c->role = NULL;
	c->machine = c->startup_id = c->icon_name = NULL;
	c->pid = 0;

	/* Update based on client type */
	if (c->client_type == XDGShell) {
		struct wl_client *wl_client;
		struct wlr_surface *surface;

		toplevel = c->surface.xdg->toplevel;

		/* Window title from XDG toplevel */
		if (toplevel->title)
			c->name = strdup(toplevel->title);

		/* app_id is the Wayland equivalent of WM_CLASS */
		if (toplevel->app_id)
			c->class = strdup(toplevel->app_id);

		/* Get PID from wl_client */
		surface = c->surface.xdg->surface;
		if (surface && surface->resource) {
			pid_t pid;
			wl_client = wl_resource_get_client(surface->resource);
			wl_client_get_credentials(wl_client, &pid, NULL, NULL);
			c->pid = (uint32_t)pid;
		}

		/* instance and role don't exist in Wayland (X11 only) */
		c->instance = NULL;
		c->role = NULL;
	}
#ifdef XWAYLAND
	else if (c->client_type == X11) {
		/* X11 clients: read properties from X11 */
		/* WM_NAME (window title) */
		if (c->surface.xwayland->title)
			c->name = strdup(c->surface.xwayland->title);

		/* WM_CLASS (class and instance) */
		if (c->surface.xwayland->class)
			c->class = strdup(c->surface.xwayland->class);
		if (c->surface.xwayland->instance)
			c->instance = strdup(c->surface.xwayland->instance);

		/* PID */
		c->pid = c->surface.xwayland->pid;

		/* For more detailed X11 properties, we'd need xcb queries
		 * but role and machine are rarely used, so skip for now */
		c->role = NULL;
		c->machine = NULL;
	}
#endif

	/* Emit property change signals for metadata that changed */
	luaA_emit_signal_global_with_client("client::property::name", c);
	luaA_emit_signal_global_with_client("client::property::class", c);
	luaA_emit_signal_global_with_client("client::property::instance", c);
	luaA_emit_signal_global_with_client("client::property::pid", c);
}

/*
 * Tag System API Implementation
 */

/* Tag constants */
int
some_get_tag_count(void)
{
	return some_tagcount();
}

uint32_t
some_get_tag_mask(void)
{
	return some_tagmask();
}

/*
 * Config Array Access API Implementation
 */

/*
 * Get monitor output name (e.g., "HDMI-A-1", "eDP-1")
 */
const char *
some_get_monitor_name(Monitor *m)
{
	if (!m || !m->wlr_output)
		return NULL;
	return m->wlr_output->name;
}

/*
 * Get monitor under cursor position
 */
Monitor *
some_monitor_at_cursor(void)
{
	if (!cursor)
		return NULL;
	return xytomon(cursor->x, cursor->y);
}

/*
 * Get current cursor position
 */
void
some_get_cursor_position(double *x, double *y)
{
	if (!cursor) {
		if (x) *x = 0.0;
		if (y) *y = 0.0;
		return;
	}
	if (x) *x = cursor->x;
	if (y) *y = cursor->y;
}

/*
 * Start interactive move of focused client
 * NOTE: This is now a no-op - move/resize is handled by Lua mousegrabber
 * via awful.mouse.client.move() called from client button bindings in rc.lua
 */
void
some_client_start_move(void)
{
	/* No-op: Lua mousegrabber handles move */
}

/*
 * Start interactive resize of focused client
 * NOTE: This is now a no-op - move/resize is handled by Lua mousegrabber
 * via awful.mouse.client.resize() called from client button bindings in rc.lua
 */
void
some_client_start_resize(void)
{
	/* No-op: Lua mousegrabber handles resize */
}

/*
 * Toggle floating mode for focused client
 */
void
some_client_togglefloating(void)
{
	Arg arg = {0};
	togglefloating(&arg);
}

/*
 * Set cursor position (warp cursor)
 * If silent is true, motion events are suppressed
 */
void
some_set_cursor_position(double x, double y, int silent)
{
	if (!cursor)
		return;

	/* If silent mode, set flag to suppress enter/leave events on next motion */
	if (silent) {
		globalconf.mouse_under.ignore_next_enter_leave = true;
	}

	wlr_cursor_warp(cursor, NULL, x, y);
}

/*
 * Get mouse button states
 * Returns pressed state for buttons 1-5 (left, right, middle, side1, side2)
 * Button mapping: BTN_LEFT=1, BTN_RIGHT=2, BTN_MIDDLE=3, BTN_SIDE=4, BTN_EXTRA=5
 *
 * NOTE: We use globalconf.button_state which is tracked in buttonpress(),
 * NOT seat->pointer_state. This is critical for mousegrabber to work correctly.
 * The seat's pointer state only tracks buttons when focused on a surface,
 * but during compositor-level grabs (like window move/resize) there may be
 * no focused surface. globalconf.button_state is always accurate.
 */
void
some_get_button_states(int states[5])
{
	int i;

	if (!states)
		return;

	/* Read from globalconf.button_state which is updated in buttonpress() */
	for (i = 0; i < 5; i++)
		states[i] = globalconf.button_state.buttons[i] ? 1 : 0;
}

/*
 * Get object (client or layer surface) under cursor
 * Returns client pointer if cursor is over a client window
 * Returns NULL if cursor is over background or layer surface
 */
Client *
some_object_under_cursor(void)
{
	if (!cursor)
		return NULL;

	/* Use existing some_client_at function */
	return some_client_at(cursor->x, cursor->y);
}

/*
 * Get drawin under cursor position
 * Returns drawin_t pointer or NULL if no drawin under cursor
 */
drawin_t *
some_drawin_under_cursor(void)
{
	drawin_t *d = NULL;

	if (!cursor)
		return NULL;

	/* Use xytonode to find drawin at cursor position */
	xytonode(cursor->x, cursor->y, NULL, NULL, NULL, &d, NULL, NULL);

	return d;
}

/*
 * Warp cursor to center of specified monitor
 */
void
some_warp_cursor_to_monitor(Monitor *m)
{
	struct wlr_box box;
	extern struct wlr_output_layout *output_layout;

	if (!m || !m->wlr_output || !cursor)
		return;

	/* Get monitor geometry from output layout */
	wlr_output_layout_get_box(output_layout, m->wlr_output, &box);

	/* Warp to center of monitor */
	wlr_cursor_warp(cursor, NULL,
		box.x + box.width / 2,
		box.y + box.height / 2);
}

/*
 * Apply drawin struts (from Lua wibars) to a usable area
 * This is called from arrangelayers() to preserve wibar struts
 */
void
some_monitor_apply_drawin_struts(Monitor *m, struct wlr_box *area)
{
	extern lua_State *globalconf_L;

	if (!globalconf_L || !m || !area)
		return;

	luaA_monitor_apply_drawin_struts(globalconf_L, m, area);
}

/*
 * Focus a client
 */
void
some_focus_client(Client *c, int lift)
{
	focusclient(c, lift);
}

/*
 * Get the top focusable client on a monitor and focus it
 * Returns the focused client
 */
Client *
some_focus_top_client(Monitor *m)
{
	Client *c = focustop(m);
	if (c)
		focusclient(c, 1);
	return c;
}

/*
 * XKB Keyboard Layout API
 *
 * TODO: XKB toggle options (grp:rctrl_toggle, grp:alt_shift_toggle, etc.) don't
 * trigger layout changes via key presses. The API functions work correctly, but
 * xkbcommon's built-in toggle handling isn't being activated by wlroots keyboard
 * group key events. Needs investigation into wlr_keyboard_group's xkb_state
 * update path. Workaround: use keybindings that call xkb_set_layout_group().
 */

/* Deferred XKB signal emission (matches AwesomeWM's xkb_refresh pattern) */
static gboolean
xkb_refresh(gpointer unused)
{
	globalconf.xkb.update_pending = false;

	if (globalconf.xkb.map_changed)
		luaA_emit_signal_global("xkb::map_changed");

	if (globalconf.xkb.group_changed)
		luaA_emit_signal_global("xkb::group_changed");

	globalconf.xkb.map_changed = false;
	globalconf.xkb.group_changed = false;

	return G_SOURCE_REMOVE;
}

static void
xkb_schedule_refresh(void)
{
	if (globalconf.xkb.update_pending)
		return;
	globalconf.xkb.update_pending = true;
	g_idle_add_full(G_PRIORITY_LOW, xkb_refresh, NULL, NULL);
}

void
some_xkb_schedule_group_changed(void)
{
	globalconf.xkb.group_changed = true;
	xkb_schedule_refresh();
}

void
some_xkb_schedule_map_changed(void)
{
	globalconf.xkb.map_changed = true;
	xkb_schedule_refresh();
}

/* Get the current xkb_state from the keyboard group */
struct xkb_state *
some_xkb_get_state(void)
{
	if (!kb_group || !kb_group->wlr_group)
		return NULL;
	return kb_group->wlr_group->keyboard.xkb_state;
}

/* Get the current xkb_keymap from the keyboard group */
struct xkb_keymap *
some_xkb_get_keymap(void)
{
	if (!kb_group || !kb_group->wlr_group)
		return NULL;
	return kb_group->wlr_group->keyboard.keymap;
}

/* Set the keyboard layout group
 * In Wayland, we update the xkb_state directly and notify clients.
 * Returns 1 on success, 0 on failure
 */
int
some_xkb_set_layout_group(xkb_layout_index_t group)
{
	struct xkb_state *xkb_state;
	struct xkb_keymap *keymap;
	xkb_layout_index_t num_layouts;
	xkb_mod_mask_t depressed, latched, locked;
	xkb_layout_index_t old_group;

	if (!kb_group || !kb_group->wlr_group)
		return 0;

	xkb_state = kb_group->wlr_group->keyboard.xkb_state;
	keymap = kb_group->wlr_group->keyboard.keymap;

	if (!xkb_state || !keymap)
		return 0;

	/* Validate group index */
	num_layouts = xkb_keymap_num_layouts(keymap);
	if (group >= num_layouts)
		return 0;

	/* Get current modifier state (preserve it while changing layout) */
	depressed = xkb_state_serialize_mods(xkb_state, XKB_STATE_MODS_DEPRESSED);
	latched = xkb_state_serialize_mods(xkb_state, XKB_STATE_MODS_LATCHED);
	locked = xkb_state_serialize_mods(xkb_state, XKB_STATE_MODS_LOCKED);

	/* Get current group for comparison */
	old_group = xkb_state_serialize_layout(xkb_state, XKB_STATE_LAYOUT_EFFECTIVE);

	/* Update xkb_state with new layout group (locked layout) */
	xkb_state_update_mask(xkb_state,
		depressed, latched, locked,  /* preserve modifiers */
		0,      /* depressed_layout */
		0,      /* latched_layout */
		group); /* locked_layout = new layout */

	/* Notify clients of modifier change (which includes layout) */
	wlr_seat_keyboard_notify_modifiers(seat,
		&kb_group->wlr_group->keyboard.modifiers);

	/* Emit signal if layout actually changed */
	if (old_group != group) {
		globalconf.xkb.last_group = group;
		some_xkb_schedule_group_changed();
	}

	return 1;
}

/* Get the XKB group names/symbols string
 * Returns a static buffer with format like "pc+English (US)+Russian"
 */
const char *
some_xkb_get_group_names(void)
{
	static char symbols_buffer[512];
	struct xkb_keymap *keymap;
	xkb_layout_index_t num_layouts, i;
	size_t offset = 0;

	if (!kb_group || !kb_group->wlr_group)
		return NULL;

	keymap = kb_group->wlr_group->keyboard.keymap;
	if (!keymap)
		return NULL;

	/* Build symbols string from keymap layout names */
	num_layouts = xkb_keymap_num_layouts(keymap);

	/* Start with "pc+" prefix (matches XKB convention) */
	offset = snprintf(symbols_buffer, sizeof(symbols_buffer), "pc");

	for (i = 0; i < num_layouts && offset < sizeof(symbols_buffer) - 1; i++) {
		const char *name = xkb_keymap_layout_get_name(keymap, i);
		if (name) {
			offset += snprintf(symbols_buffer + offset,
			                   sizeof(symbols_buffer) - offset,
			                   "+%s", name);
		}
	}

	/* Append XKB options if configured */
	if (globalconf.keyboard.xkb_options &&
	    *globalconf.keyboard.xkb_options &&
	    offset < sizeof(symbols_buffer) - 1) {
		offset += snprintf(symbols_buffer + offset,
		                   sizeof(symbols_buffer) - offset,
		                   "+%s", globalconf.keyboard.xkb_options);
	}

	return symbols_buffer;
}

/* External references needed for keymap rebuild */
extern struct wl_event_loop *some_get_event_loop(void);

/* Rebuild the keyboard keymap from current globalconf settings */
void
some_rebuild_keyboard_keymap(void)
{
	struct xkb_context *context;
	struct xkb_keymap *keymap;
	struct xkb_rule_names rules = {0};

	if (!kb_group || !kb_group->wlr_group)
		return;

	context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (!context)
		return;

	rules.layout = globalconf.keyboard.xkb_layout;
	rules.variant = globalconf.keyboard.xkb_variant;
	rules.options = globalconf.keyboard.xkb_options;

	keymap = xkb_keymap_new_from_names(context, &rules,
	                                   XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (keymap) {
		wlr_keyboard_set_keymap(&kb_group->wlr_group->keyboard, keymap);
		xkb_keymap_unref(keymap);
		some_xkb_schedule_map_changed();
	}

	xkb_context_unref(context);
}
