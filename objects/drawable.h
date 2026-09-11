#ifndef DRAWABLE_H
#define DRAWABLE_H

#include <lua.h>
#include <cairo.h>
#include <stdbool.h>
#include <wlr/util/box.h>
#include "common/luaclass.h"

/* Forward declarations */
struct wlr_buffer;
typedef struct wlr_box area_t;  /* Already defined elsewhere, but repeated for clarity */
typedef struct drawin_t drawin_t;  /* Forward declare drawin */
typedef struct client_t client_t;  /* Forward declare client */


/* Drawable owner type - tracks what owns this drawable (AwesomeWM pattern) */
typedef enum {
	DRAWABLE_OWNER_NONE,    /* No owner (orphaned drawable) */
	DRAWABLE_OWNER_DRAWIN,  /* Owned by a drawin (standalone window) */
	DRAWABLE_OWNER_CLIENT   /* Owned by client titlebar */
} drawable_owner_type_t;

/* Drawable geometry and owner, using the AwesomeWM class system. */
typedef struct drawable_t {
	LUA_OBJECT_HEADER  /* Adds signals, refs, class - replaces signal_array_t */

	/* X11 pixmap stub (for AwesomeWM compatibility) - always 0 on Wayland */
	uint32_t pixmap;

	/* Geometry (AwesomeWM uses area_t instead of separate x/y/width/height) */
	area_t geometry;

	/* Object validity flag - false when being garbage collected */
	bool valid;

	/* Owner tracking (AwesomeWM pattern) - tracks which object owns this drawable */
	drawable_owner_type_t owner_type;
	union {
		void *ptr;           /* Generic pointer */
		drawin_t *drawin;    /* When owner_type == DRAWABLE_OWNER_DRAWIN */
		client_t *client;    /* When owner_type == DRAWABLE_OWNER_CLIENT */
	} owner;
} drawable_t;

/* Drawable class (AwesomeWM class system) */
extern lua_class_t drawable_class;

/* Drawable class setup (AwesomeWM API) */
drawable_t *drawable_allocator(lua_State *L);
void drawable_set_geometry(lua_State *L, int didx, area_t geom);
void drawable_class_setup(lua_State *L);

/* somewm setup helper (called from luaa.c) */
void luaA_drawable_setup(lua_State *L);

/* The converted tree and its box, resolved through the drawable owner. */
struct widget_host;
int drawable_push(lua_State *L, drawable_t *d);
bool drawable_widget_host(drawable_t *d, struct widget_host *out);

/* Buffer creation from raw Cairo pixel data (for non-drawable Cairo surfaces) */
struct wlr_buffer *drawable_create_buffer_from_data(int width, int height, const void *cairo_data, size_t cairo_stride);

#endif /* DRAWABLE_H */
