/* The renderer: reconciles Clay's sorted render command array into wlr_scene,
 * retained and keyed by (command id, command type). Square rectangles and
 * borders become scene rects; text, images, and rounded rectangles and borders
 * rasterize with cairo into a wlr_buffer (wlr_scene has no rounded or
 * non-rectangular primitive). Unchanged commands cause zero scene mutations;
 * ids that vanish are swept.
 *
 * Ported from kiln, the reference compositor this was proven in. The tree==scene
 * verifier at the tail of every pass is compiled in only under
 * SOMEWM_RENDER_VERIFY (the asan and test builds), never in release. */

#include <assert.h>
#include <drm_fourcc.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cairo.h>
#include <pango/pangocairo.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>

#include "common/util.h"
#include "render.h"
#include "render_image.h"
#include "render_text.h"
#include "shadow.h"

/* All 100 native clips may nest inside a floating root's inherited scissor.
 * CLIP_INF leaves an unclipped axis larger than the output's coordinates. */
#define CLIP_STACK_MAX 101
#define CLIP_INF 1.0e6f

/* A wlr_buffer backed by a cairo image surface, for rasterized text. */
struct cairo_buffer {
	struct wlr_buffer base;
	cairo_surface_t *surface;
};

static void cairo_buffer_destroy(struct wlr_buffer *buffer) {
	struct cairo_buffer *cb = wl_container_of(buffer, cb, base);
	wlr_buffer_finish(buffer);
	cairo_surface_destroy(cb->surface);
	free(cb);
}

static bool cairo_buffer_begin_data_ptr_access(struct wlr_buffer *buffer,
		uint32_t flags, void **data, uint32_t *format, size_t *stride) {
	struct cairo_buffer *cb = wl_container_of(buffer, cb, base);
	if (flags & WLR_BUFFER_DATA_PTR_ACCESS_WRITE) {
		return false;
	}
	unsigned char *pixels = cairo_image_surface_get_data(cb->surface);
	if (pixels == NULL) {
		return false;
	}
	*data = pixels;
	*format = DRM_FORMAT_ARGB8888;
	*stride = cairo_image_surface_get_stride(cb->surface);
	return true;
}

static void cairo_buffer_end_data_ptr_access(struct wlr_buffer *buffer) {
}

static const struct wlr_buffer_impl cairo_buffer_impl = {
	.destroy = cairo_buffer_destroy,
	.begin_data_ptr_access = cairo_buffer_begin_data_ptr_access,
	.end_data_ptr_access = cairo_buffer_end_data_ptr_access,
};

/* wlroots can release a scene buffer's CPU pixels after uploading its texture.
 * Scene readback still needs those pixels. Hold one consumer reference for the
 * node's current raster, shared with the renderer rather than copied, and drop
 * it on replacement or node destruction. This is bounded by raster_bytes. */
struct raster_readback {
	struct wlr_addon addon;
	struct wlr_buffer *buffer;
};

static void raster_readback_destroy(struct wlr_addon *addon) {
	struct raster_readback *readback = wl_container_of(addon, readback, addon);
	wlr_addon_finish(addon);
	if (readback->buffer != NULL) {
		wlr_buffer_unlock(readback->buffer);
	}
	free(readback);
}

static const struct wlr_addon_interface raster_readback_impl = {
	.name = "somewm raster readback",
	.destroy = raster_readback_destroy,
};

static void raster_set_buffer(struct wlr_scene_buffer *sb, struct cairo_buffer *cb) {
	struct wlr_addon *addon = wlr_addon_find(&sb->node.addons, NULL,
		&raster_readback_impl);
	struct raster_readback *readback = addon != NULL
		? wl_container_of(addon, readback, addon) : NULL;
	if (readback == NULL && cb != NULL) {
		readback = calloc(1, sizeof(*readback));
		if (readback == NULL) {
			/* Keep rendering if the optional capture reference cannot allocate. */
			wlr_scene_buffer_set_buffer(sb, &cb->base);
			return;
		}
		wlr_addon_init(&readback->addon, &sb->node.addons, NULL,
			&raster_readback_impl);
	}
	struct wlr_buffer *buffer = cb != NULL ? wlr_buffer_lock(&cb->base) : NULL;
	/* Detach the scene's old release listener before releasing its old raster. */
	wlr_scene_buffer_set_buffer(sb, buffer);
	if (readback != NULL) {
		if (readback->buffer != NULL) {
			wlr_buffer_unlock(readback->buffer);
		}
		readback->buffer = buffer;
	}
}

/* NULL when the surface could not be created. Cairo hands back a nil surface
 * rather than crashing when a dimension exceeds its limits, and a nil surface's
 * data pointer is NULL, so an unchecked buffer reaches wlroots as a scene
 * buffer that reports data access succeeded and yields no pixels. Every caller
 * treats NULL as "no raster this frame". */
static struct cairo_buffer *cairo_buffer_create(int width, int height) {
	struct cairo_buffer *cb = calloc(1, sizeof(*cb));
	if (cb == NULL) {
		return NULL;
	}
	cb->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
		width, height);
	if (cairo_surface_status(cb->surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(cb->surface);
		free(cb);
		return NULL;
	}
	wlr_buffer_init(&cb->base, &cairo_buffer_impl, width, height);
	return cb;
}

/* The nearest rounded clip an element sits under: a clip scope opened by a
 * rounded RECTANGLE (a rounded wibox's root, a rounded background).
 * wlr_scene clips to boxes, so a node whose realized box reaches one of the
 * arc's corner squares is rastered with the arc as its cairo clip instead.
 * radius 0 is no rounded clip at all. */
struct clip_round {
	Clay_BoundingBox box;
	float radius;
};

/* A clip scope a RECTANGLE opened this frame (render.h): its realized box,
 * composed with whatever clipped it, and the nearest arc, its own or the
 * one it sits under. */
struct clip_scope {
	uint64_t owner;
	unsigned number;
	Clay_BoundingBox box;
	struct clip_round round;
};

struct shadow_cache {
	struct shadow_cache *next;
	struct render_shadow style;
	float scale;
	size_t refs, bytes;
	struct cairo_buffer *tiles[SHADOW_SLICE_COUNT];
};

/* One retained record per (command id, command type). */
struct rnode {
	uint64_t key;
	/* box is Clay's solved box; rbox is the realized box after clipping to
	 * the active SCISSOR scope (equal to box when no clip applies). box
	 * drives raster/content diffs; rbox drives node position, size, and the
	 * tree==scene verifier. */
	Clay_BoundingBox box;
	Clay_BoundingBox rbox;
	/* The clip this node was realized against, its scope and the active
	 * SCISSOR together (the infinite box when unclipped or exempt),
	 * retained so the verifier can assert rbox stays inside it: rbox =
	 * box_intersect(box, clip) by construction, so a green check proves no
	 * path skipped the clip. */
	Clay_BoundingBox clip;
	Clay_RenderData data;
	/* The command's z order, retained only so the tree dump can print the
	 * band a node landed in without re-solving. */
	int16_t z;
	char *text;
	int32_t text_len;
	/* RECTANGLE: a scene rect. TEXT: a scene buffer. BORDER: a tree
	 * holding four scene rects (top, right, bottom, left). CUSTOM: a
	 * client scene tree the renderer borrowed, never owned. */
	struct wlr_scene_node *node;
	/* BORDER: a tree of four straight edge rects plus, for a rounded border,
	 * up to four corner arc buffers (tiny tiles, not a full-box buffer).
	 * border_sides holds the edges; border_corners the arcs (NULL/disabled where
	 * a corner radius is zero). */
	struct wlr_scene_rect *border_sides[4];
	struct wlr_scene_buffer *border_corners[4];
	/* Whether each corner's last raster produced a tile. The scene buffer
	 * pointer cannot answer this: the scene frees a dropped raster buffer
	 * after texture upload, so it reads NULL for a corner that still renders. */
	bool border_tile[4];
	/* IMAGE: the decode generation last rasterized, so a reload re-rasters. */
	uint64_t img_gen;
	int img_src_x, img_src_y;
	cairo_surface_t *img_native;
	int img_width, img_height;
	uint8_t img_filter;
	bool img_stretch, img_natural;
	struct render_shape shape;
	struct shadow_cache *shadow;
	struct wlr_scene_buffer *shadow_tiles[SHADOW_SLICE_COUNT];
	struct wlr_scene_rect *shadow_fills[SHADOW_FILL_COUNT];
	float *shape_ops;
	size_t shape_ops_len;
	/* The scale this node's raster was drawn at: the fourth raster cache key
	 * (content, font, size, scale). Clay solves logical, so a scale change alone
	 * leaves the box identical; without this a runtime set_scale would keep the
	 * old-density buffer. Rects and square borders carry no raster, so it stays 0. */
	float raster_scale;
	/* TEXT: the device-pixel bound this node's raster was truncated to, 0 for an
	 * untouched run. A fifth raster key, and the only one not derivable from the
	 * command: it comes from the clip, which can move while the command does not. */
	int text_ellipsis;
	/* The rounded clip this node's raster was cut to at a corner (radius 0
	 * for none): a raster key like text_ellipsis, from its clip scope. */
	struct clip_round mask;
	/* Bytes of the cairo raster this node holds in the scene (0 for rects,
	 * trees, and borrowed clients), kept so the per-state total is O(1). */
	size_t raster_bytes;
	/* Keep dimensions after wlroots releases the CPU buffer on upload. */
	int raster_width, raster_height;
	bool borrowed;
	uint64_t handle;
	uint64_t gen;
	/* The command's userData word (render.h), retained for the input
	 * backmap; and the opacity applied to buffers or folded into rect color. */
	void *user_data;
	float opacity;
};

/* An open-addressing slot mapping a command key to its index in nodes. */
struct rnode_slot {
	uint64_t key;
	size_t index;
	bool used;
};

struct render_state {
	uint32_t output_id;
	bool visibility_batched;
	struct shadow_cache *shadows;
	struct wlr_scene_tree *tree;
	struct rnode *nodes;
	size_t len, cap;
	uint64_t gen;
	/* Retained scene order: OUTPUT's rectangle and image first, followed by
	 * every other command in Clay order. build keeps the new order separate
	 * so an unchanged frame can avoid restacking. */
	uint64_t *order;
	size_t order_len, order_cap;
	uint64_t *build;
	/* key -> index into nodes, so a lookup is O(1) and the reconcile is O(N)
	 * rather than O(N^2). Insert-only, rebuilt from nodes each pass. */
	struct rnode_slot *map;
	size_t map_cap;
	/* The clip scopes of the frame being reconciled, in the order their
	 * rectangles opened them. */
	struct clip_scope *scopes;
	size_t scopes_len, scopes_cap;
	/* Profiling readback: resident cairo raster bytes across all live
	 * nodes, and buffers allocated by the current reconcile pass. */
	size_t raster_bytes;
	int buffers_created;
	bool shape_overflow_logged;
	/* A kind-swap (rounded <-> square rect or border) destroyed and recreated
	 * a node under an unchanged command key this pass. The recreated scene
	 * node was appended at the top of its sibling list, so the restack must
	 * run even though the command order is byte-identical. */
	bool node_recreated;
	/* The output's scale, driving device-pixel raster sizing. 1.0 is the
	 * identity: every device_len below reduces to the logical length, so a
	 * non-HiDPI output rasters exactly as before. */
	float scale;
};

static void shadow_cache_release(struct render_state *rs, struct shadow_cache *cache);

/* The retained node that drew a scene node: the hit node is the retained
 * node itself (rect, buffer) or a descendant of it (a square border's side
 * rect under its tree). */
static struct rnode *rnode_for_scene_node(struct render_state *rs,
		struct wlr_scene_node *node) {
	if (node == NULL) {
		return NULL;
	}
	for (size_t i = 0; i < rs->len; i++) {
		struct rnode *n = &rs->nodes[i];
		if (n->node == NULL) {
			continue;
		}
		for (struct wlr_scene_node *c = node; c != NULL;
				c = c->parent != NULL ? &c->parent->node : NULL) {
			if (c == n->node) {
				return n;
			}
			if (c == &rs->tree->node) {
				break;
			}
		}
	}
	return NULL;
}

struct render_state *render_create(struct wlr_scene_tree *parent) {
	struct render_state *rs = calloc(1, sizeof(*rs));
	rs->tree = wlr_scene_tree_create(parent);
	rs->scale = 1.0f;
	return rs;
}

void render_set_enabled(struct render_state *rs, bool on) {
	wlr_scene_node_set_enabled(&rs->tree->node, on);
}

/* The parked tree is found under its root by the marker in its node data,
 * so a root that is torn down and made again (the solver tests) gets a
 * fresh one instead of a stale pointer. */
static const int parked_marker;

struct wlr_scene_tree *render_parked_tree(struct wlr_scene_tree *root) {
	struct wlr_scene_node *child;
	struct wlr_scene_tree *parked;

	wl_list_for_each(child, &root->children, link)
		if (child->data == &parked_marker)
			return wlr_scene_tree_from_node(child);
	parked = wlr_scene_tree_create(root);
	parked->node.data = (void *)&parked_marker;
	wlr_scene_node_set_enabled(&parked->node, false);
	return parked;
}

void render_tree_set_opacity(struct wlr_scene_node *node, float opacity) {
	if (node->type == WLR_SCENE_NODE_BUFFER) {
		wlr_scene_buffer_set_opacity(wlr_scene_buffer_from_node(node), opacity);
	} else if (node->type == WLR_SCENE_NODE_TREE) {
		struct wlr_scene_node *child;
		wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
			render_tree_set_opacity(child, opacity);
	}
}

/* Hand a borrowed tree back: if the owner hook agrees this render_state
 * still owns it, the tree goes to the parked tree, disabled. A tree whose
 * object died is never touched (the hook answers false). */
