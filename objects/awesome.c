/* TODO: Rename this module to something better than "awesome"
 * Options: somewm, core, compositor
 * Current name chosen for AwesomeWM API compatibility
 */

#include "awesome.h"
#include "luaa.h"
#include "signal.h"
#include "spawn.h"
#include "systray.h"
#include "drawin.h"
#include "../somewm_api.h"
#include "../draw.h"  /* Must be before globalconf.h to avoid type conflicts */
#include "../globalconf.h"
#include "../color.h"
#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <drm_fourcc.h>
#include <cairo/cairo.h>

/* External functions */
extern void wlr_log_init(int verbosity, void *callback);

/* Forward declarations */
static int luaA_awesome_index(lua_State *L);

/** awesome.xrdb_get_value(resource_class, resource_name) - Get xrdb value
 * Delegates to Lua implementation for xrdb compatibility in Wayland.
 * This is a minimal stub that calls gears.xresources.get_value()
 * \param resource_class Resource class (usually empty string)
 * \param resource_name Resource name (e.g., "background", "Xft.dpi")
 * \return Resource value string or nil if not found
 */
static int
luaA_awesome_xrdb_get_value(lua_State *L)
{
	const char *resource_class;
	const char *resource_name;

	/* Parse arguments - AwesomeWM uses (class, name) */
	resource_class = luaL_optstring(L, 1, "");
	resource_name = luaL_checkstring(L, 2);

	/* Delegate to Lua implementation in gears.xresources */
	lua_getglobal(L, "require");
	lua_pushstring(L, "gears.xresources");
	lua_call(L, 1, 1);  /* require("gears.xresources") */

	/* Call get_value method */
	lua_getfield(L, -1, "get_value");
	lua_pushstring(L, resource_class);
	lua_pushstring(L, resource_name);
	lua_call(L, 2, 1);  /* xresources.get_value(class, name) */

	/* The return value is already on the stack */
	return 1;
}

/** awesome.quit() - Quit the compositor
 */
static int
luaA_awesome_quit(lua_State *L)
{
	some_compositor_quit();
	return 0;
}

/** awesome.new_client_placement - Get/set new client placement mode
 * Controls where new clients are placed in the tiling order.
 * 0 = master (new clients become master), 1 = slave (new clients become slaves)
 * When called with no arguments, returns current placement mode.
 * When called with a number or string, sets the placement mode.
 * \param placement Optional: 0/"master" for master placement, 1/"slave" for slave placement
 * \return Current placement mode (if getting): 0 for master, 1 for slave
 */
static int
luaA_awesome_new_client_placement(lua_State *L)
{
	if (lua_gettop(L) >= 1) {
		/* Set mode */
		int placement = 0;
		if (lua_isnumber(L, 1)) {
			placement = (int)lua_tonumber(L, 1);
		} else if (lua_isstring(L, 1)) {
			const char *str = lua_tostring(L, 1);
			if (strcmp(str, "slave") == 0) {
				placement = 1;
			} else if (strcmp(str, "master") == 0) {
				placement = 0;
			}
		}
		some_set_new_client_placement(placement);
		return 0;
	}
	/* Get mode */
	lua_pushnumber(L, some_get_new_client_placement());
	return 1;
}

/** awesome.get_cursor_position() - Get current cursor position
 * \return Table {x=double, y=double} with cursor coordinates
 */
static int
luaA_awesome_get_cursor_position(lua_State *L)
{
	double x, y;

	some_get_cursor_position(&x, &y);

	lua_newtable(L);
	lua_pushnumber(L, x);
	lua_setfield(L, -2, "x");
	lua_pushnumber(L, y);
	lua_setfield(L, -2, "y");
	return 1;
}

/** awesome.get_cursor_monitor() - Get monitor under cursor
 * \return Monitor userdata (lightuserdata) or nil
 */
static int
luaA_awesome_get_cursor_monitor(lua_State *L)
{
	Monitor *m = some_monitor_at_cursor();

	if (m)
		lua_pushlightuserdata(L, m);
	else
		lua_pushnil(L);
	return 1;
}

/** awesome.connect_signal(name, callback) - Connect to a global signal
 * Uses the internal global signal array (AwesomeWM pattern)
 * \param name Signal name (string)
 * \param callback Lua function to call when signal is emitted
 */
