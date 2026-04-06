#ifndef SOMEWM_ANIMATION_H
#define SOMEWM_ANIMATION_H

#include <lua.h>
#include <wayland-server-core.h>

/** Single animation instance */
typedef struct animation_t {
    struct wl_list link;     /* globalconf.animations list */
    double duration;         /* Total duration in seconds */
    double elapsed;          /* Elapsed time in seconds */
    double start_time;       /* Monotonic time when animation was created */
    int easing;              /* Easing function enum */
    int tick_ref;            /* Lua registry ref for tick callback */
    int done_ref;            /* Lua registry ref for done callback */
    int handle_ref;          /* Lua registry ref for the handle userdata */
    bool cancelled;          /* Set by handle:cancel() */
} animation_t;

/** Easing function types */
enum animation_easing {
    EASING_LINEAR,
    EASING_EASE_OUT_CUBIC,
    EASING_EASE_IN_OUT_CUBIC,
};

/** Initialize the animation subsystem (call once at startup) */
void animation_init(struct wl_event_loop *loop);

/** Tick all active animations. Called from some_refresh(). */
void animation_tick_all(void);

/** Clean up all animations (call at shutdown) */
void animation_cleanup(void);

/** Register awesome.start_animation in Lua */
void animation_setup(lua_State *L);

/** Lua binding: awesome.start_animation(duration, easing, tick_fn, done_fn) */
int luaA_start_animation(lua_State *L);

#endif /* SOMEWM_ANIMATION_H */