static void render_release(struct render_state *rs, struct rnode *n,
		const struct render_client_hooks *hooks) {
	if (hooks->release(hooks->data, n->handle, rs) && n->node != NULL) {
		/* The parked tree hangs off the scene root, the top of this
		 * band's parent chain. */
		struct wlr_scene_tree *root = rs->tree;
		while (root->node.parent != NULL)
			root = root->node.parent;
		wlr_scene_node_reparent(n->node, render_parked_tree(root));
		wlr_scene_node_set_enabled(n->node, false);
	}
}

void render_set_position(struct render_state *rs, int x, int y) {
	/* wlr_scene_node_set_position no-ops on identical coordinates. */
	wlr_scene_node_set_position(&rs->tree->node, x, y);
}

void render_set_output_id(struct render_state *rs, uint32_t id) {
	rs->output_id = id;
}

void render_set_scale(struct render_state *rs, float scale) {
	rs->scale = scale > 0.0f ? scale : 1.0f;
}

/* Device pixels spanned by a logical span [origin, origin+len) at scale: the
 * difference of rounded device edges. This is wlr_scene's own scale_length
 * (types/scene/wlr_scene.c), and matching it verbatim is what makes a raster
 * sample 1:1 (no upscale blur) and two tiles sharing a logical edge land on the
 * same device pixel (no seam). origin is the node's output-local logical position
 * ((int)box coordinate); wlroots derives the same offset. At scale 1 this is len. */
int render_device_len(int origin, int len, float scale) {
	return (int)(round((double)(origin + len) * scale) -
		round((double)origin * scale));
}

#define device_len render_device_len

/* Corner radii in device pixels: a rounded corner drawn into a device-sized
 * buffer must scale its arc, or it shrinks (in logical terms) as scale grows. */
static Clay_CornerRadius scale_corner_radius(Clay_CornerRadius r, float scale) {
	return (Clay_CornerRadius){ r.topLeft * scale, r.topRight * scale,
		r.bottomLeft * scale, r.bottomRight * scale };
}

static size_t rmap_hash(uint64_t key) {
	key ^= key >> 33;
	key *= 0xff51afd7ed558ccdULL;
	key ^= key >> 33;
	key *= 0xc4ceb9fe1a85ec53ULL;
	key ^= key >> 33;
	return (size_t)key;
}

/* Rebuild the key->index map from the current nodes, sized to keep the load
 * factor under one half so probe chains stay short. Called at the start of a
 * pass, and again after the sweep since swap-removal scrambles the indices. */
static void rmap_rebuild(struct render_state *rs) {
	size_t need = 16;
	while (need < rs->len * 2) {
		need *= 2;
	}
	if (rs->map_cap < need) {
		free(rs->map);
		rs->map = malloc(need * sizeof(*rs->map));
		rs->map_cap = need;
	}
	memset(rs->map, 0, rs->map_cap * sizeof(*rs->map));
	size_t mask = rs->map_cap - 1;
	for (size_t i = 0; i < rs->len; i++) {
		size_t s = rmap_hash(rs->nodes[i].key) & mask;
		while (rs->map[s].used) {
			s = (s + 1) & mask;
		}
		rs->map[s].key = rs->nodes[i].key;
		rs->map[s].index = i;
		rs->map[s].used = true;
	}
}

/* Index of key in nodes, or SIZE_MAX. */
static size_t rmap_get(struct render_state *rs, uint64_t key) {
	if (rs->map_cap == 0) {
		return SIZE_MAX;
	}
	size_t mask = rs->map_cap - 1;
	size_t s = rmap_hash(key) & mask;
	while (rs->map[s].used) {
		if (rs->map[s].key == key) {
			return rs->map[s].index;
		}
		s = (s + 1) & mask;
	}
	return SIZE_MAX;
}

bool render_shadow_box(struct render_state *rs, uint32_t id, Clay_BoundingBox *box) {
	size_t idx = rmap_get(rs, (uint64_t)CLAY_RENDER_COMMAND_TYPE_CUSTOM << 32 | id);
	if (idx == SIZE_MAX || !rs->nodes[idx].shadow)
		return false;
	*box = rs->nodes[idx].box;
	return true;
}

static struct rnode *rnode_add(struct render_state *rs, uint64_t key) {
	p_grow(&rs->nodes, rs->len + 1, &rs->cap);
	struct rnode *n = &rs->nodes[rs->len++];
	memset(n, 0, sizeof(*n));
	/* Matches wlroots' default: a fresh scene buffer is opaque, so a
	 * declared opacity of 0.0 must not compare equal to the sentinel. */
	n->opacity = 1.0f;
	n->key = key;
	return n;
}

/* The two-behavior sweep: nodes the renderer created are destroyed;
 * borrowed client trees are handed back through release, which reparents
 * and disables them (or no-ops if the client is already gone). The stored
 * pointer of a borrowed node is never dereferenced here. */
static void rnode_remove(struct render_state *rs, struct rnode *n,
		const struct render_client_hooks *hooks) {
	free(n->text);
	free(n->shape_ops);
	if (n->img_native)
		cairo_surface_destroy(n->img_native);
	if (n->shadow)
		shadow_cache_release(rs, n->shadow);
	else
		rs->raster_bytes -= n->raster_bytes;
	if (n->borrowed) {
		render_release(rs, n, hooks);
	} else {
		/* Hide a retired border once before destroying its child primitives. */
		if ((uint32_t)(n->key >> 32) == CLAY_RENDER_COMMAND_TYPE_BORDER)
			wlr_scene_node_set_enabled(n->node, false);
		wlr_scene_node_destroy(n->node);
	}
	*n = rs->nodes[--rs->len];
}

static float clay_srgb(float channel) {
	return channel / 255.0f;
}

static void clay_color_to_float(Clay_Color c, float out[4]) {
	/* wlr_scene_rect wants premultiplied alpha. */
	float a = clay_srgb(c.a);
	out[0] = clay_srgb(c.r) * a;
	out[1] = clay_srgb(c.g) * a;
	out[2] = clay_srgb(c.b) * a;
	out[3] = a;
}

/* The one rounding rule for a box the scene realizes: round both edges to whole
 * pixels, the size is their difference. This is client_solved_box's rule
 * (declare.c), applied once at the top of the reconcile walk, so a client's
 * configure equals its geometry and two boxes sharing a solved edge share a
 * realized one. Every (int) cast below then reads an exact integer. */
static Clay_BoundingBox box_snap(Clay_BoundingBox b) {
	float x = lroundf(b.x), y = lroundf(b.y);
	return (Clay_BoundingBox){ x, y,
		lroundf(b.x + b.width) - x, lroundf(b.y + b.height) - y };
}

static bool box_pos_equal(Clay_BoundingBox a, Clay_BoundingBox b) {
	return (int)a.x == (int)b.x && (int)a.y == (int)b.y;
}

static bool box_size_equal(Clay_BoundingBox a, Clay_BoundingBox b) {
	return (int)a.width == (int)b.width && (int)a.height == (int)b.height;
}

/* At fractional scale, equal logical sizes can span different device pixels
 * after a move. Reuse only when both the logical and device extents agree. */
static bool raster_size_equal(Clay_BoundingBox a, Clay_BoundingBox b, float scale) {
	return box_size_equal(a, b) &&
		device_len((int)a.x, (int)a.width, scale) ==
			device_len((int)b.x, (int)b.width, scale) &&
		device_len((int)a.y, (int)a.height, scale) ==
			device_len((int)b.y, (int)b.height, scale);
}

/* The visible rectangle of a inside b. A degenerate (zero-area) result means a
 * lies entirely outside the clip; callers realize that as a disabled node or a
 * zero-size rect. */
static Clay_BoundingBox box_intersect(Clay_BoundingBox a, Clay_BoundingBox b) {
	float x0 = a.x > b.x ? a.x : b.x;
	float y0 = a.y > b.y ? a.y : b.y;
	float ax1 = a.x + a.width, ay1 = a.y + a.height;
	float bx1 = b.x + b.width, by1 = b.y + b.height;
	float x1 = ax1 < bx1 ? ax1 : bx1;
	float y1 = ay1 < by1 ? ay1 : by1;
	Clay_BoundingBox r = { x0, y0, x1 > x0 ? x1 - x0 : 0.0f, y1 > y0 ? y1 - y0 : 0.0f };
	return r;
}

static bool box_empty(Clay_BoundingBox b) {
	return (int)b.width <= 0 || (int)b.height <= 0;
}

/* The clip scope stored for an unclipped or clip-exempt node: so large it
 * never bounds anything, matching the SCISSOR unclipped-axis representation. */
static Clay_BoundingBox box_inf(void) {
	Clay_BoundingBox b = { -CLIP_INF, -CLIP_INF, 2.0f * CLIP_INF, 2.0f * CLIP_INF };
	return b;
}

/* inner lies within outer, with a half-pixel tolerance for float noise. */
static bool box_contains(Clay_BoundingBox outer, Clay_BoundingBox inner) {
	const float eps = 0.5f;
	return inner.x >= outer.x - eps && inner.y >= outer.y - eps &&
		inner.x + inner.width <= outer.x + outer.width + eps &&
		inner.y + inner.height <= outer.y + outer.height + eps;
}

/* --- shared raster helpers ---
 *
 * rounded_rect_path and buffer_apply_clip serve every rastered leaf (rounded
 * rectangle, text, image): wlr_scene draws only square fills, so rounded or
 * measured content becomes a cairo buffer that is cropped to its clip. */

/* Whether a realized box touches any of the four corner squares of a rounded
 * clip, which is where a box clip and the arc disagree. */
static bool clip_round_hits(const struct clip_round *m, Clay_BoundingBox b) {
	float r = m->radius;
	if (r <= 0) {
		return false;
	}
	Clay_BoundingBox corners[4] = {
		{ m->box.x, m->box.y, r, r },
		{ m->box.x + m->box.width - r, m->box.y, r, r },
		{ m->box.x, m->box.y + m->box.height - r, r, r },
		{ m->box.x + m->box.width - r, m->box.y + m->box.height - r, r, r },
	};
	for (int i = 0; i < 4; i++) {
		Clay_BoundingBox c = corners[i];
		if (b.x < c.x + c.width && c.x < b.x + b.width &&
				b.y < c.y + c.height && c.y < b.y + b.height) {
			return true;
		}
	}
	return false;
}

static bool corner_radius_zero(Clay_CornerRadius r) {
	return r.topLeft == 0 && r.topRight == 0 &&
		r.bottomLeft == 0 && r.bottomRight == 0;
}

static void rounded_rect_path(cairo_t *cr, double x, double y, double w,
		double h, Clay_CornerRadius r) {
	/* Clamp each radius to half the smaller side so opposite corners cannot
	 * cross into a self-intersecting path. An explicit origin lets a caller add
	 * a second, inset path (the border ring) without CTM games. */
	double m = (w < h ? w : h) / 2.0;
	double tl = r.topLeft > m ? m : r.topLeft;
	double tr = r.topRight > m ? m : r.topRight;
	double br = r.bottomRight > m ? m : r.bottomRight;
	double bl = r.bottomLeft > m ? m : r.bottomLeft;
	double deg = 3.14159265358979323846 / 180.0;
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - tr, y + tr, tr, -90.0 * deg, 0.0);
	cairo_arc(cr, x + w - br, y + h - br, br, 0.0, 90.0 * deg);
	cairo_arc(cr, x + bl, y + h - bl, bl, 90.0 * deg, 180.0 * deg);
	cairo_arc(cr, x + tl, y + tl, tl, 180.0 * deg, 270.0 * deg);
	cairo_close_path(cr);
}

/* Is (px,py) inside the rounded rect [x,y,w,h] with corner radii r? The same
 * shape rounded_rect_path fills, expressed as a point predicate: inside the
 * plain rect, and inside the arc wherever a corner's radius square applies.
 * Radii are clamped to half the smaller side, matching the path. Used by the
 * geometric border hit test (below), never a pixel read. */
static bool point_in_rounded_rect(double px, double py, double x, double y,
		double w, double h, Clay_CornerRadius r) {
	if (px < x || py < y || px >= x + w || py >= y + h) {
		return false;
	}
	double m = (w < h ? w : h) / 2.0;
	double tl = r.topLeft > m ? m : r.topLeft;
	double tr = r.topRight > m ? m : r.topRight;
	double br = r.bottomRight > m ? m : r.bottomRight;
	double bl = r.bottomLeft > m ? m : r.bottomLeft;
	double dx, dy;
	if (px < x + tl && py < y + tl) {                  /* top-left corner */
		dx = px - (x + tl); dy = py - (y + tl);
		return dx * dx + dy * dy <= tl * tl;
	}
	if (px >= x + w - tr && py < y + tr) {             /* top-right corner */
		dx = px - (x + w - tr); dy = py - (y + tr);
		return dx * dx + dy * dy <= tr * tr;
	}
	if (px >= x + w - br && py >= y + h - br) {         /* bottom-right corner */
		dx = px - (x + w - br); dy = py - (y + h - br);
		return dx * dx + dy * dy <= br * br;
	}
	if (px < x + bl && py >= y + h - bl) {              /* bottom-left corner */
		dx = px - (x + bl); dy = py - (y + h - bl);
		return dx * dx + dy * dy <= bl * bl;
	}
	return true;                                       /* the straight interior */
}

/* Crop a buffer leaf to its realized clip box. The buffer covers the full
 * solved box (stretch images use source dimensions). SCISSOR changes the source
 * crop without redrawing the buffer; removing the clip restores the full source. */