static int
luaA_awesome_connect_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const void *ref;
	luaL_checktype(L, 2, LUA_TFUNCTION);

	/* Store function in registry and get reference */
	lua_pushvalue(L, 2);  /* Duplicate function on stack */
	ref = luaA_object_ref(L, -1);

	/* Add reference to global signal array */
	luaA_signal_connect(name, ref);

	return 0;
}

/** awesome.disconnect_signal(name, callback) - Disconnect from a global signal
 * Uses the internal global signal array (AwesomeWM pattern)
 * \param name Signal name (string)
 * \param callback Lua function to disconnect
 */
static int
luaA_awesome_disconnect_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const void *ref;
	luaL_checktype(L, 2, LUA_TFUNCTION);

	ref = lua_topointer(L, 2);
	if (luaA_signal_disconnect(name, ref))
		luaA_object_unref(L, ref);

	return 0;
}

/** awesome.emit_signal(name, ...) - Emit a global signal
 * Uses the internal global signal array (AwesomeWM pattern)
 * \param name Signal name (string)
 * \param ... Arguments to pass to callbacks
 */
static int
luaA_awesome_emit_signal(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	int nargs = lua_gettop(L) - 1;  /* Number of extra arguments */

	luaA_signal_emit(L, name, nargs);

	return 0;
}

/** awesome._get_key_name(keysym) - Get human-readable key name
 * Translates XKB keysym to name string for AwesomeWM compatibility
 * \param keysym XKB keysym (number or string)
 * \return[1] string keysym The keysym name
 * \return[1] nil keysym If no valid keysym is found
 * \return[2] string printsymbol The UTF-8 representation
 * \return[2] nil printsymbol If the keysym has no printable representation
 */
static int
luaA_awesome_get_key_name(lua_State *L)
{
	xkb_keysym_t keysym;
	char keysym_name[64];
	char utf8[8] = {0};

	/* Accept either number (keysym) or string (key name) */
	if (lua_isnumber(L, 1)) {
		keysym = (xkb_keysym_t)lua_tonumber(L, 1);
	} else if (lua_isstring(L, 1)) {
		const char *key_str = lua_tostring(L, 1);
		keysym = xkb_keysym_from_name(key_str, XKB_KEYSYM_CASE_INSENSITIVE);
		if (keysym == XKB_KEY_NoSymbol) {
			/* Return nil, nil for invalid keysym */
			lua_pushnil(L);
			lua_pushnil(L);
			return 2;
		}
	} else {
		/* Return nil, nil for invalid input */
		lua_pushnil(L);
		lua_pushnil(L);
		return 2;
	}

	/* Get the keysym name */
	xkb_keysym_get_name(keysym, keysym_name, sizeof(keysym_name));

	/* Push the keysym name as first return value */
	lua_pushstring(L, keysym_name);

	/* Try to get UTF-8 representation as second return value */
	if (xkb_keysym_to_utf8(keysym, utf8, sizeof(utf8)) > 0 && utf8[0]) {
		lua_pushstring(L, utf8);
	} else {
		lua_pushnil(L);
	}

	return 2;  /* Return two values */
}

/** awesome.xkb_get_group_names() - Get keyboard layout symbols string
 * Returns XKB symbols name format used by keyboardlayout widget.
 * Format: "pc+English (US)+Russian+grp:alt_shift_toggle"
 * \return String of XKB symbols
 */
static int
luaA_awesome_xkb_get_group_names(lua_State *L)
{
	const char *symbols = some_xkb_get_group_names();

	if (symbols) {
		lua_pushstring(L, symbols);
	} else {
		/* Fallback: build from globalconf settings */
		const char *layout = globalconf.keyboard.xkb_layout;
		if (layout && *layout) {
			lua_pushfstring(L, "pc+%s", layout);
		} else {
			lua_pushstring(L, "pc+us");
		}
	}
	return 1;
}

/** awesome.xkb_get_layout_group() - Get current keyboard layout index
 * Returns the currently active keyboard layout group (0-based index).
 * \return Integer layout group index
 */
static int
luaA_awesome_xkb_get_layout_group(lua_State *L)
{
	struct xkb_state *state = some_xkb_get_state();
	xkb_layout_index_t group;

	if (!state) {
		lua_pushinteger(L, 0);
		return 1;
	}

	group = xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE);
	lua_pushinteger(L, (int)group);
	return 1;
}

