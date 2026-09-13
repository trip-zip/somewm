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
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>

#include "clay.h"
#include "clay_impl.h"
#include "declare.h"
#include "objects/drawable.h"
#include "objects/screen.h"
#include "render.h"
#include "render_text.h"
#include "input.h"
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
#include "common/lualib.h"
#include "luaa.h"
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
	/* What the last frame's pass declared, in declaration order, for the
	 * tree dump: the desktop-level elements (roots, client frames, bar
	 * slots, leaves) with their parent, sizing and where each number came
	 * from. A widget tree records its root only; the dump walks its nodes
	 * from the retained widget_tree. Filled by declare_output_frame's pass
	 * alone; queries read the completed declarations and commands. */
	struct declare_record *records;
	size_t records_len, records_cap;
};

/* Where a declared number came from, per doc-1 rule 3: a genuine input
 * (the output, the theme, the protocol, the user's own placement) or a box
 * somewm computed from other boxes, which is what the Clay rebuild retires.
 * A record with no fixed axis carries DECLARE_SRC_NONE. */
enum declare_src {
	DECLARE_SRC_NONE = 0,
	DECLARE_SRC_OUTPUT,
	DECLARE_SRC_THEME,
	DECLARE_SRC_PROTOCOL,
	DECLARE_SRC_USER,
	DECLARE_SRC_LAST_FRAME,
	DECLARE_SRC_DERIVED,
};

struct declare_record {
	const char *role;
	uint64_t handle;       /* the object it stands for, 0 for none */
	uint32_t id;           /* the Clay element id, for the solved box */
	int parent;            /* index into the same array, -1 for a root */
	Clay_Sizing sizing;
	enum declare_src src;
	bool floating;
	Clay_FloatingAttachToElement attach_to;
	uint32_t attach_id;
	Clay_Vector2 offset;
	Clay_FloatingAttachPoints points;
	bool passthrough;
	int16_t band;
	bool vertical;
	Clay_Padding padding;
	uint16_t gap;
	bool custom, image, clip;
	/* A widget tree root: the host whose nodes the dump walks under it. */
	bool has_host;
	struct widget_host host;
};

struct declare_output {
	struct wlr_output *wlr_output;
	struct declare_band desktop;
	struct declare_band lock;
	bool dirty;
	/* The frame deadline: a mark arms it, and an output the backend never
	 * frames (a nested window on an unviewed tag, an asleep monitor) runs
	 * its frame when it fires. */
	struct wl_event_source *deadline;
	bool deadline_armed;
	/* This output's crop of the wallpaper (globalconf.wallpaper), and the
	 * surface generation and layout position it was cut from. */
	struct image_entry wallpaper;
	uint64_t wallpaper_gen;
	int wallpaper_x, wallpaper_y;
	/* The inspector's per-output facts: the desktop context's debug flag
	 * copied as a gate for the seat mirror (refreshed wherever the flag
	 * can change), the press latched for the next solve, and the wheel
	 * delta accumulated for it. */
	bool inspecting;
	bool press_pending;
	double scroll_x, scroll_y;
};

/* Zero hooks until window.c installs the real ones at startup; the
 * reconciler only consults them for CUSTOM commands and borrowed nodes,
 * neither of which can exist before then. */
static struct render_client_hooks client_hooks;

static bool in_frame;

/* The seat mirror (declare.h): the left button's state, where the cursor
 * was last mirrored, the output it was over, and how many outputs show the
 * panel, so the mirror costs a comparison while none does. */
static struct {
	bool down;
	double x, y;
	struct declare_output *over;
	int count;
} insp;

/* Longer than a frame period, so a visible output's frame always wins. */
#define DECLARE_DEADLINE_MS 50
static int deadline_fire(void *data);
static void inspector_resync(void);
static bool inspector_feed(struct declare_output *dout, Monitor *m,
	Clay_Vector2 *point);
static void inspector_emit_closed(Monitor *m);

bool
declare_in_frame(void)
{
	return in_frame;
}

static size_t
shape_ops(void *data, const struct render_shape *shape, float w, float h,
	float *ops, size_t cap)
{
	lua_State *L = globalconf.L;
	int ref = ((const struct widget_shape *)shape)->ref;
	lua_pushnumber(L, w);
	lua_pushnumber(L, h);
	lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
	if (!luaA_dofunction(L, 2, 1))
		return 0;
	size_t len = lua_istable(L, -1) ? luaA_rawlen(L, -1) : 0;
	for (size_t i = 0; i < len; i++) {
		lua_rawgeti(L, -1, i + 1);
		bool number = lua_type(L, -1) == LUA_TNUMBER;
		if (number && i < cap)
			ops[i] = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);
		if (!number) {
			len = 0;
			break;
		}
	}
	lua_pop(L, 1);
	return len;
}

void
declare_set_client_hooks(const struct render_client_hooks *hooks)
{
	client_hooks = *hooks;
	client_hooks.shape_ops = shape_ops;
}

/* --- the handle registry --- */

struct handle_entry {
	void *object;
	enum declare_kind kind;
	uint32_t id;
	uint32_t declared_gen;
};

static struct handle_entry *handles;
static size_t handles_len, handles_cap;
static uint32_t handle_next = 1;
static uint32_t declare_gen;

/* A layout is the unit of the once-per-drawin guard. Every layout must
 * start a new generation, including queries outside the frame walk. */
static void
declare_begin_layout(void)
{
	Clay_BeginLayout();
	declare_gen++;
}

/* --- the declaration record (the tree dump) --- */

static struct declare_band *recording;
static int record_stack[64];
static int record_depth;

static void
record_begin(struct declare_band *band)
{
	recording = band;
	band->records_len = 0;
	record_depth = 0;
}

static void
record_end(void)
{
	recording = NULL;
}

/* Record one opened element under the one currently open, and make it the
 * parent of what follows until record_close. */
static void
record_open(const char *role, uint64_t handle, Clay_ElementId id,
	const Clay_ElementDeclaration *decl, enum declare_src src,
	const struct widget_host *host)
{
	struct declare_band *band = recording;
	struct declare_record *r;

	if (!band)
		return;
	if (band->records_len == band->records_cap) {
		band->records_cap = band->records_cap ? band->records_cap * 2 : 64;
		p_realloc(&band->records, band->records_cap);
	}
	r = &band->records[band->records_len];
	*r = (struct declare_record) {
		.role = role,
		.handle = handle,
		.id = id.id,
		.parent = record_depth > 0 ? record_stack[record_depth - 1] : -1,
		.sizing = decl->layout.sizing,
		.src = src,
		.floating = decl->floating.attachTo != CLAY_ATTACH_TO_NONE,
		.attach_to = decl->floating.attachTo,
		.attach_id = decl->floating.parentId,
		.offset = decl->floating.offset,
        .points = decl->floating.attachPoints,
        .passthrough = decl->floating.pointerCaptureMode == CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
		.band = decl->floating.zIndex,
		.vertical = decl->layout.layoutDirection == CLAY_TOP_TO_BOTTOM,
		.padding = decl->layout.padding,
		.gap = decl->layout.childGap,
		.custom = decl->custom.customData != NULL && decl->custom.customData != RENDER_CLIP_MARK,
		.image = decl->image.imageData != NULL,
		.clip = render_userdata_byte(decl->userData, RENDER_UD_OPENS_SHIFT) != 0,
		.has_host = host != NULL,
	};
	if (host)
		r->host = *host;
	if (record_depth < (int)LENGTH(record_stack))
		record_stack[record_depth] = (int)band->records_len;
	record_depth++;
	band->records_len++;
}

static void
record_close(void)
{
	if (recording && record_depth > 0)
		record_depth--;
}

static uint64_t
handle_pack(enum declare_kind kind, uint32_t id)
{
	return ((uint64_t)kind << 32) | id;
}

/* Chrome scale is tens of objects; linear scans are fine. */
uint64_t
declare_handle_for(void *object, enum declare_kind kind)
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
declare_leaf(const char *role, uint64_t handle, enum declare_src src,
	Clay_ElementId id, Clay_ElementDeclaration *decl)
{
	Clay__OpenElementWithId(id);
	Clay__ConfigureOpenElementPtr(decl);
	record_open(role, handle, id, decl, src, NULL);
	record_close();
	Clay__CloseElement();
}

/* --- the draw order ---
 *
 * The board's band table (doc-2): a flow element has no band, a floating
 * element's band is its zIndex. Clay sorts floating tree roots by zIndex
 * (every floating element is one, clay.h:2102-2107; the sort is at
 * clay.h:2603-2615 and is stable), so declaration order decides only within
 * a band. A window's band comes from its stacking attribute; a transient
 * that sets none of its own inherits its parent's. The rows the table
 * leaves out (layer-shell background and bottom, desktop clients and
 * drawins, a plain wibox, the fullscreen backing) sit between its lines in
 * their old relative order. The flow root is in that sort too, at zIndex 0,
 * so what draws under the bars (a wallpaper wibox, a desktop client, the
 * background and bottom layers) carries a negative band. */
enum {
	/* The output's own fill: the root colour, or the root wallpaper. */
	Z_OUTPUT_BG = -10,
	Z_LAYER_BACKGROUND = -8,
	Z_CLIENT_DESKTOP = -6,
	Z_DRAWIN_BG = -4,
	Z_LAYER_BOTTOM = -2,
	Z_CLIENT_BELOW = 10,
	Z_CLIENT_NORMAL = 20,
	/* A wibox placed by its geometry, neither a bar in flow nor ontop. */
	Z_DRAWIN = 25,
	Z_CLIENT_ABOVE = 30,
	Z_FULLSCREEN_BG = 38,
	Z_CLIENT_FULLSCREEN = 40,
	Z_CLIENT_ONTOP = 50,
	Z_BAR_ONTOP = 60,
	Z_LAYER_TOP = 70,
	/* Popups, menus and tooltips: an ontop drawin, or an xdg popup over its
	 * owner and whatever the owner overlaps. */
	Z_DRAWIN_ONTOP = 80,
	Z_POPUP = 80,
	Z_NOTIFICATION = 90,
	Z_LAYER_OVERLAY = 100,
	/* Override-redirect X11 windows (menus, tooltips, drag icons) carry
	 * no stacking attribute to place them and are always transient UI for
	 * the window below, so they sit above everything. */
	Z_CLIENT_UNMANAGED = 110,
	/* The drag icon rides the pointer above everything on the desktop. */
	Z_DRAG_ICON = 120,
};

/* The lock band is a separate Clay context with its own order: its root
 * element is the opaque backdrop, then the covers, then the lock surface. */
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
	/* Clay's pointer query walks the roots topmost first and stops at
	 * the first floating one it hits unless it passes the pointer
	 * through (clay.h:3913, Clay_SetPointerState); every root here does,
	 * so a query under a drawin reaches the drawin's own tree whatever
	 * lies above it. What takes input is the scene's to decide. */
	decl->floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
}

static Clay_ElementDeclaration
leaf_at(int16_t z, int x, int y, int w, int h)
{
	Clay_ElementDeclaration decl = { 0 };

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
		| ((uint64_t)(1 + (unsigned)(opacity * 254.0f + 0.5f))
			<< RENDER_UD_OPACITY_SHIFT));
}

/* The word with its two clip bytes (render.h): the scope a rectangle opens
 * and the scope the command is clipped by. */
