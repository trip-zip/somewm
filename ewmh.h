/*
 * ewmh.h - EWMH support functions
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

#ifndef SOMEWM_EWMH_H
#define SOMEWM_EWMH_H

#include "objects/client.h"
#include "strut.h"

#ifdef XWAYLAND
#include <xcb/xcb.h>

void ewmh_init(xcb_connection_t *conn, int screen_nbr);
void ewmh_init_lua(void);
void ewmh_update_net_numbers_of_desktop(void);
void ewmh_update_net_desktop_names(void);
void ewmh_update_net_client_list_stacking(void);
void ewmh_client_check_hints(client_t *);
void ewmh_client_update_desktop(client_t *);
void ewmh_update_strut(xcb_window_t, strut_t *);
void ewmh_process_client_strut(client_t *);
int ewmh_process_client_message(xcb_client_message_event_t *);
void ewmh_update_window_type(xcb_window_t window, uint32_t type);

/* somewm-specific - not in AwesomeWM */
void ewmh_update_net_desktop_geometry(xcb_connection_t *conn, int phys_screen);

#else  /* !XWAYLAND */

/* Pure Wayland stubs - EWMH not needed without XWayland */

void ewmh_init(void *conn, int screen_nbr);
void ewmh_init_lua(void);
void ewmh_update_net_numbers_of_desktop(void);
void ewmh_update_net_desktop_names(void);
void ewmh_update_net_client_list_stacking(void);
void ewmh_client_check_hints(client_t *c);
void ewmh_client_update_desktop(client_t *c);
void ewmh_update_strut(void *window, strut_t *strut);
void ewmh_process_client_strut(client_t *c);
int ewmh_process_client_message(void *ev);
void ewmh_update_window_type(void *window, uint32_t type);
void ewmh_update_net_desktop_geometry(void *conn, int phys_screen);

#endif  /* XWAYLAND */

#endif /* SOMEWM_EWMH_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
