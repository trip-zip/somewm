/*
 * input_method.c - text-input-v3 / input-method-v2 relay for somewm
 *
 * See input_method.h for the design. Adapted from sway/input/text_input.c.
 */
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_input_method_v2.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_text_input_v3.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/box.h>
#ifdef XWAYLAND
#include <wlr/xwayland.h>
#endif

#include "somewm.h"
#include "client.h"
#include "input_method.h"
#include "objects/client.h"
#include "common/util.h"
#include "wlr_compat.h"

InputMethodRelay im_relay;
struct wlr_text_input_manager_v3 *text_input_mgr;
struct wlr_input_method_manager_v2 *input_method_mgr;

static void input_popup_set_focus(InputPopup *popup, struct wlr_surface *surface);

static TextInput *
relay_get_focused_text_input(void)
{
	TextInput *text_input;
	wl_list_for_each(text_input, &im_relay.text_inputs, link) {
		if (text_input->input->focused_surface)
			return text_input;
	}
	return NULL;
}

static TextInput *
relay_get_focusable_text_input(void)
{
	TextInput *text_input;
	wl_list_for_each(text_input, &im_relay.text_inputs, link) {
		if (text_input->pending_focused_surface)
			return text_input;
	}
	return NULL;
}

/* Resolve the scene tree an IME popup should hang off for a focused surface.
 * Both client_t and LayerSurface carry a popups tree that tracks the parent's
 * position and is exempt from its content clip, which is exactly what a
 * candidate window needs. Returns NULL for surfaces we cannot anchor to. */
static struct wlr_scene_tree *
popup_parent_tree(struct wlr_surface *surface)
{
	Client *c = NULL;
	LayerSurface *l = NULL;

	switch (toplevel_from_wlr_surface(surface, &c, &l)) {
	case LayerShell:
		return l ? l->popups : NULL;
	case XDGShell:
	case X11:
		return c ? c->popups : NULL;
	default:
		return NULL;
	}
}

/* Position popup->scene_tree at the text cursor, flipped to stay on screen.
 * The cursor rectangle is surface-local, and the popups tree it is parented to
 * shares the surface's origin, so the rectangle needs no translation. */
static void
constrain_popup(InputPopup *popup)
{
	TextInput *text_input;
	struct wlr_box cursor_area, output_box;
	struct wlr_output *output;
	struct wlr_scene_tree *parent;
	int parent_lx = 0, parent_ly = 0;
	int popup_width, popup_height;
	int x1, x2, y1, y2, x, y;
	int available_right, available_left, available_down, available_up;
	bool has_cursor_rect;

	if (!popup->scene_tree || !popup->focused_surface)
		return;
	if (!(text_input = relay_get_focused_text_input()))
		return;

	parent = popup->scene_tree->node.parent;
	if (!parent)
		return;
	wlr_scene_node_coords(&parent->node, &parent_lx, &parent_ly);

	has_cursor_rect = text_input->input->current.features
			& WLR_TEXT_INPUT_V3_FEATURE_CURSOR_RECTANGLE;
	if (has_cursor_rect) {
		cursor_area = text_input->input->current.cursor_rectangle;
	} else {
		/* No cursor rectangle: anchor to the whole parent surface */
		cursor_area = (struct wlr_box){
			.x = 0, .y = 0,
			.width = popup->focused_surface->current.width,
			.height = popup->focused_surface->current.height,
		};
	}

	popup_width = popup->popup_surface->surface->current.width;
	popup_height = popup->popup_surface->surface->current.height;

	/* Layout-space edges of the cursor rectangle */
	x1 = parent_lx + cursor_area.x;
	x2 = x1 + cursor_area.width;
	y1 = parent_ly + cursor_area.y;
	y2 = y1 + cursor_area.height;

	/* Default: left-aligned with the cursor, below it */
	x = x1;
	y = y2;

	output = wlr_output_layout_output_at(output_layout, x1, y1);
	if (output) {
		wlr_output_layout_get_box(output_layout, output, &output_box);

		available_right = output_box.x + output_box.width - x1;
		available_left = x2 - output_box.x;
		if (available_right < popup_width && available_left > available_right)
			x = x2 - popup_width;

		available_down = output_box.y + output_box.height - y2;
		available_up = y1 - output_box.y;
		if (available_down < popup_height && available_up > available_down)
			y = y1 - popup_height;
	}

	wlr_scene_node_set_position(&popup->scene_tree->node,
			x - parent_lx, y - parent_ly);

	if (has_cursor_rect) {
		struct wlr_box rect = {
			.x = x1 - x,
			.y = y1 - y,
			.width = cursor_area.width,
			.height = cursor_area.height,
		};
		wlr_input_popup_surface_v2_send_text_input_rectangle(
				popup->popup_surface, &rect);
	}
}

