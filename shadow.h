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

#include <cairo.h>
#include <lua.h>
#include <stdbool.h>
#include <stdint.h>
#include <wlr/util/box.h>
#include "render_image.h"

/**
 * Gradient slice indices for the shadow nine-patch.
 *
 * The shadow is a rounded rectangle: the object's frame grown by `spread`
 * on every side, translated by the offset, with a `radius`-wide falloff
 * outside its boundary. Corner patches carry the rounded falloff, edge
 * strips carry the straight falloff, and solid rects (see the fill enum)
 * cover the interior.
 *
 *   TL  TOP  TR
 *   L  (fill) R
 *   BL  BOT  BR
 */
enum {
    SHADOW_CORNER_TL = 0,
    SHADOW_CORNER_TR,
    SHADOW_CORNER_BL,
    SHADOW_CORNER_BR,
    SHADOW_EDGE_TOP,
    SHADOW_EDGE_BOTTOM,
    SHADOW_EDGE_LEFT,
    SHADOW_EDGE_RIGHT,
    SHADOW_SLICE_COUNT
};

/**
 * Solid interior rects. The corner patches own the four corner squares of
 * the shadow rectangle; these rects cover the rest of the interior.
 */
enum {
    SHADOW_FILL_MID = 0,  /**< Full-height band between the corner columns */
    SHADOW_FILL_LEFT,     /**< Left column between the two left corners */
    SHADOW_FILL_RIGHT,    /**< Right column between the two right corners */
    SHADOW_FILL_COUNT
};

/**
 * Shadow configuration for a single object (client or drawin).
 *
 * When NULL on an object, global defaults from globalconf are used.
 * When non-NULL, these values override the defaults.
 */
typedef struct shadow_config_t {
    bool enabled;           /**< Shadow enabled for this object */
    int radius;             /**< Falloff distance in pixels (default: 12) */
    int offset_x;           /**< Horizontal offset (default: -15) */
    int offset_y;           /**< Vertical offset (default: -15) */
    int spread;             /**< Outset of the shadow rect before falloff (default: 0) */
    int corner_radius;      /**< Rounded corner radius of the shadow rect (default: 0) */
    float opacity;          /**< Shadow opacity 0.0-1.0 (default: 0.75) */
    float color[4];         /**< Shadow color RGBA; alpha multiplies opacity */
    bool clip_directional;  /**< Accepted for compatibility; no longer used */
} shadow_config_t;

/* The eight textures a shadow draws with, rendered once per config. */
struct shadow_leaves {
    struct image_entry tex[SHADOW_SLICE_COUNT]; /* corners TL TR BL BR, edges top bottom left right */
    shadow_config_t config;
    bool ready;
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

/* Render the textures when config differs; NULL or disabled clears them. */
void shadow_leaves_update(struct shadow_leaves *s, const shadow_config_t *config);
void shadow_leaves_clear(struct shadow_leaves *s);
/* Eight slices then three fills at the object's origin. False when the
 * object is too small for the corner patches. Empty boxes have zero size. */
bool shadow_layout(const shadow_config_t *config, int width, int height,
                   struct wlr_box out[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT]);
float shadow_paint(const shadow_config_t *config);
void shadow_box(const shadow_config_t *config, int width, int height,
                int *x, int *y, int *w, int *h);

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
bool shadow_config_from_lua(lua_State *L, int idx, shadow_config_t *config,
                           bool is_drawin);

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
