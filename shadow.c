/*
 * shadow.c - compositor-level shadow support (9-slice drop shadow)
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

#include "shadow.h"
#include "color.h"
#include "globalconf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <drm_fourcc.h>

/* Default shadow configuration (disabled by default, theme enables) */
static const shadow_config_t shadow_defaults = {
    .enabled = false,
    .radius = 12,
    .offset_x = 0,
    .offset_y = 6,
    .opacity = 0.5f,
    .color = { 0.0f, 0.0f, 0.0f, 1.0f },
    .clip_directional = true,
};

/* ========== wlr_buffer Implementation ========== */

struct shadow_buffer {
    struct wlr_buffer base;
    void *data;
    int width;
    int height;
    size_t stride;
};

static void shadow_buffer_destroy(struct wlr_buffer *wlr_buffer)
{
    struct shadow_buffer *buffer = wl_container_of(wlr_buffer, buffer, base);
    free(buffer->data);
    free(buffer);
}

static bool shadow_buffer_begin_data_ptr_access(
    struct wlr_buffer *wlr_buffer, uint32_t flags, void **data,
    uint32_t *format, size_t *stride)
{
    struct shadow_buffer *buffer = wl_container_of(wlr_buffer, buffer, base);
    *data = buffer->data;
    *format = DRM_FORMAT_ARGB8888;
    *stride = buffer->stride;
    return true;
}

static void shadow_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer)
{
    /* Nothing to do */
}

static const struct wlr_buffer_impl shadow_buffer_impl = {
    .destroy = shadow_buffer_destroy,
    .begin_data_ptr_access = shadow_buffer_begin_data_ptr_access,
    .end_data_ptr_access = shadow_buffer_end_data_ptr_access,
};

/**
 * Create a wlr_buffer with given dimensions, zero-initialized.
 */
static struct wlr_buffer *
shadow_buffer_create(int width, int height)
{
    if (width <= 0 || height <= 0)
        return NULL;

    struct shadow_buffer *buffer = calloc(1, sizeof(*buffer));
    if (!buffer)
        return NULL;

    buffer->width = width;
    buffer->height = height;
    buffer->stride = (size_t)width * 4;

    size_t size = buffer->stride * (size_t)height;
    buffer->data = calloc(1, size);
    if (!buffer->data) {
        free(buffer);
        return NULL;
    }

    wlr_buffer_init(&buffer->base, &shadow_buffer_impl, width, height);
    return &buffer->base;
}

/* ========== Gradient Rendering ========== */

/**
 * Smoothstep falloff for shadow gradient.
 * Returns 1.0 at the window edge (t=0) and 0.0 at the outer edge (t=1).
 */
static inline float
shadow_falloff(float t)
{
    if (t >= 1.0f) return 0.0f;
    if (t <= 0.0f) return 1.0f;
    float s = 1.0f - t;
    return s * s * (3.0f - 2.0f * s);
}

/**
 * Compute a premultiplied ARGB8888 pixel for a shadow gradient.
 */
static inline uint32_t
shadow_pixel(const float color[4], float opacity, float falloff)
{
    float alpha = falloff * opacity;
    uint8_t a = (uint8_t)(alpha * 255.0f + 0.5f);
    uint8_t r = (uint8_t)(color[0] * alpha * 255.0f + 0.5f);
    uint8_t g = (uint8_t)(color[1] * alpha * 255.0f + 0.5f);
    uint8_t b = (uint8_t)(color[2] * alpha * 255.0f + 0.5f);
    return ((uint32_t)a << 24) | ((uint32_t)r << 16) |
           ((uint32_t)g << 8) | (uint32_t)b;
}

/**
 * Render a corner texture with radial gradient.
 *
 * @param corner Corner index (0=TL, 1=TR, 2=BL, 3=BR)
 * @param radius Shadow radius (texture is radius x radius pixels)
 * @param color RGBA color
 * @param opacity Shadow opacity
 * @return wlr_buffer or NULL on failure
 */