static void
input_popup_destroy_scene_tree(InputPopup *popup)
{
	if (popup->scene_tree) {
		wlr_scene_node_destroy(&popup->scene_tree->node);
		popup->scene_tree = NULL;
	}
}

static void
handle_focused_surface_unmap(struct wl_listener *listener, void *data)
{
	InputPopup *popup = wl_container_of(listener, popup, focused_surface_unmap);
	input_popup_set_focus(popup, NULL);
}

/* Re-parent a popup onto a newly focused surface, or tear it down for NULL.
 * Called on every text-input commit via relay_send_im_state(), so unchanged
 * focus must not rebuild the scene tree - that would thrash the subsurface
 * tree on every keystroke. */
static void
input_popup_set_focus(InputPopup *popup, struct wlr_surface *surface)
{
	struct wlr_scene_tree *parent;

	if (surface && surface == popup->focused_surface && popup->scene_tree) {
		constrain_popup(popup);
		return;
	}

	wl_list_remove(&popup->focused_surface_unmap.link);
	wl_list_init(&popup->focused_surface_unmap.link);

	input_popup_destroy_scene_tree(popup);
	popup->focused_surface = NULL;

	if (!surface || !popup->popup_surface->surface->mapped)
		return;

	if (!(parent = popup_parent_tree(surface))) {
		log_debug("input-method: unsupported IME focus surface");
		return;
	}

	if (!(popup->scene_tree = wlr_scene_tree_create(parent))) {
		log_error("input-method: failed to allocate popup scene tree");
		return;
	}
	if (!wlr_scene_subsurface_tree_create(popup->scene_tree,
			popup->popup_surface->surface)) {
		log_error("input-method: failed to allocate popup subsurface tree");
		input_popup_destroy_scene_tree(popup);
		return;
	}

	popup->focused_surface = surface;
	wl_signal_add(&surface->events.unmap, &popup->focused_surface_unmap);

	constrain_popup(popup);
}

static void
input_popup_update_focus(InputPopup *popup)
{
	TextInput *text_input = relay_get_focused_text_input();
	input_popup_set_focus(popup,
			text_input ? text_input->input->focused_surface : NULL);
}

static void
handle_popup_surface_map(struct wl_listener *listener, void *data)
{
	InputPopup *popup = wl_container_of(listener, popup, surface_map);
	input_popup_update_focus(popup);
}

static void
handle_popup_surface_unmap(struct wl_listener *listener, void *data)
{
	InputPopup *popup = wl_container_of(listener, popup, surface_unmap);
	input_popup_set_focus(popup, NULL);
}

static void
handle_popup_surface_commit(struct wl_listener *listener, void *data)
{
	InputPopup *popup = wl_container_of(listener, popup, surface_commit);
	constrain_popup(popup);
}

static void
handle_popup_destroy(struct wl_listener *listener, void *data)
{
	InputPopup *popup = wl_container_of(listener, popup, destroy);

	input_popup_destroy_scene_tree(popup);
	wl_list_remove(&popup->focused_surface_unmap.link);
	wl_list_remove(&popup->surface_commit.link);
	wl_list_remove(&popup->surface_map.link);
	wl_list_remove(&popup->surface_unmap.link);
	wl_list_remove(&popup->destroy.link);
	wl_list_remove(&popup->link);
	free(popup);
}

static void
handle_im_new_popup_surface(struct wl_listener *listener, void *data)
{
	struct wlr_input_popup_surface_v2 *popup_surface = data;
	InputPopup *popup = ecalloc(1, sizeof(*popup));

	popup->popup_surface = popup_surface;
	popup_surface->data = popup;

	LISTEN(&popup_surface->events.destroy, &popup->destroy, handle_popup_destroy);
	LISTEN(&popup_surface->surface->events.commit, &popup->surface_commit,
			handle_popup_surface_commit);
	LISTEN(&popup_surface->surface->events.map, &popup->surface_map,
			handle_popup_surface_map);
	LISTEN(&popup_surface->surface->events.unmap, &popup->surface_unmap,
			handle_popup_surface_unmap);

	popup->focused_surface_unmap.notify = handle_focused_surface_unmap;
	wl_list_init(&popup->focused_surface_unmap.link);

	wl_list_insert(&im_relay.popups, &popup->link);
	input_popup_update_focus(popup);
}

