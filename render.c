/* The renderer: reconciles Clay's sorted render command array into wlr_scene,
 * retained and keyed by (command id, command type). Rectangles and borders
 * become scene rects, rounded through somewm's wlroots build; text, images,
 * shape paths and the fills a path cuts rasterize with cairo into a
 * wlr_buffer. Unchanged commands cause zero scene mutations; ids that vanish
 * are swept.
 *
 * Ported from kiln, the reference compositor this was proven in. The tree==scene
 * verifier at the tail of every pass is compiled in only under
 * SOMEWM_RENDER_VERIFY (the asan and test builds), never in release. */

#include <assert.h>
#include <librsvg/rsvg.h>
#include <drm_fourcc.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cairo.h>
#include <pango/pangocairo.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/interface.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_compositor.h>
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

/* Masks use the host's solved pixels, independently of its cropped scene box.
 * Path storage belongs to the retained shape node and survives through input.
 * A radius mask becomes a rounded clip on every scene node it reaches; a path
 * mask is baked into the rasters under it, so only paths key a raster. */
struct clip_mask {
	Clay_BoundingBox box;
	Clay_CornerRadius radii;
	bool path;
	const float *ops;
	size_t len;
	uint64_t gen, key;
};

#define CLIP_MASKS_MAX 16
struct clip_masks {
	size_t len, paths;
	uint64_t digest;
	struct clip_mask items[CLIP_MASKS_MAX];
};

/* Each scope intersects its box and all shaped masks with its parent. */
struct clip_scope {
	uint64_t owner;
	unsigned number;
	Clay_BoundingBox box;
	struct clip_masks masks;
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
    struct render_presentation presentation;
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
	struct render_text_attr *text_attrs;
	size_t text_attrs_len;
	/* RECTANGLE, BORDER: a scene rect. TEXT, IMAGE, shape: a scene buffer.
	 * CUSTOM: a client scene tree the renderer borrowed, never owned. */
	struct wlr_scene_node *node;
	/* IMAGE: the decode generation last rasterized, so a reload re-rasters. */
	uint64_t img_gen;
	int img_src_x, img_src_y;
	cairo_surface_t *img_native;
	void *img_vector;
	int img_width, img_height;
	uint8_t img_filter, img_transform;
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
	 * old-density buffer. Rects carry no raster, so it stays 0. */
	float raster_scale;
	/* TEXT: the device-pixel bound this node's raster was truncated to, 0 for an
	 * untouched run. A fifth raster key, and the only one not derivable from the
	 * command: it comes from the clip, which can move while the command does not. */
	int text_ellipsis;
	/* The scope index is refreshed each frame for input. Only the digest
	 * survives scope rebuilding as a raster cache key. */
	size_t mask_scope;
	uint64_t mask_digest;
	/* Bytes of the cairo raster this node holds in the scene (0 for rects,
	 * trees, and borrowed clients), kept so the per-state total is O(1). */
	size_t raster_bytes;
	/* Keep dimensions after wlroots releases the CPU buffer on upload. */
	int raster_width, raster_height;
	bool borrowed;
	/* Its command vanished while its element stayed in the tree: the node
	 * is kept, disabled, out of the order, until the command returns or the
	 * element leaves. */
	bool retained;
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

struct owner_constraint {
    uint64_t owner;
    Clay_BoundingBox clip, border, content;
    bool clips, fits_border, clips_content;
};

struct render_state {
    struct owner_constraint *constraints;
    size_t constraints_len, constraints_cap;
    struct fade_value {uint64_t owner; uint32_t id; struct render_presentation pose; bool opened;} *fades;
    size_t fades_len, fades_cap;
    bool fades_prepared;
    struct fade_alias {uint64_t owner, ancestor; bool seen;} *fade_aliases;
    size_t fade_aliases_len, fade_aliases_cap;
    float fade_factor;
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
	/* Clip scopes persist through input, in command order. Their storage is
	 * reserved before reconciliation so scope pointers stay stable all frame. */
	struct clip_scope *scopes;
	size_t scopes_len, scopes_cap;
	/* Profiling readback: resident cairo raster bytes across all live
	 * nodes, and buffers allocated by the current reconcile pass. */
	size_t raster_bytes;
	int buffers_created;
	/* Scene nodes the current pass created and destroyed. */
	int created, swept;
	/* Nodes kept dark after the last sweep (rnode.retained). */
	size_t retained;
	bool shape_overflow_logged;
	bool mask_overflow_logged;
	bool clip_overflow_logged;
	/* A kind swap (a rect crossing a path edge) destroyed and recreated a
	 * node under an unchanged command key this pass. The recreated scene
	 * node was appended at the top of its sibling list, so the restack must
	 * run even though the command order is byte-identical. */
	bool node_recreated;
	/* The output's scale, driving device-pixel raster sizing. 1.0 is the
	 * identity: every device_len below reduces to the logical length, so a
	 * non-HiDPI output rasters exactly as before. */
	float scale;
};

static void shadow_cache_release(struct render_state *rs, struct shadow_cache *cache);

struct presentation_node {
    struct wlr_addon addon;
    struct wl_listener commit;
    struct wlr_scene_node *node;
    struct render_presentation pose;
    int x, y, width, height, parent_x, parent_y;
    int presented_parent_x, presented_parent_y;
    float radii[4], cutout_radii[4];
    struct wlr_box cutout;
    struct wlr_render_rounded_clip clips[WLR_SCENE_ROUNDED_CLIPS];
    size_t clips_len;
    bool applied, enabled;
};

static void presentation_destroy(struct wlr_addon *addon)
{
    struct presentation_node *p = wl_container_of(addon, p, addon);
    wl_list_remove(&p->commit.link);
    wlr_addon_finish(addon);
    free(p);
}

static const struct wlr_addon_interface presentation_impl = {
    .name = "somewm presentation", .destroy = presentation_destroy,
};

static struct presentation_node *presentation_node(struct wlr_scene_node *node)
{
    struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &presentation_impl);
    return addon ? wl_container_of(addon, (struct presentation_node *)NULL, addon) : NULL;
}

static struct wlr_box presentation_local_box(struct presentation_node *p, struct wlr_box box)
{
    Clay_BoundingBox b = render_present_box(p->pose, (Clay_BoundingBox){
        p->parent_x + p->x + box.x, p->parent_y + p->y + box.y, box.width, box.height});
    Clay_BoundingBox origin = render_present_box(p->pose, (Clay_BoundingBox){
        p->parent_x + p->x, p->parent_y + p->y, 0, 0});
    return (struct wlr_box){b.x - origin.x, b.y - origin.y, b.width, b.height};
}

static void presentation_apply(struct presentation_node *p)
{
    struct wlr_scene_node *node = p->node;
    Clay_BoundingBox b = render_present_box(p->pose, (Clay_BoundingBox){
        p->parent_x + p->x, p->parent_y + p->y, p->width, p->height});
    wlr_scene_node_set_position(node, b.x - p->presented_parent_x, b.y - p->presented_parent_y);
    bool visible = p->enabled && p->pose.scale > 0
        && (node->type == WLR_SCENE_NODE_TREE || (b.width > 0 && b.height > 0));
    wlr_scene_node_set_enabled(node, visible);
    float radii[4], cutout_radii[4];
    struct wlr_render_rounded_clip clips[WLR_SCENE_ROUNDED_CLIPS];
    for (int i = 0; i < 4; i++) {
        radii[i] = p->radii[i] * p->pose.scale;
        cutout_radii[i] = p->cutout_radii[i] * p->pose.scale;
    }
    for (size_t i = 0; i < p->clips_len; i++) {
        clips[i].box = presentation_local_box(p, p->clips[i].box);
        for (int j = 0; j < 4; j++) clips[i].radii[j] = p->clips[i].radii[j] * p->pose.scale;
    }
    if (node->type == WLR_SCENE_NODE_RECT) {
        struct wlr_scene_rect *rect = wlr_scene_rect_from_node(node);
        struct wlr_box cutout = presentation_local_box(p, p->cutout);
        if (p->cutout.width > 0) {
            int left = p->cutout.x > 0 ? MAX(1, lroundf(p->cutout.x * p->pose.scale)) : 0;
            int top = p->cutout.y > 0 ? MAX(1, lroundf(p->cutout.y * p->pose.scale)) : 0;
            int right = p->width - p->cutout.x - p->cutout.width;
            int bottom = p->height - p->cutout.y - p->cutout.height;
            right = right > 0 ? MAX(1, lroundf(right * p->pose.scale)) : 0;
            bottom = bottom > 0 ? MAX(1, lroundf(bottom * p->pose.scale)) : 0;
            cutout = (struct wlr_box){left, top, MAX(0, (int)b.width - left - right),
                MAX(0, (int)b.height - top - bottom)};
        }
        wlr_scene_rect_set_size(rect, b.width, b.height);
        wlr_scene_rect_set_corner_radii(rect, radii);
        wlr_scene_rect_set_cutout(rect, p->cutout.width ? &cutout : NULL, cutout_radii);
        wlr_scene_rect_set_rounded_clips(rect, clips, p->clips_len);
    } else if (node->type == WLR_SCENE_NODE_BUFFER) {
        struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
        if (b.width > 0 && b.height > 0) wlr_scene_buffer_set_dest_size(sb, b.width, b.height);
        wlr_scene_buffer_set_corner_radii(sb, radii);
        wlr_scene_buffer_set_rounded_clips(sb, clips, p->clips_len);
    }
    p->applied = true;
}

static void presentation_commit(struct wl_listener *listener, void *data)
{
    struct presentation_node *p = wl_container_of(listener, p, commit);
    if (!p->applied) return;
    struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(p->node);
    p->width = sb->dst_width;
    p->height = sb->dst_height;
    p->x = p->node->x;
    p->y = p->node->y;
    p->enabled = p->node->enabled;
    presentation_apply(p);
}

static void presentation_restore(struct wlr_scene_node *node)
{
    struct presentation_node *p = presentation_node(node);
    if (p && p->applied) {
        wlr_scene_node_set_position(node, p->x, p->y);
        wlr_scene_node_set_enabled(node, p->enabled);
        if (node->type == WLR_SCENE_NODE_RECT) {
            struct wlr_scene_rect *rect = wlr_scene_rect_from_node(node);
            wlr_scene_rect_set_size(rect, p->width, p->height);
            wlr_scene_rect_set_corner_radii(rect, p->radii);
            wlr_scene_rect_set_cutout(rect, p->cutout.width ? &p->cutout : NULL, p->cutout_radii);
            wlr_scene_rect_set_rounded_clips(rect, p->clips, p->clips_len);
        } else if (node->type == WLR_SCENE_NODE_BUFFER) {
            struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
            wlr_scene_buffer_set_dest_size(sb, p->width, p->height);
            wlr_scene_buffer_set_corner_radii(sb, p->radii);
            wlr_scene_buffer_set_rounded_clips(sb, p->clips, p->clips_len);
        }
        p->applied = false;
    }
    if (node->type == WLR_SCENE_NODE_TREE) {
        struct wlr_scene_node *child;
        wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
            presentation_restore(child);
    }
}

