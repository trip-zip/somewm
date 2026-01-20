/*
 * ewmh.c - EWMH support functions
 *
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
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

#include "ewmh.h"
#include "globalconf.h"
#include "objects/client.h"
#include "objects/tag.h"
#include "luaa.h"
#include "x11_compat.h"
#include "common/util.h"

#ifdef XWAYLAND
#include <xcb/xcb.h>
#include <xcb/xcb_atom.h>
#include <string.h>
#include <stdlib.h>

#define _NET_WM_STATE_REMOVE 0
#define _NET_WM_STATE_ADD 1
#define _NET_WM_STATE_TOGGLE 2

#define ALL_DESKTOPS 0xffffffff

/* ========== INITIALIZATION (Lines 645-680 from AwesomeWM) ========== */

/** Initialize EWMH support on XWayland startup.
 * Creates the _NET_SUPPORTING_WM_CHECK window and advertises EWMH capabilities.
 * This function matches AwesomeWM's ewmh_init() exactly.
 *
 * \param conn XCB connection to X server
 * \param screen_nbr Physical screen number (usually 0)
 */
void
ewmh_init(xcb_connection_t *conn, int screen_nbr)
{
    xcb_window_t root;
    const char *wm_name;
    int i;

    if (!conn || !globalconf.screen) return;

    root = globalconf.screen->root;

    /* 1. Create invisible _NET_SUPPORTING_WM_CHECK window (AwesomeWM pattern) */
    globalconf.ewmh.window = xcb_generate_id(conn);
    xcb_create_window(conn, globalconf.screen->root_depth,
                      globalconf.ewmh.window, root,
                      -1, -1, 1, 1, 0,
                      XCB_COPY_FROM_PARENT,
                      globalconf.screen->root_visual,
                      0, NULL);

    /* 2. Set _NET_SUPPORTING_WM_CHECK on root → invisible window */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, root,
                        _NET_SUPPORTING_WM_CHECK, XCB_ATOM_WINDOW, 32, 1,
                        &globalconf.ewmh.window);

    /* 3. Set _NET_SUPPORTING_WM_CHECK on invisible window → itself (EWMH spec) */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, globalconf.ewmh.window,
                        _NET_SUPPORTING_WM_CHECK, XCB_ATOM_WINDOW, 32, 1,
                        &globalconf.ewmh.window);

    /* 4. Set _NET_WM_NAME on invisible window (WM name) */
    wm_name = "somewm";
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, globalconf.ewmh.window,
                        _NET_WM_NAME, UTF8_STRING, 8, strlen(wm_name), wm_name);

    /* 5. Build _NET_SUPPORTED atom list (all 46 atoms we support) */
    globalconf.ewmh.supported_atoms_count = 46;
    globalconf.ewmh.supported_atoms = malloc(46 * sizeof(xcb_atom_t));

    /* Populate supported atoms array - exact order from plan */
    i = 0;
    globalconf.ewmh.supported_atoms[i++] = _NET_SUPPORTED;
    globalconf.ewmh.supported_atoms[i++] = _NET_SUPPORTING_WM_CHECK;
    globalconf.ewmh.supported_atoms[i++] = _NET_CLIENT_LIST;
    globalconf.ewmh.supported_atoms[i++] = _NET_CLIENT_LIST_STACKING;
    globalconf.ewmh.supported_atoms[i++] = _NET_NUMBER_OF_DESKTOPS;
    globalconf.ewmh.supported_atoms[i++] = _NET_DESKTOP_NAMES;
    globalconf.ewmh.supported_atoms[i++] = _NET_CURRENT_DESKTOP;
    globalconf.ewmh.supported_atoms[i++] = _NET_ACTIVE_WINDOW;
    globalconf.ewmh.supported_atoms[i++] = _NET_CLOSE_WINDOW;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_NAME;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_VISIBLE_NAME;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_ICON_NAME;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_VISIBLE_ICON_NAME;
    globalconf.ewmh.supported_atoms[i++] = _NET_DESKTOP_GEOMETRY;
    globalconf.ewmh.supported_atoms[i++] = _NET_DESKTOP_VIEWPORT;
    globalconf.ewmh.supported_atoms[i++] = _NET_WORKAREA;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_DESKTOP;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_STICKY;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_SKIP_TASKBAR;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_FULLSCREEN;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_MAXIMIZED_HORZ;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_MAXIMIZED_VERT;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_ABOVE;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_BELOW;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_MODAL;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_HIDDEN;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_STATE_DEMANDS_ATTENTION;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_DESKTOP;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_DOCK;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_TOOLBAR;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_MENU;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_UTILITY;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_SPLASH;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_DIALOG;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_DROPDOWN_MENU;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_POPUP_MENU;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_TOOLTIP;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_NOTIFICATION;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_COMBO;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_DND;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_WINDOW_TYPE_NORMAL;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_ICON;
    globalconf.ewmh.supported_atoms[i++] = _NET_WM_PID;

    /* 6. Set _NET_SUPPORTED on root (advertise our EWMH capabilities) */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, root,
                        _NET_SUPPORTED, XCB_ATOM_ATOM, 32,
                        globalconf.ewmh.supported_atoms_count,
                        globalconf.ewmh.supported_atoms);

    log_info("EWMH initialized (%zu atoms)", globalconf.ewmh.supported_atoms_count);
}

