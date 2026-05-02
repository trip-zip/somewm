#ifndef CLAY_LAYOUT_H
#define CLAY_LAYOUT_H

#include <lua.h>

#include <wlr/util/box.h>

typedef struct client_t client_t;
typedef struct LayerSurface LayerSurface;

/* Register the _somewm_clay global table with Lua bindings */
void luaA_clay_setup(lua_State *L);

/* Free all per-screen Clay contexts and arena memory (hot-reload) */
void clay_cleanup(void);

/* Apply pending layout results to client geometry.
 * Called from some_refresh() at Step 1.75. */
void clay_apply_all(void);

/* Per-client decoration sub-pass. Builds a Clay tree of borders + titlebars
 * + surface for c, then writes computed positions to c->scene's children
 * (borders, titlebar buffers, c->scene_surface). c->scene's own outer node
 * is positioned by the caller; Clay only owns the inner geometry.
 * The surface element's size is returned via *out_inner_w / *out_inner_h
 * for the caller to forward to client_set_size(). */
void clay_apply_client_decorations(client_t *c, int *out_inner_w, int *out_inner_h);

/* Phase 13: layer-shell sub-pass. Replaces wlr_scene_layer_surface_v1_configure
 * by building a Clay tree from the layer surface's anchor / exclusive_zone /
 * margin / desired_size. Sends the configure event, positions the scene node,
 * and subtracts the exclusive zone from *usable_area per protocol semantics.
 *
 * `layout_box` is the bounding box the surface lays out within. Per
 * layer-shell v1 spec, surfaces with exclusive_zone >= 0 must lay out within
 * the *usable* area (respecting other exclusives); only exclusive_zone == -1
 * lays out within the full monitor area. The caller is responsible for
 * picking the right box. */
void clay_apply_layer_surface(LayerSurface *l, struct wlr_box layout_box,
                              struct wlr_box *usable_area);

#endif
