/*
 * event_queue.c - Batched event queue for deferred signal dispatch
 *
 * C code queues events during Wayland event handling. The drain function
 * dispatches them to Lua at the frame boundary (in some_refresh()).
 * This ensures the call stack never interleaves C and Lua.
 */
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#include "event_queue.h"
#include "globalconf.h"
#include "common/luaobject.h"
#include "common/luaclass.h"
#include "objects/signal.h"

/* Signal name lookup table - maps SIG_* enum to string */
static const char *signal_names[SIG_COUNT] = {
	[SIG_PROPERTY_GEOMETRY]  = "property::geometry",
	[SIG_PROPERTY_POSITION]  = "property::position",
	[SIG_PROPERTY_SIZE]      = "property::size",
	[SIG_PROPERTY_X]         = "property::x",
	[SIG_PROPERTY_Y]         = "property::y",
	[SIG_PROPERTY_WIDTH]     = "property::width",
	[SIG_PROPERTY_HEIGHT]    = "property::height",
	[SIG_PROPERTY_ACTIVE]    = "property::active",
	[SIG_FOCUS]              = "focus",
	[SIG_UNFOCUS]            = "unfocus",
	[SIG_CLIENT_FOCUS]       = "client::focus",
	[SIG_CLIENT_UNFOCUS]     = "client::unfocus",
	[SIG_MOUSE_ENTER]        = "mouse::enter",
	[SIG_MOUSE_LEAVE]        = "mouse::leave",
	[SIG_MOUSE_MOVE]         = "mouse::move",
	[SIG_LIST]               = "list",
	[SIG_SWAPPED]            = "swapped",
	[SIG_REQUEST_ACTIVATE]   = "request::activate",
	[SIG_REQUEST_URGENT]     = "request::urgent",
	[SIG_REQUEST_TAG]        = "request::tag",
	[SIG_REQUEST_SELECT]     = "request::select",
	[SIG_SYSTRAY_SECONDARY_ACTIVATE]  = "request::secondary_activate",
	[SIG_SYSTRAY_CONTEXT_MENU]        = "request::context_menu",
	[SIG_SYSTRAY_SCROLL]              = "request::scroll",
	[SIG_CLIENT_PROPERTY_GEOMETRY] = "client::property::geometry",
};

/* Queue storage - simple dynamic array */
#define QUEUE_INITIAL_CAP 64

static some_event_t *queue_buf = NULL;
static int queue_len = 0;
static int queue_cap = 0;

static void
queue_grow(void)
{
	int new_cap = queue_cap == 0 ? QUEUE_INITIAL_CAP : queue_cap * 2;
	some_event_t *new_buf = realloc(queue_buf, new_cap * sizeof(some_event_t));
	if (!new_buf) {
		fprintf(stderr, "[event_queue] fatal: allocation failed (%d events)\n",
		        new_cap);
		abort();
	}
	queue_buf = new_buf;
	queue_cap = new_cap;
}

static some_event_t *
queue_push(void)
{
	if (queue_len >= queue_cap)
		queue_grow();
	return &queue_buf[queue_len++];
}

