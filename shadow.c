/*
 * shadow.c - compositor-level shadow support
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
    .offset_x = -15,
    .offset_y = -15,
    .opacity = 0.75f,
    .color = { 0.0f, 0.0f, 0.0f, 1.0f }, /* Black */
};

/* Cache linked list head */
static shadow_cache_entry_t *shadow_cache_head = NULL;

/* ========== wlr_buffer Implementation ========== */

/**
 * Shadow buffer wrapper for wlr_scene_buffer.
 * Same pattern as systray_icon_buffer in systray.c.
 */
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
 * Create a wlr_buffer from a cairo surface.
 */
static struct wlr_buffer *
shadow_buffer_from_cairo(cairo_surface_t *surface)
{
    struct shadow_buffer *buffer;
    int width, height;
    size_t stride, size;
    unsigned char *src_data;

    if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
        return NULL;

    if (cairo_image_surface_get_format(surface) != CAIRO_FORMAT_ARGB32)
        return NULL;

    width = cairo_image_surface_get_width(surface);
    height = cairo_image_surface_get_height(surface);
    stride = (size_t)cairo_image_surface_get_stride(surface);
    src_data = cairo_image_surface_get_data(surface);

    if (width <= 0 || height <= 0 || !src_data)
        return NULL;

    buffer = calloc(1, sizeof(*buffer));
    if (!buffer)
        return NULL;

    size = stride * (size_t)height;
    buffer->data = malloc(size);
    if (!buffer->data) {
        free(buffer);
        return NULL;
    }

    memcpy(buffer->data, src_data, size);
    buffer->width = width;
    buffer->height = height;
    buffer->stride = stride;

    wlr_buffer_init(&buffer->base, &shadow_buffer_impl, width, height);

    return &buffer->base;
}

/* ========== Box Blur Implementation ========== */

/**
 * Apply horizontal box blur pass.
 * Works on ARGB32 pixel data in-place (via two buffers).
 */