static void buffer_apply_clip(struct wlr_scene_buffer *sb,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox, float scale,
		int raster_width, int raster_height) {
	Clay_BoundingBox box = cmd->boundingBox;
	/* dst_size is the node's LOGICAL footprint, and it is always set: the buffer
	 * holds device pixels, so a 0,0 (natural-size) dest would make wlroots read
	 * those device pixels as logical and draw the node scale-times oversize. */
	bool clipped = !box_pos_equal(rbox, box) || !box_size_equal(rbox, box);
	if (clipped && raster_width > 0 && raster_height > 0) {
		/* The visible sub-rect in the device pixels of the full-box buffer.
		 * Every coordinate here is derived exactly as the buffer's own size
		 * was: from the TRUNCATED logical origin, through device_len. The
		 * buffer's pixel 0 is device round((int)box.x * scale), so taking the
		 * crop origin from the unrounded box.x shifts every clipped raster by
		 * a pixel whenever the solved origin has a fractional part. At scale 1
		 * this is the plain logical crop. */
		int ox = (int)box.x, oy = (int)box.y;
		int rx = (int)rbox.x, ry = (int)rbox.y;
		int rw = (int)rbox.width, rh = (int)rbox.height;
		struct wlr_fbox src = {
			device_len(ox, rx - ox, scale),
			device_len(oy, ry - oy, scale),
			device_len(rx, rw, scale),
			device_len(ry, rh, scale) };
		/* Stretch images retain a source-sized raster, and text can retain
		 * extra glyph pixels at fractional scales. Map the destination
		 * grid into that raster; other leaves have a ratio of one. Bound
		 * against actual retained dimensions, including float edge roundoff. */
		double bw = raster_width, bh = raster_height;
		double full_w = device_len(ox, (int)box.width, scale);
		double full_h = device_len(oy, (int)box.height, scale);
		double sx = full_w > 0 ? bw / full_w : 1;
		double sy = full_h > 0 ? bh / full_h : 1;
		src.x = fmax(0, fmin(src.x * sx, bw - fmin(1, sx)));
		src.y = fmax(0, fmin(src.y * sy, bh - fmin(1, sy)));
		src.width = fmin(fmax(1.0, src.width) * sx, bw - src.x);
		src.height = fmin(fmax(1.0, src.height) * sy, bh - src.y);
		wlr_scene_buffer_set_source_box(sb, &src);
		wlr_scene_buffer_set_dest_size(sb, rw, rh);
	} else {
		wlr_scene_buffer_set_source_box(sb, NULL);
		wlr_scene_buffer_set_dest_size(sb, (int)box.width, (int)box.height);
	}
}

static size_t cairo_buffer_bytes(struct cairo_buffer *cb) {
	return (size_t)cairo_image_surface_get_stride(cb->surface) *
		(size_t)cairo_image_surface_get_height(cb->surface);
}

/* Apply the clip to a raster leaf and report whether that alone was a mutation.
 * A re-raster already counted itself and reapplies the crop because setting a
 * fresh buffer resets it; an empty realized box leaves the buffer alone, since
 * the reconcile pass disables the node instead (a 0,0 dest would mean natural
 * size, not zero). Shared by the rounded rect, text and image leaves so the
 * three cannot drift apart. */
static int rnode_apply_clip(struct rnode *n, struct wlr_scene_buffer *sb,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox, float scale,
		bool raster_changed) {
	bool clip_changed = !box_pos_equal(n->rbox, rbox) ||
		!box_size_equal(n->rbox, rbox) ||
		!box_pos_equal(n->box, cmd->boundingBox) ||
		!box_size_equal(n->box, cmd->boundingBox);
	if ((raster_changed || clip_changed) && !box_empty(rbox)) {
		buffer_apply_clip(sb, cmd, rbox, scale, n->raster_width, n->raster_height);
		return clip_changed && !raster_changed ? 1 : 0;
	}
	return 0;
}

/* Swap a raster leaf's buffer, keeping the per-state byte account current:
 * every cairo raster resident in the scene is counted at its swap, so the
 * profiling log reports raster bytes without walking the scene. */
static void rnode_set_raster(struct render_state *rs, struct rnode *n,
		struct wlr_scene_buffer *sb, struct cairo_buffer *cb) {
	size_t bytes = 0;
	if (cb != NULL) {
		bytes = cairo_buffer_bytes(cb);
		rs->buffers_created++;
	}
	rs->raster_bytes = rs->raster_bytes - n->raster_bytes + bytes;
	n->raster_bytes = bytes;
	n->raster_width = cb ? cb->base.width : 0;
	n->raster_height = cb ? cb->base.height : 0;
	raster_set_buffer(sb, cb);
	if (cb != NULL) {
		wlr_buffer_drop(&cb->base);
	}
}

/* --- rectangles ---
 *
 * A square rectangle is a cheap wlr_scene_rect. A rounded rectangle has no
 * scene primitive, so it is cairo-rastered into a buffer and cropped to its
 * clip like text and images. The node kind follows the corner radius, so a
 * radius toggling across frames swaps the kind (handled in the dispatcher). */

/* Clip cr, which draws the device pixels of the buffer for box, to the rounded
 * clip m. The buffer's pixel 0 is device round((int)box.x * scale), as
 * buffer_apply_clip derives it, so the arc lands on the same device pixels
 * the scene crops the box to. */
static void apply_clip_round(cairo_t *cr, Clay_BoundingBox box,
		const struct clip_round *m, float scale) {
	if (m == NULL || m->radius <= 0) {
		return;
	}
	int ox = (int)box.x, oy = (int)box.y;
	int mx = (int)m->box.x, my = (int)m->box.y;
	double x = device_len(ox, mx - ox, scale);
	double y = device_len(oy, my - oy, scale);
	double w = device_len(mx, (int)m->box.width, scale);
	double h = device_len(my, (int)m->box.height, scale);
	Clay_CornerRadius r = { m->radius, m->radius, m->radius, m->radius };
	rounded_rect_path(cr, x, y, w, h, scale_corner_radius(r, scale));
	cairo_clip(cr);
}

/* Whether a node's retained mask differs from the one that applies now. */
static bool clip_round_changed(const struct clip_round *have,
		const struct clip_round *want) {
	struct clip_round none = { 0 };
	if (want == NULL) {
		want = &none;
	}
	return memcmp(have, want, sizeof(*have)) != 0;
}

static void clip_round_keep(struct clip_round *have, const struct clip_round *want) {
	struct clip_round none = { 0 };
	*have = want != NULL ? *want : none;
}

static struct cairo_buffer *rasterize_rounded_rect(Clay_RenderCommand *cmd,
		float scale, const struct clip_round *mask) {
	Clay_RectangleRenderData *rd = &cmd->renderData.rectangle;
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1) {
		return NULL;
	}
	/* Device pixels: the path fills the whole buffer (no transparent seam edge)
	 * and the radius scales, so the corner is a true arc at the output density. */
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_round(cr, cmd->boundingBox, mask, scale);
	rounded_rect_path(cr, 0, 0, w, h, scale_corner_radius(rd->cornerRadius, scale));
	/* Straight alpha as in rasterize_text; cairo premultiplies into ARGB32. */
	cairo_set_source_rgba(cr,
		clay_srgb(rd->backgroundColor.r), clay_srgb(rd->backgroundColor.g),
		clay_srgb(rd->backgroundColor.b), clay_srgb(rd->backgroundColor.a));
	cairo_fill(cr);
	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

static int reconcile_square_rect(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
	Clay_RectangleRenderData *rd = &cmd->renderData.rectangle;
	float color[4];
	clay_color_to_float(rd->backgroundColor, color);
	float opacity = render_userdata_opacity(cmd->userData);
	for (int i = 0; i < 4; i++)
		color[i] *= opacity;
	int muts = 0;

	/* A solid rect crops to its clip by shrinking; the color is uniform, so
	 * the visible region is exactly the intersection box. */
	if (n->node == NULL) {
		struct wlr_scene_rect *rect = wlr_scene_rect_create(rs->tree,
			(int)rbox.width, (int)rbox.height, color);
		n->node = &rect->node;
		n->opacity = opacity;
		/* A radius toggle can create this rect mid-frame, when the common
		 * placement pass no longer sees the node as new; place it now. */
		wlr_scene_node_set_position(n->node, (int)rbox.x, (int)rbox.y);
		return 1;
	}

	struct wlr_scene_rect *rect = wlr_scene_rect_from_node(n->node);
	if (!box_size_equal(n->rbox, rbox)) {
		wlr_scene_rect_set_size(rect, (int)rbox.width, (int)rbox.height);
		muts++;
	}
	if (memcmp(&n->data.rectangle.backgroundColor, &rd->backgroundColor,
			sizeof(rd->backgroundColor)) != 0 || opacity != n->opacity) {
		wlr_scene_rect_set_color(rect, color);
		n->opacity = opacity;
		muts++;
	}
	return muts;
}

/* A clip mark's node: a rect of no color, so wlr_scene never draws it and
 * still hands it back from a hit test (render.h RENDER_CLIP_MARK). */
static int reconcile_clip_mark(struct render_state *rs, struct rnode *n,
		Clay_BoundingBox rbox) {
	static const float none[4] = { 0 };

	if (n->node == NULL) {
		struct wlr_scene_rect *rect = wlr_scene_rect_create(rs->tree,
			(int)rbox.width, (int)rbox.height, none);
		n->node = &rect->node;
		return 1;
	}
	if (!box_size_equal(n->rbox, rbox)) {
		wlr_scene_rect_set_size(wlr_scene_rect_from_node(n->node),
			(int)rbox.width, (int)rbox.height);
		return 1;
	}
	return 0;
}

static int reconcile_rounded_rect(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_round *mask) {
	Clay_RectangleRenderData *rd = &cmd->renderData.rectangle;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
		/* As with reconcile_square_rect, a radius toggle creates this
		 * mid-frame, past the common placement pass. */
		wlr_scene_node_set_position(n->node, (int)rbox.x, (int)rbox.y);
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

	/* The whole Clay_RectangleRenderData (color and radius) plus the scale is the
	 * raster key; re-raster on first sight, a solved-size change, or a rescale. */
	bool raster_changed = is_new ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		memcmp(&n->data.rectangle, rd, sizeof(*rd)) != 0 ||
		clip_round_changed(&n->mask, mask);
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_rounded_rect(cmd, rs->scale, mask));
		n->raster_scale = rs->scale;
		clip_round_keep(&n->mask, mask);
		muts++;
	}

	float opacity = render_userdata_opacity(cmd->userData);
	if (is_new || opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}

	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	return muts;
}

/* A rect's node kind depends on its corner radius, so a radius toggling between
 * zero and nonzero swaps the kind: destroy the old node and let the chosen path
 * recreate it. */
static int reconcile_rectangle(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_round *mask) {
	/* A square rect under a rounded clip's corner is a raster too: a scene
	 * rect cannot follow the arc. */
	bool rounded = !corner_radius_zero(cmd->renderData.rectangle.cornerRadius) ||
		mask != NULL;
	if (n->node != NULL) {
		enum wlr_scene_node_type want = rounded ?
			WLR_SCENE_NODE_BUFFER : WLR_SCENE_NODE_RECT;
		if (n->node->type != want) {
			wlr_scene_node_destroy(n->node);
			n->node = NULL;
			rs->raster_bytes -= n->raster_bytes;
			n->raster_bytes = 0;
			rs->node_recreated = true;
		}
	}
	return rounded ? reconcile_rounded_rect(rs, n, cmd, rbox, mask)
		: reconcile_square_rect(rs, n, cmd, rbox);
}

/* --- borders: four straight edge rects, plus corner arc tiles when rounded ---
 *
 * One path serves square and rounded borders. The four edges are scene
 * rects inset from the box corners by the corner radius; each rounded corner is
 * a small cairo tile (radius-sized) drawing just its arc of the ring. A square
 * border (radius 0) insets by nothing and shows no tiles, degenerating exactly
 * to the old four-rect border. So the full-box ring buffer is gone: a border now
 * costs four rects plus up to four tiles the size of the radius, not a buffer the
 * size of the client. The tree sits at the solved box origin; borders are not
 * clip targets (the reconcile loop leaves rbox = box), so each edge is clipped
 * in absolute space and mapped back, a corner disabled when fully clipped. */

/* The square each rounded corner occupies in the ring, indexed TL, TR, BL, BR,
 * and 0 for a square corner.
 *
 * It must cover the arc (ceil of the radius) AND the full thickness of both
 * edges meeting there, because the two straight edges are inset by exactly this
 * and nothing else draws what neither covers. Sizing the tile to the radius
 * alone, and insetting the edges by the radius on one axis and the border width
 * on the other, leaves the band between the two undrawn at every corner where
 * 0 < radius < width: for a 100x100 border of width 5 and radius 3, nothing at
 * all draws x in [0,3), y in [3,5). A square corner needs no tile, and gets no
 * inset here: its horizontal edge runs the full width and its vertical edge
 * starts below, which is the plain four-rect border. */
static void border_corner_extents(Clay_RenderCommand *cmd, int ext[4]) {
	Clay_BorderWidth bw = cmd->renderData.border.width;
	Clay_CornerRadius cr = cmd->renderData.border.cornerRadius;
	int r[4] = { (int)ceilf(cr.topLeft), (int)ceilf(cr.topRight),
		(int)ceilf(cr.bottomLeft), (int)ceilf(cr.bottomRight) };
	/* The two edges meeting at each corner. */
	int adj[4][2] = { { bw.top, bw.left }, { bw.top, bw.right },
		{ bw.bottom, bw.left }, { bw.bottom, bw.right } };
	for (int c = 0; c < 4; c++) {
		int e = r[c];
		if (e < 1) {
			ext[c] = 0;
			continue;
		}
		if (adj[c][0] > e) e = adj[c][0];
		if (adj[c][1] > e) e = adj[c][1];
		ext[c] = e;
	}
}

/* The four straight edges, inset from each corner by that corner's extent, so
 * edges and corner tiles partition the ring with no gap and no double-draw (a
 * translucent border color makes an overlap as visible as a hole). A square
 * corner has no tile, so only its vertical edge is inset, by the horizontal
 * edge's width. */
