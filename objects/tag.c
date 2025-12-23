/*
 * tag.c - tag management
 *
 * Ported from AwesomeWM for somewm (Wayland compositor)
 * Copyright © 2007-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "tag.h"
#include "luaa.h"
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "../somewm_api.h"
#include "../globalconf.h"
#include "../util.h"
#include "../somewm_types.h"
#include "client.h"
#include "screen.h"
#include "../banning.h"
#include <stdio.h>
#include <stdint.h>

/* AwesomeWM-compatible tag class */
lua_class_t tag_class;

/* Generate tag_new(), luaA_tag_gc(), etc. via LUA_OBJECT_FUNCS macro */
LUA_OBJECT_FUNCS(tag_class, tag_t, tag)

/** Wipe a tag when it's garbage collected
 */
static void
tag_wipe(tag_t *tag)
{
	client_array_wipe(&tag->clients);
	p_delete(&tag->name);
}

/** Helper functions for Lua compatibility */

/** Emit tagged/untagged signal on both client and tag
 * \param t the tag
 * \param c the client
 * \param signame signal name ("tagged" or "untagged")
 */
static void
tag_client_emit_signal(tag_t *t, client_t *c, const char *signame)
{
	lua_State *L = globalconf_get_lua_State();
	luaA_object_push(L, c);
	luaA_object_push(L, t);
	/* emit signal on client, with tag as argument */
	luaA_object_emit_signal(L, -2, signame, 1);
	/* re-push tag */
	luaA_object_push(L, t);
	/* move tag before client */
	lua_insert(L, -2);
	/* emit signal on tag, with client as argument */
	luaA_object_emit_signal(L, -2, signame, 1);
	/* Remove tag */
	lua_pop(L, 1);
}

/** Tag a client with the tag on top of the stack.
 * \param L The Lua VM state.
 * \param c the client to tag
 */
void
tag_client(lua_State *L, client_t *c)
{
	tag_t *t = luaA_object_ref_class(L, -1, &tag_class);

	/* don't tag twice */
	if (is_client_tagged(c, t))
	{
		luaA_object_unref(L, t);
		return;
	}

	client_array_append(&t->clients, c);

	/* Bitmask sync removed - arrays maintained */

	/* Mark that visibility needs update (AwesomeWM compatibility) */
	banning_need_update();

	/* Arrange the monitor to update layout and visibility immediately */
	if (c->mon)
		some_monitor_arrange(c->mon);

	tag_client_emit_signal(t, c, "tagged");
}

/** Untag a client with specified tag.
 * \param c the client to untag
 * \param t the tag to untag the client from
 */
void
untag_client(client_t *c, tag_t *t)
{
	for (int i = 0; i < t->clients.len; i++)
		if (t->clients.tab[i] == c)
		{
			lua_State *L = globalconf_get_lua_State();
			client_array_take(&t->clients, i);

			/* Bitmask sync removed - arrays maintained */

			/* Mark that visibility needs update (AwesomeWM compatibility) */
			banning_need_update();

			/* Arrange the monitor to update layout and visibility immediately */
			if (c->mon)
				some_monitor_arrange(c->mon);

			tag_client_emit_signal(t, c, "untagged");
			luaA_object_unref(L, t);
			return;
		}
}

/** Check if a client is tagged with the specified tag.
 * \param c the client
 * \param t the tag
 * \return true if the client is tagged with the tag, false otherwise.
 */
bool
is_client_tagged(client_t *c, tag_t *t)
{
	if (!c || !t)
		return false;

	for (int i = 0; i < t->clients.len; i++)
		if (t->clients.tab[i] == c)
			return true;

	return false;
}

void
tag_unref_simplified(tag_t **tag)
{
	luaA_object_unref(globalconf.L, *tag);
}

bool
tag_get_selected(tag_t *tag)
{
	return tag->selected;
}

char *
tag_get_name(tag_t *tag)
{
	return tag->name;
}

/* ========================================================================
 * Tag Lua API - property getters/setters
 * ======================================================================== */