static void
box_blur_h(uint32_t *src, uint32_t *dst, int width, int height, int radius)
{
    float iarr = 1.0f / (float)(radius + radius + 1);

    for (int y = 0; y < height; y++) {
        int ti = y * width;
        int li = ti;
        int ri = ti + radius;

        uint32_t fv = src[ti];
        uint32_t lv = src[ti + width - 1];

        /* Initial accumulator values */
        float r_acc = (float)((fv >> 16) & 0xFF) * (float)(radius + 1);
        float g_acc = (float)((fv >> 8) & 0xFF) * (float)(radius + 1);
        float b_acc = (float)(fv & 0xFF) * (float)(radius + 1);
        float a_acc = (float)((fv >> 24) & 0xFF) * (float)(radius + 1);

        for (int j = 0; j < radius; j++) {
            uint32_t p = src[ti + j];
            r_acc += (float)((p >> 16) & 0xFF);
            g_acc += (float)((p >> 8) & 0xFF);
            b_acc += (float)(p & 0xFF);
            a_acc += (float)((p >> 24) & 0xFF);
        }

        /* First segment: [0, radius] - accumulating right edge only */
        for (int x = 0; x <= radius; x++) {
            uint32_t p = src[ri++];
            r_acc += (float)((p >> 16) & 0xFF) - (float)((fv >> 16) & 0xFF);
            g_acc += (float)((p >> 8) & 0xFF) - (float)((fv >> 8) & 0xFF);
            b_acc += (float)(p & 0xFF) - (float)(fv & 0xFF);
            a_acc += (float)((p >> 24) & 0xFF) - (float)((fv >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti++] = (a << 24) | (r << 16) | (g << 8) | b;
        }

        /* Middle segment: both edges move */
        for (int x = radius + 1; x < width - radius; x++) {
            uint32_t p_add = src[ri++];
            uint32_t p_sub = src[li++];
            r_acc += (float)((p_add >> 16) & 0xFF) - (float)((p_sub >> 16) & 0xFF);
            g_acc += (float)((p_add >> 8) & 0xFF) - (float)((p_sub >> 8) & 0xFF);
            b_acc += (float)(p_add & 0xFF) - (float)(p_sub & 0xFF);
            a_acc += (float)((p_add >> 24) & 0xFF) - (float)((p_sub >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti++] = (a << 24) | (r << 16) | (g << 8) | b;
        }

        /* Last segment: right edge stays at last value */
        for (int x = width - radius; x < width; x++) {
            uint32_t p_sub = src[li++];
            r_acc += (float)((lv >> 16) & 0xFF) - (float)((p_sub >> 16) & 0xFF);
            g_acc += (float)((lv >> 8) & 0xFF) - (float)((p_sub >> 8) & 0xFF);
            b_acc += (float)(lv & 0xFF) - (float)(p_sub & 0xFF);
            a_acc += (float)((lv >> 24) & 0xFF) - (float)((p_sub >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti++] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

/**
 * Apply vertical box blur pass.
 */
static void
box_blur_v(uint32_t *src, uint32_t *dst, int width, int height, int radius)
{
    float iarr = 1.0f / (float)(radius + radius + 1);

    for (int x = 0; x < width; x++) {
        int ti = x;
        int li = ti;
        int ri = ti + radius * width;

        uint32_t fv = src[ti];
        uint32_t lv = src[ti + width * (height - 1)];

        float r_acc = (float)((fv >> 16) & 0xFF) * (float)(radius + 1);
        float g_acc = (float)((fv >> 8) & 0xFF) * (float)(radius + 1);
        float b_acc = (float)(fv & 0xFF) * (float)(radius + 1);
        float a_acc = (float)((fv >> 24) & 0xFF) * (float)(radius + 1);

        for (int j = 0; j < radius; j++) {
            uint32_t p = src[ti + j * width];
            r_acc += (float)((p >> 16) & 0xFF);
            g_acc += (float)((p >> 8) & 0xFF);
            b_acc += (float)(p & 0xFF);
            a_acc += (float)((p >> 24) & 0xFF);
        }

        for (int y = 0; y <= radius; y++) {
            uint32_t p = src[ri];
            ri += width;
            r_acc += (float)((p >> 16) & 0xFF) - (float)((fv >> 16) & 0xFF);
            g_acc += (float)((p >> 8) & 0xFF) - (float)((fv >> 8) & 0xFF);
            b_acc += (float)(p & 0xFF) - (float)(fv & 0xFF);
            a_acc += (float)((p >> 24) & 0xFF) - (float)((fv >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti] = (a << 24) | (r << 16) | (g << 8) | b;
            ti += width;
        }

        for (int y = radius + 1; y < height - radius; y++) {
            uint32_t p_add = src[ri];
            uint32_t p_sub = src[li];
            ri += width;
            li += width;
            r_acc += (float)((p_add >> 16) & 0xFF) - (float)((p_sub >> 16) & 0xFF);
            g_acc += (float)((p_add >> 8) & 0xFF) - (float)((p_sub >> 8) & 0xFF);
            b_acc += (float)(p_add & 0xFF) - (float)(p_sub & 0xFF);
            a_acc += (float)((p_add >> 24) & 0xFF) - (float)((p_sub >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti] = (a << 24) | (r << 16) | (g << 8) | b;
            ti += width;
        }

        for (int y = height - radius; y < height; y++) {
            uint32_t p_sub = src[li];
            li += width;
            r_acc += (float)((lv >> 16) & 0xFF) - (float)((p_sub >> 16) & 0xFF);
            g_acc += (float)((lv >> 8) & 0xFF) - (float)((p_sub >> 8) & 0xFF);
            b_acc += (float)(lv & 0xFF) - (float)(p_sub & 0xFF);
            a_acc += (float)((lv >> 24) & 0xFF) - (float)((p_sub >> 24) & 0xFF);

            uint8_t r = (uint8_t)roundf(r_acc * iarr);
            uint8_t g = (uint8_t)roundf(g_acc * iarr);
            uint8_t b = (uint8_t)roundf(b_acc * iarr);
            uint8_t a = (uint8_t)roundf(a_acc * iarr);
            dst[ti] = (a << 24) | (r << 16) | (g << 8) | b;
            ti += width;
        }
    }
}

/**
 * Apply box blur to pixel data.
 * Three passes of box blur approximates Gaussian blur.
 */
static void
box_blur(uint32_t *data, int width, int height, int radius)
{
    uint32_t *tmp = malloc((size_t)width * (size_t)height * sizeof(uint32_t));
    if (!tmp)
        return;

    /* Three passes for good Gaussian approximation */
    box_blur_h(data, tmp, width, height, radius);
    box_blur_v(tmp, data, width, height, radius);
    box_blur_h(data, tmp, width, height, radius);
    box_blur_v(tmp, data, width, height, radius);
    box_blur_h(data, tmp, width, height, radius);
    box_blur_v(tmp, data, width, height, radius);

    free(tmp);
}

/* ========== Shadow Rendering ========== */

/**
 * Render shadow corner texture.
 *
 * Creates a texture of size (2*radius) x (2*radius) with a blurred
 * quarter-circle in the specified corner position.
 *
 * @param radius Blur radius
 * @param color RGBA color
 * @param opacity Shadow opacity
 * @param corner 0=TL, 1=TR, 2=BL, 3=BR
 * @return Cairo surface (caller must destroy)
 */
static cairo_surface_t *
shadow_render_corner(int radius, const float color[4], float opacity, int corner)
{
    int size = radius * 2;
    int full_size = size * 3;
    cairo_surface_t *work_surface;
    cairo_t *cr;
    cairo_surface_t *corner_surface;
    uint32_t *pixels;
    int stride;

    if (size <= 0)
        return NULL;

    /* Create working surface with padding for blur */
    work_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                              full_size, full_size);
    if (cairo_surface_status(work_surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(work_surface);
        return NULL;
    }

    /* Draw solid rectangle in the center */
    cr = cairo_create(work_surface);
    cairo_set_source_rgba(cr, color[0], color[1], color[2], opacity);
    cairo_rectangle(cr, size, size, size, size);
    cairo_fill(cr);
    cairo_destroy(cr);

    /* Apply blur */
    cairo_surface_flush(work_surface);
    pixels = (uint32_t *)cairo_image_surface_get_data(work_surface);
    stride = cairo_image_surface_get_stride(work_surface) / 4;
    (void)stride; /* Stride equals full_size for ARGB32 */

    box_blur(pixels, full_size, full_size, radius);
    cairo_surface_mark_dirty(work_surface);

    /* Extract corner region */
    corner_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size);
    if (cairo_surface_status(corner_surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(corner_surface);
        cairo_surface_destroy(work_surface);
        return NULL;
    }

    cr = cairo_create(corner_surface);

    /* Source coordinates depend on corner */
    int sx, sy;
    switch (corner) {
        case 0: sx = 0;        sy = 0;        break; /* TL */
        case 1: sx = size * 2; sy = 0;        break; /* TR */
        case 2: sx = 0;        sy = size * 2; break; /* BL */
        case 3: sx = size * 2; sy = size * 2; break; /* BR */
        default: sx = 0; sy = 0;
    }

    cairo_set_source_surface(cr, work_surface, -sx, -sy);
    cairo_paint(cr);
    cairo_destroy(cr);

    cairo_surface_destroy(work_surface);
    return corner_surface;
}

/**
 * Render shadow edge texture.
 *
 * Creates a 1-pixel wide/tall strip that will be stretched.
 *
 * @param radius Blur radius
 * @param color RGBA color
 * @param opacity Shadow opacity
 * @param horizontal true for horizontal edge (top/bottom), false for vertical
 * @param positive true for bottom/right edge, false for top/left
 * @return Cairo surface (caller must destroy)
 */
static cairo_surface_t *
shadow_render_edge(int radius, const float color[4], float opacity,
                   bool horizontal, bool positive)
{
    int size = radius * 2;
    int full_size = size * 3;
    cairo_surface_t *work_surface;
    cairo_t *cr;
    cairo_surface_t *edge_surface;
    uint32_t *pixels;
    int edge_w, edge_h;

    if (size <= 0)
        return NULL;

    /* Create working surface */
    work_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                              full_size, full_size);
    if (cairo_surface_status(work_surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(work_surface);
        return NULL;
    }

    /* Draw solid rectangle in the center */
    cr = cairo_create(work_surface);
    cairo_set_source_rgba(cr, color[0], color[1], color[2], opacity);
    cairo_rectangle(cr, size, size, size, size);
    cairo_fill(cr);
    cairo_destroy(cr);

    /* Apply blur */
    cairo_surface_flush(work_surface);
    pixels = (uint32_t *)cairo_image_surface_get_data(work_surface);
    box_blur(pixels, full_size, full_size, radius);
    cairo_surface_mark_dirty(work_surface);

    /* Extract edge strip (1 pixel wide/tall) */
    if (horizontal) {
        edge_w = 1;
        edge_h = size;
    } else {
        edge_w = size;
        edge_h = 1;
    }

    edge_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, edge_w, edge_h);
    if (cairo_surface_status(edge_surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(edge_surface);
        cairo_surface_destroy(work_surface);
        return NULL;
    }

    cr = cairo_create(edge_surface);

    int sx, sy;
    if (horizontal) {
        /* Horizontal edge: extract from center column */
        sx = full_size / 2;
        sy = positive ? (size * 2) : 0;
    } else {
        /* Vertical edge: extract from center row */
        sx = positive ? (size * 2) : 0;
        sy = full_size / 2;
    }

    cairo_set_source_surface(cr, work_surface, -sx, -sy);
    cairo_paint(cr);
    cairo_destroy(cr);

    cairo_surface_destroy(work_surface);
    return edge_surface;
}

/* ========== Cache Management ========== */

/**
 * Check if two colors are equal (within epsilon).
 */
static bool
colors_equal(const float a[4], const float b[4])
{
    const float eps = 0.001f;
    return fabsf(a[0] - b[0]) < eps &&
           fabsf(a[1] - b[1]) < eps &&
           fabsf(a[2] - b[2]) < eps &&
           fabsf(a[3] - b[3]) < eps;
}

shadow_cache_entry_t *
shadow_cache_get(int radius, const float color[4], float opacity)
{
    shadow_cache_entry_t *entry;
    cairo_surface_t *surface;

    /* Search existing cache */
    for (entry = shadow_cache_head; entry; entry = entry->next) {
        if (entry->radius == radius &&
            colors_equal(entry->color, color) &&
            fabsf(entry->opacity - opacity) < 0.001f) {
            entry->refcount++;
            return entry;
        }
    }

    /* Create new entry */
    entry = calloc(1, sizeof(*entry));
    if (!entry)
        return NULL;

    entry->radius = radius;
    memcpy(entry->color, color, sizeof(entry->color));
    entry->opacity = opacity;
    entry->refcount = 1;

    /* Render corners */
    surface = shadow_render_corner(radius, color, opacity, 0);
    if (surface) {
        entry->corner_tl = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_corner(radius, color, opacity, 1);
    if (surface) {
        entry->corner_tr = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_corner(radius, color, opacity, 2);
    if (surface) {
        entry->corner_bl = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_corner(radius, color, opacity, 3);
    if (surface) {
        entry->corner_br = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    /* Render edges */
    surface = shadow_render_edge(radius, color, opacity, true, false);
    if (surface) {
        entry->edge_top = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_edge(radius, color, opacity, true, true);
    if (surface) {
        entry->edge_bottom = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_edge(radius, color, opacity, false, false);
    if (surface) {
        entry->edge_left = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    surface = shadow_render_edge(radius, color, opacity, false, true);
    if (surface) {
        entry->edge_right = shadow_buffer_from_cairo(surface);
        cairo_surface_destroy(surface);
    }

    /* Add to cache */
    entry->next = shadow_cache_head;
    shadow_cache_head = entry;

    return entry;
}

void
shadow_cache_put(shadow_cache_entry_t *entry)
{
    if (!entry)
        return;

    entry->refcount--;
    /* Keep in cache even at refcount 0 - will be freed on cache_clear */
}

void
shadow_cache_clear(void)
{
    shadow_cache_entry_t *entry = shadow_cache_head;
    while (entry) {
        shadow_cache_entry_t *next = entry->next;

        if (entry->corner_tl) wlr_buffer_drop(entry->corner_tl);
        if (entry->corner_tr) wlr_buffer_drop(entry->corner_tr);
        if (entry->corner_bl) wlr_buffer_drop(entry->corner_bl);
        if (entry->corner_br) wlr_buffer_drop(entry->corner_br);
        if (entry->edge_top) wlr_buffer_drop(entry->edge_top);
        if (entry->edge_bottom) wlr_buffer_drop(entry->edge_bottom);
        if (entry->edge_left) wlr_buffer_drop(entry->edge_left);
        if (entry->edge_right) wlr_buffer_drop(entry->edge_right);

        free(entry);
        entry = next;
    }
    shadow_cache_head = NULL;
}

/* ========== Core API ========== */

void
shadow_init(void)
{
    /* Initialize with empty cache */
    shadow_cache_head = NULL;
}

void
shadow_cleanup(void)
{
    shadow_cache_clear();
}

const shadow_config_t *
shadow_get_effective_config(const shadow_config_t *override, bool is_drawin)
{
    if (override)
        return override;

    /* Return global defaults from globalconf (set by beautiful theme) */
    return is_drawin ? &globalconf.shadow.drawin : &globalconf.shadow.client;
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

    /* Create shadow tree as first child (renders behind everything else) */
    shadow->tree = wlr_scene_tree_create(parent);
    if (!shadow->tree)
        return false;

    /* Place at bottom of parent's children */
    wlr_scene_node_lower_to_bottom(&shadow->tree->node);

    /* Get cached textures */
    shadow->cache = shadow_cache_get(config->radius, config->color, config->opacity);
    if (!shadow->cache) {
        wlr_scene_node_destroy(&shadow->tree->node);
        shadow->tree = NULL;
        return false;
    }

    /* Create corner buffers */
    if (shadow->cache->corner_tl) {
        shadow->buffer[SHADOW_CORNER_TL] = wlr_scene_buffer_create(shadow->tree, shadow->cache->corner_tl);
    }
    if (shadow->cache->corner_tr) {
        shadow->buffer[SHADOW_CORNER_TR] = wlr_scene_buffer_create(shadow->tree, shadow->cache->corner_tr);
    }
    if (shadow->cache->corner_bl) {
        shadow->buffer[SHADOW_CORNER_BL] = wlr_scene_buffer_create(shadow->tree, shadow->cache->corner_bl);
    }
    if (shadow->cache->corner_br) {
        shadow->buffer[SHADOW_CORNER_BR] = wlr_scene_buffer_create(shadow->tree, shadow->cache->corner_br);
    }

    /* Create edge buffers */
    if (shadow->cache->edge_top) {
        shadow->buffer[SHADOW_EDGE_TOP] = wlr_scene_buffer_create(shadow->tree, shadow->cache->edge_top);
    }
    if (shadow->cache->edge_bottom) {
        shadow->buffer[SHADOW_EDGE_BOTTOM] = wlr_scene_buffer_create(shadow->tree, shadow->cache->edge_bottom);
    }
    if (shadow->cache->edge_left) {
        shadow->buffer[SHADOW_EDGE_LEFT] = wlr_scene_buffer_create(shadow->tree, shadow->cache->edge_left);
    }
    if (shadow->cache->edge_right) {
        shadow->buffer[SHADOW_EDGE_RIGHT] = wlr_scene_buffer_create(shadow->tree, shadow->cache->edge_right);
    }

    /* Update geometry */
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
    int corner_size = r * 2;
    int ox = config->offset_x;
    int oy = config->offset_y;

    /* Edge dimensions (stretched to fit) */
    int edge_h_width = width - corner_size;  /* Horizontal edge width */
    int edge_v_height = height - corner_size; /* Vertical edge height */

    if (edge_h_width < 0) edge_h_width = 0;
    if (edge_v_height < 0) edge_v_height = 0;

    /* Position shadow tree with offset */
    wlr_scene_node_set_position(&shadow->tree->node, ox - r, oy - r);

    /* Corners */
    if (shadow->buffer[SHADOW_CORNER_TL]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_CORNER_TL]->node, 0, 0);
    }
    if (shadow->buffer[SHADOW_CORNER_TR]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_CORNER_TR]->node,
                                    corner_size + edge_h_width, 0);
    }
    if (shadow->buffer[SHADOW_CORNER_BL]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_CORNER_BL]->node,
                                    0, corner_size + edge_v_height);
    }
    if (shadow->buffer[SHADOW_CORNER_BR]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_CORNER_BR]->node,
                                    corner_size + edge_h_width,
                                    corner_size + edge_v_height);
    }

    /* Edges - stretched to fill gaps between corners */
    if (shadow->buffer[SHADOW_EDGE_TOP]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_EDGE_TOP]->node,
                                    corner_size, 0);
        wlr_scene_buffer_set_dest_size(shadow->buffer[SHADOW_EDGE_TOP],
                                       edge_h_width, corner_size);
    }
    if (shadow->buffer[SHADOW_EDGE_BOTTOM]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_EDGE_BOTTOM]->node,
                                    corner_size, corner_size + edge_v_height);
        wlr_scene_buffer_set_dest_size(shadow->buffer[SHADOW_EDGE_BOTTOM],
                                       edge_h_width, corner_size);
    }
    if (shadow->buffer[SHADOW_EDGE_LEFT]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_EDGE_LEFT]->node,
                                    0, corner_size);
        wlr_scene_buffer_set_dest_size(shadow->buffer[SHADOW_EDGE_LEFT],
                                       corner_size, edge_v_height);
    }
    if (shadow->buffer[SHADOW_EDGE_RIGHT]) {
        wlr_scene_node_set_position(&shadow->buffer[SHADOW_EDGE_RIGHT]->node,
                                    corner_size + edge_h_width, corner_size);
        wlr_scene_buffer_set_dest_size(shadow->buffer[SHADOW_EDGE_RIGHT],
                                       corner_size, edge_v_height);
    }
}

void
shadow_update_config(shadow_nodes_t *shadow,
                    const shadow_config_t *config,
                    int width, int height)
{
    if (!shadow)
        return;

    /* If config changed significantly, destroy and recreate */
    if (shadow->cache) {
        if (shadow->cache->radius != config->radius ||
            !colors_equal(shadow->cache->color, config->color) ||
            fabsf(shadow->cache->opacity - config->opacity) > 0.001f) {
            /* Config changed, need to recreate */
            struct wlr_scene_tree *parent = NULL;
            if (shadow->tree)
                parent = shadow->tree->node.parent;
            shadow_destroy(shadow);
            if (parent && config->enabled)
                shadow_create(parent, shadow, config, width, height);
            return;
        }
    }

    /* Just update geometry */
    shadow_update_geometry(shadow, config, width, height);
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

    if (shadow->cache) {
        shadow_cache_put(shadow->cache);
        shadow->cache = NULL;
    }

    if (shadow->tree) {
        wlr_scene_node_destroy(&shadow->tree->node);
        shadow->tree = NULL;
    }

    memset(shadow->buffer, 0, sizeof(shadow->buffer));
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

    lua_getfield(L, idx, "color");
    if (!lua_isnil(L, -1)) {
        /* Parse color - supports "#RRGGBB" or table {r, g, b, a} */
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
    /* Read beautiful.shadow_* properties and update globalconf.shadow */
    lua_getglobal(L, "beautiful");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

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
        } else if (lua_istable(L, -1)) {
            for (int i = 0; i < 4; i++) {
                lua_rawgeti(L, -1, i + 1);
                if (lua_isnumber(L, -1))
                    globalconf.shadow.client.color[i] = (float)lua_tonumber(L, -1);
                lua_pop(L, 1);
            }
        }
    }
    lua_pop(L, 1);

    /* Drawin-specific overrides (fall back to client defaults) */
    lua_getfield(L, -1, "shadow_drawin_enabled");
    if (!lua_isnil(L, -1))
        globalconf.shadow.drawin.enabled = lua_toboolean(L, -1);
    else
        globalconf.shadow.drawin.enabled = globalconf.shadow.client.enabled;
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_radius");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.radius = (int)lua_tointeger(L, -1);
    else
        globalconf.shadow.drawin.radius = globalconf.shadow.client.radius;
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_offset_x");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.offset_x = (int)lua_tointeger(L, -1);
    else
        globalconf.shadow.drawin.offset_x = globalconf.shadow.client.offset_x;
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_offset_y");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.offset_y = (int)lua_tointeger(L, -1);
    else
        globalconf.shadow.drawin.offset_y = globalconf.shadow.client.offset_y;
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_opacity");
    if (lua_isnumber(L, -1))
        globalconf.shadow.drawin.opacity = (float)lua_tonumber(L, -1);
    else
        globalconf.shadow.drawin.opacity = globalconf.shadow.client.opacity;
    lua_pop(L, 1);

    lua_getfield(L, -1, "shadow_drawin_color");
    if (!lua_isnil(L, -1)) {
        if (lua_isstring(L, -1)) {
            const char *str = lua_tostring(L, -1);
            color_t c;
            if (color_init_from_string(&c, str)) {
                globalconf.shadow.drawin.color[0] = c.red / 255.0f;
                globalconf.shadow.drawin.color[1] = c.green / 255.0f;
                globalconf.shadow.drawin.color[2] = c.blue / 255.0f;
                globalconf.shadow.drawin.color[3] = c.alpha / 255.0f;
            }
        } else if (lua_istable(L, -1)) {
            for (int i = 0; i < 4; i++) {
                lua_rawgeti(L, -1, i + 1);
                if (lua_isnumber(L, -1))
                    globalconf.shadow.drawin.color[i] = (float)lua_tonumber(L, -1);
                lua_pop(L, 1);
            }
        }
    } else {
        /* Fall back to client color */
        memcpy(globalconf.shadow.drawin.color, globalconf.shadow.client.color,
               sizeof(globalconf.shadow.drawin.color));
    }
    lua_pop(L, 1);

    lua_pop(L, 1);  /* Pop beautiful table */
}

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
