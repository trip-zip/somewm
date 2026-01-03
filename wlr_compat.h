/*
 * wlr_compat.h - wlroots version abstraction layer
 *
 * Provides macros to abstract wlroots API details. When wlroots 0.20
 * inevitably breaks APIs, only this file needs updating.
 *
 * Currently targets wlroots 0.19.
 */

#ifndef WLR_COMPAT_H
#define WLR_COMPAT_H

#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/util/edges.h>

/* wlr_presentation_create takes display, backend, and version */
#define COMPAT_PRESENTATION_CREATE(dpy, backend) \
    wlr_presentation_create((dpy), (backend), 2)

/* Timeline sync is available */
#define COMPAT_HAS_TIMELINE_FEATURES 1

/* XWayland: set_maximized takes separate h/v bools */
#define COMPAT_XWAYLAND_SET_MAXIMIZED(surface, maximized) \
    wlr_xwayland_surface_set_maximized((surface), (maximized), (maximized))

/* XWayland: helper functions */
#define COMPAT_XWAYLAND_OVERRIDE_REDIRECT_WANTS_FOCUS(surface) \
    wlr_xwayland_surface_override_redirect_wants_focus(surface)
#define COMPAT_XWAYLAND_ICCCM_INPUT_MODEL(surface) \
    wlr_xwayland_surface_icccm_input_model(surface)

/* XWayland: window type helper */
#define COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, type) \
    wlr_xwayland_surface_has_window_type((surface), (type))

/* XDG surface geometry */
#define COMPAT_XDG_SURFACE_GEOMETRY(surface) ((surface)->geometry)

#endif /* WLR_COMPAT_H */