/** Get tag name property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes name string)
 */
static int
luaA_tag_get_name(lua_State *L, tag_t *tag)
{
	lua_pushstring(L, tag->name);
	return 1;
}

/** Set tag name property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_name(lua_State *L, tag_t *tag)
{
	const char *name = luaL_checkstring(L, -1);
	p_delete(&tag->name);
	tag->name = a_strdup(name);
	luaA_awm_object_emit_signal(L, -3, "property::name", 0);
	return 0;
}

/** Get tag selected property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes boolean)
 */
static int
luaA_tag_get_selected(lua_State *L, tag_t *tag)
{
	lua_pushboolean(L, tag->selected);
	return 1;
}

/** Set tag selected property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_selected(lua_State *L, tag_t *tag)
{
	bool selected;
	Monitor *m;

	selected = lua_toboolean(L, -1);

	if (tag->selected != selected) {
		tag->selected = selected;
		banning_need_update();
		luaA_awm_object_emit_signal(L, -3, "property::selected", 0);

		m = some_get_focused_monitor();
		if (m) {
			some_monitor_arrange(m);
			/* Note: focus handled by Lua via property::selected signal → awful.permissions.check_focus_tag */
		}
	}
	return 0;
}

/** Get tag activated property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes boolean)
 */
static int
luaA_tag_get_activated(lua_State *L, tag_t *tag)
{
	lua_pushboolean(L, tag->activated);
	return 1;
}

/** Set tag activated property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_activated(lua_State *L, tag_t *tag)
{
	bool activated = lua_toboolean(L, -1);
	if (tag->activated != activated) {
		tag->activated = activated;

		/* When activated, add to global tags array (AwesomeWM pattern) */
		if (activated) {
			lua_pushvalue(L, -3);  /* Push tag */
			tag_array_append(&globalconf.tags, luaA_object_ref_class(L, -1, &tag_class));
			fprintf(stderr, "[TAG_ACTIVATED] Added tag to globalconf.tags (count=%d)\n", globalconf.tags.len);
			fflush(stderr);
		} else {
			/* When deactivated, remove from global tags array */
			for (int i = 0; i < globalconf.tags.len; i++) {
				if (globalconf.tags.tab[i] == tag) {
					tag_array_take(&globalconf.tags, i);
					luaA_object_unref(L, tag);
					fprintf(stderr, "[TAG_ACTIVATED] Removed tag from globalconf.tags (count=%d)\n", globalconf.tags.len);
					fflush(stderr);
					break;
				}
			}
		}

		luaA_awm_object_emit_signal(L, -3, "property::activated", 0);
	} else {
		fflush(stderr);
	}
	return 0;
}

/* ========================================================================
 * AwesomeWM-compatible properties: screen, mfact, nmaster
 * ======================================================================== */

/** Get tag screen property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes screen object or nil)
 */
static int
luaA_tag_get_screen(lua_State *L, tag_t *tag)
{
	if (tag->screen)
		luaA_object_push(L, tag->screen);
	else
		lua_pushnil(L);
	return 1;
}

/** Set tag screen property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_screen(lua_State *L, tag_t *tag)
{
	screen_t *new_screen = NULL;

	if (!lua_isnil(L, -1))
		new_screen = luaA_checkscreen(L, -1);

	if (tag->screen != new_screen) {
		tag->screen = new_screen;
		luaA_awm_object_emit_signal(L, -3, "property::screen", 0);
	}

	return 0;
}

/** Get tag mfact property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes number)
 */
static int
luaA_tag_get_mfact(lua_State *L, tag_t *tag)
{
	lua_pushnumber(L, tag->mfact);
	return 1;
}

