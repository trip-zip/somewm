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

#include "shadow.h"
#include "color.h"
#include "globalconf.h"
#include <stdio.h>
#include <string.h>
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

/** Peak paint alpha: opacity scaled by the color's own alpha channel. */
float
shadow_paint(const shadow_config_t *config)
{
    float paint = config->opacity * config->color[3];
    if (paint < 0.0f) paint = 0.0f;
    if (paint > 1.0f) paint = 1.0f;
    return paint;
}

/* ========== Core API ========== */

void
shadow_init(void)
{
    /* Styles are authored inputs; render states own all tiles. */
}

void
shadow_cleanup(void)
{
    /* Render state teardown releases its shared tiles. */
}

const shadow_config_t *
shadow_get_effective_config(const shadow_config_t *override, bool is_drawin)
{
    if (override)
        return override;

    return is_drawin ? &globalconf.shadow.drawin : &globalconf.shadow.client;
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
