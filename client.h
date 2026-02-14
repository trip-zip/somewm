/*
 * client.h - XWayland/XDG client abstraction layer
 *
 * Static inline functions for client operations that differ between XWayland
 * and native XDG clients. Using inline functions allows unused code paths to
 * compile out when XWAYLAND is not defined.
 */

/* Need complete client_t definition for inline functions */
#include <assert.h>
#include "somewm_types.h"  /* For Client typedef and Monitor */
#include "objects/client.h" /* For complete client_t definition */
#include "wlr_compat.h"  /* For wlroots version compatibility */
#include "common/util.h"  /* For log_debug */

/* Leave these functions first; they're used in the others */
static inline int
client_is_x11(Client *c)
{
#ifdef XWAYLAND
	return c->client_type == X11;
#endif
	return 0;
}

static inline struct wlr_surface *
client_surface(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		assert(c->surface.xwayland != NULL);
		return c->surface.xwayland->surface;
	}
#endif
	assert(c->surface.xdg != NULL);
	return c->surface.xdg->surface;
}

static inline int
toplevel_from_wlr_surface(struct wlr_surface *s, Client **pc, LayerSurface **pl)
{
	struct wlr_xdg_surface *xdg_surface, *tmp_xdg_surface;
	struct wlr_surface *root_surface;
	struct wlr_layer_surface_v1 *layer_surface;
	Client *c = NULL;
	LayerSurface *l = NULL;
	int type = -1;
#ifdef XWAYLAND
	struct wlr_xwayland_surface *xsurface;
#endif

	if (!s)
		return -1;
	root_surface = wlr_surface_get_root_surface(s);

#ifdef XWAYLAND
	if ((xsurface = wlr_xwayland_surface_try_from_wlr_surface(root_surface))) {
		c = xsurface->data;
		type = c->client_type;
		goto end;
	}
#endif

	if ((layer_surface = wlr_layer_surface_v1_try_from_wlr_surface(root_surface))) {
		l = layer_surface->data;
		type = LayerShell;
		goto end;
	}

	xdg_surface = wlr_xdg_surface_try_from_wlr_surface(root_surface);
	while (xdg_surface) {
		tmp_xdg_surface = NULL;
		switch (xdg_surface->role) {
		case WLR_XDG_SURFACE_ROLE_POPUP:
			if (!xdg_surface->popup || !xdg_surface->popup->parent)
				return -1;

			tmp_xdg_surface = wlr_xdg_surface_try_from_wlr_surface(xdg_surface->popup->parent);

			if (!tmp_xdg_surface)
				return toplevel_from_wlr_surface(xdg_surface->popup->parent, pc, pl);

			xdg_surface = tmp_xdg_surface;
			break;
		case WLR_XDG_SURFACE_ROLE_TOPLEVEL:
			c = xdg_surface->data;
			type = c->client_type;
			goto end;
		case WLR_XDG_SURFACE_ROLE_NONE:
			return -1;
		}
	}

end:
	if (pl)
		*pl = l;
	if (pc)
		*pc = c;
	return type;
}

/* The others */
static inline void
client_activate_surface(struct wlr_surface *s, int activated)
{
	struct wlr_xdg_toplevel *toplevel;
#ifdef XWAYLAND
	struct wlr_xwayland_surface *xsurface;
#endif
	if (!s) {
		wlr_log(WLR_DEBUG, "[FOCUS-ACTIVATE] surface=NULL, skipping");
		return;
	}
#ifdef XWAYLAND
	if ((xsurface = wlr_xwayland_surface_try_from_wlr_surface(s))) {
		wlr_log(WLR_DEBUG, "[FOCUS-ACTIVATE] X11 surface=%p activated=%d title=%s",
			(void*)s, activated, xsurface->title ? xsurface->title : "?");
		wlr_xwayland_surface_activate(xsurface, activated);
		return;
	}
#endif
	if ((toplevel = wlr_xdg_toplevel_try_from_wlr_surface(s))) {
		wlr_log(WLR_DEBUG, "[FOCUS-ACTIVATE] XDG surface=%p activated=%d title=%s",
			(void*)s, activated, toplevel->title ? toplevel->title : "?");
		wlr_xdg_toplevel_set_activated(toplevel, activated);
	}
}

static inline uint32_t
client_set_bounds(Client *c, int32_t width, int32_t height)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return 0;
#endif
	if (wl_resource_get_version(c->surface.xdg->toplevel->resource) >=
			XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION && width >= 0 && height >= 0
			&& (c->bounds.width != width || c->bounds.height != height)) {
		c->bounds.width = width;
		c->bounds.height = height;
		return wlr_xdg_toplevel_set_bounds(c->surface.xdg->toplevel, width, height);
	}
	return 0;
}

static inline const char *
client_get_appid(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return c->surface.xwayland->class ? c->surface.xwayland->class : "broken";
#endif
	return c->surface.xdg->toplevel->app_id ? c->surface.xdg->toplevel->app_id : "broken";
}

