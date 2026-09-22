/*
 * input.h - Input handling for somewm compositor
 *
 * Keyboard, pointer, gestures, pointer constraints, input device
 * management, hit testing, and cursor helpers.
 */
#ifndef INPUT_H
#define INPUT_H

#include "somewm_types.h"
#include <stdbool.h>
#include <stdint.h>
#include <xkbcommon/xkbcommon.h>

struct wl_listener;
struct wlr_box;
struct wlr_input_device;
struct wlr_keyboard;
struct wlr_pointer;
struct wlr_pointer_constraint_v1;
struct wlr_surface;
struct libinput_device;
typedef struct drawin_t drawin_t;
typedef struct drawable_t drawable_t;

/* Pointer/cursor */
void axisnotify(struct wl_listener *listener, void *data);
void buttonpress(struct wl_listener *listener, void *data);
void cursorframe(struct wl_listener *listener, void *data);
void motionnotify(uint32_t time, struct wlr_input_device *device,
		double dx, double dy, double dx_unaccel, double dy_unaccel);
void motionrelative(struct wl_listener *listener, void *data);
void motionabsolute(struct wl_listener *listener, void *data);
void pointerfocus(Client *c, struct wlr_surface *surface,
		double sx, double sy, uint32_t time);

/* The pointer image: what the seat shows at the pointer. declare_cursor()
 * declares it as a leaf of the output under the pointer; nothing sets an
 * image on the wlr_cursor, so wlroots paints no cursor of its own. A themed
 * name, or a client's cursor surface with its hotspot, or neither while a
 * client hides the pointer. gen counts every change, so an output's copy of
 * a themed image is rebuilt when the theme is. */
struct cursor_image {
	char *name;
	struct wlr_surface *surface;
	/* The surface's scene tree, born parked and borrowed by the output
	 * that declares it (its declare handle is the surface); NULL again
	 * once wlroots destroyed it with the surface. */
	struct wlr_scene_tree *tree;
	void *render_owner;
	int hotspot_x, hotspot_y;
	uint64_t gen;
	struct wl_listener surface_destroy, surface_commit;
};
extern struct cursor_image cursor_image;
void cursor_set_xcursor(const char *name);
void cursor_set_surface(struct wlr_surface *surface, int hotspot_x, int hotspot_y);

/* Keyboard */
int keybinding(uint32_t mods, uint32_t keycode, xkb_keysym_t sym,
		xkb_keysym_t base_sym, bool is_keypress);
void keypress(struct wl_listener *listener, void *data);
void keypressmod(struct wl_listener *listener, void *data);
int keyrepeat(void *data);

/* Pointer constraints */
void createpointerconstraint(struct wl_listener *listener, void *data);
void destroypointerconstraint(struct wl_listener *listener, void *data);
void cursorconstrain(struct wlr_pointer_constraint_v1 *constraint);
void cursorwarptohint(void);

/* Input device management */
void inputdevice(struct wl_listener *listener, void *data);
void createpointer(struct wlr_pointer *pointer);
void createkeyboard(struct wlr_keyboard *keyboard);
KeyboardGroup *createkeyboardgroup(void);
void destroykeyboardgroup(struct wl_listener *listener, void *data);
void apply_input_settings_to_all_devices(void);
void virtualkeyboard(struct wl_listener *listener, void *data);
void virtualpointer(struct wl_listener *listener, void *data);

/* Hit testing */
void xytonode(double x, double y, struct wlr_surface **psurface,
		Client **pc, LayerSurface **pl, drawin_t **pd, drawable_t **pdrawable,
		double *nx, double *ny);
bool drawin_accepts_input_at(drawin_t *d, double local_x, double local_y);

/* Cursor helpers */
void setcursor(struct wl_listener *listener, void *data);
void setcursorshape(struct wl_listener *listener, void *data);

/* Listener structs (registered in setup(), defined in input.c) */
extern struct wl_listener cursor_axis;
extern struct wl_listener cursor_button;
extern struct wl_listener cursor_frame;
extern struct wl_listener cursor_motion;
extern struct wl_listener cursor_motion_absolute;
extern struct wl_listener new_input_device;
extern struct wl_listener new_virtual_keyboard;
extern struct wl_listener new_virtual_pointer;
extern struct wl_listener new_pointer_constraint;
extern struct wl_listener gesture_swipe_begin;
extern struct wl_listener gesture_swipe_update;
extern struct wl_listener gesture_swipe_end;
extern struct wl_listener gesture_pinch_begin;
extern struct wl_listener gesture_pinch_update;
extern struct wl_listener gesture_pinch_end;
extern struct wl_listener gesture_hold_begin;
extern struct wl_listener gesture_hold_end;

/* Request listeners (registered in setup()) */
extern struct wl_listener request_cursor;
extern struct wl_listener request_set_psel;
extern struct wl_listener request_set_sel;
extern struct wl_listener request_set_cursor_shape;
extern struct wl_listener request_start_drag;
extern struct wl_listener start_drag;

#endif /* INPUT_H */