static int
ewmh_update_net_active_window(lua_State *L)
{
    xcb_window_t win;

    if (!globalconf.connection || !globalconf.screen)
        return 0;

    if(globalconf.focus.client && globalconf.focus.client->client_type == X11)
        win = globalconf.focus.client->window;
    else
        win = XCB_NONE;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
			globalconf.screen->root,
			_NET_ACTIVE_WINDOW, XCB_ATOM_WINDOW, 32, 1, &win);

    return 0;
}

/* ========== CLIENT HINTS CHECKING (Lines 377-487 from AwesomeWM) ========== */

/** Read EWMH properties from newly created XWayland client.
 * This function matches AwesomeWM's ewmh_client_check_hints() exactly.
 *
 * \param c The client to check
 */
void
ewmh_client_check_hints(client_t *c)
{
    xcb_connection_t *conn;
    xcb_get_property_cookie_t cookies[4];
    xcb_get_property_reply_t *reply;
    xcb_atom_t *atoms;
    int count, i;
    uint32_t desktop, pid;
    xcb_atom_t type_atom;

    if (!globalconf.connection || c->client_type != X11) return;

    conn = globalconf.connection;

    /* Batch property reads (AwesomeWM efficiency pattern) */
    cookies[0] = xcb_get_property(conn, 0, c->window,
                                   _NET_WM_DESKTOP, XCB_ATOM_CARDINAL, 0, 1);
    cookies[1] = xcb_get_property(conn, 0, c->window,
                                   _NET_WM_STATE, XCB_ATOM_ATOM, 0, UINT32_MAX);
    cookies[2] = xcb_get_property(conn, 0, c->window,
                                   _NET_WM_WINDOW_TYPE, XCB_ATOM_ATOM, 0, UINT32_MAX);
    cookies[3] = xcb_get_property(conn, 0, c->window,
                                   _NET_WM_PID, XCB_ATOM_CARDINAL, 0, 1);

    /* 1. Process _NET_WM_DESKTOP (desktop/tag assignment) */
    reply = xcb_get_property_reply(conn, cookies[0], NULL);
    if (reply && xcb_get_property_value_length(reply) > 0) {
        desktop = *(uint32_t *)xcb_get_property_value(reply);
        /* TODO: Assign client to tag at desktop index */
        /* This would emit "request::tag" signal in AwesomeWM */
        (void)desktop;  /* Suppress warning for now */
    }
    free(reply);

    /* 2. Process _NET_WM_STATE (fullscreen, maximized, etc.) */
    reply = xcb_get_property_reply(conn, cookies[1], NULL);
    if (reply) {
        atoms = xcb_get_property_value(reply);
        count = xcb_get_property_value_length(reply) / sizeof(xcb_atom_t);

        for (i = 0; i < count; i++) {
            if (atoms[i] == _NET_WM_STATE_FULLSCREEN)
                c->fullscreen = true;
            else if (atoms[i] == _NET_WM_STATE_MAXIMIZED_HORZ)
                c->maximized_horizontal = true;
            else if (atoms[i] == _NET_WM_STATE_MAXIMIZED_VERT)
                c->maximized_vertical = true;
            else if (atoms[i] == _NET_WM_STATE_STICKY)
                c->sticky = true;
            else if (atoms[i] == _NET_WM_STATE_ABOVE)
                c->above = true;
            else if (atoms[i] == _NET_WM_STATE_BELOW)
                c->below = true;
            else if (atoms[i] == _NET_WM_STATE_MODAL)
                c->modal = true;
            else if (atoms[i] == _NET_WM_STATE_DEMANDS_ATTENTION) {
                lua_State *L = globalconf_get_lua_State();
                luaA_object_push(L, c);
                client_set_urgent(L, -1, true);
                lua_pop(L, 1);
            }
            else if (atoms[i] == _NET_WM_STATE_SKIP_TASKBAR)
                c->skip_taskbar = true;
            else if (atoms[i] == _NET_WM_STATE_HIDDEN)
                c->minimized = true;
        }
    }
    free(reply);

    /* 3. Process _NET_WM_WINDOW_TYPE (window type) */
    reply = xcb_get_property_reply(conn, cookies[2], NULL);
    if (reply && xcb_get_property_value_length(reply) > 0) {
        atoms = xcb_get_property_value(reply);
        type_atom = atoms[0];  /* Use first type */

        if (type_atom == _NET_WM_WINDOW_TYPE_DESKTOP)
            c->type = WINDOW_TYPE_DESKTOP;
        else if (type_atom == _NET_WM_WINDOW_TYPE_DOCK)
            c->type = WINDOW_TYPE_DOCK;
        else if (type_atom == _NET_WM_WINDOW_TYPE_SPLASH)
            c->type = WINDOW_TYPE_SPLASH;
        else if (type_atom == _NET_WM_WINDOW_TYPE_DIALOG)
            c->type = WINDOW_TYPE_DIALOG;
        else if (type_atom == _NET_WM_WINDOW_TYPE_UTILITY)
            c->type = WINDOW_TYPE_UTILITY;
        else if (type_atom == _NET_WM_WINDOW_TYPE_TOOLBAR)
            c->type = WINDOW_TYPE_TOOLBAR;
        else if (type_atom == _NET_WM_WINDOW_TYPE_MENU)
            c->type = WINDOW_TYPE_MENU;
        else if (type_atom == _NET_WM_WINDOW_TYPE_DROPDOWN_MENU)
            c->type = WINDOW_TYPE_DROPDOWN_MENU;
        else if (type_atom == _NET_WM_WINDOW_TYPE_POPUP_MENU)
            c->type = WINDOW_TYPE_POPUP_MENU;
        else if (type_atom == _NET_WM_WINDOW_TYPE_TOOLTIP)
            c->type = WINDOW_TYPE_TOOLTIP;
        else if (type_atom == _NET_WM_WINDOW_TYPE_NOTIFICATION)
            c->type = WINDOW_TYPE_NOTIFICATION;
        else if (type_atom == _NET_WM_WINDOW_TYPE_COMBO)
            c->type = WINDOW_TYPE_COMBO;
        else if (type_atom == _NET_WM_WINDOW_TYPE_DND)
            c->type = WINDOW_TYPE_DND;
        else if (type_atom == _NET_WM_WINDOW_TYPE_NORMAL)
            c->type = WINDOW_TYPE_NORMAL;
    }
    free(reply);

    /* 4. Process _NET_WM_PID (process ID) */
    reply = xcb_get_property_reply(conn, cookies[3], NULL);
    if (reply && xcb_get_property_value_length(reply) > 0) {
        pid = *(uint32_t *)xcb_get_property_value(reply);
        c->pid = pid;
    }
    free(reply);
}