/** Set tag mfact property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_mfact(lua_State *L, tag_t *tag)
{
	float new_mfact = (float)luaL_checknumber(L, -1);

	/* Clamp to valid range (0.05 to 0.95) */
	if (new_mfact < 0.05f) new_mfact = 0.05f;
	if (new_mfact > 0.95f) new_mfact = 0.95f;

	if (tag->mfact != new_mfact) {
		tag->mfact = new_mfact;
		luaA_awm_object_emit_signal(L, -3, "property::mfact", 0);

		/* Trigger layout update if this tag is selected */
		if (tag->selected && tag->screen && tag->screen->monitor) {
			some_monitor_arrange(tag->screen->monitor);
		}
	}

	return 0;
}

/** Get tag nmaster property
 * \param L Lua state
 * \param tag Tag object
 * \return 1 (pushes integer)
 */
static int
luaA_tag_get_nmaster(lua_State *L, tag_t *tag)
{
	lua_pushinteger(L, tag->nmaster);
	return 1;
}

/** Set tag nmaster property
 * \param L Lua state
 * \param tag Tag object
 * \return 0
 */
static int
luaA_tag_set_nmaster(lua_State *L, tag_t *tag)
{
	int new_nmaster = luaL_checkinteger(L, -1);

	/* Ensure non-negative */
	if (new_nmaster < 0) new_nmaster = 0;

	if (tag->nmaster != new_nmaster) {
		tag->nmaster = new_nmaster;
		luaA_awm_object_emit_signal(L, -3, "property::nmaster", 0);

		/* Trigger layout update if this tag is selected */
		if (tag->selected && tag->screen && tag->screen->monitor) {
			some_monitor_arrange(tag->screen->monitor);
		}
	}

	return 0;
}

/** Create a new tag object from Lua
 * \param L Lua state
 * \return 1 (pushes new tag)
 */
static int
luaA_tag_new(lua_State *L)
{
	return luaA_class_new(L, &tag_class);
}

/** Get list of clients on this tag
 * \param L Lua state
 * \return 1 (pushes client table)
 */
static int
luaA_tag_clients(lua_State *L)
{
	tag_t *tag = luaA_checkudata(L, 1, &tag_class);
	lua_newtable(L);

	for (int i = 0; i < tag->clients.len; i++) {
		luaA_object_push(L, tag->clients.tab[i]);
		lua_rawseti(L, -2, i + 1);
	}

	return 1;
}

/* ========================================================================
 * Tag class setup
 * ======================================================================== */

void
tag_class_setup(lua_State *L)
{
	static const struct luaL_Reg tag_methods[] = {
		LUA_CLASS_METHODS(tag)
		{ "__call", luaA_tag_new },
		{ NULL, NULL }
	};

	static const struct luaL_Reg tag_meta[] = {
		LUA_OBJECT_META(tag)
		LUA_CLASS_META
		{ "clients", luaA_tag_clients },
		{ NULL, NULL }
	};

	/* Setup tag class */
	luaA_class_setup(L, &tag_class, "tag", NULL,
	                 (lua_class_allocator_t) tag_new,
	                 (lua_class_collector_t) tag_wipe,
	                 NULL,
	                 luaA_class_index_miss_property, luaA_class_newindex_miss_property,
	                 tag_methods, tag_meta);

	/* Register tag properties */
	luaA_class_add_property(&tag_class, "name",
	                        (lua_class_propfunc_t) luaA_tag_set_name,
	                        (lua_class_propfunc_t) luaA_tag_get_name,
	                        (lua_class_propfunc_t) luaA_tag_set_name);
	luaA_class_add_property(&tag_class, "selected",
	                        (lua_class_propfunc_t) luaA_tag_set_selected,
	                        (lua_class_propfunc_t) luaA_tag_get_selected,
	                        (lua_class_propfunc_t) luaA_tag_set_selected);
	luaA_class_add_property(&tag_class, "activated",
	                        (lua_class_propfunc_t) luaA_tag_set_activated,
	                        (lua_class_propfunc_t) luaA_tag_get_activated,
	                        (lua_class_propfunc_t) luaA_tag_set_activated);

	/* Register AwesomeWM-compatible properties */
	luaA_class_add_property(&tag_class, "screen",
	                        (lua_class_propfunc_t) luaA_tag_set_screen,
	                        (lua_class_propfunc_t) luaA_tag_get_screen,
	                        (lua_class_propfunc_t) luaA_tag_set_screen);
	luaA_class_add_property(&tag_class, "mfact",
	                        (lua_class_propfunc_t) luaA_tag_set_mfact,
	                        (lua_class_propfunc_t) luaA_tag_get_mfact,
	                        (lua_class_propfunc_t) luaA_tag_set_mfact);
	luaA_class_add_property(&tag_class, "nmaster",
	                        (lua_class_propfunc_t) luaA_tag_set_nmaster,
	                        (lua_class_propfunc_t) luaA_tag_get_nmaster,
	                        (lua_class_propfunc_t) luaA_tag_set_nmaster);
}

