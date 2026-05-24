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

/* Phase 1: is lgi installed / requireable at all? A failure here means lgi
 * is genuinely missing. */
const char probe_lgi[] =
"pcall(require, 'luarocks.loader')\n"
"local lua_version = jit and jit.version or _VERSION\n"
"print(string.format('Building for %s', lua_version))\n"
"assert(require('lgi'))\n"
;

/* Phase 2: lgi loads, so it is installed. Is it new enough and are the
 * namespaces somewm uses actually usable? Touching a namespace makes lgi
 * build its enums, which is where a GLib/gobject-introspection version skew
 * throws (lgi's own ffi.lua / core.record.fromarray). A failure here means
 * lgi is present but unusable, not missing. */
const char commands[] =
"local lgi = require('lgi')\n"
"local lgi_version = require('lgi.version')\n"
"print(string.format('Found lgi %s', lgi_version))\n"
"local _, _, major_minor, patch = string.find(lgi_version, '^(%d%.%d)%.(%d)')\n"
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

/* Print guidance for a failed check and decide the exit code. When installed
 * is false lgi could not be required (missing); when true lgi is present but a
 * version/namespace check failed (usually a packaging mismatch). Returns the
 * process exit code, honoring SOMEWM_IGNORE_LGI. */
static int fail(lua_State *L, int installed)
{
    const char *env = "SOMEWM_IGNORE_LGI";
    const char *err = lua_tostring(L, -1);

    fprintf(stderr, "\n");
    fprintf(stderr, "ERROR: %s\n", err);
    fprintf(stderr, "\n");
    fprintf(stderr, "========================================\n");
    fprintf(stderr, "         LGI CHECK FAILED\n");
    fprintf(stderr, "========================================\n");
    fprintf(stderr, "\n");

    if (!installed)
    {
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
#if LUA_VERSION_NUM >= 505
        fprintf(stderr, "\n");
        fprintf(stderr, "Note: Lua 5.5 support landed in lgi upstream (PR #359) but\n");
        fprintf(stderr, "distros may not ship a matching package yet. Build lgi from\n");
        fprintf(stderr, "source against Lua 5.5: https://github.com/lgi-devs/lgi\n");
#endif
#endif
        fprintf(stderr, "\n");
        fprintf(stderr, "To skip this check (not recommended), set %s=1\n", env);
        fprintf(stderr, "\n");
    }
    else
    {
        fprintf(stderr, "lgi is installed, but somewm could not load the GObject\n");
        fprintf(stderr, "namespaces it needs (see the error above).\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "If that error mentions 'fromarray' / 'lgi.record expected,\n");
        fprintf(stderr, "got table', your lgi predates GLib 2.88's enum-class change\n");
        fprintf(stderr, "and needs the upstream fix (lgi-devs/lgi#352, not yet\n");
        fprintf(stderr, "released). Any lgi without that patch breaks on GLib >= 2.88.\n");
        fprintf(stderr, "This is not a somewm bug.\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Update lgi to a build that includes the fix, or pin\n");
        fprintf(stderr, "GLib < 2.88 until your distro ships it.\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Setting %s=1 lets the build finish, but lgi will fail the\n", env);
        fprintf(stderr, "same way when somewm loads your config.\n");
        fprintf(stderr, "\n");
    }

    if (getenv(env) != NULL)
    {
        fprintf(stderr, "Continuing anyway due to %s=1\n", env);
        return 0;
    }
    return 1;
}

int main(void)
{
    int result = 0;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    if (luaL_dostring(L, probe_lgi))
        result = fail(L, 0);
    else if (luaL_dostring(L, commands))
        result = fail(L, 1);

    lua_close(L);
    return result;
}
