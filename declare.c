/*
 * declare.c - the per-output declare/solve boundary for the Clay tree
 *
 * Each output owns a Clay context sized to its effective resolution and a
 * render_state parented into a band directly below LyrBlock, so everything
 * the tree will declare stays under the session lock, its covers, and the
 * drag icon. Per dirty frame the declare pass rebuilds the output's tree:
 * every box somewm computes elsewhere enters as a fixed floating leaf
 * attached to Clay's root, so Clay places without solving it.
 *
 * Draw order is Clay's own: zIndex picks the band and declaration order
 * breaks ties inside it. The bands are the table below; within one, clients
 * follow the stack and layer-shell surfaces the oldest first.
 */

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>

#include "clay.h"
#include "declare.h"
#include "render.h"
#include "somewm.h"
#include "somewm_types.h"
#include "globalconf.h"
#include "client.h"
#include "focus.h"
#include "somewm_api.h"
#include "monitor.h"
#include "stack.h"
#include "widget.h"
#include "window.h"
#include "common/buffer.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"

/* One Clay context plus the render_state its solved commands reconcile
 * into. Every output has a desktop band; the lua-lock band is created when
 * the lock engages (covers and the lock surface drawin reconcile into
 * LyrBlock, above locked_bg, below the raised external lock surface). */
struct declare_band {
	Clay_Context *clay;
	void *arena;
	struct wlr_scene_tree *tree;
	struct render_state *render;
	/* The last frame's readback for the tree dump: what the solve
	 * produced, what the reconcile changed, and how long each step took.
	 * Written by declare_output_frame only, so a band that has not drawn
	 * since the last dump reports the frame it did draw. */
	int commands, mutations;
	int64_t declare_us, solve_us, reconcile_us;
};

struct declare_output {
	struct wlr_output *wlr_output;
	struct declare_band desktop;
	struct declare_band lock;
	bool dirty;
};

/* Zero hooks until window.c installs the real ones at startup; the
 * reconciler only consults them for CUSTOM commands and borrowed nodes,
 * neither of which can exist before then. */
static struct render_client_hooks client_hooks;

void
declare_set_client_hooks(const struct render_client_hooks *hooks)
{
	client_hooks = *hooks;
}

/* --- the handle registry --- */

struct handle_entry {
	void *object;
	enum declare_kind kind;
	uint32_t id;
};

static struct handle_entry *handles;
static size_t handles_len, handles_cap;
static uint32_t handle_next = 1;

static uint64_t
handle_pack(enum declare_kind kind, uint32_t id)
{
	return ((uint64_t)kind << 32) | id;
}

/* Chrome scale is tens of objects; linear scans are fine. */
static uint64_t
handle_for(void *object, enum declare_kind kind)
{
	for (size_t i = 0; i < handles_len; i++)
		if (handles[i].object == object)
			return handle_pack(handles[i].kind, handles[i].id);
	if (handles_len == handles_cap) {
		handles_cap = handles_cap ? handles_cap * 2 : 32;
		p_realloc(&handles, handles_cap);
	}
	handles[handles_len++] = (struct handle_entry) {
		.object = object, .kind = kind, .id = handle_next++,
	};
	return handle_pack(kind, handles[handles_len - 1].id);
}

void *
declare_handle_get(uint64_t handle, enum declare_kind *kind)
{
	uint32_t id = (uint32_t)handle;

	for (size_t i = 0; i < handles_len; i++) {
		if (handles[i].id != id)
			continue;
		if (handles[i].kind != (enum declare_kind)(handle >> 32))
			return NULL;
		if (kind)
			*kind = handles[i].kind;
		return handles[i].object;
	}
	return NULL;
}

void
declare_handle_drop(void *object)
{
	for (size_t i = 0; i < handles_len; i++) {
		if (handles[i].object == object) {
			handles[i] = handles[--handles_len];
			return;
		}
	}
}

/* --- leaf declarations --- */

static void
declare_leaf(Clay_ElementDeclaration *decl)
{
	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(decl);
	Clay__CloseElement();
}

/* --- the draw order ---
 *
 * One band per line, bottom first. Clay sorts floating tree roots by zIndex
 * (every floating element is one, clay.h:2102-2107; the sort is at
 * clay.h:2603-2615 and is stable), so declaration order decides only within
 * a band. A window's band comes from its stacking attribute; a transient
 * that sets none inherits its parent's. */
enum {
	Z_LAYER_BACKGROUND = 10,
	Z_CLIENT_DESKTOP = 20,
	Z_DRAWIN_BG = 30,
	Z_LAYER_BOTTOM = 40,
	Z_CLIENT_BELOW = 50,
	Z_CLIENT_NORMAL = 60,
	Z_DRAWIN_WIBOX = 70,
	Z_LAYER_TOP = 80,
	Z_CLIENT_ABOVE = 90,
	Z_DRAWIN_TOP = 100,
	Z_FULLSCREEN_BG = 105,
	Z_CLIENT_FULLSCREEN = 110,
	Z_LAYER_OVERLAY = 120,
	Z_CLIENT_ONTOP = 130,
	Z_DRAWIN_OVERLAY = 140,
	/* Override-redirect X11 windows (menus, tooltips, drag icons) carry
	 * no stacking attribute to place them and are always transient UI for
	 * the window below, so they sit above everything. */
	Z_CLIENT_UNMANAGED = 150,
};

