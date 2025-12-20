/*
 * lgi-check.c - Check that LGI is available at build time
 *
 * This program is run during the build to verify that the correct lgi
 * package is installed for the Lua version being used. If lgi is not
 * found, the build fails with a helpful error message.
 *
 * Based on AwesomeWM's lgi-check.c
 *
 * Copyright © 2017 Uli Schlachter <psychon@znc.in>
 * Copyright © 2024 somewm contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdio.h>
#include <stdlib.h>

const char commands[] =
"pcall(require, 'luarocks.loader')\n"
"local lua_version = jit and jit.version or _VERSION\n"
"print(string.format('Building for %s', lua_version))\n"
"local ok, lgi = pcall(require, 'lgi')\n"
"if not ok then\n"
"    error('lgi module not found: ' .. tostring(lgi))\n"
"end\n"
"local lgi_version = require('lgi.version')\n"
"print(string.format('Found lgi %s', lgi_version))\n"
"_, _, major_minor, patch = string.find(lgi_version, '^(%d%.%d)%.(%d)')\n"
"if tonumber(major_minor) < 0.8 or (tonumber(major_minor) == 0.8 and tonumber(patch) < 0) then\n"
"    error(string.format('lgi is too old, need at least version %s, got %s.',\n"
"        '0.8.0', lgi_version))\n"
"end\n"
"assert(lgi.cairo, 'lgi.cairo not found')\n"
"assert(lgi.Pango, 'lgi.Pango not found')\n"
"assert(lgi.PangoCairo, 'lgi.PangoCairo not found')\n"
"assert(lgi.GLib, 'lgi.GLib not found')\n"
"assert(lgi.Gio, 'lgi.Gio not found')\n"
"assert(lgi.GdkPixbuf, 'lgi.GdkPixbuf not found')\n"
"print('LGI check passed!')\n"
;

int main(void)
{
    int result = 0;
    const char *env = "SOMEWM_IGNORE_LGI";
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    if (luaL_dostring(L, commands))
    {
        const char *err = lua_tostring(L, -1);
        fprintf(stderr, "\n");
        fprintf(stderr, "ERROR: %s\n", err);
        fprintf(stderr, "\n");
        fprintf(stderr, "========================================\n");
        fprintf(stderr, "         LGI CHECK FAILED\n");
        fprintf(stderr, "========================================\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "somewm requires the lgi (Lua GObject Introspection) library.\n");
        fprintf(stderr, "You must install the lgi package that matches your Lua version.\n");
        fprintf(stderr, "\n");
#ifdef LUA_JITLIBNAME
        fprintf(stderr, "Detected: LuaJIT (Lua 5.1 compatible)\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Install one of these packages:\n");
        fprintf(stderr, "  Arch Linux:   sudo pacman -S lua51-lgi\n");
        fprintf(stderr, "  Debian/Ubuntu: sudo apt install lua-lgi\n");
        fprintf(stderr, "  Fedora:        sudo dnf install lua-lgi\n");
#else
        fprintf(stderr, "Detected: Lua " LUA_VERSION "\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Install the lgi package for your Lua version:\n");
        fprintf(stderr, "  Arch Linux:   sudo pacman -S lua-lgi (for Lua 5.4)\n");
        fprintf(stderr, "                sudo pacman -S lua51-lgi (for Lua 5.1)\n");
        fprintf(stderr, "  Debian/Ubuntu: sudo apt install lua-lgi\n");
        fprintf(stderr, "  Fedora:        sudo dnf install lua-lgi\n");
#endif
        fprintf(stderr, "\n");
        fprintf(stderr, "To skip this check (not recommended), set %s=1\n", env);
        fprintf(stderr, "\n");

        if (getenv(env) == NULL)
            result = 1;
        else
            fprintf(stderr, "Continuing anyway due to %s=1\n", env);
    }

    lua_close(L);
    return result;
}