static struct wlr_buffer *
shadow_render_corner(int corner, int radius, const float color[4], float opacity)
{
    if (radius <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(radius, radius);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    /* Inner corner position (the edge closest to the window) */
    int cx, cy;
    switch (corner) {
    case 0: cx = radius - 1; cy = radius - 1; break;  /* TL: inner at bottom-right */
    case 1: cx = 0;          cy = radius - 1; break;  /* TR: inner at bottom-left */
    case 2: cx = radius - 1; cy = 0;          break;  /* BL: inner at top-right */
    case 3: cx = 0;          cy = 0;          break;  /* BR: inner at top-left */
    default: cx = 0; cy = 0; break;
    }

    float inv_radius = (radius > 1) ? 1.0f / (float)(radius - 1) : 1.0f;

    for (int y = 0; y < radius; y++) {
        for (int x = 0; x < radius; x++) {
            float dx = (float)(x - cx);
            float dy = (float)(y - cy);
            float dist = sqrtf(dx * dx + dy * dy);
            float t = dist * inv_radius;
            pixels[y * radius + x] = shadow_pixel(color, opacity,
                                                   shadow_falloff(t));
        }
    }

    return wlr_buf;
}

/**
 * Render horizontal edge texture (1 pixel wide, radius pixels tall).
 * Gradient goes from opaque at position 0 to transparent at position radius-1.
 */
static struct wlr_buffer *
shadow_render_edge_h(int radius, const float color[4], float opacity)
{
    if (radius <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(1, radius);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    float inv_radius = (radius > 1) ? 1.0f / (float)(radius - 1) : 1.0f;

    for (int y = 0; y < radius; y++) {
        float t = (float)y * inv_radius;
        pixels[y] = shadow_pixel(color, opacity, shadow_falloff(t));
    }

    return wlr_buf;
}

/**
 * Render vertical edge texture (radius pixels wide, 1 pixel tall).
 * Gradient goes from opaque at position 0 to transparent at position radius-1.
 */
static struct wlr_buffer *
shadow_render_edge_v(int radius, const float color[4], float opacity)
{
    if (radius <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(radius, 1);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    float inv_radius = (radius > 1) ? 1.0f / (float)(radius - 1) : 1.0f;

    for (int x = 0; x < radius; x++) {
        float t = (float)x * inv_radius;
        pixels[x] = shadow_pixel(color, opacity, shadow_falloff(t));
    }

    return wlr_buf;
}

/**
 * Render a 1x1 solid pixel at full shadow color and opacity.
 * Used for fill strips that bridge the gap between window edge and offset shadow.
 */
static struct wlr_buffer *
shadow_render_fill(const float color[4], float opacity)
{
    struct wlr_buffer *wlr_buf = shadow_buffer_create(1, 1);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;
    pixels[0] = shadow_pixel(color, opacity, 1.0f);

    return wlr_buf;
}

/* ========== Core API ========== */

void
shadow_init(void)
{
    /* Nothing to initialize - per-shadow textures are self-contained */
}

void
shadow_cleanup(void)
{
    /* Nothing to cleanup globally - per-shadow textures freed in shadow_destroy */
}

const shadow_config_t *
shadow_get_effective_config(const shadow_config_t *override, bool is_drawin)
{
    if (override)
        return override;

    return is_drawin ? &globalconf.shadow.drawin : &globalconf.shadow.client;
}

/**
 * Free owned textures in a shadow_nodes_t.
 */
static void
shadow_free_textures(shadow_nodes_t *shadow)
{
    for (int i = 0; i < SHADOW_TEXTURE_COUNT; i++) {
        if (shadow->textures[i]) {
            wlr_buffer_drop(shadow->textures[i]);
            shadow->textures[i] = NULL;
        }
    }
}

/**
 * Render gradient textures for a shadow configuration.
 * Stores results in shadow->textures[0..5]:
 *   [0]=corner_TL, [1]=corner_TR, [2]=corner_BL, [3]=corner_BR,
 *   [4]=edge_h, [5]=edge_v
 */
static bool
shadow_render_textures(shadow_nodes_t *shadow, const shadow_config_t *config)
{
    shadow->textures[0] = shadow_render_corner(0, config->radius,
                                               config->color, config->opacity);
    shadow->textures[1] = shadow_render_corner(1, config->radius,
                                               config->color, config->opacity);
    shadow->textures[2] = shadow_render_corner(2, config->radius,
                                               config->color, config->opacity);
    shadow->textures[3] = shadow_render_corner(3, config->radius,
                                               config->color, config->opacity);
    shadow->textures[4] = shadow_render_edge_h(config->radius,
                                               config->color, config->opacity);
    shadow->textures[5] = shadow_render_edge_v(config->radius,
                                               config->color, config->opacity);
    shadow->textures[6] = shadow_render_fill(config->color, config->opacity);

    /* Check that at least corners were created */
    if (!shadow->textures[0]) {
        shadow_free_textures(shadow);
        return false;
    }

    return true;
}

bool
shadow_create(struct wlr_scene_tree *parent,
              shadow_nodes_t *shadow,
              const shadow_config_t *config,
              int width, int height)
{
    if (!parent || !shadow || !config)
        return false;

    memset(shadow, 0, sizeof(*shadow));

    if (!config->enabled)
        return true;

    /* Render per-shadow gradient textures */
    if (!shadow_render_textures(shadow, config))
        return false;

    /* Create shadow tree as first child (renders behind everything else) */
    shadow->tree = wlr_scene_tree_create(parent);
    if (!shadow->tree) {
        shadow_free_textures(shadow);
        return false;
    }

    wlr_scene_node_lower_to_bottom(&shadow->tree->node);

    /* Create scene buffers for each slice.
     * Corners use their own texture each.
     * Top/bottom edges share edge_h texture; left/right share edge_v. */
    if (shadow->textures[0])
        shadow->slice[SHADOW_CORNER_TL] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[0]);
    if (shadow->textures[1])
        shadow->slice[SHADOW_CORNER_TR] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[1]);
    if (shadow->textures[2])
        shadow->slice[SHADOW_CORNER_BL] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[2]);
    if (shadow->textures[3])
        shadow->slice[SHADOW_CORNER_BR] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[3]);

    if (shadow->textures[4]) {
        shadow->slice[SHADOW_EDGE_TOP] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[4]);
        shadow->slice[SHADOW_EDGE_BOTTOM] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[4]);
    }
    if (shadow->textures[5]) {
        shadow->slice[SHADOW_EDGE_LEFT] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[5]);
        shadow->slice[SHADOW_EDGE_RIGHT] = wlr_scene_buffer_create(
            shadow->tree, shadow->textures[5]);
    }

    /* Fill strips for offset gaps (1x1 solid pixel stretched) */
    if (shadow->textures[6]) {
        if (config->offset_y != 0)
            shadow->slice[SHADOW_FILL_H] = wlr_scene_buffer_create(
                shadow->tree, shadow->textures[6]);
        if (config->offset_x != 0)
            shadow->slice[SHADOW_FILL_V] = wlr_scene_buffer_create(
                shadow->tree, shadow->textures[6]);
    }

    /* Position and size all slices */
    shadow_update_geometry(shadow, config, width, height);

    return true;
}