/* The lock band is a separate Clay context with its own order. */
enum {
	Z_LOCK_COVER = 10,
	Z_LOCK_SURFACE = 20,
};

/* The placement every box somewm computes elsewhere enters with: a fixed
 * size at an explicit offset from the root, so Clay places it without
 * solving for it. */
static void
place_fixed(Clay_ElementDeclaration *decl, int16_t z, int x, int y,
	int w, int h)
{
	decl->layout.sizing.width = CLAY_SIZING_FIXED(w);
	decl->layout.sizing.height = CLAY_SIZING_FIXED(h);
	decl->floating.offset = (Clay_Vector2) { x, y };
	decl->floating.attachTo = CLAY_ATTACH_TO_ROOT;
	decl->floating.zIndex = z;
}

static Clay_ElementDeclaration
leaf_at(Clay_String label, uint32_t index, int16_t z,
	int x, int y, int w, int h)
{
	Clay_ElementDeclaration decl = {
		.id = Clay__HashString(label, index, 0),
	};

	place_fixed(&decl, z, x, y, w, h);
	return decl;
}

/* The per-element userData word (render.h): registry id in bits 0-31, kind
 * in 32-39, opacity byte in 40-47. A packed integer rather than a pointer,
 * so a retained command can never dangle into freed registry state; the low
 * 40 bits are exactly a declare handle. */
_Static_assert(sizeof(void *) >= 8, "userData packing needs 64-bit pointers");

static void *
leaf_userdata(uint64_t handle, float opacity)
{
	return (void *)(uintptr_t)(handle
		| ((uint64_t)(1 + (unsigned)(opacity * 254.0f + 0.5f)) << 40));
}

/* The band that drew a node is the one whose render_state retains it, which
 * is not the band under the pointer: a drawin overhanging an output edge and
 * a floating client dragged clear of its monitor both draw on a neighbor
 * while the band that declared them stays where it is. Every band answers,
 * and a node belongs to at most one, so the first hit is the owner. Asking
 * all of them also covers a point in a gap between misaligned outputs, where
 * there is no monitor to ask. */
void *
declare_hit(struct wlr_scene_node *node, enum declare_kind *kind)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		struct declare_output *dout = m->declare;
		void *ud;

		if (!dout)
			continue;
		ud = render_hit_userdata(dout->desktop.render, node);
		if (!ud && dout->lock.render)
			ud = render_hit_userdata(dout->lock.render, node);
		if (ud)
			return declare_handle_get(
				declare_userdata_handle(ud), kind);
	}
	return NULL;
}

/* somewm colors are straight-alpha 0-1 floats; Clay_Color is 0-255.
 * The renderer premultiplies once when converting back for wlr_scene. */
static Clay_Color
clay_color(const float rgba[4])
{
	return (Clay_Color) {
		rgba[0] * 255.0f, rgba[1] * 255.0f,
		rgba[2] * 255.0f, rgba[3] * 255.0f,
	};
}

/* The frame box: awful.layout's geometry plus the border ring drawn around
 * the content, positioned output-local (the render band sits at the output's
 * layout position). One BORDER element and one CUSTOM element at the same
 * box, border first so the borrowed tree, popups included, stacks above it,
 * matching the popup raise in client_configure_to_box(). */
static void
declare_client(Client *c, Monitor *m, int16_t z)
{
	uint64_t handle = handle_for(c, DECLARE_KIND_CLIENT);
	uint32_t id = (uint32_t)handle;
	int bw = c->bw;
	int fw = c->geometry.width + 2 * bw;
	int fh = c->geometry.height + 2 * bw;
	int x = c->geometry.x - m->m.x;
	int y = c->geometry.y - m->m.y;
	bool clamp = client_clamps_to_monitor(c);

	/* Under a clip-offscreen layout, a fully offscreen client declares
	 * nothing: the sweep releases its tree disabled, which is today's
	 * visible=false hide. The test uses the geometry box, matching the
	 * content-box test in client_configure_to_box(). */
	if (clamp && (x + bw + c->geometry.width <= 0
			|| y + bw + c->geometry.height <= 0
			|| x + bw >= m->m.width
			|| y + bw >= m->m.height))
		return;

	if (bw > 0) {
		Clay_ElementDeclaration b = leaf_at(
			CLAY_STRING("client.border"), id, z, x, y, fw, fh);
		float rgba[4];

		client_border_rgba(c, rgba);
		b.border.color = clay_color(rgba);
		b.border.width = (Clay_BorderWidth) {
			bw, bw, bw, bw, 0 };
		b.userData = leaf_userdata(handle, 1.0f);
		if (clamp) {
			/* The monitor scissor: a floating clip wrapper at the
			 * output box; the border rides inside as an
			 * attach-to-parent child inheriting the wrapper's clip
			 * (clay.h:2077-2079, 2123), so a partially offscreen
			 * border clips at the output edge instead of bleeding
			 * onto the neighbor. The surface leaf stays outside:
			 * CUSTOM is never clipped, and the surface's own clamp
			 * lives in client_configure_to_box(). */
			Clay_ElementDeclaration w = leaf_at(
				CLAY_STRING("client.clip"), id, z,
				0, 0, m->m.width, m->m.height);
			w.clip = (Clay_ClipElementConfig) {
				.horizontal = true, .vertical = true };
			b.floating.attachTo = CLAY_ATTACH_TO_PARENT;
			b.floating.clipTo = CLAY_CLIP_TO_ATTACHED_PARENT;
			Clay__OpenElement();
			Clay__ConfigureOpenElementPtr(&w);
			declare_leaf(&b);
			Clay__CloseElement();
		} else {
			declare_leaf(&b);
		}
	}

	Clay_ElementDeclaration s = leaf_at(
		CLAY_STRING("client.surface"), id, z, x, y, fw, fh);
	s.custom.customData = (void *)(uintptr_t)handle;
	s.userData = leaf_userdata(handle, 1.0f);
	declare_leaf(&s);
}