static void presentation_tree(struct wlr_scene_node *node, struct render_presentation pose,
        int parent_x, int parent_y, int presented_parent_x, int presented_parent_y,
        bool borrowed, bool root)
{
    int x = node->x, y = node->y;
    struct presentation_node *p = presentation_node(node);
    bool transform = !borrowed || root || node->type != WLR_SCENE_NODE_TREE;
    if (transform) {
        if (!p) {
            p = calloc(1, sizeof(*p));
            p->node = node;
            wl_list_init(&p->commit.link);
            wlr_addon_init(&p->addon, &node->addons, NULL, &presentation_impl);
            if (borrowed && node->type == WLR_SCENE_NODE_BUFFER) {
                struct wlr_scene_surface *surface = wlr_scene_surface_try_from_buffer(wlr_scene_buffer_from_node(node));
                if (surface) {
                    p->commit.notify = presentation_commit;
                    wl_signal_add(&surface->surface->events.commit, &p->commit);
                }
            }
        }
        p->pose = pose;
        p->x = x; p->y = y;
        p->parent_x = parent_x; p->parent_y = parent_y;
        p->presented_parent_x = presented_parent_x; p->presented_parent_y = presented_parent_y;
        p->enabled = node->enabled;
        if (node->type == WLR_SCENE_NODE_RECT) {
            struct wlr_scene_rect *rect = wlr_scene_rect_from_node(node);
            p->width = rect->width; p->height = rect->height;
            memcpy(p->radii, rect->corner_radii, sizeof(p->radii));
            p->cutout = rect->cutout_box;
            memcpy(p->cutout_radii, rect->cutout_radii, sizeof(p->cutout_radii));
            p->clips_len = rect->clips_len;
            memcpy(p->clips, rect->clips, sizeof(p->clips));
        } else if (node->type == WLR_SCENE_NODE_BUFFER) {
            struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
            p->width = sb->dst_width; p->height = sb->dst_height;
            memcpy(p->radii, sb->corner_radii, sizeof(p->radii));
            p->clips_len = sb->clips_len;
            memcpy(p->clips, sb->clips, sizeof(p->clips));
        }
        presentation_apply(p);
    }
    if (node->type == WLR_SCENE_NODE_TREE) {
        struct wlr_scene_node *child;
        wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
            presentation_tree(child, pose, parent_x + x, parent_y + y,
                presented_parent_x + node->x, presented_parent_y + node->y, borrowed, false);
    }
}

/* A node's scene pointer, read only after a borrowed tree resolves: a client
 * can die between frames, and then its tree is gone while the record still
 * holds the pointer (render.h). The record forgets it there. */
static struct wlr_scene_node *rnode_scene_node(struct rnode *n,
		const struct render_client_hooks *hooks) {
	if (n->borrowed && n->node != NULL && hooks->resolve(hooks->data, n->handle) == NULL)
		n->node = NULL;
	return n->node;
}

/* The retained node that drew a scene node: the hit node is the retained
 * node itself (rect, buffer) or a descendant of it (a square border's side
 * rect under its tree). */
