/*
 * draw.c - drawing utilities
 *
 * Adapted from AwesomeWM's draw.c for Wayland/somewm
 * Original copyright:
 *   Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * X11-specific code removed:
 *   - All X11 visual querying (lines 195-240 in original)
 *   - Cairo-XCB integration (lines 242-255 in original)
 *   - globalconf dependencies
 *
 * Portable code extracted:
 *   - Surface creation from ARGB data (lines 50-78)
 *   - GdkPixbuf conversion (lines 84-134)
 *   - Surface duplication (lines 152-172)
 *   - Image loading (lines 180-193)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "draw.h"
#include "common/util.h"

#include <stdlib.h>
#include <math.h>

/* Cairo user data key for automatic buffer cleanup */
static cairo_user_data_key_t data_key;

/** Free data callback for Cairo surface user data */
static inline void
free_data(void *data)
{
    free(data);
}

/** Create a Cairo surface from raw ARGB data
 *
 * Extracted from AwesomeWM draw.c lines 50-78.
 * No modifications needed - this is pure Cairo code with no X11 dependencies.
 *
 * \param width Width of the image in pixels
 * \param height Height of the image in pixels
 * \param data Pointer to ARGB pixel data (format: 0xAARRGGBB per pixel)
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *
draw_surface_from_data(int width, int height, uint32_t *data)
{
    unsigned long int len;
    unsigned long int i;
    uint32_t *buffer;
    cairo_surface_t *surface;

    len = width * height;
    buffer = malloc(len * sizeof(uint32_t));
    if (!buffer)
        return NULL;

    /* Cairo wants premultiplied alpha, meh :( */
    for(i = 0; i < len; i++)
    {
        uint8_t a = (data[i] >> 24) & 0xff;
        double alpha = a / 255.0;
        uint8_t r = (uint8_t)(((data[i] >> 16) & 0xff) * alpha);
        uint8_t g = (uint8_t)(((data[i] >>  8) & 0xff) * alpha);
        uint8_t b = (uint8_t)(((data[i] >>  0) & 0xff) * alpha);
        buffer[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }

    surface =
        cairo_image_surface_create_for_data((unsigned char *) buffer,
                                            CAIRO_FORMAT_ARGB32,
                                            width,
                                            height,
                                            width*4);
    /* This makes sure that buffer will be freed */
    cairo_surface_set_user_data(surface, &data_key, buffer, &free_data);

    return surface;
}

/** Create a Cairo surface from a GdkPixbuf
 *
 * Extracted from AwesomeWM draw.c lines 84-134.
 * No modifications needed - this is pure GdkPixbuf/Cairo code.
 *
 * \param buf GdkPixbuf to convert
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *
draw_surface_from_pixbuf(GdkPixbuf *buf)
{
    int width;
    int height;
    int pix_stride;
    guchar *pixels;
    int channels;
    cairo_surface_t *surface;
    int cairo_stride;
    unsigned char *cairo_pixels;
    cairo_format_t format;
    int y;

    width = gdk_pixbuf_get_width(buf);
    height = gdk_pixbuf_get_height(buf);
    pix_stride = gdk_pixbuf_get_rowstride(buf);
    pixels = gdk_pixbuf_get_pixels(buf);
    channels = gdk_pixbuf_get_n_channels(buf);

    format = CAIRO_FORMAT_ARGB32;
    if (channels == 3)
        format = CAIRO_FORMAT_RGB24;

    surface = cairo_image_surface_create(format, width, height);
    cairo_surface_flush(surface);
    cairo_stride = cairo_image_surface_get_stride(surface);
    cairo_pixels = cairo_image_surface_get_data(surface);

    for (y = 0; y < height; y++)
    {
        guchar *row;
        uint32_t *cairo;
        int x;

        row = pixels;
        cairo = (uint32_t *) cairo_pixels;

        for (x = 0; x < width; x++) {
            if (channels == 3)
            {
                uint8_t r = *row++;
                uint8_t g = *row++;
                uint8_t b = *row++;
                *cairo++ = (r << 16) | (g << 8) | b;
            } else {
                uint8_t r = *row++;
                uint8_t g = *row++;
                uint8_t b = *row++;
                uint8_t a = *row++;
                double alpha = a / 255.0;
                r = (uint8_t)(r * alpha);
                g = (uint8_t)(g * alpha);
                b = (uint8_t)(b * alpha);
                *cairo++ = ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
            }
        }
        pixels += pix_stride;
        cairo_pixels += cairo_stride;
    }

    cairo_surface_mark_dirty(surface);
    return surface;
}

/** Get the size of a Cairo surface
 *
 * Extracted from AwesomeWM draw.c lines 136-146.
 * Helper function for draw_dup_image_surface().
 *
 * \param surface Surface to measure
 * \param width Pointer to store width
 * \param height Pointer to store height
 */
