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

/* Max SCISSOR nesting the clip stack holds; deeper scopes reuse the innermost
 * bound (degenerate, and far past any real chrome). CLIP_INF stands in for an
 * unclipped axis: outputs are at most a few thousand px, so it never clamps. */
#define CLIP_STACK_MAX 64
#define CLIP_INF 1.0e6f

/* A wlr_buffer backed by a cairo image surface, for rasterized text. */
struct cairo_buffer {
	struct wlr_buffer base;
	cairo_surface_t *surface;
};

static void cairo_buffer_destroy(struct wlr_buffer *buffer) {
	struct cairo_buffer *cb = wl_container_of(buffer, cb, base);
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

/* One retained record per (command id, command type). */
struct rnode {
	uint64_t key;
	/* box is Clay's solved box; rbox is the realized box after clipping to
	 * the active SCISSOR scope (equal to box when no clip applies). box
	 * drives raster/content diffs; rbox drives node position, size, and the
	 * tree==scene verifier. */
	Clay_BoundingBox box;
	Clay_BoundingBox rbox;
	/* The active SCISSOR clip scope this node was realized against (the
	 * infinite box when unclipped or exempt), retained so the verifier can
	 * assert rbox stays inside it: rbox = box_intersect(box, clip) by
	 * construction, so a green check proves no path skipped the clip. */
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
	/* The scale this node's raster was drawn at: the fourth raster cache key
	 * (content, font, size, scale). Clay solves logical, so a scale change alone
	 * leaves the box identical; without this a runtime set_scale would keep the
	 * old-density buffer. Rects and square borders carry no raster, so it stays 0. */
	float raster_scale;
	/* TEXT: the device-pixel bound this node's raster was truncated to, 0 for an
	 * untouched run. A fifth raster key, and the only one not derivable from the
	 * command: it comes from the clip, which can move while the command does not. */
	int text_ellipsis;
	/* Bytes of the cairo raster this node holds in the scene (0 for rects,
	 * trees, and borrowed clients), kept so the per-state total is O(1). */
	size_t raster_bytes;
	bool borrowed;
	uint64_t handle;
	uint64_t gen;
	/* The command's userData word (render.h), retained for the input
	 * backmap; and the opacity last applied to an IMAGE node's buffer. */
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
	struct wlr_scene_tree *tree;
	struct rnode *nodes;
	size_t len, cap;
	uint64_t gen;
	/* Command keys in draw order (popup-owners folded to the tail) from the
	 * previous frame, to detect reordering without touching the scene when
	 * order is unchanged. build assembles this frame's order before the fold,
	 * kept off order so the previous final order survives the comparison. */
	uint64_t *order;
	size_t order_len, order_cap;
	uint64_t *build;
	/* key -> index into nodes, so a lookup is O(1) and the reconcile is O(N)
	 * rather than O(N^2). Insert-only, rebuilt from nodes each pass. */
	struct rnode_slot *map;
	size_t map_cap;
	/* Profiling readback: resident cairo raster bytes across all live
	 * nodes, and buffers allocated by the current reconcile pass. */
	size_t raster_bytes;
	int buffers_created;
	/* A kind-swap (rounded <-> square rect or border) destroyed and recreated
	 * a node under an unchanged command key this pass. The recreated scene
	 * node was appended at the top of its sibling list, so the restack must
	 * run even though the command order is byte-identical. */
	bool node_recreated;
	/* The output's scale, driving device-pixel raster sizing. 1.0 is the
	 * identity: every device_len below reduces to the logical length, so a
	 * non-HiDPI output rasters exactly as before. */
	float scale;
	/* The hooks of the last reconcile pass, for input callbacks that fire
	 * between passes (accepts_input). The declarer passes a stable struct. */
	const struct render_client_hooks *hooks;
	struct render_state *next;
};

/* Every live render_state, so a corner tile's input callback can find the node
 * that owns it.
 *
 * The obvious back-pointer, wlr_scene_node.data on the tile, is not ours to
 * use: input.c reads that field off a hit leaf buffer as a drawable_t and
 * dereferences ->owner_type with no type tag (input.c:1734), and off parent
 * trees as a drawin_t or a client (input.c:1759). Anything the renderer stored
 * there would be read as one of those the moment the render tree sits in a
 * walked layer. One entry per output's chrome, so the walk is a handful of
 * pointers, and the callback already scans nodes linearly. */
static struct render_state *render_states;

struct render_state *render_create(struct wlr_scene_tree *parent) {
	struct render_state *rs = calloc(1, sizeof(*rs));
	rs->tree = wlr_scene_tree_create(parent);
	rs->scale = 1.0f;
	rs->next = render_states;
	render_states = rs;
	return rs;
}

void render_set_enabled(struct render_state *rs, bool on) {
	wlr_scene_node_set_enabled(&rs->tree->node, on);
}

void render_set_position(struct render_state *rs, int x, int y) {
	/* wlr_scene_node_set_position no-ops on identical coordinates. */
	wlr_scene_node_set_position(&rs->tree->node, x, y);
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
	rs->raster_bytes -= n->raster_bytes;
	if (n->borrowed) {
		hooks->release(hooks->data, n->handle, rs);
	} else {
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

static bool box_pos_equal(Clay_BoundingBox a, Clay_BoundingBox b) {
	return (int)a.x == (int)b.x && (int)a.y == (int)b.y;
}

static bool box_size_equal(Clay_BoundingBox a, Clay_BoundingBox b) {
	return (int)a.width == (int)b.width && (int)a.height == (int)b.height;
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

/* Crop a buffer leaf to its realized clip box. The buffer always holds the full
 * solved box, so a SCISSOR clip is a source-box crop, never a re-raster; a NULL
 * source with 0,0 dest restores the natural extent when the clip no longer
 * bites. */
static void buffer_apply_clip(struct wlr_scene_buffer *sb,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox, float scale) {
	Clay_BoundingBox box = cmd->boundingBox;
	/* dst_size is the node's LOGICAL footprint, and it is always set: the buffer
	 * holds device pixels, so a 0,0 (natural-size) dest would make wlroots read
	 * those device pixels as logical and draw the node scale-times oversize. */
	bool clipped = !box_pos_equal(rbox, box) || !box_size_equal(rbox, box);
	if (clipped) {
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
		/* Truncation is not monotonic across the two boxes, so a clip flush
		 * against the box edge can land a device pixel past the buffer; keep
		 * the crop inside it rather than sampling off the end. */
		double bw = device_len(ox, (int)box.width, scale);
		double bh = device_len(oy, (int)box.height, scale);
		src.x = fmin(src.x, bw - 1);
		src.y = fmin(src.y, bh - 1);
		src.width = fmax(1.0, fmin(src.width, bw - src.x));
		src.height = fmax(1.0, fmin(src.height, bh - src.y));
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
		!box_size_equal(n->rbox, rbox);
	if ((raster_changed || clip_changed) && !box_empty(rbox)) {
		buffer_apply_clip(sb, cmd, rbox, scale);
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
	wlr_scene_buffer_set_buffer(sb, cb != NULL ? &cb->base : NULL);
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

static struct cairo_buffer *rasterize_rounded_rect(Clay_RenderCommand *cmd,
		float scale) {
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
	int muts = 0;

	/* A solid rect crops to its clip by shrinking; the color is uniform, so
	 * the visible region is exactly the intersection box. */
	if (n->node == NULL) {
		struct wlr_scene_rect *rect = wlr_scene_rect_create(rs->tree,
			(int)rbox.width, (int)rbox.height, color);
		n->node = &rect->node;
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
			sizeof(rd->backgroundColor)) != 0) {
		wlr_scene_rect_set_color(rect, color);
		muts++;
	}
	return muts;
}

static int reconcile_rounded_rect(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
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
		!box_size_equal(n->box, cmd->boundingBox) ||
		n->raster_scale != rs->scale ||
		memcmp(&n->data.rectangle, rd, sizeof(*rd)) != 0;
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_rounded_rect(cmd, rs->scale));
		n->raster_scale = rs->scale;
		muts++;
	}

	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	return muts;
}

/* A rect's node kind depends on its corner radius, so a radius toggling between
 * zero and nonzero swaps the kind: destroy the old node and let the chosen path
 * recreate it. */
static int reconcile_rectangle(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
	bool rounded = !corner_radius_zero(cmd->renderData.rectangle.cornerRadius);
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
	return rounded ? reconcile_rounded_rect(rs, n, cmd, rbox)
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

/* A rounded corner tile overlays a small square of the client body (the arc's
 * interior is transparent), so a click there must fall through to the surface as
 * the old full-box buffer did, or the tile shadows that corner and diverges from
 * Clay, which ranks the surface topmost. The test is GEOMETRIC, not a pixel
 * read: the ring is inside the outer rounded rect and outside the inner inset
 * one, the shape the tiles fill. It runs in logical space (device scale never
 * reaches the hit path). Only corner tiles carry it; the straight edges are
 * opaque rects that never overlap the body. The retained node behind a tile is
 * found by scanning the live render_states for the one holding it in
 * border_corners, since the tile carries no back-pointer. */
static bool border_point_accepts_input(struct wlr_scene_buffer *sb,
		double *sx, double *sy) {
	struct rnode *n = NULL;
	for (struct render_state *rs = render_states;
			rs != NULL && n == NULL; rs = rs->next) {
		for (size_t i = 0; i < rs->len && n == NULL; i++) {
			for (int c = 0; c < 4; c++) {
				if (rs->nodes[i].border_corners[c] == sb) {
					n = &rs->nodes[i];
					break;
				}
			}
		}
	}
	if (n == NULL) {
		return false;
	}
	/* The tile sits at its corner offset within the border tree, and the tree is
	 * at the box origin, so the tile's node position IS its box-relative origin;
	 * add the local point to reach the box-relative coords the ring is defined in. */
	double bx = sb->node.x + *sx;
	double by = sb->node.y + *sy;
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
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const Clay_BoundingBox *clip) {
	(void)rbox;   /* borders are not clip targets, so rbox == box. */
	Clay_BorderRenderData *bd = &cmd->renderData.border;
	float color[4];
	clay_color_to_float(bd->color, color);
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
		wlr_scene_node_set_position(n->node,
			(int)cmd->boundingBox.x, (int)cmd->boundingBox.y);
		for (int i = 0; i < 4; i++) {
			n->border_sides[i] = wlr_scene_rect_create(tree,
				edges[i][2], edges[i][3], color);
			wlr_scene_node_set_position(&n->border_sides[i]->node,
				edges[i][0], edges[i][1]);
		}
		for (int c = 0; c < 4; c++) {
			struct wlr_scene_buffer *sb = wlr_scene_buffer_create(tree, NULL);
			sb->point_accepts_input = border_point_accepts_input;
			n->border_corners[c] = sb;
		}
	}

	/* Corner arcs: keyed on border data, scale, AND box size. The ring path
	 * clamps radii against the solved box, so a tile rastered against a small
	 * or degenerate box goes stale when the box grows. */
	bool corner_changed = is_new ||
		!box_size_equal(n->box, cmd->boundingBox) ||
		n->raster_scale != rs->scale ||
		memcmp(&n->data.border, bd, sizeof(*bd)) != 0;
	if (corner_changed) {
		size_t bytes = 0;
		for (int c = 0; c < 4; c++) {
			struct cairo_buffer *cb =
				rasterize_border_corner(cmd, ext, rs->scale, c);
			wlr_scene_buffer_set_buffer(n->border_corners[c],
				cb != NULL ? &cb->base : NULL);
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
	bool color_changed = !is_new && memcmp(&n->data.border.color, &bd->color,
		sizeof(bd->color)) != 0;
	for (int i = 0; i < 4; i++) {
		/* The rect itself is the record of its last realized box, so there is
		 * no shadow copy to keep in step with what was written. */
		struct wlr_scene_rect *side = n->border_sides[i];
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
	return muts;
}

/* --- text --- */

/* The device-pixel bound a truncated run is truncated to, or 0 for an untouched
 * run.
 *
 * A text command's own box is the width of its glyphs, so it is never the space
 * the run had to fit into and there is nothing on the declaration side to read.
 * The clip its parent declared is the only bound that exists, and rbox is that
 * clip already intersected with the run.
 *
 * Measured from the run's left edge to the clip's right edge rather than as
 * rbox.width, because a clip that cuts the left as well leaves rbox narrower
 * than the span the glyphs are laid out across, and truncating at that narrower
 * number would cut text that is on screen. */
static int text_ellipsis_width(Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		float scale) {
	if (((uintptr_t)cmd->userData & RENDER_TEXT_ELLIPSIZE) == 0) {
		return 0;
	}
	double avail = (rbox.x + rbox.width) - cmd->boundingBox.x;
	if (avail >= cmd->boundingBox.width || avail <= 0) {
		return 0;
	}
	return device_len((int)cmd->boundingBox.x, (int)avail, scale);
}

static struct cairo_buffer *rasterize_text(Clay_RenderCommand *cmd, float scale,
		int max_width) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int width = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int height = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (width < 1 || height < 1) {
		return NULL;
	}

	struct cairo_buffer *cb = cairo_buffer_create(width, height);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	/* Cairo takes straight alpha here, so no premultiply. */
	cairo_set_source_rgba(cr,
		clay_srgb(td->textColor.r), clay_srgb(td->textColor.g),
		clay_srgb(td->textColor.b), clay_srgb(td->textColor.a));

	/* Draw the glyphs at device font size into the device-sized buffer, the same
	 * size render_measure_text measured at, so the run occupies exactly the logical
	 * box Clay solved (scaled). Crisp on a fractional output, no CTM scaling. */
	PangoLayout *layout = pango_cairo_create_layout(cr);
	render_set_text(layout, td->stringContents.chars,
		td->stringContents.length, td->fontId, td->fontSize, scale, max_width);
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
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
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
	int ell = text_ellipsis_width(cmd, rbox, rs->scale);
	bool raster_changed = content_changed ||
		!box_size_equal(n->box, cmd->boundingBox) ||
		n->raster_scale != rs->scale ||
		n->text_ellipsis != ell ||
		!text_data_equal(&n->data.text, td);
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_text(cmd, rs->scale, ell));
		n->raster_scale = rs->scale;
		n->text_ellipsis = ell;
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
 * The decode cache (ui.c) holds one native cairo surface per path. The image
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
		struct image_entry *entry, float scale) {
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1 || entry->width < 1 || entry->height < 1) {
		return NULL;
	}
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);

	/* w and h are already device pixels, so scaling the native surface to fill
	 * them (below) also carries the output scale: the image is sampled once, at
	 * device density. The corner radii scale to match. */
	Clay_CornerRadius radius = scale_corner_radius(
		cmd->renderData.image.cornerRadius, scale);
	if (!corner_radius_zero(radius)) {
		rounded_rect_path(cr, 0, 0, w, h, radius);
		cairo_clip(cr);
	}
	cairo_scale(cr, (double)w / entry->width, (double)h / entry->height);
	Clay_Color ink = cmd->renderData.image.backgroundColor;
	if (ink.a > 0) {
		cairo_set_source_rgba(cr, clay_srgb(ink.r), clay_srgb(ink.g),
			clay_srgb(ink.b), clay_srgb(ink.a));
		cairo_mask_surface(cr, entry->native, 0, 0);
	} else {
		cairo_set_source_surface(cr, entry->native, 0, 0);
		cairo_paint(cr);
	}

	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

/* The input filter on image leaves: find the owning rnode across the live
 * render_states (same scan as border_point_accepts_input) and ask the
 * declarer's hook with the retained userData word and the node-local point.
 * This is what lets a shaped drawin's pass-through pixels fall through
 * wlr_scene_node_at to whatever draws below. */
static bool image_point_accepts_input(struct wlr_scene_buffer *sb,
		double *sx, double *sy) {
	for (struct render_state *rs = render_states; rs != NULL; rs = rs->next) {
		for (size_t i = 0; i < rs->len; i++) {
			struct rnode *n = &rs->nodes[i];
			if (n->node != &sb->node) {
				continue;
			}
			if (rs->hooks == NULL || rs->hooks->accepts_input == NULL) {
				return true;
			}
			return rs->hooks->accepts_input(rs->hooks->data,
				n->user_data, *sx, *sy);
		}
	}
	return false;
}

static bool image_data_equal(Clay_ImageRenderData *a, Clay_ImageRenderData *b) {
	return a->imageData == b->imageData &&
		memcmp(&a->backgroundColor, &b->backgroundColor,
			sizeof(a->backgroundColor)) == 0 &&
		memcmp(&a->cornerRadius, &b->cornerRadius,
			sizeof(a->cornerRadius)) == 0;
}

static int reconcile_image(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
	struct image_entry *entry =
		(struct image_entry *)cmd->renderData.image.imageData;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		sb->point_accepts_input = image_point_accepts_input;
		n->node = &sb->node;
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

	/* A missing, failed, or not-yet-decoded entry shows nothing. */
	bool usable = entry != NULL && !entry->failed && entry->native != NULL;
	bool raster_changed = is_new ||
		!box_size_equal(n->box, cmd->boundingBox) ||
		n->raster_scale != rs->scale ||
		!image_data_equal(&n->data.image, &cmd->renderData.image) ||
		(usable && entry->gen != n->img_gen);

	if (raster_changed) {
		rnode_set_raster(rs, n, sb,
			usable ? rasterize_image(cmd, entry, rs->scale) : NULL);
		n->img_gen = usable ? entry->gen : 0;
		n->raster_scale = rs->scale;
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

static int reconcile_surface(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, const struct render_client_hooks *hooks) {
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
	if (n->node == NULL) {
		wlr_scene_node_reparent(&tree->node, rs->tree);
		wlr_scene_node_set_enabled(&tree->node, true);
		n->node = &tree->node;
		hooks->borrow(hooks->data, handle, rs);
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
	if (box_empty(n->rbox)) {
		return n->node->enabled;
	}
	if (!n->node->enabled || !box_contains(n->clip, n->rbox)) {
		return true;
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
	wlr_log(WLR_ERROR, "tree==scene: key %" PRIx64 " %s at %d,%d but "
		"realized box says %d,%d %dx%d inside clip %d,%d %dx%d",
		n->key, n->node->enabled ? "enabled" : "disabled",
		n->node->x, n->node->y,
		(int)n->rbox.x, (int)n->rbox.y,
		(int)n->rbox.width, (int)n->rbox.height,
		(int)n->clip.x, (int)n->clip.y,
		(int)n->clip.width, (int)n->clip.height);
	abort();
}

#endif /* SOMEWM_RENDER_VERIFY */

/* Does the command key name a borrowed client that currently presents a live
 * xdg-popup? Only a CUSTOM (place-leaf) command can, so the cheap type check
 * skips the map lookup and the hook for every draw-leaf. Used to fold such
 * clients to the top of the order so their popups are not occluded. */
static bool rnode_owns_popup(struct render_state *rs, uint64_t key,
		const struct render_client_hooks *hooks) {
	if ((uint32_t)(key >> 32) != CLAY_RENDER_COMMAND_TYPE_CUSTOM) {
		return false;
	}
	size_t idx = rmap_get(rs, key);
	return idx != SIZE_MAX && rs->nodes[idx].borrowed &&
		hooks->has_popup(hooks->data, rs->nodes[idx].handle);
}

#ifdef SOMEWM_RENDER_VERIFY

/* Check 1 of the agreement invariant: scene sibling order equals command
 * order. The restack raises each command's node to the top in order, so a
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
			wlr_log(WLR_ERROR, "tree==scene: sibling order diverges from "
				"command order");
			abort();
		}
	}
	/* Every command left over must be nodeless; one with a node means the
	 * scene is missing a child the command declared. */
	while (oi < rs->order_len) {
		size_t idx = rmap_get(rs, rs->order[oi]);
		oi++;
		if (idx != SIZE_MAX && rs->nodes[idx].node != NULL) {
			wlr_log(WLR_ERROR, "tree==scene: command %" PRIx64
				" has no scene child", rs->order[oi - 1]);
			abort();
		}
	}
}

#endif /* SOMEWM_RENDER_VERIFY */

/* --- the scene-node-to-Clay-id backmap --- */

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

void *render_hit_userdata(struct render_state *rs, struct wlr_scene_node *node) {
	struct rnode *n = rnode_for_scene_node(rs, node);
	return n != NULL ? n->user_data : NULL;
}

uint32_t render_hit_id(struct render_state *rs, struct wlr_scene_node *node) {
	struct rnode *n = rnode_for_scene_node(rs, node);
	if (n == NULL) {
		return 0;
	}
	/* RECTANGLE, IMAGE, and CUSTOM commands carry the element id directly
	 * (comparable to Clay_GetPointerOverIds). TEXT and BORDER commands
	 * carry a Clay-derived per-line / per-side hash, not the element id,
	 * so they are not comparable; report 0 for them (the structural checks
	 * cover their order and clipping). */
	uint32_t type = (uint32_t)(n->key >> 32);
	if (type == CLAY_RENDER_COMMAND_TYPE_TEXT ||
			type == CLAY_RENDER_COMMAND_TYPE_BORDER) {
		return 0;
	}
	return (uint32_t)(n->key & 0xFFFFFFFF);
}

/* --- the reconcile pass --- */

int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
		const struct render_client_hooks *hooks) {
	rs->gen++;
	rs->buffers_created = 0;
	rs->node_recreated = false;
	rs->hooks = hooks;
	int muts = 0;

	/* Map reflects the pre-pass nodes; new nodes appended below get unique
	 * keys and are never looked up again this pass, so it stays valid. */
	rmap_rebuild(rs);
	size_t pre_len = rs->len;

	/* One capacity for both, so p_realloc rather than p_grow: the second
	 * p_grow would see the capacity the first already raised. */
	if ((size_t)commands.length > rs->order_cap) {
		rs->order_cap = commands.length;
		p_realloc(&rs->order, rs->order_cap);
		p_realloc(&rs->build, rs->order_cap);
	}

	/* The active SCISSOR clip scopes, innermost last, rebuilt as the walk
	 * crosses START/END. wlr_scene has no subtree clip, so each drawn node is
	 * clipped on its own against the top of this stack. Depth is bounded by
	 * tree nesting; the cap is a backstop, not a real limit. */
	Clay_BoundingBox clip_stack[CLIP_STACK_MAX];
	int clip_depth = 0;

	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
		uint64_t key = (uint64_t)cmd->commandType << 32 | cmd->id;
		rs->build[i] = key;

		size_t idx = rmap_get(rs, key);
		struct rnode *n = idx == SIZE_MAX ? NULL : &rs->nodes[idx];
		if (n == NULL) {
			n = rnode_add(rs, key);
		}
		bool is_new = n->node == NULL;
		n->gen = rs->gen;
		n->z = cmd->zIndex;
		n->user_data = cmd->userData;

		/* The clip that applies to this command reflects every START/END
		 * already crossed; this command's own START (below) affects only its
		 * children. Place-leaves are exempt (client popups overhang),
		 * so a CUSTOM subtree is never clipped. */
		const Clay_BoundingBox *clip_top = clip_depth > 0 ?
			&clip_stack[(clip_depth < CLIP_STACK_MAX ? clip_depth : CLIP_STACK_MAX) - 1]
			: NULL;
		/* A border (square or rounded) keeps its per-side clip against clip_top,
		 * so it stays unclippable and its tree sits at the unclipped origin: the
		 * edges clip in absolute space and each corner tile disables when fully
		 * clipped. Only the rastered leaves crop via rbox. */
		bool clippable = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE;
		Clay_BoundingBox rbox = (clip_top != NULL && clippable) ?
			box_intersect(cmd->boundingBox, *clip_top) : cmd->boundingBox;

		switch (cmd->commandType) {
		case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
			muts += reconcile_rectangle(rs, n, cmd, rbox);
			break;
		case CLAY_RENDER_COMMAND_TYPE_BORDER:
			muts += reconcile_border(rs, n, cmd, rbox, clip_top);
			break;
		case CLAY_RENDER_COMMAND_TYPE_TEXT:
			muts += reconcile_text(rs, n, cmd, rbox);
			break;
		case CLAY_RENDER_COMMAND_TYPE_IMAGE:
			muts += reconcile_image(rs, n, cmd, rbox);
			break;
		case CLAY_RENDER_COMMAND_TYPE_CUSTOM:
			muts += reconcile_surface(rs, n, cmd, hooks);
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
			Clay_BoundingBox clip = cmd->boundingBox;
			bool both = !cmd->renderData.clip.horizontal &&
				!cmd->renderData.clip.vertical;
			if (!cmd->renderData.clip.horizontal && !both) {
				clip.x = -CLIP_INF;
				clip.width = 2.0f * CLIP_INF;
			}
			if (!cmd->renderData.clip.vertical && !both) {
				clip.y = -CLIP_INF;
				clip.height = 2.0f * CLIP_INF;
			}
			if (clip_top != NULL) {
				clip = box_intersect(*clip_top, clip);
			}
			if (clip_depth < CLIP_STACK_MAX) {
				clip_stack[clip_depth] = clip;
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
			/* Every Clay command type is handled above; a new one is a bug. */
			wlr_log(WLR_ERROR, "unhandled render command type %d",
				cmd->commandType);
			abort();
		}

		/* Position and visibility are common to every realized node. Placement
		 * of a new node is part of its creation mutation, not a second one. A
		 * NULL node is a SCISSOR marker or a surface whose client died
		 * mid-frame; skip it. Position uses the realized box, so a node clipped
		 * on its left or top edge sits at the clip boundary. */
		if (n->node != NULL) {
			if (is_new || !box_pos_equal(n->rbox, rbox)) {
				wlr_scene_node_set_position(n->node, (int)rbox.x, (int)rbox.y);
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
					hooks->reposition(hooks->data, n->handle);
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
		/* The scope rbox was realized against, mirroring the rbox computation
		 * above: the active clip for a clippable node, else unbounded. */
		n->clip = (clip_top != NULL && clippable) ? *clip_top : box_inf();
		n->data = cmd->renderData;
	}
	size_t build_len = commands.length;
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
	 * declare loop were never inserted; either way the fold and the restack read
	 * the map by key, so it has to be rebuilt. A frame that added and removed
	 * nothing did neither, which is the frame worth keeping free of per-node
	 * work. */
	if (swept || rs->len != pre_len) {
		rmap_rebuild(rs);
	}

	/* Fold popup-owner clients to the tail (the top): a borrowed client showing
	 * a live xdg-popup is raised above its sibling clients so the popup, which
	 * may overhang into a neighbor tile, is not occluded. Stable partition, so
	 * a steadily-open popup yields the identical order every frame. The
	 * reconciler stays the single stacking authority, so verify_order (check 1)
	 * holds against this same order. */
	if (hooks->has_popup != NULL) {
		size_t no = 0;
		for (size_t i = 0; i < build_len; i++) {
			if (rnode_owns_popup(rs, rs->build[i], hooks)) {
				no++;
			}
		}
		if (no > 0) {
			uint64_t *owners = malloc(no * sizeof(*owners));
			size_t oi = 0, w = 0;
			for (size_t i = 0; i < build_len; i++) {
				if (rnode_owns_popup(rs, rs->build[i], hooks)) {
					owners[oi++] = rs->build[i];
				} else {
					rs->build[w++] = rs->build[i];
				}
			}
			for (size_t j = 0; j < no; j++) {
				rs->build[w++] = owners[j];
			}
			free(owners);
		}
	}

	/* order_changed against the previous frame's FINAL (folded) order, so an
	 * identical frame, popup open or not, still restacks nothing. A kind-swap
	 * recreation forces it regardless: the fresh scene node sits at the top
	 * of the sibling list while its command key is unchanged. */
	bool order_changed = build_len != rs->order_len || rs->node_recreated;
	for (size_t i = 0; !order_changed && i < build_len; i++) {
		if (rs->build[i] != rs->order[i]) {
			order_changed = true;
		}
	}
	memcpy(rs->order, rs->build, build_len * sizeof(*rs->order));
	rs->order_len = build_len;

	/* Commands are sorted by z (popup-owners folded on top); restack only when
	 * the order changed. */
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
			hooks->release(hooks->data, rs->nodes[i].handle, rs);
		}
		free(rs->nodes[i].text);
	}
	wlr_scene_node_destroy(&rs->tree->node);
	for (struct render_state **p = &render_states; *p != NULL; p = &(*p)->next) {
		if (*p == rs) {
			*p = rs->next;
			break;
		}
	}
	free(rs->nodes);
	free(rs->order);
	free(rs->build);
	free(rs->map);
	free(rs);
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
