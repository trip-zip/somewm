/*
 * loop.h - Main loop machinery: GLib integration and the refresh cycle
 */
#ifndef LOOP_H
#define LOOP_H

/* Same typedef glib's gtypes.h uses. Declared rather than included: the
 * prototypes below need the name, and every consumer of this header would
 * otherwise parse all of glib for it. */
typedef struct _GSource GSource;

struct wl_event_loop;

/* Create the GSource that runs the refresh cycle in GLib's prepare phase. */
GSource *create_refresh_source(void);

/* Create the GSource that dispatches Wayland events. */
GSource *create_wayland_source(struct wl_event_loop *loop);

/* Install the custom poll function on the default GLib context. */
void some_loop_install_poll_func(void);

#endif /* LOOP_H */
