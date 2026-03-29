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
#include "common/luaobject.h"
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
		fprintf(stderr, "[event_queue] allocation failed\n");
		return;
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
some_event_queue_property(lua_State *L, int obj_ud, uint16_t signal_id)
{
	some_event_t *e = queue_push();
	e->event_type = EVENT_OBJECT;
	e->signal_id = signal_id;
	e->nargs = 0;
	e->args_ref = LUA_NOREF;

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
}

void
some_event_queue_move(lua_State *L, int obj_ud, int local_x, int local_y)
{
	/* Coalesce: scan backward for an existing SIG_MOUSE_MOVE on the same
	 * object. If found, update its args instead of adding a new event.
	 * We compare by checking if the object ref points to the same object. */

	/* First, get a ref to the object for comparison */
	lua_pushvalue(L, obj_ud);

	/* Scan backward (most recent events first) for a match */
	for (int i = queue_len - 1; i >= 0; i--) {
		some_event_t *existing = &queue_buf[i];

		/* Stop scanning if we hit a non-move event (preserve ordering
		 * relative to enter/leave events) */
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
		some_event_t *e = &queue_buf[i];
		const char *name = signal_names[e->signal_id];

		if (!name)
			goto cleanup;

		if (e->event_type == EVENT_GLOBAL) {
			luaA_emit_signal_global(name);
			goto cleanup;
		}

		/* Push object from registry */
		if (e->object_ref == LUA_NOREF)
			goto cleanup;
		lua_rawgeti(L, LUA_REGISTRYINDEX, e->object_ref);

		/* Unpack args from registry if present */
		int nargs = 0;
		if (e->args_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX, e->args_ref);
			/* Unpack table values onto stack. As each value is pushed,
			 * the table shifts down by one position. */
			nargs = e->nargs;
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
		if (e->object_ref != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX, e->object_ref);
		if (e->args_ref != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX, e->args_ref);
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
some_event_queue_wipe(void)
{
	free(queue_buf);
	queue_buf = NULL;
	queue_len = 0;
	queue_cap = 0;
}
