#ifndef SOMEWM_RENDER_H
#define SOMEWM_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "clay.h"

struct wlr_scene_tree;
struct wlr_scene_node;

struct render_state;

struct render_gradient {
	int kind;
	float points[6];
	int count;
	float stops[16][5];
};

struct render_shape {
	uint64_t gen;
	float fill[4];
	struct render_gradient gradient;
	float stroke[4];
	float stroke_width;
};

/* How the renderer reaches client surfaces. resolve returns the client's
 * scene tree for a handle, or NULL if the client is gone (then the
 * renderer must not touch any stored pointer). configure asks the client
 * to match its solved box. borrow records the render_state that reparented
 * the tree as its current owner. release returns a borrowed tree to its
 * home parent, disabled, but only if the caller is still the owner: after a
 * client migrates to another output, the old output's sweep must not
 * disable a node the new owner is showing. release answers whether the
 * caller was the owner; the renderer then parks the tree itself. The owner
 * token is an opaque render_state pointer. reposition notes that a borrowed tree moved this
 * frame (its solved position changed), so the owner can re-derive anything
 * keyed to the tree's scene position, namely xdg-popup unconstrain and X11
 * root coordinates; x and y are the tree's new position, band-local. C to
 * C, never Lua; optional (a NULL reposition is not called).
 *
 * The renderer holds no client knowledge: window.c implements these (handle =
 * the client, resolve returns c->scene) and declare.c hands them to every
 * reconcile. */
struct render_client_hooks {
	struct wlr_scene_tree *(*resolve)(void *data, uint64_t handle);
	void (*configure)(void *data, uint64_t handle, int width, int height);
	void (*borrow)(void *data, uint64_t handle, void *owner);
	bool (*release)(void *data, uint64_t handle, void *owner);
	void (*reposition)(void *data, uint64_t handle, int x, int y);
	/* Realized origin relative to the solved origin; width 0 removes the crop.
	 * Optional, like reposition. */
	void (*clip)(void *data, uint64_t handle, int x, int y, int width, int height);
	/* Path floats for the solved logical box, 0 for no path. A count above
	 * cap reports overflow. NULL draws no shape leaves. */
	size_t (*shape_ops)(void *data, const struct render_shape *shape,
		float w, float h, float *ops, size_t cap);
	void *data;
};

struct render_state *render_create(struct wlr_scene_tree *parent);

/* The disabled tree, under root, where surface trees live while no output
 * declares them: born there, and returned there on release. Created on first
 * use. */
struct wlr_scene_tree *render_parked_tree(struct wlr_scene_tree *root);

/* Apply a declared opacity to every buffer under a borrowed surface tree.
 * The reconcile applies the word's opacity; a surface commit resets
 * wlroots' buffers to opaque, so the commit path re-applies it. */
void render_tree_set_opacity(struct wlr_scene_node *node, float opacity);

/* Show or hide everything this render_state drew, without dropping the retained
 * nodes, so a band that is raised again does not first flash its last frame. */
void render_set_enabled(struct render_state *rs, bool on);
void render_destroy(struct render_state *rs,
	const struct render_client_hooks *hooks);

/* Reconcile a solved command array into the scene. Returns the number of
 * scene mutations performed (0 for an identical frame). bounds is the box a
 * command clipped by RENDER_CLIP_BOUNDS is cut to (the output). Afterwards,
 * in builds compiled with SOMEWM_RENDER_VERIFY, the tree==scene verifier
 * compares every command box against the scene and aborts on divergence. */
int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
	const struct render_client_hooks *hooks, Clay_BoundingBox bounds);

/* Identify OUTPUT, whose own rectangle and untinted image paint below all
 * other commands. Zero leaves every element in ordinary command order. */
void render_set_output_id(struct render_state *rs, uint32_t id);

/* Read the retained shadow geometry used for painting and dump records. */
bool render_shadow_box(struct render_state *rs, uint32_t id, Clay_BoundingBox *box);

/* Move the per-output UI tree to the output's position in the layout. */
void render_set_position(struct render_state *rs, int x, int y);

/* The output's scale, applied to every raster from the next reconcile on: buffers
 * are sized in device pixels (edges rounded in device space, so shared tile edges
 * cannot seam) and content is drawn at device density, so a fractional output is
 * sharp. Clay still solves in logical px (wlr_output_effective_resolution divides
 * by scale), so this touches only the raster, never the layout. A change re-rasters
 * this output's nodes (scale joins the raster cache key). */
void render_set_scale(struct render_state *rs, float scale);

/* The device length of a logical span, rounded at both edges: what every
 * raster buffer is sized by, so a surface sized with it lands in its box
 * without resampling. */
int render_device_len(int origin, int len, float scale);

/* The userData channel: Clay carries each element's userData word into its
 * render commands untouched, and the renderer retains it per node. The word
 * is a packed integer, never a pointer, so a retained command can never
 * dangle into freed declarer state. Bits 0-39 are the declarer's to encode
 * and to get back from render_hit_userdata(); the renderer reads the three
 * bytes above them:
 *
 * - bits 40-47, the opacity of an IMAGE command: 0 means unset, fully
 *   opaque, else 1 + opacity * 254.
 * - bits 48-55, the clip scope a RECTANGLE command opens, 0 for none. A
 *   scope is the rectangle's realized box and corner radius, named by this
 *   number under the word's bits 0-39, so two declarers never share one; it
 *   lives for the frame. A TEXT command opens no scope and carries its text
 *   flags here instead (render_text.h).
 * - bits 56-63, the scope the command is clipped by: 0 for none, a number a
 *   RECTANGLE earlier in the frame opened under the same bits 0-39, or
 *   RENDER_CLIP_BOUNDS for the bounds render_reconcile() was handed. A
 *   command is cut to the scope's box, rectangle and arc; a rectangle that
 *   opens a scope of its own composes it with the one it is clipped by.
 *
 * These scopes provide rounded clipping. Clay's SCISSOR commands provide
 * rectangular clipping for passive hosts, scrolling and the inspector;
 * the renderer intersects both kinds of clip when they overlap. */