/** awesome.xkb_set_layout_group(num) - Switch keyboard layout
 * Sets the active keyboard layout to the specified group index.
 * \param num Layout group index (0-based)
 */
static int
luaA_awesome_xkb_set_layout_group(lua_State *L)
{
	xkb_layout_index_t group = (xkb_layout_index_t)luaL_checkinteger(L, 1);

	if (!some_xkb_set_layout_group(group)) {
		luaL_error(L, "Failed to set keyboard layout group %d", (int)group);
	}

	return 0;
}

/** awesome.register_xproperty() - Register X property for client persistence
 * Stub implementation for AwesomeWM compatibility.
 * In AwesomeWM this registers X11 properties that persist across restarts.
 * For Wayland we don't have X properties, so this is a no-op stub.
 * TODO: Implement Wayland-native persistence (maybe via desktop files or state files)
 * \param property_name The property name to register
 * \param property_type The type: "string", "number", or "boolean"
 * \return Returns nothing
 */
static int
luaA_awesome_register_xproperty(lua_State *L)
{
	/* Validate arguments for compatibility */
	luaL_checkstring(L, 1);  /* property name */
	luaL_checkstring(L, 2);  /* property type */

	/* TODO: Implement Wayland-native persistence mechanism
	 * For now, this is a silent no-op to allow awful.client to load */
	return 0;
}

/** awesome.pixbuf_to_surface() - Convert GdkPixbuf to cairo surface
 * Translates a GdkPixbuf (from LGI) to a cairo image surface.
 * This is used by gears.surface when loading image files via GdkPixbuf.
 * \param pixbuf The GdkPixbuf as a light userdata (from GdkPixbuf._native)
 * \param path The pixbuf origin path (for error messages, unused)
 * \return Cairo surface as light userdata (or nil + error message)
 */
static int
luaA_pixbuf_to_surface(lua_State *L)
{
	GdkPixbuf *pixbuf = (GdkPixbuf *) lua_touserdata(L, 1);
	cairo_surface_t *surface;

	if (!pixbuf) {
		lua_pushnil(L);
		lua_pushstring(L, "Invalid pixbuf (expected light userdata)");
		return 2;
	}

	surface = draw_surface_from_pixbuf(pixbuf);
	if (!surface) {
		lua_pushnil(L);
		lua_pushstring(L, "Failed to create cairo surface from pixbuf");
		return 2;
	}

	/* Lua must free this ref via cairo.Surface or we have a leak */
	lua_pushlightuserdata(L, surface);
	return 1;
}

/** Rebuild keyboard keymap with current XKB settings
 * Called after changing xkb_layout, xkb_variant, or xkb_options
 */
static void
rebuild_keyboard_keymap(void)
{
	some_rebuild_keyboard_keymap();
}

/** Helper to count visible systray entries (status != "Passive")
 */
static int
systray_count_visible(void)
{
	systray_item_array_t *items = systray_get_items();
	int count = 0;
	int i;

	if (!items)
		return 0;

	for (i = 0; i < items->len; i++) {
		systray_item_t *item = items->tab[i];
		/* Count if valid and not passive */
		if (item && item->is_valid) {
			if (!item->status || strcmp(item->status, "Passive") != 0)
				count++;
		}
	}
	return count;
}

/* ========================================================================
 * Systray icon buffer wrapper for wlr_scene_buffer
 * ======================================================================== */

struct systray_icon_buffer {
	struct wlr_buffer base;
	void *data;
	int width;
	int height;
	size_t stride;
};

static void systray_icon_buffer_destroy(struct wlr_buffer *wlr_buffer)
{
	struct systray_icon_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	free(buffer->data);
	free(buffer);
}

static bool systray_icon_buffer_begin_data_ptr_access(
	struct wlr_buffer *wlr_buffer, uint32_t flags, void **data,
	uint32_t *format, size_t *stride)
{
	struct systray_icon_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	*data = buffer->data;
	*format = DRM_FORMAT_ARGB8888;
	*stride = buffer->stride;
	return true;
}

static void systray_icon_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer)
{
	/* Nothing to do */
}