static bool
declarable_client(Client *c)
{
	if (!c || !c->scene || !client_surface(c)
			|| !client_surface(c)->mapped)
		return false;
	/* Banning's visibility fact (tags, minimized) becomes a declare
	 * filter: an undeclared client's tree is released disabled by the
	 * sweep. Unmanaged clients are not tag-tracked. */
	return client_is_unmanaged(c) || client_isvisible(c);
}

/* A transient that sets no stacking attribute of its own inherits its
 * parent's band and is declared right above it. One that sets ontop, above,
 * below or fullscreen declares as a root in that band instead, so the
 * attribute wins over the parent's placement, as in AwesomeWM.
 * stack_client_layer() returns WINDOW_LAYER_IGNORE for exactly the first
 * case, so this implies c->transient_for. */
static bool
transient_inherits(Client *c)
{
	return stack_client_layer(c) == WINDOW_LAYER_IGNORE;
}

static int16_t
client_z(Client *c)
{
	if (client_is_unmanaged(c))
		return Z_CLIENT_UNMANAGED;

	switch (stack_client_effective_layer(c)) {
	case WINDOW_LAYER_DESKTOP:
		return Z_CLIENT_DESKTOP;
	case WINDOW_LAYER_BELOW:
		return Z_CLIENT_BELOW;
	case WINDOW_LAYER_ABOVE:
		return Z_CLIENT_ABOVE;
	case WINDOW_LAYER_FULLSCREEN:
		return Z_CLIENT_FULLSCREEN;
	case WINDOW_LAYER_ONTOP:
		return Z_CLIENT_ONTOP;
	default:
		return Z_CLIENT_NORMAL;
	}
}

/* Inheriting transients ride their parent: declared right above it in the
 * band it resolved to, mirroring stack_transients_above() (stack.c).
 * Unmanaged children are excluded; declare_unmanaged_clients() owns every
 * unmanaged client, and declaring one here too would hash a duplicate Clay
 * id and abort. */
static void
declare_client_tree(Client *c, Monitor *m)
{
	declare_client(c, m, client_z(c));
	foreach(node, globalconf.stack)
		if ((*node)->transient_for == c && (*node)->mon == m
				&& !client_is_unmanaged(*node)
				&& transient_inherits(*node)
				&& declarable_client(*node))
			declare_client_tree(*node, m);
}

/* Whether declare_client_tree() will reach c through its parent. When it
 * will not (c carries a stacking attribute of its own, or the parent is
 * minimized, unmapped, unmanaged, or on another output), c declares as a
 * root instead of vanishing; the old scene path kept exactly these clients
 * visible per-client. The immediate parent suffices: every managed
 * declarable client on m is declared, as a root or by riding one, so a
 * declarable parent is a declared parent. */
static bool
transient_rides_parent(Client *c, Monitor *m)
{
	Client *p = c->transient_for;

	return p && transient_inherits(c) && p->mon == m
		&& !client_is_unmanaged(p) && declarable_client(p);
}

static void
declare_clients(Monitor *m)
{
	foreach(node, globalconf.stack) {
		Client *c = *node;

		/* Cheap pointer filters first, then the riding test, which
		 * skips a transient before it pays for its own tag-visibility
		 * check. Unmanaged (override-redirect) clients are declared by
		 * declare_unmanaged_clients() instead. */
		if (!c || c->mon != m || client_is_unmanaged(c))
			continue;
		if (transient_rides_parent(c, m))
			continue;
		if (!declarable_client(c))
			continue;
		declare_client_tree(c, m);
	}
}

/* Unmanaged clients have no c->mon assignment to trust; each declares on
 * exactly one output, the one under its center, so two outputs never fight
 * over borrowing the same scene tree. */
static Monitor *
monitor_for_unmanaged(Client *c)
{
	Monitor *m = xytomon(c->geometry.x + c->geometry.width / 2.0,
		c->geometry.y + c->geometry.height / 2.0);

	return m ? m : c->mon;
}

static void
declare_unmanaged_clients(Monitor *m)
{
	foreach(node, globalconf.stack) {
		Client *c = *node;

		if (!c || !client_is_unmanaged(c))
			continue;
		if (monitor_for_unmanaged(c) != m)
			continue;
		if (!declarable_client(c))
			continue;
		declare_client(c, m, client_z(c));
	}
}

static void
declare_layer_surface(LayerSurface *l, Monitor *m, int16_t z)
{
	uint64_t handle = handle_for(l, DECLARE_KIND_LAYER);
	struct wlr_layer_surface_v1 *ls = l->layer_surface;
	/* l->geom is output-local, captured by arrangelayer() from the
	 * layer-shell solve; the scene node's own position belongs to the
	 * reconciler and may hold this same value already. */
	Clay_ElementDeclaration s = leaf_at(CLAY_STRING("layer.surface"),
		(uint32_t)handle, z, l->geom.x, l->geom.y,
		ls->current.actual_width, ls->current.actual_height);

	s.custom.customData = (void *)(uintptr_t)handle;
	s.userData = leaf_userdata(handle, 1.0f);
	declare_leaf(&s);
}

