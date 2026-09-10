/*
 * input_method.h - text-input-v3 / input-method-v2 relay for somewm
 *
 * The relay manages the relationship between the text-input and input-method
 * interfaces on somewm's seat. Any number of text-input objects may be bound,
 * but at most one is focused (receiving events) at a time; at most one
 * input-method may be bound. When both sides are present and focused, the
 * relay passes messages between them.
 *
 * Text input focus is a subset of keyboard focus: a focused text-input implies
 * wl_keyboard sent an enter, but keyboard focus does not imply text input
 * focus. Focus is tracked off seat->keyboard_state.events.focus_change rather
 * than from focusclient() and friends, since somewm sets keyboard focus from a
 * dozen call sites across focus.c, window.c, somewm_api.c and objects/client.c.
 *
 * Modelled on sway's sway/input/text_input.c, adapted for somewm's single seat,
 * keyboard groups, and per-parent popup scene trees.
 */

#ifndef SOMEWM_INPUT_METHOD_H
#define SOMEWM_INPUT_METHOD_H

#include <wayland-server-core.h>
#include <wlr/types/wlr_input_method_v2.h>
#include <wlr/types/wlr_text_input_v3.h>

#include "somewm_types.h"

/* One text-input object bound by a client. */
typedef struct {
	struct wlr_text_input_v3 *input;
	/* Surface that holds seat focus, stored for when the text-input cannot be
	 * sent an enter immediately - e.g. no input method is running yet. Cleared
	 * once the text-input has been entered. */
	struct wlr_surface *pending_focused_surface;

	struct wl_list link; /* InputMethodRelay.text_inputs */

	struct wl_listener pending_focused_surface_destroy;
	struct wl_listener enable;
	struct wl_listener commit;
	struct wl_listener disable;
	struct wl_listener destroy;
} TextInput;

/* One candidate/preedit popup surface owned by the input method. */
typedef struct {
	/* Popup scene tree, parented under the focused surface's popups tree
	 * (client_t::popups or LayerSurface::popups) so it follows the parent and
	 * escapes the parent's content clip. NULL until the surface is focused. */
	struct wlr_scene_tree *scene_tree;
	struct wlr_input_popup_surface_v2 *popup_surface;
	struct wlr_surface *focused_surface;

	struct wl_list link; /* InputMethodRelay.popups */

	struct wl_listener destroy;
	struct wl_listener surface_commit;
	struct wl_listener surface_map;
	struct wl_listener surface_unmap;
	struct wl_listener focused_surface_unmap;
} InputPopup;

typedef struct {
	struct wl_list text_inputs; /* TextInput.link */
	struct wl_list popups;      /* InputPopup.link */
	struct wlr_input_method_v2 *input_method; /* may be NULL */

	struct wl_listener new_text_input;
	struct wl_listener text_input_manager_destroy;
	struct wl_listener new_input_method;
	struct wl_listener input_method_manager_destroy;

	struct wl_listener im_commit;
	struct wl_listener im_grab_keyboard;
	struct wl_listener im_new_popup_surface;
	struct wl_listener im_destroy;
	struct wl_listener im_keyboard_grab_destroy;

	struct wl_listener seat_focus_change;
} InputMethodRelay;

extern InputMethodRelay im_relay;
extern struct wlr_text_input_manager_v3 *text_input_mgr;
extern struct wlr_input_method_manager_v2 *input_method_mgr;

/* Called from setup() after the seat exists. Creates both managers and wires
 * the relay to them and to seat keyboard focus changes. */
void input_method_relay_init(void);

/* Called from cleanup() before the display is destroyed. */
void input_method_relay_finish(void);

/* Returns the input method's keyboard grab if this keyboard group's events
 * should be routed to the input method instead of the focused client, or NULL
 * if they should go to the client as usual. Returns NULL for the input
 * method's own virtual keyboard, which would otherwise loop events back into
 * the IME that generated them. */
struct wlr_input_method_keyboard_grab_v2 *input_method_get_keyboard_grab(
		KeyboardGroup *group);

#endif /* SOMEWM_INPUT_METHOD_H */
