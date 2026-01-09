/*
 * layer_surface.h - Layer shell surface object for Lua
 *
 * This module exposes layer shell surfaces (panels, launchers, lock screens)
 * to Lua with a signal/permission model matching AwesomeWM's client pattern.
 *
 * Layer surfaces inherit from window_class to get opacity, strut, buttons.
 */

#ifndef SOMEWM_LAYER_SURFACE_H
#define SOMEWM_LAYER_SURFACE_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>
#include "objects/window.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "common/array.h"

/* Forward declarations */
struct screen_t;
struct wlr_layer_surface_v1;
struct wlr_scene_tree;
struct wlr_scene_layer_surface_v1;

/* LayerSurface is defined in somewm_types.h */
#include "../somewm_types.h"

/* Include globalconf.h for layer_surface_array_t (needed by ARRAY_FUNCS below) */
#include "../globalconf.h"

/**
 * Layer surface Lua object structure
 *
 * This wraps the C-level LayerSurface struct and provides Lua integration.
 * Uses WINDOW_OBJECT_HEADER for AwesomeWM compatibility (opacity, strut, buttons).
 *
 * Properties from protocol (read-only):
 *   - namespace: Application identifier (e.g., "waybar", "rofi")
 *   - layer: One of "background", "bottom", "top", "overlay"
 *   - keyboard_interactive: "none", "exclusive", "on_demand"
 *   - exclusive_zone: Pixels reserved for exclusive use
 *   - anchor: Table with top, bottom, left, right booleans
 *   - margin: Table with top, bottom, left, right numbers
 *   - geometry: Table with x, y, width, height
 *   - screen: The screen this surface is on
 *   - mapped: Whether the surface is currently mapped
 *   - pid: Process ID of the client
 *
 * Properties (compositor-controlled):
 *   - has_keyboard_focus: Whether this surface has keyboard focus
 */
typedef struct layer_surface_t {
	WINDOW_OBJECT_HEADER           /* Base window fields (opacity, strut, buttons, etc.) */

	/* Link to C-level LayerSurface struct */
	LayerSurface *ls;              /* Pointer to underlying wlroots layer surface wrapper */

	/* Compositor-controlled properties */
	bool has_keyboard_focus;       /* Whether this surface has keyboard focus */

	/* Screen assignment */
	struct screen_t *screen;       /* Which screen this layer surface belongs to */
} layer_surface_t;

/* Layer surface class (global) */
extern lua_class_t layer_surface_class;

/* layer_surface_array_t is defined in globalconf.h
 * Generate array functions here so they're available to luaa.c */
ARRAY_FUNCS(layer_surface_t *, layer_surface, DO_NOTHING)

/* Generate helper functions for layer_surface class */
LUA_OBJECT_FUNCS(layer_surface_class, layer_surface_t, layer_surface)

/* Layer surface-specific wrappers for class system check/to functions */
static inline layer_surface_t *
luaA_checklayer_surface(lua_State *L, int idx)
{
	return (layer_surface_t *)luaA_checkudata(L, idx, &layer_surface_class);
}

static inline layer_surface_t *
luaA_tolayer_surface(lua_State *L, int idx)
{
	return (layer_surface_t *)luaA_toudata(L, idx, &layer_surface_class);
}

/**
 * Setup the layer_surface Lua class.
 * Called from luaa.c during initialization.
 * @param L The Lua state.
 */
void layer_surface_class_setup(lua_State *L);

/**
 * Create and manage a Lua layer_surface object for a C LayerSurface.
 * Called when a layer shell surface is mapped.
 * @param L The Lua state.
 * @param ls The C-level LayerSurface struct.
 * @return The new layer_surface_t object (also pushed to stack).
 */
layer_surface_t *layer_surface_manage(lua_State *L, LayerSurface *ls);

/**
 * Emit request::manage signal for a newly mapped layer surface.
 * @param ls The layer_surface_t object.
 */
void layer_surface_emit_manage(layer_surface_t *ls);

/**
 * Emit request::keyboard signal when a layer surface requests keyboard focus.
 * @param ls The layer_surface_t object.
 * @param context "exclusive" or "on_demand"
 */
void layer_surface_emit_request_keyboard(layer_surface_t *ls, const char *context);

/**
 * Emit request::unmanage signal when a layer surface unmaps.
 * @param ls The layer_surface_t object.
 */
void layer_surface_emit_unmanage(layer_surface_t *ls);

/**
 * Grant keyboard focus to a layer surface.
 * Called from Lua when setting has_keyboard_focus = true.
 * @param ls The layer_surface_t object.
 */
void layer_surface_focus(layer_surface_t *ls);

/**
 * Revoke keyboard focus from a layer surface.
 * Called from Lua when setting has_keyboard_focus = false.
 * @param ls The layer_surface_t object.
 */
void layer_surface_unfocus(layer_surface_t *ls);

/**
 * Get all layer surfaces.
 * Pushes an array of layer_surface objects to the Lua stack.
 * @param L The Lua state.
 * @return Number of values pushed (1 - the array).
 */
int luaA_layer_surface_get(lua_State *L);

/**
 * Refresh layer surfaces (called from main event loop if needed).
 */
void layer_surface_refresh(void);

/**
 * Get the layer name as a string.
 * @param layer The wlr_layer_shell_v1_layer enum value.
 * @return Static string: "background", "bottom", "top", or "overlay".
 */
const char *layer_surface_layer_name(uint32_t layer);

/**
 * Get the keyboard interactivity mode as a string.
 * @param mode The zwlr_layer_surface_v1_keyboard_interactivity enum value.
 * @return Static string: "none", "exclusive", or "on_demand".
 */
const char *layer_surface_keyboard_mode_name(uint32_t mode);

#endif /* SOMEWM_LAYER_SURFACE_H */