void
some_event_queue_signal0(lua_State *L, int obj_ud, uint16_t signal_id)
{
	some_event_t *e = queue_push();
	e->event_type = EVENT_OBJECT;
	e->signal_id = signal_id;
	e->nargs = 0;
	e->args_ref = LUA_NOREF;
	e->class_ptr = NULL;

	/* Capture object reference */
	lua_pushvalue(L, obj_ud);
	e->object_ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

void
some_event_queue_signal(lua_State *L, int obj_ud, uint16_t signal_id,
                        int nargs)
{
	some_event_t *e = queue_push();
	e->event_type = EVENT_OBJECT;
	e->signal_id = signal_id;
	e->nargs = nargs;
	e->class_ptr = NULL;

	/* Capture object reference.
	 * The caller passes obj_ud relative to the current stack which
	 * already includes the nargs arguments on top. */
	lua_pushvalue(L, obj_ud);
	e->object_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	/* Capture arguments into a table */
	if (nargs > 0) {
		lua_createtable(L, nargs, 0);
		/* Arguments are at stack positions -(nargs+1) to -2
		 * (the table is at -1) */
		for (int i = 0; i < nargs; i++) {
			lua_pushvalue(L, -(nargs + 1) + i);
			lua_rawseti(L, -2, i + 1);
		}
		e->args_ref = luaL_ref(L, LUA_REGISTRYINDEX);
		/* Pop the original arguments from the caller's stack */
		lua_pop(L, nargs);
	} else {
		e->args_ref = LUA_NOREF;
	}
}

void
some_event_queue_global(uint16_t signal_id)
{
	some_event_t *e = queue_push();
	e->event_type = EVENT_GLOBAL;
	e->signal_id = signal_id;
	e->object_ref = LUA_NOREF;
	e->nargs = 0;
	e->args_ref = LUA_NOREF;
	e->class_ptr = NULL;
}

void
some_event_queue_class(struct lua_class_t *class_ptr, uint16_t signal_id)
{
	some_event_t *e = queue_push();
	e->event_type = EVENT_CLASS;
	e->signal_id = signal_id;
	e->object_ref = LUA_NOREF;
	e->class_ptr = class_ptr;
	e->nargs = 0;
	e->args_ref = LUA_NOREF;
}

void
some_event_queue_move(lua_State *L, int obj_ud, int local_x, int local_y)
{
	/* Coalesce mouse::move events for the same object.
	 *
	 * Invariant: between enter/leave brackets on a given object, every
	 * mouse::move on that object is folded into one event with the latest
	 * coordinates. motionnotify() always emits leave + enter when the
	 * hovered object changes, and the scan below stops at the first
	 * non-move event, so coalescing never crosses an enter/leave boundary
	 * and the chronological ordering of move/enter/leave is preserved.
	 *
	 * We compare object identity via lua_rawequal on the registry-cached
	 * userdata (AwesomeWM caches one userdata per C object). */

	/* First, get a ref to the object for comparison */
	lua_pushvalue(L, obj_ud);

	/* Scan backward (most recent events first) for a match */
	for (int i = queue_len - 1; i >= 0; i--) {
		some_event_t *existing = &queue_buf[i];

		/* Stop scanning if we hit a non-move event. This preserves
		 * the chronological ordering of any interleaved enter/leave
		 * events relative to the moves. */
		if (existing->signal_id != SIG_MOUSE_MOVE)
			break;

		/* Check if same object by comparing via registry */
		lua_rawgeti(L, LUA_REGISTRYINDEX, existing->object_ref);
		int same = lua_rawequal(L, -1, -2);
		lua_pop(L, 1);

		if (same) {
			/* Update the args in place */
			if (existing->args_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, existing->args_ref);

			lua_createtable(L, 2, 0);
			lua_pushinteger(L, local_x);
			lua_rawseti(L, -2, 1);
			lua_pushinteger(L, local_y);
			lua_rawseti(L, -2, 2);
			existing->args_ref = luaL_ref(L, LUA_REGISTRYINDEX);

			lua_pop(L, 1);  /* pop the comparison object */
			return;
		}
	}

	/* No existing event found - create new one */
	some_event_t *e = queue_push();
	e->event_type = EVENT_OBJECT;
	e->signal_id = SIG_MOUSE_MOVE;
	e->nargs = 2;
	e->class_ptr = NULL;
	e->object_ref = luaL_ref(L, LUA_REGISTRYINDEX);  /* consumes the pushed object */

	lua_createtable(L, 2, 0);
	lua_pushinteger(L, local_x);
	lua_rawseti(L, -2, 1);
	lua_pushinteger(L, local_y);
	lua_rawseti(L, -2, 2);
	e->args_ref = luaL_ref(L, LUA_REGISTRYINDEX);
}

void
some_event_queue_drain(lua_State *L)
{
	/* Process a snapshot of the queue length. Events added during drain
	 * (by signal handlers) will be processed on the next drain cycle,
	 * not in this one. This prevents infinite loops. */
	int count = queue_len;

	for (int i = 0; i < count; i++) {
		/* Copy the event by value. Dispatched Lua handlers can call
		 * back into C and queue more events; if that triggers
		 * queue_grow() -> realloc(), the queue_buf pointer moves and
		 * any pointer into it (including &queue_buf[i]) is freed. The
		 * local copy is independent of the buffer. */
		some_event_t e = queue_buf[i];

		if (e.signal_id >= SIG_COUNT)
			goto cleanup;

		const char *name = signal_names[e.signal_id];

		if (!name)
			goto cleanup;

		if (e.event_type == EVENT_GLOBAL) {
			luaA_emit_signal_global(name);
			goto cleanup;
		}

		if (e.event_type == EVENT_CLASS) {
			/* Class-level signal (e.g., client "list").
			 * some_event_queue_class() never captures args today, so
			 * there is nothing to unpack here. */
			luaA_class_emit_signal(L, e.class_ptr, name, 0);
			goto cleanup;
		}

		/* Push object from registry */
		if (e.object_ref == LUA_NOREF)
			goto cleanup;
		lua_rawgeti(L, LUA_REGISTRYINDEX, e.object_ref);

		/* Unpack args from registry if present */
		int nargs = 0;
		if (e.args_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX, e.args_ref);
			nargs = e.nargs;
			/* -j always points to the args table: after pushing
			 * j-1 values, the table has shifted from -1 to -j. */
			for (int j = 1; j <= nargs; j++)
				lua_rawgeti(L, -j, j);
			/* Remove the args table (now below the unpacked values) */
			lua_remove(L, -(nargs + 1));
		}

		/* Dispatch through existing signal mechanism */
		luaA_object_emit_signal(L, -(nargs + 1), name, nargs);

		/* Pop the object */
		lua_pop(L, 1);

	cleanup:
		/* Release registry refs */
		if (e.object_ref != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX, e.object_ref);
		if (e.args_ref != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX, e.args_ref);
	}

	/* Remove processed events. If new events were added during drain,
	 * shift them to the front. */
	if (queue_len > count) {
		memmove(queue_buf, queue_buf + count,
		        (queue_len - count) * sizeof(some_event_t));
		queue_len -= count;
	} else {
		queue_len = 0;
	}
}

bool
some_event_queue_pending(void)
{
	return queue_len > 0;
}

void
some_event_queue_init(void)
{
	queue_buf = NULL;
	queue_len = 0;
	queue_cap = 0;
}

void
some_event_queue_reset(void)
{
	/* Drop pending events without unref-ing. Used by hot-reload right
	 * before the old Lua state is abandoned: the old registry goes
	 * with the leaked state, so unref-ing is wasted work. Letting
	 * these events survive into the new state would be a correctness
	 * bug: the old integer refs would index unrelated slots in the
	 * new registry and a later drain would emit on random objects
	 * (or unref unrelated slots). */
	queue_len = 0;
}

void
some_event_queue_wipe(void)
{
	/* Release any pending registry refs (events queued after last drain) */
	lua_State *L = globalconf_get_lua_State();
	if (L) {
		for (int i = 0; i < queue_len; i++) {
			if (queue_buf[i].object_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, queue_buf[i].object_ref);
			if (queue_buf[i].args_ref != LUA_NOREF)
				luaL_unref(L, LUA_REGISTRYINDEX, queue_buf[i].args_ref);
		}
	}
	free(queue_buf);
	queue_buf = NULL;
	queue_len = 0;
	queue_cap = 0;
}