static void border_edge_boxes(Clay_RenderCommand *cmd, const int ext[4],
		const Clay_BoundingBox *clip, int boxes[4][4]) {
	int w = (int)cmd->boundingBox.width;
	int h = (int)cmd->boundingBox.height;
	Clay_BorderWidth bw = cmd->renderData.border.width;
	int vtl = ext[0] > 0 ? ext[0] : bw.top;
	int vtr = ext[1] > 0 ? ext[1] : bw.top;
	int vbl = ext[2] > 0 ? ext[2] : bw.bottom;
	int vbr = ext[3] > 0 ? ext[3] : bw.bottom;
	/* top, right, bottom, left: {x, y, width, height}. */
	int sides[4][4] = {
		{ ext[0], 0, w - ext[0] - ext[1], bw.top },
		{ w - bw.right, vtr, bw.right, h - vtr - vbr },
		{ ext[2], h - bw.bottom, w - ext[2] - ext[3], bw.bottom },
		{ 0, vtl, bw.left, h - vtl - vbl },
	};
	/* Clay can solve an element smaller than its borders/radii; never negative. */
	for (int i = 0; i < 4; i++) {
		if (sides[i][2] < 0) sides[i][2] = 0;
		if (sides[i][3] < 0) sides[i][3] = 0;
	}
	if (clip != NULL) {
		int ox = (int)cmd->boundingBox.x, oy = (int)cmd->boundingBox.y;
		for (int i = 0; i < 4; i++) {
			Clay_BoundingBox abs = { (float)(ox + sides[i][0]),
				(float)(oy + sides[i][1]),
				(float)sides[i][2], (float)sides[i][3] };
			Clay_BoundingBox c = box_intersect(abs, *clip);
			sides[i][0] = (int)c.x - ox;
			sides[i][1] = (int)c.y - oy;
			sides[i][2] = (int)c.width;
			sides[i][3] = (int)c.height;
		}
	}
	memcpy(boxes, sides, sizeof(sides));
}

/* The ring's inner hole radii: each corner radius shrunk by the thicker of the
 * two edges meeting there. The hit test and the raster must agree on this to
 * the pixel, or a click lands somewhere the drawn ring does not cover. */
static Clay_CornerRadius inset_corner_radius(Clay_CornerRadius r,
		Clay_BorderWidth bw) {
	return (Clay_CornerRadius){
		fmax(0.0f, r.topLeft - fmaxf(bw.top, bw.left)),
		fmax(0.0f, r.topRight - fmaxf(bw.top, bw.right)),
		fmax(0.0f, r.bottomLeft - fmaxf(bw.bottom, bw.left)),
		fmax(0.0f, r.bottomRight - fmaxf(bw.bottom, bw.right)),
	};
}

/* Whether a box-relative point lies on a border's ring: inside the outer
 * rounded rect and outside the inner inset one, the shape the edge rects
 * and corner tiles fill. A click in the hole, or outside the arc of a
 * corner tile, falls through to the surface below, as Clay ranks it. The
 * test is geometric, in logical space; device scale never reaches it. */
static bool border_point_in_ring(struct rnode *n, double bx, double by) {
	Clay_BorderRenderData *bd = &n->data.border;
	double w = n->box.width, h = n->box.height;
	if (!point_in_rounded_rect(bx, by, 0, 0, w, h, bd->cornerRadius)) {
		return false;
	}
	Clay_BorderWidth bw = bd->width;
	double iw = w - bw.left - bw.right, ih = h - bw.top - bw.bottom;
	if (iw <= 0 || ih <= 0) {
		return true;   /* borders meet or overlap: the whole box is ring. */
	}
	/* The inner hole; a point inside it falls through. */
	Clay_CornerRadius ir = inset_corner_radius(bd->cornerRadius, bw);
	return !point_in_rounded_rect(bx, by, bw.left, bw.top, iw, ih, ir);
}

/* One corner of the ring, into a small device buffer (radius-sized). The full
 * ring path is drawn translated so this corner lands at the tile origin; the
 * tile only rasterizes its own arc. corner: 0=TL, 1=TR, 2=BL, 3=BR. NULL for a
 * square (radius 0) corner, where the straight edges meet with nothing to draw. */
static struct cairo_buffer *rasterize_border_corner(Clay_RenderCommand *cmd,
		const int ext[4], float scale, int corner) {
	Clay_BorderRenderData *bd = &cmd->renderData.border;
	Clay_CornerRadius cc = bd->cornerRadius;
	int r = ext[corner];
	int tile = device_len(0, r, scale);
	if (r < 1 || tile < 1) {
		return NULL;
	}
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1) {
		return NULL;
	}
	struct cairo_buffer *cb = cairo_buffer_create(tile, tile);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	/* Land this corner of the ring at the tile origin (right/bottom corners are
	 * pulled back by the full box minus the tile). */
	double tx = (corner == 1 || corner == 3) ? (double)(w - tile) : 0.0;
	double ty = (corner == 2 || corner == 3) ? (double)(h - tile) : 0.0;
	cairo_translate(cr, -tx, -ty);
	Clay_BorderWidth bw = bd->width;
	double sl = bw.left * scale, sr = bw.right * scale;
	double st = bw.top * scale, sb = bw.bottom * scale;
	cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
	rounded_rect_path(cr, 0, 0, w, h, scale_corner_radius(cc, scale));
	double iw = (double)w - sl - sr, ih = (double)h - st - sb;
	if (iw > 0 && ih > 0) {
		Clay_CornerRadius ir = inset_corner_radius(cc, bw);
		rounded_rect_path(cr, sl, st, iw, ih, scale_corner_radius(ir, scale));
	}
	/* Straight alpha as in rasterize_text; cairo premultiplies into ARGB32. */
	cairo_set_source_rgba(cr, clay_srgb(bd->color.r), clay_srgb(bd->color.g),
		clay_srgb(bd->color.b), clay_srgb(bd->color.a));
	cairo_fill(cr);
	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

/* A border, square or rounded, is a tree of four edge rects plus up to four
 * corner arc tiles. Edges carry box moves, resizes, and clip; corner tiles carry
 * the arc, re-rastered whenever the border data, scale, or box size changes
 * (the ring path clamps radii against the box, so the arc must always be
 * derived from the same box the edges were inset by). */
static int reconcile_border(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, const Clay_BoundingBox *clip) {
	Clay_BorderRenderData *bd = &cmd->renderData.border;
	float color[4];
	clay_color_to_float(bd->color, color);
	float opacity = render_userdata_opacity(cmd->userData);
	for (int i = 0; i < 4; i++)
		color[i] *= opacity;
	int ext[4];
	border_corner_extents(cmd, ext);
	int edges[4][4];
	border_edge_boxes(cmd, ext, clip, edges);
	int w = (int)cmd->boundingBox.width, h = (int)cmd->boundingBox.height;
	/* Box-relative corner origins (TL, TR, BL, BR). */
	int cpos[4][2] = { { 0, 0 }, { w - ext[1], 0 },
		{ 0, h - ext[2] }, { w - ext[3], h - ext[3] } };
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_tree *tree = wlr_scene_tree_create(rs->tree);
		n->node = &tree->node;
		/* Populate a new border before exposing it to scene damage tracking. */
		wlr_scene_node_set_enabled(n->node, false);
		wlr_scene_node_set_position(n->node,
			(int)cmd->boundingBox.x, (int)cmd->boundingBox.y);
	}

	/* Corner arcs: keyed on border data, scale, AND box size. The ring path
	 * clamps radii against the solved box, so a tile rastered against a small
	 * or degenerate box goes stale when the box grows. */
	bool corner_changed = is_new ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		memcmp(&n->data.border, bd, sizeof(*bd)) != 0;
	if (corner_changed) {
		size_t bytes = 0;
		for (int c = 0; c < 4; c++) {
			struct cairo_buffer *cb =
				rasterize_border_corner(cmd, ext, rs->scale, c);
			if (cb != NULL && n->border_corners[c] == NULL) {
				n->border_corners[c] = wlr_scene_buffer_create(
					wlr_scene_tree_from_node(n->node), NULL);
				wlr_scene_buffer_set_opacity(n->border_corners[c], opacity);
			}
			if (n->border_corners[c] != NULL)
				raster_set_buffer(n->border_corners[c], cb);
			n->border_tile[c] = cb != NULL;
			if (cb != NULL) {
				bytes += cairo_buffer_bytes(cb);
				rs->buffers_created++;
				wlr_buffer_drop(&cb->base);
			}
		}
		rs->raster_bytes = rs->raster_bytes - n->raster_bytes + bytes;
		n->raster_bytes = bytes;
		n->raster_scale = rs->scale;
		muts++;
	}

	/* Edges: diff realized boxes (box move, resize, width, clip) and recolor. */
	bool color_changed = !is_new && (memcmp(&n->data.border.color, &bd->color,
		sizeof(bd->color)) != 0 || opacity != n->opacity);
	for (int i = 0; i < 4; i++) {
		/* The rect itself is the record of its last realized box, so there is
		 * no shadow copy to keep in step with what was written. */
		struct wlr_scene_rect *side = n->border_sides[i];
		if (side == NULL) {
			if (edges[i][2] == 0 || edges[i][3] == 0) continue;
			side = wlr_scene_rect_create(wlr_scene_tree_from_node(n->node),
				edges[i][2], edges[i][3], color);
			n->border_sides[i] = side;
			muts++;
        }
		if (side->node.x != edges[i][0] || side->node.y != edges[i][1] ||
				side->width != edges[i][2] || side->height != edges[i][3]) {
			wlr_scene_rect_set_size(side, edges[i][2], edges[i][3]);
			wlr_scene_node_set_position(&side->node, edges[i][0], edges[i][1]);
			muts++;
		}
		if (color_changed) {
			wlr_scene_rect_set_color(side, color);
			muts++;
		}
	}

	/* Corner tiles: place at the box-relative corner, size to the logical corner
	 * extent (the buffer is device-sized), and show only where an extent and its
	 * raster exist and the corner is not fully clipped out. */
	for (int c = 0; c < 4; c++) {
		struct wlr_scene_buffer *sb = n->border_corners[c];
		if (sb == NULL) continue;
		if (opacity != n->opacity) {
			wlr_scene_buffer_set_opacity(sb, opacity);
			if (!is_new)
				muts++;
		}
		bool show = ext[c] >= 1 && n->border_tile[c];
		if (show && clip != NULL) {
			Clay_BoundingBox cb = { cmd->boundingBox.x + cpos[c][0],
				cmd->boundingBox.y + cpos[c][1],
				(float)ext[c], (float)ext[c] };
			show = !box_empty(box_intersect(cb, *clip));
		}
		if (show) {
			wlr_scene_node_set_position(&sb->node, cpos[c][0], cpos[c][1]);
			wlr_scene_buffer_set_dest_size(sb, ext[c], ext[c]);
		}
		if (sb->node.enabled != show) {
			wlr_scene_node_set_enabled(&sb->node, show);
			if (!is_new) {
				muts++;
			}
		}
	}
	n->opacity = opacity;
	return muts;
}

/* --- text --- */

/* Pango's bound is relative to the original run, even when its left side is
 * cropped. Read the effective clip itself: intersecting it with the run and
 * then reconstructing its right edge can lose enough precision to turn a
 * fully contained run into an ellipsis. Quantize only at the device-pixel
 * boundary, without first discarding fractional logical widths. */
static int text_ellipsis_width(Clay_RenderCommand *cmd,
		const Clay_BoundingBox *clip, float scale) {
	if (clip == NULL ||
			((uintptr_t)cmd->userData & RENDER_TEXT_ELLIPSIZE) == 0) {
		return 0;
	}
	double avail = (double)clip->x + clip->width - cmd->boundingBox.x;
	int natural = (int)round((double)cmd->boundingBox.width * scale);
	int bound = (int)round(fmax(0, fmin(avail,
		cmd->boundingBox.width)) * scale);
	return bound > 0 && bound < natural ? bound : 0;
}

