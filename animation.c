#include "animation.h"
#include "globalconf.h"
#include "luaa.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Animation list and keep-alive timer */
static struct wl_list animations;
static struct wl_event_source *keepalive_timer;

/* Monotonic clock for elapsed time */
static double
clock_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}


/* Easing functions */
static double
ease_linear(double t)
{
	return t;
}

static double
ease_out_cubic(double t)
{
	double inv = 1.0 - t;
	return 1.0 - inv * inv * inv;
}

static double
ease_in_out_cubic(double t)
{
	if (t < 0.5)
		return 4.0 * t * t * t;
	double inv = -2.0 * t + 2.0;
	return 1.0 - inv * inv * inv / 2.0;
}

static double
apply_easing(int easing, double t)
{
	switch (easing) {
	case EASING_LINEAR:         return ease_linear(t);
	case EASING_EASE_OUT_CUBIC: return ease_out_cubic(t);
	case EASING_EASE_IN_OUT_CUBIC: return ease_in_out_cubic(t);
	default:                    return t;
	}
}

static int
parse_easing(const char *str)
{
	if (!str || strcmp(str, "linear") == 0)
		return EASING_LINEAR;
	if (strcmp(str, "ease-out-cubic") == 0)
		return EASING_EASE_OUT_CUBIC;
	if (strcmp(str, "ease-in-out-cubic") == 0)
		return EASING_EASE_IN_OUT_CUBIC;
	return EASING_LINEAR;
}

/* Keep-alive timer callback - just wakes the event loop */
static int
keepalive_callback(void *data)
{
	(void)data;
	/* Re-arm if animations still active */
	if (!wl_list_empty(&animations))
		wl_event_source_timer_update(keepalive_timer, 1);
	return 0;
}

static void
arm_keepalive(void)
{
	if (keepalive_timer && !wl_list_empty(&animations))
		wl_event_source_timer_update(keepalive_timer, 1);
}

static void
disarm_keepalive(void)
{
	if (keepalive_timer && wl_list_empty(&animations))
		wl_event_source_timer_update(keepalive_timer, 0);
}

/* Nil out the handle userdata so the Lua handle becomes inert */
static void
animation_nil_handle(lua_State *L, animation_t *anim)
{
	if (anim->handle_ref != LUA_REFNIL) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, anim->handle_ref);
		animation_t **ud = lua_touserdata(L, -1);
		if (ud) *ud = NULL;
		lua_pop(L, 1);
	}
}

/* Free an animation and its Lua refs */
static void
animation_destroy(animation_t *anim)
{
	lua_State *L = globalconf_get_lua_State();
	wl_list_remove(&anim->link);
	if (anim->tick_ref != LUA_REFNIL)
		luaL_unref(L, LUA_REGISTRYINDEX, anim->tick_ref);
	if (anim->done_ref != LUA_REFNIL)
		luaL_unref(L, LUA_REGISTRYINDEX, anim->done_ref);
	if (anim->handle_ref != LUA_REFNIL)
		luaL_unref(L, LUA_REGISTRYINDEX, anim->handle_ref);
	free(anim);
}

/* Animation handle metatable name */
#define ANIM_HANDLE_MT "somewm.animation_handle"

/** handle:cancel() */
static int
luaA_animation_handle_cancel(lua_State *L)
{
	animation_t **ud = luaL_checkudata(L, 1, ANIM_HANDLE_MT);
	if (*ud)
		(*ud)->cancelled = true;
	return 0;
}

/** handle:is_active() */
static int
luaA_animation_handle_is_active(lua_State *L)
{
	animation_t **ud = luaL_checkudata(L, 1, ANIM_HANDLE_MT);
	lua_pushboolean(L, *ud && !(*ud)->cancelled);
	return 1;
}

static const struct luaL_Reg animation_handle_methods[] = {
	{ "cancel", luaA_animation_handle_cancel },
	{ "is_active", luaA_animation_handle_is_active },
	{ NULL, NULL }
};