/* Forward the text-input's current state to the input method. */
static void
relay_send_im_state(struct wlr_text_input_v3 *input)
{
	struct wlr_input_method_v2 *input_method = im_relay.input_method;
	TextInput *text_input;
	InputPopup *popup;

	if (!input_method) {
		log_debug("input-method: sending state but no input method bound");
		return;
	}

	if (input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT)
		wlr_input_method_v2_send_surrounding_text(input_method,
				input->current.surrounding.text,
				input->current.surrounding.cursor,
				input->current.surrounding.anchor);

	wlr_input_method_v2_send_text_change_cause(input_method,
			input->current.text_change_cause);

	if (input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE)
		wlr_input_method_v2_send_content_type(input_method,
				input->current.content_type.hint,
				input->current.content_type.purpose);

	text_input = relay_get_focused_text_input();
	wl_list_for_each(popup, &im_relay.popups, link)
		input_popup_set_focus(popup,
				text_input ? text_input->input->focused_surface : NULL);

	wlr_input_method_v2_send_done(input_method);
}

static void
relay_disable_text_input(TextInput *text_input)
{
	if (!im_relay.input_method) {
		log_debug("input-method: disabling text input but no input method bound");
		return;
	}
	wlr_input_method_v2_send_deactivate(im_relay.input_method);
	relay_send_im_state(text_input->input);
}

/* Deliver the input method's committed state back to the focused text-input. */
static void
handle_im_commit(struct wl_listener *listener, void *data)
{
	struct wlr_input_method_v2 *input_method = im_relay.input_method;
	TextInput *text_input = relay_get_focused_text_input();

	if (!text_input)
		return;

	if (input_method->current.preedit.text)
		wlr_text_input_v3_send_preedit_string(text_input->input,
				input_method->current.preedit.text,
				input_method->current.preedit.cursor_begin,
				input_method->current.preedit.cursor_end);

	if (input_method->current.commit_text)
		wlr_text_input_v3_send_commit_string(text_input->input,
				input_method->current.commit_text);

	if (input_method->current.delete.before_length
			|| input_method->current.delete.after_length)
		wlr_text_input_v3_send_delete_surrounding_text(text_input->input,
				input_method->current.delete.before_length,
				input_method->current.delete.after_length);

	wlr_text_input_v3_send_done(text_input->input);
}

static void
handle_im_keyboard_grab_destroy(struct wl_listener *listener, void *data)
{
	/* wlroots emits this signal with NULL data, despite wlr_input_method_v2.h
	 * annotating it "struct wlr_input_method_keyboard_grab_v2". Take the grab
	 * from the input method instead; the input method itself may already be
	 * gone if the grab is being torn down as part of its destruction. */
	struct wlr_input_method_keyboard_grab_v2 *keyboard_grab =
			im_relay.input_method ? im_relay.input_method->keyboard_grab : NULL;

	wl_list_remove(&im_relay.im_keyboard_grab_destroy.link);
	wl_list_init(&im_relay.im_keyboard_grab_destroy.link);

	/* Hand the modifier state back to the client that lost it to the grab */
	if (keyboard_grab && keyboard_grab->keyboard) {
		wlr_seat_set_keyboard(seat, keyboard_grab->keyboard);
		wlr_seat_keyboard_notify_modifiers(seat,
				&keyboard_grab->keyboard->modifiers);
	}
}

static void
handle_im_grab_keyboard(struct wl_listener *listener, void *data)
{
	struct wlr_input_method_keyboard_grab_v2 *keyboard_grab = data;

	wlr_input_method_keyboard_grab_v2_set_keyboard(keyboard_grab,
			wlr_seat_get_keyboard(seat));

	LISTEN(&keyboard_grab->events.destroy, &im_relay.im_keyboard_grab_destroy,
			handle_im_keyboard_grab_destroy);
}

static void
text_input_set_pending_focused_surface(TextInput *text_input,
		struct wlr_surface *surface)
{
	wl_list_remove(&text_input->pending_focused_surface_destroy.link);
	text_input->pending_focused_surface = surface;

	if (surface)
		wl_signal_add(&surface->events.destroy,
				&text_input->pending_focused_surface_destroy);
	else
		wl_list_init(&text_input->pending_focused_surface_destroy.link);
}

static void
handle_im_destroy(struct wl_listener *listener, void *data)
{
	TextInput *text_input;

	wl_list_remove(&im_relay.im_commit.link);
	wl_list_remove(&im_relay.im_grab_keyboard.link);
	wl_list_remove(&im_relay.im_new_popup_surface.link);
	wl_list_remove(&im_relay.im_destroy.link);
	im_relay.input_method = NULL;

	if ((text_input = relay_get_focused_text_input())) {
		/* Keyboard focus is unchanged, so hold on to the surface in case an
		 * input method comes back */
		text_input_set_pending_focused_surface(text_input,
				text_input->input->focused_surface);
		wlr_text_input_v3_send_leave(text_input->input);
	}
}

