/*
 * xwayland.h - XWayland X11 compatibility layer
 *
 * Handles X11 client lifecycle, configuration, activation, and EWMH
 * initialization for XWayland surfaces.
 */
#ifndef XWAYLAND_H
#define XWAYLAND_H

#include <stdint.h>
#include <lua.h>

struct wl_listener;
struct client_t;
struct wlr_box;

int luaA_client_get_x11_configure(lua_State *L, struct client_t *c);
void xwayland_geometry_authored(struct client_t *c);
void xwayland_publish_geometry(struct client_t *c, struct wlr_box frame,
        uint32_t request_serial);

void xwayland_setup(void);
void xwayland_cleanup(void);

/* XWayland listener callbacks (used by client_reregister_listeners) */
void activatex11(struct wl_listener *listener, void *data);
void associatex11(struct wl_listener *listener, void *data);
void configurex11(struct wl_listener *listener, void *data);
void createnotifyx11(struct wl_listener *listener, void *data);
void dissociatex11(struct wl_listener *listener, void *data);
void sethints(struct wl_listener *listener, void *data);

#endif /* XWAYLAND_H */