static void
declare_layer_surfaces(Monitor *m)
{
	static const int16_t band_z[] = {
		[ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND] = Z_LAYER_BACKGROUND,
		[ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM] = Z_LAYER_BOTTOM,
		[ZWLR_LAYER_SHELL_V1_LAYER_TOP] = Z_LAYER_TOP,
		[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY] = Z_LAYER_OVERLAY,
	};
	LayerSurface *l;

	/* protocols.c prepends new surfaces to m->layers, and scene child
	 * order stacks newer surfaces on top; reverse iteration declares the
	 * oldest first, at the bottom. */
	for (size_t band = 0; band < LENGTH(m->layers); band++) {
		wl_list_for_each_reverse(l, &m->layers[band], link) {
			if (!l->mapped || !l->scene)
				continue;
			declare_layer_surface(l, m, band_z[band]);
		}
	}
}

/* --- the converted widget tree (widget.h) ---
 *
 * One element per node, nested as lua/wibox/clay.lua compiled them. The
 * root is the drawin's own box, fixed and floating like any other leaf here,
 * and it clips on both axes so a layout that overflows draws nothing outside
 * the drawin: Clay emits the clip as a SCISSOR pair around the subtree
 * (clay.h:2121-2123, 2806-2807, 3029-3033) and render.c crops every leaf to it
 * (buffer_apply_clip). A clip parent also leaves overflowing children at
 * their size instead of compressing them (clay.h:2305-2311).
 *
 * Ids follow the path from the root: the root hashes the drawin's registry
 * id, and a child hashes its index seeded with its parent's id, the shape of
 * CLAY_IDI_LOCAL (clay.h:92). A widget inserted among its siblings renames
 * the siblings after it and their subtrees and nothing else, so the rest of
 * the tree keeps its retained nodes; a preorder index would rename every
 * node after the insertion point.
 *
 * Every node carries the drawin's handle in userData, containers included:
 * the pointer over a gap between leaves lands on a container's rectangle,
 * and declare_hit has to resolve that node to the drawin (input.c then takes
 * drawin-local coordinates from the drawin's own box, not the node's).
 */
static Clay_ElementId
widget_root_id(uint32_t id)
{
	return Clay__HashString(CLAY_STRING("drawin.widget"), id, 0);
}

static Clay_ElementId
widget_child_id(Clay_ElementId parent, uint16_t index)
{
	return Clay__HashString(CLAY_STRING("drawin.widget"), index, parent.id);
}

static Clay_SizingAxis
widget_sizing(const struct widget_node *n, int axis)
{
	return n->fixed[axis] ? CLAY_SIZING_FIXED(n->size[axis])
		: CLAY_SIZING_GROW(0, n->max[axis]);
}

static Clay_ElementDeclaration
widget_node_decl(const struct widget_node *n, Clay_ElementId id, int16_t z,
	void *userdata)
{
	Clay_ElementDeclaration e = {
		.id = id,
		.layout = {
			.sizing = { widget_sizing(n, 0), widget_sizing(n, 1) },
			.padding = { n->pad[0], n->pad[1], n->pad[2], n->pad[3] },
			.childGap = n->gap,
			.childAlignment = { n->align[0], n->align[1] },
			.layoutDirection = n->vertical
				? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT,
		},
		.cornerRadius = { n->radius, n->radius, n->radius, n->radius },
		.userData = userdata,
	};

	if (n->bg[3] > 0)
		e.backgroundColor = clay_color(n->bg);
	if (n->border[3] > 0) {
		e.border.color = clay_color(n->border);
		e.border.width = (Clay_BorderWidth) {
			n->bw[0], n->bw[1], n->bw[2], n->bw[3], 0 };
	}
	if (n->floating) {
		/* A stack child: off the flow, at the parent's top left, in the
		 * drawin's band (a floating element is its own tree root, sorted
		 * by zIndex and then declaration order, clay.h:2603-2615),
		 * clipped to the drawin like its siblings (clay.h:2074-2079). */
		e.floating.attachTo = CLAY_ATTACH_TO_PARENT;
		e.floating.clipTo = CLAY_CLIP_TO_ATTACHED_PARENT;
		e.floating.zIndex = z;
	}
	return e;
}

static size_t
declare_widget_subtree(drawin_t *d, size_t i, Clay_ElementId id, int16_t z,
	int x, int y, void *userdata, size_t *leaf)
{
	const struct widget_node *n = &d->widget_nodes[i];
	Clay_ElementDeclaration e = widget_node_decl(n, id, z, userdata);
	size_t next = i + 1;

	if (i == 0) {
		place_fixed(&e, z, x, y, d->width, d->height);
		e.clip = (Clay_ClipElementConfig) {
			.horizontal = true, .vertical = true };
	}
	if (n->raster && *leaf < d->widget_leaves_len)
		e.image.imageData = &d->widget_leaves[(*leaf)++];

	Clay__OpenElement();
	Clay__ConfigureOpenElementPtr(&e);
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_widget_subtree(d, next, widget_child_id(id, k),
			z, x, y, userdata, leaf);
	Clay__CloseElement();
	return next;
}