static void *
userdata_clip(void *word, unsigned opens, unsigned clipped_by)
{
	return (void *)((uintptr_t)word
		| (uint64_t)opens << RENDER_UD_OPENS_SHIFT
		| (uint64_t)clipped_by << RENDER_UD_CLIP_SHIFT);
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

/* --- the input walk (declare.h) --- */

static bool declarable_client(Client *c);

struct hit_walk {
	struct declare_hit *out;
	double lx, ly;
};

static bool
hit_accept(void *user, const struct render_node_view *v, double sx, double sy)
{
	struct hit_walk *w = user;
	struct declare_hit *out = w->out;
	enum declare_kind kind = 0;
	void *obj = declare_handle_get(declare_userdata_handle(v->user_data), &kind);
	struct wlr_surface *surface = NULL;
	double sub_x, sub_y;

	if (!obj)
		return false;
	switch (kind) {
	case DECLARE_KIND_DRAWIN: {
		drawin_t *d = obj;

		if (!drawin_accepts_input_at(d, w->lx - d->x, w->ly - d->y))
			return false;
		*out = (struct declare_hit) { kind, d, NULL, 0, 0 };
		return true;
	}
	case DECLARE_KIND_TITLEBAR:
		*out = (struct declare_hit) { kind, obj, NULL, 0, 0 };
		return true;
	case DECLARE_KIND_CLIENT: {
		Client *c = obj;

		/* A retained node outlives its object's visibility by one
		 * frame: a client that just unmapped or minimized is still in
		 * the order, and wlroots' surface_at answers for an unmapped
		 * root surface. Only what the next frame would declare takes
		 * the point. */
		if (!declarable_client(c))
			return false;
		/* The surface leaf: its origin is the window geometry, so the
		 * xdg buffer point adds the geometry offset back; an input hole
		 * falls through. Chrome (the border) is the client anywhere. */
		if (v->type != CLAY_RENDER_COMMAND_TYPE_CUSTOM) {
			*out = (struct declare_hit) { kind, c, NULL, 0, 0 };
			return true;
		}
#ifdef XWAYLAND
		if (client_is_x11(c))
			surface = wlr_surface_surface_at(client_surface(c), sx, sy,
				&sub_x, &sub_y);
		else
#endif
		{
			struct wlr_box geo = COMPAT_XDG_SURFACE_GEOMETRY(c->surface.xdg);

			surface = wlr_xdg_surface_surface_at(c->surface.xdg,
				sx + geo.x, sy + geo.y, &sub_x, &sub_y);
		}
		if (!surface)
			return false;
		*out = (struct declare_hit) { kind, c, surface, sub_x, sub_y };
		return true;
	}
	case DECLARE_KIND_LAYER: {
		LayerSurface *l = obj;

		if (!l->mapped)
			return false;
		surface = wlr_layer_surface_v1_surface_at(l->layer_surface, sx, sy,
			&sub_x, &sub_y);
		if (!surface)
			return false;
		*out = (struct declare_hit) { kind, l, surface, sub_x, sub_y };
		return true;
	}
	case DECLARE_KIND_POPUP: {
		Popup *p = obj;
		Client *c = NULL;
		LayerSurface *l = NULL;
		int type;

		if (!p->popup->base->surface->mapped)
			return false;
		surface = wlr_surface_surface_at(p->popup->base->surface, sx, sy,
			&sub_x, &sub_y);
		if (!surface)
			return false;
		type = toplevel_from_wlr_surface(p->popup->base->surface, &c, &l);
		*out = (struct declare_hit) {
			type == LayerShell ? DECLARE_KIND_LAYER : DECLARE_KIND_CLIENT,
			type == LayerShell ? (void *)l : (void *)c, surface, sub_x, sub_y };
		return true;
	}
	case DECLARE_KIND_LOCK: {
		struct wlr_session_lock_surface_v1 *ls = obj;

		if (!ls->surface->mapped)
			return false;
		surface = wlr_surface_surface_at(ls->surface, sx, sy, &sub_x, &sub_y);
		if (!surface)
			return false;
		*out = (struct declare_hit) { kind, ls, surface, sub_x, sub_y };
		return true;
	}
	default:
		/* The output's own background, the drag icon: nothing takes the
		 * point here; whatever is below may. */
		return false;
	}
}

static bool
hit_band(struct declare_band *band, Monitor *m, struct hit_walk *w)
{
	return band->render && render_hit(band->render, w->lx - m->m.x,
		w->ly - m->m.y, hit_accept, w);
}

/* While locked, only the lock band answers: its backdrop covers the
 * desktop, whose retained nodes must not take input through it. */
static bool
hit_output(Monitor *m, struct hit_walk *w)
{
	if (!m->declare)
		return false;
	if (session_is_locked())
		return hit_band(&m->declare->lock, m, w);
	return hit_band(&m->declare->desktop, m, w);
}

void
declare_hit_at(double lx, double ly, struct declare_hit *out)
{
	struct hit_walk w = { out, lx, ly };
	Monitor *under = xytomon(lx, ly), *m;

	*out = (struct declare_hit) { 0 };
	if (under && hit_output(under, &w))
		return;
	wl_list_for_each(m, &mons, link)
		if (m != under && hit_output(m, &w))
			return;
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

static void
declare_shadow(struct shadow_leaves *s, const shadow_config_t *config,
	Clay_String label, uint64_t handle, int16_t z, int x, int y, int w, int h)
{
	uint32_t id = (uint32_t)handle;
	struct wlr_box boxes[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT];

	shadow_leaves_update(s, config);
	if (!s->ready || !shadow_layout(config, w, h, boxes))
		return;
	float rgba[4] = { config->color[0], config->color[1],
		config->color[2], shadow_paint(config) };
	/* The index participates in the hash (third_party/clay.h:1376).
	 * Sixteen slots per object keep its eleven parts distinct. */
	for (int i = 0; i < SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT; i++) {
		struct wlr_box b = boxes[i];

		if (b.width <= 0 || b.height <= 0)
			continue;
		Clay_ElementDeclaration leaf = leaf_at(z,
			x + b.x, y + b.y, b.width, b.height);
		if (i < SHADOW_SLICE_COUNT) {
			if (!s->tex[i].native)
				continue;
			leaf.image.imageData = &s->tex[i];
		} else {
			leaf.backgroundColor = clay_color(rgba);
		}
		declare_leaf(label.chars, handle, DECLARE_SRC_DERIVED,
			Clay__HashStringWithOffset(label, id * 16 + i, 0), &leaf);
	}
}

static void declare_widget_tree(const struct widget_host *host, int16_t z,
	void *userdata);
static void declare_widget_slot(const struct widget_host *host, Clay_ElementId id,
	const Clay_ElementDeclaration *slot, const char *role, enum declare_src src,
	int16_t z, void *userdata);
static Clay_ElementId output_id(Monitor *m);
static Clay_ElementId workarea_id(Monitor *m);
static bool floating_layout;

/* The popups whose parent is `parent` (a toplevel's or a popup's surface),
 * each a borrowed surface leaf attached to the element `parent_id` and
 * offset by the protocol's popup geometry, then their own popups. The
 * parent's window geometry sits at (geo_x, geo_y) inside its element (0,0
 * for a toplevel's surface leaf, which is the window geometry), and the
 * popup's own geometry offset is folded in, so the leaf is the whole
 * surface, shadow margins included. Creation order keeps parents first. */
static void
declare_popups(struct wlr_surface *parent, Clay_ElementId parent_id,
	int geo_x, int geo_y)
{
	Popup *p;

	wl_list_for_each(p, &popups, link) {
		struct wlr_xdg_popup *popup = p->popup;
		struct wlr_surface *surface = popup->base->surface;
		struct wlr_box geo = popup->base->geometry;
		uint64_t handle;
		Clay_ElementId id;

		if (popup->parent != parent || !p->tree || !surface->mapped)
			continue;
		handle = declare_handle_for(p, DECLARE_KIND_POPUP);
		id = Clay__HashStringWithOffset(CLAY_STRING("popup"), (uint32_t)handle, 0);
		Clay_ElementDeclaration s = {
			.layout.sizing = { CLAY_SIZING_FIXED(surface->current.width),
				CLAY_SIZING_FIXED(surface->current.height) },
			.floating = {
				.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
				.parentId = parent_id.id,
				.offset = { geo_x + popup->current.geometry.x - geo.x,
					geo_y + popup->current.geometry.y - geo.y },
				.zIndex = Z_POPUP,
				.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
			},
			.custom.customData = (void *)(uintptr_t)handle,
			.userData = leaf_userdata(handle, 1.0f),
		};
		declare_leaf("popup", handle, DECLARE_SRC_PROTOCOL, id, &s);
		declare_popups(surface, id, geo.x, geo.y);
	}
}

static void
declare_titlebar(Client *c, client_titlebar_t bar, uint32_t id, int16_t z)
{
	struct widget_host host;
	int size = c->titlebar[bar].size;

	if (size == 0 || !client_titlebar_host(c, c->titlebar[bar].drawable, &host))
		return;
	bool horizontal = bar == CLIENT_TITLEBAR_TOP || bar == CLIENT_TITLEBAR_BOTTOM;
	uint64_t handle = declare_handle_for(c->titlebar[bar].drawable, DECLARE_KIND_TITLEBAR);
	Clay_ElementDeclaration e = {
		.layout.sizing = {
			horizontal ? CLAY_SIZING_GROW(0) : CLAY_SIZING_FIXED(size),
			horizontal ? CLAY_SIZING_FIXED(size) : CLAY_SIZING_GROW(0),
		},
	};

	static const char *const roles[] = {
		"TITLEBAR", "TITLEBAR_RIGHT", "TITLEBAR_BOTTOM", "TITLEBAR_LEFT",
	};
	Clay_ElementId slot = Clay__HashStringWithOffset(
		CLAY_STRING("client.titlebar"), id * 4 + bar, 0);

	if (host.tree->nodes_len > 0) {
		host.flow = true;
		declare_widget_slot(&host, slot, &e, roles[bar], DECLARE_SRC_THEME,
			z, leaf_userdata(handle, 1.0f));
		return;
	}
	Clay__OpenElementWithId(slot);
	Clay__ConfigureOpenElementPtr(&e);
	record_open(roles[bar], handle, slot, &e, DECLARE_SRC_THEME, NULL);
	record_close();
	Clay__CloseElement();
}

/* Padding starts the children inside the border (third_party/clay.h:2704).
 * Fixed bars leave the growing surface the remaining space
 * (third_party/clay.h:2349-2392, 2409-2411). */
static void
declare_client(Client *c, Monitor *m, int16_t z, const Clay_ElementDeclaration *allocation)
{
	uint64_t handle = declare_handle_for(c, DECLARE_KIND_CLIENT);
	uint32_t id = (uint32_t)handle;
	int bw = c->fullscreen ? 0 : c->bw;
	int fw = c->geometry.width + 2 * bw;
	int fh = c->geometry.height + 2 * bw;
	int x = c->geometry.x - m->m.x;
	int y = c->geometry.y - m->m.y;
	bool clamp = client_clamps_to_monitor(c);

	if (!allocation && clamp && (x + bw + c->geometry.width <= 0
			|| y + bw + c->geometry.height <= 0
			|| x + bw >= m->m.width
			|| y + bw >= m->m.height))
		return;

	if (!allocation)
	declare_shadow(&c->shadow,
		shadow_get_effective_config(c->shadow_config, false),
		CLAY_STRING("client.shadow"), handle, z, x, y, fw, fh);
    Clay_ElementDeclaration frame = allocation
        ? *allocation
        : leaf_at(z, x, y, fw, fh);
	if (!allocation && !client_is_unmanaged(c)) {
		frame.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
		frame.floating.parentId = output_id(m).id;
		if (c->fullscreen) {
			frame.layout.sizing = (Clay_Sizing) { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) };
			frame.floating.offset = (Clay_Vector2) { 0, 0 };
		}
	}
	frame.layout.layoutDirection = CLAY_TOP_TO_BOTTOM;
	frame.layout.padding = (Clay_Padding) { bw, bw, bw, bw };
	frame.userData = leaf_userdata(handle, 1.0f);
	if (clamp)
		frame.userData = userdata_clip(frame.userData, 0, RENDER_CLIP_BOUNDS);
	if (bw > 0) {
		float rgba[4];

		client_border_rgba(c, rgba);
		frame.border.color = clay_color(rgba);
		frame.border.width = (Clay_BorderWidth) { bw, bw, bw, bw, 0 };
	}
	/* Native layouts contribute sizing/attachments. Remaining old layouts
	 * still expose derived rectangles; user placement and protocol inputs
	 * retain their own provenance. */
	enum declare_src src = allocation ? DECLARE_SRC_THEME : client_is_unmanaged(c) ? DECLARE_SRC_PROTOCOL
		: c->fullscreen ? DECLARE_SRC_OUTPUT
		: some_client_get_floating(c) || floating_layout ? DECLARE_SRC_USER
		: c->ontop || c->above || c->below ? DECLARE_SRC_LAST_FRAME : DECLARE_SRC_DERIVED;
	Clay_ElementId frame_id = Clay__HashStringWithOffset(CLAY_STRING("client"), id, 0);

	Clay__OpenElementWithId(frame_id);
	Clay__ConfigureOpenElementPtr(&frame);
	record_open("CLIENT", handle, frame_id, &frame, src, NULL);
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_TOP, id, z);
	Clay_ElementDeclaration row = {
		.layout = {
			.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
			.layoutDirection = CLAY_LEFT_TO_RIGHT,
		},
	};
	Clay_ElementId row_id = Clay__HashStringWithOffset(CLAY_STRING("client.row"), id, 0);

	bool sides = !c->fullscreen && (c->titlebar[CLIENT_TITLEBAR_LEFT].size
		|| c->titlebar[CLIENT_TITLEBAR_RIGHT].size);
	if (sides) {
		Clay__OpenElementWithId(row_id);
		Clay__ConfigureOpenElementPtr(&row);
		record_open("CLIENT_BODY", handle, row_id, &row, DECLARE_SRC_NONE, NULL);
	}
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_LEFT, id, z);
	Clay_ElementDeclaration surface = {
		.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		.custom.customData = (void *)(uintptr_t)handle,
		.userData = leaf_userdata(handle,
			c->opacity >= 0 ? (float)c->opacity : 1.0f),
	};
	Clay_ElementId surface_id = Clay__HashStringWithOffset(
		CLAY_STRING("client.surface"), id, 0);
	float minw = 0, minh = 0, maxw = 0, maxh = 0;
	if (c->size_hints_honor && !c->fullscreen) {
		if (c->client_type == XDGShell) {
			struct wlr_xdg_toplevel_state hints = c->surface.xdg->toplevel->current;
			minw = hints.min_width; minh = hints.min_height;
			maxw = hints.max_width; maxh = hints.max_height;
		} else {
			minw = c->size_hints.min_width; minh = c->size_hints.min_height;
			maxw = c->size_hints.max_width; maxh = c->size_hints.max_height;
		}
	}
	surface.layout.sizing = (Clay_Sizing) {
		CLAY_SIZING_GROW(minw, maxw), CLAY_SIZING_GROW(minh, maxh),
	};
	/* Hints belong to the surface, never the percent slot. On the cross
	 * axis Clay lets this leaf overhang a narrower slot (decision 1). */
	declare_leaf("SURFACE", handle, minw || minh || maxw || maxh
		? DECLARE_SRC_PROTOCOL : DECLARE_SRC_NONE, surface_id,
		&surface);
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_RIGHT, id, z);
	if (sides) {
		record_close();
		Clay__CloseElement();
	}
	if (!c->fullscreen)
		declare_titlebar(c, CLIENT_TITLEBAR_BOTTOM, id, z);
	record_close();
	Clay__CloseElement();
	/* The client's popups attach to its surface leaf, declared above. */
	declare_popups(client_surface(c), surface_id, 0, 0);
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
	if (c->fullscreen)
		return c->ontop ? Z_CLIENT_ONTOP : Z_CLIENT_FULLSCREEN;

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

static bool layout_client_declaration(Client *c, Monitor *m, Clay_ElementDeclaration *e);

/* Inheriting transients ride their parent: declared right above it in the
 * band it resolved to, mirroring stack_transients_above() (stack.c).
 * Unmanaged children are excluded; declare_unmanaged_clients() owns every
 * unmanaged client, and declaring one here too would hash a duplicate Clay
 * id and abort. */
static void
declare_client_tree(Client *c, Monitor *m)
{
	Clay_ElementDeclaration e;
	bool native = layout_client_declaration(c, m, &e);
	if (native) c->clay_tiled = true;
	bool inset = native && e.layout.padding.left;
	if (inset) {
		Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("client.cell"),
			(uint32_t)declare_handle_for(c, DECLARE_KIND_CLIENT), 0);
		Clay__OpenElementWithId(id);
		Clay__ConfigureOpenElementPtr(&e);
		record_open("CELL", 0, id, &e, DECLARE_SRC_THEME, NULL);
		/* The inset is the allocation; surface protocol minima may
		 * overhang it without expanding the client border/titlebar area. */
		e = (Clay_ElementDeclaration) {
			.layout.sizing = { CLAY_SIZING_PERCENT(1), CLAY_SIZING_PERCENT(1) },
		};
	}
	declare_client(c, m, client_z(c), native ? &e : NULL);
	if (inset) {
		record_close();
		Clay__CloseElement();
	}
	foreach(node, globalconf.stack)
		if ((*node)->transient_for == c && (*node)->mon == m
				&& !client_is_unmanaged(*node)
				&& !(*node)->clay_tiled
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
	Clay_ElementDeclaration e;

	return p && p->mon == m && transient_inherits(c)
		&& (!p->clay_tiled || layout_client_declaration(p, m, &e))
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
		if (!c || c->mon != m || client_is_unmanaged(c) || c->clay_tiled)
			continue;
		if (transient_rides_parent(c, m))
			continue;
		if (!declarable_client(c))
			continue;
		declare_client_tree(c, m);
	}
}

/* Lua contributes the slot tree, retaining the AwesomeWM client order and
 * tag policy. C translates sizing and composition directly to Clay. */
static int tile_ref = LUA_NOREF;

static void
tile_prepare(Monitor *m)
{
    lua_State *L = globalconf_L;
    int top = lua_gettop(L);
    foreach(node, globalconf.clients)
        if ((*node)->mon == m) (*node)->clay_tiled = false;
    luaL_unref(L, LUA_REGISTRYINDEX, tile_ref);
    tile_ref = LUA_NOREF;
    floating_layout = false;
    lua_getglobal(L, "require");
    lua_pushliteral(L, "awful.layout");
    if (lua_pcall(L, 1, 1, 0)) goto done;
    lua_getfield(L, -1, "_clay_describe");
    luaA_screen_push(L, luaA_screen_get_by_monitor(L, m));
    if (lua_pcall(L, 1, 2, 0)) goto done;
    floating_layout = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (lua_istable(L, -1)) tile_ref = luaL_ref(L, LUA_REGISTRYINDEX);
done:
    lua_settop(L, top);
}

static float
slot_number(lua_State *L, int index, const char *key)
{
    lua_getfield(L, index, key);
    float value = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return value;
}

/* Absence means GROW; an authored zero remains a percentage allocation. */
static Clay_SizingAxis
slot_sizing(lua_State *L, int index, const char *key)
{
    lua_getfield(L, index, key);
    bool specified = lua_isnumber(L, -1);
    float share = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return specified ? CLAY_SIZING_PERCENT(share) : CLAY_SIZING_GROW(0);
}

/* Native layout floats are looked up by original client while the existing
 * stack walk declares them. This retains raise/lower and transient order;
 * the Lua map contains attachment/sizing policy, never solved rectangles. */
static bool
layout_client_declaration(Client *c, Monitor *m, Clay_ElementDeclaration *e)
{
    lua_State *L = globalconf_L;
    int top = lua_gettop(L);
    bool found = false;
    if (tile_ref == LUA_NOREF) return false;
    lua_rawgeti(L, LUA_REGISTRYINDEX, tile_ref);
    lua_getfield(L, -1, "floating");
    if (!lua_istable(L, -1)) goto done;
    luaA_object_push(L, c);
    lua_rawget(L, -2);
    if (!lua_istable(L, -1)) goto done;
    int pad = slot_number(L, -1, "padding");
    *e = (Clay_ElementDeclaration) {
        .layout.sizing = { slot_sizing(L, -1, "w"), slot_sizing(L, -1, "h") },
        .floating = {
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
            .parentId = workarea_id(m).id,
            .zIndex = client_z(c),
            .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        },
    };
    e->layout.padding = (Clay_Padding) { pad, pad, pad, pad };
    lua_getfield(L, -1, "attach_to");
    if (lua_isstring(L, -1) && !strcmp(lua_tostring(L, -1), "output"))
        e->floating.parentId = output_id(m).id;
    lua_pop(L, 1);
    lua_getfield(L, -1, "center");
    if (lua_toboolean(L, -1))
        e->floating.attachPoints = (Clay_FloatingAttachPoints) {
            .element = CLAY_ATTACH_POINT_CENTER_CENTER,
            .parent = CLAY_ATTACH_POINT_CENTER_CENTER,
        };
    lua_pop(L, 1);
    found = true;
done:
    lua_settop(L, top);
    return found;
}