static struct rnode *rnode_for_scene_node(struct render_state *rs,
		struct wlr_scene_node *node, const struct render_client_hooks *hooks) {
	if (node == NULL) {
		return NULL;
	}
	for (size_t i = 0; i < rs->len; i++) {
		struct rnode *n = &rs->nodes[i];
		if (rnode_scene_node(n, hooks) == NULL) {
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

void render_fades_begin(struct render_state *rs)
{
    rs->fades_len = 0;
    rs->fades_prepared = true;
}

struct render_presentation render_carrier_decode(Clay_Color color)
{
    if (color.a < 0 || color.a > 1 || color.r < 0 || color.g < 0 || color.b < 0
            || color.r > color.a + .00001f || color.g > color.a + .00001f
            || color.b > 5 * color.a + .00001f) {
        wlr_log(WLR_ERROR, "unsupported overlay tint");
        abort();
    }
    /* Clay rounds blue and alpha separately, so near rest b / a can pass 5. */
    return (struct render_presentation){
        .scale = color.r > 0 ? 1 - color.a : 1,
        .fade = color.g > 0 ? 1 - color.a : 1,
        .anchor = color.a > 0 ? lroundf(fminf(color.b / color.a, 5)) : 0,
    };
}

Clay_BoundingBox render_present_box(struct render_presentation p, Clay_BoundingBox b)
{
    float x = roundf(p.origin.x + p.scale * (b.x - p.origin.x));
    float y = roundf(p.origin.y + p.scale * (b.y - p.origin.y));
    return (Clay_BoundingBox){x, y,
        roundf(p.origin.x + p.scale * (b.x + b.width - p.origin.x)) - x,
        roundf(p.origin.y + p.scale * (b.y + b.height - p.origin.y)) - y};
}

bool render_unpresent(struct render_presentation p, double *x, double *y)
{
    if (p.scale <= 0) return false;
    *x = p.origin.x + (*x - p.origin.x) / p.scale;
    *y = p.origin.y + (*y - p.origin.y) / p.scale;
    return true;
}

static Clay_BoundingBox unpresent_box(struct render_presentation p, Clay_BoundingBox b)
{
    if (p.scale <= 0) return b;
    return (Clay_BoundingBox){p.origin.x + (b.x - p.origin.x) / p.scale,
        p.origin.y + (b.y - p.origin.y) / p.scale, b.width / p.scale, b.height / p.scale};
}

void render_fade_carrier(struct render_state *rs, const Clay_RenderCommand *cmd)
{
    Clay_Color color = cmd->renderData.overlayColor.color;
    struct render_presentation pose = render_carrier_decode(color);
    if (rs->fades_len == rs->fades_cap) {
        rs->fades_cap = rs->fades_cap ? rs->fades_cap * 2 : 8;
        p_realloc(&rs->fades, rs->fades_cap);
    }
    rs->fades[rs->fades_len++] = (struct fade_value){
        .owner = (uintptr_t)cmd->userData & RENDER_UD_OWNER_MASK, .id = cmd->id, .pose = pose};
}

static struct fade_value *fade_value(struct render_state *rs, uint32_t id)
{
    for (size_t i = 0; i < rs->fades_len; i++)
        if (rs->fades[i].id == id) return &rs->fades[i];
    return NULL;
}

void render_carrier_box(struct render_state *rs, uint32_t id, Clay_BoundingBox box)
{
    struct fade_value *v = fade_value(rs, id);
    if (!v) return;
    v->pose.origin = (Clay_Vector2){
        box.x + box.width * (v->pose.anchor == 4 ? 0 : v->pose.anchor == 5 ? 1 : .5f),
        box.y + box.height * (v->pose.anchor == 2 ? 0 : v->pose.anchor == 3 ? 1 : .5f)};
}

/* Floating titlebars and protocol popups use their frame's carrier through authored owner links. */
void render_fade_alias(struct render_state *rs, uint64_t owner, uint64_t ancestor)
{
    for (size_t i = 0; i < rs->fade_aliases_len; i++) {
        if (rs->fade_aliases[i].owner != owner) continue;
        rs->fade_aliases[i].ancestor = ancestor;
        return;
    }
    if (rs->fade_aliases_len == rs->fade_aliases_cap) {
        rs->fade_aliases_cap = rs->fade_aliases_cap ? rs->fade_aliases_cap * 2 : 8;
        p_realloc(&rs->fade_aliases, rs->fade_aliases_cap);
    }
    rs->fade_aliases[rs->fade_aliases_len++] = (struct fade_alias){.owner = owner, .ancestor = ancestor};
}

static float command_opacity(struct render_state *rs, const Clay_RenderCommand *cmd)
{
    return render_userdata_opacity(cmd->userData) * rs->fade_factor;
}

struct render_presentation render_owner_presentation(struct render_state *rs, uint64_t owner)
{
    if (!rs) return (struct render_presentation){.scale = 1, .fade = 1};
    for (size_t i = 0; i < rs->fades_len; i++)
        if (rs->fades[i].owner == owner && owner) return rs->fades[i].pose;
    for (size_t i = 0; i < rs->fade_aliases_len; i++)
        if (rs->fade_aliases[i].owner == owner) {
            rs->fade_aliases[i].seen = true;
            for (size_t j = 0; j < rs->fades_len; j++)
                if (rs->fades[j].owner == rs->fade_aliases[i].ancestor) return rs->fades[j].pose;
        }
    return (struct render_presentation){.scale = 1, .fade = 1};
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

void render_park(struct wlr_scene_node *node) {
	struct wlr_scene_tree *root = node->parent;
	while (root->node.parent != NULL)
		root = root->node.parent;
	wlr_scene_node_reparent(node, render_parked_tree(root));
	wlr_scene_node_set_enabled(node, false);
}

/* Surface commits and clip changes replace wlroots' buffer opacity. Keep
 * the declared value with each scene surface, including subsurfaces added
 * after the tree was borrowed. Scene destruction owns the listeners. */
struct surface_opacity {
	struct wlr_addon addon;
	struct wl_listener commit;
	struct wlr_scene_buffer *buffer;
	float value; /* Compositor multiplier, before the surface's alpha modifier. */
};

static void render_tree_set_opacity(struct wlr_scene_node *node, float opacity);

static void surface_opacity_destroy(struct wlr_addon *addon) {
	struct surface_opacity *p = wl_container_of(addon, p, addon);
	wl_list_remove(&p->commit.link);
	wlr_addon_finish(addon);
	free(p);
}

static const struct wlr_addon_interface surface_opacity_impl = {
	.name = "somewm surface opacity", .destroy = surface_opacity_destroy,
};

static void surface_opacity_commit(struct wl_listener *listener, void *data) {
	struct surface_opacity *p = wl_container_of(listener, p, commit);
	/* wlroots adds new subsurface scene nodes before emitting the parent's
	 * commit, and may also reconfigure existing child clips on that commit. */
	render_tree_set_opacity(&p->buffer->node.parent->node, p->value);
}

static void render_tree_set_opacity(struct wlr_scene_node *node, float opacity) {
	if (node->type == WLR_SCENE_NODE_BUFFER) {
		struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(node);
		struct wlr_scene_surface *surface = wlr_scene_surface_try_from_buffer(buffer);
		if (surface) {
			struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &surface_opacity_impl);
			struct surface_opacity *p = addon ? wl_container_of(addon, p, addon) : NULL;
			if (!p) {
				p = calloc(1, sizeof(*p));
				if (!p) abort();
				p->buffer = buffer;
				wlr_addon_init(&p->addon, &node->addons, NULL, &surface_opacity_impl);
				p->commit.notify = surface_opacity_commit;
				wl_signal_add(&surface->surface->events.commit, &p->commit);
			}
			p->value = opacity;
			const struct wlr_alpha_modifier_surface_v1_state *alpha =
				wlr_alpha_modifier_v1_get_surface_state(surface->surface);
			if (alpha) opacity *= alpha->multiplier;
		}
		wlr_scene_buffer_set_opacity(buffer, opacity);
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
        presentation_restore(n->node);
		render_park(n->node);
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
	if (idx == SIZE_MAX || !rs->nodes[idx].shadow || rs->nodes[idx].retained)
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
	n->presentation = (struct render_presentation){.scale = 1, .fade = 1};
	n->key = key;
	n->mask_scope = SIZE_MAX;
	return n;
}

/* The two-behavior sweep: nodes the renderer created are destroyed;
 * borrowed client trees are handed back through release, which reparents
 * and disables them (or no-ops if the client is already gone). The stored
 * pointer of a borrowed node is never dereferenced here. */
static void rnode_remove(struct render_state *rs, struct rnode *n,
		const struct render_client_hooks *hooks) {
	free(n->text);
	free(n->text_attrs);
	free(n->shape_ops);
	if (n->img_native)
		cairo_surface_destroy(n->img_native);
	if (n->img_vector)
		g_object_unref(n->img_vector);
	if (n->shadow)
		shadow_cache_release(rs, n->shadow);
	else
		rs->raster_bytes -= n->raster_bytes;
	if (n->borrowed) {
		render_release(rs, n, hooks);
	} else {
		if (n->node != NULL)
			rs->swept++;
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

void render_constraints_begin(struct render_state *rs) {
    rs->constraints_len = 0;
}

void render_constraint(struct render_state *rs, uint64_t owner,
        Clay_BoundingBox box, bool border) {
    struct owner_constraint *entry = NULL;
    for (size_t i = 0; i < rs->constraints_len; i++)
        if (rs->constraints[i].owner == owner) entry = &rs->constraints[i];
    if (!entry) {
        if (rs->constraints_len == rs->constraints_cap) {
            rs->constraints_cap = rs->constraints_cap ? rs->constraints_cap * 2 : 16;
            p_realloc(&rs->constraints, rs->constraints_cap);
        }
        entry = &rs->constraints[rs->constraints_len++];
        *entry = (struct owner_constraint){ .owner = owner };
    }
    if (border) {
        entry->border = entry->fits_border ? box_intersect(entry->border, box) : box;
        entry->fits_border = true;
    } else {
        entry->clip = entry->clips ? box_intersect(entry->clip, box) : box;
        entry->clips = true;
    }
}

static struct owner_constraint *owner_constraint(struct render_state *rs, void *word) {
    uint64_t owner = (uintptr_t)word & RENDER_UD_OWNER_MASK;
    for (size_t i = 0; i < rs->constraints_len; i++)
        if (rs->constraints[i].owner == owner) return &rs->constraints[i];
    return NULL;
}

/* Floating surfaces follow the frame's border in command order. Their drawn
 * size can lag behind the animated allocation, so keep their pixels inside
 * the fitted ring. Derive the inset before reconciling any command, without
 * changing the size sent to the client or clipping its separate popups. */
static void border_content_constraints(struct render_state *rs, Clay_RenderCommandArray commands) {
    for (size_t i = 0; i < rs->constraints_len; i++)
        rs->constraints[i].clips_content = false;
    for (int32_t i = 0; i < commands.length; i++) {
        Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&commands, i);
        if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_BORDER) continue;
        struct owner_constraint *constraint = owner_constraint(rs, cmd->userData);
        if (!constraint || !constraint->fits_border) continue;
        Clay_BoundingBox box = box_snap(box_intersect(cmd->boundingBox, constraint->border));
        Clay_BorderWidth bw = cmd->renderData.border.width;
        constraint->content = (Clay_BoundingBox){box.x + bw.left, box.y + bw.top,
            fmaxf(0, box.width - bw.left - bw.right), fmaxf(0, box.height - bw.top - bw.bottom)};
        constraint->clips_content = true;
    }
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
 * apply_clip_mask and buffer_apply_clip serve every rastered leaf (text,
 * image, shape path): a path mask is baked into the raster, which is then
 * cropped to its clip. A radius mask is never baked; it is a rounded clip on
 * the scene node (node_rounded_clips). */

static void shape_path(cairo_t *cr, const float *ops, size_t len);

static cairo_t *mask_context(const struct clip_mask *mask) {
	static cairo_t *cr;
	if (cr == NULL) {
		cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
		cr = cairo_create(surface);
		cairo_surface_destroy(surface);
	}
	cairo_new_path(cr);
	shape_path(cr, mask->ops, mask->len);
	return cr;
}

/* Whether a radius mask reaches box: the four corner squares are the only
 * places it differs from its own box, which already crops the node. */
static bool rounded_mask_hits(const struct clip_mask *m, Clay_BoundingBox b) {
	Clay_CornerRadius r = m->radii;
	Clay_BoundingBox corners[4] = {
		{ m->box.x, m->box.y, r.topLeft, r.topLeft },
		{ m->box.x + m->box.width - r.topRight, m->box.y, r.topRight, r.topRight },
		{ m->box.x, m->box.y + m->box.height - r.bottomLeft, r.bottomLeft, r.bottomLeft },
		{ m->box.x + m->box.width - r.bottomRight, m->box.y + m->box.height - r.bottomRight,
			r.bottomRight, r.bottomRight },
	};
	for (int i = 0; i < 4; i++) {
		Clay_BoundingBox c = corners[i];
		if (c.width > 0 && b.x < c.x + c.width && c.x < b.x + b.width &&
				b.y < c.y + c.height && c.y < b.y + b.height) {
			return true;
		}
	}
	return false;
}

/* Whether a path mask cuts box: a corner of the box lies outside the path. */
static bool path_masks_hit(const struct clip_masks *masks, Clay_BoundingBox box) {
	for (size_t i = 0; masks && i < masks->len; i++) {
		const struct clip_mask *m = &masks->items[i];
		if (!m->path)
			continue;
		cairo_t *cr = mask_context(m);
		double x = box.x - m->box.x, y = box.y - m->box.y;
		if (!cairo_in_fill(cr, x, y) ||
				!cairo_in_fill(cr, x + box.width, y) ||
				!cairo_in_fill(cr, x, y + box.height) ||
				!cairo_in_fill(cr, x + box.width, y + box.height))
			return true;
	}
	return false;
}

static bool corner_radius_zero(Clay_CornerRadius r) {
	return r.topLeft == 0 && r.topRight == 0 &&
		r.bottomLeft == 0 && r.bottomRight == 0;
}

/* Clay's radii in the order the scene takes them: top-left, top-right,
 * bottom-right, bottom-left. */
static void scene_radii(float out[4], Clay_CornerRadius r) {
	out[0] = r.topLeft;
	out[1] = r.topRight;
	out[2] = r.bottomRight;
	out[3] = r.bottomLeft;
}

/* Is (px,py) inside the rounded rect [x,y,w,h] with corner radii r? The shape
 * the scene draws, as a point predicate: inside the plain rect, and inside
 * the arc wherever a corner's radius square applies, the radii fitted to the
 * box by the edge rule the renderers use. Used by the geometric hit tests,
 * never a pixel read. */
static bool point_in_rounded_rect(double px, double py, double x, double y,
		double w, double h, Clay_CornerRadius r) {
	if (px < x || py < y || px >= x + w || py >= y + h) {
		return false;
	}
	float radii[4], fit[4];
	scene_radii(radii, r);
	wlr_render_fit_corner_radii(fit, radii, w, h);
	double tl = fit[0], tr = fit[1], br = fit[2], bl = fit[3];
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
		/* Unclipped, or clipped with no raster to crop (a shape with no
		 * fill or stroke): the footprint is still the realized box. */
		wlr_scene_buffer_set_source_box(sb, NULL);
		wlr_scene_buffer_set_dest_size(sb, (int)rbox.width, (int)rbox.height);
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
 * size, not zero). A move alone rewrites the same crop, which wlroots skips, so
 * only a changed source box or dest size counts. Shared by the text, image and
 * shape leaves so the three cannot drift apart. */
static int rnode_apply_clip(struct rnode *n, struct wlr_scene_buffer *sb,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox, float scale,
		bool raster_changed) {
	bool clip_changed = !box_pos_equal(n->rbox, rbox) ||
		!box_size_equal(n->rbox, rbox) ||
		!box_pos_equal(n->box, cmd->boundingBox) ||
		!box_size_equal(n->box, cmd->boundingBox);
	if ((raster_changed || clip_changed) && !box_empty(rbox)) {
		struct wlr_fbox src = sb->src_box;
		int dst_width = sb->dst_width, dst_height = sb->dst_height;
		buffer_apply_clip(sb, cmd, rbox, scale, n->raster_width, n->raster_height);
		return !raster_changed && (!wlr_fbox_equal(&src, &sb->src_box) ||
			dst_width != sb->dst_width || dst_height != sb->dst_height);
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

/* Bake every path mask into a raster. Buffer and mask origins use the same
 * device rounding as buffer_apply_clip. Restoring the matrix after appending
 * a path preserves the accumulated clip. */
static void apply_clip_mask(cairo_t *cr, Clay_BoundingBox box,
		const struct clip_masks *masks, float scale) {
	for (size_t i = 0; masks && i < masks->len; i++) {
		const struct clip_mask *m = &masks->items[i];
		if (!m->path)
			continue;
		int ox = (int)box.x, oy = (int)box.y;
		int mx = (int)m->box.x, my = (int)m->box.y;
		cairo_matrix_t matrix;
		cairo_get_matrix(cr, &matrix);
		cairo_translate(cr, device_len(ox, mx - ox, scale),
			device_len(oy, my - oy, scale));
		cairo_scale(cr, scale, scale);
		shape_path(cr, m->ops, m->len);
		cairo_set_matrix(cr, &matrix);
		cairo_clip(cr);
	}
}

static uint64_t mask_digest_bytes(uint64_t digest, const void *data, size_t len) {
	const unsigned char *bytes = data;
	for (size_t i = 0; i < len; i++) {
		digest ^= bytes[i];
		digest *= UINT64_C(1099511628211);
	}
	return digest;
}

/* Hash the path masks' explicit fields without struct padding or storage
 * addresses, cached once per scope: path generation and geometry determine
 * the pixels they bake. Radius masks are scene clips and key no raster. */
static uint64_t clip_masks_digest(const struct clip_masks *masks) {
	uint64_t digest = masks->paths ? UINT64_C(14695981039346656037) : 0;
	for (size_t i = 0; i < masks->len; i++) {
		const struct clip_mask *m = &masks->items[i];
		if (!m->path)
			continue;
		float geometry[] = { m->box.x, m->box.y, m->box.width, m->box.height };
		uint64_t identity[] = { m->key, m->gen, m->len };
		digest = mask_digest_bytes(digest, geometry, sizeof(geometry));
		digest = mask_digest_bytes(digest, identity, sizeof(identity));
	}
	return digest;
}

static bool clip_mask_changed(const struct rnode *n, const struct clip_masks *want) {
	return n->mask_digest != (want ? want->digest : 0);
}

static void clip_mask_keep(struct rnode *n, size_t scope, const struct clip_masks *want) {
	n->mask_scope = scope;
	n->mask_digest = want ? want->digest : 0;
}

/* A raster re-bakes its path masks when they change, and when it moves under
 * one: the path is drawn in buffer-local pixels. */
static bool path_masks_changed(const struct rnode *n,
		const struct clip_masks *masks, Clay_BoundingBox box) {
	return clip_mask_changed(n, masks) ||
		(masks && masks->paths && !box_pos_equal(n->box, box));
}

/* --- rounded clips ---
 *
 * The arcs of a radius mask, and a cropped node's own arcs, reach the scene
 * as rounded clips on the node: node-local boxes with radii the renderers cut
 * by, so a move, a resize or a crop under a rounded host rasters nothing. */

/* The rounded clips of a node realized at rbox, node-local, innermost first,
 * and the radii it carries as its own. An uncropped node takes own as its
 * own; a cropped one takes own as a clip at its solved box instead, so the
 * arcs stay where the solved box puts them. Then every radius mask whose
 * corner squares reach rbox, from the innermost. A fifth is dropped and
 * logged once. */
static size_t node_rounded_clips(struct render_state *rs, Clay_BoundingBox box,
		Clay_BoundingBox rbox, Clay_CornerRadius own,
		const struct clip_masks *masks, float radii[4],
		struct wlr_render_rounded_clip clips[WLR_SCENE_ROUNDED_CLIPS]) {
	size_t len = 0;
	memset(radii, 0, 4 * sizeof(*radii));
	if (!corner_radius_zero(own)) {
		if (box_pos_equal(box, rbox) && box_size_equal(box, rbox)) {
			scene_radii(radii, own);
		} else {
			clips[len].box = (struct wlr_box) { (int)box.x - (int)rbox.x,
				(int)box.y - (int)rbox.y, (int)box.width, (int)box.height };
			scene_radii(clips[len++].radii, own);
		}
	}
	for (size_t i = masks ? masks->len : 0; i > 0; i--) {
		const struct clip_mask *m = &masks->items[i - 1];
		if (m->path || !rounded_mask_hits(m, rbox))
			continue;
		if (len == WLR_SCENE_ROUNDED_CLIPS) {
			if (!rs->clip_overflow_logged) {
				wlr_log(WLR_ERROR, "node under more than %d rounded hosts; "
					"dropping the outer ones", WLR_SCENE_ROUNDED_CLIPS);
				rs->clip_overflow_logged = true;
			}
			break;
		}
		clips[len].box = (struct wlr_box) { (int)m->box.x - (int)rbox.x,
			(int)m->box.y - (int)rbox.y, (int)m->box.width, (int)m->box.height };
		scene_radii(clips[len++].radii, m->radii);
	}
	return len;
}

/* Apply the radii and clips a raster leaf at rbox carries to its buffer.
 * Counted once the node exists; a new node's are part of its creation. */
static int buffer_set_rounded(struct render_state *rs, struct wlr_scene_buffer *sb,
		Clay_BoundingBox box, Clay_BoundingBox rbox, Clay_CornerRadius own,
		const struct clip_masks *masks, bool is_new) {
	float radii[4];
	struct wlr_render_rounded_clip clips[WLR_SCENE_ROUNDED_CLIPS];
	size_t len = node_rounded_clips(rs, box, rbox, own, masks, radii, clips);
	int muts = 0;
	if (memcmp(sb->corner_radii, radii, sizeof(radii)) != 0) {
		wlr_scene_buffer_set_corner_radii(sb, radii);
		muts++;
	}
	if (sb->clips_len != len || memcmp(sb->clips, clips, len * sizeof(*clips)) != 0) {
		wlr_scene_buffer_set_rounded_clips(sb, clips, len);
		muts++;
	}
	return is_new ? 0 : muts;
}

/* --- rectangles and borders: one scene rect each ---
 *
 * A RECTANGLE is a scene rect with the command's radii; a BORDER is one with
 * the command's radii and a rounded hole inset by the four widths. Both crop
 * to their clip by shrinking (the colour is uniform), the radii of a cropped
 * one riding along as a clip at the solved box; the arcs of every rounded
 * host reaching the box are further clips. No raster, so a move or a resize
 * touches no pixels. A rect or border a path mask cuts rasters instead
 * (reconcile_rect_raster): a path is not a scene primitive. */

/* The box inset by the four widths, box-relative. Returns false when the
 * widths meet or cross: the whole box is ring. */
static bool border_hole(const Clay_RenderCommand *cmd, Clay_BoundingBox *hole) {
	Clay_BorderWidth bw = cmd->renderData.border.width;
	*hole = (Clay_BoundingBox){ bw.left, bw.top,
		cmd->boundingBox.width - bw.left - bw.right,
		cmd->boundingBox.height - bw.top - bw.bottom };
	return hole->width > 0 && hole->height > 0;
}

/* Each corner radius less the thicker of its two edges. The hit test, the
 * scene cutout and the raster all use it, so a click lands on the drawn ring. */
static Clay_CornerRadius inset_corner_radius(Clay_CornerRadius r,
		Clay_BorderWidth bw) {
	return (Clay_CornerRadius){
		fmax(0.0f, r.topLeft - fmaxf(bw.top, bw.left)),
		fmax(0.0f, r.topRight - fmaxf(bw.top, bw.right)),
		fmax(0.0f, r.bottomLeft - fmaxf(bw.bottom, bw.left)),
		fmax(0.0f, r.bottomRight - fmaxf(bw.bottom, bw.right)),
	};
}

static int reconcile_rect(struct render_state *rs, struct rnode *n,
		Clay_BoundingBox box, Clay_BoundingBox rbox, Clay_Color fill,
		float opacity, Clay_CornerRadius radii, const Clay_BoundingBox *hole,
		Clay_CornerRadius hole_radii, const struct clip_masks *masks) {
	float color[4];
	clay_color_to_float(fill, color);
	for (int i = 0; i < 4; i++)
		color[i] *= opacity;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_rect *rect = wlr_scene_rect_create(rs->tree,
			(int)rbox.width, (int)rbox.height, color);
		n->node = &rect->node;
		rs->created++;
		/* A kind swap creates this mid-frame, when the common placement
		 * pass no longer sees the node as new; place it now. */
		wlr_scene_node_set_position(n->node, (int)rbox.x, (int)rbox.y);
	}
	struct wlr_scene_rect *rect = wlr_scene_rect_from_node(n->node);
	if (rect->width != (int)rbox.width || rect->height != (int)rbox.height) {
		wlr_scene_rect_set_size(rect, (int)rbox.width, (int)rbox.height);
		muts++;
	}
	if (memcmp(rect->color, color, sizeof(color)) != 0) {
		wlr_scene_rect_set_color(rect, color);
		muts++;
	}

	float own[4];
	struct wlr_render_rounded_clip clips[WLR_SCENE_ROUNDED_CLIPS];
	size_t len = node_rounded_clips(rs, box, rbox, radii, masks, own, clips);
	if (memcmp(rect->corner_radii, own, sizeof(own)) != 0) {
		wlr_scene_rect_set_corner_radii(rect, own);
		muts++;
	}
	if (rect->clips_len != len || memcmp(rect->clips, clips, len * sizeof(*clips)) != 0) {
		wlr_scene_rect_set_rounded_clips(rect, clips, len);
		muts++;
	}

	struct wlr_box cutout = {0};
	float cutout_radii[4] = {0};
	if (hole != NULL) {
		cutout = (struct wlr_box) { (int)box.x + (int)hole->x - (int)rbox.x,
			(int)box.y + (int)hole->y - (int)rbox.y,
			(int)hole->width, (int)hole->height };
		scene_radii(cutout_radii, hole_radii);
	}
	if (!wlr_box_equal(&rect->cutout_box, &cutout) ||
			memcmp(rect->cutout_radii, cutout_radii, sizeof(cutout_radii)) != 0) {
		wlr_scene_rect_set_cutout(rect, hole != NULL ? &cutout : NULL, cutout_radii);
		muts++;
	}
	/* Creating the node is its one mutation, placement included. */
	return is_new ? 1 : muts;
}

/* Radii in scene order, fitted to the box as wlroots fits them. */
static void rounded_box_path(cairo_t *cr, double x, double y, double w, double h,
		const float radii[4]) {
	float r[4];
	wlr_render_fit_corner_radii(r, radii, w, h);
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r[1], y + r[1], r[1], -G_PI_2, 0);
	cairo_arc(cr, x + w - r[2], y + h - r[2], r[2], 0, G_PI_2);
	cairo_arc(cr, x + r[3], y + h - r[3], r[3], G_PI_2, G_PI);
	cairo_arc(cr, x + r[0], y + r[0], r[0], G_PI, 3 * G_PI_2);
	cairo_close_path(cr);
}

/* A RECTANGLE's fill or a BORDER's ring through its path masks, in device
 * pixels. The outer arcs are the buffer node's radii and are not drawn here. */
static struct cairo_buffer *rasterize_rect(Clay_RenderCommand *cmd, float scale,
		const struct clip_masks *mask) {
	bool border = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_BORDER;
	Clay_Color color = border ? cmd->renderData.border.color
		: cmd->renderData.rectangle.backgroundColor;
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1) {
		return NULL;
	}
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_mask(cr, cmd->boundingBox, mask, scale);
	/* Straight alpha as in rasterize_text; cairo premultiplies into ARGB32. */
	cairo_set_source_rgba(cr, clay_srgb(color.r), clay_srgb(color.g),
		clay_srgb(color.b), clay_srgb(color.a));
	cairo_paint(cr);
	Clay_BoundingBox hole;
	if (border && border_hole(cmd, &hole)) {
		/* Round the hole's device edges as wlroots rounds the cutout's
		 * (scale_length). At a fractional scale the ring is then as wide
		 * as an uncut border. */
		int ox = (int)cmd->boundingBox.x, oy = (int)cmd->boundingBox.y;
		int hx = (int)hole.x, hy = (int)hole.y;
		float radii[4];
		scene_radii(radii, inset_corner_radius(cmd->renderData.border.cornerRadius,
			cmd->renderData.border.width));
		for (int i = 0; i < 4; i++)
			radii[i] *= scale;
		cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
		rounded_box_path(cr, device_len(ox, hx, scale), device_len(oy, hy, scale),
			device_len(ox + hx, (int)hole.width, scale),
			device_len(oy + hy, (int)hole.height, scale), radii);
		cairo_fill(cr);
	}
	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

/* Whether the command changes what the raster bakes: a fill's color, or a
 * ring's color, widths and radii. */
static bool rect_raster_data_changed(const struct rnode *n,
		const Clay_RenderCommand *cmd) {
	if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_BORDER)
		return memcmp(&n->data.rectangle.backgroundColor,
			&cmd->renderData.rectangle.backgroundColor,
			sizeof(Clay_Color)) != 0;
	const Clay_BorderRenderData *old = &n->data.border, *bd = &cmd->renderData.border;
	return memcmp(&old->color, &bd->color, sizeof(bd->color)) != 0 ||
		memcmp(&old->cornerRadius, &bd->cornerRadius, sizeof(bd->cornerRadius)) != 0 ||
		old->width.left != bd->width.left || old->width.right != bd->width.right ||
		old->width.top != bd->width.top || old->width.bottom != bd->width.bottom;
}

/* A RECTANGLE or BORDER a path mask cuts: a scene buffer cropped to its clip.
 * Its own arcs are the buffer's radii and the rounded hosts' arcs its clips.
 * It re-rasters on a change of size, scale, baked data or path masks, so a
 * move under a path redraws it and a move under an arc does not. */
static int reconcile_rect_raster(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
	Clay_CornerRadius radii = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_BORDER
		? cmd->renderData.border.cornerRadius : cmd->renderData.rectangle.cornerRadius;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
		rs->created++;
		/* As in reconcile_rect, a kind swap creates this past the common
		 * placement pass. */
		wlr_scene_node_set_position(n->node, (int)rbox.x, (int)rbox.y);
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

	bool raster_changed = is_new ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		rect_raster_data_changed(n, cmd) ||
		path_masks_changed(n, mask, cmd->boundingBox);
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_rect(cmd, rs->scale, mask));
		n->raster_scale = rs->scale;
		muts++;
	}

	float opacity = command_opacity(rs, cmd);
	if (is_new || opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}

	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, sb, cmd->boundingBox, rbox, radii, mask, is_new);
	return muts;
}

/* Whether a rect rasters: true when a path mask cuts it. Every other rect,
 * rounded or not, is a scene rect. A rect that crosses a path edge changes
 * kind, so the old node is destroyed and the caller creates the new one. */
static bool rect_rasters(struct render_state *rs, struct rnode *n,
		Clay_BoundingBox rbox, const struct clip_masks *mask) {
	bool raster = path_masks_hit(mask, rbox);
	if (n->node != NULL) {
		enum wlr_scene_node_type want = raster ?
			WLR_SCENE_NODE_BUFFER : WLR_SCENE_NODE_RECT;
		if (n->node->type != want) {
			wlr_scene_node_destroy(n->node);
			rs->swept++;
			n->node = NULL;
			rs->raster_bytes -= n->raster_bytes;
			n->raster_bytes = 0;
			rs->node_recreated = true;
		}
	}
	return raster;
}

static int reconcile_rectangle(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
	Clay_RectangleRenderData *rd = &cmd->renderData.rectangle;
	return rect_rasters(rs, n, rbox, mask) ? reconcile_rect_raster(rs, n, cmd, rbox, mask)
		: reconcile_rect(rs, n, cmd->boundingBox, rbox, rd->backgroundColor,
			command_opacity(rs, cmd), rd->cornerRadius, NULL,
			(Clay_CornerRadius){0}, mask);
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
		rs->created++;
		return 1;
	}
	if (!box_size_equal(n->rbox, rbox)) {
		wlr_scene_rect_set_size(wlr_scene_rect_from_node(n->node),
			(int)rbox.width, (int)rbox.height);
		return 1;
	}
	return 0;
}

