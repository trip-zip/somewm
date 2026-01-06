/*
 * lualib.h - useful functions and type for Lua
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
 *
 */

#include "common/lualib.h"
#include "luaa.h"
#include <string.h>

lua_CFunction lualib_dofunction_on_error;

void luaA_checkfunction(lua_State *L, int idx)
{
    if(!lua_isfunction(L, idx))
        luaA_typerror(L, idx, "function");
}

void luaA_checktable(lua_State *L, int idx)
{
    if(!lua_istable(L, idx))
        luaA_typerror(L, idx, "table");
}

void luaA_dumpstack(lua_State *L)
{
    int top;

    if (!L) {
        fprintf(stderr, "-------- Lua stack dump: NULL state! ---------\n");
        return;
    }

    top = lua_gettop(L);

    /* Sanity check - stack should never be this large */
    if (top < 0 || top > 10000) {
        fprintf(stderr, "-------- Lua stack dump: CORRUPTED (top=%d) ---------\n", top);
        return;
    }

    fprintf(stderr, "-------- Lua stack dump (top=%d) ---------\n", top);
    for(int i = top; i >= 1; i--)
    {
        int t = lua_type(L, i);

        /* Sanity check type value */
        if (t < LUA_TNONE || t > LUA_TTHREAD) {
            fprintf(stderr, "%d: CORRUPTED TYPE (%d)\n", i, t);
            continue;
        }

        switch (t)
        {
          case LUA_TSTRING:
            {
                const char *s = lua_tostring(L, i);
                if (s)
                    fprintf(stderr, "%d: string: `%.100s'%s\n", i, s,
                            strlen(s) > 100 ? "..." : "");
                else
                    fprintf(stderr, "%d: string: (null)\n", i);
            }
            break;
          case LUA_TBOOLEAN:
            fprintf(stderr, "%d: bool:   %s\n", i, lua_toboolean(L, i) ? "true" : "false");
            break;
          case LUA_TNUMBER:
            fprintf(stderr, "%d: number: %g\n", i, lua_tonumber(L, i));
            break;
          case LUA_TNIL:
            fprintf(stderr, "%d: nil\n", i);
            break;
          case LUA_TTABLE:
          case LUA_TUSERDATA:
            /* Only call luaA_rawlen for types that support it safely */
            fprintf(stderr, "%d: %s\t#%d\t%p\n", i, lua_typename(L, t),
                    (int) luaA_rawlen(L, i),
                    lua_topointer(L, i));
            break;
          default:
            /* For other types (function, thread, lightuserdata), don't call rawlen */
            fprintf(stderr, "%d: %s\t%p\n", i, lua_typename(L, t),
                    lua_topointer(L, i));
            break;
        }
    }
    fprintf(stderr, "------- Lua stack dump end ------\n");
}

// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