static void
declare_tile_slot(Monitor *m, int index, unsigned ordinal, bool root)
{
    lua_State *L = globalconf_L;
    index = luaA_absindex(L, index);
    Clay_ElementDeclaration e = {
        .layout.sizing = { slot_sizing(L, index, "w"), slot_sizing(L, index, "h") },
    };
    lua_getfield(L, index, "contain_size");
    e.layout.sizeContain = lua_toboolean(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, index, "client");
    if (lua_isuserdata(L, -1)) {
        Client *c = luaA_checkudata(L, -1, &client_class);
        lua_pop(L, 1);
        if (declarable_client(c)) {
            c->clay_tiled = true;
            declare_client(c, m, 0, &e);
        }
        return;
    }
    lua_pop(L, 1);
    int gap = slot_number(L, index, "gap");
    int pad = slot_number(L, index, "padding");
    e.layout.childGap = gap;
    lua_getfield(L, index, "ceil_grow");
    e.layout.ceilGrow = lua_toboolean(L, -1);
    lua_pop(L, 1);
    e.layout.padding = (Clay_Padding) { pad, pad, pad, pad };
    lua_getfield(L, index, "direction");
    e.layout.layoutDirection = !strcmp(lua_tostring(L, -1), "column")
        ? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT;
    lua_pop(L, 1);
    lua_getfield(L, index, "center");
    if (lua_toboolean(L, -1)) {
        if (e.layout.layoutDirection == CLAY_TOP_TO_BOTTOM)
            e.layout.childAlignment.y = CLAY_ALIGN_Y_CENTER;
        else
            e.layout.childAlignment.x = CLAY_ALIGN_X_CENTER;
    }
    lua_pop(L, 1);
    lua_getfield(L, index, "role");
    const char *role = lua_tostring(L, -1);
    Clay_ElementId id = root ? workarea_id(m)
        : Clay__HashStringWithOffset(CLAY_STRING("tile.run"), ordinal, workarea_id(m).id);
    Clay__OpenElementWithId(id);
    Clay__ConfigureOpenElementPtr(&e);
    record_open(role, 0, id, &e, gap || pad ? DECLARE_SRC_THEME : DECLARE_SRC_NONE, NULL);
    lua_getfield(L, index, "children");
    for (unsigned i = 1; i <= lua_objlen(L, -1); i++) {
        lua_rawgeti(L, -1, i);
        declare_tile_slot(m, -1, ordinal * 31 + i, false);
        lua_pop(L, 1);
    }
    lua_pop(L, 2);
    record_close();
    Clay__CloseElement();
}

static void
declare_workarea(Monitor *m)
{
    if (tile_ref != LUA_NOREF) {
        lua_rawgeti(globalconf_L, LUA_REGISTRYINDEX, tile_ref);
        declare_tile_slot(m, -1, 1, true);
        lua_pop(globalconf_L, 1);
    } else {
        Clay_ElementDeclaration e = {
            .layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
        };
        declare_leaf("WORKAREA", 0, DECLARE_SRC_NONE, workarea_id(m), &e);
    }
}

static void
clients_settle(Monitor *m)
{
    foreach(node, globalconf.clients) {
        Client *c = *node;
        if (c->mon != m || (!c->clay_tiled && !c->fullscreen)
                || !declarable_client(c)) continue;
        Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("client"),
            (uint32_t)declare_handle_for(c, DECLARE_KIND_CLIENT), 0);
        Clay_ElementData data = Clay_GetElementData(id);
        if (!data.found) continue;
        Clay_BoundingBox b = data.boundingBox;
        int x = lroundf(b.x), y = lroundf(b.y);
        client_set_solved_geometry(c, (area_t) {
            .x = m->m.x + x, .y = m->m.y + y,
            .width = MAX(1, lroundf(b.x+b.width) - x - (c->fullscreen ? 0 : 2*c->bw)),
            .height = MAX(1, lroundf(b.y+b.height) - y - (c->fullscreen ? 0 : 2*c->bw)),
        });
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
		declare_client(c, m, client_z(c), NULL);
	}
}

/* --- the converted widget tree (widget.h) ---
 *
 * One element per node, nested as lua/wibox/clay.lua compiled them. The
 * root is the drawable's box, or the host slot with the same area. Distinct
 * host insets keep a separate content element.
 * Clipping is the renderer's, not Clay's: a Clay clip element is a scroll
 * container, a context holds ten (clay.h:2194), and one clipping axis stops
 * Clay compressing the children along it (clay.h:2305-2311). Instead every
 * node's word names the scope it is clipped by and, for the root and a
 * rounded container, the scope it opens (widget.c numbers them, render.h
 * says how the renderer reads them), so a layout that overflows draws
 * nothing outside the drawin and a rounded background cuts its children to
 * its arc, as the container's own clip did.
 *
 * The tree records its actual declared root ID. Original widget occurrences
 * retain stable IDs across sibling changes and host combination; anonymous
 * structure follows its parent's path, and unbound text uses Clay's hash.
 *
 * Every node carries the drawin's handle in userData, containers included:
 * the pointer over a gap between leaves lands on a container's rectangle,
 * and declare_hit has to resolve that node to the drawin (input.c then takes
 * drawin-local coordinates from the drawin's own box, not the node's).
 */
/* This pass's widget identities resolve to their declared Clay elements. */
static struct { uint32_t identity, occurrence, host, id; } *attachment_targets;
static size_t attachment_targets_len, attachment_targets_cap;

static void
attachment_bind(struct widget_binding binding, uint32_t host, uint32_t id)
{
	if (!binding.identity)
		return;
	if (attachment_targets_len == attachment_targets_cap) {
		attachment_targets_cap = attachment_targets_cap ? attachment_targets_cap * 2 : 64;
		p_realloc(&attachment_targets, attachment_targets_cap);
	}
	attachment_targets[attachment_targets_len].identity = binding.identity;
	attachment_targets[attachment_targets_len].occurrence = binding.occurrence;
	attachment_targets[attachment_targets_len].host = host;
	attachment_targets[attachment_targets_len++].id = id;
}

static unsigned
attachment_occurrences(const struct widget_tree *tree, uint32_t identity)
{
    unsigned count = 0;
    for (size_t i = 0; i < tree->bindings_len && count < 2; i++)
        count += tree->bindings[i].identity == identity;
    return count;
}

/* Before the first completed frame Lua may have no occurrence registry yet.
 * Count authored visible placements in the stored trees, including attachment
 * hosts that have not been declared yet. Declaration order cannot select one
 * copy of an ambiguous target. This reads identity metadata, never boxes. */
static bool
attachment_is_ambiguous(uint32_t identity, uint32_t host_id)
{
    unsigned count = 0;
    if (host_id) {
        drawin_t *d = declare_handle_get(handle_pack(DECLARE_KIND_DRAWIN, host_id), NULL);
        if (d)
            return d->visible && d->screen && !some_is_lock_drawin(d)
                && attachment_occurrences(&d->widgets, identity) > 1;
        drawable_t *drawable = declare_handle_get(handle_pack(DECLARE_KIND_TITLEBAR, host_id), NULL);
        Client *c = drawable && drawable->owner_type == DRAWABLE_OWNER_CLIENT
            ? drawable->owner.client : NULL;
        if (c && declarable_client(c) && !c->fullscreen)
            for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++)
                if (c->titlebar[bar].drawable == drawable && c->titlebar[bar].size)
                    return attachment_occurrences(&c->titlebar[bar].widgets, identity) > 1;
        return false;
    }
    foreach(item, globalconf.drawins) {
        drawin_t *d = *item;
        if (d->visible && d->screen && !some_is_lock_drawin(d))
            count += attachment_occurrences(&d->widgets, identity);
        if (count > 1) return true;
    }
    foreach(item, globalconf.clients) {
        Client *c = *item;
        if (!declarable_client(c) || c->fullscreen) continue;
        for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++) {
            if (c->titlebar[bar].size)
                count += attachment_occurrences(&c->titlebar[bar].widgets, identity);
            if (count > 1) return true;
        }
    }
    return false;
}

static uint32_t
attachment_target(drawin_t *d)
{
    uint32_t identity = d->attachment.target, occurrence = d->attachment.occurrence;
    uint32_t id = 0;
    if (!occurrence && attachment_is_ambiguous(identity, d->attachment.host)) {
        if (!d->attachment_ambiguous)
            wlr_log(WLR_ERROR, "ambiguous attachment target %"PRIu32
                "; pass a widget hit with its occurrence", identity);
        d->attachment_ambiguous = true;
        return 0;
    }
    for (size_t i = 0; i < attachment_targets_len; i++)
        if (attachment_targets[i].identity == identity
                && (!d->attachment.host || attachment_targets[i].host == d->attachment.host)
                && (!occurrence || attachment_targets[i].occurrence == occurrence)) {
            if (id && id != attachment_targets[i].id) return 0;
            id = attachment_targets[i].id;
        }
    return id;
}

static Clay_ElementId
widget_root_id(uint32_t id)
{
	return Clay__HashStringWithOffset(CLAY_STRING("drawin.widget"), id, 0);
}

/* Clay's own hash of a child index under a parent id (Clay__HashNumber,
 * clay.h, which the header keeps to itself), verbatim: a text element gets
 * exactly this id from Clay__OpenTextElement, and reading its box back
 * means computing the same one. */
static uint32_t
clay_hash_number(uint32_t offset, uint32_t seed)
{
	uint32_t hash = seed;

	hash += (offset + 48);
	hash += (hash << 10);
	hash ^= (hash >> 6);
	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);
	return hash + 1;
}

/* Widget elements, including promoted text, use stable placement tokens.
 * Unbound text uses Clay's index hash, including floating siblings. Anonymous structure
 * uses its parent's path. Emission, readback and inspection share this rule. */
static Clay_ElementId
widget_child_id(struct widget_tree *d, size_t child, Clay_ElementId parent,
	uint16_t index)
{
	if (d->nodes[child].occurrence)
		return Clay__HashStringWithOffset(CLAY_STRING("widget.occurrence"),
			d->nodes[child].occurrence, 0);
	if (d->nodes[child].text)
		return (Clay_ElementId) { .id = clay_hash_number(index, parent.id) };
	return Clay__HashStringWithOffset(CLAY_STRING("drawin.widget"), index, parent.id);
}

static Clay_SizingAxis
widget_sizing(const struct widget_node *n, int axis)
{
	switch (n->sizing[axis]) {
	case WIDGET_SIZING_FIXED:
		return CLAY_SIZING_FIXED(n->size[axis]);
	case WIDGET_SIZING_PERCENT:
		/* Percent has no min/max clamps (third_party/clay.h:1863-1871). */
		return CLAY_SIZING_PERCENT(n->size[axis]);
	case WIDGET_SIZING_GROW:
		return CLAY_SIZING_GROW(n->min[axis], n->max[axis]);
	default:
		return CLAY_SIZING_FIT(n->min[axis], n->max[axis]);
	}
}

static Clay_ElementDeclaration
widget_node_decl(const struct widget_node *n, int16_t z,
	void *userdata)
{
	Clay_ElementDeclaration e = {
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

	if (!n->shape && n->bg[3] > 0)
		e.backgroundColor = clay_color(n->bg);
	else if (n->clip_opens)
		/* A transparent root, or a rounded container with no fill, still
		 * clips what it holds: Clay draws a RECTANGLE only for a fill, so
		 * the scope rides a CUSTOM command the renderer realizes as an
		 * input-only rect (render.h). */
		e.custom.customData = RENDER_CLIP_MARK;
	if (n->border[3] > 0) {
		e.border.color = clay_color(n->border);
		e.border.width = (Clay_BorderWidth) {
			n->bw[0], n->bw[1], n->bw[2], n->bw[3], 0 };
	}
	if (n->scroll) {
		e.clip = (Clay_ClipElementConfig) {
			.horizontal = n->scroll == 1,
			.vertical = n->scroll == 2,
			.childOffset = { n->scroll == 1 ? -n->scrolled : 0,
				n->scroll == 2 ? -n->scrolled : 0 },
		};
	}
	if (n->floating) {
		/* A stack child: off the flow, at the parent's top left, in the
		 * drawin's band (a floating element is its own tree root, sorted
		 * by zIndex and then declaration order, clay.h:2603-2615). */
		e.floating.offset = (Clay_Vector2) { n->offset[0], n->offset[1] };
		e.floating.attachTo = CLAY_ATTACH_TO_PARENT;
		e.floating.zIndex = z;
		/* A stack child lies over its siblings and passes the pointer
		 * through to them, as every widget under the point is under it
		 * (place_fixed says the same of the roots). */
		e.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
	}
	return e;
}

static size_t
declare_widget_subtree(const struct widget_host *host, size_t i, Clay_ElementId id, int16_t z,
	void *userdata, size_t *leaf, const Clay_ElementDeclaration *root_decl)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	void *word = userdata_clip(userdata, n->clip_opens, n->clip_by);
	Clay_ElementDeclaration e;
	size_t next = i + 1;

	for (uint32_t k = 0; k < n->binding_count; k++)
		attachment_bind(d->bindings[n->binding_start + k], host->id, id.id);

	/* A text element, as CLAY_TEXT declares one: the run and its config,
	 * no children, the drawin's word riding the config's userData to the
	 * renderer with the ellipsize flag in it (render_text.h), so the run
	 * clips like its siblings and a pointer over the glyphs is the
	 * drawin's. */
	if (n->text) {
		Clay_TextElementConfig cfg = {
			.userData = (void *)((uintptr_t)word
				| (n->ellipsize ? RENDER_TEXT_ELLIPSIZE : 0)),
			.textColor = clay_color(n->fg),
			.fontId = n->font,
			.wrapMode = n->wrap,
			.textAlignment = n->text_align,
		};
		Clay_TextElementLayout layout = {
			.growWidth = n->sizing[0] == WIDGET_SIZING_GROW,
			.growHeight = n->sizing[1] == WIDGET_SIZING_GROW,
			.verticalAlignment = n->align[1],
		};
		Clay__OpenTextElementWithLayout(id, (Clay_String) {
			.length = (int32_t)n->text_len,
			.chars = d->text + n->text_off,
		}, cfg, n->text_layout ? &layout : NULL);
		return next;
	}

	e = root_decl ? *root_decl : widget_node_decl(n, z, word);
	/* Definite hosts keep overflowing content at its own size. Passive
	 * native clipping replaces the old FLOAT/FIT root's previous-size floor. */
	if (i == 0 && n->sizing[0] == WIDGET_SIZING_FIXED
			&& n->sizing[1] == WIDGET_SIZING_FIXED)
		e.clip = (Clay_ClipElementConfig) {.horizontal = true, .vertical = true, .passive = true};
	if (i == 0 && host->flow && !root_decl) {
		/* A bar's root fills the slot the frame sized for it; the
		 * drawin's geometry is what this element solves to. */
		e.layout.sizing = (Clay_Sizing) {
			host->fit[0] ? widget_sizing(n, 0) : host->told[0] ? CLAY_SIZING_FIXED(host->told[0]) : CLAY_SIZING_GROW(0),
			host->fit[1] ? widget_sizing(n, 1) : host->told[1] ? CLAY_SIZING_FIXED(host->told[1]) : CLAY_SIZING_GROW(0),
		};
	} else if (i == 0 && !root_decl) {
		/* A titlebar root attaches at its parent's origin; a drawin
		 * uses an output-local offset (third_party/clay.h:2074-2080,
		 * 2625-2677). Fixed axes use the host box, while an awful.popup
		 * fits within its tree's limits. */
		e.floating.offset = host->in_parent ? (Clay_Vector2) { 0, 0 }
			: (Clay_Vector2) { host->x, host->y };
		e.floating.attachTo = host->in_parent
			? CLAY_ATTACH_TO_PARENT : CLAY_ATTACH_TO_ROOT;
		e.floating.zIndex = z;
		e.layout.sizing = (Clay_Sizing) {
			n->sizing[0] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->w) : widget_sizing(n, 0),
			n->sizing[1] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->h) : widget_sizing(n, 1),
		};
	}
	/* A shaped drawin's masks, as the root's corners (drawin.h
	 * shape_radius), which the root's clip scope carries to every node
	 * under it. */
	if (i == 0 && host->radius > 0)
		e.cornerRadius = (Clay_CornerRadius) { host->radius,
			host->radius, host->radius, host->radius };
	if (n->image && *leaf < d->leaves_len)
		e.image.imageData = &d->leaves[(*leaf)++];
	if (n->shape)
		e.custom.customData = render_shape_tag(&d->shapes[n->shape - 1].shape);

	Clay__OpenElementWithId(id);
	Clay__ConfigureOpenElementPtr(&e);
	if (i == 0 && !host->flow) {
		/* The root stands for the drawin, at the box placement gave it;
		 * a titlebar's root fills the slot the theme sized. The nodes
		 * under it are the tree's own, walked from the store. A bar's
		 * slot recorded itself with this host. */
		bool fixed = n->sizing[0] == WIDGET_SIZING_FIXED
			|| n->sizing[1] == WIDGET_SIZING_FIXED;

		record_open(host->in_parent ? "widgets" : "drawin",
			userdata ? declare_userdata_handle(userdata) : 0, id, &e,
			!fixed ? DECLARE_SRC_NONE : host->in_parent
				? DECLARE_SRC_THEME : DECLARE_SRC_DERIVED, host);
	}
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_widget_subtree(host, next,
			widget_child_id(d, next, id, k), z, userdata, leaf, NULL);
	if (i == 0 && !host->flow)
		record_close();
	Clay__CloseElement();
	return next;
}

/* The trees this pass declares for the first time since they changed: after
 * the solve, each drawable hears clay::solved with its boxes. */
static struct widget_host *solved_hosts;
static size_t solved_len, solved_cap;

