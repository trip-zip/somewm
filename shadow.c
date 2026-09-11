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
 * falloff, and up to three solid rectangles cover the interior. Falloff
 * values agree exactly along every seam (both measure distance to the
 * shadow rectangle), so the patches meet without visible steps. */

#include "shadow.h"
#include "color.h"
#include "globalconf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

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
float
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
 * @return cairo surface or NULL on failure
 */
static cairo_surface_t *
shadow_render_corner(int corner, int radius, int corner_radius,
                     const float color[4], float paint)
{
    int side = radius + corner_radius;
    if (side <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface) / 4;

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
            pixels[y * stride + x] =
                shadow_pixel(color, shadow_alpha_at(sdf, radius) * paint);
        }
    }

    cairo_surface_mark_dirty(surface);
    return surface;
}

/**
 * Render the horizontal edge texture (1 pixel wide, radius tall).
 * Alpha fades upward for the top edge and downward for the bottom edge.
 */
static cairo_surface_t *
shadow_render_edge_h(int radius, const float color[4], float paint, bool top)
{
    if (radius <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, radius);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface) / 4;

    for (int y = 0; y < radius; y++)
        pixels[y * stride] = shadow_pixel(color,
            shadow_alpha_at((float)(top ? radius - 1 - y : y) + 0.5f, radius) * paint);

    cairo_surface_mark_dirty(surface);
    return surface;
}

/**
 * Render the vertical edge texture (radius wide, 1 pixel tall).
 * Alpha fades leftward for the left edge and rightward for the right edge.
 */
static cairo_surface_t *
shadow_render_edge_v(int radius, const float color[4], float paint, bool left)
{
    if (radius <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, radius, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);

    for (int x = 0; x < radius; x++)
        pixels[x] = shadow_pixel(color,
            shadow_alpha_at((float)(left ? radius - 1 - x : x) + 0.5f, radius) * paint);

    cairo_surface_mark_dirty(surface);
    return surface;
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
    /* Nothing to cleanup globally - per-shadow textures are owned by the leaves */
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

void
shadow_leaves_clear(struct shadow_leaves *s)
{
    for (int i = 0; i < SHADOW_SLICE_COUNT; i++)
        image_entry_set(&s->tex[i], NULL);
    s->ready = false;
}

void
shadow_leaves_update(struct shadow_leaves *s, const shadow_config_t *config)
{
    if (!config || !config->enabled) {
        shadow_leaves_clear(s);
        return;
    }
    if (s->ready && memcmp(&s->config, config, sizeof(*config)) == 0)
        return;

    int radius = shadow_radius(config);
    int cr = shadow_corner_radius(config);
    float paint = shadow_paint(config);
    for (int i = 0; i < SHADOW_SLICE_COUNT; i++) {
        cairo_surface_t *surface;
        if (i < SHADOW_EDGE_TOP)
            surface = shadow_render_corner(i, radius, cr, config->color, paint);
        else if (i < SHADOW_EDGE_LEFT)
            surface = shadow_render_edge_h(radius, config->color, paint,
                                           i == SHADOW_EDGE_TOP);
        else
            surface = shadow_render_edge_v(radius, config->color, paint,
                                           i == SHADOW_EDGE_LEFT);
        image_entry_set(&s->tex[i], surface);
        s->tex[i].stretch = i >= SHADOW_EDGE_TOP;
        if (!surface && (i < SHADOW_EDGE_TOP ? radius + cr : radius) > 0) {
            shadow_leaves_clear(s);
            return;
        }
    }
    s->config = *config;
    s->ready = true;
}

bool
shadow_layout(const shadow_config_t *config, int width, int height,
              struct wlr_box out[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT])
{
    int radius = shadow_radius(config);
    int cr = shadow_corner_radius(config);
    int sw = width + 2 * config->spread;
    int sh = height + 2 * config->spread;
    int bx = config->offset_x - config->spread;
    int by = config->offset_y - config->spread;

    if (sw < 2 * cr || sh < 2 * cr || sw <= 0 || sh <= 0)
        return false;

    int cs = radius + cr;     /* corner patch side */
    int mid_w = sw - 2 * cr;  /* span between the corner columns */
    int mid_h = sh - 2 * cr;

    out[SHADOW_CORNER_TL] = (struct wlr_box) { bx - radius, by - radius, cs, cs };
    out[SHADOW_CORNER_TR] = (struct wlr_box) { bx + sw - cr, by - radius, cs, cs };
    out[SHADOW_CORNER_BL] = (struct wlr_box) { bx - radius, by + sh - cr, cs, cs };
    out[SHADOW_CORNER_BR] = (struct wlr_box) { bx + sw - cr, by + sh - cr, cs, cs };

    out[SHADOW_EDGE_TOP] = (struct wlr_box) { bx + cr, by - radius, mid_w, radius };
    out[SHADOW_EDGE_BOTTOM] = (struct wlr_box) { bx + cr, by + sh, mid_w, radius };
    out[SHADOW_EDGE_LEFT] = (struct wlr_box) { bx - radius, by + cr, radius, mid_h };
    out[SHADOW_EDGE_RIGHT] = (struct wlr_box) { bx + sw, by + cr, radius, mid_h };

    out[SHADOW_SLICE_COUNT + SHADOW_FILL_MID] = (struct wlr_box) { bx + cr, by, mid_w, sh };
    out[SHADOW_SLICE_COUNT + SHADOW_FILL_LEFT] = (struct wlr_box) { bx, by + cr, cr, mid_h };
    out[SHADOW_SLICE_COUNT + SHADOW_FILL_RIGHT] = (struct wlr_box) { bx + sw - cr, by + cr, cr, mid_h };
    for (int i = 0; i < SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT; i++) {
        if (out[i].width <= 0 || out[i].height <= 0)
            out[i].width = out[i].height = 0;
    }
    return true;
}

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
