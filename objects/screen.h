#ifndef SCREEN_H
#define SCREEN_H

#include <lua.h>
#include "../somewm_types.h"
#include "signal.h"
#include "common/luaclass.h"  /* For LUA_OBJECT_HEADER macro */

/* Forward declarations */
struct drawin_t;

/* Screen lifecycle management - who controls the screen */
typedef enum {
	SCREEN_LIFECYCLE_USER = 0,        /* Unmanaged (from fake_add) */
	SCREEN_LIFECYCLE_LUA  = 0x1 << 0, /* Managed internally by Lua */
	SCREEN_LIFECYCLE_C    = 0x1 << 1  /* Managed internally by C */
} screen_lifecycle_t;

/* Screen object structure - wraps Monitor with signal support */
typedef struct screen_t {
	LUA_OBJECT_HEADER              /* Must be first for lua_object_t casting */
	Monitor *monitor;              /* Pointer to underlying wlroots Monitor */
	int index;                     /* Screen index (1-based for Lua) */
	bool valid;                    /* Is this screen still valid? */
	screen_lifecycle_t lifecycle;  /* Who manages this screen's lifecycle */
	struct wlr_box geometry;       /* Cached screen geometry (x, y, width, height) */
	struct wlr_box workarea;       /* Cached workarea (geometry minus struts) */
	char *name;                    /* User-assigned screen name */
} screen_t;

/* Metatable name for screen userdata */
#define SCREEN_MT "screen"

/* Screen class setup (AwesomeWM pattern) */
void screen_class_setup(lua_State *L);

/* Screen object creation and management */
screen_t *luaA_screen_new(lua_State *L, Monitor *m, int index);
void luaA_screen_push(lua_State *L, screen_t *screen);
screen_t *luaA_checkscreen(lua_State *L, int idx);
screen_t *luaA_toscreen(lua_State *L, int idx);
screen_t *luaA_screen_get_by_monitor(lua_State *L, Monitor *m);
screen_t *luaA_screen_get_primary_screen(lua_State *L);

/* Screen scanning and signals (called from somewm.c) */
void luaA_screen_emit_scanning(lua_State *L);
void luaA_screen_emit_scanned(lua_State *L);
bool luaA_screen_scanned_done(void);
void luaA_screen_added(lua_State *L, screen_t *screen);
void luaA_screen_emit_all_added(lua_State *L);
void luaA_screen_removed(lua_State *L, screen_t *screen);
void luaA_screen_emit_list(lua_State *L);
void luaA_screen_emit_viewports(lua_State *L);
void luaA_screen_emit_primary_changed(lua_State *L, screen_t *screen);
screen_t *luaA_screen_getbycoord(lua_State *L, int x, int y);

/* Screen geometry and workarea updates */
void luaA_screen_update_geometry(lua_State *L, screen_t *screen);
void luaA_screen_update_workarea(lua_State *L, screen_t *screen, struct wlr_box *workarea);
void luaA_screen_update_workarea_for_drawin(lua_State *L, struct drawin_t *drawin);
void luaA_monitor_apply_drawin_struts(lua_State *L, Monitor *m, struct wlr_box *area);

/* Screen-client operations (AwesomeWM compatibility) */
struct client_t;
typedef struct wlr_box area_t;
screen_t *screen_getbycoord(int x, int y);
bool screen_area_in_screen(screen_t *, area_t);
void screen_client_moveto(struct client_t *, screen_t *, bool);
Monitor *luaA_monitor_get_by_screen(lua_State *, screen_t *);

/* Object signal support
 * Note: luaA_object_emit_signal() is now declared in awm_luaobject.h
 * as it's a generic function for all object types */
void signal_array_init(signal_array_t *arr);
void signal_array_wipe(signal_array_t *arr);

#endif /* SCREEN_H */
