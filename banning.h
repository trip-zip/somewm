/*
 * banning.h - client banning/visibility management
 *
 * Stub implementation for somewm (Wayland compositor)
 * Based on AwesomeWM's banning.h
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

#ifndef SOMEWM_BANNING_H
#define SOMEWM_BANNING_H

/** Mark that client visibility needs to be refreshed.
 *
 * In AwesomeWM (X11), "banning" refers to hiding windows by unmapping them
 * or moving them offscreen. In Wayland, we use wlroots scene graph visibility.
 *
 * TODO: Implement proper client visibility management:
 * - Check if client should be visible based on tags
 * - Update wlr_scene_node enabled state
 * - Handle layer/stacking order changes
 */
void banning_need_update(void);

/** Refresh client visibility for all clients.
 *
 * This is called when globalconf.need_lazy_banning is true.
 *
 * TODO: Iterate all clients, check tag visibility, update scene graph.
 */
void banning_refresh(void);

#endif /* SOMEWM_BANNING_H */
/* vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80 */