static const struct wlr_buffer_impl systray_icon_buffer_impl = {
	.destroy = systray_icon_buffer_destroy,
	.begin_data_ptr_access = systray_icon_buffer_begin_data_ptr_access,
	.end_data_ptr_access = systray_icon_buffer_end_data_ptr_access,
};

/**
 * Create a wlr_buffer from a cairo surface.
 * The buffer takes ownership of a copy of the surface data.
 */
static struct wlr_buffer *
systray_buffer_from_cairo(cairo_surface_t *surface)
{
	struct systray_icon_buffer *buffer;
	int width, height;
	size_t stride, size;
	unsigned char *src_data;

	if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
		return NULL;

	if (cairo_image_surface_get_format(surface) != CAIRO_FORMAT_ARGB32)
		return NULL;

	width = cairo_image_surface_get_width(surface);
	height = cairo_image_surface_get_height(surface);
	stride = (size_t)cairo_image_surface_get_stride(surface);
	src_data = cairo_image_surface_get_data(surface);

	if (width <= 0 || height <= 0 || !src_data)
		return NULL;

	buffer = calloc(1, sizeof(*buffer));
	if (!buffer)
		return NULL;

	size = stride * (size_t)height;
	buffer->data = malloc(size);
	if (!buffer->data) {
		free(buffer);
		return NULL;
	}

	memcpy(buffer->data, src_data, size);
	buffer->width = width;
	buffer->height = height;
	buffer->stride = stride;

	wlr_buffer_init(&buffer->base, &systray_icon_buffer_impl, width, height);

	return &buffer->base;
}

/** Render systray icons to scene graph
 * Creates/updates scene buffer nodes for each visible systray item
 */
static void
systray_render_icons(drawin_t *drawin)
{
	systray_item_array_t *items;
	int i, pos_x, pos_y, idx;
	int base_size, spacing, rows;
	bool horizontal;

	if (!drawin || !drawin->scene_tree)
		return;

	items = systray_get_items();
	if (!items || items->len == 0)
		return;

	/* Create scene tree for icons if needed */
	if (!globalconf.systray.scene_tree) {
		globalconf.systray.scene_tree = wlr_scene_tree_create(drawin->scene_tree);
		if (!globalconf.systray.scene_tree)
			return;
		/* Mark with drawin so xytonode correctly identifies it */
		globalconf.systray.scene_tree->node.data = drawin;
	}

	/* Get layout parameters */
	base_size = globalconf.systray.layout.base_size;
	spacing = globalconf.systray.layout.spacing;
	horizontal = globalconf.systray.layout.horizontal;
	rows = globalconf.systray.layout.rows;

	if (base_size <= 0)
		base_size = 24;
	if (rows <= 0)
		rows = 1;

	/* Position the systray container */
	wlr_scene_node_set_position(&globalconf.systray.scene_tree->node,
	                            globalconf.systray.layout.x,
	                            globalconf.systray.layout.y);

	/* Clear existing children - we'll recreate them
	 * This is simple but not optimal; a proper implementation would reuse nodes */
	{
		struct wlr_scene_node *child, *tmp;
		wl_list_for_each_safe(child, tmp, &globalconf.systray.scene_tree->children, link) {
			wlr_scene_node_destroy(child);
		}
	}

	/* Render each visible item */
	idx = 0;
	for (i = 0; i < items->len; i++) {
		systray_item_t *item = items->tab[i];
		int row, col;

		if (!item || !item->is_valid)
			continue;
		if (item->status && strcmp(item->status, "Passive") == 0)
			continue;

		/* Calculate position in grid */
		if (horizontal) {
			col = idx / rows;
			row = idx % rows;
			pos_x = col * (base_size + spacing);
			pos_y = row * (base_size + spacing);
		} else {
			row = idx / rows;
			col = idx % rows;
			pos_x = col * (base_size + spacing);
			pos_y = row * (base_size + spacing);
		}

		/* Render the icon */
		if (item->icon) {
			/* Use actual icon cairo surface */
			struct wlr_buffer *icon_buffer = systray_buffer_from_cairo(item->icon);
			if (icon_buffer) {
				struct wlr_scene_buffer *scene_buf;
				scene_buf = wlr_scene_buffer_create(globalconf.systray.scene_tree,
				                                    icon_buffer);
				if (scene_buf) {
					wlr_scene_node_set_position(&scene_buf->node, pos_x, pos_y);
					/* Mark as belonging to drawin's drawable for xytonode() */
					scene_buf->node.data = drawin->drawable;
					/* Scale if icon size differs from base_size */
					if (item->icon_width != base_size || item->icon_height != base_size) {
						wlr_scene_buffer_set_dest_size(scene_buf, base_size, base_size);
					}
				}
				wlr_buffer_drop(icon_buffer);
			}
		} else {
			/* Fallback: placeholder colored rectangle */
			float color[4] = {0.5f, 0.5f, 0.8f, 1.0f};
			struct wlr_scene_rect *rect;
			rect = wlr_scene_rect_create(globalconf.systray.scene_tree,
			                             base_size, base_size, color);
			if (rect) {
				wlr_scene_node_set_position(&rect->node, pos_x, pos_y);
				/* Mark as belonging to drawin's drawable for xytonode() */
				rect->node.data = drawin->drawable;
			}
		}

		idx++;
	}
}

