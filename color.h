/*
 * color.h - color parsing and manipulation
 *
 * Adapted from AwesomeWM's color.c for Wayland/somewm
 * Original copyright:
 *   Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *   Copyright © 2009 Uli Schlachter <psychon@znc.in>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef COLOR_H
#define COLOR_H

#include <stdint.h>
#include <stdbool.h>
#include <lua.h>

/** Color structure for Wayland/somewm
 *
 * Unlike AwesomeWM's X11 color_t which includes pixel values and X11 colormaps,
 * this is a simple RGBA structure. Wayland has no colormaps - colors are just
 * RGBA values used directly with Cairo or wlroots.
 */
typedef struct {
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t alpha;
    bool initialized;
} color_t;

/** Parse a hex color string to color_t
 * Supports:
 *   #RGB     -> #RRGGBB with full alpha
 *   #RRGGBB  -> RGB with full alpha (0xff)
 *   #RRGGBBAA -> RGBA with explicit alpha
 *
 * \param color Pointer to color_t to fill
 * \param colstr Color string (must start with #)
 * \return true if parsing succeeded, false on error
 */
bool color_init_from_string(color_t *color, const char *colstr);

/** Convert color_t to Cairo color format (doubles 0.0-1.0)
 * \param color Source color
 * \param r Pointer to store red (0.0-1.0)
 * \param g Pointer to store green (0.0-1.0)
 * \param b Pointer to store blue (0.0-1.0)
 * \param a Pointer to store alpha (0.0-1.0)
 */
void color_to_cairo(const color_t *color, double *r, double *g, double *b, double *a);

/** Convert color_t to float array for wlroots (0.0-1.0)
 * Format: float[4] = {r, g, b, a} where each is 0.0-1.0
 * This is the format used by wlr_scene_rect_set_color()
 * \param color Source color
 * \param floats Pointer to float[4] array to fill
 */
void color_to_floats(const color_t *color, float floats[static 4]);

/** Convert color_t to uint32_t ARGB format
 * Format: 0xAARRGGBB (suitable for wlroots)
 * \param color Source color
 * \return uint32_t in ARGB format
 */
uint32_t color_to_uint32(const color_t *color);

/** Convert color_t to uint32_t RGBA format
 * Format: 0xRRGGBBAA (alternative format)
 * \param color Source color
 * \return uint32_t in RGBA format
 */
uint32_t color_to_uint32_rgba(const color_t *color);

/** Push a color as a hex string onto the Lua stack
 * Format: "#RRGGBB" or "#RRGGBBAA" if alpha < 0xff
 * \param L Lua state
 * \param color Color to push
 * \return Number of elements pushed on stack (always 1)
 */
int luaA_pushcolor(lua_State *L, const color_t *color);

/** Parse a color from Lua
 * Accepts a hex color string from the Lua stack
 * \param L Lua state
 * \param idx Stack index of color string
 * \param color Pointer to color_t to fill
 * \return true if parsing succeeded, false on error
 */
bool luaA_tocolor(lua_State *L, int idx, color_t *color);

#endif /* COLOR_H */