static void
text_input_send_enter(TextInput *text_input, struct wlr_surface *surface)
{
	InputPopup *popup;

	wlr_text_input_v3_send_enter(text_input->input, surface);
	wl_list_for_each(popup, &im_relay.popups, link)
		input_popup_set_focus(popup, surface);
}

static void
handle_text_input_enable(struct wl_listener *listener, void *data)
{
	TextInput *text_input = wl_container_of(listener, text_input, enable);

	if (!text_input->input->focused_surface) {
		log_debug("input-method: text input enabled but no longer focused");
		return;
	}
	if (!im_relay.input_method) {
		log_debug("input-method: text input enabled but no input method bound");
		return;
	}
	wlr_input_method_v2_send_activate(im_relay.input_method);
	relay_send_im_state(text_input->input);
}

static void
handle_text_input_commit(struct wl_listener *listener, void *data)
{
	TextInput *text_input = wl_container_of(listener, text_input, commit);

	if (!text_input->input->focused_surface) {
		log_debug("input-method: unfocused text input tried to commit");
		return;
	}
	if (!text_input->input->current_enabled) {
		log_debug("input-method: inactive text input tried to commit");
		return;
	}
	if (!im_relay.input_method) {
		log_debug("input-method: text input committed but no input method bound");
		return;
	}
	relay_send_im_state(text_input->input);
}

static void
handle_text_input_disable(struct wl_listener *listener, void *data)
{
	TextInput *text_input = wl_container_of(listener, text_input, disable);

	if (!text_input->input->focused_surface) {
		log_debug("input-method: text input disabled but no longer focused");
		return;
	}
	relay_disable_text_input(text_input);
}

static void
handle_text_input_destroy(struct wl_listener *listener, void *data)
{
	TextInput *text_input = wl_container_of(listener, text_input, destroy);

	if (text_input->input->current_enabled)
		relay_disable_text_input(text_input);

	/* Also unlinks pending_focused_surface_destroy */
	text_input_set_pending_focused_surface(text_input, NULL);
	wl_list_remove(&text_input->enable.link);
	wl_list_remove(&text_input->commit.link);
	wl_list_remove(&text_input->disable.link);
	wl_list_remove(&text_input->destroy.link);
	wl_list_remove(&text_input->link);
	free(text_input);
}

static void
handle_pending_focused_surface_destroy(struct wl_listener *listener, void *data)
{
	TextInput *text_input = wl_container_of(listener, text_input,
			pending_focused_surface_destroy);

	text_input->pending_focused_surface = NULL;
	wl_list_remove(&text_input->pending_focused_surface_destroy.link);
	wl_list_init(&text_input->pending_focused_surface_destroy.link);
}

static void
relay_handle_new_text_input(struct wl_listener *listener, void *data)
{
	struct wlr_text_input_v3 *wlr_text_input = data;
	TextInput *text_input;

	if (wlr_text_input->seat != seat)
		return;

	text_input = ecalloc(1, sizeof(*text_input));
	text_input->input = wlr_text_input;
	wl_list_insert(&im_relay.text_inputs, &text_input->link);

	LISTEN(&wlr_text_input->events.enable, &text_input->enable,
			handle_text_input_enable);
	LISTEN(&wlr_text_input->events.commit, &text_input->commit,
			handle_text_input_commit);
	LISTEN(&wlr_text_input->events.disable, &text_input->disable,
			handle_text_input_disable);
	LISTEN(&wlr_text_input->events.destroy, &text_input->destroy,
			handle_text_input_destroy);

	text_input->pending_focused_surface_destroy.notify =
			handle_pending_focused_surface_destroy;
	wl_list_init(&text_input->pending_focused_surface_destroy.link);
}

static void
relay_handle_new_input_method(struct wl_listener *listener, void *data)
{
	struct wlr_input_method_v2 *input_method = data;
	TextInput *text_input;

	if (input_method->seat != seat)
		return;

	if (im_relay.input_method) {
		log_info("input-method: refusing a second input method on the seat");
		wlr_input_method_v2_send_unavailable(input_method);
		return;
	}

	im_relay.input_method = input_method;
	LISTEN(&input_method->events.commit, &im_relay.im_commit, handle_im_commit);
	LISTEN(&input_method->events.grab_keyboard, &im_relay.im_grab_keyboard,
			handle_im_grab_keyboard);
	LISTEN(&input_method->events.new_popup_surface,
			&im_relay.im_new_popup_surface, handle_im_new_popup_surface);
	LISTEN(&input_method->events.destroy, &im_relay.im_destroy, handle_im_destroy);

	/* A text-input may have been waiting for an input method to appear */
	if ((text_input = relay_get_focusable_text_input())) {
		text_input_send_enter(text_input, text_input->pending_focused_surface);
		text_input_set_pending_focused_surface(text_input, NULL);
	}
}