/* Whether a box-relative point lies on a border's ring: inside the outer
 * rounded rect and outside the inner inset one, the shape the scene rect
 * draws around its cutout. A click in the hole, or outside the arc of a
 * corner, falls through to the surface below, as Clay ranks it. The test
 * is geometric, in logical space; device scale never reaches it. */
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

/* A scene rect with a rounded hole (border_hole, inset_corner_radius), or
 * the ring's raster when a path mask cuts it. */
static int reconcile_border(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
	if (rect_rasters(rs, n, rbox, mask))
		return reconcile_rect_raster(rs, n, cmd, rbox, mask);
	Clay_BorderRenderData *bd = &cmd->renderData.border;
	Clay_BoundingBox hole;
	bool has_hole = border_hole(cmd, &hole);
	return reconcile_rect(rs, n, cmd->boundingBox, rbox, bd->color,
		command_opacity(rs, cmd), bd->cornerRadius, has_hole ? &hole : NULL,
		inset_corner_radius(bd->cornerRadius, bd->width), mask);
}

/* The map from a frame drawn unrotated into a (w, h) box: a point (x, y) of
 * the old frame lands at the point the transform's point map gives. */
static void transform_matrix(cairo_matrix_t *m, uint8_t t, double w, double h) {
	cairo_matrix_init_identity(m);
	switch (t) {
	case WL_OUTPUT_TRANSFORM_90:
		cairo_matrix_translate(m, 0, h);
		cairo_matrix_rotate(m, -G_PI_2);
		break;
	case WL_OUTPUT_TRANSFORM_180:
		cairo_matrix_translate(m, w, h);
		cairo_matrix_rotate(m, G_PI);
		break;
	case WL_OUTPUT_TRANSFORM_270:
		cairo_matrix_translate(m, w, 0);
		cairo_matrix_rotate(m, G_PI_2);
		break;
	case WL_OUTPUT_TRANSFORM_FLIPPED:
		cairo_matrix_translate(m, w, 0);
		cairo_matrix_scale(m, -1, 1);
		break;
	case WL_OUTPUT_TRANSFORM_FLIPPED_180:
		cairo_matrix_translate(m, 0, h);
		cairo_matrix_scale(m, 1, -1);
		break;
	}
}