#define RENDER_UD_OWNER_MASK 0xFFFFFFFFFFULL
/* The customData of a CUSTOM command that names no client: the element opens
 * the scope its word says and is realized as a fully transparent rect, which
 * wlr_scene leaves out of the render list (scene_node_invisible, an alpha of
 * 0) and still hit-tests (scene_node_at_iterator checks no alpha). That is
 * how a container with no fill clips what it holds, and how a transparent
 * drawin's root takes input over its whole box as a wibox does (Clay emits a
 * RECTANGLE only for a fill, clay.h:2780, and a CUSTOM command regardless,
 * clay.h:2875). All ones, a value no handle takes. */
#define RENDER_CLIP_MARK ((void *)(uintptr_t)UINT64_MAX)
struct render_shadow {
	uint64_t gen;
	int radius, corner_radius;
	float rgba[4];
	uint32_t owner_id;
	int spread, offset_x, offset_y;
	/* Current completed layout, including owners with no paint command. */
	Clay_BoundingBox owner_box;
};

#define RENDER_SHADOW_TAG (UINT64_C(1) << 62)
static inline void *render_shadow_tag(struct render_shadow *shadow)
{
	return (void *)((uintptr_t)shadow | RENDER_SHADOW_TAG);
}
static inline struct render_shadow *render_shadow_of(void *data)
{
	return (struct render_shadow *)((uintptr_t)data & ~RENDER_SHADOW_TAG);
}

#define RENDER_SHAPE_TAG (UINT64_C(1) << 63)

static inline void *render_shape_tag(struct render_shape *shape)
{
	return (void *)((uintptr_t)shape | RENDER_SHAPE_TAG);
}

static inline struct render_shape *render_shape_of(void *data)
{
	return (struct render_shape *)((uintptr_t)data & ~RENDER_SHAPE_TAG);
}

#define RENDER_UD_OPACITY_SHIFT 40
#define RENDER_UD_OPENS_SHIFT 48
#define RENDER_UD_CLIP_SHIFT 56
#define RENDER_CLIP_BOUNDS 0xffu

static inline unsigned
render_userdata_byte(void *ud, unsigned shift)
{
	return ((uintptr_t)ud >> shift) & 0xff;
}

static inline float
render_userdata_opacity(void *ud)
{
	unsigned byte = render_userdata_byte(ud, RENDER_UD_OPACITY_SHIFT);
	return byte ? (float)(byte - 1) / 254.0f : 1.0f;
}

/* The retained userData word of the command that drew node (the node itself,
 * or an ancestor for a border's side rects), or 0 for a node this
 * render_state did not draw. Works for every command type, which is what
 * makes it the input backmap: BORDER and TEXT nodes carry no element id
 * but do carry their element's word. */
void *render_hit_userdata(struct render_state *rs, struct wlr_scene_node *node);

/* One retained node, as the tree dump reads it back (declare.c formats the
 * line). The renderer names no object: user_data is the declarer's word and
 * id its Clay element id, both handed back untouched. */
struct render_node_view {
	uint32_t type;   /* Clay_RenderCommandType */
	uint32_t id;     /* the Clay element id; TEXT and BORDER carry a
			  * Clay-derived per-line / per-side hash instead */
	int16_t z;
	Clay_BoundingBox box;   /* solved geometry, or owner-relative shadow geometry */
	Clay_BoundingBox rbox;  /* what was realized, after the clip */
	size_t raster_bytes;    /* nonzero for a node holding a cairo raster */
	bool has_node;          /* false for a SCISSOR marker, a clip mark or a
				 * dead surface */
	bool clip_mark;         /* a CUSTOM command carrying RENDER_CLIP_MARK */
	bool mismatch;          /* the scene disagrees with rbox */
	void *user_data;
};

/* The topmost retained node under a band-local point that accept admits,
 * walking the last frame's draw order from the top; a refusal continues
 * below. The renderer applies what it drew (a rounded rect's arcs, a border's
 * ring, a shape's path) before asking; accept applies what the node stands
 * for. sx, sy are node-local. Returns whether anything accepted. */
bool render_hit(struct render_state *rs, double x, double y,
	bool (*accept)(void *user, const struct render_node_view *view,
		double sx, double sy), void *user);

/* Walk the retained nodes in the last pass's draw order, bottom to top, for
 * the tree dump. Reads only what the reconcile already retained; it neither
 * solves nor touches the scene. */
void render_walk(struct render_state *rs,
	void (*fn)(void *user, const struct render_node_view *view), void *user);

/* Profiling readback, logged on every solve so a long-running session can
 * assert growth stays proportional to on-screen content: live retained nodes,
 * resident cairo raster bytes across them, and buffers allocated by the last
 * reconcile pass. */
size_t render_node_count(struct render_state *rs);
size_t render_raster_bytes(struct render_state *rs);
int render_buffers_created(struct render_state *rs);
/* Whether the last reconcile temporarily hid its enabled ancestor while
 * replacing owned primitive nodes. Stable and observable scenes never batch. */
bool render_visibility_batched(struct render_state *rs);

#endif
