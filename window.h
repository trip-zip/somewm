/*
 * window.h - Window lifecycle, geometry, and surface management
 *
 * XDG shell handlers, geometry application, layout arrangement,
 * appearance helpers, and client commands.
 */
#ifndef WINDOW_H
#define WINDOW_H

#include "somewm_types.h"

struct wl_display;
struct wl_listener;
struct wlr_box;

/* Schedule wl_display_flush_clients() to run on the next event-loop idle.
 * Use this whenever a flush is needed from inside a Wayland signal emit
 * (e.g. surface->events.map handlers, or any code path that may execute
 * during signal dispatch). A synchronous flush in that context can call
 * wl_client_destroy() on a hung-up peer and tear down a resource whose
 * signal is still being emitted, which trips a wlroots assertion. */
void schedule_flush_clients(struct wl_display *display);

/* XDG shell / window lifecycle */
void createnotify(struct wl_listener *listener, void *data);
void initialcommitnotify(struct wl_listener *listener, void *data);
void commitnotify(struct wl_listener *listener, void *data);
void mapnotify(struct wl_listener *listener, void *data);
void unmapnotify(struct wl_listener *listener, void *data);
void destroynotify(struct wl_listener *listener, void *data);
void updatetitle(struct wl_listener *listener, void *data);
void maximizenotify(struct wl_listener *listener, void *data);
void minimizenotify(struct wl_listener *listener, void *data);
void fullscreennotify(struct wl_listener *listener, void *data);

/* Geometry */
/* The client-facing half of geometry application: surface inset,
 * titlebars, the configure send, and the surface clip. render_client_hooks
 * and forced configure re-sends call it directly. */
void client_configure_to_box(Client *c);
bool client_clamps_to_monitor(Client *c);
void window_setup_render_hooks(void);

void resize(Client *c, struct wlr_box geo, int interact);
void applybounds(Client *c, struct wlr_box *bbox);

/* Layout */
void arrange(Monitor *m);

/* Appearance */
const float *get_focuscolor(void);
const float *get_bordercolor(void);

/* Client commands */
Monitor *monitor_for_unmanaged(Client *c);
void client_node_attach(Client *c, Monitor *m);
void setmon(Client *c, Monitor *m, uint32_t newtags);
void setfullscreen(Client *c, int fullscreen);

/* Listener management (hot-reload) */
void client_remove_all_listeners(client_t *c);
void client_reregister_listeners(client_t *c);

/* Listener structs */
extern struct wl_listener new_xdg_toplevel;
extern struct wl_listener new_xdg_popup;
extern struct wl_listener new_xdg_decoration;

void client_node_destroy(Client *c);

/* An xdg popup declared as a floating element attached to its parent's surface. */
typedef struct Popup {
	struct node *node;
	struct wlr_xdg_popup *popup;
	void *render_owner;
	struct wl_list link;           /* in popups, creation order */
	struct wl_listener commit;
	struct wl_listener reposition;
	struct wl_listener destroy;
} Popup;
/* Every live popup, parents before their nested popups. */
extern struct wl_list popups;

void window_track_surfaces(void);
void window_surface_sweep(Monitor *, bool remove_all);
void window_surface_frame_done(Monitor *, const struct timespec *);
bool window_surface_visible(struct wlr_surface *);

#endif /* WINDOW_H */