/** Update client EWMH hints.
 * \param L The Lua VM state.
 */
static int
ewmh_client_update_hints(lua_State *L)
{
    client_t *c = luaA_checkudata(L, 1, &client_class);
    xcb_atom_t state[10];
    int i = 0;

    if (!globalconf.connection || c->client_type != X11)
        return 0;

    if(c->modal)
        state[i++] = _NET_WM_STATE_MODAL;
    if(c->fullscreen)
        state[i++] = _NET_WM_STATE_FULLSCREEN;
    if(c->maximized_vertical || c->maximized)
        state[i++] = _NET_WM_STATE_MAXIMIZED_VERT;
    if(c->maximized_horizontal || c->maximized)
        state[i++] = _NET_WM_STATE_MAXIMIZED_HORZ;
    if(c->sticky)
        state[i++] = _NET_WM_STATE_STICKY;
    if(c->skip_taskbar)
        state[i++] = _NET_WM_STATE_SKIP_TASKBAR;
    if(c->above)
        state[i++] = _NET_WM_STATE_ABOVE;
    if(c->below)
        state[i++] = _NET_WM_STATE_BELOW;
    if(c->minimized)
        state[i++] = _NET_WM_STATE_HIDDEN;
    if(c->urgent)
        state[i++] = _NET_WM_STATE_DEMANDS_ATTENTION;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                        c->window, _NET_WM_STATE, XCB_ATOM_ATOM, 32, i, state);

    return 0;
}