void
shadow_update_geometry(shadow_nodes_t *shadow,
                      const shadow_config_t *config,
                      int width, int height)
{
    if (!shadow || !shadow->tree || !config)
        return;

    int r = config->radius;
    int ox = config->offset_x;
    int oy = config->offset_y;

    /* Determine which slices to show based on offset direction */
    bool show_top = true, show_bottom = true;
    bool show_left = true, show_right = true;

    if (config->clip_directional) {
        /* Only show shadow on the side toward the offset */
        show_top = (oy < 0);
        show_bottom = (oy > 0);
        show_left = (ox < 0);
        show_right = (ox > 0);

        /* If no offset, show all sides */
        if (ox == 0 && oy == 0) {
            show_top = show_bottom = show_left = show_right = true;
        }
        /* If only vertical offset, still show left/right sides */
        if (ox == 0) {
            show_left = show_right = true;
        }
        /* If only horizontal offset, still show top/bottom */
        if (oy == 0) {
            show_top = show_bottom = true;
        }
    }

    /* Position corners */
    if (shadow->slice[SHADOW_CORNER_TL]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_CORNER_TL]->node, ox - r, oy - r);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_CORNER_TL]->node, show_top && show_left);
    }
    if (shadow->slice[SHADOW_CORNER_TR]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_CORNER_TR]->node, ox + width, oy - r);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_CORNER_TR]->node, show_top && show_right);
    }
    if (shadow->slice[SHADOW_CORNER_BL]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_CORNER_BL]->node, ox - r, oy + height);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_CORNER_BL]->node, show_bottom && show_left);
    }
    if (shadow->slice[SHADOW_CORNER_BR]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_CORNER_BR]->node, ox + width, oy + height);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_CORNER_BR]->node, show_bottom && show_right);
    }

    /* Edges - stretched to fill gaps between corners.
     * Edge textures have gradient: position 0 = opaque, position max = transparent.
     * Top/left edges need 180° flip so opaque side touches the window. */
    if (shadow->slice[SHADOW_EDGE_TOP]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_EDGE_TOP]->node, ox, oy - r);
        wlr_scene_buffer_set_dest_size(
            shadow->slice[SHADOW_EDGE_TOP], width, r);
        wlr_scene_buffer_set_transform(
            shadow->slice[SHADOW_EDGE_TOP], WL_OUTPUT_TRANSFORM_180);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_EDGE_TOP]->node, show_top);
    }
    if (shadow->slice[SHADOW_EDGE_BOTTOM]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_EDGE_BOTTOM]->node, ox, oy + height);
        wlr_scene_buffer_set_dest_size(
            shadow->slice[SHADOW_EDGE_BOTTOM], width, r);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_EDGE_BOTTOM]->node, show_bottom);
    }
    if (shadow->slice[SHADOW_EDGE_LEFT]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_EDGE_LEFT]->node, ox - r, oy);
        wlr_scene_buffer_set_dest_size(
            shadow->slice[SHADOW_EDGE_LEFT], r, height);
        wlr_scene_buffer_set_transform(
            shadow->slice[SHADOW_EDGE_LEFT], WL_OUTPUT_TRANSFORM_180);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_EDGE_LEFT]->node, show_left);
    }
    if (shadow->slice[SHADOW_EDGE_RIGHT]) {
        wlr_scene_node_set_position(
            &shadow->slice[SHADOW_EDGE_RIGHT]->node, ox + width, oy);
        wlr_scene_buffer_set_dest_size(
            shadow->slice[SHADOW_EDGE_RIGHT], r, height);
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_EDGE_RIGHT]->node, show_right);
    }

    /* Fill strips bridge the gap between the window edge and the offset
     * shadow position.  Without these, a visible gap appears between the
     * window and the shadow in the offset direction. */
    if (shadow->slice[SHADOW_FILL_H] && oy != 0) {
        int abs_oy = oy > 0 ? oy : -oy;
        if (oy > 0) {
            /* Shadow drops down: fill from window bottom to shadow bottom edge */
            wlr_scene_node_set_position(
                &shadow->slice[SHADOW_FILL_H]->node, ox, height);
            wlr_scene_buffer_set_dest_size(
                shadow->slice[SHADOW_FILL_H], width, abs_oy);
        } else {
            /* Shadow rises up: fill from shadow top edge to window top */
            wlr_scene_node_set_position(
                &shadow->slice[SHADOW_FILL_H]->node, ox, oy);
            wlr_scene_buffer_set_dest_size(
                shadow->slice[SHADOW_FILL_H], width, abs_oy);
        }
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_FILL_H]->node,
            oy > 0 ? show_bottom : show_top);
    }

    if (shadow->slice[SHADOW_FILL_V] && ox != 0) {
        int abs_ox = ox > 0 ? ox : -ox;
        if (ox > 0) {
            /* Shadow goes right: fill from window right to shadow right edge */
            wlr_scene_node_set_position(
                &shadow->slice[SHADOW_FILL_V]->node, width, oy);
            wlr_scene_buffer_set_dest_size(
                shadow->slice[SHADOW_FILL_V], abs_ox, height);
        } else {
            /* Shadow goes left: fill from shadow left edge to window left */
            wlr_scene_node_set_position(
                &shadow->slice[SHADOW_FILL_V]->node, ox, oy);
            wlr_scene_buffer_set_dest_size(
                shadow->slice[SHADOW_FILL_V], abs_ox, height);
        }
        wlr_scene_node_set_enabled(
            &shadow->slice[SHADOW_FILL_V]->node,
            ox > 0 ? show_right : show_left);
    }
}