/** Systray kickout - remove systray from a drawin
 */
static void
systray_kickout(drawin_t *drawin)
{
	if (globalconf.systray.parent != drawin)
		return;

	/* Destroy scene tree if it exists */
	if (globalconf.systray.scene_tree) {
		wlr_scene_node_destroy(&globalconf.systray.scene_tree->node);
		globalconf.systray.scene_tree = NULL;
	}

	globalconf.systray.parent = NULL;
}

/** awesome.systray() - Manage the system tray
 *
 * This function has three modes:
 * 1. Query mode (no args): Returns (count, parent_drawin)
 * 2. Kickout mode (1 arg): Remove systray from the specified drawin
 * 3. Render mode (9 args): Position and render systray icons
 *
 * Unlike AwesomeWM's X11 XEmbed approach, we use StatusNotifierItem (SNI)
 * protocol via D-Bus. Icons are rendered as scene graph nodes.
 *
 * \param L Lua state
 * \return 2 values: number of visible entries, parent drawin (or nil)
 */
static int
luaA_systray(lua_State *L)
{
	int nargs = lua_gettop(L);
	drawin_t *drawin;
	int x, y, base_size, spacing, rows;
	bool horizontal, reverse;
	const char *bg_color;
	color_t bg;

	/* Mode 1: Query - just return count and parent */
	if (nargs == 0) {
		lua_pushinteger(L, systray_count_visible());
		if (globalconf.systray.parent)
			luaA_object_push(L, globalconf.systray.parent);
		else
			lua_pushnil(L);
		return 2;
	}

	/* Get the drawin argument (required for modes 2 and 3) */
	drawin = luaA_todrawin(L, 1);
	if (!drawin) {
		/* Invalid drawin, just return count and nil */
		lua_pushinteger(L, systray_count_visible());
		lua_pushnil(L);
		return 2;
	}

	/* Mode 2: Kickout - remove systray from this drawin */
	if (nargs == 1) {
		systray_kickout(drawin);
		lua_pushinteger(L, systray_count_visible());
		lua_pushnil(L);
		return 2;
	}

	/* Mode 3: Render - position and display systray icons */
	/* Args: drawin, x, y, base_size, is_rotated, bg_color, reverse, spacing, rows */

	x = luaL_checkinteger(L, 2);
	y = luaL_checkinteger(L, 3);
	base_size = luaL_checkinteger(L, 4);
	horizontal = lua_toboolean(L, 5);  /* is_rotated in AwesomeWM */
	bg_color = luaL_optstring(L, 6, "#000000");
	reverse = lua_toboolean(L, 7);
	spacing = luaL_optinteger(L, 8, 0);
	rows = luaL_optinteger(L, 9, 1);

	/* Switch parent if needed */
	if (globalconf.systray.parent != drawin) {
		/* Kickout from old parent */
		if (globalconf.systray.parent)
			systray_kickout(globalconf.systray.parent);
		globalconf.systray.parent = drawin;
	}

	/* Parse and store background color */
	if (color_init_from_string(&bg, bg_color)) {
		globalconf.systray.background_pixel =
			((uint32_t)(bg.alpha * 255) << 24) |
			((uint32_t)(bg.red * 255) << 16) |
			((uint32_t)(bg.green * 255) << 8) |
			((uint32_t)(bg.blue * 255));
	}

	/* Store layout parameters */
	globalconf.systray.layout.x = x;
	globalconf.systray.layout.y = y;
	globalconf.systray.layout.base_size = base_size;
	globalconf.systray.layout.horizontal = horizontal;
	globalconf.systray.layout.reverse = reverse;
	globalconf.systray.layout.spacing = spacing;
	globalconf.systray.layout.rows = rows > 0 ? rows : 1;

	/* Render systray icons to scene graph */
	systray_render_icons(drawin);

	lua_pushinteger(L, systray_count_visible());
	luaA_object_push(L, drawin);
	return 2;
}