static void
ewmh_update_maximize(bool h, bool status, bool toggle)
{
    lua_State *L = globalconf_get_lua_State();

    if (h)
        lua_pushstring(L, "client_maximize_horizontal");
    else
        lua_pushstring(L, "client_maximize_vertical");

    /* Create table argument with raise=true. */
    lua_newtable(L);
    lua_pushstring(L, "toggle");
    lua_pushboolean(L, toggle);
    lua_settable(L, -3);
    lua_pushstring(L, "status");
    lua_pushboolean(L, status);
    lua_settable(L, -3);

    luaA_object_emit_signal(L, -3, "request::geometry", 2);
}

static void
ewmh_process_state_atom(client_t *c, xcb_atom_t state, int set)
{
    lua_State *L = globalconf_get_lua_State();
    luaA_object_push(L, c);

    if(state == _NET_WM_STATE_STICKY)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_sticky(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_sticky(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_sticky(L, -1, !c->sticky);
    }
    else if(state == _NET_WM_STATE_SKIP_TASKBAR)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_skip_taskbar(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_skip_taskbar(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_skip_taskbar(L, -1, !c->skip_taskbar);
    }
    else if(state == _NET_WM_STATE_FULLSCREEN)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_fullscreen(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_fullscreen(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_fullscreen(L, -1, !c->fullscreen);
    }
    else if(state == _NET_WM_STATE_MAXIMIZED_HORZ)
    {
        if(set == _NET_WM_STATE_REMOVE)
            ewmh_update_maximize(true, false, false);
        else if(set == _NET_WM_STATE_ADD)
            ewmh_update_maximize(true, true, false);
        else if(set == _NET_WM_STATE_TOGGLE)
            ewmh_update_maximize(true, false, true);
    }
    else if(state == _NET_WM_STATE_MAXIMIZED_VERT)
    {
        if(set == _NET_WM_STATE_REMOVE)
            ewmh_update_maximize(false, false, false);
        else if(set == _NET_WM_STATE_ADD)
            ewmh_update_maximize(false, true, false);
        else if(set == _NET_WM_STATE_TOGGLE)
            ewmh_update_maximize(false, false, true);
    }
    else if(state == _NET_WM_STATE_ABOVE)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_above(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_above(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_above(L, -1, !c->above);
    }
    else if(state == _NET_WM_STATE_BELOW)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_below(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_below(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_below(L, -1, !c->below);
    }
    else if(state == _NET_WM_STATE_MODAL)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_modal(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_modal(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_modal(L, -1, !c->modal);
    }
    else if(state == _NET_WM_STATE_HIDDEN)
    {
        if(set == _NET_WM_STATE_REMOVE)
            client_set_minimized(L, -1, false);
        else if(set == _NET_WM_STATE_ADD)
            client_set_minimized(L, -1, true);
        else if(set == _NET_WM_STATE_TOGGLE)
            client_set_minimized(L, -1, !c->minimized);
    }
    else if(state == _NET_WM_STATE_DEMANDS_ATTENTION)
    {
        if(set == _NET_WM_STATE_REMOVE) {
            lua_pushboolean(L, false);
            luaA_object_emit_signal(L, -2, "request::urgent", 1);
        }
        else if(set == _NET_WM_STATE_ADD) {
            lua_pushboolean(L, true);
            luaA_object_emit_signal(L, -2, "request::urgent", 1);
        }
        else if(set == _NET_WM_STATE_TOGGLE) {
            lua_pushboolean(L, !c->urgent);
            luaA_object_emit_signal(L, -2, "request::urgent", 1);
        }
    }

    lua_pop(L, 1);
}

static void
ewmh_process_desktop(client_t *c, uint32_t desktop)
{
    lua_State *L = globalconf_get_lua_State();
    int idx = desktop;
    if(desktop == ALL_DESKTOPS)
    {
        luaA_object_push(L, c);
        lua_pushboolean(L, true);
        luaA_object_emit_signal(L, -2, "request::tag", 1);
        lua_pop(L, 1);
    }
    else if (idx >= 0 && idx < globalconf.tags.len)
    {
        luaA_object_push(L, c);
        luaA_object_push(L, globalconf.tags.tab[idx]);
        luaA_object_emit_signal(L, -2, "request::tag", 1);
        lua_pop(L, 1);
    }
}

int
ewmh_process_client_message(xcb_client_message_event_t *ev)
{
    client_t *c;

    if (!globalconf.connection)
        return 0;

    if(ev->type == _NET_CURRENT_DESKTOP)
    {
        int idx = ev->data.data32[0];
        if (idx >= 0 && idx < globalconf.tags.len)
        {
            lua_State *L = globalconf_get_lua_State();
            luaA_object_push(L, globalconf.tags.tab[idx]);
            lua_pushstring(L, "ewmh");
            luaA_object_emit_signal(L, -2, "request::select", 1);
            lua_pop(L, 1);
        }
    }
    else if(ev->type == _NET_CLOSE_WINDOW)
    {
        if((c = client_getbywin(ev->window)))
           client_kill(c);
    }
    else if(ev->type == _NET_WM_DESKTOP)
    {
        if((c = client_getbywin(ev->window)))
        {
            ewmh_process_desktop(c, ev->data.data32[0]);
        }
    }
    else if(ev->type == _NET_WM_STATE)
    {
        if((c = client_getbywin(ev->window)))
        {
            ewmh_process_state_atom(c, (xcb_atom_t) ev->data.data32[1], ev->data.data32[0]);
            if(ev->data.data32[2])
                ewmh_process_state_atom(c, (xcb_atom_t) ev->data.data32[2],
                                        ev->data.data32[0]);
        }
    }
    else if(ev->type == _NET_ACTIVE_WINDOW)
    {
        if((c = client_getbywin(ev->window))) {
            lua_State *L = globalconf_get_lua_State();
            luaA_object_push(L, c);
            lua_pushstring(L, "ewmh");

            /* Create table argument with raise=true. */
            lua_newtable(L);
            lua_pushstring(L, "raise");
            lua_pushboolean(L, true);
            lua_settable(L, -3);

            luaA_object_emit_signal(L, -3, "request::activate", 2);
            lua_pop(L, 1);
        }
    }

    return 0;
}

static int
ewmh_update_net_client_list(lua_State *L)
{
    int n = 0;
    xcb_window_t *wins;

    if (!globalconf.connection || !globalconf.screen)
        return 0;

    /* Allocate on stack for X11 clients only */
    wins = alloca(globalconf.clients.len * sizeof(xcb_window_t));

    foreach(client, globalconf.clients)
        if((*client)->client_type == X11)
            wins[n++] = (*client)->window;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_CLIENT_LIST, XCB_ATOM_WINDOW, 32, n, wins);

    return 0;
}

/** Set the client list in stacking order, bottom to top.
 */
void
ewmh_update_net_client_list_stacking(void)
{
    int n = 0;
    xcb_window_t *wins;

    if (!globalconf.connection || !globalconf.screen)
        return;

    /* Allocate on stack for X11 clients only */
    wins = alloca(globalconf.stack.len * sizeof(xcb_window_t));

    foreach(client, globalconf.stack)
        if((*client)->client_type == X11)
            wins[n++] = (*client)->window;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
			globalconf.screen->root,
			_NET_CLIENT_LIST_STACKING, XCB_ATOM_WINDOW, 32, n, wins);
}

void
ewmh_update_net_numbers_of_desktop(void)
{
    uint32_t count;

    if (!globalconf.connection || !globalconf.screen)
        return;

    count = globalconf.tags.len;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
			globalconf.screen->root,
			_NET_NUMBER_OF_DESKTOPS, XCB_ATOM_CARDINAL, 32, 1, &count);
}

int
ewmh_update_net_current_desktop(lua_State *L)
{
    uint32_t idx = 0;
    int i;

    if (!globalconf.connection || !globalconf.screen)
        return 0;

    /* Find first selected tag index */
    for (i = 0; i < globalconf.tags.len; i++) {
        if (globalconf.tags.tab[i]->selected) {
            idx = i;
            break;
        }
    }

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_CURRENT_DESKTOP, XCB_ATOM_CARDINAL, 32, 1, &idx);
    return 0;
}

void
ewmh_update_net_desktop_names(void)
{
    size_t total_len, len;
    char *names, *p;

    if (!globalconf.connection || !globalconf.screen)
        return;

    /* Build NULL-separated UTF8 string list (EWMH spec) */
    total_len = 0;
    foreach(tag, globalconf.tags)
        total_len += strlen((*tag)->name) + 1;

    if (total_len == 0)
        return;

    names = malloc(total_len);
    p = names;
    foreach(tag, globalconf.tags)
    {
        len = strlen((*tag)->name);
        memcpy(p, (*tag)->name, len);
        p += len;
        *p++ = '\0';
    }

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
			globalconf.screen->root,
			_NET_DESKTOP_NAMES, UTF8_STRING, 8, total_len, names);
    free(names);
}

/** Update _NET_DESKTOP_GEOMETRY with screen size.
 * This function matches AwesomeWM's ewmh_update_net_desktop_geometry() exactly.
 *
 * \param conn XCB connection to X server
 * \param phys_screen Physical screen number (unused in Wayland)
 */
void
ewmh_update_net_desktop_geometry(xcb_connection_t *conn, int phys_screen)
{
    uint32_t geom[2];

    (void)phys_screen;  /* Not used in Wayland */

    if (!conn || !globalconf.screen) return;

    /* TODO: Get geometry from wlroots output layout
     * For now, use dummy values
     */
    geom[0] = 1920;
    geom[1] = 1080;

    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_DESKTOP_GEOMETRY, XCB_ATOM_CARDINAL, 32, 2, geom);
}

