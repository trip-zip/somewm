/*
 * draw.h - drawing utilities
 *
 * Adapted from AwesomeWM's draw.h for Wayland/somewm
 * Original copyright:
 *   Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef DRAW_H
#define DRAW_H

#include <stdint.h>
#include <cairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <lua.h>

#ifdef XWAYLAND
#include <xcb/xcb.h>
#endif


/** Create a Cairo surface from a GdkPixbuf
 *
 * Converts a GdkPixbuf (loaded image) to a Cairo image surface.
 * Handles both RGB (3 channel) and RGBA (4 channel) pixbufs.
 * Applies premultiplied alpha for RGBA images.
 *
 * \param buf GdkPixbuf to convert
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *draw_surface_from_pixbuf(GdkPixbuf *buf);

/** Duplicate a Cairo image surface
 *
 * Creates a copy of the given surface. Useful for creating modified versions
 * of images without affecting the original.
 *
 * \param surface Surface to duplicate
 * \return A new Cairo image surface with the same contents, or NULL on error
 */
cairo_surface_t *draw_dup_image_surface(cairo_surface_t *surface);

/** Load an image file into a Cairo surface
 *
 * Uses GdkPixbuf to load various image formats (PNG, JPEG, etc.) and converts
 * to a Cairo surface suitable for rendering.
 *
 * \param L Lua state (for error reporting compatibility with AwesomeWM)
 * \param path Path to image file
 * \param error Pointer to store GError if loading fails (can be NULL)
 * \return A new Cairo image surface, or NULL on error
 */
cairo_surface_t *draw_load_image(lua_State *L, const char *path, GError **error);

/* X11 visual functions - stubs for XWayland compatibility
 * Note: We use void* instead of xcb_screen_t* because somewm's globalconf.screen
 * is not an xcb_screen_t* like in AwesomeWM. These stubs just return NULL anyway.
 */
#ifdef XWAYLAND
void *draw_find_visual(const void *s, uint32_t visual);
#endif

#endif /* DRAW_H */
