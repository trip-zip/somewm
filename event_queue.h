/*
 * event_queue.h - Batched event queue for deferred signal dispatch
 *
 * Replaces synchronous C-to-Lua signal emission with frame-boundary
 * delivery. C code queues events during event handling; the drain
 * function dispatches them to Lua at defined sync points.
 */
#ifndef EVENT_QUEUE_H
#define EVENT_QUEUE_H

#include <stdbool.h>
#include <stdint.h>
#include <lua.h>

/* Signal name IDs - avoid string allocation per event.
 * Add new entries as signals are converted from synchronous to queued. */
enum {
	/* Property signals (informational, 0 args unless noted) */
	SIG_PROPERTY_GEOMETRY,
	SIG_PROPERTY_POSITION,
	SIG_PROPERTY_SIZE,
	SIG_PROPERTY_X,
	SIG_PROPERTY_Y,
	SIG_PROPERTY_WIDTH,
	SIG_PROPERTY_HEIGHT,

	/* Focus signals */
	SIG_PROPERTY_ACTIVE,   /* 1 arg: bool */
	SIG_FOCUS,
	SIG_UNFOCUS,
	SIG_CLIENT_FOCUS,      /* global */
	SIG_CLIENT_UNFOCUS,    /* global */

	/* Mouse signals */
	SIG_MOUSE_ENTER,
	SIG_MOUSE_LEAVE,
	SIG_MOUSE_MOVE,        /* 2 args: local x, y - coalesced per object */

	/* Global geometry signal */
	SIG_CLIENT_PROPERTY_GEOMETRY,  /* global */

	/* Placeholder for future conversions */

	SIG_COUNT
};

/* Event types */
enum {
	EVENT_OBJECT,  /* Signal on a specific Lua object */
	EVENT_CLASS,   /* Signal on a Lua class */
	EVENT_GLOBAL,  /* Signal on the awesome global */
};

/* A single queued event */
typedef struct {
	uint8_t event_type;   /* EVENT_OBJECT, EVENT_CLASS, EVENT_GLOBAL */
	uint16_t signal_id;   /* SIG_* enum value */
	int object_ref;       /* luaL_ref to target object (LUA_NOREF for globals) */
	int nargs;            /* Number of arguments captured */
	int args_ref;         /* luaL_ref to args table (LUA_NOREF if 0 args) */
} some_event_t;

/* Queue a 0-arg property signal on an object (fast path) */
void some_event_queue_property(lua_State *L, int obj_ud,
                               uint16_t signal_id);

/* Queue a signal with arguments on an object */
void some_event_queue_signal(lua_State *L, int obj_ud,
                             uint16_t signal_id, int nargs);

/* Queue a global signal (no object) */
void some_event_queue_global(uint16_t signal_id);

/* Queue a mouse::move with coalescing (updates existing if same object) */
void some_event_queue_move(lua_State *L, int obj_ud,
                           int local_x, int local_y);

/* Drain: dispatch all queued events to Lua, then clear */
void some_event_queue_drain(lua_State *L);

/* Check if queue has pending events */
bool some_event_queue_pending(void);

/* Init/cleanup */
void some_event_queue_init(void);
void some_event_queue_wipe(void);

#endif /* EVENT_QUEUE_H */
