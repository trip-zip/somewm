/*
 * shadow.h - compositor-level shadow support
 *
 * Copyright © 2025 somewm contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#ifndef SOMEWM_SHADOW_H
#define SOMEWM_SHADOW_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_buffer.h>
#include <cairo/cairo.h>

/**
 * Shadow configuration for a single object (client or drawin).
 *
 * When NULL on an object, global defaults from globalconf are used.
 * When non-NULL, these values override the defaults.
 */
typedef struct shadow_config_t {
    bool enabled;           /**< Shadow enabled for this object */
    int radius;             /**< Blur radius in pixels (picom default: 12) */
    int offset_x;           /**< Horizontal offset (picom default: -15) */
    int offset_y;           /**< Vertical offset (picom default: -15) */
    float opacity;          /**< Shadow opacity 0.0-1.0 (picom default: 0.75) */
    float color[4];         /**< Shadow color RGBA (default: black) */
} shadow_config_t;

/**
 * Pre-rendered shadow texture cache entry.
 *
 * Shadows with the same radius and color share textures.
 * The 9-slice approach uses:
 *   - 4 corner textures (fixed size: 2*radius x 2*radius)
 *   - 4 edge textures (1px thick strips that get stretched)
 */
typedef struct shadow_cache_entry_t {
    int radius;                      /**< Radius this was rendered for */
    float color[4];                  /**< Color this was rendered for */
    float opacity;                   /**< Opacity this was rendered for */
    struct wlr_buffer *corner_tl;    /**< Top-left corner */
    struct wlr_buffer *corner_tr;    /**< Top-right corner */
    struct wlr_buffer *corner_bl;    /**< Bottom-left corner */
    struct wlr_buffer *corner_br;    /**< Bottom-right corner */
    struct wlr_buffer *edge_top;     /**< Top edge (1px tall, 1px wide) */
    struct wlr_buffer *edge_bottom;  /**< Bottom edge */
    struct wlr_buffer *edge_left;    /**< Left edge (1px wide, 1px tall) */
    struct wlr_buffer *edge_right;   /**< Right edge */
    int refcount;                    /**< Reference count for caching */
    struct shadow_cache_entry_t *next; /**< Linked list for cache */
} shadow_cache_entry_t;

/**
 * Shadow scene nodes attached to a client or drawin.
 *
 * This structure is embedded in client_t and drawin_t.
 * The 8 buffer nodes correspond to the 9-slice pattern:
 *   [0] = corner_tl, [1] = edge_top, [2] = corner_tr
 *   [3] = edge_left,                 [4] = edge_right
 *   [5] = corner_bl, [6] = edge_bottom, [7] = corner_br
 */
typedef struct shadow_nodes_t {
    struct wlr_scene_tree *tree;            /**< Container for shadow nodes */
    struct wlr_scene_buffer *buffer[8];     /**< 9-slice buffers (4 corners + 4 edges) */
    shadow_cache_entry_t *cache;            /**< Reference to cached textures */
} shadow_nodes_t;

/* Shadow indices for buffer array */
enum {
    SHADOW_CORNER_TL = 0,
    SHADOW_EDGE_TOP = 1,
    SHADOW_CORNER_TR = 2,
    SHADOW_EDGE_LEFT = 3,
    SHADOW_EDGE_RIGHT = 4,
    SHADOW_CORNER_BL = 5,
    SHADOW_EDGE_BOTTOM = 6,
    SHADOW_CORNER_BR = 7,
    SHADOW_NODE_COUNT = 8
};

/**
 * Global shadow defaults (stored in globalconf.shadow).
 */
typedef struct shadow_defaults_t {
    shadow_config_t client;   /**< Default for clients */
    shadow_config_t drawin;   /**< Default for drawins/wiboxes */
} shadow_defaults_t;

/* ========== Core API ========== */

/**
 * Initialize shadow subsystem.
 * Call once at compositor startup.
 */