static void apply_transform(cairo_t *cr, uint8_t t, double w, double h) {
	cairo_matrix_t m;
	transform_matrix(&m, t, w, h);
	cairo_transform(cr, &m);
}

static bool transform_turns(uint8_t t) {
	return t == WL_OUTPUT_TRANSFORM_90 || t == WL_OUTPUT_TRANSFORM_270;
}

/* --- text --- */

/* Pango's bound is relative to the original run, even when its left side is
 * cropped. Read the effective clip itself: intersecting it with the run and
 * then reconstructing its right edge can lose enough precision to turn a
 * fully contained run into an ellipsis. The run's box is realized
 * (box_snap) and the clip is solved, so quantize each edge at the device
 * scale and take the difference, as device_len does. A clip edge within
 * float noise of the run's own edge is the run's edge: Clay solves in
 * float32, and a solved edge a hair below a realized edge that sits on a
 * half pixel would otherwise round the other way. */
static int text_ellipsis_width(Clay_RenderCommand *cmd,
		const Clay_BoundingBox *clip, float scale) {
	if (clip == NULL ||
			((uintptr_t)cmd->userData & RENDER_TEXT_ELLIPSIZE) == 0) {
		return 0;
	}
	bool turn = transform_turns(render_font_transform(cmd->renderData.text.fontId));
	const Clay_BoundingBox *box = &cmd->boundingBox;
	double start = turn ? box->y : box->x;
	double end = start + (turn ? box->height : box->width);
	double clip_end = turn ? (double)clip->y + clip->height
		: (double)clip->x + clip->width;
	if (clip_end >= end - 1e-3)
		return 0;
	long origin = lround(start * scale);
	int natural = (int)(lround(end * scale) - origin);
	int bound = (int)(lround(clip_end * scale) - origin);
	return bound > 0 && bound < natural ? bound : 0;
}

static struct cairo_buffer *rasterize_text(Clay_RenderCommand *cmd, float scale,
		int max_width, const struct clip_masks *mask,
        const struct render_text_attr *attrs, size_t attrs_len) {
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
	PangoContext *context = render_text_context();
	PangoLayout *layout = pango_layout_new(context);
	g_object_unref(context);
	render_set_text(layout, td->stringContents.chars,
		td->stringContents.length, td->fontId, td->fontSize, scale, 0);
	int natural_width, natural_height;
	pango_layout_get_pixel_size(layout, &natural_width, &natural_height);
	uint8_t t = render_font_transform(td->fontId);
	if (transform_turns(t)) {
		int swap = natural_width;
		natural_width = natural_height;
		natural_height = swap;
	}
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
	apply_clip_mask(cr, cmd->boundingBox, mask, scale);
	/* Cairo takes straight alpha here, so no premultiply. */
	cairo_set_source_rgba(cr,
		clay_srgb(td->textColor.r), clay_srgb(td->textColor.g),
		clay_srgb(td->textColor.b), clay_srgb(td->textColor.a));

    PangoAttrList *list = pango_attr_list_new();
    for (size_t i = 0; i < attrs_len; i++) {
        const struct render_text_attr *a = &attrs[i];
        PangoAttribute *attr = NULL;
        switch (a->kind) {
        case RENDER_TEXT_FOREGROUND:
            attr = pango_attr_foreground_new(lroundf(a->value[0] * 65535),
                lroundf(a->value[1] * 65535), lroundf(a->value[2] * 65535));
            break;
        case RENDER_TEXT_FOREGROUND_ALPHA:
            attr = pango_attr_foreground_alpha_new(lroundf(a->value[0] * 65535));
            break;
        case RENDER_TEXT_BACKGROUND:
            attr = pango_attr_background_new(lroundf(a->value[0] * 65535),
                lroundf(a->value[1] * 65535), lroundf(a->value[2] * 65535));
            break;
        case RENDER_TEXT_BACKGROUND_ALPHA:
            attr = pango_attr_background_alpha_new(lroundf(a->value[0] * 65535));
            break;
        case RENDER_TEXT_UNDERLINE:
            attr = pango_attr_underline_new((PangoUnderline)a->value[0]);
            break;
        case RENDER_TEXT_STRIKETHROUGH:
            attr = pango_attr_strikethrough_new(a->value[0] != 0);
            break;
        }
        if (attr) {
            attr->start_index = a->start;
            attr->end_index = a->end;
            pango_attr_list_insert(list, attr);
        }
    }
    pango_layout_set_attributes(layout, list);
    pango_attr_list_unref(list);

	/* Device-sized glyphs, as measured by render_measure_text; no CTM scaling. */
	apply_transform(cr, t, width, height);
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

/* Clips a's byte range to [off, end) and makes it relative to off. False
 * when nothing of it lies on that line. */
static bool line_attr(struct render_text_attr *a, uint32_t off, uint32_t end) {
	if (a->end <= off || a->start >= end) return false;
	a->start = MAX(a->start, off) - off;
	a->end = MIN(a->end, end) - off;
	return true;
}

/* Field by field: a struct copy need not keep its padding, so memcmp could
 * report every frame as a change and re-raster the line. */
static bool attr_equal(const struct render_text_attr *a, const struct render_text_attr *b) {
	return a->start == b->start && a->end == b->end && a->kind == b->kind &&
		memcmp(a->value, b->value, sizeof(a->value)) == 0;
}

static int reconcile_text(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const Clay_BoundingBox *clip, const struct clip_masks *mask,
        const struct render_client_hooks *hooks) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int muts = 0;

	/* Clay emits a line of length -1 when a word wider than its box is
	 * followed by a space and a newline (clay.h:2614-2615). It is an empty
	 * line: nothing reads the slice, and its box is -spaceWidth wide, so
	 * the node stays hidden below. */
	if (td->stringContents.length < 0) {
		if (n->node == NULL) {
			n->node = &wlr_scene_buffer_create(rs->tree, NULL)->node;
			rs->created++;
		}
		return 0;
	}

    /* Clay emits one command per line, a slice of the element's string
     * (clay.h:2995). The hook's ranges index the whole string; the node keeps
     * them clipped to this line and relative to its first byte. Compare first
     * and copy only on change, so an unchanged line allocates nothing. */
    const struct render_text_attr *attrs = NULL;
    size_t attrs_len = hooks && hooks->text_attrs
        ? hooks->text_attrs(hooks->data, cmd->userData, td->stringContents.baseChars, &attrs) : 0;
    uint32_t off = (uint32_t)(td->stringContents.chars - td->stringContents.baseChars);
    uint32_t end = off + (uint32_t)td->stringContents.length;
    size_t line_len = 0;
    bool attrs_changed = false;
    for (size_t i = 0; i < attrs_len; i++) {
        struct render_text_attr a = attrs[i];
        if (!line_attr(&a, off, end)) continue;
        attrs_changed |= line_len >= n->text_attrs_len
            || !attr_equal(&n->text_attrs[line_len], &a);
        line_len++;
    }
    attrs_changed |= line_len != n->text_attrs_len;
    if (attrs_changed) {
        free(n->text_attrs);
        n->text_attrs = line_len ? malloc(line_len * sizeof(*attrs)) : NULL;
        n->text_attrs_len = 0;
        for (size_t i = 0; n->text_attrs && i < attrs_len; i++) {
            struct render_text_attr a = attrs[i];
            if (line_attr(&a, off, end)) n->text_attrs[n->text_attrs_len++] = a;
        }
    }

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
		rs->created++;
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
	bool raster_changed = content_changed || attrs_changed ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		n->text_ellipsis != ell ||
		!text_data_equal(&n->data.text, td) ||
		path_masks_changed(n, mask, cmd->boundingBox);
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);
	if (raster_changed) {
		rnode_set_raster(rs, n, sb, rasterize_text(cmd, rs->scale, ell, mask,
            n->text_attrs, n->text_attrs_len));
		n->raster_scale = rs->scale;
		n->text_ellipsis = ell;
		muts++;
	}

	float opacity = command_opacity(rs, cmd);
	if (opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}

	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, sb, cmd->boundingBox, rbox,
		(Clay_CornerRadius){0}, mask, is_new);

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
 * An image entry (render_image.h) holds a cairo surface or RsvgHandle. The image
 * rasters per node into a box-sized buffer: cairo scales the surface or librsvg
 * decodes the document into the solved box; its corner radii are the buffer
 * node's. This mirrors reconcile_text (raster on change, then crop to the
 * clip), so an image clips inside a scroll container for free.
 *
 * The colour an image command carries is a STENCIL here: the ink replaces the
 * decoded pixels and only their alpha survives. Clay carries the colour and
 * leaves the interpretation to the renderer, so this is a choice, and the
 * reason for it is that the case worth having is inking a glyph whose own
 * colour is arbitrary. Scaling each channel by the ink instead would preserve
 * the file's shading but could only ever darken, which cannot ink a dark glyph
 * at all. A zero-alpha ink never arrives: the solver stores no colour for it. */