static inline void
client_get_clip(Client *c, struct wlr_box *clip)
{
	/* Clip must match the content area: geometry minus borders AND titlebars.
	 * The surface node is positioned at (bw + tl, bw + tt) in the parent,
	 * so clip dimensions must be the content size to prevent the surface
	 * from bleeding past the bottom/right borders. */
	int tl = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
	int tt = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;
	int tr = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_RIGHT].size;
	int tb = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_BOTTOM].size;
	int cw = c->geometry.width - 2 * c->bw - tl - tr;
	int ch = c->geometry.height - 2 * c->bw - tt - tb;
	if (cw < 1) cw = 1;
	if (ch < 1) ch = 1;

	*clip = (struct wlr_box){
		.x = 0,
		.y = 0,
		.width = cw,
		.height = ch,
	};

#ifdef XWAYLAND
	if (client_is_x11(c))
		return;
#endif

	clip->x = COMPAT_XDG_SURFACE_GEOMETRY(c->surface.xdg).x;
	clip->y = COMPAT_XDG_SURFACE_GEOMETRY(c->surface.xdg).y;
}

static inline void
client_get_geometry(Client *c, struct wlr_box *geom)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		geom->x = c->surface.xwayland->x;
		geom->y = c->surface.xwayland->y;
		geom->width = c->surface.xwayland->width;
		geom->height = c->surface.xwayland->height;
		return;
	}
#endif
	*geom = COMPAT_XDG_SURFACE_GEOMETRY(c->surface.xdg);
}

static inline Client *
client_get_parent(Client *c)
{
	Client *p = NULL;
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		if (c->surface.xwayland->parent)
			toplevel_from_wlr_surface(c->surface.xwayland->parent->surface, &p, NULL);
		return p;
	}
#endif
	if (c->surface.xdg->toplevel->parent)
		toplevel_from_wlr_surface(c->surface.xdg->toplevel->parent->base->surface, &p, NULL);
	return p;
}

static inline int
client_has_children(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return !wl_list_empty(&c->surface.xwayland->children);
#endif
	/* surface.xdg->link is never empty because it always contains at least the
	 * surface itself. */
	return wl_list_length(&c->surface.xdg->link) > 1;
}

static inline const char *
client_get_title(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return c->surface.xwayland->title ? c->surface.xwayland->title : "broken";
#endif
	return c->surface.xdg->toplevel->title ? c->surface.xdg->toplevel->title : "broken";
}

static inline int
client_is_float_type(Client *c)
{
	struct wlr_xdg_toplevel *toplevel;
	struct wlr_xdg_toplevel_state state;

#ifdef XWAYLAND
	if (client_is_x11(c)) {
		struct wlr_xwayland_surface *surface = c->surface.xwayland;
		xcb_size_hints_t *size_hints = surface->size_hints;
		if (surface->modal)
			return 1;

#ifdef WLR_VERSION_0_19
		if (COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DIALOG)
				|| COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH)
				|| COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLBAR)
				|| COMPAT_XWAYLAND_HAS_WINDOW_TYPE(surface, WLR_XWAYLAND_NET_WM_WINDOW_TYPE_UTILITY)) {
			return 1;
		}
#endif

		return size_hints && size_hints->min_width > 0 && size_hints->min_height > 0
			&& (size_hints->max_width == size_hints->min_width
				|| size_hints->max_height == size_hints->min_height);
	}
#endif

	toplevel = c->surface.xdg->toplevel;
	state = toplevel->current;
	return toplevel->parent || (state.min_width != 0 && state.min_height != 0
		&& (state.min_width == state.max_width
			|| state.min_height == state.max_height));
}

static inline int
client_is_rendered_on_mon(Client *c, Monitor *m)
{
	/* This is needed for when you don't want to check formal assignment,
	 * but rather actual displaying of the pixels.
	 * Usually VISIBLEON suffices and is also faster. */
	struct wlr_surface_output *s;
	int unused_lx, unused_ly;
	if (!wlr_scene_node_coords(&c->scene->node, &unused_lx, &unused_ly))
		return 0;
	wl_list_for_each(s, &client_surface(c)->current_outputs, link)
		if (s->output == m->wlr_output)
			return 1;
	return 0;
}

static inline int
client_is_stopped(Client *c)
{
	int pid;
	siginfo_t in = {0};
#ifdef XWAYLAND
	if (client_is_x11(c))
		return 0;
#endif

	wl_client_get_credentials(c->surface.xdg->client->client, &pid, NULL, NULL);
	if (waitid(P_PID, pid, &in, WNOHANG|WCONTINUED|WSTOPPED|WNOWAIT) < 0) {
		/* This process is not our child process, while is very unlikely that
		 * it is stopped, in order to do not skip frames, assume that it is. */
		if (errno == ECHILD)
			return 1;
	} else if (in.si_pid) {
		if (in.si_code == CLD_STOPPED || in.si_code == CLD_TRAPPED)
			return 1;
		if (in.si_code == CLD_CONTINUED)
			return 0;
	}

	return 0;
}