static void
declare_widget_tree_at(const struct widget_host *host, Clay_ElementId id, int16_t z,
	void *userdata, const Clay_ElementDeclaration *root_decl)
{
	struct widget_tree *d = host->tree;
	size_t leaf = 0;

	if (d->root_id != id.id)
		d->declared = false;
	d->root_id = id.id;
	if (!d->declared) {
		d->declared = true;
		if (solved_len == solved_cap) {
			solved_cap = solved_cap ? solved_cap * 2 : 16;
			p_realloc(&solved_hosts, solved_cap);
		}
		solved_hosts[solved_len++] = *host;
	}
	declare_widget_subtree(host, 0, id, z, userdata, &leaf, root_decl);
}

static void
declare_widget_tree(const struct widget_host *host, int16_t z, void *userdata)
{
	declare_widget_tree_at(host, widget_root_id(host->id), z, userdata, NULL);
}

/* The slot and drawable have equal areas: keep the slot's authored sizing
 * and attachment, and the drawable's paint, clipping and child arrangement.
 * Callers retain distinct content elements for margins/non-stretched bars. */
static void
declare_widget_slot(const struct widget_host *host, Clay_ElementId id,
	const Clay_ElementDeclaration *slot, const char *role, enum declare_src src,
	int16_t z, void *userdata)
{
	const struct widget_node *n = &host->tree->nodes[0];
	Clay_ElementDeclaration e = widget_node_decl(n, z,
		userdata_clip(userdata, n->clip_opens, n->clip_by));
	e.layout.sizing = slot->layout.sizing;
	e.floating = slot->floating;
	if (host->radius > 0)
		e.cornerRadius = (Clay_CornerRadius) {host->radius, host->radius,
			host->radius, host->radius};
	record_open(role, declare_userdata_handle(userdata), id, &e, src, host);
	declare_widget_tree_at(host, id, z, userdata, &e);
	record_close();
}

/* --- drawins ---
 *
 * Shadow leaves below border below content. The drawin owns their image
 * entries; gen bumps on content change.
 * Opacity applies to the content leaf only, matching the old scene-buffer
 * path, which never set opacity on the border or shadow. */
static void
declare_drawin(drawin_t *d, Monitor *m, int16_t z)
{
	uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
	uint32_t id = (uint32_t)handle;
	int bw = d->border_width;
	int x = d->x - m->m.x;
	int y = d->y - m->m.y;
	float opacity = d->opacity >= 0 ? (float)d->opacity : 1.0f;

	/* First declaration in this layout wins, including its z order. */
	for (size_t i = 0; i < handles_len; i++) {
		if (handles[i].id != id)
			continue;
		if (handles[i].declared_gen == declare_gen)
			return;
		handles[i].declared_gen = declare_gen;
		break;
	}

	declare_shadow(&d->shadow,
		shadow_get_effective_config(d->shadow_config, true),
		CLAY_STRING("drawin.shadow"), handle, z, x, y, d->width, d->height);
	if (bw > 0 && d->border_entry.native) {
		/* No userData: the input filter (window.c hook_accepts_input)
		 * reads a bare word as "never accepts input", which is what the
		 * old border_buffer's point_accepts_input answered, and the
		 * shadow leaf below gets the same treatment for free. */
		Clay_ElementDeclaration b = leaf_at(z, x - bw, y - bw,
			d->width + 2 * bw, d->height + 2 * bw);
		b.image.imageData = &d->border_entry;
		declare_leaf("drawin.border", handle, DECLARE_SRC_DERIVED,
			Clay__HashStringWithOffset(CLAY_STRING("drawin.border"), id, 0), &b);
	}

	/* The widget tree declares the drawin's content. */
	if (d->widgets.nodes_len > 0) {
		struct widget_host host;

		if (drawin_widget_host(d, &host))
			declare_widget_tree(&host, z, leaf_userdata(handle, opacity));
		return;
	}

}

/* A desktop drawin covering its screen (awful.wallpaper): a slot floating
 * over the output, grow by grow, holding the tree as a child that fills it,
 * so no number of its own enters the tree. */
static bool
drawin_covers_output(drawin_t *d, Monitor *m)
{
	return d->type == WINDOW_TYPE_DESKTOP && d->x == m->m.x && d->y == m->m.y
		&& d->width == m->m.width && d->height == m->m.height;
}

static void
declare_wallpaper_drawin(drawin_t *d, Monitor *m, int16_t z)
{
	uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
	float opacity = d->opacity >= 0 ? (float)d->opacity : 1.0f;
	struct widget_host host;
	Clay_ElementDeclaration slot = {
		.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		.floating = {
			.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
			.parentId = output_id(m).id,
			.zIndex = z,
			.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
		},
	};
	Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("WALLPAPER"),
		(uint32_t)handle, 0);

	if (!drawin_widget_host(d, &host))
		return;
	host.flow = true;
	declare_widget_slot(&host, id, &slot, "WALLPAPER", DECLARE_SRC_NONE,
		z, leaf_userdata(handle, opacity));
}

/* A visible drawin declares once its first compile stores a tree. */
static bool
declarable_drawin(drawin_t *d, Monitor *m)
{
	return d->visible
		&& d->widgets.nodes_len > 0
		&& d->screen && d->screen->monitor == m;
}

/* --- layer surfaces ---
 *
 * A layer surface is a slot holding its surface leaf, the way a wibar is:
 * the slot's padding is the protocol's margins and its child alignment its
 * anchors, and the leaf is the size the client asked for, or grow on an
 * axis anchored to both sides (protocol). A surface with an exclusive zone
 * at an edge is a bar in the output's flow at that edge, the slot fixed
 * across it by the zone plus the margin there. Any other floats in its
 * layer's band over the workarea, which is what the zones leave and where
 * wlroots arranged it, or over the whole output for a zone of -1. A surface
 * is declared once it is initialized: its first configure carries the size
 * the tree solved, and it maps into it. Until it maps it takes no input
 * (hit_accept). */
static const int16_t layer_band_z[] = {
	[ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND] = Z_LAYER_BACKGROUND,
	[ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM] = Z_LAYER_BOTTOM,
	[ZWLR_LAYER_SHELL_V1_LAYER_TOP] = Z_LAYER_TOP,
	[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY] = Z_LAYER_OVERLAY,
};

static bool
declarable_layer(LayerSurface *l, Monitor *m)
{
	return l->mon == m && l->scene && l->layer_surface->initialized;
}

static void
declare_layer_slot(LayerSurface *l, Monitor *m, enum wlr_edges edge, int16_t z)
{
	struct wlr_layer_surface_v1 *ls = l->layer_surface;
	struct wlr_layer_surface_v1_state *st = &ls->current;
	uint64_t handle = declare_handle_for(l, DECLARE_KIND_LAYER);
	bool left = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
	bool right = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
	bool top = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
	bool bottom = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
	bool told = st->desired_width || st->desired_height;
	Clay_ElementDeclaration slot = {
		.layout = {
			.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
			.padding = { st->margin.left, st->margin.right,
				st->margin.top, st->margin.bottom },
			.childAlignment = {
				left && !right ? CLAY_ALIGN_X_LEFT
					: right && !left ? CLAY_ALIGN_X_RIGHT : CLAY_ALIGN_X_CENTER,
				top && !bottom ? CLAY_ALIGN_Y_TOP
					: bottom && !top ? CLAY_ALIGN_Y_BOTTOM : CLAY_ALIGN_Y_CENTER,
			},
		},
	};
	Clay_ElementDeclaration leaf = {
		.layout.sizing = {
			st->desired_width ? CLAY_SIZING_FIXED(st->desired_width)
				: CLAY_SIZING_GROW(0),
			st->desired_height ? CLAY_SIZING_FIXED(st->desired_height)
				: CLAY_SIZING_GROW(0),
		},
		.custom.customData = (void *)(uintptr_t)handle,
		.userData = leaf_userdata(handle, 1.0f),
	};
	Clay_ElementId slot_id = Clay__HashStringWithOffset(CLAY_STRING("LAYER"),
		(uint32_t)handle, 0);
	Clay_ElementId id = Clay__HashStringWithOffset(
		CLAY_STRING("layer.surface"), (uint32_t)handle, 0);

	switch (edge) {
	case WLR_EDGE_TOP:
		slot.layout.sizing.height = CLAY_SIZING_FIXED(
			st->exclusive_zone + st->margin.top);
		slot.layout.padding.bottom = 0;
		break;
	case WLR_EDGE_BOTTOM:
		slot.layout.sizing.height = CLAY_SIZING_FIXED(
			st->exclusive_zone + st->margin.bottom);
		slot.layout.padding.top = 0;
		break;
	case WLR_EDGE_LEFT:
		slot.layout.sizing.width = CLAY_SIZING_FIXED(
			st->exclusive_zone + st->margin.left);
		slot.layout.padding.right = 0;
		break;
	case WLR_EDGE_RIGHT:
		slot.layout.sizing.width = CLAY_SIZING_FIXED(
			st->exclusive_zone + st->margin.right);
		slot.layout.padding.left = 0;
		break;
	default: {
        /* A nonexclusive surface is the floating slot itself, attached to
         * OUTPUT from protocol anchors. Two-sided stretch uses padding to
         * inset its surface; no output/sibling rectangle is computed. */
        unsigned xpoint = left && !right ? 0 : right && !left ? 2 : 1;
        unsigned ypoint = top && !bottom ? 0 : bottom && !top ? 2 : 1;
        slot.layout.sizing = leaf.layout.sizing;
        slot.layout.padding = (Clay_Padding) {0};
        if (!st->desired_width) {
            slot.layout.padding.left = MAX(0, st->margin.left);
            slot.layout.padding.right = MAX(0, st->margin.right);
        }
        if (!st->desired_height) {
            slot.layout.padding.top = MAX(0, st->margin.top);
            slot.layout.padding.bottom = MAX(0, st->margin.bottom);
        }
        slot.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
        slot.floating.parentId = output_id(m).id;
        slot.floating.attachPoints.parent = xpoint * 3 + ypoint;
        slot.floating.attachPoints.element = xpoint * 3 + ypoint;
        slot.floating.offset = (Clay_Vector2) {
            left && !right ? st->margin.left : right && !left ? -st->margin.right
                : left && right && st->desired_width ? (st->margin.left - st->margin.right) / 2.0f : 0,
            top && !bottom ? st->margin.top : bottom && !top ? -st->margin.bottom
                : top && bottom && st->desired_height ? (st->margin.top - st->margin.bottom) / 2.0f : 0,
        };
        slot.floating.zIndex = z;
        slot.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
        leaf.layout.sizing = (Clay_Sizing) {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)};
        break;
    }
	}
	Clay__OpenElementWithId(slot_id);
	Clay__ConfigureOpenElementPtr(&slot);
	record_open(edge != WLR_EDGE_NONE ? "LAYER_BAR" : "LAYER_OVERLAY", handle, slot_id,
		&slot, DECLARE_SRC_PROTOCOL,
		NULL);
    if (edge == WLR_EDGE_NONE && ((!st->desired_width && (st->margin.left < 0 || st->margin.right < 0))
            || (!st->desired_height && (st->margin.top < 0 || st->margin.bottom < 0)))) {
        /* Positive margins are padding. Negative protocol margins expand a
         * surface leaf about that inset; no sibling or output box is read. */
        Clay_ElementId inset_id = Clay__HashStringWithOffset(CLAY_STRING("layer.inset"), (uint32_t)handle, 0);
        Clay_ElementDeclaration inset = {.layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}};
        declare_leaf("layer.inset", handle, DECLARE_SRC_NONE, inset_id, &inset);
        float ml = st->desired_width ? 0 : MIN(0, st->margin.left);
        float mr = st->desired_width ? 0 : MIN(0, st->margin.right);
        float mt = st->desired_height ? 0 : MIN(0, st->margin.top);
        float mb = st->desired_height ? 0 : MIN(0, st->margin.bottom);
        leaf.floating = (Clay_FloatingElementConfig){
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = inset_id.id,
            .offset = {(ml-mr)/2, (mt-mb)/2}, .expand = {-(ml+mr)/2, -(mt+mb)/2},
            .zIndex = z, .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        };
    }
	declare_leaf("layer.surface", handle,
		edge != WLR_EDGE_NONE && told ? DECLARE_SRC_PROTOCOL : DECLARE_SRC_NONE, id, &leaf);
	record_close();
	Clay__CloseElement();
	declare_popups(ls->surface, id, 0, 0);
}

/* The layer surfaces that float, oldest first at the bottom of their band
 * (protocols.c prepends new surfaces to m->layers). */
static void
declare_floating_layers(Monitor *m)
{
	LayerSurface *l;

	for (size_t band = 0; band < LENGTH(m->layers); band++)
		wl_list_for_each_reverse(l, &m->layers[band], link)
			if (declarable_layer(l, m) && wlr_layer_surface_v1_get_exclusive_edge(
					l->layer_surface) == WLR_EDGE_NONE)
				declare_layer_slot(l, m, WLR_EDGE_NONE, layer_band_z[band]);
}

/* --- bars (awful.wibar) ---
 *
 * A bar is a slot at an edge of the output: grow along the edge, fixed
 * across it by the drawin's thickness (the theme's wibar height), holding
 * the drawin's widget tree as a child that fills it. In the output's flow
 * the slot reserves that space; an ontop bar, or one that reserves nothing,
 * floats over the output at the same edge in its band. The drawin's
 * geometry is whatever its tree's root solved to, written back after the
 * solve (bars_settle), so Lua reads the box the frame drew and input finds
 * the bar there. A bar declares no shadow: a flow element has no band to
 * put one under. */
struct bar_record {
	drawin_t *d;
	struct widget_host host;
};

static struct bar_record bars[WIDGET_NODES_MAX];
static size_t bars_len;

static bool
bar_flows(drawin_t *d)
{
	return d->bar.reserve && !d->ontop;
}

static void
declare_bar(drawin_t *d, Monitor *m, int16_t z)
{
	static const Clay_FloatingAttachPointType points[] = {
		[DRAWIN_EDGE_TOP] = CLAY_ATTACH_POINT_CENTER_TOP,
		[DRAWIN_EDGE_BOTTOM] = CLAY_ATTACH_POINT_CENTER_BOTTOM,
		[DRAWIN_EDGE_LEFT] = CLAY_ATTACH_POINT_LEFT_CENTER,
		[DRAWIN_EDGE_RIGHT] = CLAY_ATTACH_POINT_RIGHT_CENTER,
	};
	uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
	bool horizontal = d->bar.edge == DRAWIN_EDGE_TOP
		|| d->bar.edge == DRAWIN_EDGE_BOTTOM;
	const uint16_t *mg = d->bar.margins;
	int thickness = horizontal ? d->height + mg[2] + mg[3]
		: d->width + mg[0] + mg[1];
	float opacity = d->opacity >= 0 ? (float)d->opacity : 1.0f;
	Clay_ElementDeclaration slot = {
		.layout = {
			.sizing = {
				horizontal ? CLAY_SIZING_GROW(0) : CLAY_SIZING_FIXED(thickness),
				horizontal ? CLAY_SIZING_FIXED(thickness) : CLAY_SIZING_GROW(0),
			},
			.padding = { mg[0], mg[1], mg[2], mg[3] },
			.childAlignment = {
				horizontal && d->bar.align
					? (d->bar.align == 1 ? CLAY_ALIGN_X_LEFT : CLAY_ALIGN_X_RIGHT)
					: CLAY_ALIGN_X_CENTER,
				!horizontal && d->bar.align
					? (d->bar.align == 1 ? CLAY_ALIGN_Y_TOP : CLAY_ALIGN_Y_BOTTOM)
					: CLAY_ALIGN_Y_CENTER,
			},
			.layoutDirection = horizontal
				? CLAY_LEFT_TO_RIGHT : CLAY_TOP_TO_BOTTOM,
		},
	};
	Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("WIBAR"),
		(uint32_t)handle, 0);
	struct bar_record *bar;

	if (bars_len == LENGTH(bars))
		return;
	bar = &bars[bars_len++];
	bar->d = d;
	drawin_widget_host(d, &bar->host);
	bar->host.flow = true;
	if (!d->bar.stretch)
		bar->host.told[horizontal ? 0 : 1] = horizontal ? d->width : d->height;
	if (z) {
		slot.floating.attachTo = CLAY_ATTACH_TO_PARENT;
		slot.floating.attachPoints.element = points[d->bar.edge];
		slot.floating.attachPoints.parent = points[d->bar.edge];
		slot.floating.zIndex = z;
		slot.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
	}
	if (d->bar.stretch && !mg[0] && !mg[1] && !mg[2] && !mg[3]) {
		declare_widget_slot(&bar->host, id, &slot, "WIBAR", DECLARE_SRC_THEME,
			z, leaf_userdata(handle, opacity));
		return;
	}
	Clay__OpenElementWithId(id);
	Clay__ConfigureOpenElementPtr(&slot);
	record_open("WIBAR", handle, id, &slot, DECLARE_SRC_THEME, &bar->host);
	declare_widget_tree(&bar->host, z, leaf_userdata(handle, opacity));
	record_close();
	Clay__CloseElement();
}