/* ========================================================================
 * Tag initialization - populate globalconf.tags with tag_t Lua objects
 * ======================================================================== */

/** Initialize tags and populate globalconf.tags
 * Creates tag_t Lua objects and stores them in globalconf.tags array
 * \param L Lua state
 * \param tagcount Number of tags to create
 * \param tagnames Array of tag names
 */
void
luaA_tags_init(lua_State *L, int tagcount, const char **tagnames)
{
	if (tagcount < 1 || tagcount > 31) {
		fprintf(stderr, "luaA_tags_init: invalid tagcount %d (must be 1..31)\n", tagcount);
		return;
	}

	/* Initialize globalconf.tags array */
	tag_array_init(&globalconf.tags);

	/* Stop Lua GC during tag creation to prevent premature collection */
	lua_gc(L, LUA_GCSTOP, 0);

	/* Create tag_t Lua objects */
	for (int i = 0; i < tagcount; i++) {
		/* tag_new() creates userdata and leaves it on the stack */
		tag_t *tag = (tag_t *)tag_new(L);

		/* Set tag name */
		tag->name = a_strdup(tagnames[i]);

		/* Set tag as activated by default */
		tag->activated = true;

		/* First tag is selected by default */
		tag->selected = (i == 0);

		/* Initialize clients array */
		client_array_init(&tag->clients);

		/* Set tag index in _private.awful_tag_properties (AwesomeWM compatibility)
		 * This is required for screen.tags to sort correctly.
		 * Stack: [tag] */
		lua_pushvalue(L, -1);  /* Duplicate tag on stack: [tag, tag] */

		/* Get tag._private */
		lua_getfield(L, -1, "_private");  /* [tag, tag, _private] */
		if (lua_isnil(L, -1)) {
			/* _private doesn't exist, create it */
			lua_pop(L, 1);  /* Pop nil: [tag, tag] */
			lua_newtable(L);  /* [tag, tag, _private] */
			lua_pushvalue(L, -1);  /* [tag, tag, _private, _private] */
			lua_setfield(L, -3, "_private");  /* tag._private = _private: [tag, tag, _private] */
		}

		/* Create awful_tag_properties table */
		lua_newtable(L);  /* [tag, tag, _private, awful_tag_properties] */

		/* Set index = i+1 (1-based) */
		lua_pushinteger(L, i + 1);  /* [tag, tag, _private, awful_tag_properties, index] */
		lua_setfield(L, -2, "index");  /* awful_tag_properties.index = i+1: [tag, tag, _private, awful_tag_properties] */

		/* Set _private.awful_tag_properties = awful_tag_properties */
		lua_setfield(L, -2, "awful_tag_properties");  /* [tag, tag, _private] */
		lua_pop(L, 2);  /* Pop _private and duplicate tag: [tag] */

		/* Add to globalconf.tags */
		tag_array_append(&globalconf.tags, tag);

		/* Keep reference in Lua registry to prevent GC */
		/* Object is already on stack from tag_new(), just ref it */
		/* luaA_object_ref pops the object from the stack */
		luaA_object_ref(L, -1);
	}

	/* Restart Lua GC */
	lua_gc(L, LUA_GCRESTART, 0);
}