static void
declare_widget_tree(drawin_t *d, uint32_t id, int16_t z, int x, int y,
	void *userdata)
{
	size_t leaf = 0;

	d->widget_nodes_declared = true;
	declare_widget_subtree(d, 0, widget_root_id(id), z, x, y, userdata,
		&leaf);
}

/* --- drawins as whole-buffer image leaves ---
 *
 * Shadow below border below content, all riding the drawin's own image
 * entries (objects/drawin.c fills them; gen bumps on content change).
 * Opacity applies to the content leaf only, matching the old scene-buffer
 * path, which never set opacity on the border or shadow. */
static void
declare_drawin(drawin_t *d, Monitor *m, int16_t z)
{
	uint64_t handle = handle_for(d, DECLARE_KIND_DRAWIN);
	uint32_t id = (uint32_t)handle;
	int bw = d->border_width;
	int x = d->x - m->m.x;
	int y = d->y - m->m.y;
	float opacity = d->opacity >= 0 ? (float)d->opacity : 1.0f;

	if (d->shadow_entry.native) {
		int sx, sy, sw, sh;
		shadow_box(&d->shadow_entry_config, d->width, d->height,
			&sx, &sy, &sw, &sh);
		Clay_ElementDeclaration s = leaf_at(CLAY_STRING("drawin.shadow"),
			id, z, x + sx, y + sy, sw, sh);
		s.image.imageData = &d->shadow_entry;
		declare_leaf(&s);
	}
	if (bw > 0 && d->border_entry.native) {
		/* No userData: the input filter (window.c hook_accepts_input)
		 * reads a bare word as "never accepts input", which is what the
		 * old border_buffer's point_accepts_input answered, and the
		 * shadow leaf below gets the same treatment for free. */
		Clay_ElementDeclaration b = leaf_at(CLAY_STRING("drawin.border"),
			id, z, x - bw, y - bw,
			d->width + 2 * bw, d->height + 2 * bw);
		b.image.imageData = &d->border_entry;
		declare_leaf(&b);
	}

	/* A converted widget tree declares its own leaves, each carrying the
	 * pixels of one subtree lua/wibox/clay.lua could not express, at the
	 * box Clay solves for it. */
	if (d->widget_nodes_len > 0) {
		declare_widget_tree(d, id, z, x, y, leaf_userdata(handle, opacity));
		return;
	}

	Clay_ElementDeclaration c = leaf_at(CLAY_STRING("drawin.image"), id, z,
		x, y, d->width, d->height);
	c.image.imageData = &d->content_entry;
	c.userData = leaf_userdata(handle, opacity);
	declare_leaf(&c);
}

/* Map-then-draw: a drawin only declares once its content entry holds pixels,
 * the same gate the old path applied by enabling the scene node after the
 * first refresh. */
static bool
declarable_drawin(drawin_t *d, Monitor *m)
{
	return d->visible
		&& d->content_entry.native
		&& d->screen && d->screen->monitor == m;
}

/* The drawin band policy (AwesomeWM compat): desktop and splash below
 * clients like wallpaper, ontop above everything, dock above normal
 * windows, everything else in the wibox band. */
static int16_t
drawin_z(drawin_t *d)
{
	if (d->type == WINDOW_TYPE_DESKTOP || d->type == WINDOW_TYPE_SPLASH)
		return Z_DRAWIN_BG;
	if (d->ontop)
		return Z_DRAWIN_OVERLAY;
	if (d->type == WINDOW_TYPE_DOCK)
		return Z_DRAWIN_TOP;
	return Z_DRAWIN_WIBOX;
}

static void
declare_drawins(Monitor *m)
{
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		/* Lock drawins belong to the lock pass while locked. */
		if (session_is_locked() && some_is_lock_drawin(d))
			continue;
		if (!declarable_drawin(d, m))
			continue;
		declare_drawin(d, m, drawin_z(d));
	}
}

/* The opaque backing the xdg protocol requires under a non-opaque
 * fullscreen surface; replaces the per-monitor fullscreen_bg scene rect,
 * enabled under the same condition (arrange()'s focustop check). */
static void
declare_fullscreen_bg(Monitor *m)
{
	Client *c = focustop(m);

	if (!c || !c->fullscreen)
		return;

	Clay_ElementDeclaration bg = leaf_at(CLAY_STRING("fullscreen_bg"), 0,
		Z_FULLSCREEN_BG, 0, 0, m->m.width, m->m.height);
	bg.backgroundColor = clay_color(globalconf.appearance.fullscreen_bg);
	declare_leaf(&bg);
}

static void
declare_scene(Monitor *m)
{
	declare_layer_surfaces(m);
	declare_clients(m);
	declare_drawins(m);
	declare_fullscreen_bg(m);
	declare_unmanaged_clients(m);
	/* Session lock: locked_bg, the lock covers, and the lock surface stay
	 * C-owned scene nodes in LyrBlock, above this whole band. */
}

/* The boxes of one subtree, in the preorder the tree table uses, rounded
 * against the root's own box so a box crossing into Lua is the whole
 * drawin-local pixel the layout engine would have placed. Edges round, not
 * the size, so two boxes that share an edge in Clay share it here. */