/** Update the client active desktop.
 * This is "wrong" since it can be on several tags, but EWMH has a strict view
 * of desktop system so just take the first tag.
 * \param c The client.
 */
void
ewmh_client_update_desktop(client_t *c)
{
    int i;

    if (!globalconf.connection || c->client_type != X11)
        return;

    if(c->sticky)
    {
        xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                            c->window, _NET_WM_DESKTOP, XCB_ATOM_CARDINAL, 32, 1,
                            (uint32_t[]) { ALL_DESKTOPS });
        return;
    }
    for(i = 0; i < globalconf.tags.len; i++)
        if(is_client_tagged(c, globalconf.tags.tab[i]))
        {
            xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                                c->window, _NET_WM_DESKTOP, XCB_ATOM_CARDINAL, 32, 1, &i);
            return;
        }
    /* It doesn't have any tags, remove the property */
    xcb_delete_property(globalconf.connection, c->window, _NET_WM_DESKTOP);
}

/** Update the client struts.
 * \param window The window to update the struts for.
 * \param strut The strut type to update the window with.
 */
void
ewmh_update_strut(xcb_window_t window, strut_t *strut)
{
    if (!globalconf.connection)
        return;

    if(window)
    {
        const uint32_t state[] =
        {
            strut->left,
            strut->right,
            strut->top,
            strut->bottom,
            strut->left_start_y,
            strut->left_end_y,
            strut->right_start_y,
            strut->right_end_y,
            strut->top_start_x,
            strut->top_end_x,
            strut->bottom_start_x,
            strut->bottom_end_x
        };

        xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                            window, _NET_WM_STRUT_PARTIAL, XCB_ATOM_CARDINAL, 32, 12, state);
    }
}