void
shadow_update_config(shadow_nodes_t *shadow,
                    struct wlr_scene_tree *parent,
                    const shadow_config_t *config,
                    int width, int height)
{
    if (!shadow || !config)
        return;

    /* Destroy existing shadow and recreate with new config.
     * Gradient textures are tiny (~2.5KB) so recreation is cheap. */
    shadow_destroy(shadow);

    if (config->enabled)
        shadow_create(parent, shadow, config, width, height);
}

void
shadow_set_visible(shadow_nodes_t *shadow, bool visible)
{
    if (!shadow || !shadow->tree)
        return;

    wlr_scene_node_set_enabled(&shadow->tree->node, visible);
}

void
shadow_destroy(shadow_nodes_t *shadow)
{
    if (!shadow)
        return;

    if (shadow->tree) {
        wlr_scene_node_destroy(&shadow->tree->node);
        shadow->tree = NULL;
    }

    memset(shadow->slice, 0, sizeof(shadow->slice));
    shadow_free_textures(shadow);
}

/* ========== Lua Integration ========== */

bool
shadow_config_from_lua(lua_State *L, int idx, shadow_config_t *config)
{
    if (!config)
        return false;

    /* Default values */
    *config = shadow_defaults;

    if (lua_isboolean(L, idx)) {
        config->enabled = lua_toboolean(L, idx);
        return true;
    }

    if (lua_isnil(L, idx)) {
        config->enabled = false;
        return true;
    }

    if (!lua_istable(L, idx)) {
        lua_pushstring(L, "shadow must be boolean or table");
        return false;
    }

    /* Parse table fields */
    config->enabled = true;

    lua_getfield(L, idx, "enabled");
    if (!lua_isnil(L, -1))
        config->enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "radius");
    if (lua_isnumber(L, -1))
        config->radius = (int)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "offset_x");
    if (lua_isnumber(L, -1))
        config->offset_x = (int)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "offset_y");
    if (lua_isnumber(L, -1))
        config->offset_y = (int)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "opacity");
    if (lua_isnumber(L, -1))
        config->opacity = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "clip_directional");
    if (!lua_isnil(L, -1))
        config->clip_directional = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "color");
    if (!lua_isnil(L, -1)) {
        if (lua_isstring(L, -1)) {
            const char *str = lua_tostring(L, -1);
            color_t c;
            if (color_init_from_string(&c, str)) {
                config->color[0] = c.red / 255.0f;
                config->color[1] = c.green / 255.0f;
                config->color[2] = c.blue / 255.0f;
                config->color[3] = c.alpha / 255.0f;
            }
        } else if (lua_istable(L, -1)) {
            for (int i = 0; i < 4; i++) {
                lua_rawgeti(L, -1, i + 1);
                if (lua_isnumber(L, -1))
                    config->color[i] = (float)lua_tonumber(L, -1);
                lua_pop(L, 1);
            }
        }
    }
    lua_pop(L, 1);

    return true;
}