/* What is in flow at one edge: the layer surfaces with an exclusive zone
 * there, overlay layer down to background and newest first as wlroots
 * arranged them, then the wibars in the order they became visible. A
 * bottom or right edge declares them last first, so the first stays at
 * the edge. */
struct flow_item {
	drawin_t *d;
	LayerSurface *l;
};

static const enum wlr_edges wlr_edge_of[] = {
	[DRAWIN_EDGE_TOP] = WLR_EDGE_TOP,
	[DRAWIN_EDGE_BOTTOM] = WLR_EDGE_BOTTOM,
	[DRAWIN_EDGE_LEFT] = WLR_EDGE_LEFT,
	[DRAWIN_EDGE_RIGHT] = WLR_EDGE_RIGHT,
};

static size_t
edge_items(Monitor *m, enum drawin_edge edge, struct flow_item *items, size_t cap)
{
	size_t n = 0;
	LayerSurface *l;

	for (size_t band = LENGTH(m->layers); band-- > 0;)
		wl_list_for_each(l, &m->layers[band], link)
			if (declarable_layer(l, m) && n < cap
					&& wlr_layer_surface_v1_get_exclusive_edge(l->layer_surface)
						== wlr_edge_of[edge])
				items[n++] = (struct flow_item) { .l = l };
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		if (d->bar.edge == edge && bar_flows(d) && declarable_drawin(d, m)
				&& n < cap)
			items[n++] = (struct flow_item) { .d = d };
	}
	return n;
}

static void
declare_edge(Monitor *m, enum drawin_edge edge)
{
	struct flow_item items[LENGTH(bars)];
	size_t n = edge_items(m, edge, items, LENGTH(items));
	bool reverse = edge == DRAWIN_EDGE_BOTTOM || edge == DRAWIN_EDGE_RIGHT;

	for (size_t i = 0; i < n; i++) {
		struct flow_item *it = &items[reverse ? n - 1 - i : i];

		if (it->d)
			declare_bar(it->d, m, 0);
		else
			declare_layer_slot(it->l, m, wlr_edge_of[edge], 0);
	}
}

static bool
edge_has_bars(Monitor *m, enum drawin_edge edge)
{
	struct flow_item item;

	return edge_items(m, edge, &item, 1) > 0;
}

/* The bars over the output rather than in its flow, at their edges. */
static void
declare_floating_bars(Monitor *m)
{
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		if (d->bar.edge && !bar_flows(d) && declarable_drawin(d, m))
			declare_bar(d, m, d->ontop ? Z_BAR_ONTOP : Z_DRAWIN);
	}
}

/* After the solve: each bar's drawin takes the box its tree's root solved
 * to, in layout coordinates. A changed size marks the drawable, and the
 * frame's second pass compiles the tree at that size. */
static void
bars_settle(Monitor *m)
{
	size_t len = bars_len;

	bars_len = 0;
	for (size_t i = 0; i < len; i++) {
		drawin_t *d = bars[i].d;
		Clay_ElementData root = Clay_GetElementData(
			(Clay_ElementId) {.id = bars[i].host.tree->root_id});
		Clay_BoundingBox b = root.boundingBox;
		int x, y, w, h;

		if (!root.found)
			continue;
		x = m->m.x + (int)floorf(b.x + 0.5f);
		y = m->m.y + (int)floorf(b.y + 0.5f);
		w = (int)floorf(b.width + 0.5f);
		h = (int)floorf(b.height + 0.5f);
		if (x != d->x || y != d->y || w != d->width || h != d->height)
			luaA_drawin_set_geometry(globalconf_L, d, x, y, w, h);
	}
}

/* Content-sized drawins without an attachment also take their solved size.
 * This replaces popup's fit callback writing width/height in Lua. */
static void
popups_settle(Monitor *m)
{
    foreach(item, globalconf.drawins) {
        drawin_t *d = *item;
        if (d->bar.edge || d->attachment.kind || !declarable_drawin(d, m)
                || d->widgets.nodes[0].sizing[0] != WIDGET_SIZING_FIT
                || d->widgets.nodes[0].sizing[1] != WIDGET_SIZING_FIT) continue;
        uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
        Clay_ElementData root = Clay_GetElementData(widget_root_id((uint32_t)handle));
        if (!root.found) continue;
        Clay_BoundingBox b = root.boundingBox;
        int w = (int)floorf(b.width + 0.5f), h = (int)floorf(b.height + 0.5f);
        if (w != d->width || h != d->height)
            luaA_drawin_set_geometry(globalconf_L, d, d->x, d->y, w, h);
    }
}

/* The drawin band policy: desktop and splash below clients like the
 * wallpaper, an ontop drawin with the popups (a notification above them),
 * everything else placed by its geometry just above normal clients. */
static int16_t
drawin_z(drawin_t *d)
{
	if (d->type == WINDOW_TYPE_DESKTOP || d->type == WINDOW_TYPE_SPLASH)
		return Z_DRAWIN_BG;
	if (d->ontop)
		return d->type == WINDOW_TYPE_NOTIFICATION
			? Z_NOTIFICATION : Z_DRAWIN_ONTOP;
	return Z_DRAWIN;
}

/* Decorations are pixels inside an image, not a second placement engine.
 * A container reserves the theme extent as padding. Both kinds retain the existing
 * widget subtree and use its solved size for the next raster. */
static Clay_Dimensions
attachment_decoration(drawin_t *d, Clay_ElementDeclaration *slot)
{
    const shadow_config_t *s = shadow_get_effective_config(d->shadow_config, true);
    int ex = d->border_width, ey = ex;
    if (drawin_native_attachment_border(d)) {
        const color_t *color = &d->border_color_parsed;
        slot->border = (Clay_BorderElementConfig) {
            .color = {color->red, color->green, color->blue, color->alpha},
            .width = {ex, ex, ex, ex, 0},
        };
        image_entry_set(&d->attachment_decoration, NULL);
        return (Clay_Dimensions){ex, ey};
    }
    if (s->enabled) {
        int outset = MAX(0, s->spread + s->radius);
        ex = MAX(ex, outset + abs(s->offset_x));
        ey = MAX(ey, outset + abs(s->offset_y));
    }
    if (!ex && !ey) {
        image_entry_set(&d->attachment_decoration, NULL);
        return (Clay_Dimensions){0};
    }
    int w = MAX(1, d->width), h = MAX(1, d->height);
    if (d->attachment_decoration.native && d->decoration_width == w
            && d->decoration_height == h && d->decoration_border_gen == d->border_entry.gen
            && !memcmp(&d->decoration_shadow, s, sizeof(*s))) {
        slot->image.imageData = &d->attachment_decoration;
        return (Clay_Dimensions){ex, ey};
    }
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w+2*ex, h+2*ey);
    cairo_t *cr = cairo_create(surface);
    cairo_translate(cr, ex, ey);
    struct wlr_box boxes[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT];
    shadow_leaves_update(&d->shadow, s);
    if (d->shadow.ready && shadow_layout(s, w, h, boxes)) {
        for (size_t i = 0; i < LENGTH(boxes); i++) {
            struct wlr_box b = boxes[i];
            if (b.width <= 0 || b.height <= 0) continue;
            cairo_save(cr);
            cairo_rectangle(cr, b.x, b.y, b.width, b.height);
            cairo_clip(cr);
            if (i < SHADOW_SLICE_COUNT) {
                struct image_entry *tex = &d->shadow.tex[i];
                if (!tex->native) { cairo_restore(cr); continue; }
                cairo_translate(cr, b.x, b.y);
                cairo_scale(cr, (double)b.width/tex->width, (double)b.height/tex->height);
                cairo_set_source_surface(cr, tex->native, 0, 0);
            } else cairo_set_source_rgba(cr, s->color[0], s->color[1], s->color[2], shadow_paint(s));
            cairo_paint(cr);
            cairo_restore(cr);
        }
    }
    if (d->border_entry.native) {
        cairo_set_source_surface(cr, d->border_entry.native, -d->border_width, -d->border_width);
        cairo_paint(cr);
    }
    cairo_destroy(cr);
    image_entry_set(&d->attachment_decoration, surface);
    d->decoration_width = w; d->decoration_height = h;
    d->decoration_border_gen = d->border_entry.gen;
    d->decoration_shadow = *s;
    slot->image.imageData = &d->attachment_decoration;
    return (Clay_Dimensions){ex, ey};
}

static bool
declare_attachment(drawin_t *d, Monitor *m)
{
    if (d->attachment.kind == 2 && !d->attachment.target) return false;
    uint32_t target = d->attachment.target
        ? attachment_target(d) : output_id(m).id;
    if (!target || bars_len == LENGTH(bars)) return false;
    if (d->attachment.hover && !Clay_PointerOver((Clay_ElementId){.id=target})) return false;
    uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
    struct bar_record *a = &bars[bars_len++];
    a->d = d;
    drawin_widget_host(d, &a->host);
    a->host.flow = true;
    a->host.fit[0] = a->host.fit[1] = true;
    const struct widget_node *n = &d->widgets.nodes[0];
    Clay_ElementDeclaration slot = {
        .layout.sizing = { widget_sizing(n, 0), widget_sizing(n, 1) },
        .floating = {
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = target,
            .attachPoints = { .parent = d->attachment.parent, .element = d->attachment.own },
            .offset = { d->attachment.x, d->attachment.y },
            .zIndex = Z_POPUP,
            .pointerCaptureMode = d->attachment.passthrough
                ? CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH : CLAY_POINTER_CAPTURE_MODE_CAPTURE,
        },
    };
    if (d->attachment.kind == 3) {
        slot.layout.sizing.width = CLAY_SIZING_FIXED(d->attachment.width);
        slot.layout.layoutDirection = CLAY_TOP_TO_BOTTOM;
        slot.floating.zIndex = Z_NOTIFICATION;
        a->host.fit[0] = false;
    }
    Clay_Dimensions decoration = attachment_decoration(d, &slot);
    slot.layout.padding = (Clay_Padding){decoration.width, decoration.width,
        decoration.height, decoration.height};
    /* Attach the content's own point; decoration extends around it. */
    slot.floating.offset.x += ((int)d->attachment.own / 3 - 1) * decoration.width;
    slot.floating.offset.y += ((int)d->attachment.own % 3 - 1) * decoration.height;
    if (d->attachment.kind == 3)
        slot.layout.sizing.width = CLAY_SIZING_FIXED(d->attachment.width + 2*decoration.width);
    Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("ATTACHMENT"),
        (uint32_t)handle, 0);
    const char *role = d->attachment.kind == 3 ? "LAUNCHER"
        : d->attachment.kind == 2 ? "TOOLTIP" : "POPUP";
    enum declare_src src = d->attachment.kind == 3 || decoration.width || decoration.height
        ? DECLARE_SRC_THEME : DECLARE_SRC_NONE;
    if (!decoration.width && !decoration.height) {
        declare_widget_slot(&a->host, id, &slot, role, src,
            slot.floating.zIndex, leaf_userdata(handle, d->opacity >= 0 ? (float)d->opacity : 1.0f));
        return true;
    }
    Clay__OpenElementWithId(id);
    Clay__ConfigureOpenElementPtr(&slot);
    record_open(role, handle, id, &slot, src, &a->host);
    declare_widget_tree(&a->host, slot.floating.zIndex, leaf_userdata(handle,
        d->opacity >= 0 ? (float)d->opacity : 1.0f));
    record_close();
    Clay__CloseElement();
    return true;
}

/* A nonempty notification position is one root float with flow children. */
static void
declare_notifications(Monitor *m)
{
    for (int position = 0; position < 9; position++) {
        drawin_t *first = NULL;
        foreach(item, globalconf.drawins) {
            drawin_t *d = *item;
            if (d->attachment.kind == 4 && d->attachment.position == position
                    && declarable_drawin(d, m)) { first = d; break; }
        }
        if (!first) continue;
        Clay_ElementDeclaration stack = {
            .layout = {
                .sizing = { CLAY_SIZING_FIXED(first->attachment.width), CLAY_SIZING_FIT(0) },
                .layoutDirection = CLAY_TOP_TO_BOTTOM, .childGap = first->attachment.gap,
            },
            .floating = {
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = output_id(m).id,
                .attachPoints = { .parent = position, .element = position },
                .offset = {first->attachment.x, first->attachment.y},
                .zIndex = Z_NOTIFICATION,
                .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
            },
        };
        Clay_ElementId stack_id = Clay__HashStringWithOffset(CLAY_STRING("NOTIFICATIONS"), position, 0);
        Clay__OpenElementWithId(stack_id);
        Clay__ConfigureOpenElementPtr(&stack);
        record_open("NOTIFICATIONS", 0, stack_id, &stack, DECLARE_SRC_THEME, NULL);
        foreach(item, globalconf.drawins) {
            drawin_t *d = *item;
            if (d->attachment.kind != 4 || d->attachment.position != position
                    || !declarable_drawin(d, m) || bars_len == LENGTH(bars)) continue;
            struct bar_record *a = &bars[bars_len++];
            a->d = d;
            drawin_widget_host(d, &a->host);
            a->host.flow = true; a->host.fit[1] = true;
            uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
            Clay_ElementDeclaration child = {
                .layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0) },
            };
            Clay_Dimensions decoration = attachment_decoration(d, &child);
            child.layout.padding = (Clay_Padding){decoration.width, decoration.width,
                decoration.height, decoration.height};
            Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("ATTACHMENT"), (uint32_t)handle, 0);
            if (!decoration.width && !decoration.height) {
                declare_widget_slot(&a->host, id, &child, "NOTIFICATION", DECLARE_SRC_NONE,
                    Z_NOTIFICATION, leaf_userdata(handle, d->opacity >= 0 ? (float)d->opacity : 1.0f));
                continue;
            }
            Clay__OpenElementWithId(id);
            Clay__ConfigureOpenElementPtr(&child);
            record_open("NOTIFICATION", handle, id, &child, DECLARE_SRC_NONE, &a->host);
            declare_widget_tree(&a->host, Z_NOTIFICATION, leaf_userdata(handle,
                d->opacity >= 0 ? (float)d->opacity : 1.0f));
            record_close();
            Clay__CloseElement();
        }
        record_close();
        Clay__CloseElement();
    }
}

static void
declare_drawins(Monitor *m)
{
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		/* Lock drawins belong to the lock pass while locked; bars are
		 * the output's own. */
		if (session_is_locked() && some_is_lock_drawin(d))
			continue;
		if (d->bar.edge || d->attachment.kind || !declarable_drawin(d, m))
			continue;
		if (drawin_covers_output(d, m))
			declare_wallpaper_drawin(d, m, drawin_z(d));
		else
			declare_drawin(d, m, drawin_z(d));
	}
    declare_notifications(m);
    /* Targets in other popups must be declared first, independent of the
     * drawins list's order. Missing/hidden targets leave the popup absent. */
    bool progress;
    do {
        progress = false;
        foreach(item, globalconf.drawins) {
            drawin_t *d = *item;
            if (!d->attachment.kind || d->attachment.kind == 4 || !declarable_drawin(d, m)) continue;
            bool done = false;
            for (size_t i = 0; i < bars_len; i++) if (bars[i].d == d) done = true;
            if (!done && declare_attachment(d, m)) progress = true;
        }
    } while (progress);
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

	Clay_ElementDeclaration bg = leaf_at(Z_FULLSCREEN_BG, 0, 0, m->m.width, m->m.height);
	bg.backgroundColor = clay_color(globalconf.appearance.fullscreen_bg);
	declare_leaf("fullscreen_bg", 0, DECLARE_SRC_OUTPUT,
		Clay__HashStringWithOffset(CLAY_STRING("fullscreen_bg"), 0, 0), &bg);
}

/* This output's crop of the wallpaper surface root.c paints over the whole
 * layout, cut again when the surface changes or the output moves in the
 * layout; the entry's pointer stays, so the node is retained and
 * re-rastered. Empty when there is no wallpaper. */
static void
wallpaper_crop(Monitor *m)
{
	struct declare_output *dout = m->declare;
	struct image_entry *e = &dout->wallpaper;
	cairo_surface_t *wall = globalconf.wallpaper;

	if (!wall || m->m.width <= 0 || m->m.height <= 0) {
		image_entry_set(e, NULL);
		return;
	}
	if (dout->wallpaper_gen == globalconf.wallpaper_gen
			&& e->width == m->m.width && e->height == m->m.height
			&& dout->wallpaper_x == m->m.x && dout->wallpaper_y == m->m.y)
		return;
	cairo_surface_t *crop = cairo_image_surface_create(
		CAIRO_FORMAT_ARGB32, m->m.width, m->m.height);
	cairo_t *cr;

	if (cairo_surface_status(crop) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(crop);
		image_entry_set(e, NULL);
		return;
	}
	cr = cairo_create(crop);
	cairo_set_source_surface(cr, wall, -m->m.x, -m->m.y);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	cairo_paint(cr);
	cairo_destroy(cr);
	cairo_surface_flush(crop);
	image_entry_set(e, crop);
	dout->wallpaper_gen = globalconf.wallpaper_gen;
	dout->wallpaper_x = m->m.x;
	dout->wallpaper_y = m->m.y;
}