static size_t
widget_boxes_walk(drawin_t *d, size_t i, Clay_ElementId id, int (*boxes)[4],
	int *n, Clay_BoundingBox root)
{
	const struct widget_node *node = &d->widget_nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	size_t next = i + 1;

	if (data.found && node->widget) {
		Clay_BoundingBox b = data.boundingBox;
		int x0 = (int)floorf(b.x - root.x + 0.5f);
		int y0 = (int)floorf(b.y - root.y + 0.5f);

		boxes[*n][0] = x0;
		boxes[*n][1] = y0;
		boxes[*n][2] = (int)floorf(b.x + b.width - root.x + 0.5f) - x0;
		boxes[*n][3] = (int)floorf(b.y + b.height - root.y + 0.5f) - y0;
		(*n)++;
	}
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_boxes_walk(d, next, widget_child_id(id, k), boxes,
			n, root);
	return next;
}

int
declare_widget_boxes(drawin_t *d, int (*boxes)[4])
{
	Monitor *m = d->screen ? d->screen->monitor : NULL;
	struct declare_output *dout = m ? m->declare : NULL;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementData root;
	int n = 0;

	/* Clay's hashmap answers with the last box an id ever had, so a tree
	 * the declare pass has not reached yet would read back the boxes of
	 * the one it replaced. Report nothing until it has. */
	if (!dout || !d->widget_nodes_declared)
		return 0;

	/* What the last frame solved, not a second solve of its own: Clay
	 * keeps every element's box in the context's hashmap, so the readback
	 * is one lookup per node against the boxes the output drew. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(dout->desktop.clay);
	root_id = widget_root_id((uint32_t)handle_for(d, DECLARE_KIND_DRAWIN));
	root = Clay_GetElementData(root_id);
	if (root.found)
		widget_boxes_walk(d, 0, root_id, boxes, &n, root.boundingBox);
	Clay_SetCurrentContext(previous);
	return n;
}

int
declare_output_order(struct declare_output *dout, Monitor *m, void **objects,
	int cap)
{
	int n = 0;

	Clay_SetCurrentContext(dout->desktop.clay);
	Clay_BeginLayout();
	declare_scene(m);
	Clay_RenderCommandArray commands = Clay_EndLayout();

	for (int32_t i = 0; i < commands.length && n < cap; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		void *object = declare_handle_get(
			declare_userdata_handle(cmd->userData), NULL);

		/* A leaf with no handle (the clip wrapper, the fullscreen
		 * backing) is not an object. A client declares a border leaf
		 * and a surface leaf, a drawin up to three image leaves; the
		 * object enters the order once, at its lowest leaf. */
		if (!object || (n > 0 && objects[n - 1] == object))
			continue;
		objects[n++] = object;
	}
	return n;
}

/* --- context lifecycle and the frame entry --- */

static int64_t
now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void
handle_clay_error(Clay_ErrorData error)
{
	/* A Clay error (arena exhaustion, duplicate id, command array
	 * overflow) is a bug, not a condition to ride out. */
	wlr_log(WLR_ERROR, "clay error %d: %.*s", error.errorType,
		error.errorText.length, error.errorText.chars);
	abort();
}

/* One band: an arena-backed Clay context and a render_state reconciling
 * into a fresh tree under parent. */
static void
declare_band_init(struct declare_band *band, struct wlr_output *wlr_output,
	struct wlr_scene_tree *parent)
{
	uint32_t arena_size = Clay_MinMemorySize();
	int width, height;

	wlr_output_effective_resolution(wlr_output, &width, &height);
	band->arena = malloc(arena_size);
	band->clay = Clay_Initialize(
		Clay_CreateArenaWithCapacityAndMemory(arena_size, band->arena),
		(Clay_Dimensions) { .width = width, .height = height },
		(Clay_ErrorHandler) { .errorHandlerFunction = handle_clay_error });
	/* Clay_Initialize left this the current context. Clay drops any
	 * element whose box lies entirely outside layoutDimensions
	 * (clay.h:2465), which saves draw calls in immediate mode and loses
	 * windows here. Boxes are output-local, but the nodes they reconcile
	 * into are not confined to the output: a floating client mid-drag and
	 * a drawin overhanging an edge render on the neighbor while their box
	 * is still relative to the output that declared them. wlr_scene does
	 * the per-output culling. */
	Clay_SetCullingEnabled(false);
	band->tree = wlr_scene_tree_create(parent);
	band->render = render_create(band->tree);
}

static void
declare_band_wipe(struct declare_band *band)
{
	if (!band->clay)
		return;
	/* The Clay_Context lives inside the arena being freed. Clay keeps a
	 * global current-context pointer; left dangling, the next
	 * Clay_MinMemorySize or Clay_Initialize would read freed memory. */
	if (Clay_GetCurrentContext() == band->clay)
		Clay_SetCurrentContext(NULL);
	render_destroy(band->render, &client_hooks);
	wlr_scene_node_destroy(&band->tree->node);
	free(band->arena);
}

/* Layout dimensions, band position, and raster scale have one owner: this
 * function, run at band creation and on every updatemons pass. The frame
 * entry never re-derives them. */
static void
declare_band_update(struct declare_band *band, struct wlr_output *wlr_output,
	int lx, int ly)
{
	int width, height;

	if (!band->clay)
		return;
	wlr_output_effective_resolution(wlr_output, &width, &height);
	Clay_SetCurrentContext(band->clay);
	Clay_SetLayoutDimensions(
		(Clay_Dimensions) { .width = width, .height = height });
	render_set_position(band->render, lx, ly);
	render_set_scale(band->render, wlr_output->scale);
}