void
shadow_config_to_lua(lua_State *L, const shadow_config_t *config)
{
    if (!config) {
        lua_pushnil(L);
        return;
    }

    if (!config->enabled) {
        lua_pushboolean(L, false);
        return;
    }

    lua_newtable(L);

    lua_pushboolean(L, config->enabled);
    lua_setfield(L, -2, "enabled");

    lua_pushinteger(L, config->radius);
    lua_setfield(L, -2, "radius");

    lua_pushinteger(L, config->offset_x);
    lua_setfield(L, -2, "offset_x");

    lua_pushinteger(L, config->offset_y);
    lua_setfield(L, -2, "offset_y");

    lua_pushnumber(L, config->opacity);
    lua_setfield(L, -2, "opacity");

    lua_pushboolean(L, config->clip_directional);
    lua_setfield(L, -2, "clip_directional");

    /* Color as hex string */
    char color_str[10];
    snprintf(color_str, sizeof(color_str), "#%02X%02X%02X",
             (int)(config->color[0] * 255),
             (int)(config->color[1] * 255),
             (int)(config->color[2] * 255));
    lua_pushstring(L, color_str);
    lua_setfield(L, -2, "color");
}

void
shadow_load_beautiful_defaults(lua_State *L)
{
    /* Use require() to get beautiful module (it's typically local, not global) */
    lua_getglobal(L, "require");
    lua_pushstring(L, "beautiful");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        lua_pop(L, 1);
        return;
    }
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    /* Reset to defaults before parsing */
    globalconf.shadow.client = shadow_defaults;
    globalconf.shadow.drawin = shadow_defaults;

    /* Client shadow defaults */
    lua_getfield(L, -1, "shadow_enabled");
    if (!lua_isnil(L, -1))
        globalconf.shadow.client.enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_radius");
    if (lua_isnumber(L, -1))
        globalconf.shadow.client.radius = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_offset_x");
    if (lua_isnumber(L, -1))
        globalconf.shadow.client.offset_x = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_offset_y");
    if (lua_isnumber(L, -1))
        globalconf.shadow.client.offset_y = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_opacity");
    if (lua_isnumber(L, -1))
        globalconf.shadow.client.opacity = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_clip");
    if (!lua_isnil(L, -1)) {
        if (lua_isboolean(L, -1)) {
            globalconf.shadow.client.clip_directional = lua_toboolean(L, -1);
        } else if (lua_isstring(L, -1)) {
            const char *clip = lua_tostring(L, -1);
            if (clip)
                globalconf.shadow.client.clip_directional =
                    (strcmp(clip, "directional") == 0);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_color");
    if (!lua_isnil(L, -1)) {
        if (lua_isstring(L, -1)) {
            const char *str = lua_tostring(L, -1);
            color_t c;
            if (color_init_from_string(&c, str)) {
                globalconf.shadow.client.color[0] = c.red / 255.0f;
                globalconf.shadow.client.color[1] = c.green / 255.0f;
                globalconf.shadow.client.color[2] = c.blue / 255.0f;
                globalconf.shadow.client.color[3] = c.alpha / 255.0f;
            }
        }
    }
    lua_pop(L, 1);

    /* Copy client defaults to drawin, then apply drawin-specific overrides */
    globalconf.shadow.drawin = globalconf.shadow.client;

    lua_getfield(L, -1, "shadow_drawin_enabled");
    if (!lua_isnil(L, -1))
        globalconf.shadow.drawin.enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_radius");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.radius = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_offset_x");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.offset_x = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_offset_y");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.offset_y = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_opacity");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.opacity = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_pop(L, 1);  /* Pop beautiful table */
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