static struct cairo_buffer *rasterize_text(Clay_RenderCommand *cmd, float scale,
		int max_width, const struct clip_round *mask) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int width = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int height = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (width < 1 || height < 1) {
		return NULL;
	}

	/* Keep the complete natural run in the source buffer. The integer scene
	 * extent can be smaller at fractional scales; buffer_apply_clip already
	 * maps the source raster to that retained destination and its genuine crop.
	 * This changes neither solved geometry nor lookup/input coordinates. */
	PangoContext *context = pango_font_map_create_context(
		pango_cairo_font_map_get_default());
	PangoLayout *layout = pango_layout_new(context);
	g_object_unref(context);
	render_set_text(layout, td->stringContents.chars,
		td->stringContents.length, td->fontId, td->fontSize, scale, 0);
	int natural_width, natural_height;
	pango_layout_get_pixel_size(layout, &natural_width, &natural_height);
	width = width > natural_width ? width : natural_width;
	height = height > natural_height ? height : natural_height;
	if (max_width > 0) {
		pango_layout_set_width(layout, max_width * PANGO_SCALE);
		pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
	}
	struct cairo_buffer *cb = cairo_buffer_create(width, height);
	if (cb == NULL) {
		g_object_unref(layout);
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_round(cr, cmd->boundingBox, mask, scale);
	/* Cairo takes straight alpha here, so no premultiply. */
	cairo_set_source_rgba(cr,
		clay_srgb(td->textColor.r), clay_srgb(td->textColor.g),
		clay_srgb(td->textColor.b), clay_srgb(td->textColor.a));

	/* Device-sized glyphs, as measured by render_measure_text; no CTM scaling. */
	pango_cairo_update_layout(cr, layout);
	pango_cairo_show_layout(cr, layout);

	g_object_unref(layout);
	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

static bool text_data_equal(Clay_TextRenderData *a, Clay_TextRenderData *b) {
	return memcmp(&a->textColor, &b->textColor, sizeof(a->textColor)) == 0 &&
		a->fontId == b->fontId && a->fontSize == b->fontSize &&
		a->letterSpacing == b->letterSpacing && a->lineHeight == b->lineHeight;
}

static int reconcile_text(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const Clay_BoundingBox *clip, const struct clip_round *mask) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int muts = 0;

	/* Length first, and the compare only for a non-empty run: an empty one
	 * leaves n->text NULL, and memcmp(NULL, ..., 0) is undefined even though it
	 * reads nothing (UBSan flags it). */
	bool content_changed = n->text_len != td->stringContents.length ||
		(td->stringContents.length > 0 &&
			memcmp(n->text, td->stringContents.chars,
				td->stringContents.length) != 0);

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
		content_changed = true;
	}

	/* The buffer is always rasterized at the full solved box; clipping is a
	 * crop of that buffer, never a re-raster. Re-raster on content, solved
	 * size, or style change.
	 *
	 * A truncated run is the one thing here that a crop cannot express, so its
	 * bound joins the raster keys. Without it, narrowing a clip over a run whose
	 * own box never moved would keep the buffer truncated at the old width and
	 * crop the mark itself in half. */
	int ell = text_ellipsis_width(cmd, clip, rs->scale);
	bool raster_changed = content_changed ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		n->text_ellipsis != ell ||
		!text_data_equal(&n->data.text, td) ||
		clip_round_changed(&n->mask, mask);
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_text(cmd, rs->scale, ell, mask));
		n->raster_scale = rs->scale;
		n->text_ellipsis = ell;
		clip_round_keep(&n->mask, mask);
		muts++;
	}

	float opacity = render_userdata_opacity(cmd->userData);
	if (opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}

	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);

	if (content_changed) {
		free(n->text);
		n->text = malloc(td->stringContents.length);
		memcpy(n->text, td->stringContents.chars, td->stringContents.length);
		n->text_len = td->stringContents.length;
	}
	return muts;
}

/* --- images ---
 *
 * An image entry (render_image.h) holds one native cairo surface. The image
 * rasters per node into a box-sized buffer: cairo scales the native into the
 * solved box and rounds the corners if asked. This mirrors reconcile_text
 * (raster on change, then crop to the clip), so an image clips inside a scroll
 * container for free.
 *
 * The colour an image command carries is a STENCIL here: the ink replaces the
 * decoded pixels and only their alpha survives. Clay carries the colour and
 * leaves the interpretation to the renderer, so this is a choice, and the
 * reason for it is that the case worth having is inking a glyph whose own
 * colour is arbitrary. Scaling each channel by the ink instead would preserve
 * the file's shading but could only ever darken, which cannot ink a dark glyph
 * at all. A zero-alpha ink never arrives: the solver stores no colour for it. */

static struct cairo_buffer *rasterize_image(Clay_RenderCommand *cmd,
		struct image_entry *entry, float scale, const struct clip_round *mask) {
	int w = entry->stretch ? (int)ceilf(entry->width * scale)
		: device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = entry->stretch ? (int)ceilf(entry->height * scale)
		: device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1 || entry->width < 1 || entry->height < 1) {
		return NULL;
	}
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_round(cr, cmd->boundingBox, mask, scale);

	/* w and h are device pixels. Natural images scale only by the output
	 * scale; other images scale to fill the box. The corner radii scale
	 * to device pixels in both cases. */
	Clay_CornerRadius radius = scale_corner_radius(
		cmd->renderData.image.cornerRadius, scale);
	if (!corner_radius_zero(radius)) {
		rounded_rect_path(cr, 0, 0, w, h, radius);
		cairo_clip(cr);
	}
	if (entry->natural || entry->stretch)
		cairo_scale(cr, scale, scale);
	else
		cairo_scale(cr, (double)w / entry->width, (double)h / entry->height);
	cairo_pattern_t *pattern = cairo_pattern_create_for_surface(entry->native);
	/* Pattern matrices map into source coordinates: this places the source
	 * at -src_x,-src_y in logical pixels, before the output scale. */
	cairo_matrix_t matrix;
	cairo_matrix_init_translate(&matrix, entry->src_x, entry->src_y);
	cairo_pattern_set_matrix(pattern, &matrix);
	if (entry->filter > 0)
		cairo_pattern_set_filter(pattern, entry->filter - 1);
	Clay_Color ink = cmd->renderData.image.backgroundColor;
	if (ink.a > 0) {
		cairo_set_source_rgba(cr, clay_srgb(ink.r), clay_srgb(ink.g),
			clay_srgb(ink.b), clay_srgb(ink.a));
		cairo_mask(cr, pattern);
	} else {
		cairo_set_source(cr, pattern);
		cairo_paint(cr);
	}
	cairo_pattern_destroy(pattern);

	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

/* Whether a node-local point is inside the arcs a node draws within: its
 * own corner radius for a rounded rect, and the rounded clip a raster was
 * cut to at a corner. The pixels outside are transparent, and a shaped
 * wibox's mask took no input there either. sx, sy are relative to the scene
 * node, which sits at rbox. */
static bool rnode_point_in_arcs(struct rnode *n, double sx, double sy) {
	double px = sx + (n->rbox.x - n->box.x);
	double py = sy + (n->rbox.y - n->box.y);
	if (n->mask.radius > 0) {
		Clay_CornerRadius r = { n->mask.radius, n->mask.radius,
			n->mask.radius, n->mask.radius };
		if (!point_in_rounded_rect(n->box.x + px, n->box.y + py,
				n->mask.box.x, n->mask.box.y,
				n->mask.box.width, n->mask.box.height, r)) {
			return false;
		}
	}
	if ((uint32_t)(n->key >> 32) == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
		return point_in_rounded_rect(px, py, 0, 0, n->box.width,
			n->box.height, n->data.rectangle.cornerRadius);
	}
	return true;
}

static bool image_data_equal(Clay_ImageRenderData *a, Clay_ImageRenderData *b) {
	return memcmp(&a->backgroundColor, &b->backgroundColor,
			sizeof(a->backgroundColor)) == 0 &&
		memcmp(&a->cornerRadius, &b->cornerRadius,
			sizeof(a->cornerRadius)) == 0;
}

static int reconcile_image(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_round *mask) {
	struct image_entry *entry =
		(struct image_entry *)cmd->renderData.image.imageData;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

	/* An entry with no surface shows nothing. */
	bool usable = entry != NULL && entry->native != NULL;
	bool raster_changed = is_new ||
		((!entry || !entry->stretch)
			&& !raster_size_equal(n->box, cmd->boundingBox, rs->scale)) ||
		n->raster_scale != rs->scale ||
		!image_data_equal(&n->data.image, &cmd->renderData.image) ||
		(usable ? entry->native : NULL) != n->img_native ||
		(usable && (entry->gen != n->img_gen
			|| entry->src_x != n->img_src_x || entry->src_y != n->img_src_y
			|| entry->width != n->img_width || entry->height != n->img_height
			|| entry->filter != n->img_filter || entry->stretch != n->img_stretch
			|| entry->natural != n->img_natural)) ||
		clip_round_changed(&n->mask, mask);

	if (raster_changed) {
		rnode_set_raster(rs, n, sb,
			usable ? rasterize_image(cmd, entry, rs->scale, mask) : NULL);
		/* Hold the surface so its address cannot be reused while cached.
		 * This makes pointer identity lifetime-safe without an ID counter. */
		cairo_surface_t *native = usable ? cairo_surface_reference(entry->native) : NULL;
		if (n->img_native)
			cairo_surface_destroy(n->img_native);
		n->img_native = native;
		n->img_gen = usable ? entry->gen : 0;
		n->img_src_x = usable ? entry->src_x : 0;
		n->img_src_y = usable ? entry->src_y : 0;
		n->img_width = usable ? entry->width : 0;
		n->img_height = usable ? entry->height : 0;
		n->img_filter = usable ? entry->filter : 0;
		n->img_stretch = usable && entry->stretch;
		n->img_natural = usable && entry->natural;
		n->raster_scale = rs->scale;
		clip_round_keep(&n->mask, mask);
		muts++;
	}

	float opacity = render_userdata_opacity(cmd->userData);
	if (opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new) {
			muts++;
		}
	}

	/* Crop to the clip, exactly as reconcile_text does (buffer is ceil(box)
	 * sized, so the source box is in box pixels). */
	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	return muts;
}

/* The same retained path drives painting and input, in logical pixels. */
static void shape_path(cairo_t *cr, const float *ops, size_t len) {
	for (size_t i = 0; i < len; ) {
		float op = ops[i++];
		size_t count = op == 0 || op == 1 ? 2 : op == 2 ? 6 : 0;
		if ((op != 0 && op != 1 && op != 2 && op != 3) || count > len - i) {
			cairo_new_path(cr);
			return;
		}
		const float *p = ops + i;
		if (op == 0)
			cairo_move_to(cr, p[0], p[1]);
		else if (op == 1)
			cairo_line_to(cr, p[0], p[1]);
		else if (op == 2)
			cairo_curve_to(cr, p[0], p[1], p[2], p[3], p[4], p[5]);
		else
			cairo_close_path(cr);
		i += count;
	}
}

/* Whether a node-local point is inside a shape leaf's path: its fill, or
 * its stroke when it has no fill. */
static bool shape_point_in_path(struct rnode *n, double sx, double sy) {
	static cairo_t *cr;
	if (cr == NULL) {
		cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
		cr = cairo_create(surface);
		cairo_surface_destroy(surface);
	}
	shape_path(cr, n->shape_ops, n->shape_ops_len);
	double x = sx + n->rbox.x - n->box.x;
	double y = sy + n->rbox.y - n->box.y;
	bool hit = false;
	if (n->shape.fill[3] > 0)
		hit = cairo_in_fill(cr, x, y);
	else if (n->shape.stroke[3] > 0 && n->shape.stroke_width > 0) {
		cairo_set_line_width(cr, n->shape.stroke_width);
		hit = cairo_in_stroke(cr, x, y);
	}
	cairo_new_path(cr);
	return hit;
}

static struct cairo_buffer *rasterize_shape(Clay_RenderCommand *cmd,
		const struct render_shape *shape, const float *ops, size_t len,
		float scale, const struct clip_round *mask) {
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (len == 0 || w < 1 || h < 1)
		return NULL;
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL)
		return NULL;
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_round(cr, cmd->boundingBox, mask, scale);
	cairo_scale(cr, scale, scale);
	shape_path(cr, ops, len);
	if (shape->gradient.kind) {
		const struct render_gradient *g = &shape->gradient;
		const float *p = g->points;
		cairo_pattern_t *pattern = g->kind == 1
			? cairo_pattern_create_linear(p[0], p[1], p[2], p[3])
			: cairo_pattern_create_radial(p[0], p[1], p[2], p[3], p[4], p[5]);
		for (int i = 0; i < g->count; i++) {
			const float *c = g->stops[i];
			cairo_pattern_add_color_stop_rgba(pattern, c[0], c[1], c[2], c[3], c[4]);
		}
		cairo_set_source(cr, pattern);
		cairo_fill_preserve(cr);
		cairo_pattern_destroy(pattern);
	} else if (shape->fill[3] > 0) {
		const float *c = shape->fill;
		cairo_set_source_rgba(cr, c[0], c[1], c[2], c[3]);
		cairo_fill_preserve(cr);
	}
	if (shape->stroke[3] > 0 && shape->stroke_width > 0) {
		const float *c = shape->stroke;
		cairo_set_source_rgba(cr, c[0], c[1], c[2], c[3]);
		cairo_set_line_width(cr, shape->stroke_width);
		cairo_stroke(cr);
	} else {
		cairo_new_path(cr);
	}
	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}



/**
 * Smoothstep falloff for shadow gradient.
 * Returns 1.0 at the shadow boundary (t=0) and 0.0 at the outer edge (t=1).
 */
static inline float
shadow_falloff(float t)
{
    if (t >= 1.0f) return 0.0f;
    if (t <= 0.0f) return 1.0f;
    float s = 1.0f - t;
    return s * s * (3.0f - 2.0f * s);
}

/**
 * Alpha for a point at signed distance sdf (pixels, positive = outside)
 * from the shadow rectangle's boundary. radius > 0 fades over that
 * distance; radius == 0 keeps a hard edge with 1px of anti-aliasing.
 */
static inline float
shadow_alpha_at(float sdf, int radius)
{
    if (radius > 0)
        return shadow_falloff(sdf / (float)radius);
    if (sdf <= -0.5f) return 1.0f;
    if (sdf >= 0.5f) return 0.0f;
    return 0.5f - sdf;
}

/**
 * Compute a premultiplied ARGB8888 pixel for the shadow color at the
 * given alpha.
 */
static inline uint32_t
shadow_pixel(const float color[4], float alpha)
{
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 1.0f) alpha = 1.0f;
    uint8_t a = (uint8_t)(alpha * 255.0f + 0.5f);
    uint8_t r = (uint8_t)(color[0] * alpha * 255.0f + 0.5f);
    uint8_t g = (uint8_t)(color[1] * alpha * 255.0f + 0.5f);
    uint8_t b = (uint8_t)(color[2] * alpha * 255.0f + 0.5f);
    return ((uint32_t)a << 24) | ((uint32_t)r << 16) |
           ((uint32_t)g << 8) | (uint32_t)b;
}

/**
 * Render one corner patch of the shadow rectangle.
 *
 * The patch is a (radius + corner_radius) square covering the corner arc:
 * falloff outside the rounded boundary, solid inside it. The math is done
 * in top-left orientation and mirrored for the other corners.
 *
 * @param corner Corner index (0=TL, 1=TR, 2=BL, 3=BR)
 * @param radius Falloff distance
 * @param corner_radius Rounded corner radius of the shadow rect
 * @param color RGBA color
 * @param paint Peak alpha (opacity * color alpha)
 * @return cairo surface or NULL on failure
 */
