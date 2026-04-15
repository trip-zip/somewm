/*
 * window.h - Window lifecycle, geometry, and scene graph management
 *
 * XDG shell handlers, geometry application, layout arrangement,
 * appearance helpers, and client commands.
 */
#ifndef WINDOW_H
#define WINDOW_H

#include "somewm_types.h"

struct wl_listener;
struct wlr_box;

/* XDG shell / window lifecycle */
void createnotify(struct wl_listener *listener, void *data);
void initialcommitnotify(struct wl_listener *listener, void *data);
void commitnotify(struct wl_listener *listener, void *data);
void mapnotify(struct wl_listener *listener, void *data);
void unmapnotify(struct wl_listener *listener, void *data);
void destroynotify(struct wl_listener *listener, void *data);
void updatetitle(struct wl_listener *listener, void *data);
void maximizenotify(struct wl_listener *listener, void *data);
void fullscreennotify(struct wl_listener *listener, void *data);

/* Geometry */
void apply_geometry_to_wlroots(Client *c);
void resize(Client *c, struct wlr_box geo, int interact);
void applybounds(Client *c, struct wlr_box *bbox);

/* Layout */
void arrange(Monitor *m);

/* Appearance */
unsigned int get_border_width(void);
const float *get_focuscolor(void);
const float *get_bordercolor(void);
const float *get_urgentcolor(void);

/* Client commands */
void setmon(Client *c, Monitor *m, uint32_t newtags);
void setfullscreen(Client *c, int fullscreen);
void killclient(const Arg *arg);
void swapstack(const Arg *arg);
void zoom(const Arg *arg);
void togglefloating(const Arg *arg);
void tagmon(const Arg *arg);

/* Listener management (hot-reload) */
void client_remove_all_listeners(client_t *c);
void client_reregister_listeners(client_t *c);

/* Listener structs */
extern struct wl_listener new_xdg_toplevel;
extern struct wl_listener new_xdg_popup;
extern struct wl_listener new_xdg_decoration;

inline struct wlr_scene_tree *
client_surface_get_scene_tree(struct wlr_surface *surface)
{
	return surface ? surface->data : NULL;
}

inline void
client_surface_clear_scene_data(struct wlr_surface *surface, struct wlr_scene_tree *st)
{
	if (surface && surface->data == st)
		surface->data = NULL;
}

void client_scene_node_destroy(Client* c);

#endif /* WINDOW_H */