/** awesome.sync() - Synchronize with the compositor
 * In AwesomeWM this flushes X11 requests via xcb_aux_sync().
 * For Wayland, we flush pending events to clients.
 * Used primarily in tests and by awful.screenshot.
 * \noreturn
 */
static int
luaA_awesome_sync(lua_State *L)
{
	struct wl_display *display = some_get_display();
	if (display) {
		wl_display_flush_clients(display);
	}
	return 0;
}

/** Set a libinput pointer/touchpad setting and apply to all devices
 * Called from awful.input Lua module
 * \param key The setting name (e.g., "tap_to_click", "natural_scrolling")
 * \param value The value to set
 * \return Nothing
 */
static int
luaA_awesome_set_input_setting(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);

	if (strcmp(key, "tap_to_click") == 0) {
		globalconf.input.tap_to_click = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "tap_and_drag") == 0) {
		globalconf.input.tap_and_drag = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "drag_lock") == 0) {
		globalconf.input.drag_lock = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "natural_scrolling") == 0) {
		globalconf.input.natural_scrolling = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "disable_while_typing") == 0) {
		globalconf.input.disable_while_typing = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "left_handed") == 0) {
		globalconf.input.left_handed = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "middle_button_emulation") == 0) {
		globalconf.input.middle_button_emulation = luaL_checkinteger(L, 2);
	} else if (strcmp(key, "scroll_method") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.scroll_method);
		globalconf.input.scroll_method = val ? strdup(val) : NULL;
	} else if (strcmp(key, "click_method") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.click_method);
		globalconf.input.click_method = val ? strdup(val) : NULL;
	} else if (strcmp(key, "send_events_mode") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.send_events_mode);
		globalconf.input.send_events_mode = val ? strdup(val) : NULL;
	} else if (strcmp(key, "accel_profile") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.accel_profile);
		globalconf.input.accel_profile = val ? strdup(val) : NULL;
	} else if (strcmp(key, "accel_speed") == 0) {
		globalconf.input.accel_speed = lua_tonumber(L, 2);
	} else if (strcmp(key, "tap_button_map") == 0) {
		const char *val = lua_isnil(L, 2) ? NULL : luaL_checkstring(L, 2);
		free(globalconf.input.tap_button_map);
		globalconf.input.tap_button_map = val ? strdup(val) : NULL;
	} else {
		return luaL_error(L, "Unknown input setting: %s", key);
	}

	/* Apply settings to all connected devices */
	apply_input_settings_to_all_devices();
	return 0;
}

/** Set a keyboard setting and apply
 * Called from awful.input Lua module
 * \param key The setting name (e.g., "xkb_layout", "keyboard_repeat_rate")
 * \param value The value to set
 * \return Nothing
 */
static int
luaA_awesome_set_keyboard_setting(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);

	if (strcmp(key, "keyboard_repeat_rate") == 0) {
		globalconf.keyboard.repeat_rate = luaL_checkinteger(L, 2);
		/* TODO: Apply repeat rate to keyboard group */
	} else if (strcmp(key, "keyboard_repeat_delay") == 0) {
		globalconf.keyboard.repeat_delay = luaL_checkinteger(L, 2);
		/* TODO: Apply repeat delay to keyboard group */
	} else if (strcmp(key, "xkb_layout") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_layout);
		globalconf.keyboard.xkb_layout = strdup(val);
		rebuild_keyboard_keymap();
	} else if (strcmp(key, "xkb_variant") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_variant);
		globalconf.keyboard.xkb_variant = strdup(val);
		rebuild_keyboard_keymap();
	} else if (strcmp(key, "xkb_options") == 0) {
		const char *val = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
		free(globalconf.keyboard.xkb_options);
		globalconf.keyboard.xkb_options = strdup(val);
		rebuild_keyboard_keymap();
	} else {
		return luaL_error(L, "Unknown keyboard setting: %s", key);
	}

	return 0;
}