/** Update the window type.
 * \param window The window to update.
 * \param type The new type to set.
 */
void
ewmh_update_window_type(xcb_window_t window, uint32_t type)
{
    if (!globalconf.connection)
        return;

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                        window, _NET_WM_WINDOW_TYPE, XCB_ATOM_ATOM, 32, 1, &type);
}

/** Process the WM strut of a client.
 * \param c The client.
 */
void
ewmh_process_client_strut(client_t *c)
{
    void *data;
    xcb_get_property_reply_t *strut_r;

    if (!globalconf.connection || c->client_type != X11)
        return;

    xcb_get_property_cookie_t strut_q = xcb_get_property_unchecked(globalconf.connection, false, c->window,
                                                                   _NET_WM_STRUT_PARTIAL, XCB_ATOM_CARDINAL, 0, 12);
    strut_r = xcb_get_property_reply(globalconf.connection, strut_q, NULL);

    if(strut_r
       && strut_r->value_len
       && (data = xcb_get_property_value(strut_r)))
    {
        uint32_t *strut = data;

        if(c->strut.left != strut[0]
           || c->strut.right != strut[1]
           || c->strut.top != strut[2]
           || c->strut.bottom != strut[3]
           || c->strut.left_start_y != strut[4]
           || c->strut.left_end_y != strut[5]
           || c->strut.right_start_y != strut[6]
           || c->strut.right_end_y != strut[7]
           || c->strut.top_start_x != strut[8]
           || c->strut.top_end_x != strut[9]
           || c->strut.bottom_start_x != strut[10]
           || c->strut.bottom_end_x != strut[11])
        {
            c->strut.left = strut[0];
            c->strut.right = strut[1];
            c->strut.top = strut[2];
            c->strut.bottom = strut[3];
            c->strut.left_start_y = strut[4];
            c->strut.left_end_y = strut[5];
            c->strut.right_start_y = strut[6];
            c->strut.right_end_y = strut[7];
            c->strut.top_start_x = strut[8];
            c->strut.top_end_x = strut[9];
            c->strut.bottom_start_x = strut[10];
            c->strut.bottom_end_x = strut[11];

            lua_State *L = globalconf_get_lua_State();
            luaA_object_push(L, c);
            luaA_object_emit_signal(L, -1, "property::struts", 0);
            lua_pop(L, 1);
        }
    }

    free(strut_r);
}