/* The output element: the one flow root of the tree, sized to the output,
 * painting the wallpaper as its image or the root colour as its background
 * (Clay emits an IMAGE for an element with imageData and a RECTANGLE for a
 * background with alpha, clay.h:3025-3083, so the two are exclusive). Its
 * word names the Monitor under DECLARE_KIND_WALLPAPER, so the input filter
 * (window.c) refuses it pointer input, the way it refused the wallpaper
 * leaf, and the screenshot path can skip it. It is a column: the top bars,
 * then a row of the left bars and right bars around the middle when there
 * are any, then the bottom bars. The bars that float sit over it at their
 * edges. */
/* The workarea: what the bars leave of the output, where the clients go.
 * screen.workarea is the box this element solves to (workarea_settle). */
static Clay_ElementId
workarea_id(Monitor *m)
{
	return Clay__HashStringWithOffset(CLAY_STRING("WORKAREA"),
		(uint32_t)declare_handle_for(m, DECLARE_KIND_WALLPAPER), 0);
}

/* After the solve: the screen's workarea is the WORKAREA box, in layout
 * coordinates. screen_set_workarea queues property::workarea when it
 * changed, and awful.layout arranges on it. */
static void
workarea_settle(Monitor *m)
{
	Clay_ElementData data = Clay_GetElementData(workarea_id(m));
	Clay_BoundingBox b = data.boundingBox;
	screen_t *s = luaA_screen_get_by_monitor(globalconf_L, m);
	struct wlr_box box;

	if (!data.found || !s)
		return;
	box.x = m->m.x + (int)floorf(b.x + 0.5f);
	box.y = m->m.y + (int)floorf(b.y + 0.5f);
	box.width = (int)floorf(b.x + b.width + 0.5f) - (int)floorf(b.x + 0.5f);
	box.height = (int)floorf(b.y + b.height + 0.5f) - (int)floorf(b.y + 0.5f);
	screen_set_workarea(globalconf_L, s, &box);
}

static Clay_ElementId
output_id(Monitor *m)
{
	return Clay__HashStringWithOffset(CLAY_STRING("OUTPUT"),
		(uint32_t)declare_handle_for(m, DECLARE_KIND_WALLPAPER), 0);
}

/* The output's own fill, the root wallpaper or the root colour: a float the
 * size of the output at the lowest band, so what draws under the bars (a
 * wallpaper wibox, a desktop client, the background and bottom layers)
 * draws over it. Were it OUTPUT's own background, Clay would draw it after
 * every negative band and before the bars, hiding the one under the other.
 * Its word is the output's, so the input filter and the screenshot path
 * treat it as they treated the wallpaper leaf. */
static void
declare_background(Monitor *m, uint64_t handle)
{
	Clay_ElementDeclaration bg = {
		.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		.floating = {
			.attachTo = CLAY_ATTACH_TO_PARENT,
			.zIndex = Z_OUTPUT_BG,
			.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
		},
		.userData = leaf_userdata(handle, 1.0f),
	};

	wallpaper_crop(m);
	if (m->declare->wallpaper.native)
		bg.image.imageData = &m->declare->wallpaper;
	else
		bg.backgroundColor = clay_color(globalconf.appearance.rootcolor);
	declare_leaf("BACKGROUND", handle, DECLARE_SRC_OUTPUT,
		Clay__HashStringWithOffset(CLAY_STRING("BACKGROUND"), (uint32_t)handle, 0),
		&bg);
}

static void
declare_output(Monitor *m)
{
	uint64_t handle = declare_handle_for(m, DECLARE_KIND_WALLPAPER);
	Clay_ElementId id = output_id(m);
	Clay_ElementDeclaration o = {
		.layout = {
			.sizing = { CLAY_SIZING_FIXED(m->m.width),
				CLAY_SIZING_FIXED(m->m.height) },
			.layoutDirection = CLAY_TOP_TO_BOTTOM,
		},
		.userData = leaf_userdata(handle, 1.0f),
	};

	/* The inspector's panel takes the right edge while it is up (Clay
	 * narrows its own root by the same width, clay.h:4363): the desktop
	 * reflows into what is left, as beside a right bar. */
	if (m->declare->inspecting)
		o.layout.padding.right = (uint16_t)Clay__debugViewWidth;
	Clay__OpenElementWithId(id);
	Clay__ConfigureOpenElementPtr(&o);
	record_open("OUTPUT", handle, id, &o, DECLARE_SRC_OUTPUT, NULL);
	declare_background(m, handle);
	declare_edge(m, DRAWIN_EDGE_TOP);
	if (edge_has_bars(m, DRAWIN_EDGE_LEFT) || edge_has_bars(m, DRAWIN_EDGE_RIGHT)) {
		Clay_ElementDeclaration middle = {
			.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		};
		Clay_ElementId middle_id = Clay__HashStringWithOffset(
			CLAY_STRING("MIDDLE"), (uint32_t)handle, 0);

		Clay__OpenElementWithId(middle_id);
		Clay__ConfigureOpenElementPtr(&middle);
		record_open("MIDDLE", 0, middle_id, &middle, DECLARE_SRC_NONE, NULL);
		declare_edge(m, DRAWIN_EDGE_LEFT);
		declare_workarea(m);
		declare_edge(m, DRAWIN_EDGE_RIGHT);
		record_close();
		Clay__CloseElement();
	} else {
		declare_workarea(m);
	}
	declare_edge(m, DRAWIN_EDGE_BOTTOM);
	declare_floating_bars(m);
	record_close();
	Clay__CloseElement();
}

/* The seat's drag icon, on the output under the pointer, at the pointer:
 * a borrowed surface leaf whose position is the cursor, an input. */
static void
declare_drag_icon(Monitor *m)
{
	struct wlr_drag_icon *icon = seat->drag ? seat->drag->icon : NULL;
	uint64_t handle;
	Clay_ElementDeclaration s;

	if (!icon || !icon->data || !icon->surface->mapped
			|| xytomon(cursor->x, cursor->y) != m)
		return;
	handle = declare_handle_for(icon, DECLARE_KIND_DRAG);
	s = leaf_at(Z_DRAG_ICON, (int)round(cursor->x) - m->m.x,
		(int)round(cursor->y) - m->m.y,
		icon->surface->current.width, icon->surface->current.height);
	s.custom.customData = (void *)(uintptr_t)handle;
	s.userData = leaf_userdata(handle, 1.0f);
	declare_leaf("drag.icon", handle, DECLARE_SRC_USER,
		Clay__HashStringWithOffset(CLAY_STRING("drag.icon"),
		(uint32_t)handle, 0), &s);
}

static void
declare_scene(Monitor *m)
{
	attachment_targets_len = 0;
	bars_len = 0;
	tile_prepare(m);
	declare_output(m);
	declare_floating_layers(m);
	declare_clients(m);
	declare_drawins(m);
	declare_fullscreen_bg(m);
	declare_unmanaged_clients(m);
	declare_drag_icon(m);
	luaL_unref(globalconf_L, LUA_REGISTRYINDEX, tile_ref);
	tile_ref = LUA_NOREF;
}

/* The boxes of one subtree, in the preorder the tree table uses, rounded
 * against the root's own box so a box crossing into Lua is the whole
 * drawin-local pixel. Edges round, not the size, so two boxes that share an
 * edge in the solved layout share it here. */
static size_t
widget_boxes_walk(struct widget_tree *d, size_t i, Clay_ElementId id, int (*boxes)[4],
	int *n, Clay_BoundingBox root)
{
	const struct widget_node *node = &d->nodes[i];
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
		next = widget_boxes_walk(d, next, widget_child_id(d, next, id, k),
			boxes, n, root);
	return next;
}

/* Whether Clay's last pointer query named id. */
static bool
pointer_over(Clay_ElementIdArray ids, Clay_ElementId id)
{
	for (int32_t k = 0; k < ids.length; k++)
		if (ids.internalArray[k].id == id.id)
			return true;
	return false;
}

/* The preorder indices of the widget nodes Clay's pointer query named, in
 * preorder: parents before children, a stack's children bottom to top,
 * which is the order find_widgets has always answered in. */
static size_t
widget_hits_walk(struct widget_tree *d, size_t i, Clay_ElementId id,
	Clay_ElementIdArray ids, int *out, int *n, int cap)
{
	const struct widget_node *node = &d->nodes[i];
	size_t next = i + 1;

	if (node->widget && *n < cap && pointer_over(ids, id))
		out[(*n)++] = (int)i;
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_hits_walk(d, next, widget_child_id(d, next, id, k),
			ids, out, n, cap);
	return next;
}

/* The band whose last solve placed host's tree: the lock band for a lock
 * drawin while the session is locked, else the desktop. NULL before the band
 * exists. */
static struct declare_band *
host_band(const struct widget_host *host)
{
	struct declare_output *dout = host->m->declare;
	struct declare_band *band = session_is_locked()
		&& some_is_lock_drawin(declare_handle_get(
			handle_pack(DECLARE_KIND_DRAWIN, host->id), NULL))
		? &dout->lock : &dout->desktop;

	return band->clay ? band : NULL;
}

int
declare_widget_hits(const struct widget_host *host, double x, double y, int *out, int cap)
{
	struct widget_tree *d = host->tree;
	Monitor *m = host->m;
	struct declare_output *dout = m ? m->declare : NULL;
	struct declare_band *band;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementIdArray ids;
	int n = 0;

	if (!dout || !d->declared || !(band = host_band(host)))
		return 0;
	/* The query runs against the boxes of the output's last solve, in
	 * output coordinates, and answers every element under the point
	 * across the whole context: this tree's nodes are picked out of it. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	Clay_SetPointerState((Clay_Vector2) {
		(float)(host->x + x), (float)(host->y + y) }, false);
	ids = Clay_GetPointerOverIds();
	root_id = (Clay_ElementId) {.id = d->root_id};
#ifdef SOMEWM_RENDER_VERIFY
	/* The scene named this drawable at the point (input.c), so the query
	 * (third_party/clay.h:3900-3967) must reach its root: the two disagreeing
	 * is the divergence the tree==scene verifier exists to catch. */
	if (!pointer_over(ids, root_id)) {
		wlr_log(WLR_ERROR, "scene==clay: the scene hit drawable %dx%d+%d+%d "
			"at %g,%g but Clay's query does not reach its root",
			host->w, host->h, host->x + m->m.x, host->y + m->m.y, x, y);
		abort();
	}
#endif
	widget_hits_walk(d, 0, root_id, ids, out, &n, cap);
	Clay_SetCurrentContext(previous);
	return n;
}

/* The boxes of host's tree in the current context: one lookup per node
 * against what that context last solved. */
static int
widget_boxes_read(const struct widget_host *host, int (*boxes)[4])
{
	Clay_ElementId root_id = {.id = host->tree->root_id};
	Clay_ElementData root = Clay_GetElementData(root_id);
	int n = 0;

	if (root.found)
		widget_boxes_walk(host->tree, 0, root_id, boxes, &n,
			root.boundingBox);
	return n;
}

int
declare_widget_boxes(const struct widget_host *host, int (*boxes)[4])
{
	struct declare_band *band;
	Clay_Context *previous;
	int n;

	/* Clay's hashmap answers with the last box an id ever had, so a tree
	 * the declare pass has not reached yet would read back the boxes of
	 * the one it replaced. Report nothing until it has. */
	if (!host->m || !host->m->declare || !host->tree->declared
			|| !(band = host_band(host)))
		return 0;
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	n = widget_boxes_read(host, boxes);
	Clay_SetCurrentContext(previous);
	return n;
}

/* After a solve: each tree this pass put in front of Clay for the first
 * time since it changed hands its drawable the boxes, as clay::solved. The
 * handlers place the tree's nodes and may change what the frame shows (a
 * popup taking its content's size, a grid telling its rows), which marks
 * the output dirty again for a second pass. */
static void
solved_emit(void)
{
	static int boxes[WIDGET_NODES_MAX][4];
	static const char *keys[] = { "x", "y", "width", "height" };
	lua_State *L = globalconf_L;
	size_t len = solved_len;

	solved_len = 0;
	if (!L)
		return;
	for (size_t i = 0; i < len; i++) {
		int n = widget_boxes_read(&solved_hosts[i], boxes);
		int top = lua_gettop(L);

		drawable_push(L, solved_hosts[i].drawable);
		lua_createtable(L, n, 0);
		for (int k = 0; k < n; k++) {
			lua_createtable(L, 0, 4);
			for (int j = 0; j < 4; j++) {
				lua_pushinteger(L, boxes[k][j]);
				lua_setfield(L, -2, keys[j]);
			}
			lua_rawseti(L, -2, k + 1);
		}
		luaA_object_emit_signal(L, -2, "clay::solved", 1);
		lua_settop(L, top);
	}
}


int
declare_output_order(struct declare_output *dout, void **objects,
	int cap)
{
	int n = 0;

	if (!dout->desktop.clay)
		return 0;
	Clay_Context *previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(dout->desktop.clay);
	Clay_RenderCommandArray commands = clay_render_commands();

	for (int32_t i = 0; i < commands.length && n < cap; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		enum declare_kind kind = 0;
		void *object = declare_handle_get(
			declare_userdata_handle(cmd->userData), &kind);

		/* A leaf with no handle (the fullscreen backing) is not an
		 * object, and only clients, drawins, titlebars and layer surfaces
		 * are Lua objects. A client declares a border leaf and a surface
		 * leaf, a drawin up to three image leaves; the object enters the
		 * order once, at its lowest leaf. */
		if (!object || (kind != DECLARE_KIND_CLIENT
				&& kind != DECLARE_KIND_DRAWIN
				&& kind != DECLARE_KIND_TITLEBAR
				&& kind != DECLARE_KIND_LAYER)
				|| (n > 0 && objects[n - 1] == object))
			continue;
		objects[n++] = object;
	}
	Clay_SetCurrentContext(previous);
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
	fprintf(stderr, "clay error %d: %.*s\n", error.errorType,
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
	Clay_SetMeasureTextFunction(render_measure_text, NULL);
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
	p_delete(&band->records);
	band->records_len = band->records_cap = 0;
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
	dout->deadline = wl_event_loop_add_timer(
		wl_display_get_event_loop(some_get_display()), deadline_fire, dout);
	/* Every desktop band lives in LyrDesktop, below LyrBlock. */
	declare_band_init(&dout->desktop, wlr_output, layers[LyrDesktop]);
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
	/* The backdrop: the band's flow root, opaque over the whole output,
	 * so desktop content is never visible while locked, even on an output
	 * with no cover drawin (a hotplugged monitor). */
	Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("LOCK"), 0, 0);
	Clay_ElementDeclaration backdrop = {
		.layout = {
			.sizing = { CLAY_SIZING_FIXED(m->m.width),
				CLAY_SIZING_FIXED(m->m.height) },
			.layoutDirection = CLAY_TOP_TO_BOTTOM,
		},
		.backgroundColor = { 0.1f * 255, 0.1f * 255, 0.1f * 255, 255 },
	};

	Clay__OpenElementWithId(id);
	Clay__ConfigureOpenElementPtr(&backdrop);
	record_open("LOCK", 0, id, &backdrop, DECLARE_SRC_OUTPUT, NULL);
	record_close();
	Clay__CloseElement();

	for (int i = 0; i < cover_count; i++)
		if (covers[i] && declarable_drawin(covers[i], m))
			declare_drawin(covers[i], m, Z_LOCK_COVER);
	if (lock_surface && declarable_drawin(lock_surface, m))
		declare_drawin(lock_surface, m, Z_LOCK_SURFACE);
	/* An ext-session-lock client's surface for this output: a borrowed
	 * surface leaf filling the output, which the protocol configured to
	 * that size. */
	if (m->lock_surface) {
		uint64_t handle = declare_handle_for(m->lock_surface, DECLARE_KIND_LOCK);
		Clay_ElementDeclaration s = leaf_at(Z_LOCK_SURFACE, 0, 0,
			m->m.width, m->m.height);

		s.custom.customData = (void *)(uintptr_t)handle;
		s.userData = leaf_userdata(handle, 1.0f);
		declare_leaf("lock.surface", handle, DECLARE_SRC_OUTPUT,
			Clay__HashStringWithOffset(CLAY_STRING("lock.surface"),
			(uint32_t)handle, 0), &s);
	}
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
	wl_event_source_remove(dout->deadline);
	if (insp.over == dout)
		insp.over = NULL;
	if (dout->inspecting) {
		dout->inspecting = false;
		inspector_resync();
	}
	declare_band_wipe(&dout->desktop);
	declare_band_wipe(&dout->lock);
	image_entry_set(&dout->wallpaper, NULL);
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
declare_hot_reload(void)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		struct declare_output *dout = m->declare;
		if (!dout)
			continue;
		struct declare_band *bands[] = { &dout->desktop, &dout->lock };
		for (size_t i = 0; i < LENGTH(bands); i++) {
			struct declare_band *band = bands[i];
			if (!band->render)
				continue;
			render_destroy(band->render, &client_hooks);
			band->render = render_create(band->tree);
			declare_band_update(band, dout->wlr_output, m->m.x, m->m.y);
			if (band == &dout->lock)
				render_set_enabled(band->render, some_is_lua_locked());
		}
		declare_output_mark_dirty(dout);
	}
}

