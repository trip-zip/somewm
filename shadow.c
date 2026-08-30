/*
 * shadow.c - compositor-level shadow support (nine-patch drop shadow)
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

/* The shadow is a rounded rectangle: the object's frame grown by `spread`
 * on every side, translated by (offset_x, offset_y), rounded by
 * `corner_radius`, with a `radius`-wide smoothstep falloff outside its
 * boundary. It is assembled as a nine-patch: four corner patches carry the
 * rounded falloff, four GPU-stretched edge strips carry the straight
 * falloff, and up to three solid scene rects cover the interior. Falloff
 * values agree exactly along every seam (both measure distance to the
 * shadow rectangle), so the patches meet without visible steps. */

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
    .offset_x = -15,
    .offset_y = -15,
    .spread = 0,
    .corner_radius = 0,
    .opacity = 0.75f,
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
 * Returns 1.0 at the shadow boundary (t=0) and 0.0 at the outer edge (t=1).
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
 * Alpha for a point at signed distance sdf (pixels, positive = outside)
 * from the shadow rectangle's boundary. radius > 0 fades over that
 * distance; radius == 0 keeps a hard edge with 1px of anti-aliasing.
 */
static inline float
shadow_alpha_at(float sdf, int radius)
{
    if (radius > 0)
        return shadow_falloff(sdf / (float)radius);
    if (sdf <= -0.5f) return 1.0f;
    if (sdf >= 0.5f) return 0.0f;
    return 0.5f - sdf;
}

/**
 * Compute a premultiplied ARGB8888 pixel for the shadow color at the
 * given alpha.
 */
static inline uint32_t
shadow_pixel(const float color[4], float alpha)
{
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 1.0f) alpha = 1.0f;
    uint8_t a = (uint8_t)(alpha * 255.0f + 0.5f);
    uint8_t r = (uint8_t)(color[0] * alpha * 255.0f + 0.5f);
    uint8_t g = (uint8_t)(color[1] * alpha * 255.0f + 0.5f);
    uint8_t b = (uint8_t)(color[2] * alpha * 255.0f + 0.5f);
    return ((uint32_t)a << 24) | ((uint32_t)r << 16) |
           ((uint32_t)g << 8) | (uint32_t)b;
}

/** Peak paint alpha: opacity scaled by the color's own alpha channel. */
static inline float
shadow_paint(const shadow_config_t *config)
{
    float paint = config->opacity * config->color[3];
    if (paint < 0.0f) paint = 0.0f;
    if (paint > 1.0f) paint = 1.0f;
    return paint;
}

/**
 * Render one corner patch of the shadow rectangle.
 *
 * The patch is a (radius + corner_radius) square covering the corner arc:
 * falloff outside the rounded boundary, solid inside it. The math is done
 * in top-left orientation and mirrored for the other corners.
 *
 * @param corner Corner index (0=TL, 1=TR, 2=BL, 3=BR)
 * @param radius Falloff distance
 * @param corner_radius Rounded corner radius of the shadow rect
 * @param color RGBA color
 * @param paint Peak alpha (opacity * color alpha)
 * @return wlr_buffer or NULL on failure
 */
static struct wlr_buffer *
shadow_render_corner(int corner, int radius, int corner_radius,
                     const float color[4], float paint)
{
    int side = radius + corner_radius;
    if (side <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(side, side);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    bool mirror_x = (corner == 1 || corner == 3);
    bool mirror_y = (corner == 2 || corner == 3);

    /* In TL orientation the arc center sits at local (side, side): the
     * patch spans [-radius, corner_radius) from the rect corner, and the
     * center is corner_radius inside it. */
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            float lx = (mirror_x ? side - 1 - x : x) + 0.5f;
            float ly = (mirror_y ? side - 1 - y : y) + 0.5f;
            float dx = lx - (float)side;
            float dy = ly - (float)side;
            float sdf = sqrtf(dx * dx + dy * dy) - (float)corner_radius;
            pixels[y * side + x] =
                shadow_pixel(color, shadow_alpha_at(sdf, radius) * paint);
        }
    }

    return wlr_buf;
}