static struct cairo_buffer *rasterize_image(Clay_RenderCommand *cmd,
		struct image_entry *entry, float scale, const struct clip_masks *mask) {
	bool turn = transform_turns(entry->transform);
	int w = entry->stretch ? (int)ceilf((turn ? entry->height : entry->width) * scale)
		: device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = entry->stretch ? (int)ceilf((turn ? entry->width : entry->height) * scale)
		: device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (w < 1 || h < 1 || entry->width < 1 || entry->height < 1) {
		return NULL;
	}
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL) {
		return NULL;
	}
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_mask(cr, cmd->boundingBox, mask, scale);

	/* w and h are device pixels. Natural images scale only by the output
	 * scale; other images scale to fill the box. */
	/* The frame the image is painted into, before the transform turns it. */
	apply_transform(cr, entry->transform, w, h);
	int fw = turn ? h : w, fh = turn ? w : h;
	Clay_Color ink = cmd->renderData.image.backgroundColor;
	if (entry->vector) {
		double sx = entry->natural || entry->stretch ? scale : (double)fw / entry->width;
		double sy = entry->natural || entry->stretch ? scale : (double)fh / entry->height;
		RsvgRectangle viewport = { -entry->src_x * sx, -entry->src_y * sy,
			entry->width * sx, entry->height * sy };
		if (ink.a > 0)
			cairo_push_group(cr);
		rsvg_handle_render_document(entry->vector, cr, &viewport, NULL);
		if (ink.a > 0) {
			cairo_pattern_t *pattern = cairo_pop_group(cr);
			cairo_set_source_rgba(cr, clay_srgb(ink.r), clay_srgb(ink.g),
				clay_srgb(ink.b), clay_srgb(ink.a));
			cairo_mask(cr, pattern);
			cairo_pattern_destroy(pattern);
		}
	} else {
		if (entry->natural || entry->stretch)
			cairo_scale(cr, scale, scale);
		else
			cairo_scale(cr, (double)fw / entry->width, (double)fh / entry->height);
		cairo_pattern_t *pattern = cairo_pattern_create_for_surface(entry->native);
		/* Pattern matrices map into source coordinates: this places the source
		 * at -src_x,-src_y in logical pixels, before the output scale. */
		cairo_matrix_t matrix;
		cairo_matrix_init_translate(&matrix, entry->src_x, entry->src_y);
		cairo_pattern_set_matrix(pattern, &matrix);
		if (entry->filter > 0)
			cairo_pattern_set_filter(pattern, entry->filter - 1);
		if (ink.a > 0) {
			cairo_set_source_rgba(cr, clay_srgb(ink.r), clay_srgb(ink.g),
				clay_srgb(ink.b), clay_srgb(ink.a));
			cairo_mask(cr, pattern);
		} else {
			cairo_set_source(cr, pattern);
			cairo_paint(cr);
		}
		cairo_pattern_destroy(pattern);
	}

	cairo_destroy(cr);
	cairo_surface_flush(cb->surface);
	return cb;
}

/* Band-local points and raster clips use the same host-local mask geometry. */
static bool point_in_masks(const struct clip_masks *masks, double x, double y) {
	for (size_t i = 0; masks && i < masks->len; i++) {
		const struct clip_mask *m = &masks->items[i];
		double mx = x - m->box.x, my = y - m->box.y;
		if (m->path) {
			if (!cairo_in_fill(mask_context(m), mx, my)) return false;
		} else {
			if (!point_in_rounded_rect(mx, my, 0, 0, m->box.width, m->box.height, m->radii))
				return false;
		}
	}
	return true;
}

static const struct clip_masks *rnode_masks(struct render_state *rs, const struct rnode *n) {
	return n->mask_scope == SIZE_MAX ? NULL : &rs->scopes[n->mask_scope].masks;
}

/* Input intersects inherited masks, then the node's own corners: a
 * rectangle's, or a CUSTOM node's (a client surface cut by its radii).
 * Scene-local coordinates start at the cropped box. */
static bool rnode_point_in_arcs(struct render_state *rs, struct rnode *n,
		double sx, double sy) {
	if (!point_in_masks(rnode_masks(rs, n), sx + n->rbox.x, sy + n->rbox.y)) return false;
	uint32_t type = (uint32_t)(n->key >> 32);
	if (type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE || type == CLAY_RENDER_COMMAND_TYPE_CUSTOM) {
		return point_in_rounded_rect(sx + n->rbox.x - n->box.x,
			sy + n->rbox.y - n->box.y, 0, 0, n->box.width,
			n->box.height, type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE
				? n->data.rectangle.cornerRadius : n->data.custom.cornerRadius);
	}
	return true;
}

static int reconcile_image(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
	struct image_entry *entry =
		(struct image_entry *)cmd->renderData.image.imageData;
	int muts = 0;

	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
		rs->created++;
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);

	/* An entry with no source shows nothing. */
	bool usable = entry != NULL && (entry->native != NULL || entry->vector != NULL);
	bool raster_changed = is_new ||
		((!entry || !entry->stretch)
			&& !raster_size_equal(n->box, cmd->boundingBox, rs->scale)) ||
		n->raster_scale != rs->scale ||
		memcmp(&n->data.image.backgroundColor, &cmd->renderData.image.backgroundColor,
			sizeof(Clay_Color)) != 0 ||
		(usable ? entry->native : NULL) != n->img_native ||
		(usable ? entry->vector : NULL) != n->img_vector ||
		(usable && (entry->gen != n->img_gen
			|| entry->src_x != n->img_src_x || entry->src_y != n->img_src_y
			|| entry->width != n->img_width || entry->height != n->img_height
			|| entry->filter != n->img_filter || entry->stretch != n->img_stretch
			|| entry->natural != n->img_natural
			|| entry->transform != n->img_transform)) ||
		path_masks_changed(n, mask, cmd->boundingBox);

	if (raster_changed) {
		rnode_set_raster(rs, n, sb,
			usable ? rasterize_image(cmd, entry, rs->scale, mask) : NULL);
		/* Hold the source so its address cannot be reused while cached.
		 * This makes pointer identity lifetime-safe without an ID counter. */
		cairo_surface_t *native = usable && entry->native
			? cairo_surface_reference(entry->native) : NULL;
		void *vector = usable && entry->vector ? g_object_ref(entry->vector) : NULL;
		if (n->img_native)
			cairo_surface_destroy(n->img_native);
		if (n->img_vector)
			g_object_unref(n->img_vector);
		n->img_vector = vector;
		n->img_native = native;
		n->img_gen = usable ? entry->gen : 0;
		n->img_src_x = usable ? entry->src_x : 0;
		n->img_src_y = usable ? entry->src_y : 0;
		n->img_width = usable ? entry->width : 0;
		n->img_height = usable ? entry->height : 0;
		n->img_filter = usable ? entry->filter : 0;
		n->img_stretch = usable && entry->stretch;
		n->img_natural = usable && entry->natural;
		n->img_transform = usable ? entry->transform : 0;
		n->raster_scale = rs->scale;
		muts++;
	}

	float opacity = command_opacity(rs, cmd);
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
	muts += buffer_set_rounded(rs, sb, cmd->boundingBox, rbox,
		cmd->renderData.image.cornerRadius, mask, is_new);
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
		float scale, const struct clip_masks *mask) {
	int w = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int h = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (len == 0 || w < 1 || h < 1
			|| (!shape->gradient.kind && shape->fill[3] <= 0
				&& (shape->stroke[3] <= 0 || shape->stroke_width <= 0)))
		return NULL;
	struct cairo_buffer *cb = cairo_buffer_create(w, h);
	if (cb == NULL)
		return NULL;
	cairo_t *cr = cairo_create(cb->surface);
	apply_clip_mask(cr, cmd->boundingBox, mask, scale);
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
		/* The points were authored in the unrotated box. */
		cairo_matrix_t m;
		transform_matrix(&m, shape->transform, cmd->boundingBox.width,
			cmd->boundingBox.height);
		cairo_matrix_invert(&m);
		cairo_pattern_set_matrix(pattern, &m);
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
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox)
{
	const struct render_shadow *style = render_shadow_of(cmd->renderData.custom.customData);
	bool fresh = n->node == NULL;
    float opacity = command_opacity(rs, cmd);
    bool opacity_changed = opacity != n->opacity;
	bool changed = fresh || n->raster_scale != rs->scale
		|| n->shadow->style.radius != style->radius
		|| n->shadow->style.corner_radius != style->corner_radius
		|| memcmp(n->shadow->style.rgba, style->rgba, sizeof(style->rgba));
	int muts = 0;
	if (fresh) {
		struct wlr_scene_tree *tree = wlr_scene_tree_create(rs->tree);
		n->node = &tree->node;
		rs->created++;
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
		muts++;
	}
    if (changed || opacity_changed) {
        float color[4] = {style->rgba[0] * style->rgba[3] * opacity,
            style->rgba[1] * style->rgba[3] * opacity, style->rgba[2] * style->rgba[3] * opacity,
            style->rgba[3] * opacity};
        for (int i = 0; i < SHADOW_FILL_COUNT; i++)
            wlr_scene_rect_set_color(n->shadow_fills[i], color);
        if (!changed) muts++;
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
        Clay_BoundingBox full = {cmd->boundingBox.x + b[0], cmd->boundingBox.y + b[1], b[2], b[3]};
        Clay_BoundingBox cut = box_intersect(full, rbox);
        int px = (int)(cut.x - rbox.x), py = (int)(cut.y - rbox.y);
        bool show = fits && !box_empty(cut) && (!tile || n->shadow->tiles[i]);
		if (node->enabled != show) {
			wlr_scene_node_set_enabled(node, show);
			muts++;
		}
		if (!show)
			continue;
        if (node->x != px || node->y != py) {
            wlr_scene_node_set_position(node, px, py);
			muts++;
		}
		if (tile) {
			struct wlr_scene_buffer *sb = n->shadow_tiles[i];
            if (opacity_changed) wlr_scene_buffer_set_opacity(sb, opacity);
            if (changed || !box_pos_equal(n->box, cmd->boundingBox)
                    || !box_size_equal(n->box, cmd->boundingBox)
                    || !box_pos_equal(n->rbox, rbox) || !box_size_equal(n->rbox, rbox)) {
                Clay_RenderCommand tile_cmd = {.boundingBox = full};
                struct cairo_buffer *raster = n->shadow->tiles[i];
                buffer_apply_clip(sb, &tile_cmd, cut, rs->scale,
                    raster->base.width, raster->base.height);
                muts++;
            }
		} else {
			struct wlr_scene_rect *rect = n->shadow_fills[i-SHADOW_SLICE_COUNT];
            if (rect->width != (int)cut.width || rect->height != (int)cut.height) {
                wlr_scene_rect_set_size(rect, (int)cut.width, (int)cut.height);
				muts++;
			}
		}
	}
    n->opacity = opacity;
	return muts;
}