void shadow_init(void);

/**
 * Cleanup shadow subsystem.
 * Call at compositor shutdown to free cached textures.
 */
void shadow_cleanup(void);

/**
 * Get effective shadow configuration for an object.
 *
 * @param override Object-specific config (may be NULL for defaults)
 * @param is_drawin true for drawin, false for client
 * @return Effective configuration (never NULL, returns pointer to defaults if override is NULL)
 */
const shadow_config_t *shadow_get_effective_config(
    const shadow_config_t *override, bool is_drawin);

/* ========== Shadow Rendering ========== */

/**
 * Create shadow nodes for an object.
 *
 * Creates the shadow_tree as a child of the given parent tree,
 * positioned below (behind) other content.
 *
 * @param parent Parent scene tree (client->scene or drawin->scene_tree)
 * @param shadow Shadow nodes structure to populate
 * @param config Shadow configuration to use
 * @param width Object width in pixels
 * @param height Object height in pixels
 * @return true on success, false on failure
 */
bool shadow_create(struct wlr_scene_tree *parent,
                   shadow_nodes_t *shadow,
                   const shadow_config_t *config,
                   int width, int height);

/**
 * Update shadow geometry after object resize.
 *
 * @param shadow Shadow nodes structure
 * @param config Shadow configuration
 * @param width New object width
 * @param height New object height
 */
void shadow_update_geometry(shadow_nodes_t *shadow,
                           const shadow_config_t *config,
                           int width, int height);

/**
 * Update shadow configuration (radius, color, etc changed).
 *
 * This may re-render textures if configuration changed significantly.
 *
 * @param shadow Shadow nodes structure
 * @param config New configuration
 * @param width Object width
 * @param height Object height
 */
void shadow_update_config(shadow_nodes_t *shadow,
                         const shadow_config_t *config,
                         int width, int height);

/**
 * Show or hide shadow.
 *
 * @param shadow Shadow nodes structure
 * @param visible true to show, false to hide
 */
void shadow_set_visible(shadow_nodes_t *shadow, bool visible);

/**
 * Destroy shadow nodes and release cache reference.
 *
 * @param shadow Shadow nodes structure to cleanup
 */
void shadow_destroy(shadow_nodes_t *shadow);

/* ========== Cache Management ========== */

/**
 * Get or create cached shadow textures for given configuration.
 *
 * @param radius Blur radius
 * @param color RGBA color
 * @param opacity Shadow opacity
 * @return Cache entry (refcount incremented), or NULL on failure
 */
shadow_cache_entry_t *shadow_cache_get(int radius, const float color[4], float opacity);

/**
 * Release reference to cache entry.
 *
 * @param entry Cache entry to release
 */
void shadow_cache_put(shadow_cache_entry_t *entry);

/**
 * Clear all cached shadow textures.
 * Useful when theme changes.
 */
void shadow_cache_clear(void);

/* ========== Lua Integration ========== */

/**
 * Parse shadow configuration from Lua value.
 *
 * Accepts:
 *   - boolean: true = use defaults, false = disabled
 *   - table: { radius = N, offset_x = N, ... }
 *
 * @param L Lua state
 * @param idx Stack index of value
 * @param config Config structure to populate
 * @return true if valid, false if invalid (leaves error on stack)
 */
bool shadow_config_from_lua(lua_State *L, int idx, shadow_config_t *config);

/**
 * Push shadow configuration to Lua.
 *
 * @param L Lua state
 * @param config Config to push (NULL pushes nil)
 */
void shadow_config_to_lua(lua_State *L, const shadow_config_t *config);

/**
 * Get shadow defaults from beautiful theme.
 *
 * Reads beautiful.shadow_* properties and updates globalconf.shadow.
 * Called during theme loading.
 *
 * @param L Lua state
 */
void shadow_load_beautiful_defaults(lua_State *L);

#endif /* SOMEWM_SHADOW_H */