/* awesome module methods */
static const luaL_Reg awesome_methods[] = {
	{ "quit", luaA_awesome_quit },
	{ "spawn", luaA_spawn },
	{ "new_client_placement", luaA_awesome_new_client_placement },
	{ "get_cursor_position", luaA_awesome_get_cursor_position },
	{ "get_cursor_monitor", luaA_awesome_get_cursor_monitor },
	{ "connect_signal", luaA_awesome_connect_signal },
	{ "disconnect_signal", luaA_awesome_disconnect_signal },
	{ "emit_signal", luaA_awesome_emit_signal },
	{ "_get_key_name", luaA_awesome_get_key_name },
	{ "xkb_get_group_names", luaA_awesome_xkb_get_group_names },
	{ "xkb_get_layout_group", luaA_awesome_xkb_get_layout_group },
	{ "xkb_set_layout_group", luaA_awesome_xkb_set_layout_group },
	{ "xrdb_get_value", luaA_awesome_xrdb_get_value },
	{ "register_xproperty", luaA_awesome_register_xproperty },
	{ "pixbuf_to_surface", luaA_pixbuf_to_surface },
	{ "systray", luaA_systray },
	{ "sync", luaA_awesome_sync },
	{ "_set_input_setting", luaA_awesome_set_input_setting },
	{ "_set_keyboard_setting", luaA_awesome_set_keyboard_setting },
	{ NULL, NULL }
};

/** awesome.__index handler for property access
 * Handles: startup_errors, keyboard settings, input settings
 * (AwesomeWM-compatible pattern)
 */
static int
luaA_awesome_index(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	if (A_STREQ(key, "startup_errors")) {
		/* Return nil if no errors, otherwise return error string */
		if (globalconf.startup_errors.len == 0)
			return 0;  /* Return nothing (nil) */
		lua_pushstring(L, globalconf.startup_errors.s);
		return 1;
	}

	if (A_STREQ(key, "x11_fallback_info")) {
		/* Return nil if no fallback occurred, otherwise return info table */
		if (!globalconf.x11_fallback.config_path)
			return 0;  /* Return nil */

		lua_newtable(L);

		lua_pushstring(L, globalconf.x11_fallback.config_path);
		lua_setfield(L, -2, "config_path");

		lua_pushinteger(L, globalconf.x11_fallback.line_number);
		lua_setfield(L, -2, "line_number");

		/* Note: C stores as pattern_desc, Lua expects "pattern" */
		lua_pushstring(L, globalconf.x11_fallback.pattern_desc);
		lua_setfield(L, -2, "pattern");

		lua_pushstring(L, globalconf.x11_fallback.suggestion);
		lua_setfield(L, -2, "suggestion");

		if (globalconf.x11_fallback.line_content) {
			lua_pushstring(L, globalconf.x11_fallback.line_content);
			lua_setfield(L, -2, "line_content");
		}

		return 1;
	}

	/* Logging properties */
	if (A_STREQ(key, "log_level")) {
		/* Convert int enum to string */
		const char *level_str = "error";  /* Default */
		switch (globalconf.log_level) {
			case 0: level_str = "silent"; break;  /* WLR_SILENT */
			case 1: level_str = "error"; break;   /* WLR_ERROR */
			case 2: level_str = "info"; break;    /* WLR_INFO */
			case 3: level_str = "debug"; break;   /* WLR_DEBUG */
		}
		lua_pushstring(L, level_str);
		return 1;
	}

	/* Compositor behavior properties */
	if (A_STREQ(key, "bypass_surface_visibility")) {
		lua_pushboolean(L, globalconf.appearance.bypass_surface_visibility);
		return 1;
	}

	/* For other keys, do regular table lookup */
	lua_rawget(L, 1);
	return 1;
}

/** awesome.__newindex handler for property setting
 * Handles: keyboard settings, input settings
 */
