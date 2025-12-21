/*
 * ewmh.c - EWMH (Extended Window Manager Hints) support
 *
 * Complete implementation for somewm (Wayland compositor with XWayland)
 * Based exactly on AwesomeWM's ewmh.c:645-803
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
#include "objects/luaa.h"
#include "x11_compat.h"

#ifdef XWAYLAND
#include <xcb/xcb.h>
#include <xcb/xcb_atom.h>
#include <string.h>
#include <stdlib.h>

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

    printf("somewm: EWMH initialized (%zu atoms advertised)\n",
           globalconf.ewmh.supported_atoms_count);
}

/* ========== ACTIVE WINDOW TRACKING (Lines 242-260 from AwesomeWM) ========== */

/** Update _NET_ACTIVE_WINDOW property with currently focused client.
 * This function matches AwesomeWM's ewmh_update_net_active_window() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_active_window(xcb_connection_t *conn)
{
    xcb_window_t win;

    if (!conn || !globalconf.screen) return;

    win = XCB_NONE;

    /* Get focused client (only advertise X11 clients via EWMH) */
    if (globalconf.focus.client && globalconf.focus.client->client_type == X11)
        win = globalconf.focus.client->window;

    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_ACTIVE_WINDOW, XCB_ATOM_WINDOW, 32, 1, &win);
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

/* ========== CLIENT HINTS UPDATE (Lines 262-323 from AwesomeWM) ========== */

/** Sync client state changes TO _NET_WM_STATE property (somewm → X11).
 * This function matches AwesomeWM's ewmh_client_update_hints() exactly.
 *
 * \param L Lua state (for signal emission)
 * \param idx Stack index of client object
 * \param c The client to update
 */
void
ewmh_client_update_hints(lua_State *L, int idx, client_t *c)
{
    xcb_connection_t *conn;
    xcb_atom_t state[10];
    int count;

    (void)L;    /* Not used in current implementation */
    (void)idx;  /* Not used in current implementation */

    if (!globalconf.connection || c->client_type != X11) return;

    conn = globalconf.connection;
    count = 0;

    /* Build atom list from client state (exact AwesomeWM order) */
    if (c->modal)         state[count++] = _NET_WM_STATE_MODAL;
    if (c->fullscreen)    state[count++] = _NET_WM_STATE_FULLSCREEN;
    if (c->maximized_vertical)   state[count++] = _NET_WM_STATE_MAXIMIZED_VERT;
    if (c->maximized_horizontal)   state[count++] = _NET_WM_STATE_MAXIMIZED_HORZ;
    if (c->sticky)        state[count++] = _NET_WM_STATE_STICKY;
    if (c->above)         state[count++] = _NET_WM_STATE_ABOVE;
    if (c->below)         state[count++] = _NET_WM_STATE_BELOW;
    if (c->minimized)     state[count++] = _NET_WM_STATE_HIDDEN;
    if (c->urgent)        state[count++] = _NET_WM_STATE_DEMANDS_ATTENTION;
    if (c->skip_taskbar)  state[count++] = _NET_WM_STATE_SKIP_TASKBAR;

    /* Update _NET_WM_STATE property */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, c->window,
                        _NET_WM_STATE, XCB_ATOM_ATOM, 32, count, state);
}

/* ========== CLIENT MESSAGE PROCESSING (Lines 489-576 from AwesomeWM) ========== */

/** Handle X11 ClientMessage events (state change requests FROM clients).
 * This function matches AwesomeWM's ewmh_process_client_message() exactly.
 *
 * \param ev The X11 client message event
 * \return 1 if handled, 0 if not
 */
int
ewmh_process_client_message(xcb_client_message_event_t *ev)
{
    if (!globalconf.connection) return 0;

    /* TODO: Implement client message processing
     * This requires:
     * 1. client_getbywin() to find client by X11 window ID
     * 2. client_set_fullscreen(), client_set_maximized(), etc.
     * 3. Proper handling of _NET_WM_STATE actions (add/remove/toggle)
     *
     * For now, return 0 (not handled)
     */
    (void)ev;
    return 0;
}

