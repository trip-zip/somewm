/*
 * wlr_compat.h - wlroots version compatibility layer
 *
 * Provides macros to support both wlroots 0.18 and 0.19 APIs.
 *
 * Key differences between 0.18 and 0.19:
 * - wlr_presentation_create: 0.18 takes 2 args, 0.19 takes 3 args
 * - backend->features.timeline: 0.19 only
 * - wlr_scene_set_gamma_control_manager_v1: 0.19 only
 * - wlr_xwayland_surface_set_maximized: 0.18 takes 1 bool, 0.19 takes 2 bools
 * - wlr_xwayland_surface_override_redirect_wants_focus: 0.19 only
 * - wlr_xwayland_icccm_input_model vs wlr_xwayland_surface_icccm_input_model
 *
 * Note: Both 0.18 and 0.19 use the same wlr_output_state_*() API.
 */

#ifndef WLR_COMPAT_H
#define WLR_COMPAT_H

#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/util/edges.h>

#ifdef WLR_VERSION_0_19

/* wlr_presentation_create gained a version parameter in 0.19 */
#define COMPAT_PRESENTATION_CREATE(dpy, backend) \
    wlr_presentation_create((dpy), (backend), 2)

/* Timeline sync is available in 0.19 */
#define COMPAT_HAS_TIMELINE_FEATURES 1

/* XWayland: set_maximized takes separate h/v bools in 0.19 */
#define COMPAT_XWAYLAND_SET_MAXIMIZED(surface, maximized) \
    wlr_xwayland_surface_set_maximized((surface), (maximized), (maximized))

/* XWayland: helper functions renamed in 0.19 */
#define COMPAT_XWAYLAND_OVERRIDE_REDIRECT_WANTS_FOCUS(surface) \
    wlr_xwayland_surface_override_redirect_wants_focus(surface)
#define COMPAT_XWAYLAND_ICCCM_INPUT_MODEL(surface) \
    wlr_xwayland_surface_icccm_input_model(surface)

/* XWayland: window type helper available in 0.19 */
#define COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, type) \
    wlr_xwayland_surface_has_window_type((surface), (type))

/* XDG surface geometry: 0.19 has convenience field directly on surface */
#define COMPAT_XDG_SURFACE_GEOMETRY(surface) ((surface)->geometry)

#else /* wlroots 0.18 */

/* wlr_presentation_create takes only display and backend in 0.18 */
#define COMPAT_PRESENTATION_CREATE(dpy, backend) \
    wlr_presentation_create((dpy), (backend))

/* Timeline features not available in 0.18 */
#define COMPAT_HAS_TIMELINE_FEATURES 0

/* XWayland: set_maximized takes single bool in 0.18 */
#define COMPAT_XWAYLAND_SET_MAXIMIZED(surface, maximized) \
    wlr_xwayland_surface_set_maximized((surface), (maximized))

/* XWayland: override_redirect_wants_focus doesn't exist in 0.18,
 * check the surface property directly */
#define COMPAT_XWAYLAND_OVERRIDE_REDIRECT_WANTS_FOCUS(surface) \
    ((surface)->override_redirect)
#define COMPAT_XWAYLAND_ICCCM_INPUT_MODEL(surface) \
    wlr_xwayland_icccm_input_model(surface)

/* XWayland: window type helper doesn't exist in 0.18.
 * For floating detection, we rely on modal and size hints instead. */
#define COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, type) (0)

/* XDG surface geometry: 0.19 has convenience field, 0.18 uses current.geometry */
#define COMPAT_XDG_SURFACE_GEOMETRY(surface) ((surface)->current.geometry)

#endif /* WLR_VERSION_0_19 */

#endif /* WLR_COMPAT_H */
