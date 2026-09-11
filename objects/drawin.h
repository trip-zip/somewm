#ifndef DRAWIN_H
#define DRAWIN_H

#include <lua.h>
#include <stdbool.h>
#include <cairo.h>
#include "../somewm_types.h"
#include "objects/window.h"  /* For WINDOW_OBJECT_HEADER */
#include "../color.h"
#include "signal.h"
#include "common/luaclass.h"  /* For lua_class_t */
#include "common/luaobject.h"  /* For LUA_OBJECT_FUNCS macro */
#include "shadow.h"           /* Shadow configuration and textures */
#include "../render.h"
#include "../widget.h"
#include "../render_image.h"  /* For struct image_entry */

struct widget_shape {
	struct render_shape shape;
	int ref;
};

/* Forward declarations */
struct screen_t;
struct drawable_t;
struct widget_node;

/* Drawin object structure - represents a drawable window (wibox/panel/popup)
 *
 * Uses WINDOW_OBJECT_HEADER for AwesomeWM compatibility.
 * Fields from WINDOW_OBJECT_HEADER:
 *   - LUA_OBJECT_HEADER (signals)
 *   - uint32_t window, frame_window (0 for Wayland)
 *   - double opacity
 *   - strut_t strut
 *   - button_array_t buttons
 *   - bool border_need_update
 *   - color_t border_color
 *   - uint16_t border_width
 *   - window_type_t type
 *   - void (*border_width_callback)(...)
 */
typedef struct drawin_t {
	WINDOW_OBJECT_HEADER           /* Base window fields from AwesomeWM */

	/* Geometry */
	int x;
	int y;
	int width;
	int height;
	bool geometry_dirty;           /* Pending geometry update flag */

	/* Properties */
	bool visible;                  /* Is drawin currently displayed? */
	bool ontop;                    /* Should drawin be above other windows? */
	char *cursor;                  /* Mouse cursor name (e.g., "left_ptr") */

	/* Surface scale override (somewm extension, not in AwesomeWM).
	 * 0.0 = auto (use output scale), >0.0 = force this scale for masks and borders.
	 * Avoids HiDPI CPU upscaling for content like screenshot overlays. */
	float scale_override;

	/* Screen assignment */
	struct screen_t *screen;       /* Which screen this drawin belongs to */

	/* Drawable for rendering (AwesomeWM pattern: stored in uservalue table)
	 * Pointer retrieved via luaA_object_ref_item, pushed via luaA_object_push_item */
	struct drawable_t *drawable;   /* Direct C pointer for callback access */

	color_t border_color_parsed;            /* Cached parsed color for efficient refresh */

	/* Shadow support (compositor-level, replaces picom shadows) */
	shadow_config_t *shadow_config;         /* Per-drawin override (NULL = use defaults) */

	/* Shape properties (AwesomeWM compatibility)
	 * These are cairo_surface_t* alpha masks, either A1 (AwesomeWM's
	 * format) or ARGB32 (somewm's, for anti-aliased edges).
	 * NULL means no custom shape (full rectangle). */
	cairo_surface_t *shape_bounding;        /* Visual bounding shape (rounded corners, etc.) */
	cairo_surface_t *shape_clip;            /* Drawing clip region */
	cairo_surface_t *shape_input;           /* Input hit-test region (click-through) */
	cairo_surface_t *shape_border;          /* Pre-rendered anti-aliased border (ARGB32) */
	/* Content corner radius of rounded bounding and clip masks, including
	 * bordered shapes. -1 means the masks are not one rounded rectangle
	 * and the converted drawin draws unshaped. Set at every mask change. */
	float shape_radius;

	/* Stable border and shadow image entries, owned by the drawin. */
	struct image_entry border_entry;
	struct shadow_leaves shadow;

	/* The described widget tree (widget.h) and its image entries in
	 * preorder. Empty until the drawable's first compile stores a tree,
	 * which is what lets a visible drawin declare (declare.c). */
	struct widget_tree widgets;
} drawin_t;

bool drawin_widget_host(drawin_t *d, struct widget_host *out);

/* Metatable name for drawin userdata */
#define DRAWIN_MT "drawin"

/* AwesomeWM class system - drawin class variable */
extern lua_class_t drawin_class;

/* Generate helper functions for drawin class (new, push, check, etc.) */
LUA_OBJECT_FUNCS(drawin_class, drawin_t, drawin)

/* Drawin-specific wrappers for class system check/to functions */
static inline drawin_t *
luaA_checkdrawin(lua_State *L, int idx)
{
	return (drawin_t *)luaA_checkudata(L, idx, &drawin_class);
}

static inline drawin_t *
luaA_todrawin(lua_State *L, int idx)
{
	return (drawin_t *)luaA_toudata(L, idx, &drawin_class);
}

/* Drawin class setup and lifecycle */
void luaA_drawin_setup(lua_State *L);
void drawin_class_setup(lua_State *L);

/* Drawin geometry synchronization (external API - for wibox code etc) */
void luaA_drawin_set_geometry(lua_State *L, drawin_t *drawin, int x, int y, int width, int height);
void luaA_drawin_set_strut(lua_State *L, drawin_t *drawin, strut_t strut);

/* Drawin geometry synchronization */
void luaA_drawin_apply_geometry(drawin_t *drawin);

/* Mark the output this drawin is on stale, so the next frame re-declares it.
 * A no-op for a drawin with no screen yet, or a screen with no monitor. */
void drawin_mark_dirty(drawin_t *drawin);

/* Drawin refresh cycle (called from main event loop) */
void drawin_refresh(void);

/* Object signal support
 * Note: luaA_object_emit_signal() is now declared in awm_luaobject.h
 * as it's a generic function for all object types (defined in awm_luaobject.c) */

#endif /* DRAWIN_H */