void
declare_output_mark_dirty(struct declare_output *dout)
{
	dout->dirty = true;
	wlr_output_schedule_frame(dout->wlr_output);
	if (!dout->deadline_armed) {
		dout->deadline_armed = true;
		wl_event_source_timer_update(dout->deadline, DECLARE_DEADLINE_MS);
	}
}

/* The deadline fired: the frame ran and cleared the mark, or the backend
 * sent no frame event and this is where the output declares. */
static int
deadline_fire(void *data)
{
	struct declare_output *dout = data;
	Monitor *m = dout->wlr_output->data;

	dout->deadline_armed = false;
	if (m && dout->wlr_output->enabled
			&& declare_output_frame(dout, m, some_is_lua_locked()) > 0)
		motionnotify(0, NULL, 0, 0, 0, 0);
	return 0;
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
	static bool in_pass;
	struct declare_band *band;
	Clay_RenderCommandArray commands;
	Clay_Vector2 insp_point = { -1, -1 };
	bool inspecting, insp_edge = false, insp_closed = false;
	int64_t start, declared, solved;

	/* A clay::solved handler that runs a frame of its own (awesome
	 * ._test_redeclare) finds this one mid-pass. */
	if (!dout->dirty || in_pass)
		return -1;
	in_pass = true;

	/* While lua-locked, this output solves its lock scene instead; the
	 * desktop band keeps its last scene, occluded by locked_bg. The lock
	 * band normally exists already (declare_lock_set_visible creates it
	 * on engage); this covers outputs created mid-lock. */
	if (lock_active && !dout->lock.clay) {
		declare_band_init(&dout->lock, dout->wlr_output, layers[LyrBlock]);
		declare_band_update(&dout->lock, dout->wlr_output, m->m.x, m->m.y);
	}
	band = lock_active ? &dout->lock : &dout->desktop;
	band->declare_us = band->solve_us = 0;
	/* The panel is the desktop context's; the lock band never shows it. */
	inspecting = dout->inspecting && !lock_active;

	/* Two passes at most: Lua compiles what changed, C declares every tree
	 * from its store and solves, and the trees solved for the first time
	 * hand their boxes back. A handler that changes the frame (a popup
	 * taking its content's size, a grid telling its rows) marks the output
	 * dirty again and the second pass declares that; what a second pass
	 * dirties waits for the next frame. */
	for (int pass = 0; pass < 2; pass++) {
		luaA_emit_signal_global("clay::declare");
		/* What the compile stored, this pass declares: its marks are
		 * consumed here, not carried into a second pass. */
		dout->dirty = false;
		start = now_us();
		in_frame = true;
		Clay_SetCurrentContext(band->clay);
		render_text_set_measure_scale(dout->wlr_output->scale);
		clay_scroll_records_clear();
		if (inspecting)
			insp_edge = inspector_feed(dout, m, &insp_point);
		declare_begin_layout();
		record_begin(band);
		if (lock_active)
			declare_lock_scene(m);
		else
			declare_scene(m);
		record_end();
		declared = now_us();
		commands = Clay_EndLayout(0);
		solved = now_us();
		in_frame = false;
		if (inspecting) {
			/* Retire the edge now that the pass that wanted it is over
			 * (inspector_feed says why). This is also the call that
			 * closes the panel: its x button has no id, so the check
			 * at clay.h:3381-3389 never matches, and what closes it is
			 * the hover handler at clay.h:3370, which fires inside
			 * Clay_SetPointerState while the state is still the
			 * PRESSED_THIS_FRAME the feed pinned. */
			if (insp_edge)
				Clay_SetPointerState(insp_point, insp.down);
			if (!Clay_IsDebugModeEnabled()) {
				/* Closed after this pass emitted the panel: one more
				 * pass takes it out of the scene. */
				dout->inspecting = false;
				inspecting = false;
				insp_closed = true;
				inspector_resync();
				declare_output_mark_dirty(dout);
			}
		}
		band->declare_us += declared - start;
		band->solve_us += solved - declared;
		if (!lock_active) {
			bars_settle(m);
            popups_settle(m);
			workarea_settle(m);
			clients_settle(m);
		}
		solved_emit();
		if (!dout->dirty)
			break;
	}

	/* The reconcile rasterises shape leaves through their Lua callbacks,
	 * which must not change the tree it is drawing. */
	start = now_us();
	in_frame = true;
	band->commands = commands.length;
	band->mutations = render_reconcile(band->render, commands,
		&client_hooks, (Clay_BoundingBox) { 0, 0, m->m.width, m->m.height });
	in_frame = false;
	band->reconcile_us = now_us() - start;
	in_pass = false;
	if (insp_closed)
		inspector_emit_closed(m);
	return band->mutations;
}

/* --- the Clay debug inspector (declare.h) --- */

/* The palette is plain globals with external linkage that the vendored
 * header never declares in its header section (clay.h:3100-3104); the
 * width and highlight color it does (clay.h:926-927). */
extern Clay_Color CLAY__DEBUGVIEW_COLOR_1;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_2;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_3;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_4;
extern Clay_Color CLAY__DEBUGVIEW_COLOR_SELECTED_ROW;

/* Recount the gate from the per-output copies, which are refreshed at
 * every point the flag can change: the setter, the frame's EndLayout, and
 * an output's destruction. */
static void
inspector_resync(void)
{
	Monitor *m;

	insp.count = 0;
	wl_list_for_each(m, &mons, link)
		if (m->declare && m->declare->inspecting)
			insp.count++;
}

bool
declare_inspector_get(struct declare_output *dout)
{
	Clay_Context *previous = Clay_GetCurrentContext();
	bool on;

	Clay_SetCurrentContext(dout->desktop.clay);
	on = Clay_IsDebugModeEnabled();
	Clay_SetCurrentContext(previous);
	return on;
}

void
declare_inspector_set(struct declare_output *dout, bool on)
{
	Clay_Context *previous = Clay_GetCurrentContext();

	Clay_SetCurrentContext(dout->desktop.clay);
	Clay_SetDebugModeEnabled(on);
	Clay_SetCurrentContext(previous);
	dout->inspecting = on;
	dout->press_pending = false;
	dout->scroll_x = dout->scroll_y = 0;
	inspector_resync();
	declare_output_mark_dirty(dout);
}

int
declare_inspector_style(const struct declare_inspector_style *style,
	const char *font)
{
	Clay_Color *slots[] = {
		&CLAY__DEBUGVIEW_COLOR_1, &CLAY__DEBUGVIEW_COLOR_2,
		&CLAY__DEBUGVIEW_COLOR_3, &CLAY__DEBUGVIEW_COLOR_4,
		&CLAY__DEBUGVIEW_COLOR_SELECTED_ROW, &Clay__debugViewHighlightColor,
	};
	Clay_Context *previous = Clay_GetCurrentContext();
	Monitor *m;
	int err = 0;

	for (size_t i = 0; i < countof(slots); i++)
		*slots[i] = (Clay_Color) { style->colors[i][0], style->colors[i][1],
			style->colors[i][2], style->colors[i][3] };
	Clay__debugViewWidth = style->width > 0 ? (uint32_t)style->width : 0;
	if (font)
		err = render_font_set_default(font);
	wl_list_for_each(m, &mons, link) {
		if (!m->declare)
			continue;
		/* Clay's measure cache keys on the font id, so a new face behind
		 * id 0 would keep answering with the old one's widths
		 * (clay.h:919 exists for this). */
		if (font && !err) {
			Clay_SetCurrentContext(m->declare->desktop.clay);
			Clay_ResetMeasureTextCache();
		}
		if (m->declare->inspecting)
			declare_output_mark_dirty(m->declare);
	}
	Clay_SetCurrentContext(previous);
	return err;
}

void
declare_inspector_pointer(int down, bool press_edge)
{
	struct declare_output *at;
	Monitor *m;

	if (down >= 0)
		insp.down = down;
	if (insp.count == 0)
		return;
	/* A frame with mutations replays a motion at the same point
	 * (rendermon, deadline_fire); a solve for it would mutate nothing and
	 * replay it again. Only a moved cursor or a button is news. */
	if (down < 0 && !press_edge && cursor->x == insp.x && cursor->y == insp.y)
		return;
	insp.x = cursor->x;
	insp.y = cursor->y;
	m = xytomon(cursor->x, cursor->y);
	at = m ? m->declare : NULL;
	if (at != insp.over) {
		/* The panel left behind keeps its hovered row until it solves. */
		if (insp.over && insp.over->inspecting)
			declare_output_mark_dirty(insp.over);
		insp.over = at;
	}
	if (!at || !at->inspecting)
		return;
	if (press_edge)
		at->press_pending = true;
	/* The hovered row, the highlight and the selection only move in a
	 * solve. */
	declare_output_mark_dirty(at);
}

void
declare_inspector_scroll(double dx, double dy)
{
	Monitor *m = insp.count ? xytomon(cursor->x, cursor->y) : NULL;

	if (!m || !m->declare || !m->declare->inspecting)
		return;
	m->declare->scroll_x += dx;
	m->declare->scroll_y += dy;
	declare_output_mark_dirty(m->declare);
}

bool
declare_inspector_covers(double lx, double ly)
{
	Monitor *m = insp.count ? xytomon(lx, ly) : NULL;

	/* While lua-locked the desktop band, panel included, sits under
	 * locked_bg. */
	if (!m || !m->declare || !m->declare->inspecting || some_is_lua_locked())
		return false;
	return lx - m->m.x >= m->m.width - (double)Clay__debugViewWidth;
}

/* Hand Clay one pass's worth of seat, for the panel only. Every state is
 * forced rather than mirrored, because Clay's pointer state is an edge
 * machine driven by a function other callers also invoke:
 * declare_widget_hits runs Clay_SetPointerState on every hit query, and
 * each call advances the machine. The transition is a pure function of
 * (previous state, down), so two calls pin any state whatever those
 * queries left behind: (up, down) is the one PRESSED_THIS_FRAME, (down,
 * down) is PRESSED, (up, up) is RELEASED. Runs before Clay_BeginLayout,
 * against the previous pass's tree, which is what the panel wants: the row
 * under the cursor and the close button it may have pressed belong to the
 * panel it drew last.
 *
 * An output the cursor is not over is pinned to a point off its panel, up:
 * a stale hover clears, and no press or wheel lands where the cursor is
 * not. (Kiln fed the converted point into every inspecting context, and
 * Clay's row math, clay.h:3405-3414, drops the hover only for a point left
 * of the panel, so a cursor on the screen to the right picked a row by y.)
 *
 * Returns whether a press edge was fed. The caller retires it after
 * Clay_EndLayout: the close button registers a hover handler every frame
 * that fires inside Clay_SetPointerState on PRESSED_THIS_FRAME
 * (clay.h:3370-3376), and left standing, the next hit query over that
 * button would close the panel out of nowhere. */
static bool
inspector_feed(struct declare_output *dout, Monitor *m, Clay_Vector2 *point)
{
	bool mine = xytomon(cursor->x, cursor->y) == m;
	bool edge = false;

	*point = mine ? (Clay_Vector2) { cursor->x - m->m.x, cursor->y - m->m.y }
		: (Clay_Vector2) { -1, -1 };
	if (dout->press_pending) {
		/* Latched onto this output; a cursor that left since is a lost
		 * click, not one delivered somewhere else. */
		dout->press_pending = false;
		if (mine) {
			Clay_SetPointerState(*point, false);
			Clay_SetPointerState(*point, true);
			edge = true;
		}
	}
	if (!edge) {
		bool down = insp.down && mine;

		Clay_SetPointerState(*point, down);
		Clay_SetPointerState(*point, down);
	}
	/* At most once per pass, and only with a delta: it drops every scroll
	 * record not declared since the last call (clay.h:4045), so a second
	 * call in one pass would purge the panel's own panes. Clay's own scroll
	 * handling stays in charge, since the panel's clips and its hovered-row
	 * math are both written against it; the overflow scroll nodes set
	 * their childOffset themselves and never read it. */
	if (dout->scroll_x != 0 || dout->scroll_y != 0) {
		Clay_UpdateScrollContainers(false,
			(Clay_Vector2) { dout->scroll_x, dout->scroll_y }, 0);
		dout->scroll_x = dout->scroll_y = 0;
	}
	return edge;
}

/* The panel closed itself through its x button: the screen hears the
 * signal the property setter emits (objects/screen.c). After the frame,
 * so a handler may dirty the output. */
static void
inspector_emit_closed(Monitor *m)
{
	lua_State *L = globalconf_L;
	screen_t *s = luaA_screen_get_by_monitor(L, m);

	if (!s)
		return;
	luaA_screen_push(L, s);
	luaA_object_emit_signal(L, -1, "property::inspector", 0);
	lua_pop(L, 1);
}

/* --- the solved tree dump (somewm-client clay tree) ---
 *
 * Per band: a header of counters, the root and derived counts, the declared
 * tree as the pass recorded it (one element per line, indented, joined to
 * the solve's boxes by id), the drawins it refused, then the realized list:
 * one line per retained node in draw order, read back from what the last
 * reconcile retained (render.h). Nothing here solves or declares: the dump
 * reports the frame the output drew. The realized list doubles as a
 * tree==scene check in release builds, where the verifier is compiled out,
 * by printing the renderer's own mismatch answer.
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
widget_node_for_id(struct widget_tree *d, size_t *i, Clay_ElementId id, uint32_t want)
{
	const struct widget_node *n = &d->nodes[(*i)++];
	const struct widget_node *hit = id.id == want ? n : NULL;

	for (uint16_t k = 0; k < n->children; k++) {
		const struct widget_node *c = widget_node_for_id(d, i,
			widget_child_id(d, *i, id, k), want);

		if (c && !hit)
			hit = c;
	}
	return hit;
}

/* What the node is. A leaf that carries no handle (a drawin's shadow and
 * border, the fullscreen backing, every SCISSOR marker) stands for no object
 * and says so. */
static const char *const kind_names[] = {
	[DECLARE_KIND_CLIENT] = "client",
	[DECLARE_KIND_LAYER] = "layer",
	[DECLARE_KIND_DRAWIN] = "drawin",
	[DECLARE_KIND_TITLEBAR] = "titlebar",
	[DECLARE_KIND_WALLPAPER] = "output",
	[DECLARE_KIND_LOCK] = "lock",
	[DECLARE_KIND_DRAG] = "drag",
	[DECLARE_KIND_POPUP] = "popup",
};

/* The object a handle names, bare: the record line puts its role before it
 * and the realized list its kind. */
static void
dump_object(buffer_t *buf, uint64_t handle)
{
	enum declare_kind kind = 0;
	void *object = declare_handle_get(handle, &kind);

	if (!object) {
		buffer_adds(buf, "-");
		return;
	}
	switch (kind) {
	case DECLARE_KIND_CLIENT:
		buffer_adds(buf, client_get_appid(object));
		break;
	case DECLARE_KIND_LAYER: {
		struct wlr_layer_surface_v1 *ls =
			((LayerSurface *)object)->layer_surface;

		buffer_adds(buf, ls->namespace ? ls->namespace : "?");
		break;
	}
	case DECLARE_KIND_WALLPAPER:
		buffer_adds(buf, ((Monitor *)object)->wlr_output->name);
		break;
	case DECLARE_KIND_LOCK:
		buffer_adds(buf, ((Monitor *)((struct wlr_session_lock_surface_v1 *)
			object)->output->data)->wlr_output->name);
		break;
	case DECLARE_KIND_DRAG:
		buffer_adds(buf, "icon");
		break;
	case DECLARE_KIND_POPUP: {
		Client *c = NULL;
		LayerSurface *l = NULL;
		int type = toplevel_from_wlr_surface(
			((Popup *)object)->popup->base->surface, &c, &l);

		buffer_adds(buf, type == LayerShell && l
			? (l->layer_surface->namespace ? l->layer_surface->namespace : "?")
			: c ? client_get_appid(c) : "-");
		break;
	}
	case DECLARE_KIND_TITLEBAR:
		buffer_adds(buf, client_get_appid(((drawable_t *)object)->owner.client));
		break;
	case DECLARE_KIND_DRAWIN: {
		drawin_t *d = object;

		buffer_addf(buf, "screen %d %dx%d+%d+%d",
			d->screen ? d->screen->index : 0,
			d->width, d->height, d->x, d->y);
		break;
	}
	}
}