static cairo_surface_t *
shadow_render_corner(int corner, int radius, int corner_radius,
                     const float color[4], float paint)
{
    int side = radius + corner_radius;
    if (side <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface) / 4;

    bool mirror_x = (corner == 1 || corner == 3);
    bool mirror_y = (corner == 2 || corner == 3);

    /* In TL orientation the arc center sits at local (side, side): the
     * patch spans [-radius, corner_radius) from the rect corner, and the
     * center is corner_radius inside it. */
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            float lx = (mirror_x ? side - 1 - x : x) + 0.5f;
            float ly = (mirror_y ? side - 1 - y : y) + 0.5f;
            float dx = lx - (float)side;
            float dy = ly - (float)side;
            float sdf = sqrtf(dx * dx + dy * dy) - (float)corner_radius;
            pixels[y * stride + x] =
                shadow_pixel(color, shadow_alpha_at(sdf, radius) * paint);
        }
    }

    cairo_surface_mark_dirty(surface);
    return surface;
}

/**
 * Render the horizontal edge texture (1 pixel wide, radius tall).
 * Alpha fades upward for the top edge and downward for the bottom edge.
 */
static cairo_surface_t *
shadow_render_edge_h(int radius, const float color[4], float paint, bool top)
{
    if (radius <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, radius);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface) / 4;

    for (int y = 0; y < radius; y++)
        pixels[y * stride] = shadow_pixel(color,
            shadow_alpha_at((float)(top ? radius - 1 - y : y) + 0.5f, radius) * paint);

    cairo_surface_mark_dirty(surface);
    return surface;
}

/**
 * Render the vertical edge texture (radius wide, 1 pixel tall).
 * Alpha fades leftward for the left edge and rightward for the right edge.
 */
static cairo_surface_t *
shadow_render_edge_v(int radius, const float color[4], float paint, bool left)
{
    if (radius <= 0)
        return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, radius, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);

    for (int x = 0; x < radius; x++)
        pixels[x] = shadow_pixel(color,
            shadow_alpha_at((float)(left ? radius - 1 - x : x) + 0.5f, radius) * paint);

    cairo_surface_mark_dirty(surface);
    return surface;
}

/* Shared device-density nine-patch textures. Size and position are deliberately
 * absent from the key: a 4K window uses the same tiles as a small popup. */
static void shadow_cache_release(struct render_state *rs, struct shadow_cache *cache)
{
	if (!cache || --cache->refs)
		return;
	struct shadow_cache **link = &rs->shadows;
	while (*link != cache)
		link = &(*link)->next;
	*link = cache->next;
	for (int i = 0; i < SHADOW_SLICE_COUNT; i++)
		if (cache->tiles[i])
			wlr_buffer_drop(&cache->tiles[i]->base);
	rs->raster_bytes -= cache->bytes;
	free(cache);
}

static struct shadow_cache *shadow_cache_get(struct render_state *rs,
		const struct render_shadow *style)
{
	for (struct shadow_cache *c = rs->shadows; c; c = c->next) {
		if (c->scale == rs->scale && c->style.radius == style->radius
				&& c->style.corner_radius == style->corner_radius
				&& !memcmp(c->style.rgba, style->rgba, sizeof(style->rgba))) {
			c->refs++;
			return c;
		}
	}
	struct shadow_cache *c = calloc(1, sizeof(*c));
	c->style = *style;
	c->scale = rs->scale;
	c->refs = 1;
	int r = (int)ceilf(style->radius * rs->scale);
	int cr = (int)ceilf(style->corner_radius * rs->scale);
	for (int i = 0; i < SHADOW_SLICE_COUNT; i++) {
		cairo_surface_t *surface = i < SHADOW_EDGE_TOP
			? shadow_render_corner(i, r, cr, style->rgba, style->rgba[3])
			: i < SHADOW_EDGE_LEFT
			? shadow_render_edge_h(r, style->rgba, style->rgba[3], i == SHADOW_EDGE_TOP)
			: shadow_render_edge_v(r, style->rgba, style->rgba[3], i == SHADOW_EDGE_LEFT);
		if (!surface)
			continue;
		struct cairo_buffer *cb = calloc(1, sizeof(*cb));
		cb->surface = surface;
		wlr_buffer_init(&cb->base, &cairo_buffer_impl,
			cairo_image_surface_get_width(surface), cairo_image_surface_get_height(surface));
		c->tiles[i] = cb;
		c->bytes += cairo_buffer_bytes(cb);
		rs->buffers_created++;
	}
	c->next = rs->shadows;
	rs->shadows = c;
	rs->raster_bytes += c->bytes;
	return c;
}

/* The lower-band command may precede its owner during Clay positioning.
 * Its own box is not a placement input, even on the next unchanged frame. */
static Clay_BoundingBox shadow_owner_box(const struct render_shadow *style)
{
	Clay_BoundingBox box = style->owner_box;
	int expand = style->spread + style->radius;
	box.x += style->offset_x - expand;
	box.y += style->offset_y - expand;
	box.width += 2 * expand;
	box.height += 2 * expand;
	return box;
}

static int reconcile_shadow(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd)
{
	const struct render_shadow *style = render_shadow_of(cmd->renderData.custom.customData);
	bool fresh = n->node == NULL;
	bool changed = fresh || n->raster_scale != rs->scale
		|| n->shadow->style.radius != style->radius
		|| n->shadow->style.corner_radius != style->corner_radius
		|| memcmp(n->shadow->style.rgba, style->rgba, sizeof(style->rgba));
	int muts = 0;
	if (fresh) {
		struct wlr_scene_tree *tree = wlr_scene_tree_create(rs->tree);
		n->node = &tree->node;
		for (int i = 0; i < SHADOW_SLICE_COUNT; i++)
			n->shadow_tiles[i] = wlr_scene_buffer_create(tree, NULL);
		float clear[4] = {0};
		for (int i = 0; i < SHADOW_FILL_COUNT; i++)
			n->shadow_fills[i] = wlr_scene_rect_create(tree, 0, 0, clear);
	}
	if (changed) {
		struct shadow_cache *cache = shadow_cache_get(rs, style);
		for (int i = 0; i < SHADOW_SLICE_COUNT; i++)
			raster_set_buffer(n->shadow_tiles[i], cache->tiles[i]);
		shadow_cache_release(rs, n->shadow);
		n->shadow = cache;
		n->raster_bytes = cache->bytes; /* per-command footprint, shared in state total */
		n->raster_scale = rs->scale;
		float color[4] = {style->rgba[0] * style->rgba[3],
			style->rgba[1] * style->rgba[3], style->rgba[2] * style->rgba[3], style->rgba[3]};
		for (int i = 0; i < SHADOW_FILL_COUNT; i++)
			wlr_scene_rect_set_color(n->shadow_fills[i], color);
		muts++;
	}
	int r = style->radius, cr = style->corner_radius, cs = r + cr;
	int w = (int)cmd->boundingBox.width, h = (int)cmd->boundingBox.height;
	int mw = w - 2 * cs, mh = h - 2 * cs;
	/* Box origin is the top-left tile; the spread-grown solid box is inset
	 * by radius. Corner squares, edge strips and fills partition it once. */
	int boxes[SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT][4] = {
		{0, 0, cs, cs}, {w-cs, 0, cs, cs},
		{0, h-cs, cs, cs}, {w-cs, h-cs, cs, cs},
		{cs, 0, mw, r}, {cs, h-r, mw, r},
		{0, cs, r, mh}, {w-r, cs, r, mh},
		{cs, r, mw, h-2*r}, {r, cs, cr, mh}, {w-cs, cs, cr, mh},
	};
	bool fits = mw >= 0 && mh >= 0 && w > 2*r && h > 2*r;
	for (int i = 0; i < SHADOW_SLICE_COUNT + SHADOW_FILL_COUNT; i++) {
		int *b = boxes[i];
		bool tile = i < SHADOW_SLICE_COUNT;
		struct wlr_scene_node *node = tile ? &n->shadow_tiles[i]->node
			: &n->shadow_fills[i-SHADOW_SLICE_COUNT]->node;
		bool show = fits && b[2] > 0 && b[3] > 0 && (!tile || n->shadow->tiles[i]);
		if (node->enabled != show) {
			wlr_scene_node_set_enabled(node, show);
			muts++;
		}
		if (!show)
			continue;
		if (node->x != b[0] || node->y != b[1]) {
			wlr_scene_node_set_position(node, b[0], b[1]);
			muts++;
		}
		if (tile) {
			struct wlr_scene_buffer *sb = n->shadow_tiles[i];
			if (sb->dst_width != b[2] || sb->dst_height != b[3]) {
				wlr_scene_buffer_set_dest_size(sb, b[2], b[3]);
				muts++;
			}
		} else {
			struct wlr_scene_rect *rect = n->shadow_fills[i-SHADOW_SLICE_COUNT];
			if (rect->width != b[2] || rect->height != b[3]) {
				wlr_scene_rect_set_size(rect, b[2], b[3]);
				muts++;
			}
		}
	}
	return muts;
}

static int reconcile_shape(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_round *mask, const struct render_client_hooks *hooks) {
	static float ops[4096];
	struct render_shape *shape = render_shape_of(cmd->renderData.custom.customData);
	/* Lua may run in the hook: all raster inputs are copied before it. */
	struct render_shape value = *shape;
	int muts = 0;
	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);
	bool raster_changed = is_new ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		n->data.custom.customData != cmd->renderData.custom.customData ||
		n->shape.gen != value.gen ||
		memcmp(&n->shape.gradient, &value.gradient, sizeof(value.gradient)) != 0 ||
		memcmp(n->shape.fill, value.fill, sizeof(value.fill)) != 0 ||
		memcmp(n->shape.stroke, value.stroke, sizeof(value.stroke)) != 0 ||
		memcmp(&n->shape.stroke_width, &value.stroke_width, sizeof(value.stroke_width)) != 0 ||
		clip_round_changed(&n->mask, mask);
	if (raster_changed) {
		size_t cap = sizeof(ops) / sizeof(*ops);
		size_t len = hooks && hooks->shape_ops ? hooks->shape_ops(hooks->data,
			shape, cmd->boundingBox.width, cmd->boundingBox.height, ops, cap) : 0;
		if (len > cap) {
			if (!rs->shape_overflow_logged) {
				wlr_log(WLR_ERROR, "shape path exceeds %zu floats", cap);
				rs->shape_overflow_logged = true;
			}
			len = 0;
		}
		free(n->shape_ops);
		n->shape_ops = len ? malloc(len * sizeof(*ops)) : NULL;
		n->shape_ops_len = n->shape_ops ? len : 0;
		if (n->shape_ops)
			memcpy(n->shape_ops, ops, len * sizeof(*ops));
		n->shape = value;
		rnode_set_raster(rs, n, sb, rasterize_shape(cmd, &value,
			n->shape_ops, n->shape_ops_len, rs->scale, mask));
		n->raster_scale = rs->scale;
		clip_round_keep(&n->mask, mask);
		muts++;
	}
	float opacity = render_userdata_opacity(cmd->userData);
	if (opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}
	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	return muts;
}

/* --- client surfaces, borrowed through the hooks ---
 *
 * A scene tree has one parent, so a client can be borrowed by exactly one
 * output at a time. When a client migrates between outputs both may briefly
 * hold a retained record for it: the new output steals the tree by
 * reparenting, and the old output's next sweep would then reparent it home
 * and disable it, blanking a node the new owner shows. Ownership settles
 * that race: borrow records the reparenting render_state as owner, and a
 * release from any other render_state is a no-op. A single client is never
 * declared on two outputs in the same frame (a client belongs to one tag,
 * one screen), so simultaneous double-display cannot arise through policy;
 * if it ever did, the tree==scene verifier would abort on the position
 * mismatch, loudly. */

static struct wlr_box surface_clip_box(Clay_BoundingBox box, Clay_BoundingBox rbox) {
	if (box_pos_equal(box, rbox) && box_size_equal(box, rbox)) {
		return (struct wlr_box){0};
	}
	return (struct wlr_box){
		.x = (int)rbox.x - (int)box.x,
		.y = (int)rbox.y - (int)box.y,
		.width = (int)rbox.width,
		.height = (int)rbox.height,
	};
}

static int reconcile_surface(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct render_client_hooks *hooks) {
	uint64_t handle = (uint64_t)(uintptr_t)cmd->renderData.custom.customData;
	struct wlr_scene_tree *tree = hooks->resolve(hooks->data, handle);
	n->borrowed = true;
	n->handle = handle;

	if (tree == NULL) {
		/* The client died between the declare and this reconcile. Drop
		 * any stored pointer without touching it; the sweep or the next
		 * declare pass forgets the id. */
		n->node = NULL;
		return 0;
	}

	int muts = 0;
	float opacity = render_userdata_opacity(cmd->userData);
	bool first_borrow = n->node == NULL;
	if (first_borrow) {
		wlr_scene_node_reparent(&tree->node, rs->tree);
		wlr_scene_node_set_enabled(&tree->node, true);
		n->node = &tree->node;
		hooks->borrow(hooks->data, handle, rs);
		render_tree_set_opacity(n->node, opacity);
		n->opacity = opacity;
		muts++;
	} else if (n->node != &tree->node) {
		/* One handle, one scene tree, for the toplevel's whole life. */
		wlr_log(WLR_ERROR, "surface node for handle %" PRIu64
			" changed identity", handle);
		abort();
	}

	if (!box_size_equal(n->box, cmd->boundingBox)) {
		hooks->configure(hooks->data, handle,
			(int)cmd->boundingBox.width, (int)cmd->boundingBox.height);
		muts++;
	}
	struct wlr_box clip = surface_clip_box(cmd->boundingBox, rbox);
	struct wlr_box previous_clip = surface_clip_box(n->box, n->rbox);
	if (hooks->clip != NULL && (first_borrow || !wlr_box_equal(&clip, &previous_clip))) {
		hooks->clip(hooks->data, handle, clip.x, clip.y, clip.width, clip.height);
		muts++;
	}
	if (opacity != n->opacity) {
		render_tree_set_opacity(n->node, opacity);
		n->opacity = opacity;
		muts++;
	}
	return muts;
}