static void
get_surface_size(cairo_surface_t *surface, int *width, int *height)
{
    double x1, y1, x2, y2;
    cairo_t *cr;

    cr = cairo_create(surface);
    cairo_clip_extents(cr, &x1, &y1, &x2, &y2);
    cairo_destroy(cr);

    *width = (int)(x2 - x1);
    *height = (int)(y2 - y1);
}

/** Duplicate a Cairo image surface
 *
 * Extracted from AwesomeWM draw.c lines 152-172.
 * No modifications needed - pure Cairo code.
 *
 * \param surface Surface to duplicate
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *
draw_dup_image_surface(cairo_surface_t *surface)
{
    cairo_surface_t *res;
    int width, height;
    cairo_t *cr;

    get_surface_size(surface, &width, &height);

#if CAIRO_VERSION_MAJOR == 1 && CAIRO_VERSION_MINOR > 12
    res = cairo_surface_create_similar_image(surface, CAIRO_FORMAT_ARGB32, width, height);
#else
    res = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
#endif

    cr = cairo_create(res);
    cairo_set_source_surface(cr, surface, 0, 0);
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_paint(cr);
    cairo_destroy(cr);

    return res;
}

/** Load an image file into a Cairo surface
 *
 * Extracted from AwesomeWM draw.c lines 180-193.
 * No modifications needed - uses GdkPixbuf for loading.
 *
 * \param L Lua state (for API consistency with AwesomeWM)
 * \param path Path to image file
 * \param error Pointer to store GError if loading fails (can be NULL)
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *
draw_load_image(lua_State *L, const char *path, GError **error)
{
    cairo_surface_t *ret;
    GdkPixbuf *buf;

    (void)L;  /* Unused - kept for API compatibility */

    buf = gdk_pixbuf_new_from_file(path, error);

    if (!buf)
        /* error was set by gdk_pixbuf_new_from_file */
        return NULL;

    ret = draw_surface_from_pixbuf(buf);
    g_object_unref(buf);
    return ret;
}

/* X11 visual functions - stubs for Wayland compatibility
 * These exist in AwesomeWM for X11 visual/depth handling.
 * In Wayland, visuals are handled differently by the compositor.
 *
 * Note: We use void* instead of xcb_screen_t* because somewm's globalconf.screen
 * is not an xcb_screen_t* like in AwesomeWM. These stubs just return NULL anyway.
 */

#ifdef XWAYLAND
#include <xcb/xcb.h>

void *
draw_find_visual(const void *s, uint32_t visual)
{
    (void)s;
    (void)visual;
    return NULL;
}

void *
draw_default_visual(const void *s)
{
    (void)s;
    return NULL;
}

void *
draw_argb_visual(const void *s)
{
    (void)s;
    return NULL;
}

uint8_t
draw_visual_depth(const void *s, uint32_t vis)
{
    (void)s;
    (void)vis;
    return 32;  /* Default to 32-bit depth for ARGB */
}

void
draw_test_cairo_xcb(void)
{
    /* No-op in Wayland - Cairo/XCB integration test not needed */
}

#endif /* XWAYLAND */