void
ewmh_init_lua(void)
{
    lua_State *L = globalconf_get_lua_State();

    luaA_class_connect_signal(L, &client_class, "focus", ewmh_update_net_active_window);
    luaA_class_connect_signal(L, &client_class, "unfocus", ewmh_update_net_active_window);
    luaA_class_connect_signal(L, &client_class, "request::manage", ewmh_update_net_client_list);
    luaA_class_connect_signal(L, &client_class, "request::unmanage", ewmh_update_net_client_list);
    luaA_class_connect_signal(L, &client_class, "property::modal" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::fullscreen" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::maximized_horizontal" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::maximized_vertical" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::maximized" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::sticky" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::skip_taskbar" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::above" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::below" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::minimized" , ewmh_client_update_hints);
    luaA_class_connect_signal(L, &client_class, "property::urgent" , ewmh_client_update_hints);
    /* NET_CURRENT_DESKTOP handling */
    luaA_class_connect_signal(L, &client_class, "focus", ewmh_update_net_current_desktop);
    luaA_class_connect_signal(L, &client_class, "unfocus", ewmh_update_net_current_desktop);
    luaA_class_connect_signal(L, &client_class, "tagged", ewmh_update_net_current_desktop);
    luaA_class_connect_signal(L, &client_class, "untagged", ewmh_update_net_current_desktop);
    luaA_class_connect_signal(L, &tag_class, "property::selected", ewmh_update_net_current_desktop);
}

#else  /* !XWAYLAND */

/* Pure Wayland stubs - EWMH not needed without XWayland */

void ewmh_init(void *conn, int screen_nbr)
{
    (void)conn; (void)screen_nbr;
}

void ewmh_client_check_hints(client_t *c)
{
    (void)c;
}

int ewmh_process_client_message(void *ev)
{
    (void)ev;
    return 0;
}

void ewmh_update_net_client_list_stacking(void)
{
    /* No-op */
}

void ewmh_update_net_numbers_of_desktop(void)
{
    /* No-op */
}

void ewmh_update_net_desktop_names(void)
{
    /* No-op */
}

void ewmh_update_net_desktop_geometry(void *conn, int phys_screen)
{
    (void)conn; (void)phys_screen;
}

void ewmh_client_update_desktop(client_t *c)
{
    (void)c;
}

void ewmh_update_strut(void *window, strut_t *strut)
{
    (void)window; (void)strut;
}

void ewmh_update_window_type(void *window, uint32_t type)
{
    (void)window; (void)type;
}

void ewmh_process_client_strut(client_t *c)
{
    (void)c;
}

void ewmh_init_lua(void)
{
    /* No-op */
}

#endif  /* XWAYLAND */

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
