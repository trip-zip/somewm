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

/**
 * Shadow slice indices for 9-slice rendering.
 *
 * Layout:
 *   TL  TOP  TR
 *   L   ---   R
 *   BL  BOT  BR
 */
enum {
    SHADOW_CORNER_TL = 0,
    SHADOW_EDGE_TOP,
    SHADOW_CORNER_TR,
    SHADOW_EDGE_LEFT,
    SHADOW_EDGE_RIGHT,
    SHADOW_CORNER_BL,
    SHADOW_EDGE_BOTTOM,
    SHADOW_CORNER_BR,
    SHADOW_FILL_H,       /**< Horizontal fill strip for vertical offset gap */
    SHADOW_FILL_V,       /**< Vertical fill strip for horizontal offset gap */
    SHADOW_SLICE_COUNT
};

/** Number of owned texture buffers (4 corners + h edge + v edge + 1x1 fill) */
#define SHADOW_TEXTURE_COUNT 7

/**
 * Shadow configuration for a single object (client or drawin).
 *
 * When NULL on an object, global defaults from globalconf are used.
 * When non-NULL, these values override the defaults.
 */
typedef struct shadow_config_t {
    bool enabled;           /**< Shadow enabled for this object */
    int radius;             /**< Shadow spread radius in pixels (default: 12) */
    int offset_x;           /**< Horizontal offset (default: 0) */
    int offset_y;           /**< Vertical offset (default: 6) */
    float opacity;          /**< Shadow opacity 0.0-1.0 (default: 0.5) */
    float color[4];         /**< Shadow color RGBA (default: black) */
    bool clip_directional;  /**< Only show shadow on offset side (default: true) */
} shadow_config_t;

/**
 * Shadow scene nodes attached to a client or drawin.
 *
 * Each shadow owns its own set of gradient textures (4 corners + 2 edges).
 * The 8 scene buffer nodes are arranged in a 9-slice pattern and reference
 * these textures. Edges are stretched by the GPU via dest_size.
 */
typedef struct shadow_nodes_t {
    struct wlr_scene_tree *tree;                        /**< Container for shadow slices */
    struct wlr_scene_buffer *slice[SHADOW_SLICE_COUNT]; /**< 9-slice scene buffers */
    struct wlr_buffer *textures[SHADOW_TEXTURE_COUNT];  /**< Owned gradient textures */
} shadow_nodes_t;

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
 * Call at compositor shutdown.
 */
void shadow_cleanup(void);

/**
 * Get effective shadow configuration for an object.
 *
 * @param override Object-specific config (may be NULL for defaults)
 * @param is_drawin true for drawin, false for client
 * @return Effective configuration (never NULL)
 */
const shadow_config_t *shadow_get_effective_config(
    const shadow_config_t *override, bool is_drawin);

/* ========== Shadow Rendering ========== */

/**
 * Create shadow nodes for an object.
 *
 * Renders gradient textures and creates 8 scene buffers as children
 * of the given parent tree, positioned below (behind) other content.
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
 * Fast operation: just repositions scene nodes and updates dest_size.
 * No texture re-rendering.
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
 * Update shadow after configuration change.
 *
 * If only offset changed, repositions nodes. If radius/color/opacity
 * changed, destroys and recreates the shadow with new textures.
 *
 * @param shadow Shadow nodes structure
 * @param parent Parent scene tree (for recreation)
 * @param config New configuration
 * @param width Object width
 * @param height Object height
 */
void shadow_update_config(shadow_nodes_t *shadow,
                         struct wlr_scene_tree *parent,
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
 * Destroy shadow nodes and free owned textures.
 *
 * @param shadow Shadow nodes structure to cleanup
 */
void shadow_destroy(shadow_nodes_t *shadow);

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