struct declare_output *
declare_output_create(struct wlr_output *wlr_output)
{
	struct declare_output *dout = calloc(1, sizeof(*dout));

	dout->wlr_output = wlr_output;
	declare_band_init(&dout->desktop, wlr_output, &scene->tree);
	/* Directly above the legacy layers, and below the drag icon and
	 * LyrBlock, both placed below LyrBlock at setup before any band. */
	wlr_scene_node_place_above(&dout->desktop.tree->node,
		&layers[LyrOverlay]->node);
	dout->dirty = true;
	return dout;
}

/* The lock scene, in some_activate_lua_lock()'s own order: the covers, then
 * the lock surface drawin on top. */
static void
declare_lock_scene(Monitor *m)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);

	for (int i = 0; i < cover_count; i++)
		if (covers[i] && declarable_drawin(covers[i], m))
			declare_drawin(covers[i], m, Z_LOCK_COVER);
	if (lock_surface && declarable_drawin(lock_surface, m))
		declare_drawin(lock_surface, m, Z_LOCK_SURFACE);
}

void
declare_lock_set_visible(bool on)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare)
			continue;
		/* Create the lock band on engage: wlroots appends new children
		 * topmost, so it lands above locked_bg and below any external
		 * session-lock tree created after it. */
		if (on && !m->declare->lock.clay) {
			declare_band_init(&m->declare->lock,
				m->declare->wlr_output, layers[LyrBlock]);
			declare_band_update(&m->declare->lock,
				m->declare->wlr_output, m->m.x, m->m.y);
		}
		if (m->declare->lock.render)
			render_set_enabled(m->declare->lock.render, on);
		declare_output_mark_dirty(m->declare);
	}
}

void
declare_output_destroy(struct declare_output *dout)
{
	declare_band_wipe(&dout->desktop);
	declare_band_wipe(&dout->lock);
	free(dout);
}

void
declare_output_update(struct declare_output *dout, int lx, int ly)
{
	declare_band_update(&dout->desktop, dout->wlr_output, lx, ly);
	declare_band_update(&dout->lock, dout->wlr_output, lx, ly);
	declare_output_mark_dirty(dout);
}

void
declare_output_mark_dirty(struct declare_output *dout)
{
	dout->dirty = true;
	wlr_output_schedule_frame(dout->wlr_output);
}

/* Run the declare pass for every dirty output now. The poll function calls
 * this each loop iteration: input hit-testing reads the reconciled scene,
 * and a hidden or asleep output gets no frame events to rebuild it there.
 * The frame handler keeps its own call for marks that land in between.
 * Returns the scene mutations that took, so the caller can re-evaluate what
 * is under the pointer.
 */
int
declare_flush(void)
{
	Monitor *m;
	int mutations = 0, n;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare || !m->wlr_output->enabled)
			continue;
		n = declare_output_frame(m->declare, m, some_is_lua_locked());
		if (n > 0)
			mutations += n;
	}
	return mutations;
}

void
declare_mark_all_dirty(void)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link)
		if (m->declare)
			declare_output_mark_dirty(m->declare);
}

int
declare_output_frame(struct declare_output *dout, Monitor *m, bool lock_active)
{
	struct declare_band *band;
	int64_t declared, solved;

	if (!dout->dirty)
		return -1;
	dout->dirty = false;

	/* While lua-locked, this output solves its lock scene instead; the
	 * desktop band keeps its last scene, occluded by locked_bg. The lock
	 * band normally exists already (declare_lock_set_visible creates it
	 * on engage); this covers outputs created mid-lock. */
	if (lock_active && !dout->lock.clay) {
		declare_band_init(&dout->lock, dout->wlr_output, layers[LyrBlock]);
		declare_band_update(&dout->lock, dout->wlr_output, m->m.x, m->m.y);
	}
	band = lock_active ? &dout->lock : &dout->desktop;

	band->declare_us = now_us();
	Clay_SetCurrentContext(band->clay);
	Clay_BeginLayout();
	if (lock_active)
		declare_lock_scene(m);
	else
		declare_scene(m);
	declared = now_us();
	Clay_RenderCommandArray commands = Clay_EndLayout();
	solved = now_us();

	band->commands = commands.length;
	band->mutations = render_reconcile(band->render, commands,
		&client_hooks);
	band->reconcile_us = now_us() - solved;
	band->solve_us = solved - declared;
	band->declare_us = declared - band->declare_us;
	return band->mutations;
}

/* --- the solved tree dump (somewm-client clay tree) ---
 *
 * One header line of counters per band and one line per retained node, in
 * draw order, read back from what the last reconcile retained (render.h).
 * Nothing here solves or declares: the dump reports the frame the output
 * drew. It doubles as a tree==scene check in release builds, where the
 * verifier is compiled out, by printing the renderer's own mismatch answer.
 */

static const char *
command_name(uint32_t type)
{
	switch (type) {
	case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:	return "RECTANGLE";
	case CLAY_RENDER_COMMAND_TYPE_BORDER:		return "BORDER";
	case CLAY_RENDER_COMMAND_TYPE_TEXT:		return "TEXT";
	case CLAY_RENDER_COMMAND_TYPE_IMAGE:		return "IMAGE";
	case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:	return "SCISSOR_START";
	case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:	return "SCISSOR_END";
	case CLAY_RENDER_COMMAND_TYPE_CUSTOM:		return "CUSTOM";
	default:					return "UNKNOWN";
	}
}