/* Track keyboard focus for every path that sets it. somewm calls
 * wlr_seat_keyboard_notify_enter() from focus.c, window.c, somewm_api.c,
 * client.h and objects/client.c, so hook the seat's own signal rather than
 * each of those sites. */
static void
relay_handle_seat_focus_change(struct wl_listener *listener, void *data)
{
	struct wlr_seat_keyboard_focus_change_event *event = data;
	struct wlr_surface *surface = event->new_surface;
	TextInput *text_input;

	wl_list_for_each(text_input, &im_relay.text_inputs, link) {
		if (text_input->pending_focused_surface) {
			if (surface != text_input->pending_focused_surface)
				text_input_set_pending_focused_surface(text_input, NULL);
		} else if (text_input->input->focused_surface) {
			if (surface == text_input->input->focused_surface)
				continue;
			wlr_text_input_v3_send_leave(text_input->input);
			relay_disable_text_input(text_input);
		}

		if (surface && wl_resource_get_client(text_input->input->resource)
				== wl_resource_get_client(surface->resource)) {
			if (im_relay.input_method)
				text_input_send_enter(text_input, surface);
			else
				text_input_set_pending_focused_surface(text_input, surface);
		}
	}
}

static void
relay_finish_text_input_manager(struct wl_listener *listener, void *data)
{
	wl_list_remove(&im_relay.new_text_input.link);
	wl_list_remove(&im_relay.text_input_manager_destroy.link);
	wl_list_init(&im_relay.new_text_input.link);
	wl_list_init(&im_relay.text_input_manager_destroy.link);
	text_input_mgr = NULL;
}

static void
relay_finish_input_method_manager(struct wl_listener *listener, void *data)
{
	wl_list_remove(&im_relay.new_input_method.link);
	wl_list_remove(&im_relay.input_method_manager_destroy.link);
	wl_list_init(&im_relay.new_input_method.link);
	wl_list_init(&im_relay.input_method_manager_destroy.link);
	input_method_mgr = NULL;
}

struct wlr_input_method_keyboard_grab_v2 *
input_method_get_keyboard_grab(KeyboardGroup *group)
{
	struct wlr_input_method_v2 *input_method = im_relay.input_method;

	if (!input_method || !input_method->keyboard_grab)
		return NULL;

	/* Never route the input method's own virtual keyboard back into it:
	 * somewm gives each virtual keyboard its own group, so the originating
	 * client is recorded on the group. */
	if (group->virtual_keyboard
			&& wl_resource_get_client(group->virtual_keyboard->resource)
			== wl_resource_get_client(input_method->keyboard_grab->resource))
		return NULL;

	return input_method->keyboard_grab;
}

void
input_method_relay_init(void)
{
	wl_list_init(&im_relay.text_inputs);
	wl_list_init(&im_relay.popups);
	wl_list_init(&im_relay.im_keyboard_grab_destroy.link);

	text_input_mgr = wlr_text_input_manager_v3_create(dpy);
	input_method_mgr = wlr_input_method_manager_v2_create(dpy);

	LISTEN(COMPAT_TEXT_INPUT_MANAGER_NEW(text_input_mgr),
			&im_relay.new_text_input, relay_handle_new_text_input);
	LISTEN(&text_input_mgr->events.destroy,
			&im_relay.text_input_manager_destroy, relay_finish_text_input_manager);

	LISTEN(COMPAT_INPUT_METHOD_MANAGER_NEW(input_method_mgr),
			&im_relay.new_input_method, relay_handle_new_input_method);
	LISTEN(&input_method_mgr->events.destroy,
			&im_relay.input_method_manager_destroy,
			relay_finish_input_method_manager);

	LISTEN(&seat->keyboard_state.events.focus_change,
			&im_relay.seat_focus_change, relay_handle_seat_focus_change);
}

void
input_method_relay_finish(void)
{
	wl_list_remove(&im_relay.seat_focus_change.link);
	if (text_input_mgr)
		relay_finish_text_input_manager(NULL, NULL);
	if (input_method_mgr)
		relay_finish_input_method_manager(NULL, NULL);
}