/* --- tree==scene: every solved box must match the scene, every frame --- */

/* Whether the scene disagrees with what the command solved: a node placed or
 * sized somewhere other than its realized box, one drawing outside its
 * innermost scissor scope, or one enabled when it clipped away (an empty rbox
 * is the only case where a declared node may be off). The verifier below
 * aborts on it; the tree dump prints it, so a release build without the
 * verifier still reports the divergence rather than drawing it silently. */
static bool rnode_scene_mismatch(const struct rnode *n) {
	if (n->node == NULL) {
		return false;
	}
	if (n->borrowed && (n->node->x != (int)n->box.x ||
			n->node->y != (int)n->box.y)) {
		return true;
	}
	if (box_empty(n->rbox)) {
		return n->node->enabled;
	}
	if (!n->node->enabled || !box_contains(n->clip, n->rbox)) {
		return true;
	}
	if (n->borrowed) {
		struct wlr_scene_node *node = n->node;
		int x = node->x, y = node->y;
		while (node->type == WLR_SCENE_NODE_TREE) {
			struct wlr_scene_tree *tree = wlr_scene_tree_from_node(node);
			struct wlr_scene_node *child, *next = NULL;
			wl_list_for_each(child, &tree->children, link) {
				if (child->type == WLR_SCENE_NODE_BUFFER) {
					return child->enabled && (x + child->x != (int)n->rbox.x ||
						y + child->y != (int)n->rbox.y);
				}
				if (next == NULL && child->type == WLR_SCENE_NODE_TREE) {
					next = child;
				}
			}
			if (next == NULL) {
				break;
			}
			node = next;
			x += node->x;
			y += node->y;
		}
		return false;
	}
	if (n->node->x != (int)n->rbox.x || n->node->y != (int)n->rbox.y) {
		return true;
	}
	if (n->node->type == WLR_SCENE_NODE_RECT) {
		struct wlr_scene_rect *rect = wlr_scene_rect_from_node(n->node);

		return rect->width != (int)n->rbox.width ||
			rect->height != (int)n->rbox.height;
	}
	/* A raster leaf's dest size is its logical footprint, always set to the
	 * realized box (buffer_apply_clip), so it is comparable too. A border's
	 * node is a tree and a place-leaf's is a borrowed client tree; neither
	 * carries a size of its own. */
	if (n->node->type == WLR_SCENE_NODE_BUFFER) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

		return sb->dst_width != (int)n->rbox.width ||
			sb->dst_height != (int)n->rbox.height;
	}
	return false;
}

#ifdef SOMEWM_RENDER_VERIFY

static void verify_node(struct rnode *n) {
	if (!rnode_scene_mismatch(n)) {
		return;
	}
	fprintf(stderr, "tree==scene: key %" PRIx64 " %s at %d,%d but "
		"realized box says %d,%d %dx%d inside clip %d,%d %dx%d\n",
		n->key, n->node->enabled ? "enabled" : "disabled",
		n->node->x, n->node->y,
		(int)n->rbox.x, (int)n->rbox.y,
		(int)n->rbox.width, (int)n->rbox.height,
		(int)n->clip.x, (int)n->clip.y,
		(int)n->clip.width, (int)n->clip.height);
	abort();
}

#endif /* SOMEWM_RENDER_VERIFY */

#ifdef SOMEWM_RENDER_VERIFY

/* Check 1 of the agreement invariant: scene sibling order equals retained
 * paint order. The restack raises each command's node to the top in order, so a
 * forward walk of the children list (bottom to top) must visit exactly the
 * nodes rs->order names, in the same sequence, skipping commands that realized
 * no node (SCISSOR markers, dead surfaces). A dropped raise reorders a sibling
 * and aborts here. Runs after the restack, when the map is valid. */
static void verify_order(struct render_state *rs) {
	struct wlr_scene_node *child;
	size_t oi = 0;
	wl_list_for_each(child, &rs->tree->children, link) {
		struct wlr_scene_node *expect = NULL;
		while (oi < rs->order_len) {
			size_t idx = rmap_get(rs, rs->order[oi]);
			oi++;
			if (idx != SIZE_MAX && rs->nodes[idx].node != NULL) {
				expect = rs->nodes[idx].node;
				break;
			}
		}
		if (child != expect) {
			fprintf(stderr, "tree==scene: sibling order diverges from "
				"command order\n");
			abort();
		}
	}
	/* Every command left over must be nodeless; one with a node means the
	 * scene is missing a child the command declared. */
	while (oi < rs->order_len) {
		size_t idx = rmap_get(rs, rs->order[oi]);
		oi++;
		if (idx != SIZE_MAX && rs->nodes[idx].node != NULL) {
			fprintf(stderr, "tree==scene: command %" PRIx64
				" has no scene child\n", rs->order[oi - 1]);
			abort();
		}
	}
}

#endif /* SOMEWM_RENDER_VERIFY */

/* --- the scene-node-to-Clay-id backmap --- */

void *render_hit_userdata(struct render_state *rs, struct wlr_scene_node *node) {
	struct rnode *n = rnode_for_scene_node(rs, node);
	return n != NULL ? n->user_data : NULL;
}

/* --- the reconcile pass --- */

/* The scope a command's word names (render.h), or NULL for none, for one no
 * rectangle opened this frame, or for the bounds. Scanned from the newest:
 * a tree's commands follow the rectangle that opened their scope. */
static const struct clip_scope *scope_named(struct render_state *rs,
		void *word, unsigned number) {
	uint64_t owner = (uintptr_t)word & RENDER_UD_OWNER_MASK;
	for (size_t i = rs->scopes_len; i > 0; i--) {
		const struct clip_scope *sc = &rs->scopes[i - 1];
		if (sc->number == number && sc->owner == owner) {
			return sc;
		}
	}
	return NULL;
}

/* Open the scope a command's word says it opens (render.h), if any: its
 * realized box, and its arc when rounded, else the arc it sits under. */
static void scope_open(struct render_state *rs, void *word, Clay_BoundingBox rbox,
		const struct clip_scope *under, float radius) {
	unsigned opens = render_userdata_byte(word, RENDER_UD_OPENS_SHIFT);
	if (opens == 0) {
		return;
	}
	struct clip_round inherited = under ? under->round : (struct clip_round){0};
	if (rs->scopes_len == rs->scopes_cap) {
		rs->scopes_cap = rs->scopes_cap ? rs->scopes_cap * 2 : 32;
		p_realloc(&rs->scopes, rs->scopes_cap);
	}
	struct clip_scope *sc = &rs->scopes[rs->scopes_len++];
	sc->owner = (uintptr_t)word & RENDER_UD_OWNER_MASK;
	sc->number = opens;
	sc->box = rbox;
	if (radius > 0) {
		sc->round.box = rbox;
		sc->round.radius = radius;
	} else {
		sc->round = inherited;
	}
}

/* Visibility changes can update output membership in other scene branches.
 * Do not batch across any observable buffer signal. Retired owned nodes also
 * need quiet destruction, including descendants currently disabled. */
static bool scene_visibility_quiet(struct wlr_scene_node *node,
        bool active_only, bool check_destroy) {
    if (active_only && !node->enabled)
        return true;
    if (check_destroy && !wl_list_empty(&node->events.destroy.listener_list))
        return false;
    if (node->type == WLR_SCENE_NODE_TREE) {
        struct wlr_scene_node *child;
        wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
            if (!scene_visibility_quiet(child, active_only, check_destroy))
                return false;
    } else if (node->type == WLR_SCENE_NODE_BUFFER) {
        struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
        if (!wl_list_empty(&sb->events.output_enter.listener_list) ||
                !wl_list_empty(&sb->events.output_leave.listener_list) ||
                !wl_list_empty(&sb->events.outputs_update.listener_list) ||
                !wl_list_empty(&sb->events.output_sample.listener_list) ||
                !wl_list_empty(&sb->events.frame_done.listener_list))
            return false;
    }
    return true;
}

static bool batch_command_type(uint32_t type) {
    return type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE ||
        type == CLAY_RENDER_COMMAND_TYPE_BORDER ||
        type == CLAY_RENDER_COMMAND_TYPE_TEXT ||
        type == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START ||
        type == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END;
}

/* Reuse the current command map to detect additions/removals before mutating
 * the scene. Callback-bearing commands and borrowed trees keep their ordinary
 * lifecycle; unchanged membership never causes an ancestor visibility toggle. */
static bool can_batch_visibility(struct render_state *rs,
        Clay_RenderCommandArray commands) {
    if (!rs->tree->node.enabled)
        return false;
    bool border = false, changed = (size_t)commands.length != rs->len;
    for (size_t i = 0; i < rs->len; i++) {
        uint32_t type = (uint32_t)(rs->nodes[i].key >> 32);
        if (!batch_command_type(type) || rs->nodes[i].borrowed)
            return false;
        border |= type == CLAY_RENDER_COMMAND_TYPE_BORDER;
    }
    for (int32_t i = 0; i < commands.length; i++) {
        Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
        if (!batch_command_type(cmd->commandType))
            return false;
        border |= cmd->commandType == CLAY_RENDER_COMMAND_TYPE_BORDER;
        uint64_t key = (uint64_t)cmd->commandType << 32 | cmd->id;
        changed |= rmap_get(rs, key) == SIZE_MAX;
    }
    if (!border || !changed ||
            !scene_visibility_quiet(&rs->tree->node, false, true))
        return false;
    struct wlr_scene_tree *root = rs->tree;
    while (root->node.parent != NULL)
        root = root->node.parent;
    return scene_visibility_quiet(&root->node, true, false);
}