static inline int
client_is_unmanaged(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return c->surface.xwayland->override_redirect;
#endif
	return 0;
}

static inline void
client_notify_enter(struct wlr_surface *s, struct wlr_keyboard *kb)
{
	wlr_log(WLR_DEBUG, "[FOCUS-ENTER] surface=%p kb=%p (keycodes=%zu) seat_focused_before=%p",
		(void*)s, (void*)kb, kb ? kb->num_keycodes : (size_t)0,
		(void*)seat->keyboard_state.focused_surface);
	if (kb)
		wlr_seat_keyboard_notify_enter(seat, s, kb->keycodes,
				kb->num_keycodes, &kb->modifiers);
	else
		wlr_seat_keyboard_notify_enter(seat, s, NULL, 0, NULL);
	wlr_log(WLR_DEBUG, "[FOCUS-ENTER] DONE seat_focused_after=%p match=%d",
		(void*)seat->keyboard_state.focused_surface,
		seat->keyboard_state.focused_surface == s);
}

static inline void
client_send_close(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		log_debug("closing X11 client %p", (void*)c);
		wlr_xwayland_surface_close(c->surface.xwayland);
		return;
	}
#endif
	log_debug("closing Wayland client %p", (void*)c);
	wlr_xdg_toplevel_send_close(c->surface.xdg->toplevel);
}

static inline void
client_set_border_color(Client *c, const float color[static 4])
{
	int i;
	for (i = 0; i < 4; i++)
		wlr_scene_rect_set_color(c->border[i], color);
}

static inline void
client_set_fullscreen_internal(Client *c, int fullscreen)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		wlr_xwayland_surface_set_fullscreen(c->surface.xwayland, fullscreen);
		return;
	}
#endif
	wlr_xdg_toplevel_set_fullscreen(c->surface.xdg->toplevel, fullscreen);
}

static inline void
client_set_scale(struct wlr_surface *s, float scale)
{
	wlr_fractional_scale_v1_notify_scale(s, scale);
	wlr_surface_set_preferred_buffer_scale(s, (int32_t)ceilf(scale));
}

static inline uint32_t
client_set_size(Client *c, uint32_t width, uint32_t height)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		/* X11 position = content origin (after border + titlebars).
		 * Configure if size OR position changed. Position-only changes
		 * must also be sent so X11 clients know where they are — without
		 * this, popup menus (e.g. Steam) appear at the old position. */
		int tl = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_LEFT].size;
		int tt = c->fullscreen ? 0 : c->titlebar[CLIENT_TITLEBAR_TOP].size;
		int16_t cx = c->geometry.x + c->bw + tl;
		int16_t cy = c->geometry.y + c->bw + tt;
		if (width == c->surface.xwayland->width
				&& height == c->surface.xwayland->height
				&& cx == c->surface.xwayland->x
				&& cy == c->surface.xwayland->y)
			return 0;
		wlr_xwayland_surface_configure(c->surface.xwayland,
				cx, cy, width, height);
		return 0;
	}
#endif
	if ((int32_t)width == c->surface.xdg->toplevel->current.width
			&& (int32_t)height == c->surface.xdg->toplevel->current.height)
		return 0;
	return wlr_xdg_toplevel_set_size(c->surface.xdg->toplevel, (int32_t)width, (int32_t)height);
}

static inline void
client_set_tiled(Client *c, uint32_t edges)
{
#ifdef XWAYLAND
	if (client_is_x11(c)) {
		COMPAT_XWAYLAND_SET_MAXIMIZED(c->surface.xwayland, edges != WLR_EDGE_NONE);
		return;
	}
#endif
	if (wl_resource_get_version(c->surface.xdg->toplevel->resource)
			>= XDG_TOPLEVEL_STATE_TILED_RIGHT_SINCE_VERSION) {
		wlr_xdg_toplevel_set_tiled(c->surface.xdg->toplevel, edges);
	} else {
		wlr_xdg_toplevel_set_maximized(c->surface.xdg->toplevel, edges != WLR_EDGE_NONE);
	}
}

static inline void
client_set_suspended(Client *c, int suspended)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return;
#endif

	wlr_xdg_toplevel_set_suspended(c->surface.xdg->toplevel, suspended);
}

static inline int
client_wants_focus(Client *c)
{
#ifdef XWAYLAND
	return client_is_unmanaged(c)
		&& COMPAT_XWAYLAND_OVERRIDE_REDIRECT_WANTS_FOCUS(c->surface.xwayland)
		&& COMPAT_XWAYLAND_ICCCM_INPUT_MODEL(c->surface.xwayland) != WLR_ICCCM_INPUT_MODEL_NONE;
#endif
	return 0;
}

static inline int
client_wants_fullscreen(Client *c)
{
#ifdef XWAYLAND
	if (client_is_x11(c))
		return c->surface.xwayland->fullscreen;
#endif
	return c->surface.xdg->toplevel->requested.fullscreen;
}