static int
luaA_awesome_newindex(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	/* Logging properties */
	if (A_STREQ(key, "log_level")) {
		const char *val = luaL_checkstring(L, 3);
		int new_level = 1;  /* WLR_ERROR default */

		/* Convert string to wlroots log level enum */
		if (strcmp(val, "silent") == 0)      new_level = 0;  /* WLR_SILENT */
		else if (strcmp(val, "error") == 0)  new_level = 1;  /* WLR_ERROR */
		else if (strcmp(val, "info") == 0)   new_level = 2;  /* WLR_INFO */
		else if (strcmp(val, "debug") == 0)  new_level = 3;  /* WLR_DEBUG */

		globalconf.log_level = new_level;

		/* Apply new log level immediately */
		wlr_log_init(new_level, NULL);

		return 0;
	}

	/* Compositor behavior properties */
	if (A_STREQ(key, "bypass_surface_visibility")) {
		globalconf.appearance.bypass_surface_visibility = lua_toboolean(L, 3);
		return 0;
	}

	/* For other keys, do regular table set */
	lua_rawset(L, 1);
	return 0;
}

/** Setup the awesome Lua module
 * Registers the global 'awesome' table with compositor functions
 */
void
luaA_awesome_setup(lua_State *L)
{
	luaA_openlib(L, "awesome", awesome_methods, NULL);

	/* Set metatable for property access (AwesomeWM pattern) */
	lua_getglobal(L, "awesome");
	lua_newtable(L);  /* metatable */
	lua_pushcfunction(L, luaA_awesome_index);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, luaA_awesome_newindex);
	lua_setfield(L, -2, "__newindex");
	lua_setmetatable(L, -2);
	lua_pop(L, 1);  /* pop awesome table */

	/* Set up awesome._modifiers table for AwesomeWM compatibility
	 * Maps modifier names to XKB keysyms
	 * Format: { Shift = {{keysym=0xffe1}}, Control = {{keysym=0xffe3}}, ... }
	 */
	lua_getglobal(L, "awesome");

	lua_newtable(L);  /* _modifiers table */

	/* Shift modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe1);  /* XKB_KEY_Shift_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Shift");

	/* Control modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe3);  /* XKB_KEY_Control_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Control");

	/* Mod1 (Alt) modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffe9);  /* XKB_KEY_Alt_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod1");

	/* Mod4 (Super/Logo) modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xffeb);  /* XKB_KEY_Super_L */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod4");

	/* Mod5 modifier */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushnumber(L, 0xfe03);  /* XKB_KEY_ISO_Level3_Shift */
	lua_setfield(L, -2, "keysym");
	lua_rawseti(L, -2, 1);
	lua_setfield(L, -2, "Mod5");

	lua_setfield(L, -2, "_modifiers");

	/* awesome._active_modifiers - initially empty, will be updated by C code
	 * This is a read-only property that returns currently pressed modifiers
	 */
	lua_newtable(L);
	lua_setfield(L, -2, "_active_modifiers");

	/* awesome.api_level - AwesomeWM API compatibility level
	 * Version 5+ enables properties by default on widgets
	 */
	lua_pushnumber(L, 5);
	lua_setfield(L, -2, "api_level");

	/* awesome.composite_manager_running - indicates if compositing is active
	 * Always true for a Wayland compositor (we are the compositor)
	 */
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "composite_manager_running");

	/* awesome.themes_path - path to theme directory
	 * Used by gears.filesystem.get_themes_dir()
	 * NOTE: Do NOT include trailing slash - Lua adds it
	 */
	lua_pushstring(L, DATADIR "/somewm/themes");
	lua_setfield(L, -2, "themes_path");

	/* awesome.conffile - path to loaded config file
	 * Would be set to actual loaded config path, for now use placeholder
	 */
	lua_pushstring(L, "");
	lua_setfield(L, -2, "conffile");

	/* NOTE: awesome.startup_errors is accessed dynamically via __index handler
	 * (luaA_awesome_index). Do NOT set it statically here - a static field
	 * would shadow the __index metamethod, preventing dynamic access to
	 * errors accumulated after Lua init. This matches AwesomeWM's pattern. */

	lua_pop(L, 1);  /* pop awesome table */
}

/** Set the conffile path in awesome.conffile
 * Called after successfully loading a config file
 * \param L Lua state
 * \param conffile Path to the loaded config file
 */
void
luaA_awesome_set_conffile(lua_State *L, const char *conffile)
{
	lua_getglobal(L, "awesome");
	lua_pushstring(L, conffile);
	lua_setfield(L, -2, "conffile");
	lua_pop(L, 1);  /* pop awesome table */
}