/** awesome.start_animation(duration, easing, tick_fn, done_fn)
 * Returns a handle with :cancel() method.
 */
int
luaA_start_animation(lua_State *L)
{
	double duration = luaL_checknumber(L, 1);
	const char *easing_str = luaL_checkstring(L, 2);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	/* done_fn is optional */
	bool has_done = lua_gettop(L) >= 4 && lua_isfunction(L, 4);

	if (duration <= 0)
		return luaL_error(L, "animation duration must be positive");

	animation_t *anim = calloc(1, sizeof(*anim));
	if (!anim)
		return luaL_error(L, "out of memory");

	anim->duration = duration;
	anim->elapsed = 0;
	anim->start_time = clock_now();
	anim->easing = parse_easing(easing_str);
	anim->cancelled = false;

	/* Store tick callback */
	lua_pushvalue(L, 3);
	anim->tick_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Store done callback */
	if (has_done) {
		lua_pushvalue(L, 4);
		anim->done_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	} else {
		anim->done_ref = LUA_REFNIL;
	}

	/* Create handle userdata */
	animation_t **ud = lua_newuserdata(L, sizeof(animation_t *));
	*ud = anim;
	luaL_getmetatable(L, ANIM_HANDLE_MT);
	lua_setmetatable(L, -2);

	/* Store handle ref so we can nil it when animation finishes */
	lua_pushvalue(L, -1);
	anim->handle_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Add to list */
	wl_list_insert(&animations, &anim->link);
	arm_keepalive();

	/* Return the handle (already on stack) */
	return 1;
}

void
animation_init(struct wl_event_loop *loop)
{
	wl_list_init(&animations);
	keepalive_timer = wl_event_loop_add_timer(loop, keepalive_callback, NULL);
}

void
animation_tick_all(void)
{
	if (wl_list_empty(&animations))
		return;

	double now = clock_now();
	lua_State *L = globalconf_get_lua_State();

	animation_t *anim, *tmp;
	wl_list_for_each_safe(anim, tmp, &animations, link) {
		if (anim->cancelled) {
			animation_nil_handle(L, anim);
			animation_destroy(anim);
			continue;
		}

		/* Compute elapsed from absolute start time — avoids stale dt accumulation */
		anim->elapsed = now - anim->start_time;
		double progress = anim->elapsed / anim->duration;
		bool finished = progress >= 1.0;
		if (finished) progress = 1.0;

		double eased = apply_easing(anim->easing, progress);

		/* Call tick(eased_progress) */
		lua_rawgeti(L, LUA_REGISTRYINDEX, anim->tick_ref);
		lua_pushnumber(L, eased);
		if (lua_pcall(L, 1, 0, 0) != 0) {
			fprintf(stderr, "animation tick error: %s\n", lua_tostring(L, -1));
			lua_pop(L, 1);
			finished = true;
		}

		if (finished) {
			/* Call done() if provided */
			if (anim->done_ref != LUA_REFNIL) {
				lua_rawgeti(L, LUA_REGISTRYINDEX, anim->done_ref);
				if (lua_pcall(L, 0, 0, 0) != 0) {
					fprintf(stderr, "animation done error: %s\n",
						lua_tostring(L, -1));
					lua_pop(L, 1);
				}
			}

			animation_nil_handle(L, anim);
			animation_destroy(anim);
		}
	}

	if (wl_list_empty(&animations))
		disarm_keepalive();
}

void
animation_cleanup(void)
{
	animation_t *anim, *tmp;
	wl_list_for_each_safe(anim, tmp, &animations, link) {
		animation_destroy(anim);
	}
	if (keepalive_timer) {
		wl_event_source_remove(keepalive_timer);
		keepalive_timer = NULL;
	}
}

void
animation_setup(lua_State *L)
{
	/* Create the animation handle metatable */
	luaL_newmetatable(L, ANIM_HANDLE_MT);
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");
	luaA_setfuncs(L, animation_handle_methods);
	lua_pop(L, 1);
}