int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
		const struct render_client_hooks *hooks, Clay_BoundingBox bounds) {
	rs->gen++;
	rs->buffers_created = 0;
	rs->visibility_batched = false;
	rs->node_recreated = false;
	rs->scopes_len = 0;
	int muts = 0;

	/* Map reflects the pre-pass nodes; new nodes appended below get unique
	 * keys and are never looked up again this pass, so it stays valid. */
	rmap_rebuild(rs);
	size_t pre_len = rs->len;
    rs->visibility_batched = can_batch_visibility(rs, commands);
    if (rs->visibility_batched) {
        wlr_scene_node_set_enabled(&rs->tree->node, false);
        muts++;
    }

	/* One capacity for both, so p_realloc rather than p_grow: the second
	 * p_grow would see the capacity the first already raised. */
	if ((size_t)commands.length > rs->order_cap) {
		rs->order_cap = commands.length;
		p_realloc(&rs->order, rs->order_cap);
		p_realloc(&rs->build, rs->order_cap);
	}

	/* The active SCISSOR clip scopes Clay emitted for its own clip elements,
	 * innermost last, rebuilt as the walk crosses START/END. wlr_scene has
	 * no subtree clip, so each drawn node is clipped on its own against the
	 * top of this stack and the scope its word names. Depth is bounded by
	 * tree nesting; the cap is a backstop, not a real limit. */
	Clay_BoundingBox clip_stack[CLIP_STACK_MAX];
	int clip_depth = 0;
	const struct clip_scope bounds_scope = { .box = bounds };

	uint64_t backdrop[2] = {0};
	size_t build_len = 0;
	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		Clay_RenderCommand decoration;
		if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
				cmd->renderData.custom.customData != RENDER_CLIP_MARK &&
				((uintptr_t)cmd->renderData.custom.customData & RENDER_SHADOW_TAG)) {
			decoration = *cmd;
			decoration.boundingBox = shadow_owner_box(
				render_shadow_of(cmd->renderData.custom.customData));
			cmd = &decoration;
		}
		/* The scissor command stays solved for the clip stack and
		 * text_ellipsis_width. Every realized box rounds once, including
		 * the clipped intersection below. */
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) {
			cmd->boundingBox = box_snap(cmd->boundingBox);
		}
		bool output = rs->output_id && cmd->id == rs->output_id;
		Clay_RenderCommand image;
		if (output && cmd->commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE) {
			image = *cmd;
			image.renderData.image.backgroundColor = (Clay_Color){0};
			cmd = &image;
		}
		uint64_t key = (uint64_t)cmd->commandType << 32 | cmd->id;
		if (output && cmd->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE)
			backdrop[0] = key;
		else if (output && cmd->commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE)
			backdrop[1] = key;
		else
			rs->build[build_len++] = key;

		size_t idx = rmap_get(rs, key);
		struct rnode *n = idx == SIZE_MAX ? NULL : &rs->nodes[idx];
		if (n == NULL) {
			n = rnode_add(rs, key);
		}
		bool is_new = n->node == NULL;
		n->gen = rs->gen;
		n->z = cmd->zIndex;
		n->user_data = cmd->userData;

		/* The clip that applies to this command: the scope its word names
		 * and every SCISSOR START/END already crossed; a scope this
		 * command opens (below) affects only what names it. */
		unsigned by = render_userdata_byte(cmd->userData, RENDER_UD_CLIP_SHIFT);
		const struct clip_scope *scope = by == RENDER_CLIP_BOUNDS ? &bounds_scope
			: by != 0 ? scope_named(rs, cmd->userData, by) : NULL;
		Clay_BoundingBox clip = box_inf();
		bool clipped = false;
		if (clip_depth > 0) {
			clip = clip_stack[(clip_depth < CLIP_STACK_MAX ? clip_depth : CLIP_STACK_MAX) - 1];
			clipped = true;
		}
		if (scope != NULL) {
			clip = box_intersect(clip, scope->box);
			clipped = true;
		}
		const Clay_BoundingBox *clip_top = clipped ? &clip : NULL;
		/* A border (square or rounded) keeps its per-side clip against clip_top,
		 * so it stays unclippable and its tree sits at the unclipped origin: the
		 * edges clip in absolute space and each corner tile disables when fully
		 * clipped. Only the rastered leaves crop via rbox. */
		bool clip_mark = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			cmd->renderData.custom.customData == RENDER_CLIP_MARK;
		bool shape = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			!clip_mark && ((uintptr_t)cmd->renderData.custom.customData & RENDER_SHAPE_TAG);
		bool shadow = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			!clip_mark && ((uintptr_t)cmd->renderData.custom.customData & RENDER_SHADOW_TAG);
		bool clippable = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE || clip_mark || shape ||
			(cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM && !shadow);
		Clay_BoundingBox rbox = (clip_top != NULL && clippable) ?
			box_snap(box_intersect(cmd->boundingBox, *clip_top)) : cmd->boundingBox;
		/* The arc of the nearest rounded clip, for a raster that reaches a
		 * corner of it. */
		const struct clip_round *mask = scope != NULL && clippable &&
			clip_round_hits(&scope->round, rbox) ? &scope->round : NULL;

		switch (cmd->commandType) {
		case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
			muts += reconcile_rectangle(rs, n, cmd, rbox, mask);
			scope_open(rs, cmd->userData, rbox, scope,
				cmd->renderData.rectangle.cornerRadius.topLeft);
			break;
		case CLAY_RENDER_COMMAND_TYPE_BORDER:
			muts += reconcile_border(rs, n, cmd, clip_top);
			break;
		case CLAY_RENDER_COMMAND_TYPE_TEXT:
			muts += reconcile_text(rs, n, cmd, rbox, clip_top, mask);
			break;
		case CLAY_RENDER_COMMAND_TYPE_IMAGE:
			muts += reconcile_image(rs, n, cmd, rbox, mask);
			break;
		case CLAY_RENDER_COMMAND_TYPE_CUSTOM:
			/* A clip mark: a transparent rect that takes input (render.h),
			 * and the scope it opens. */
			if (clip_mark) {
				muts += reconcile_clip_mark(rs, n, rbox);
				scope_open(rs, cmd->userData, rbox, scope,
					cmd->renderData.custom.cornerRadius.topLeft);
				break;
			}
			if (shadow) {
				muts += reconcile_shadow(rs, n, cmd);
				break;
			}
			if (shape) {
				muts += reconcile_shape(rs, n, cmd, rbox, mask, hooks);
				break;
			}
			muts += reconcile_surface(rs, n, cmd, rbox, hooks);
			break;
		case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START: {
			/* The clip rect is the command's own box; the two bools name which
			 * axes clip, so an unclipped axis is left unbounded. Nested scopes
			 * compose by intersecting with the enclosing clip.
			 *
			 * Naming NEITHER axis means both, not none. Clay emits this command
			 * from two places: a clip element, which fills in its own config's
			 * two bools, and a FLOATING element whose clipTo names an ancestor
			 * clip, which fills in nothing at all and hands over that ancestor's
			 * box. Reading that second one
			 * as "no axis clips" is a scene-vs-Clay divergence by construction:
			 * Clay's own hit test clips such a root to that box on BOTH axes,
			 * so the scene would draw content Clay says is not there, which is
			 * exactly what the agreement invariant aborts on (the debug panel's
			 * element list is such a float, and its rows once drew over the
			 * pane below it). Scissoring the box unconditionally is the only
			 * reading that matches the solver. */
			Clay_BoundingBox sc = cmd->boundingBox;
			bool both = !cmd->renderData.clip.horizontal &&
				!cmd->renderData.clip.vertical;
			if (!cmd->renderData.clip.horizontal && !both) {
				sc.x = -CLIP_INF;
				sc.width = 2.0f * CLIP_INF;
			}
			if (!cmd->renderData.clip.vertical && !both) {
				sc.y = -CLIP_INF;
				sc.height = 2.0f * CLIP_INF;
			}
			if (clip_depth > 0) {
				sc = box_intersect(clip_stack[(clip_depth < CLIP_STACK_MAX
					? clip_depth : CLIP_STACK_MAX) - 1], sc);
			}
			if (clip_depth < CLIP_STACK_MAX) {
				clip_stack[clip_depth] = sc;
			}
			clip_depth++;
			break;
		}
		case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:
			if (clip_depth > 0) {
				clip_depth--;
			} else {
				wlr_log(WLR_ERROR, "unbalanced SCISSOR_END");
			}
			break;
		default:
			/* Unsupported commands (including pinned overlay-color scopes)
			 * are rejected; their properties remain unexposed in M0a. */
			wlr_log(WLR_ERROR, "unhandled render command type %d",
				cmd->commandType);
			abort();
		}

		/* Position and visibility are common to every realized node. Placement
		 * of a new node is part of its creation mutation, not a second one. A
		 * NULL node is a SCISSOR marker or a surface whose client died
		 * mid-frame; skip it. Borrowed trees use the solved origin because
		 * wlroots positions their cropped buffers relative to that origin.
		 * Other nodes use the realized origin at the clip boundary. */
		if (n->node != NULL) {
			Clay_BoundingBox position = n->borrowed ? cmd->boundingBox : rbox;
			Clay_BoundingBox previous = n->borrowed ? n->box : n->rbox;
			if (is_new || !box_pos_equal(previous, position)) {
				wlr_scene_node_set_position(n->node, (int)position.x, (int)position.y);
				if (!is_new) {
					muts++;
				}
				/* A borrowed client tree that was placed or moved invalidates
				 * any geometry the owner keyed to its scene position:
				 * xdg-popups unconstrained against the pre-move box, and X11
				 * root coordinates. Fires on first placement too, because the
				 * borrow's configure above ran before this position existed.
				 * Fire after set_position so the owner reads the new coords.
				 * C to C, no reconcile reentry. */
				if (n->borrowed && hooks->reposition != NULL) {
					hooks->reposition(hooks->data, n->handle,
						(int)position.x, (int)position.y);
				}
			}
			bool want_enabled = !box_empty(rbox);
			if (n->node->enabled != want_enabled) {
				wlr_scene_node_set_enabled(n->node, want_enabled);
				if (!is_new) {
					muts++;
				}
			}
		}

		n->box = cmd->boundingBox;
		n->rbox = rbox;
		/* The clip rbox was realized against, mirroring the rbox computation
		 * above: the active clip for a clippable node, else unbounded. */
		n->clip = (clip_top != NULL && clippable) ? *clip_top : box_inf();
		n->data = cmd->renderData;
	}
	/* OUTPUT is unclipped. Its two paint nodes precede even negative-band
	 * roots; colour is an underlay and never an image tint. */
	size_t backdrop_len = !!backdrop[0] + !!backdrop[1];
	if (backdrop_len) {
		memmove(rs->build + backdrop_len, rs->build,
			build_len * sizeof(*rs->build));
		for (size_t i = 0, j = 0; i < 2; i++)
			if (backdrop[i])
				rs->build[j++] = backdrop[i];
		build_len += backdrop_len;
	}
	if (clip_depth != 0) {
		wlr_log(WLR_ERROR, "unbalanced SCISSOR scopes: depth %d at frame end",
			clip_depth);
	}

	/* Sweep ids that vanished this frame. */
	bool swept = false;
	for (size_t i = 0; i < rs->len; ) {
		if (rs->nodes[i].gen != rs->gen) {
			rnode_remove(rs, &rs->nodes[i], hooks);
			swept = true;
			muts++;
		} else {
			i++;
		}
	}

	/* The sweep's swap-removal scrambles indices, and nodes appended during the
	 * declare loop were never inserted; either way the restack reads the map
	 * by key, so it has to be rebuilt. A frame that added and removed
	 * nothing did neither, which is the frame worth keeping free of per-node
	 * work. */
	if (swept || rs->len != pre_len) {
		rmap_rebuild(rs);
	}

	/* order_changed against the previous frame's order, so an identical
	 * frame restacks nothing. OUTPUT's paint leads the retained order; all
	 * other commands keep Clay order. A kind-swap recreation forces a
	 * restack regardless: the fresh scene node sits at the top of the
	 * sibling list while its command key is unchanged. */
	bool order_changed = build_len != rs->order_len || rs->node_recreated;
	for (size_t i = 0; !order_changed && i < build_len; i++) {
		if (rs->build[i] != rs->order[i]) {
			order_changed = true;
		}
	}
	memcpy(rs->order, rs->build, build_len * sizeof(*rs->order));
	rs->order_len = build_len;

	/* Restack only when the retained scene order changed. */
	if (order_changed) {
		for (size_t i = 0; i < rs->order_len; i++) {
			size_t idx = rmap_get(rs, rs->order[i]);
			assert(idx != SIZE_MAX);
			struct rnode *n = &rs->nodes[idx];
			if (n->node != NULL) {
				wlr_scene_node_raise_to_top(n->node);
				muts++;
			}
		}
	}

    /* The pass never yields. Restore the prior enabled state before any
     * completed geometry, pixels or pointer targeting can be consumed. */
    if (rs->visibility_batched) {
        wlr_scene_node_set_enabled(&rs->tree->node, true);
        muts++;
    }

#ifdef SOMEWM_RENDER_VERIFY
	for (size_t i = 0; i < rs->len; i++) {
		verify_node(&rs->nodes[i]);
	}
	verify_order(rs);
#endif

	return muts;
}

void render_destroy(struct render_state *rs,
		const struct render_client_hooks *hooks) {
	/* Borrowed trees must leave before the render tree is destroyed, or
	 * the clients' scene nodes would be destroyed with it. */
	for (size_t i = 0; i < rs->len; i++) {
		if (rs->nodes[i].borrowed) {
			render_release(rs, &rs->nodes[i], hooks);
		}
		free(rs->nodes[i].text);
		free(rs->nodes[i].shape_ops);
		if (rs->nodes[i].img_native)
			cairo_surface_destroy(rs->nodes[i].img_native);
		shadow_cache_release(rs, rs->nodes[i].shadow);
	}
	wlr_scene_node_destroy(&rs->tree->node);
	free(rs->nodes);
	free(rs->order);
	free(rs->build);
	free(rs->map);
	free(rs->scopes);
	free(rs);
}

/* The topmost node under a band-local point, walking the last frame's draw
 * order from the top: a node is a candidate when its realized box holds the
 * point and the point is inside what it draws (the arcs of a rounded rect or
 * a rounded clip, a border's ring, a shape's path), and it is the answer
 * when accept admits it. A refusal continues below: an input hole in a
 * surface, a pass-through drawin, chrome that takes no input. */
bool render_hit(struct render_state *rs, double x, double y,
		bool (*accept)(void *user, const struct render_node_view *view,
			double sx, double sy), void *user) {
	for (size_t i = rs->order_len; i > 0; i--) {
		size_t idx = rmap_get(rs, rs->order[i - 1]);

		if (idx == SIZE_MAX) {
			continue;
		}
		struct rnode *n = &rs->nodes[idx];
		uint32_t type = (uint32_t)(n->key >> 32);
		double sx = x - n->rbox.x, sy = y - n->rbox.y;

		if (n->node == NULL || box_empty(n->rbox)
				|| sx < 0 || sy < 0 || sx >= n->rbox.width || sy >= n->rbox.height) {
			continue;
		}
		if (type == CLAY_RENDER_COMMAND_TYPE_BORDER) {
			if (!border_point_in_ring(n, x - n->box.x, y - n->box.y)) {
				continue;
			}
		} else if (!rnode_point_in_arcs(n, sx, sy)) {
			continue;
		} else if (type == CLAY_RENDER_COMMAND_TYPE_CUSTOM && n->shape_ops != NULL
				&& !shape_point_in_path(n, sx, sy)) {
			continue;
		}
		if (accept(user, &(struct render_node_view) {
				.type = type,
				.id = (uint32_t)n->key,
				.z = n->z,
				.box = n->box,
				.rbox = n->rbox,
				.has_node = true,
				.clip_mark = type == CLAY_RENDER_COMMAND_TYPE_CUSTOM
					&& n->data.custom.customData == RENDER_CLIP_MARK,
				.user_data = n->user_data,
			}, sx, sy)) {
			return true;
		}
	}
	return false;
}

void render_walk(struct render_state *rs,
		void (*fn)(void *user, const struct render_node_view *view),
		void *user) {
	for (size_t i = 0; i < rs->order_len; i++) {
		size_t idx = rmap_get(rs, rs->order[i]);

		if (idx == SIZE_MAX) {
			continue;
		}
		struct rnode *n = &rs->nodes[idx];

		fn(user, &(struct render_node_view) {
			.type = (uint32_t)(n->key >> 32),
			.id = (uint32_t)n->key,
			.z = n->z,
			.box = n->box,
			.rbox = n->rbox,
			.raster_bytes = n->raster_bytes,
			.has_node = n->node != NULL,
			.clip_mark = (uint32_t)(n->key >> 32) == CLAY_RENDER_COMMAND_TYPE_CUSTOM
				&& n->data.custom.customData == RENDER_CLIP_MARK,
			.mismatch = rnode_scene_mismatch(n),
			.user_data = n->user_data,
		});
	}
}

size_t render_node_count(struct render_state *rs) {
	return rs->len;
}

size_t render_raster_bytes(struct render_state *rs) {
	return rs->raster_bytes;
}

int render_buffers_created(struct render_state *rs) {
	return rs->buffers_created;
}

bool render_visibility_batched(struct render_state *rs) {
    return rs->visibility_batched;
}