/* The widget node an element id names, walking the same path hashing the
 * declare pass used. The walk visits every node so the preorder index keeps
 * up with the id path; NULL when the id names no node in this tree. */
static const struct widget_node *
widget_node_for_id(drawin_t *d, size_t *i, Clay_ElementId id, uint32_t want)
{
	const struct widget_node *n = &d->widget_nodes[(*i)++];
	const struct widget_node *hit = id.id == want ? n : NULL;

	for (uint16_t k = 0; k < n->children; k++) {
		const struct widget_node *c = widget_node_for_id(d, i,
			widget_child_id(id, k), want);

		if (c && !hit)
			hit = c;
	}
	return hit;
}

/* What the node is. A leaf that carries no handle (a client's clip wrapper,
 * a drawin's shadow and border, the fullscreen backing, every SCISSOR
 * marker) stands for no object and says so. */
static void
dump_what(buffer_t *buf, uint32_t id, void *userdata)
{
	enum declare_kind kind = 0;
	void *object = declare_handle_get(declare_userdata_handle(userdata),
		&kind);

	if (!object) {
		buffer_adds(buf, "-");
		return;
	}
	switch (kind) {
	case DECLARE_KIND_CLIENT:
		buffer_addf(buf, "client %s", client_get_appid(object));
		break;
	case DECLARE_KIND_LAYER: {
		struct wlr_layer_surface_v1 *ls =
			((LayerSurface *)object)->layer_surface;

		buffer_addf(buf, "layer %s", ls->namespace ? ls->namespace : "?");
		break;
	}
	case DECLARE_KIND_DRAWIN: {
		drawin_t *d = object;
		const struct widget_node *n = NULL;
		size_t i = 0;

		/* A converted drawin declares no leaf of its own, so every
		 * node carrying its handle is a widget node. The tree's root
		 * is the drawin's own box, and naming it as the drawin is what
		 * keeps a converted drawin in the dump under its own name. */
		if (d->widget_nodes_len > 0)
			n = widget_node_for_id(d, &i, widget_root_id(
				(uint32_t)handle_for(d, DECLARE_KIND_DRAWIN)),
				id);
		if (n && n != d->widget_nodes)
			buffer_addf(buf, "widget %s%s", n->cls ? n->cls : "-",
				n->raster ? " raster" : "");
		else
			buffer_addf(buf, "drawin screen %d %dx%d+%d+%d",
				d->screen ? d->screen->index : 0,
				d->width, d->height, d->x, d->y);
		break;
	}
	}
}

static void
dump_node(void *user, const struct render_node_view *v)
{
	buffer_t *buf = user;

	/* Only RECTANGLE carries the band it landed in (clay.h:2908). Every
	 * other command type is built without a zIndex (clay.h:2790, 2986) and
	 * would read as the bottom band, so those say they have none. Draw
	 * order is the line order either way. */
	buffer_addf(buf, "  %08x %-13s ", v->id, command_name(v->type));
	if (v->type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE)
		buffer_addf(buf, "z=%-4d ", v->z);
	else
		buffer_adds(buf, "z=-    ");
	buffer_addf(buf, "box %d,%d %dx%d rbox %d,%d %dx%d ",
		(int)v->box.x, (int)v->box.y,
		(int)v->box.width, (int)v->box.height,
		(int)v->rbox.x, (int)v->rbox.y,
		(int)v->rbox.width, (int)v->rbox.height);
	dump_what(buf, v->id, v->user_data);
	if (v->raster_bytes)
		buffer_addf(buf, " raster=%zu", v->raster_bytes);
	/* A SCISSOR marker realizes no node by design; anything else that did
	 * not is a surface whose client died mid-frame. */
	if (!v->has_node && v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_START
			&& v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_END)
		buffer_adds(buf, " no-node");
	if (v->rbox.width != v->box.width || v->rbox.height != v->box.height
			|| v->rbox.x != v->box.x || v->rbox.y != v->box.y)
		buffer_adds(buf, " [solved!=realized]");
	if (v->mismatch)
		buffer_adds(buf, " [tree!=scene]");
	buffer_adds(buf, "\n");
}

static void
dump_band(buffer_t *buf, struct declare_band *band, struct wlr_output *o,
	const char *name)
{
	if (!band->clay)
		return;
	buffer_addf(buf, "output %s band %s scale %.2f\n", o->name, name,
		o->scale);
	buffer_addf(buf, "  commands %d mutations %d nodes %zu raster_bytes %zu "
		"buffers %d declare %" PRId64 "us solve %" PRId64 "us "
		"reconcile %" PRId64 "us\n",
		band->commands, band->mutations,
		render_node_count(band->render),
		render_raster_bytes(band->render),
		render_buffers_created(band->render),
		band->declare_us, band->solve_us, band->reconcile_us);
	render_walk(band->render, dump_node, buf);
}

char *
declare_dump(Monitor *only)
{
	buffer_t buf = BUFFER_INIT;
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare || (only && m != only))
			continue;
		dump_band(&buf, &m->declare->desktop, m->wlr_output, "desktop");
		dump_band(&buf, &m->declare->lock, m->wlr_output, "lock");
	}
	return buffer_detach(&buf);
}