/* What a realized node is: a widget node of a converted drawin is named by
 * its class, since a converted drawin declares no leaf of its own and every
 * node carrying its handle is one of its widgets; anything else is its kind
 * and the object its handle names. */
static void
dump_what(buffer_t *buf, uint32_t id, void *userdata)
{
	uint64_t handle = declare_userdata_handle(userdata);
	enum declare_kind kind = 0;
	drawin_t *d = declare_handle_get(handle, &kind);

	if (!d) {
		buffer_adds(buf, "-");
		return;
	}
	if (kind == DECLARE_KIND_DRAWIN && d->widgets.nodes_len > 0) {
		size_t i = 0;
		const struct widget_node *n = widget_node_for_id(&d->widgets,
			&i, (Clay_ElementId) {.id = d->widgets.root_id}, id);

		if (n && n != d->widgets.nodes) {
			buffer_addf(buf, "widget %s%s", n->cls ? n->cls : "-",
				n->image ? " image" : "");
			return;
		}
	}
	buffer_addf(buf, "%s ", kind_names[kind]);
	dump_object(buf, handle);
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
	/* A SCISSOR marker and a clip mark realize no node by design; anything
	 * else that did not is a surface whose client died mid-frame. */
	if (v->clip_mark)
		buffer_adds(buf, " clip");
	else if (!v->has_node && v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_START
			&& v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_END)
		buffer_adds(buf, " no-node");
	if (v->rbox.width != v->box.width || v->rbox.height != v->box.height
			|| v->rbox.x != v->box.x || v->rbox.y != v->box.y)
		buffer_adds(buf, " [solved!=realized]");
	if (v->mismatch)
		buffer_adds(buf, " [tree!=scene]");
	buffer_adds(buf, "\n");
}

/* One axis of a node's sizing, as the tree declares it, not as it solved:
 * a number is CLAY_SIZING_FIXED, percent prints times 100 then % as in
 * Clay's inspector (third_party/clay.h:3320-3322), and fit and grow carry
 * the floor and ceiling when the node set them. A fixed root is the
 * drawin's geometry whatever the node says (declare_widget_subtree). */
static void
dump_sizing(buffer_t *buf, const struct widget_node *n, int axis)
{
	if (n->sizing[axis] == WIDGET_SIZING_FIXED) {
		buffer_addf(buf, "fixed(%g)", n->size[axis]);
		return;
	}
	if (n->sizing[axis] == WIDGET_SIZING_PERCENT) {
		buffer_addf(buf, "percent(%g)", n->size[axis]);
		return;
	}
	buffer_adds(buf, n->sizing[axis] == WIDGET_SIZING_GROW ? "grow" : "fit");
	if (n->min[axis] > 0)
		buffer_addf(buf, ">=%g", n->min[axis]);
	if (n->max[axis] > 0)
		buffer_addf(buf, "<=%g", n->max[axis]);
}

/* One line per node of a converted tree, in preorder, indented by depth:
 * what the tree says the node is and the box the last solve gave it.
 *
 * This walks the element tree, not the render commands, and that is the
 * point: Clay emits a RECTANGLE only for an element whose background has
 * alpha (clay.h:2778-2781), so a container that paints nothing is solved and
 * placed but appears in no command. The command list below can never show
 * those, and they are most of a widget tree. */
static size_t
dump_widget_node(buffer_t *buf, const struct widget_host *host, size_t i, Clay_ElementId id,
	int depth)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	size_t next = i + 1;

	buffer_addf(buf, "    %08x %*s%s", id.id, depth * 2, "",
		n->cls ? n->cls : "-");
	if (n->image) {
		buffer_addf(buf, " image %dx%d", cairo_image_surface_get_width(
			(cairo_surface_t *)n->image),
			cairo_image_surface_get_height((cairo_surface_t *)n->image));
		if (n->filter) {
			static const char *const filters[] = {
				"fast", "good", "best", "nearest", "bilinear"
			};
			buffer_addf(buf, " filter=%s", filters[n->filter - 1]);
		}
		if (n->natural)
			buffer_adds(buf, " natural");
	} else if (n->shape)
		buffer_adds(buf, " shape");
	if (!n->widget && !n->text && !n->image)
		buffer_adds(buf, " spacer");
	if (n->clip_opens)
		buffer_adds(buf, " clip");
	if (n->scroll)
		buffer_addf(buf, " scroll=%s", n->scroll == 1 ? "x" : "y");
	if (n->scrolled > 0)
		buffer_addf(buf, " scrolled=%g", n->scrolled);
	if (n->text) {
		buffer_addf(buf, " \"%.*s\" font=%u", (int)n->text_len,
			d->text + n->text_off, n->font);
	} else if (i == 0 && host->flow) {
		for (int axis = 0; axis < 2; axis++) {
			buffer_adds(buf, axis ? " h=" : " w=");
			if (host->fit[axis])
                dump_sizing(buf, n, axis);
            else if (host->told[axis])
				buffer_addf(buf, "fixed(%d)", host->told[axis]);
			else
				buffer_adds(buf, "grow");
		}
	} else if (i == 0 && n->sizing[0] == WIDGET_SIZING_FIXED
			&& n->sizing[1] == WIDGET_SIZING_FIXED) {
		buffer_addf(buf, " w=fixed(%d) h=fixed(%d)", host->w, host->h);
	} else {
		buffer_adds(buf, " w=");
		dump_sizing(buf, n, 0);
		buffer_adds(buf, " h=");
		dump_sizing(buf, n, 1);
	}
	if (!n->text) {
		if (i == 0 && host->flow) {
			if (host->told[0] || host->told[1]) buffer_adds(buf, " user");
		} else if (n->sizing[0] == WIDGET_SIZING_FIXED
				|| n->sizing[1] == WIDGET_SIZING_FIXED) {
			buffer_adds(buf, i == 0 || n->last_frame_size ? " last-frame" : " user");
		}
		if (!n->image && !n->shape)
			buffer_adds(buf, n->vertical ? " column" : " row");
		if (n->pad[0] || n->pad[1] || n->pad[2] || n->pad[3])
			buffer_addf(buf, " pad %u,%u,%u,%u", n->pad[0], n->pad[1], n->pad[2], n->pad[3]);
		if (n->gap)
			buffer_addf(buf, " gap %u", n->gap);
		if (n->floating && data.found) {
			Clay_ElementDeclaration declared;
			if (clay_element_declaration(id, &declared)) {
				const Clay_FloatingElementConfig *f = &declared.floating;
				buffer_addf(buf, " attach PARENT offset %g,%g band %d", f->offset.x, f->offset.y, f->zIndex);
			}
		}
	}
	if (data.found)
		buffer_addf(buf, " box %d,%d %dx%d",
			(int)data.boundingBox.x, (int)data.boundingBox.y,
			(int)data.boundingBox.width,
			(int)data.boundingBox.height);
	else
		buffer_adds(buf, " box -");
	buffer_adds(buf, "\n");

	for (uint16_t k = 0; k < n->children; k++)
		next = dump_widget_node(buf, host, next,
			widget_child_id(d, next, id, k), depth + 1);
	return next;
}

/* Why a drawin has no compiled tree, using the states from widget.h. */
static void
dump_whole(buffer_t *buf, drawin_t *d)
{
	switch (d->widgets.state) {
	case WIDGET_NODES_NONE:
		buffer_adds(buf, " nothing converted");
		break;
	case WIDGET_NODES_MALFORMED:
		buffer_adds(buf, " malformed tree");
		break;
	case WIDGET_NODES_OVER_BUDGET:
		buffer_adds(buf, " over the output's element budget");
		break;
	default:
		buffer_adds(buf, " not compiled yet");
		break;
	}
	buffer_adds(buf, "\n");
}

/* One axis of a recorded element, Clay's own sizing types by the examples'
 * names (third_party/clay.h:304-307). */
static void
dump_axis(buffer_t *buf, Clay_SizingAxis a)
{
	switch (a.type) {
	case CLAY__SIZING_TYPE_FIXED:
		buffer_addf(buf, "fixed(%g)", a.size.minMax.min);
		return;
	case CLAY__SIZING_TYPE_PERCENT:
		buffer_addf(buf, "percent(%g)", a.size.percent);
		return;
	default:
		buffer_adds(buf, a.type == CLAY__SIZING_TYPE_GROW ? "grow" : "fit");
		if (a.size.minMax.min > 0)
			buffer_addf(buf, ">=%g", a.size.minMax.min);
		if (a.size.minMax.max > 0)
			buffer_addf(buf, "<=%g", a.size.minMax.max);
	}
}

static const char *const src_names[] = {
	[DECLARE_SRC_NONE] = NULL,
	[DECLARE_SRC_OUTPUT] = "output",
	[DECLARE_SRC_THEME] = "theme",
	[DECLARE_SRC_PROTOCOL] = "protocol",
	[DECLARE_SRC_USER] = "user",
	[DECLARE_SRC_LAST_FRAME] = "last-frame",
	[DECLARE_SRC_DERIVED] = "derived",
};

/* The declared tree, one element per line in declaration order, indented by
 * depth: its role, the object it stands for, its sizing with where a fixed
 * number came from, its flow, its attachment when it floats, and the box the
 * solve gave it. A widget tree's root carries the retained tree's nodes
 * under it, in the format the widget tests read. This is the hierarchy the
 * examples are written in, so the two can be read side by side. */
static void
dump_records(buffer_t *buf, struct declare_band *band)
{
	static const char *const attach_names[] = {
		[CLAY_ATTACH_TO_NONE] = "none",
		[CLAY_ATTACH_TO_PARENT] = "PARENT",
		[CLAY_ATTACH_TO_ELEMENT_WITH_ID] = "ELEMENT",
		[CLAY_ATTACH_TO_ROOT] = "ROOT",
	};
	int depth[1024];

	for (size_t i = 0; i < band->records_len; i++) {
		struct declare_record *r = &band->records[i];
		Clay_ElementData data = Clay_GetElementData((Clay_ElementId) { .id = r->id });
		int d = r->parent < 0 || r->parent >= (int)LENGTH(depth)
			? 0 : depth[r->parent] + 1;

		if (i < LENGTH(depth))
			depth[i] = d;
		buffer_addf(buf, "  %*s%s ", d * 2, "", r->role);
		if (r->handle)
			dump_object(buf, r->handle);
		else
			buffer_adds(buf, "-");
		if (r->has_host) {
			struct widget_tree *t = r->host.tree;

			buffer_addf(buf, " converted: %zu nodes, %zu images",
				t->nodes_len, t->leaves_len);
			if (r->host.radius > 0)
				buffer_addf(buf, ", radius %g", r->host.radius);
		}
		if (r->clip)
			buffer_adds(buf, " clip");
		buffer_adds(buf, " w=");
		dump_axis(buf, r->sizing.width);
		buffer_adds(buf, " h=");
		dump_axis(buf, r->sizing.height);
		if (src_names[r->src])
			buffer_addf(buf, " %s", src_names[r->src]);
		if (!r->custom && !r->image)
			buffer_adds(buf, r->vertical ? " column" : " row");
		if (r->padding.left || r->padding.right || r->padding.top
				|| r->padding.bottom)
			buffer_addf(buf, " pad %u,%u,%u,%u", r->padding.left,
				r->padding.right, r->padding.top, r->padding.bottom);
		if (r->gap)
			buffer_addf(buf, " gap %u", r->gap);
		const char *attach = attach_names[r->attach_to];
		if (r->attach_to == CLAY_ATTACH_TO_ELEMENT_WITH_ID)
			for (size_t j = 0; j < band->records_len; j++)
				if (band->records[j].id == r->attach_id
						&& !strcmp(band->records[j].role, "OUTPUT"))
					attach = "OUTPUT";
		if (r->floating)
			buffer_addf(buf, " attach %s offset %g,%g band %d",
				attach, r->offset.x, r->offset.y,
				r->band);
        if (r->floating && (!strcmp(r->role, "POPUP") || !strcmp(r->role, "TOOLTIP")
                || !strcmp(r->role, "NOTIFICATIONS") || !strcmp(r->role, "LAUNCHER")
                || !strcmp(r->role, "LAYER_OVERLAY"))) {
            static const char *points[] = { "LEFT_TOP", "LEFT_CENTER", "LEFT_BOTTOM",
                "TOP_CENTER", "CENTER", "BOTTOM_CENTER", "RIGHT_TOP", "RIGHT_CENTER", "RIGHT_BOTTOM" };
            buffer_addf(buf, " target %08x parent %s own %s pointer %s", r->attach_id,
                points[r->points.parent], points[r->points.element],
                r->passthrough ? "passthrough" : "capture");
        }
		if (r->custom)
			buffer_adds(buf, " custom");
		if (r->image)
			buffer_adds(buf, " image");
		if (data.found)
			buffer_addf(buf, " box %d,%d %dx%d\n",
				(int)data.boundingBox.x, (int)data.boundingBox.y,
				(int)data.boundingBox.width,
				(int)data.boundingBox.height);
		else
			buffer_adds(buf, " box -\n");
		if (r->has_host) {
			struct widget_tree *tree = r->host.tree;
			Clay_ElementId root_id = {.id = tree->root_id};
			if (r->id == root_id.id) {
				size_t next = 1;
				for (uint16_t k = 0; k < tree->nodes[0].children; k++)
					next = dump_widget_node(buf, &r->host, next,
						widget_child_id(tree, next, root_id, k), d);
			} else
				dump_widget_node(buf, &r->host, 0, root_id, d);
		}
	}
}

/* The counts the acceptance reads: flow roots (one is the target, zero is
 * today's shape where every root floats at a computed box), floating roots,
 * and elements whose number somewm derived from other boxes. */
static void
dump_counts(buffer_t *buf, struct declare_band *band)
{
	int flow = 0, floating = 0, derived = 0;

	for (size_t i = 0; i < band->records_len; i++) {
		struct declare_record *r = &band->records[i];

		if (r->parent < 0 && r->floating)
			floating++;
		else if (r->parent < 0)
			flow++;
		if (r->src == DECLARE_SRC_DERIVED)
			derived++;
	}
	buffer_addf(buf, "  roots flow %d floating %d derived %d\n",
		flow, floating, derived);
}

/* Visible drawins the band shows nothing for, with why (the states in
 * widget.h): a tree that failed to convert is left out of the tree by name,
 * never drawn by a fallback. */
static void
dump_refused(buffer_t *buf, Monitor *m, bool lock)
{
	if (lock && !session_is_locked())
		return;
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		if (lock ? !some_is_lock_drawin(d)
				: (session_is_locked()
					&& some_is_lock_drawin(d)))
			continue;
		if (!d->visible || !d->screen || d->screen->monitor != m
				|| d->widgets.nodes_len > 0)
			continue;
		buffer_addf(buf, "  drawin screen %d %dx%d+%d+%d nothing:",
			d->screen->index, d->width, d->height, d->x, d->y);
		dump_whole(buf, d);
	}
}

static void
dump_band(buffer_t *buf, struct declare_band *band, Monitor *m,
	const char *name, bool lock)
{
	struct wlr_output *o = m->wlr_output;
	Clay_Context *previous;

	if (!band->clay)
		return;
	/* The solved boxes and the inspector flag come out of this band's own
	 * Clay context, which is a read of its state; nothing here declares or
	 * solves. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	buffer_addf(buf, "output %s band %s scale %.2f inspector %s\n", o->name,
		name, o->scale, Clay_IsDebugModeEnabled() ? "on" : "off");
	buffer_addf(buf, "  commands %d mutations %d nodes %zu raster_bytes %zu "
		"buffers %d declare %" PRId64 "us solve %" PRId64 "us "
		"reconcile %" PRId64 "us\n",
		band->commands, band->mutations,
		render_node_count(band->render),
		render_raster_bytes(band->render),
		render_buffers_created(band->render),
		band->declare_us, band->solve_us, band->reconcile_us);
	dump_counts(buf, band);
	dump_records(buf, band);
	dump_refused(buf, m, lock);
	buffer_adds(buf, "  realized:\n");
	render_walk(band->render, dump_node, buf);
	Clay_SetCurrentContext(previous);
}

char *
declare_dump(Monitor *only)
{
	buffer_t buf = BUFFER_INIT;
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		if (!m->declare || (only && m != only))
			continue;
		dump_band(&buf, &m->declare->desktop, m, "desktop", false);
		dump_band(&buf, &m->declare->lock, m, "lock", true);
	}
	return buffer_detach(&buf);
}
