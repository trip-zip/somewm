/*
 * xwayland.h - XWayland X11 compatibility layer
 *
 * Handles X11 client lifecycle, configuration, activation, and EWMH
 * initialization for XWayland surfaces.
 */
#ifndef XWAYLAND_H
#define XWAYLAND_H

#ifdef XWAYLAND

struct wl_listener;

void xwayland_setup(void);
void xwayland_cleanup(void);

/* XWayland listener callbacks (used by client_reregister_listeners) */
void activatex11(struct wl_listener *listener, void *data);
void associatex11(struct wl_listener *listener, void *data);
void configurex11(struct wl_listener *listener, void *data);
void createnotifyx11(struct wl_listener *listener, void *data);
void dissociatex11(struct wl_listener *listener, void *data);
void sethints(struct wl_listener *listener, void *data);

#else

static inline void xwayland_setup(void) {}
static inline void xwayland_cleanup(void) {}

#endif /* XWAYLAND */

#endif /* XWAYLAND_H */
