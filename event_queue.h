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

struct lua_class_t;

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

	/* Lifecycle signals */
	SIG_LIST,              /* class-level, 0 args */
	SIG_SWAPPED,           /* 2 args: other object + is_source bool */

	/* Request signals (fire-and-forget, C doesn't check response) */
	SIG_REQUEST_ACTIVATE,  /* 1-2 args: context [, hints] - also used by systray items */
	SIG_REQUEST_URGENT,    /* 1 arg: bool */
	SIG_REQUEST_TAG,       /* 1 arg: tag index or table */
	SIG_REQUEST_SELECT,    /* 1 arg */
	SIG_SYSTRAY_SECONDARY_ACTIVATE, /* 2 args */
	SIG_SYSTRAY_CONTEXT_MENU,       /* 2 args */
	SIG_SYSTRAY_SCROLL,             /* 2 args */

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
	uint8_t event_type;         /* EVENT_OBJECT, EVENT_CLASS, EVENT_GLOBAL */
	uint16_t signal_id;         /* SIG_* enum value */
	int object_ref;             /* luaL_ref to target object (LUA_NOREF for globals) */
	int nargs;                  /* Number of arguments captured */
	int args_ref;               /* luaL_ref to args table (LUA_NOREF if 0 args) */
	struct lua_class_t *class_ptr;/* Class for EVENT_CLASS (NULL otherwise) */
} some_event_t;

/* Queue a 0-arg signal on an object (fast path). Used for property
 * signals and other 0-arg object signals like focus, unfocus,
 * mouse::enter, mouse::leave.
 *
 * Stack: reads the object at `obj_ud`; leaves the caller's stack
 * unchanged. The caller is responsible for popping the object
 * afterward if they no longer need it. */
void some_event_queue_signal0(lua_State *L, int obj_ud,
                              uint16_t signal_id);

/* Queue a signal with arguments on an object.
 *
 * Stack: expects the object at `obj_ud` and exactly `nargs` argument
 * values on top of the stack. Consumes the nargs (pops them); leaves
 * the object at `obj_ud` untouched. The caller is responsible for
 * popping the object afterward.
 *
 * Example (1 arg):
 *   luaA_object_push(L, c);                // [..., c]
 *   lua_pushboolean(L, true);              // [..., c, true]
 *   some_event_queue_signal(L, -2, SIG_PROPERTY_ACTIVE, 1);
 *                                          // [..., c]  (arg popped, c remains)
 *   lua_pop(L, 1);                         // [...]     (caller pops c) */
void some_event_queue_signal(lua_State *L, int obj_ud,
                             uint16_t signal_id, int nargs);

/* Queue a global signal (no object) */
void some_event_queue_global(uint16_t signal_id);

/* Queue a class-level signal (e.g., client "list").
 * Class signals never carry args in the current design; add an args
 * capture path to some_event_queue_class() before using one. */
void some_event_queue_class(struct lua_class_t *class_ptr, uint16_t signal_id);

/* Queue a mouse::move with coalescing (updates existing if same object).
 *
 * Stack: reads the object at `obj_ud`; leaves the caller's stack
 * unchanged. The caller is responsible for popping the object. */
void some_event_queue_move(lua_State *L, int obj_ud,
                           int local_x, int local_y);

/* Drain: dispatch all queued events to Lua, then clear */
void some_event_queue_drain(lua_State *L);

/* Check if queue has pending events */
bool some_event_queue_pending(void);

/* Init/cleanup */
void some_event_queue_init(void);
void some_event_queue_wipe(void);

/* Drop pending events without unref-ing. Their registry refs are
 * integer slot indices in the old state's registry, which is about
 * to be leaked with the rest of the state. Unref-ing now would be
 * safe but wasted work; letting them survive into the new state
 * would be a correctness bug: the same integers would point to
 * unrelated slots in the new registry. */
void some_event_queue_reset(void);

#endif /* EVENT_QUEUE_H */
