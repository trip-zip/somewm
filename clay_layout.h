#ifndef CLAY_LAYOUT_H
#define CLAY_LAYOUT_H

#include <lua.h>
#include <stdbool.h>

#include <wlr/util/box.h>

typedef struct client_t client_t;
typedef struct screen_t screen_t;
typedef struct LayerSurface LayerSurface;
typedef struct _cairo cairo_t;  /* matches cairo.h; avoids a hard cairo include */

/* Register the _somewm_clay global table with Lua bindings */
void luaA_clay_setup(lua_State *L);

/* Free all per-screen Clay contexts and arena memory (hot-reload) */
void clay_cleanup(void);

/* Release a removed screen's Clay context (arena, results, debug overlay) and
 * free its slot for reuse. Called from screen_removed() on output unplug. */
void clay_screen_removed(lua_State *L, screen_t *s);

/* Apply pending layout results to client geometry.
 * Called from some_refresh() at Step 1.75. */
void clay_apply_all(void);

/* Tree == scene assertion mode, read once from SOMEWM_TREE_ASSERT at startup
 * (OFF / WARN / ABORT, case-insensitive; default WARN). Gate-phase scaffolding:
 * set here but not yet consulted by any check. */
void clay_tree_assert_init(void);

/* Clay debug view (hierarchy inspector + hover highlight).
 * clay_debug_mark_dirty(): flag a pending overlay re-solve (called from the
 * pointer/button input path; no-ops unless debug is on).
 * clay_debug_tick(): drive at most one debug re-solve per event-loop
 * iteration; called from some_refresh() after clay_apply_all(). */
void clay_debug_mark_dirty(void);
void clay_debug_tick(void);

/* Composite the debug overlay(s) onto a screenshot cairo context (root.content
 * captures clients + drawins but not the standalone overlay buffer). No-op when
 * debug is off. */
void clay_debug_composite_screenshot(cairo_t *cr);

/* Per-client fallback frame solve. Builds a Clay tree of borders + titlebars
 * + surface for c, then writes computed positions to c->scene's children
 * (borders, titlebar buffers, c->scene_surface). c->scene's own outer node
 * is positioned by the caller; Clay only owns the inner geometry.
 * The surface element's size is returned via *out_inner_w / *out_inner_h
 * for the caller to forward to client_set_size(). */
void clay_apply_client_frame(client_t *c, int *out_inner_w, int *out_inner_h);

/* Apply frame boxes computed by the merged screen solve (c->merged_frame)
 * instead of the per-client solve above. Returns false when that scratch is
 * absent or stale for the live client state, so the caller falls back to
 * clay_apply_client_frame(). */
bool clay_consume_merged_frame(client_t *c, int *out_inner_w, int *out_inner_h);

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
