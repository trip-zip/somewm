/*
 * ewmh.h - EWMH (Extended Window Manager Hints) support
 *
 * Complete implementation for somewm (Wayland compositor with XWayland)
 * Based exactly on AwesomeWM's ewmh.h
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

#ifndef SOMEWM_EWMH_H
#define SOMEWM_EWMH_H

#include "objects/client.h"
#include <lua.h>

#ifdef XWAYLAND
#include <xcb/xcb.h>

/* ========== EWMH PUBLIC API (13 functions) ========== */

/** Initialize EWMH support on XWayland startup.
 * Creates the _NET_SUPPORTING_WM_CHECK window and advertises EWMH capabilities.
 * Matches AwesomeWM's ewmh_init() exactly.
 *
 * \param conn XCB connection to X server
 * \param screen_nbr Physical screen number (usually 0)
 */
void ewmh_init(xcb_connection_t *conn, int screen_nbr);

/** Update _NET_ACTIVE_WINDOW property with currently focused client.
 * Matches AwesomeWM's ewmh_update_net_active_window() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_active_window(xcb_connection_t *conn);

/** Read EWMH properties from newly created XWayland client.
 * Matches AwesomeWM's ewmh_client_check_hints() exactly.
 *
 * \param c The client to check
 */
void ewmh_client_check_hints(client_t *c);

/** Sync client state changes TO _NET_WM_STATE property (somewm → X11).
 * Matches AwesomeWM's ewmh_client_update_hints() exactly.
 *
 * \param L Lua state (for signal emission)
 * \param idx Stack index of client object
 * \param c The client to update
 */
void ewmh_client_update_hints(lua_State *L, int idx, client_t *c);

/** Handle X11 ClientMessage events (state change requests FROM clients).
 * Matches AwesomeWM's ewmh_process_client_message() exactly.
 *
 * \param ev The X11 client message event
 * \return 1 if handled, 0 if not
 */
int ewmh_process_client_message(xcb_client_message_event_t *ev);

/** Update _NET_CLIENT_LIST with all managed X11 windows.
 * Matches AwesomeWM's ewmh_update_net_client_list() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_client_list(xcb_connection_t *conn);

/** Update _NET_CLIENT_LIST_STACKING with stacking order.
 * Matches AwesomeWM's ewmh_update_net_client_list_stacking() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_client_list_stacking(xcb_connection_t *conn);

/** Update _NET_NUMBER_OF_DESKTOPS with tag count.
 * Matches AwesomeWM's ewmh_update_net_numbers_of_desktop() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_numbers_of_desktop(xcb_connection_t *conn);

/** Update _NET_CURRENT_DESKTOP with selected tag index.
 * Matches AwesomeWM's ewmh_update_net_current_desktop() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_current_desktop(xcb_connection_t *conn);

/** Update _NET_DESKTOP_NAMES with tag names.
 * Matches AwesomeWM's ewmh_update_net_desktop_names() exactly.
 *
 * \param conn XCB connection to X server
 */
void ewmh_update_net_desktop_names(xcb_connection_t *conn);

/** Update _NET_DESKTOP_GEOMETRY with screen size.
 * Matches AwesomeWM's ewmh_update_net_desktop_geometry() exactly.
 *
 * \param conn XCB connection to X server
 * \param phys_screen Physical screen number (unused in Wayland)
 */
void ewmh_update_net_desktop_geometry(xcb_connection_t *conn, int phys_screen);

/** Update _NET_WM_DESKTOP property on client window.
 * Matches AwesomeWM's ewmh_client_update_desktop() exactly.
 *
 * \param c The client to update
 */
void ewmh_client_update_desktop(client_t *c);

/** Initialize Lua signal connections for EWMH property updates.
 * Matches AwesomeWM's ewmh_init_lua() pattern.
 *
 * Note: This requires Lua signal infrastructure to be fully implemented.
 */
void ewmh_init_lua(void);

#else  /* !XWAYLAND */

/* Pure Wayland stubs - EWMH not needed without XWayland */

void ewmh_init(void *conn, int screen_nbr);
void ewmh_update_net_active_window(void *conn);
void ewmh_client_check_hints(client_t *c);
void ewmh_client_update_hints(lua_State *L, int idx, client_t *c);
int ewmh_process_client_message(void *ev);
void ewmh_update_net_client_list(void *conn);
void ewmh_update_net_client_list_stacking(void *conn);
void ewmh_update_net_numbers_of_desktop(void *conn);
void ewmh_update_net_current_desktop(void *conn);
void ewmh_update_net_desktop_names(void *conn);
void ewmh_update_net_desktop_geometry(void *conn, int phys_screen);
void ewmh_client_update_desktop(client_t *c);
void ewmh_init_lua(void);

#endif  /* XWAYLAND */

#endif /* SOMEWM_EWMH_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