static int reconcile_shape(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask, const struct render_client_hooks *hooks) {
	static float ops[4096];
	struct render_shape *shape = render_shape_of(cmd->renderData.custom.customData);
	/* Lua may run in the hook: all raster inputs are copied before it. */
	struct render_shape value = *shape;
	int muts = 0;
	bool is_new = n->node == NULL;
	if (is_new) {
		struct wlr_scene_buffer *sb = wlr_scene_buffer_create(rs->tree, NULL);
		n->node = &sb->node;
		rs->created++;
	}
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(n->node);
	bool raster_changed = is_new ||
		!box_size_equal(n->box, cmd->boundingBox) ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		n->data.custom.customData != cmd->renderData.custom.customData ||
		n->shape.gen != value.gen ||
		memcmp(&n->shape.gradient, &value.gradient, sizeof(value.gradient)) != 0 ||
		memcmp(n->shape.fill, value.fill, sizeof(value.fill)) != 0 ||
		memcmp(n->shape.stroke, value.stroke, sizeof(value.stroke)) != 0 ||
		memcmp(&n->shape.stroke_width, &value.stroke_width, sizeof(value.stroke_width)) != 0 ||
		path_masks_changed(n, mask, cmd->boundingBox);
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
		muts++;
	}
	float opacity = command_opacity(rs, cmd);
	if (opacity != n->opacity) {
		wlr_scene_buffer_set_opacity(sb, opacity);
		n->opacity = opacity;
		if (!is_new)
			muts++;
	}
	muts += rnode_apply_clip(n, sb, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, sb, cmd->boundingBox, rbox,
		(Clay_CornerRadius){0}, mask, is_new);
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
	uint64_t data = (uint64_t)(uintptr_t)cmd->renderData.custom.customData;
	uint64_t handle = data & ~RENDER_PROBED_TAG;
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
	float opacity = command_opacity(rs, cmd);
	bool first_borrow = n->node == NULL;
	bool surface_changed = first_borrow;
	if (first_borrow) {
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

	/* Beside a probe the surface is drawn at the size it committed; the
	 * probe sends the configure. */
	if (!(data & RENDER_PROBED_TAG) && !box_size_equal(n->box, cmd->boundingBox)) {
		hooks->configure(hooks->data, handle,
			(int)cmd->boundingBox.width, (int)cmd->boundingBox.height);
		surface_changed = true;
		muts++;
	}
	struct wlr_box clip = surface_clip_box(cmd->boundingBox, rbox);
	struct wlr_box previous_clip = surface_clip_box(n->box, n->rbox);
	if (hooks->clip != NULL && (first_borrow || !wlr_box_equal(&clip, &previous_clip))) {
		hooks->clip(hooks->data, handle, clip.x, clip.y, clip.width, clip.height);
		surface_changed = true;
		muts++;
	}
	Clay_CornerRadius radius = cmd->renderData.custom.cornerRadius;
	if (hooks->corners != NULL && (first_borrow ||
			memcmp(&radius, &n->data.custom.cornerRadius, sizeof(radius)) != 0)) {
		hooks->corners(hooks->data, handle, (const float[4]) { radius.topLeft,
			radius.topRight, radius.bottomRight, radius.bottomLeft });
		surface_changed = true;
		muts++;
	}
	if (surface_changed || opacity != n->opacity) {
		render_tree_set_opacity(n->node, opacity);
		n->opacity = opacity;
		if (!first_borrow) muts++;
	}
	return muts;
}

/* A configure probe (render.h): no node and nothing borrowed, only the
 * configure leg, when its solved size changed. */
static int reconcile_probe(struct rnode *n, Clay_RenderCommand *cmd,
		const struct render_client_hooks *hooks) {
	if (box_size_equal(n->box, cmd->boundingBox))
		return 0;
	hooks->configure(hooks->data,
		(uint64_t)(uintptr_t)cmd->renderData.custom.customData & ~RENDER_PROBE_TAG,
		(int)cmd->boundingBox.width, (int)cmd->boundingBox.height);
	return 1;
}

/* Whether node is one kept dark for an element still in the tree. */
static bool scene_node_retained(struct render_state *rs,
		struct wlr_scene_node *node) {
	if (rs->retained == 0 || node->enabled)
		return false;
	for (size_t i = 0; i < rs->len; i++)
		if (rs->nodes[i].retained && rs->nodes[i].node == node)
			return true;
	return false;
}

/* The sibling link under node, past any node kept dark. */
static struct wl_list *placed_below(struct render_state *rs,
		struct wlr_scene_node *node) {
	struct wl_list *at = node->link.prev;
	while (at != &rs->tree->children) {
		struct wlr_scene_node *sib = wl_container_of(at, sib, link);
		if (!scene_node_retained(rs, sib))
			break;
		at = at->prev;
	}
	return at;
}

/* --- tree==scene: every solved box must match the scene, every frame --- */

/* Whether the scene disagrees with what the command solved: a node placed or
 * sized somewhere other than its realized box, one drawing outside its
 * innermost scissor scope, or one enabled when it clipped away (an empty rbox
 * is the only case where a declared node may be off). The verifier below
 * aborts on it; the tree dump prints it, so a release build without the
 * verifier still reports the divergence rather than drawing it silently. */