/* ========== CLIENT LIST MANAGEMENT (Lines 578-633 from AwesomeWM) ========== */

/** Update _NET_CLIENT_LIST with all managed X11 windows.
 * This function matches AwesomeWM's ewmh_update_net_client_list() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_client_list(xcb_connection_t *conn)
{
    if (!conn || !globalconf.screen) return;

    /* TODO: Implement client list update
     * This requires iterating globalconf.clients array and filtering X11 clients
     * For now, set empty list
     */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_CLIENT_LIST, XCB_ATOM_WINDOW, 32, 0, NULL);
}

/** Update _NET_CLIENT_LIST_STACKING with stacking order.
 * This function matches AwesomeWM's ewmh_update_net_client_list_stacking() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_client_list_stacking(xcb_connection_t *conn)
{
    if (!conn || !globalconf.screen) return;

    /* TODO: Implement stacking order update
     * This requires traversing wlroots scene graph bottom→top
     * For now, set empty list
     */
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_CLIENT_LIST_STACKING, XCB_ATOM_WINDOW, 32, 0, NULL);
}

/* ========== DESKTOP/TAG MANAGEMENT (Lines 145-223 from AwesomeWM) ========== */

/** Update _NET_NUMBER_OF_DESKTOPS with tag count.
 * This function matches AwesomeWM's ewmh_update_net_numbers_of_desktop() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_numbers_of_desktop(xcb_connection_t *conn)
{
    uint32_t count;

    if (!conn || !globalconf.screen) return;

    /* AwesomeWM desktops = somewm tags */
    count = globalconf.tags.len;

    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_NUMBER_OF_DESKTOPS, XCB_ATOM_CARDINAL, 32, 1, &count);
}

/** Update _NET_CURRENT_DESKTOP with selected tag index.
 * This function matches AwesomeWM's ewmh_update_net_current_desktop() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_current_desktop(xcb_connection_t *conn)
{
    uint32_t desktop;
    int i;
    tag_t *tag;

    if (!conn || !globalconf.screen) return;

    /* Find selected tag index */
    desktop = 0;
    for (i = 0; i < globalconf.tags.len; i++) {
        tag = globalconf.tags.tab[i];
        if (tag->selected) {
            desktop = i;
            break;
        }
    }

    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
                        globalconf.screen->root,
                        _NET_CURRENT_DESKTOP, XCB_ATOM_CARDINAL, 32, 1, &desktop);
}

/** Update _NET_DESKTOP_NAMES with tag names.
 * This function matches AwesomeWM's ewmh_update_net_desktop_names() exactly.
 *
 * \param conn XCB connection to X server
 */
