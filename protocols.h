/*
 * protocols.h - Protocol handlers for somewm compositor
 *
 * Layer shell, idle inhibit, session lock, foreign toplevel,
 * and XDG activation token management.
 */
#ifndef PROTOCOLS_H
#define PROTOCOLS_H

#include "somewm_types.h"

typedef struct lua_State lua_State;
struct wl_listener;
struct wl_list;
struct wlr_box;
struct wlr_surface;

/* Layer shell */
void arrangelayer(Monitor *m, struct wl_list *list,
		struct wlr_box *usable_area, int exclusive);
void arrangelayers(Monitor *m);
void commitlayersurfacenotify(struct wl_listener *listener, void *data);
void createlayersurface(struct wl_listener *listener, void *data);
void destroylayersurfacenotify(struct wl_listener *listener, void *data);
void unmaplayersurfacenotify(struct wl_listener *listener, void *data);

/* Idle inhibit */
bool some_is_idle_inhibited(void);
int some_idle_inhibitor_count(void);
int some_push_idle_inhibitors(lua_State *L);
void createidleinhibitor(struct wl_listener *listener, void *data);

/* Session lock */
void locksession(struct wl_listener *listener, void *data);
void unlocksession(struct wl_listener *listener, void *data);
void createlocksurface(struct wl_listener *listener, void *data);
void destroylocksurface(struct wl_listener *listener, void *data);

/* Foreign toplevel */
void foreign_toplevel_request_activate(struct wl_listener *listener, void *data);
void foreign_toplevel_request_close(struct wl_listener *listener, void *data);
void foreign_toplevel_request_fullscreen(struct wl_listener *listener, void *data);
void foreign_toplevel_request_maximize(struct wl_listener *listener, void *data);
void foreign_toplevel_request_minimize(struct wl_listener *listener, void *data);

/* Activation tokens */
char *activation_token_create(const char *app_id);
void activation_token_cleanup(const char *token);
void activation_tokens_cancel_all(void);
void urgent(struct wl_listener *listener, void *data);

#endif /* PROTOCOLS_H */