static bool rnode_scene_mismatch(const struct rnode *original) {
    struct rnode transformed = *original;
    transformed.box = render_present_box(original->presentation, original->box);
    transformed.rbox = render_present_box(original->presentation, original->rbox);
    transformed.clip = render_present_box(original->presentation, original->clip);
    const struct rnode *n = &transformed;
	if (n->node == NULL || n->retained) {
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
	 * realized box (buffer_apply_clip), so it is comparable too. A place-leaf's
	 * node is a borrowed client tree, which carries no size of its own. */
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
	static const char *const types[] = { "tree", "rect", "buffer" };
	int w = -1, h = -1;
	if (n->node->type == WLR_SCENE_NODE_RECT) {
		w = wlr_scene_rect_from_node(n->node)->width;
		h = wlr_scene_rect_from_node(n->node)->height;
	} else if (n->node->type == WLR_SCENE_NODE_BUFFER) {
		w = wlr_scene_buffer_from_node(n->node)->dst_width;
		h = wlr_scene_buffer_from_node(n->node)->dst_height;
	}
	fprintf(stderr, "tree==scene: key %" PRIx64 " %s %s%s at %d,%d size %dx%d "
		"but realized box says %d,%d %dx%d inside clip %d,%d %dx%d\n",
		n->key, n->node->enabled ? "enabled" : "disabled",
		types[n->node->type], n->borrowed ? " borrowed" : "",
		n->node->x, n->node->y, w, h,
		(int)n->rbox.x, (int)n->rbox.y,
		(int)n->rbox.width, (int)n->rbox.height,
		(int)n->clip.x, (int)n->clip.y,
		(int)n->clip.width, (int)n->clip.height);
	abort();
}

#endif /* SOMEWM_RENDER_VERIFY */

#ifdef SOMEWM_RENDER_VERIFY

/* Check 1 of the agreement invariant: scene sibling order equals retained
 * paint order. The restack places each command's node directly above the one
 * before it, so a forward walk of the children list (bottom to top) must visit
 * exactly the nodes rs->order names, in the same sequence, skipping commands
 * that realized no node (SCISSOR markers, dead surfaces). A missed placement
 * reorders a sibling and aborts here. Runs after the restack, when the map is
 * valid. */
static void verify_order(struct render_state *rs) {
	struct wlr_scene_node *child;
	size_t oi = 0;
	wl_list_for_each(child, &rs->tree->children, link) {
		if (scene_node_retained(rs, child))
			continue;
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

void *render_hit_userdata(struct render_state *rs, struct wlr_scene_node *node,
		const struct render_client_hooks *hooks) {
	struct rnode *n = rnode_for_scene_node(rs, node, hooks);
	return n != NULL ? n->user_data : NULL;
}

/* --- the reconcile pass --- */

/* The scope a command's word names (render.h), or NULL when none was opened.
 * Scan from the newest: children follow the command that opened their scope. */
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

/* At most one scope opens per command; reconciliation reserves them all. */
static void scope_open(struct render_state *rs, void *word, Clay_BoundingBox rbox,
		const struct clip_scope *under, struct clip_mask own) {
	unsigned opens = render_userdata_byte(word, RENDER_UD_OPENS_SHIFT);
	if (opens == 0) return;
	assert(rs->scopes_len < rs->scopes_cap);
	struct clip_scope *sc = &rs->scopes[rs->scopes_len++];
	sc->owner = (uintptr_t)word & RENDER_UD_OWNER_MASK;
	sc->number = opens;
	sc->box = rbox;
	sc->masks = under ? under->masks : (struct clip_masks){0};
	if (own.path || !corner_radius_zero(own.radii)) {
		if (sc->masks.len < CLIP_MASKS_MAX) {
			sc->masks.items[sc->masks.len++] = own;
			sc->masks.paths += own.path;
			sc->masks.digest = clip_masks_digest(&sc->masks);
		} else if (!rs->mask_overflow_logged) {
			wlr_log(WLR_ERROR, "clip scope exceeds %d shaped masks; retaining outer masks",
				CLIP_MASKS_MAX);
			rs->mask_overflow_logged = true;
		}
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

/* IMAGE covers the cursor, which every output declares; leaving it out
 * kept the batch from ever engaging on a real screen. The buffer-listener
 * check in scene_visibility_quiet is what guards a toggle, not the type. */
static bool batch_command_type(uint32_t type) {
    return type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE ||
        type == CLAY_RENDER_COMMAND_TYPE_IMAGE ||
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
    bool border = false,
        changed = (size_t)commands.length != rs->len - rs->retained;
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
	border_content_constraints(rs, commands);
	rs->gen++;
	rs->buffers_created = 0;
	rs->created = 0;
	rs->swept = 0;
	rs->visibility_batched = false;
	rs->node_recreated = false;
	rs->scopes_len = 0;
	if (!rs->fades_prepared) rs->fades_len = 0;
	rs->fades_prepared = false;
	rs->fade_factor = 1;
	for (size_t i = 0; i < rs->fade_aliases_len; i++) rs->fade_aliases[i].seen = false;
	if ((size_t)commands.length > rs->scopes_cap) {
		rs->scopes_cap = commands.length;
		p_realloc(&rs->scopes, rs->scopes_cap);
	}
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
		if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START) {
			struct fade_value *value = fade_value(rs, cmd->id);
			if (!value) {
				render_fade_carrier(rs, cmd);
				value = &rs->fades[rs->fades_len - 1];
			}
			value->opened = true;
		}
		struct render_presentation presentation = render_owner_presentation(rs,
			(uintptr_t)cmd->userData & RENDER_UD_OWNER_MASK);
		rs->fade_factor = presentation.fade;
		const struct owner_constraint *constraint = owner_constraint(rs, cmd->userData);
		Clay_RenderCommand fitted;
		if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_BORDER && constraint && constraint->fits_border) {
			fitted = *cmd;
			fitted.boundingBox = box_intersect(cmd->boundingBox, constraint->border);
			cmd = &fitted;
		}
		Clay_RenderCommand decoration;
		if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
				cmd->renderData.custom.customData != RENDER_CLIP_MARK &&
				((uintptr_t)cmd->renderData.custom.customData & RENDER_SHADOW_TAG)) {
			const struct render_shadow *style = render_shadow_of(cmd->renderData.custom.customData);
			constraint = owner_constraint(rs, (void *)(uintptr_t)style->owner);
			struct fade_value *value = fade_value(rs, style->owner_id);
			presentation = value ? value->pose : (struct render_presentation){.scale = 1, .fade = 1};
			rs->fade_factor = presentation.fade;
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
		if (rnode_scene_node(n, hooks) && n->presentation.scale != 1) presentation_restore(n->node);
		bool is_new = n->node == NULL;
		n->gen = rs->gen;
		n->retained = false;
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
			clip = box_intersect(clip, scope == &bounds_scope
				? unpresent_box(presentation, scope->box) : scope->box);
			clipped = true;
		}
		if (constraint && constraint->clips) {
			clip = box_intersect(clip, unpresent_box(presentation, constraint->clip));
			clipped = true;
		}
		if (constraint && constraint->clips_content
				&& cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM
				&& ((uintptr_t)cmd->renderData.custom.customData & ~RENDER_PROBED_TAG) == constraint->owner) {
			clip = box_intersect(clip, constraint->content);
			clipped = true;
		}
		const Clay_BoundingBox *clip_top = clipped ? &clip : NULL;
		bool clip_mark = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			cmd->renderData.custom.customData == RENDER_CLIP_MARK;
		bool shape = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			!clip_mark && ((uintptr_t)cmd->renderData.custom.customData & RENDER_SHAPE_TAG);
		bool shadow = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM &&
			!clip_mark && ((uintptr_t)cmd->renderData.custom.customData & RENDER_SHADOW_TAG);
		bool clippable = cmd->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_BORDER ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT ||
			cmd->commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE || clip_mark || shape ||
			(cmd->commandType == CLAY_RENDER_COMMAND_TYPE_CUSTOM && !shadow);
		bool shadow_clipped = shadow && constraint && constraint->clips;
		Clay_BoundingBox rbox = (clip_top != NULL && clippable) ?
			box_snap(box_intersect(cmd->boundingBox, *clip_top)) : shadow_clipped
			? box_snap(box_intersect(cmd->boundingBox, unpresent_box(presentation, constraint->clip))) : cmd->boundingBox;
		size_t mask_scope = scope && clippable && scope != &bounds_scope
			? (size_t)(scope - rs->scopes) : SIZE_MAX;
		const struct clip_masks *mask = scope && clippable && scope->masks.len
			? &scope->masks : NULL;

		switch (cmd->commandType) {
		case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
			muts += reconcile_rectangle(rs, n, cmd, rbox, mask);
			scope_open(rs, cmd->userData, rbox, scope,
				(struct clip_mask){ .box = cmd->boundingBox,
					.radii = cmd->renderData.rectangle.cornerRadius });
			break;
		case CLAY_RENDER_COMMAND_TYPE_BORDER:
			muts += reconcile_border(rs, n, cmd, rbox, mask);
			break;
		case CLAY_RENDER_COMMAND_TYPE_TEXT:
			muts += reconcile_text(rs, n, cmd, rbox, clip_top, mask, hooks);
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
					(struct clip_mask){ .box = cmd->boundingBox,
						.radii = cmd->renderData.custom.cornerRadius });
				break;
			}
			if (shadow) {
				muts += reconcile_shadow(rs, n, cmd, rbox);
				break;
			}
			if ((uintptr_t)cmd->renderData.custom.customData & RENDER_PROBE_TAG) {
				muts += reconcile_probe(n, cmd, hooks);
				break;
			}
			if (shape) {
				muts += reconcile_shape(rs, n, cmd, rbox, mask, hooks);
				scope_open(rs, cmd->userData, rbox, scope,
					(struct clip_mask){ .box = cmd->boundingBox, .path = true,
						.ops = n->shape_ops, .len = n->shape_ops_len,
						.gen = n->shape.gen, .key = n->key });
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
		case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START:
			break;
		case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END: {
			struct fade_value *value = fade_value(rs, cmd->id);
			if (!value || !value->opened) {
				wlr_log(WLR_ERROR, "unmatched fade end");
				abort();
			}
			value->opened = false;
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
			/* Every emitted command must have a reconciler. */
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

		clip_mask_keep(n, mask_scope, mask);
		n->box = cmd->boundingBox;
		n->rbox = rbox;
		/* The clip rbox was realized against, mirroring the rbox computation
		 * above: the active clip for a clippable node, else unbounded. */
		n->clip = (clip_top != NULL && clippable) ? *clip_top
			: shadow_clipped ? unpresent_box(presentation, constraint->clip) : box_inf();
		n->data = cmd->renderData;
		if (n->node && presentation.scale != 1) {
			presentation_tree(n->node, presentation, 0, 0, 0, 0, n->borrowed, true);
			/* A tree carries no size for presentation_apply to test, so a
			 * picture scaled below one pixel is disabled here. */
			if (box_empty(render_present_box(presentation, rbox)))
				wlr_scene_node_set_enabled(n->node, false);
			muts++;
		} else if (n->presentation.scale != presentation.scale) {
			muts++;
		}
		n->presentation = presentation;
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

	/* Sweep ids that vanished this frame. A node the renderer owns whose
	 * element is still in the tree is kept instead, disabled and out of the
	 * order, so its command's return re-enables it rather than creating it. */
	bool swept = false;
	rs->retained = 0;
	for (size_t i = 0; i < rs->len; ) {
		struct rnode *n = &rs->nodes[i];
		if (n->gen != rs->gen && !n->borrowed && n->node != NULL &&
				hooks->declared != NULL &&
				hooks->declared(hooks->data, (uint32_t)n->key)) {
			n->gen = rs->gen;
			if (!n->retained && n->node->enabled) {
				wlr_scene_node_set_enabled(n->node, false);
				muts++;
			}
			n->retained = true;
		}
		if (n->gen != rs->gen) {
			rnode_remove(rs, n, hooks);
			swept = true;
			muts++;
		} else {
			rs->retained += n->retained;
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

	/* Restack only when the retained scene order changed, and then only the
	 * nodes not directly above their predecessor in order: a removal moves
	 * nothing, and a new node, created at the top, moves once. A node kept
	 * dark holds no place, so one between a node and its predecessor does
	 * not count against it. */
	if (order_changed) {
		struct wlr_scene_node *below = NULL;
		for (size_t i = 0; i < rs->order_len; i++) {
			size_t idx = rmap_get(rs, rs->order[i]);
			assert(idx != SIZE_MAX);
			struct rnode *n = &rs->nodes[idx];
			if (n->node == NULL)
				continue;
			struct wl_list *prev = below ? &below->link : &rs->tree->children;
			if (placed_below(rs, n->node) != prev) {
				if (below)
					wlr_scene_node_place_above(n->node, below);
				else
					wlr_scene_node_lower_to_bottom(n->node);
				muts++;
			}
			below = n->node;
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

	for (size_t i = 0; i < rs->fade_aliases_len;) {
		if (rs->fade_aliases[i].seen) i++;
		else rs->fade_aliases[i] = rs->fade_aliases[--rs->fade_aliases_len];
	}

	return muts;
}

void render_destroy(struct render_state *rs,
		const struct render_client_hooks *hooks) {
    free(rs->constraints);
	free(rs->fades);
    free(rs->fade_aliases);
	/* Borrowed trees must leave before the render tree is destroyed, or
	 * the clients' scene nodes would be destroyed with it. */
	for (size_t i = 0; i < rs->len; i++) {
		if (rs->nodes[i].borrowed) {
			render_release(rs, &rs->nodes[i], hooks);
		}
		free(rs->nodes[i].text);
		free(rs->nodes[i].text_attrs);
		free(rs->nodes[i].shape_ops);
		if (rs->nodes[i].img_native)
			cairo_surface_destroy(rs->nodes[i].img_native);
		if (rs->nodes[i].img_vector)
			g_object_unref(rs->nodes[i].img_vector);
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

bool render_point_in_masks(struct render_state *rs, uint32_t element_id,
		double x, double y) {
	if (rs == NULL) return true;
	/* These commands retain the element ID. Text lines and border sides use
	 * derived IDs; their container's clip host filters the subtree instead. */
	const uint32_t types[] = { CLAY_RENDER_COMMAND_TYPE_CUSTOM,
		CLAY_RENDER_COMMAND_TYPE_RECTANGLE, CLAY_RENDER_COMMAND_TYPE_IMAGE };
	for (size_t i = 0; i < sizeof(types) / sizeof(*types); i++) {
		size_t idx = rmap_get(rs, (uint64_t)types[i] << 32 | element_id);
		if (idx == SIZE_MAX || rs->nodes[idx].retained) continue;
		struct rnode *n = &rs->nodes[idx];
		if (!point_in_masks(rnode_masks(rs, n), x, y)) return false;
		unsigned opens = render_userdata_byte(n->user_data, RENDER_UD_OPENS_SHIFT);
		const struct clip_scope *own = opens ? scope_named(rs, n->user_data, opens) : NULL;
		if (own && !point_in_masks(&own->masks, x, y)) return false;
		if (types[i] == CLAY_RENDER_COMMAND_TYPE_CUSTOM && !own && n->shape_ops &&
				!shape_point_in_path(n, x - n->rbox.x, y - n->rbox.y)) return false;
		if (types[i] == CLAY_RENDER_COMMAND_TYPE_RECTANGLE &&
				!corner_radius_zero(n->data.rectangle.cornerRadius) &&
				!rnode_point_in_arcs(rs, n, x - n->rbox.x, y - n->rbox.y)) return false;
	}
	return true;
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
		double px = x, py = y;
		if (!render_unpresent(n->presentation, &px, &py)) continue;
		double sx = px - n->rbox.x, sy = py - n->rbox.y;

		if (n->node == NULL || box_empty(n->rbox)
				|| sx < 0 || sy < 0 || sx >= n->rbox.width || sy >= n->rbox.height) {
			continue;
		}
		if (!rnode_point_in_arcs(rs, n, sx, sy)) {
			continue;
		} else if (type == CLAY_RENDER_COMMAND_TYPE_BORDER
				&& !border_point_in_ring(n, px - n->box.x, py - n->box.y)) {
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
			.presented = render_present_box(n->presentation, n->rbox),
				.has_node = true,
				.clip_mark = type == CLAY_RENDER_COMMAND_TYPE_CUSTOM
					&& n->data.custom.customData == RENDER_CLIP_MARK,
				.user_data = n->user_data,
			}, px - n->box.x, py - n->box.y)) {
			return true;
		}
	}
	return false;
}

void render_walk(struct render_state *rs,
		const struct render_client_hooks *hooks,
		void (*fn)(void *user, const struct render_node_view *view),
		void *user) {
	for (size_t i = 0; i < rs->order_len; i++) {
		size_t idx = rmap_get(rs, rs->order[i]);

		if (idx == SIZE_MAX) {
			continue;
		}
		struct rnode *n = &rs->nodes[idx];
		rnode_scene_node(n, hooks);

		fn(user, &(struct render_node_view) {
			.type = (uint32_t)(n->key >> 32),
			.id = (uint32_t)n->key,
			.z = n->z,
			.box = n->box,
			.rbox = n->rbox,
			.presented = render_present_box(n->presentation, n->rbox),
			.raster_bytes = n->raster_bytes,
			.has_node = n->node != NULL,
			.clip_mark = (uint32_t)(n->key >> 32) == CLAY_RENDER_COMMAND_TYPE_CUSTOM
				&& n->data.custom.customData == RENDER_CLIP_MARK,
			.probe = (uint32_t)(n->key >> 32) == CLAY_RENDER_COMMAND_TYPE_CUSTOM
				&& n->data.custom.customData != RENDER_CLIP_MARK
				&& ((uintptr_t)n->data.custom.customData & RENDER_PROBE_TAG),
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

int render_nodes_created(struct render_state *rs) {
	return rs->created;
}

int render_nodes_swept(struct render_state *rs) {
	return rs->swept;
}

bool render_visibility_batched(struct render_state *rs) {
    return rs->visibility_batched;
}