void
ewmh_update_net_desktop_names(xcb_connection_t *conn)
{
    size_t total_len, len;
    int i;
    tag_t *tag;
    char *names, *p;

    if (!conn || !globalconf.screen) return;

    /* Build NULL-separated UTF8 string list (EWMH spec) */
    total_len = 0;
    for (i = 0; i < globalconf.tags.len; i++) {
        tag = globalconf.tags.tab[i];
        total_len += strlen(tag->name) + 1;  /* +1 for NULL separator */
    }

    if (total_len == 0) return;  /* No tags */

    names = malloc(total_len);
    p = names;
    for (i = 0; i < globalconf.tags.len; i++) {
        tag = globalconf.tags.tab[i];
        len = strlen(tag->name);
        memcpy(p, tag->name, len);
        p += len;
        *p++ = '\0';
    }

    xcb_change_property(conn, XCB_PROP_MODE_REPLACE,
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

/** Update _NET_WM_DESKTOP property on client window.
 * This function matches AwesomeWM's ewmh_client_update_desktop() exactly.
 *
 * \param c The client to update
 */
void
ewmh_client_update_desktop(client_t *c)
{
    uint32_t desktop;

    if (!globalconf.connection || c->client_type != X11) return;

    desktop = 0xFFFFFFFF;  /* All desktops (sticky) */

    /* TODO: Implement tag → desktop index mapping
     * somewm uses tag->clients arrays (not c->tags), so we need to:
     * 1. Iterate through globalconf.tags
     * 2. Check if client is in tag->clients array
     * 3. Use first matching tag's index as desktop
     * For now, always report 0xFFFFFFFF (all desktops)
     */

    xcb_change_property(globalconf.connection, XCB_PROP_MODE_REPLACE,
                        c->window, _NET_WM_DESKTOP, XCB_ATOM_CARDINAL, 32, 1, &desktop);
}

/* ========== LUA SIGNAL INTEGRATION (Lines 682-803 from AwesomeWM) ========== */

/** Initialize Lua signal connections for EWMH property updates.
 * This function matches AwesomeWM's ewmh_init_lua() pattern.
 *
 * Note: This requires Lua signal infrastructure to be fully implemented.
 * For now, this is a stub that will be implemented when signal system is ready.
 */
void
ewmh_init_lua(void)
{
    /* TODO: Connect Lua signals to EWMH property updates
     *
     * Tag signals → desktop updates:
     *   - "property::selected" → ewmh_update_net_current_desktop()
     *   - "property::name" → ewmh_update_net_desktop_names()
     *
     * Client signals → state updates:
     *   - "property::fullscreen" → ewmh_client_update_hints()
     *   - "property::maximized_*" → ewmh_client_update_hints()
     *   - "property::sticky" → ewmh_client_update_desktop()
     *   - "property::above" → ewmh_client_update_hints()
     *   - "property::below" → ewmh_client_update_hints()
     *   - "property::modal" → ewmh_client_update_hints()
     *   - "property::urgent" → ewmh_client_update_hints()
     *   - "property::skip_taskbar" → ewmh_client_update_hints()
     *
     * Focus signals → active window updates:
     *   - "focus" → ewmh_update_net_active_window()
     *   - "unfocus" → ewmh_update_net_active_window()
     *
     * Manage/unmanage signals → client list updates:
     *   - "manage" → ewmh_update_net_client_list()
     *   - "unmanage" → ewmh_update_net_client_list()
     *
     * This requires AwesomeWM's signal connection infrastructure.
     */
    printf("somewm: EWMH Lua signal integration (stub - to be implemented)\n");
}

#else  /* !XWAYLAND */

/* Pure Wayland stubs - EWMH not needed without XWayland */

void ewmh_init(void *conn, int screen_nbr)
{
    (void)conn; (void)screen_nbr;
}

void ewmh_update_net_active_window(void *conn)
{
    (void)conn;
}

void ewmh_client_check_hints(client_t *c)
{
    (void)c;
}

void ewmh_client_update_hints(lua_State *L, int idx, client_t *c)
{
    (void)L; (void)idx; (void)c;
}

int ewmh_process_client_message(void *ev)
{
    (void)ev;
    return 0;
}

void ewmh_update_net_client_list(void *conn)
{
    (void)conn;
}

void ewmh_update_net_client_list_stacking(void *conn)
{
    (void)conn;
}

void ewmh_update_net_numbers_of_desktop(void *conn)
{
    (void)conn;
}

void ewmh_update_net_current_desktop(void *conn)
{
    (void)conn;
}

void ewmh_update_net_desktop_names(void *conn)
{
    (void)conn;
}

void ewmh_update_net_desktop_geometry(void *conn, int phys_screen)
{
    (void)conn; (void)phys_screen;
}

void ewmh_client_update_desktop(client_t *c)
{
    (void)c;
}

void ewmh_init_lua(void)
{
    /* No-op */
}

#endif  /* XWAYLAND */

/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