/**
 * Render the horizontal edge texture (1 pixel wide, radius tall).
 * Alpha peaks at row 0 (the shadow boundary) and fades to 0 at the last
 * row. Used as-is for the bottom edge; flipped 180 for the top edge.
 */
static struct wlr_buffer *
shadow_render_edge_h(int radius, const float color[4], float paint)
{
    if (radius <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(1, radius);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    for (int y = 0; y < radius; y++)
        pixels[y] = shadow_pixel(color,
            shadow_alpha_at((float)y + 0.5f, radius) * paint);

    return wlr_buf;
}

/**
 * Render the vertical edge texture (radius wide, 1 pixel tall).
 * Alpha peaks at column 0. Used as-is for the right edge; flipped 180 for
 * the left edge.
 */
static struct wlr_buffer *
shadow_render_edge_v(int radius, const float color[4], float paint)
{
    if (radius <= 0)
        return NULL;

    struct wlr_buffer *wlr_buf = shadow_buffer_create(radius, 1);
    if (!wlr_buf)
        return NULL;

    struct shadow_buffer *buffer = wl_container_of(wlr_buf, buffer, base);
    uint32_t *pixels = (uint32_t *)buffer->data;

    for (int x = 0; x < radius; x++)
        pixels[x] = shadow_pixel(color,
            shadow_alpha_at((float)x + 0.5f, radius) * paint);

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

static inline int
shadow_radius(const shadow_config_t *config)
{
    return config->radius > 0 ? config->radius : 0;
}

static inline int
shadow_corner_radius(const shadow_config_t *config)
{
    return config->corner_radius > 0 ? config->corner_radius : 0;
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
 * Stores results in shadow->textures:
 *   [0..3]=corners TL,TR,BL,BR, [4]=edge_h, [5]=edge_v
 * With radius and corner_radius both 0 no textures are needed (the shadow
 * is a hard rectangle drawn by the fill rects alone).
 */
static bool
shadow_render_textures(shadow_nodes_t *shadow, const shadow_config_t *config)
{
    int radius = shadow_radius(config);
    int corner_radius = shadow_corner_radius(config);
    float paint = shadow_paint(config);

    for (int i = 0; i < 4; i++)
        shadow->textures[i] = shadow_render_corner(i, radius, corner_radius,
                                                   config->color, paint);
    shadow->textures[4] = shadow_render_edge_h(radius, config->color, paint);
    shadow->textures[5] = shadow_render_edge_v(radius, config->color, paint);

    /* Fail on genuine allocation failure, not on legitimately empty
     * textures (radius 0 needs no edges, radius+corner_radius 0 no corners) */
    if (radius + corner_radius > 0 && !shadow->textures[0]) {
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

    if (!shadow_render_textures(shadow, config))
        return false;

    /* Create shadow tree as first child (renders behind everything else) */
    shadow->tree = wlr_scene_tree_create(parent);
    if (!shadow->tree) {
        shadow_free_textures(shadow);
        return false;
    }

    wlr_scene_node_lower_to_bottom(&shadow->tree->node);

    for (int i = 0; i < 4; i++) {
        if (shadow->textures[i])
            shadow->slice[SHADOW_CORNER_TL + i] = wlr_scene_buffer_create(
                shadow->tree, shadow->textures[i]);
    }

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

    /* Top/left edges need a 180 flip so the opaque side touches the
     * shadow rectangle. Constant for the shadow's lifetime. */
    if (shadow->slice[SHADOW_EDGE_TOP])
        wlr_scene_buffer_set_transform(
            shadow->slice[SHADOW_EDGE_TOP], WL_OUTPUT_TRANSFORM_180);
    if (shadow->slice[SHADOW_EDGE_LEFT])
        wlr_scene_buffer_set_transform(
            shadow->slice[SHADOW_EDGE_LEFT], WL_OUTPUT_TRANSFORM_180);

    /* Solid interior rects (premultiplied color). The side columns only
     * exist when rounded corners leave gaps beside the middle band. */
    float paint = shadow_paint(config);
    float fill_color[4] = {
        config->color[0] * paint, config->color[1] * paint,
        config->color[2] * paint, paint,
    };
    shadow->fill[SHADOW_FILL_MID] =
        wlr_scene_rect_create(shadow->tree, 0, 0, fill_color);
    if (shadow_corner_radius(config) > 0) {
        shadow->fill[SHADOW_FILL_LEFT] =
            wlr_scene_rect_create(shadow->tree, 0, 0, fill_color);
        shadow->fill[SHADOW_FILL_RIGHT] =
            wlr_scene_rect_create(shadow->tree, 0, 0, fill_color);
    }

    shadow->user_visible = true;
    shadow->size_ok = true;

    /* Ensure initial geometry update always runs (cache starts at 0,0
     * from memset, which could match a zero-sized client on first map) */
    shadow->last_width = -1;
    shadow->last_height = -1;

    shadow_update_geometry(shadow, config, width, height);

    return true;
}

/** Position a gradient slice, disabling it when it has no area. */
static void
shadow_place_slice(struct wlr_scene_buffer *slice, int x, int y, int w, int h)
{
    if (!slice)
        return;
    bool on = w > 0 && h > 0;
    wlr_scene_node_set_enabled(&slice->node, on);
    if (!on)
        return;
    wlr_scene_node_set_position(&slice->node, x, y);
    wlr_scene_buffer_set_dest_size(slice, w, h);
}

/** Position a fill rect, disabling it when it has no area. */
static void
shadow_place_fill(struct wlr_scene_rect *fill, int x, int y, int w, int h)
{
    if (!fill)
        return;
    bool on = w > 0 && h > 0;
    wlr_scene_node_set_enabled(&fill->node, on);
    if (!on)
        return;
    wlr_scene_node_set_position(&fill->node, x, y);
    wlr_scene_rect_set_size(fill, w, h);
}

void
shadow_update_geometry(shadow_nodes_t *shadow,
                      const shadow_config_t *config,
                      int width, int height)
{
    if (!shadow || !shadow->tree || !config)
        return;

    /* Skip if geometry hasn't changed - avoids redundant damage.
     * Config changes go through shadow_update_config() which does
     * destroy+create, resetting the cache via memset. */
    if (shadow->last_width == width && shadow->last_height == height)
        return;
    shadow->last_width = width;
    shadow->last_height = height;

    int radius = shadow_radius(config);
    int cr = shadow_corner_radius(config);
    int sw = width + 2 * config->spread;
    int sh = height + 2 * config->spread;
    int bx = config->offset_x - config->spread;
    int by = config->offset_y - config->spread;

    /* An object smaller than its corner patches cannot host this shadow;
     * hide it rather than let the patches overlap. */
    shadow->size_ok = sw >= 2 * cr && sh >= 2 * cr && sw > 0 && sh > 0;
    wlr_scene_node_set_enabled(&shadow->tree->node,
        shadow->user_visible && shadow->size_ok);
    if (!shadow->size_ok)
        return;

    int cs = radius + cr;     /* corner patch side */
    int mid_w = sw - 2 * cr;  /* span between the corner columns */
    int mid_h = sh - 2 * cr;

    shadow_place_slice(shadow->slice[SHADOW_CORNER_TL],
        bx - radius, by - radius, cs, cs);
    shadow_place_slice(shadow->slice[SHADOW_CORNER_TR],
        bx + sw - cr, by - radius, cs, cs);
    shadow_place_slice(shadow->slice[SHADOW_CORNER_BL],
        bx - radius, by + sh - cr, cs, cs);
    shadow_place_slice(shadow->slice[SHADOW_CORNER_BR],
        bx + sw - cr, by + sh - cr, cs, cs);

    shadow_place_slice(shadow->slice[SHADOW_EDGE_TOP],
        bx + cr, by - radius, mid_w, radius);
    shadow_place_slice(shadow->slice[SHADOW_EDGE_BOTTOM],
        bx + cr, by + sh, mid_w, radius);
    shadow_place_slice(shadow->slice[SHADOW_EDGE_LEFT],
        bx - radius, by + cr, radius, mid_h);
    shadow_place_slice(shadow->slice[SHADOW_EDGE_RIGHT],
        bx + sw, by + cr, radius, mid_h);

    shadow_place_fill(shadow->fill[SHADOW_FILL_MID],
        bx + cr, by, mid_w, sh);
    shadow_place_fill(shadow->fill[SHADOW_FILL_LEFT],
        bx, by + cr, cr, mid_h);
    shadow_place_fill(shadow->fill[SHADOW_FILL_RIGHT],
        bx + sw - cr, by + cr, cr, mid_h);
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
     * Gradient textures are tiny so recreation is cheap. */
    shadow_destroy(shadow);

    if (config->enabled)
        shadow_create(parent, shadow, config, width, height);
}

void
shadow_set_visible(shadow_nodes_t *shadow, bool visible)
{
    if (!shadow)
        return;

    shadow->user_visible = visible;
    if (shadow->tree)
        wlr_scene_node_set_enabled(&shadow->tree->node,
            visible && shadow->size_ok);
}

void
shadow_destroy(shadow_nodes_t *shadow)
{
    if (!shadow)
        return;

    if (shadow->tree)
        wlr_scene_node_destroy(&shadow->tree->node);

    shadow_release(shadow);
}

void
shadow_release(shadow_nodes_t *shadow)
{
    if (!shadow)
        return;

    shadow_free_textures(shadow);
    memset(shadow, 0, sizeof(*shadow));
}

/* ========== Composite Rendering ========== */

void
shadow_box(const shadow_config_t *config, int width, int height,
           int *x, int *y, int *w, int *h)
{
    int outset = config->spread + shadow_radius(config);

    *x = config->offset_x - outset;
    *y = config->offset_y - outset;
    *w = width + 2 * outset;
    *h = height + 2 * outset;
}

cairo_surface_t *
shadow_render_composite(const shadow_config_t *config, int width, int height)
{
    if (!config || !config->enabled)
        return NULL;

    int radius = shadow_radius(config);
    int cr = shadow_corner_radius(config);
    int sw = width + 2 * config->spread;
    int sh = height + 2 * config->spread;

    /* Same size gate as shadow_update_geometry(). */
    if (sw <= 0 || sh <= 0 || sw < 2 * cr || sh < 2 * cr)
        return NULL;

    int surf_w = sw + 2 * radius;
    int surf_h = sh + 2 * radius;
    cairo_surface_t *surface = cairo_image_surface_create(
        CAIRO_FORMAT_ARGB32, surf_w, surf_h);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }

    cairo_surface_flush(surface);
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
    int stride_px = cairo_image_surface_get_stride(surface) / 4;
    float paint = shadow_paint(config);

    /* The shadow rect spans [radius, radius + sw) x [radius, radius + sh)
     * in surface pixels. Each pixel center's signed distance to the rounded
     * boundary is the one distance the corner patches and edge strips
     * encode piecewise, so this matches the scene nine-patch exactly. */
    float half_w = sw / 2.0f - cr;
    float half_h = sh / 2.0f - cr;
    float cx = radius + sw / 2.0f;
    float cy = radius + sh / 2.0f;

    for (int y = 0; y < surf_h; y++) {
        float qy = fabsf(y + 0.5f - cy) - half_h;
        for (int x = 0; x < surf_w; x++) {
            float qx = fabsf(x + 0.5f - cx) - half_w;
            float ox = qx > 0.0f ? qx : 0.0f;
            float oy = qy > 0.0f ? qy : 0.0f;
            float inner = qx > qy ? qx : qy;
            float sdf = sqrtf(ox * ox + oy * oy)
                + (inner < 0.0f ? inner : 0.0f) - cr;
            pixels[y * stride_px + x] = shadow_pixel(config->color,
                shadow_alpha_at(sdf, radius) * paint);
        }
    }

    cairo_surface_mark_dirty(surface);
    return surface;
}

/* ========== Lua Integration ========== */

bool
shadow_config_from_lua(lua_State *L, int idx, shadow_config_t *config,
                       bool is_drawin)
{
    if (!config)
        return false;

    /* Start from theme defaults (not hardcoded defaults) */
    *config = *shadow_get_effective_config(NULL, is_drawin);

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

    lua_getfield(L, idx, "spread");
    if (lua_isnumber(L, -1))
        config->spread = (int)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, idx, "corner_radius");
    if (lua_isnumber(L, -1))
        config->corner_radius = (int)lua_tonumber(L, -1);
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

    lua_pushinteger(L, config->spread);
    lua_setfield(L, -2, "spread");

    lua_pushinteger(L, config->corner_radius);
    lua_setfield(L, -2, "corner_radius");

    lua_pushnumber(L, config->opacity);
    lua_setfield(L, -2, "opacity");

    lua_pushboolean(L, config->clip_directional);
    lua_setfield(L, -2, "clip_directional");

    /* Color as hex string; include the alpha byte when it carries data */
    char color_str[11];
    if (config->color[3] < 1.0f)
        snprintf(color_str, sizeof(color_str), "#%02X%02X%02X%02X",
                 (int)(config->color[0] * 255),
                 (int)(config->color[1] * 255),
                 (int)(config->color[2] * 255),
                 (int)(config->color[3] * 255 + 0.5f));
    else
        snprintf(color_str, sizeof(color_str), "#%02X%02X%02X",
                 (int)(config->color[0] * 255),
                 (int)(config->color[1] * 255),
                 (int)(config->color[2] * 255));
    lua_pushstring(L, color_str);
    lua_setfield(L, -2, "color");
}

/** Read one integer beautiful key into an int field if set. */
static void
shadow_beautiful_int(lua_State *L, const char *key, int *out)
{
    lua_getfield(L, -1, key);
    if (lua_isnumber(L, -1))
        *out = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
}

/** Read one color beautiful key into a float[4] if set and valid. */
static void
shadow_beautiful_color(lua_State *L, const char *key, float out[4])
{
    lua_getfield(L, -1, key);
    if (lua_isstring(L, -1)) {
        const char *str = lua_tostring(L, -1);
        color_t c;
        if (color_init_from_string(&c, str)) {
            out[0] = c.red / 255.0f;
            out[1] = c.green / 255.0f;
            out[2] = c.blue / 255.0f;
            out[3] = c.alpha / 255.0f;
        }
    }
    lua_pop(L, 1);
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

    shadow_config_t *client = &globalconf.shadow.client;

    /* Client shadow defaults */
    lua_getfield(L, -1, "shadow_enabled");
    if (!lua_isnil(L, -1))
        client->enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);

    shadow_beautiful_int(L, "shadow_radius", &client->radius);
    shadow_beautiful_int(L, "shadow_offset_x", &client->offset_x);
    shadow_beautiful_int(L, "shadow_offset_y", &client->offset_y);
    shadow_beautiful_int(L, "shadow_spread", &client->spread);
    shadow_beautiful_int(L, "shadow_corner_radius", &client->corner_radius);

    lua_getfield(L, -1, "shadow_opacity");
    if (lua_isnumber(L, -1))
        client->opacity = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_clip");
    if (!lua_isnil(L, -1)) {
        if (lua_isboolean(L, -1)) {
            client->clip_directional = lua_toboolean(L, -1);
        } else if (lua_isstring(L, -1)) {
            const char *clip = lua_tostring(L, -1);
            if (clip)
                client->clip_directional =
                    (strcmp(clip, "directional") == 0);
        }
    }
    lua_pop(L, 1);

    shadow_beautiful_color(L, "shadow_color", client->color);

    /* Copy client defaults to drawin, then apply drawin-specific overrides */
    globalconf.shadow.drawin = *client;
    shadow_config_t *drawin = &globalconf.shadow.drawin;

    lua_getfield(L, -1, "shadow_drawin_enabled");
    if (!lua_isnil(L, -1))
        drawin->enabled = lua_toboolean(L, -1);
    lua_pop(L, 1);

    shadow_beautiful_int(L, "shadow_drawin_radius", &drawin->radius);
    shadow_beautiful_int(L, "shadow_drawin_offset_x", &drawin->offset_x);
    shadow_beautiful_int(L, "shadow_drawin_offset_y", &drawin->offset_y);
    shadow_beautiful_int(L, "shadow_drawin_spread", &drawin->spread);
    shadow_beautiful_int(L, "shadow_drawin_corner_radius", &drawin->corner_radius);

    lua_getfield(L, -1, "shadow_drawin_opacity");
    if (lua_isnumber(L, -1))
        drawin->opacity = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    shadow_beautiful_color(L, "shadow_drawin_color", drawin->color);

    lua_pop(L, 1);  /* Pop beautiful table */
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
