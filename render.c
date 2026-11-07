/* Retained Clay commands, painted in their reconciled order. */

#include <assert.h>
#include <librsvg/rsvg.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cairo.h>
#include <pango/pangocairo.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/render/gles2.h>
#include <wlr/render/wlr_texture.h>
#include "paint.h"
#include <wlr/types/wlr_compositor.h>
#include <wlr/util/transform.h>
#include <wlr/util/log.h>

#include "common/util.h"
#include "render.h"
#include "render_image.h"
#include "render_text.h"

/* All 100 native clips may nest inside a floating root's inherited scissor.
 * CLIP_INF leaves an unclipped axis larger than the output's coordinates. */
#define CLIP_STACK_MAX 101
#define CLIP_INF 1.0e6f

struct cairo_buffer {
    cairo_surface_t *surface;
    struct { int width, height; } base;
};

static void cairo_buffer_destroy(struct cairo_buffer *buffer) {
    if (!buffer) return;
    cairo_surface_destroy(buffer->surface);
    free(buffer);
}

static struct cairo_buffer *cairo_buffer_create(int width, int height) {
    struct cairo_buffer *buffer = calloc(1, sizeof(*buffer));
    if (!buffer) return NULL;
    buffer->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(buffer->surface) != CAIRO_STATUS_SUCCESS) {
        cairo_buffer_destroy(buffer);
        return NULL;
    }
    buffer->base.width = width;
    buffer->base.height = height;
    return buffer;
}

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
	struct clip_mask items[CLIP_MASKS_MAX];
};

/* Each scope intersects its box and all shaped masks with its parent. */
struct clip_scope {
	uint64_t owner;
	unsigned number;
	Clay_BoundingBox box;
	struct clip_masks masks;
    uint64_t coverage_key, coverage_digest;
    Clay_BoundingBox coverage_box;
};

struct raster_placement {
	float crop_x, crop_y, crop_w, crop_h;
	int dst_w, dst_h;
};

/* One retained record per (command id, command type). */
struct rnode {
	uint64_t key;
    struct render_presentation presentation;

	Clay_BoundingBox box;
	Clay_BoundingBox rbox;

	Clay_BoundingBox clip;
	Clay_RenderData data;
	/* The command's z order, retained only so the tree dump can print the
	 * band a node landed in without re-solving. */
	int16_t z;
	char *text;
	int32_t text_len;
	struct render_text_attr *text_attrs;
	size_t text_attrs_len;

    bool initialized, draws;
    struct paint_rect_params paint;
    struct paint_texture *texture;
    cairo_surface_t *coverage;
    struct paint_mask *coverage_texture;
    uint64_t coverage_digest, mask_owner;
    uint64_t raster_serial, changed;
    size_t order_position;
	/* IMAGE: the decode generation last rasterized, so a reload re-rasters. */
	uint64_t img_gen;
	int img_src_x, img_src_y;
	cairo_surface_t *img_native;
	void *img_vector;
	int img_width, img_height;
	uint8_t img_filter, img_transform;
	bool img_stretch, img_natural;
	struct render_shape shape;
    struct render_shadow shadow;
    bool shadow_kind;
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
	/* Scope indices serve input for one frame; keys survive node compaction. */
	size_t mask_scope;
	uint64_t mask_digest;

	size_t raster_bytes;
	int raster_width, raster_height;

	struct cairo_buffer *raster;
	struct raster_placement raster_placement;
	bool borrowed;
	struct render_surface_origin surface_origin;
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
    struct fade_alias {uint64_t owner, ancestor; unsigned clip; bool seen;} *fade_aliases;
    size_t fade_aliases_len, fade_aliases_cap;
    float fade_factor;
	uint32_t output_id;
    bool enabled;
    struct paint *painter;
    uint64_t renderer_generation;
    struct render_box *damage;
    size_t damage_len, damage_cap;
    size_t clip_overflows;
    int mutations;
    struct paint_texture **imports;
    size_t imports_len, imports_cap;
	struct rnode *nodes;
	size_t len, cap;
	uint64_t gen;

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
	int buffers_created, masks_created;

	int created, swept;
	/* Nodes kept dark after the last sweep (rnode.retained). */
	size_t retained;
	bool shape_overflow_logged;
	bool mask_overflow_logged;
	bool clip_overflow_logged;

	/* The output's scale, driving device-pixel raster sizing. 1.0 is the
	 * identity: every device_len below reduces to the logical length, so a
	 * non-HiDPI output rasters exactly as before. */
	float scale;
};

struct render_state *render_create(void) {
    struct render_state *rs = calloc(1, sizeof(*rs));
    if (rs) { rs->scale = 1; rs->enabled = true; }
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

void render_clip_alias(struct render_state *rs, uint64_t owner, uint64_t ancestor, unsigned scope)
{
    render_fade_alias(rs, owner, ancestor);
    for (size_t i = 0; i < rs->fade_aliases_len; i++)
        if (rs->fade_aliases[i].owner == owner) rs->fade_aliases[i].clip = scope;
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

void render_set_enabled(struct render_state *rs, bool enabled) {
    rs->enabled = enabled;
}

static void render_release(struct render_state *rs, struct rnode *n,
        const struct render_client_hooks *hooks) {
    if (hooks && hooks->release) hooks->release(hooks->data, n->handle, rs);
}

void render_set_output_id(struct render_state *rs, uint32_t id) {
	rs->output_id = id;
}

void render_set_scale(struct render_state *rs, float scale) {
	rs->scale = scale > 0.0f ? scale : 1.0f;
}

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
	if (idx == SIZE_MAX || !rs->nodes[idx].shadow_kind || rs->nodes[idx].retained)
		return false;
	*box = rs->nodes[idx].box;
	return true;
}

static struct rnode *rnode_add(struct render_state *rs, uint64_t key) {
	p_grow(&rs->nodes, rs->len + 1, &rs->cap);
	struct rnode *n = &rs->nodes[rs->len++];
	memset(n, 0, sizeof(*n));

	n->opacity = 1.0f;
	n->presentation = (struct render_presentation){.scale = 1, .fade = 1};
	n->key = key;
    n->order_position = SIZE_MAX;
	n->mask_scope = SIZE_MAX;
	return n;
}

static void rnode_remove(struct render_state *rs, struct rnode *n,
        const struct render_client_hooks *hooks) {
    free(n->text);
    free(n->text_attrs);
    free(n->shape_ops);
    if (n->img_native) cairo_surface_destroy(n->img_native);
    if (n->img_vector) g_object_unref(n->img_vector);
    if (n->borrowed) render_release(rs, n, hooks);
    rs->raster_bytes -= n->raster_bytes;
    paint_texture_destroy(n->texture);
    cairo_buffer_destroy(n->raster);
    if (n->coverage) cairo_surface_destroy(n->coverage);
    paint_mask_destroy(n->coverage_texture);
    *n = rs->nodes[--rs->len];
}

static float clay_srgb(float channel) {
	return channel / 255.0f;
}

static void clay_color_to_float(Clay_Color c, float out[4]) {

	float a = clay_srgb(c.a);
	out[0] = clay_srgb(c.r) * a;
	out[1] = clay_srgb(c.g) * a;
	out[2] = clay_srgb(c.b) * a;
	out[3] = a;
}

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

static void paint_radii(float out[4], Clay_CornerRadius r) {
	out[0] = r.topLeft;
	out[1] = r.topRight;
	out[2] = r.bottomRight;
	out[3] = r.bottomLeft;
}

static bool point_in_rounded_rect(double px, double py, double x, double y,
		double w, double h, Clay_CornerRadius r) {
	if (px < x || py < y || px >= x + w || py >= y + h) {
		return false;
	}
	float radii[4], fit[4];
	paint_radii(radii, r);
	paint_fit_radii(fit, radii, w, h);
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
static void buffer_apply_clip(
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox, float scale,
		int raster_width, int raster_height, struct raster_placement *applied) {
	Clay_BoundingBox box = cmd->boundingBox;
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
		*applied = (struct raster_placement){src.x, src.y, src.width, src.height, rw, rh};

	} else {
		/* Unclipped, or clipped with no raster to crop (a shape with no
		 * fill or stroke): the footprint is still the realized box. */
		*applied = (struct raster_placement){.dst_w = (int)rbox.width, .dst_h = (int)rbox.height};

	}
}

static size_t cairo_buffer_bytes(struct cairo_buffer *cb) {
	return (size_t)cairo_image_surface_get_stride(cb->surface) *
		(size_t)cairo_image_surface_get_height(cb->surface);
}

/* An empty realized box keeps the stored crop; record_draws skips its draw. */
static int rnode_apply_clip(struct rnode *n, Clay_RenderCommand *cmd,
        Clay_BoundingBox rbox, float scale, bool raster_changed) {
    struct raster_placement previous = n->raster_placement;
    if (!box_empty(rbox)) buffer_apply_clip(cmd, rbox, scale,
        n->raster_width, n->raster_height, &n->raster_placement);
    return memcmp(&previous, &n->raster_placement, sizeof(previous)) != 0;
}

static void rnode_upload(struct render_state *rs, struct rnode *n) {
    if (!rs->painter || !n->raster || n->texture) return;
    n->texture = paint_texture_upload(rs->painter, n->raster_width, n->raster_height,
        cairo_image_surface_get_stride(n->raster->surface),
        cairo_image_surface_get_data(n->raster->surface));
    rs->buffers_created++;
}

static void rnode_set_raster(struct render_state *rs, struct rnode *n,
        struct cairo_buffer *raster) {
    size_t bytes = raster ? cairo_buffer_bytes(raster) : 0;
    rs->raster_bytes = rs->raster_bytes - n->raster_bytes + bytes;
    n->raster_bytes = bytes;
    n->raster_width = raster ? raster->base.width : 0;
    n->raster_height = raster ? raster->base.height : 0;
    paint_texture_destroy(n->texture);
    n->texture = NULL;
    cairo_buffer_destroy(n->raster);
    n->raster = raster;
    n->raster_serial++;
    n->draws = raster != NULL;
    rnode_upload(rs, n);
}

static uint64_t mask_digest_bytes(uint64_t digest, const void *data, size_t len) {
	const unsigned char *bytes = data;
	for (size_t i = 0; i < len; i++) {
		digest ^= bytes[i];
		digest *= UINT64_C(1099511628211);
	}
	return digest;
}

static uint64_t clip_masks_digest(const struct clip_masks *masks, Clay_BoundingBox box) {
	uint64_t digest = masks->paths ? UINT64_C(14695981039346656037) : 0;
	for (size_t i = 0; i < masks->len; i++) {
		const struct clip_mask *m = &masks->items[i];
		if (!m->path)
			continue;
		float geometry[] = { m->box.x - box.x, m->box.y - box.y, m->box.width, m->box.height };
		uint64_t identity[] = { m->key, m->gen, m->len };
		digest = mask_digest_bytes(digest, geometry, sizeof(geometry));
		digest = mask_digest_bytes(digest, identity, sizeof(identity));
	}
	return digest;
}

/* Coverage is local to the scope, so translating the scope and its paths
 * together does not change the cache key or the A8 pixels. */
static void scope_coverage(struct render_state *rs, struct rnode *n,
        struct clip_scope *scope) {
    Clay_BoundingBox box = scope->box;
    int width = (int)ceilf(box.width * rs->scale);
    int height = (int)ceilf(box.height * rs->scale);
    uint64_t digest = clip_masks_digest(&scope->masks, box);
    int size[] = {width, height};
    digest = mask_digest_bytes(digest, size, sizeof(size));
    digest = mask_digest_bytes(digest, &rs->scale, sizeof(rs->scale));
    scope->coverage_key = n->key;
    scope->coverage_box = box;
    scope->coverage_digest = digest;
    if (n->coverage && n->coverage_digest == digest) return;
    if (n->coverage) cairo_surface_destroy(n->coverage);
    paint_mask_destroy(n->coverage_texture);
    n->coverage = NULL;
    n->coverage_texture = NULL;
    n->coverage_digest = digest;
    if (width < 1 || height < 1) return;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_scale(cr, rs->scale, rs->scale);
    for (size_t i = 0; i < scope->masks.len; i++) {
        const struct clip_mask *mask = &scope->masks.items[i];
        if (!mask->path) continue;
        cairo_matrix_t matrix;
        cairo_get_matrix(cr, &matrix);
        cairo_translate(cr, mask->box.x - box.x, mask->box.y - box.y);
        shape_path(cr, mask->ops, mask->len);
        cairo_set_matrix(cr, &matrix);
        cairo_clip(cr);
    }
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    cairo_paint(cr);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    n->coverage = surface;
    rs->masks_created++;
}

static void node_mask(struct rnode *n, size_t index,
        const struct clip_scope *scope, Clay_BoundingBox rbox) {
    n->mask_scope = index;
    bool masked = scope && path_masks_hit(&scope->masks, rbox);
    n->mask_owner = masked ? scope->coverage_key : 0;
    n->mask_digest = masked ? scope->coverage_digest : 0;
    Clay_BoundingBox b = masked ? scope->coverage_box : (Clay_BoundingBox){0};
    n->paint.mask_box = (struct paint_box){b.x, b.y, b.width, b.height};
}

/* The rounded clips of a node realized at rbox, node-local, innermost first,
 * and the radii it carries as its own. An uncropped node takes own as its
 * own; a cropped one takes own as a clip at its solved box instead, so the
 * arcs stay where the solved box puts them. Then every radius mask whose
 * corner squares reach rbox, from the innermost. A fifth is dropped and
 * logged once. */
static size_t node_rounded_clips(struct render_state *rs, Clay_BoundingBox box,
		Clay_BoundingBox rbox, Clay_CornerRadius own,
		const struct clip_masks *masks, float radii[4],
		struct paint_clip clips[PAINT_CLIPS]) {
	size_t len = 0;
	memset(radii, 0, 4 * sizeof(*radii));
	if (!corner_radius_zero(own)) {
		if (box_pos_equal(box, rbox) && box_size_equal(box, rbox)) {
			paint_radii(radii, own);
		} else {
			clips[len].box = (struct paint_box) { (int)box.x - (int)rbox.x,
				(int)box.y - (int)rbox.y, (int)box.width, (int)box.height };
			paint_radii(clips[len++].radii, own);
		}
	}
	for (size_t i = masks ? masks->len : 0; i > 0; i--) {
		const struct clip_mask *m = &masks->items[i - 1];
		if (m->path || !rounded_mask_hits(m, rbox))
			continue;
		if (len == PAINT_CLIPS) {
            rs->clip_overflows++;
			if (!rs->clip_overflow_logged) {
				wlr_log(WLR_ERROR, "node under more than %d rounded hosts; "
					"dropping the outer ones", PAINT_CLIPS);
				rs->clip_overflow_logged = true;
			}
			break;
		}
		clips[len].box = (struct paint_box) { (int)m->box.x - (int)rbox.x,
			(int)m->box.y - (int)rbox.y, (int)m->box.width, (int)m->box.height };
		paint_radii(clips[len++].radii, m->radii);
	}
	return len;
}

/* Apply the radii and clips a raster leaf at rbox carries to its buffer.
 * Counted once the node exists; a new node's are part of its creation. */
static int buffer_set_rounded(struct render_state *rs, struct rnode *n,
        Clay_BoundingBox box, Clay_BoundingBox rbox, Clay_CornerRadius own,
        const struct clip_masks *masks, bool is_new) {
    struct paint_rect_params previous = n->paint;
    n->paint.clips_len = node_rounded_clips(rs, box, rbox, own, masks,
        n->paint.radii, n->paint.clips);
    return memcmp(&previous, &n->paint, sizeof(previous)) != 0;
}

/* The box inset by the four widths, box-relative. Returns false when the
 * widths meet or cross: the whole box is ring. */
static bool border_hole(const Clay_RenderCommand *cmd, Clay_BoundingBox *hole) {
	Clay_BorderWidth bw = cmd->renderData.border.width;
	*hole = (Clay_BoundingBox){ bw.left, bw.top,
		cmd->boundingBox.width - bw.left - bw.right,
		cmd->boundingBox.height - bw.top - bw.bottom };
	return hole->width > 0 && hole->height > 0;
}

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
    n->draws = true;
    n->opacity = opacity;
    float color[4];
    clay_color_to_float(fill, color);
    n->paint.color = (struct paint_color){color[0]*opacity, color[1]*opacity,
        color[2]*opacity, color[3]*opacity};
    buffer_set_rounded(rs, n, box, rbox, radii, masks, false);
    n->paint.cutout = (struct paint_box){0};
    memset(n->paint.cutout_radii, 0, sizeof(n->paint.cutout_radii));
    if (hole) {
        n->paint.cutout = (struct paint_box){box.x+hole->x-rbox.x,
            box.y+hole->y-rbox.y, hole->width, hole->height};
        paint_radii(n->paint.cutout_radii, hole_radii);
    }
    return 0;
}

static int reconcile_rectangle(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
	Clay_RectangleRenderData *rd = &cmd->renderData.rectangle;
	return reconcile_rect(rs, n, cmd->boundingBox, rbox, rd->backgroundColor,
			command_opacity(rs, cmd), rd->cornerRadius, NULL,
			(Clay_CornerRadius){0}, mask);
}

static int reconcile_clip_mark(struct render_state *rs, struct rnode *n,
        Clay_BoundingBox rbox) {
    n->draws = false;
    return 0;
}

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

static int reconcile_border(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask) {
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
 * cropped. The cut is the textbox's own clip, the box it was given: a clip
 * further out (a scroll's viewport) moves the run through it and never
 * shortens it. The cut is solved, so it is compared with the run's solved
 * end: the realized box (box_snap) can round past that end, which would read
 * a whole run as cut. A cut edge within float noise of the run's own edge is
 * the run's edge, since Clay solves in float32. The bound then quantizes the
 * realized start and the cut's edge at the device scale and takes the
 * difference, as device_len does. */
static int text_ellipsis_width(Clay_RenderCommand *cmd, Clay_BoundingBox solved,
		const Clay_BoundingBox *cut, float scale) {
	if (cut == NULL ||
			((uintptr_t)cmd->userData & RENDER_TEXT_ELLIPSIZE) == 0) {
		return 0;
	}
	bool turn = transform_turns(render_font_transform(cmd->renderData.text.fontId));
	const Clay_BoundingBox *box = &cmd->boundingBox;
	double start = turn ? box->y : box->x;
	double end = start + (turn ? box->height : box->width);
	double solved_end = turn ? (double)solved.y + solved.height
		: (double)solved.x + solved.width;
	double cut_end = turn ? (double)cut->y + cut->height
		: (double)cut->x + cut->width;
	if (cut_end >= solved_end - 1e-3)
		return 0;
	long origin = lround(start * scale);
	int natural = (int)(lround(end * scale) - origin);
	int bound = (int)(lround(cut_end * scale) - origin);
	return bound > 0 && bound < natural ? bound : 0;
}

static struct cairo_buffer *rasterize_text(Clay_RenderCommand *cmd, float scale,
		int max_width,
        const struct render_text_attr *attrs, size_t attrs_len) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int width = device_len((int)cmd->boundingBox.x, (int)cmd->boundingBox.width, scale);
	int height = device_len((int)cmd->boundingBox.y, (int)cmd->boundingBox.height, scale);
	if (width < 1 || height < 1) {
		return NULL;
	}

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
		Clay_RenderCommand *cmd, Clay_BoundingBox solved, Clay_BoundingBox rbox,
		const Clay_BoundingBox *cut, const struct clip_masks *mask,
        const struct render_client_hooks *hooks) {
	Clay_TextRenderData *td = &cmd->renderData.text;
	int muts = 0;

	/* Clay emits a line of length -1 when a word wider than its box is
	 * followed by a space and a newline (clay.h:2614-2615). It is an empty
	 * line: nothing reads the slice, and its box is -spaceWidth wide, so
	 * the node stays hidden below. */
    if (td->stringContents.length < 0) {
        if (n->raster) rnode_set_raster(rs, n, NULL);
        n->draws = false;
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

	bool is_new = !n->initialized;
	if (is_new) {
		n->initialized = true;
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
	int ell = text_ellipsis_width(cmd, solved, cut, rs->scale);
	bool raster_changed = content_changed || attrs_changed ||
		!raster_size_equal(n->box, cmd->boundingBox, rs->scale) ||
		n->raster_scale != rs->scale ||
		n->text_ellipsis != ell ||
		!text_data_equal(&n->data.text, td);
	if (raster_changed) {
		rnode_set_raster(rs, n, rasterize_text(cmd, rs->scale, ell,
            n->text_attrs, n->text_attrs_len));
		n->raster_scale = rs->scale;
		n->text_ellipsis = ell;
		muts++;
	}

	float opacity = command_opacity(rs, cmd);
	if (opacity != n->opacity) {

		n->opacity = opacity;
		if (!is_new)
			muts++;
	}

	muts += rnode_apply_clip(n, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, n, cmd->boundingBox, rbox,
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
		struct image_entry *entry, float scale) {
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

	bool is_new = !n->initialized;
	if (is_new) {
		n->initialized = true;
	}

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
			|| entry->transform != n->img_transform));

	if (raster_changed) {
		rnode_set_raster(rs, n,
			usable ? rasterize_image(cmd, entry, rs->scale) : NULL);
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

		n->opacity = opacity;
		if (!is_new) {
			muts++;
		}
	}

	/* Crop to the clip, exactly as reconcile_text does (buffer is ceil(box)
	 * sized, so the source box is in box pixels). */
	muts += rnode_apply_clip(n, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, n, cmd->boundingBox, rbox,
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
		float scale) {
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
        Clay_RenderCommand *cmd, Clay_BoundingBox rbox) {
    n->shadow = *render_shadow_of(cmd->renderData.custom.customData);
    n->shadow_kind = true;
    n->draws = true;
    n->opacity = command_opacity(rs, cmd);
    return 0;
}

static int reconcile_shape(struct render_state *rs, struct rnode *n,
		Clay_RenderCommand *cmd, Clay_BoundingBox rbox,
		const struct clip_masks *mask, const struct render_client_hooks *hooks) {
	static float ops[4096];
	struct render_shape *shape = render_shape_of(cmd->renderData.custom.customData);
	/* Lua may run in the hook: all raster inputs are copied before it. */
	struct render_shape value = *shape;
	int muts = 0;
	bool is_new = !n->initialized;
	if (is_new) {
		n->initialized = true;
	}
    bool size_changed = !box_size_equal(n->box, cmd->boundingBox);
    bool path_changed = is_new || size_changed || n->shape.gen != value.gen
        || n->data.custom.customData != cmd->renderData.custom.customData;
    bool ops_changed = false;
    if (path_changed) {
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
        ops_changed = len != n->shape_ops_len
            || (len && memcmp(n->shape_ops, ops, len * sizeof(*ops)));
        if (ops_changed) {
            free(n->shape_ops);
            n->shape_ops = len ? malloc(len * sizeof(*ops)) : NULL;
            n->shape_ops_len = n->shape_ops ? len : 0;
            if (n->shape_ops) memcpy(n->shape_ops, ops, len * sizeof(*ops));
        }
    }
    /* Describing a widget may replace a closure with an identical path.
     * Its generation refreshes coverage, but its painted content is unchanged. */
    bool raster_changed = is_new || size_changed || ops_changed
        || !raster_size_equal(n->box, cmd->boundingBox, rs->scale)
        || n->raster_scale != rs->scale
        || n->shape.transform != value.transform
        || memcmp(&n->shape.gradient, &value.gradient, sizeof(value.gradient))
        || memcmp(n->shape.fill, value.fill, sizeof(value.fill))
        || memcmp(n->shape.stroke, value.stroke, sizeof(value.stroke))
        || n->shape.stroke_width != value.stroke_width;
    n->shape = value;
    if (raster_changed) {
        rnode_set_raster(rs, n, rasterize_shape(cmd, &value,
            n->shape_ops, n->shape_ops_len, rs->scale));
        n->raster_scale = rs->scale;
        muts++;
    }
	float opacity = command_opacity(rs, cmd);
	if (opacity != n->opacity) {

		n->opacity = opacity;
		if (!is_new)
			muts++;
	}
	muts += rnode_apply_clip(n, cmd, rbox, rs->scale, raster_changed);
	muts += buffer_set_rounded(rs, n, cmd->boundingBox, rbox,
		(Clay_CornerRadius){0}, mask, is_new);
	return muts;
}

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
    uint64_t data = (uintptr_t)cmd->renderData.custom.customData;
    n->handle = data & ~RENDER_PROBED_TAG;
    n->borrowed = true;
    bool first = !n->draws;
    n->draws = hooks && hooks->resolve && hooks->resolve(hooks->data, n->handle);
    if (!n->draws) return 0;
    if (first && hooks->borrow) hooks->borrow(hooks->data, n->handle, rs);
    if (!(data & RENDER_PROBED_TAG) && !box_size_equal(n->box, cmd->boundingBox))
        hooks->configure(hooks->data, n->handle, cmd->boundingBox.width, cmd->boundingBox.height);
    struct wlr_box crop = surface_clip_box(cmd->boundingBox, rbox);
    struct wlr_box previous = surface_clip_box(n->box, n->rbox);
    struct render_surface_origin origin = hooks->surface_origin
        ? hooks->surface_origin(hooks->data, n->handle) : (struct render_surface_origin){0};
    if (hooks->clip && (first || !wlr_box_equal(&crop, &previous)
            || memcmp(&origin, &n->surface_origin, sizeof(origin))))
        hooks->clip(hooks->data, n->handle, crop.x, crop.y, crop.width, crop.height);
    n->surface_origin = origin;
    Clay_CornerRadius r = cmd->renderData.custom.cornerRadius;
    if (hooks->corners && (first || memcmp(&r, &n->data.custom.cornerRadius, sizeof(r))))
        hooks->corners(hooks->data, n->handle, (float[4]){r.topLeft,r.topRight,r.bottomRight,r.bottomLeft});
    n->opacity = command_opacity(rs, cmd);
    return 0;
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
static void scope_open(struct render_state *rs, struct rnode *n, void *word, Clay_BoundingBox rbox,
		const struct clip_scope *under, struct clip_mask own) {
	unsigned opens = render_userdata_byte(word, RENDER_UD_OPENS_SHIFT);
	if (opens == 0) return;
	assert(rs->scopes_len < rs->scopes_cap);
	struct clip_scope *sc = &rs->scopes[rs->scopes_len++];
	sc->owner = (uintptr_t)word & RENDER_UD_OWNER_MASK;
	sc->number = opens;
	sc->box = rbox;
	sc->masks = under ? under->masks : (struct clip_masks){0};
    sc->coverage_key = under ? under->coverage_key : 0;
    sc->coverage_digest = under ? under->coverage_digest : 0;
    sc->coverage_box = under ? under->coverage_box : (Clay_BoundingBox){0};
	if (own.path || !corner_radius_zero(own.radii)) {
		if (sc->masks.len < CLIP_MASKS_MAX) {
			sc->masks.items[sc->masks.len++] = own;
			sc->masks.paths += own.path;
            if (own.path) scope_coverage(rs, n, sc);
		} else if (!rs->mask_overflow_logged) {
			wlr_log(WLR_ERROR, "clip scope exceeds %d shaped masks; retaining outer masks",
				CLIP_MASKS_MAX);
			rs->mask_overflow_logged = true;
		}
	}
}

static bool record_draws(const struct rnode *n) {
    return n && n->draws && !n->retained && !box_empty(n->rbox)
        && n->presentation.scale > 0;
}

static void damage_record(struct render_state *rs, const struct rnode *n) {
    if (!record_draws(n)) return;
    Clay_BoundingBox b = render_present_box(n->presentation, n->rbox);
    if (rs->damage_len == rs->damage_cap) {
        rs->damage_cap = rs->damage_cap ? rs->damage_cap * 2 : 32;
        p_realloc(&rs->damage, rs->damage_cap);
    }
    rs->damage[rs->damage_len++] = (struct render_box){b.x-1,b.y-1,b.width+2,b.height+2};
}

static void record_mutated(struct render_state *rs, struct rnode *n) {
    if (n->changed == rs->gen) return;
    n->changed = rs->gen;
    rs->mutations++;
    damage_record(rs, n);
}

static void record_changed(struct render_state *rs, const struct rnode *old, struct rnode *n) {
    bool before = record_draws(old), after = record_draws(n);
    if (!before && !after) return;
    bool changed = before != after;
    if (!changed) changed = memcmp(&old->box,&n->box,sizeof(n->box))
        || memcmp(&old->rbox,&n->rbox,sizeof(n->rbox))
        || memcmp(&old->clip,&n->clip,sizeof(n->clip))
        || memcmp(&old->paint,&n->paint,sizeof(n->paint))
        || memcmp(&old->shadow,&n->shadow,sizeof(n->shadow))
        || memcmp(&old->presentation,&n->presentation,sizeof(n->presentation))
        || memcmp(&old->surface_origin,&n->surface_origin,sizeof(n->surface_origin))
        || memcmp(&old->raster_placement,&n->raster_placement,sizeof(n->raster_placement))
        || old->mask_owner != n->mask_owner || old->mask_digest != n->mask_digest
        || old->raster_serial != n->raster_serial || old->opacity != n->opacity;
    if (!changed) return;
    damage_record(rs, old);
    if (n) record_mutated(rs,n);
    else rs->mutations++;
    rs->created += !before && after;
    rs->swept += before && !after;
}

size_t render_damage(struct render_state *rs, struct render_box *out, size_t cap) {
    size_t len = MIN(cap,rs->damage_len);
    if (len) {
        memcpy(out,rs->damage,len*sizeof(*out));
        rs->damage_len -= len;
        memmove(rs->damage,rs->damage+len,rs->damage_len*sizeof(*out));
    }
    return len;
}

void render_set_paint(struct render_state *rs, struct paint *p, uint64_t generation) {
    if (rs->painter == p && rs->renderer_generation == generation) return;
    for (size_t i=0;i<rs->len;i++) {
        paint_texture_destroy(rs->nodes[i].texture);
        rs->nodes[i].texture = NULL;
        paint_mask_destroy(rs->nodes[i].coverage_texture);
        rs->nodes[i].coverage_texture = NULL;
        if (rs->nodes[i].coverage) cairo_surface_destroy(rs->nodes[i].coverage);
        rs->nodes[i].coverage = NULL;
        damage_record(rs,&rs->nodes[i]);
    }
    rs->painter = p;
    rs->renderer_generation = generation;
}

size_t render_clip_overflows(struct render_state *rs) { return rs->clip_overflows; }

int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
		const struct render_client_hooks *hooks, Clay_BoundingBox bounds) {
	border_content_constraints(rs, commands);
	rs->gen++;
	rs->buffers_created = 0;
    rs->masks_created = 0;
    rs->mutations = 0;
	rs->created = 0;
	rs->swept = 0;
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

	/* One capacity for both, so p_realloc rather than p_grow: the second
	 * p_grow would see the capacity the first already raised. */
	if ((size_t)commands.length > rs->order_cap) {
		rs->order_cap = commands.length;
		p_realloc(&rs->order, rs->order_cap);
		p_realloc(&rs->build, rs->order_cap);
	}

	Clay_BoundingBox clip_stack[CLIP_STACK_MAX];
	/* Each scissor's own box, before the enclosing clips cut it. */
	Clay_BoundingBox clip_own[CLIP_STACK_MAX];
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
		 * text_ellipsis_width, which also reads the text's solved box.
		 * Every realized box rounds once, including the clipped
		 * intersection below. */
		Clay_BoundingBox solved = cmd->boundingBox;
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
		struct rnode before = *n;
		bool is_new = !n->initialized;
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
        if (!scope) {
            uint64_t owner = (uintptr_t)cmd->userData & RENDER_UD_OWNER_MASK;
            for (size_t j = 0; j < rs->fade_aliases_len; j++) {
                const struct fade_alias *alias = &rs->fade_aliases[j];
                if (alias->owner == owner && alias->clip) {
                    scope = scope_named(rs, (void *)(uintptr_t)alias->ancestor, alias->clip);
                    break;
                }
            }
        }
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
			scope_open(rs, n, cmd->userData, rbox, scope,
				(struct clip_mask){ .box = cmd->boundingBox,
					.radii = cmd->renderData.rectangle.cornerRadius });
			break;
		case CLAY_RENDER_COMMAND_TYPE_BORDER:
			muts += reconcile_border(rs, n, cmd, rbox, mask);
			break;
		case CLAY_RENDER_COMMAND_TYPE_TEXT:
			muts += reconcile_text(rs, n, cmd, solved, rbox, clip_depth > 0
				&& clip_depth <= CLIP_STACK_MAX ? &clip_own[clip_depth - 1] : NULL,
				mask, hooks);
			break;
		case CLAY_RENDER_COMMAND_TYPE_IMAGE:
			muts += reconcile_image(rs, n, cmd, rbox, mask);
			break;
		case CLAY_RENDER_COMMAND_TYPE_CUSTOM:
			/* A clip mark: a transparent rect that takes input (render.h),
			 * and the scope it opens. */
			if (clip_mark) {
				muts += reconcile_clip_mark(rs, n, rbox);
				scope_open(rs, n, cmd->userData, rbox, scope,
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
				scope_open(rs, n, cmd->userData, rbox, scope,
					(struct clip_mask){ .box = cmd->boundingBox, .path = true,
						.ops = n->shape_ops, .len = n->shape_ops_len,
						.gen = n->shape.gen, .key = n->key });
				break;
			}
			muts += reconcile_surface(rs, n, cmd, rbox, hooks);
			break;
		case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START: {

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
			if (clip_depth < CLIP_STACK_MAX) {
				clip_own[clip_depth] = sc;
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

        if (n->draws && n->borrowed && hooks->reposition &&
                (is_new || !box_pos_equal(n->box, cmd->boundingBox)))
            hooks->reposition(hooks->data, n->handle, cmd->boundingBox.x, cmd->boundingBox.y);
        if (n->borrowed) buffer_set_rounded(rs, n, cmd->boundingBox, rbox,
            cmd->renderData.custom.cornerRadius, mask, is_new);

		node_mask(n, mask_scope, mask_scope == SIZE_MAX ? NULL : scope, rbox);
		n->box = cmd->boundingBox;
		n->rbox = rbox;
		/* The clip rbox was realized against, mirroring the rbox computation
		 * above: the active clip for a clippable node, else unbounded. */
		n->clip = (clip_top != NULL && clippable) ? *clip_top
			: shadow_clipped ? unpresent_box(presentation, constraint->clip) : box_inf();
		n->data = cmd->renderData;
        n->presentation = presentation;
        n->initialized = true;
        record_changed(rs, &before, n);

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
        if (n->gen != rs->gen && !n->borrowed && n->initialized && hooks->declared
                && hooks->declared(hooks->data, (uint32_t)n->key)) {
            struct rnode before = *n;
            n->gen = rs->gen;
            n->retained = true;
            record_changed(rs, &before, n);
        }

		if (n->gen != rs->gen) {
			record_changed(rs, n, NULL);
			rnode_remove(rs, n, hooks);
			swept = true;
			muts++;
		} else {
			rs->retained += n->retained;
			i++;
		}
	}

	if (swept || rs->len != pre_len) {
		rmap_rebuild(rs);
	}

	memcpy(rs->order, rs->build, build_len * sizeof(*rs->order));
	rs->order_len = build_len;

    {
        size_t position = 0;
        for (size_t i = 0; i < rs->order_len; i++) {
            struct rnode *n = &rs->nodes[rmap_get(rs, rs->order[i])];
            if (!record_draws(n)) continue;
            if (n->order_position != position) record_mutated(rs, n);
            n->order_position = position++;
        }
    }

	for (size_t i = 0; i < rs->fade_aliases_len;) {
		if (rs->fade_aliases[i].seen) i++;
		else rs->fade_aliases[i] = rs->fade_aliases[--rs->fade_aliases_len];
	}

    (void)muts;
	return rs->mutations;
}

void render_destroy(struct render_state *rs, const struct render_client_hooks *hooks) {
    render_finish(rs);
    while (rs->len) rnode_remove(rs, &rs->nodes[rs->len - 1], hooks);
    free(rs->constraints);
    free(rs->fades);
    free(rs->fade_aliases);
    free(rs->nodes);
    free(rs->order);
    free(rs->build);
    free(rs->map);
    free(rs->scopes);
    free(rs->damage);
    free(rs->imports);
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

static void view_raster(struct render_node_view *view, struct cairo_buffer *raster) {
	if (!raster) return;
	view->pixels = cairo_image_surface_get_data(raster->surface);
	view->stride = cairo_image_surface_get_stride(raster->surface);
	view->raster_width = cairo_image_surface_get_width(raster->surface);
	view->raster_height = cairo_image_surface_get_height(raster->surface);
}

static struct render_node_view rnode_view(const struct rnode *n) {
	uint32_t type = n->key >> 32;
	struct render_node_view v = {
		.type = type, .id = (uint32_t)n->key, .z = n->z,
		.box = n->box, .rbox = n->rbox,
		.presented = render_present_box(n->presentation, n->rbox),
		.raster_bytes = n->raster_bytes, .has_node = n->draws, .borrowed = n->borrowed,
		.shown = n->draws && !box_empty(n->rbox) && !n->retained,
		.opacity = n->opacity,
        .masked = n->mask_owner != 0,
        .mask_box = {n->paint.mask_box.x, n->paint.mask_box.y,
            n->paint.mask_box.width, n->paint.mask_box.height},
        .clips_len = n->paint.clips_len,
		.crop = {n->raster_placement.crop_x, n->raster_placement.crop_y,
			n->raster_placement.crop_w, n->raster_placement.crop_h},
		.dst_width = n->raster_placement.dst_w, .dst_height = n->raster_placement.dst_h,
		.clip_mark = type == CLAY_RENDER_COMMAND_TYPE_CUSTOM
			&& n->data.custom.customData == RENDER_CLIP_MARK,
		.probe = type == CLAY_RENDER_COMMAND_TYPE_CUSTOM
			&& n->data.custom.customData != RENDER_CLIP_MARK
			&& ((uintptr_t)n->data.custom.customData & RENDER_PROBE_TAG),
		.user_data = n->user_data,
	};
	switch (type) {
	case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
		v.color = n->data.rectangle.backgroundColor;
		v.radii = n->data.rectangle.cornerRadius;
		break;
	case CLAY_RENDER_COMMAND_TYPE_BORDER:
		v.color = n->data.border.color;
		v.radii = n->data.border.cornerRadius;
		break;
	case CLAY_RENDER_COMMAND_TYPE_CUSTOM:
		v.radii = n->data.custom.cornerRadius;
		break;
	}
    if (n->coverage) {
        v.mask_pixels = cairo_image_surface_get_data(n->coverage);
        v.mask_stride = cairo_image_surface_get_stride(n->coverage);
        v.mask_width = cairo_image_surface_get_width(n->coverage);
        v.mask_height = cairo_image_surface_get_height(n->coverage);
    }
	view_raster(&v, n->raster);
	return v;
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

		if ((!n->draws && !(type == CLAY_RENDER_COMMAND_TYPE_CUSTOM && n->data.custom.customData == RENDER_CLIP_MARK)) || n->retained || box_empty(n->rbox)
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
		struct render_node_view view = rnode_view(n);
		if (accept(user, &view, px - n->box.x, py - n->box.y)) {
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
        struct render_node_view view = rnode_view(n);
        if (n->borrowed && !hooks->resolve(hooks->data, n->handle))
            view.has_node = view.shown = false;
        fn(user, &view);
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

int render_masks_created(struct render_state *rs) { return rs->masks_created; }

int render_nodes_created(struct render_state *rs) {
	return rs->created;
}

int render_nodes_swept(struct render_state *rs) {
	return rs->swept;
}

static struct paint_box presented_box(const struct rnode *n, Clay_BoundingBox b,
        const struct render_draw_params *params) {
    b = render_present_box(n->presentation,b);
    float x = roundf((b.x+params->origin_x)*params->scale);
    float y = roundf((b.y+params->origin_y)*params->scale);
    return (struct paint_box){x,y,
        roundf((b.x+b.width+params->origin_x)*params->scale)-x,
        roundf((b.y+b.height+params->origin_y)*params->scale)-y};
}

static struct paint_box presented_local(const struct rnode *n, struct paint_box b,
        const struct render_draw_params *params) {
    return presented_box(n,(Clay_BoundingBox){n->rbox.x+b.x,n->rbox.y+b.y,b.width,b.height},params);
}

static bool target_intersects(struct paint_box box, const struct render_draw_params *params) {
    return box.width > 0 && box.height > 0 && box.x+box.width > 0 && box.y+box.height > 0
        && (!params->width || box.x < params->width) && (!params->height || box.y < params->height);
}

static void transform_clips(const struct rnode *n, struct paint_clip *clips, size_t len,
        const struct render_draw_params *params) {
    for (size_t i=0;i<len;i++) {
        clips[i].box = presented_local(n,clips[i].box,params);
        for (int j=0;j<4;j++) clips[i].radii[j] *= n->presentation.scale*params->scale;
    }
}

static const struct paint_mask *node_coverage(struct render_state *rs,
        const struct rnode *n, struct paint *p) {
    if (!n->mask_owner) return NULL;
    size_t index = rmap_get(rs, n->mask_owner);
    if (index == SIZE_MAX) return NULL;
    struct rnode *owner = &rs->nodes[index];
    if (!owner->coverage) {
        unsigned opens = render_userdata_byte(owner->user_data, RENDER_UD_OPENS_SHIFT);
        const struct clip_scope *scope = scope_named(rs, owner->user_data, opens);
        if (scope) {
            struct clip_scope copy = *scope;
            scope_coverage(rs, owner, &copy);
        }
    }
    if (owner->coverage && !owner->coverage_texture)
        owner->coverage_texture = paint_mask_upload(p,
            cairo_image_surface_get_width(owner->coverage),
            cairo_image_surface_get_height(owner->coverage),
            cairo_image_surface_get_stride(owner->coverage),
            cairo_image_surface_get_data(owner->coverage));
    return owner->coverage_texture;
}

static struct paint_box mask_presented(const struct rnode *n,
        const struct render_draw_params *params) {
    struct paint_box b = n->paint.mask_box;
    return presented_box(n, (Clay_BoundingBox){b.x,b.y,b.width,b.height}, params);
}

struct surface_pass {
    struct render_state *rs;
    const struct rnode *record;
    struct paint *paint;
    const struct render_client_hooks *hooks;
    void *data;
    const struct render_draw_params *params;
};

static void draw_surface(struct wlr_surface *surface, int sx, int sy, void *data) {
    struct surface_pass *pass = data;
    const struct rnode *n = pass->record;
    const struct render_draw_params *params = pass->params;
    if (!surface->mapped || !wlr_surface_has_buffer(surface)) return;
    struct wlr_texture *texture = wlr_surface_get_texture(surface);
    if (!texture) return;
    Clay_BoundingBox logical = {n->box.x+sx-n->surface_origin.x,
        n->box.y+sy-n->surface_origin.y,surface->current.width,surface->current.height};
    struct paint_box dst = presented_box(n,logical,params);
    struct paint_box crop = presented_box(n,n->rbox,params);
    float left = fmaxf(dst.x,crop.x), top = fmaxf(dst.y,crop.y);
    struct paint_box visible = {left,top,fminf(dst.x+dst.width,crop.x+crop.width)-left,
        fminf(dst.y+dst.height,crop.y+crop.height)-top};
    if (!target_intersects(visible,params)) return;
    if (!pass->paint) {
        if (pass->hooks->sample) pass->hooks->sample(pass->data,surface,
            (struct render_box){dst.x,dst.y,dst.width,dst.height},params->scale*n->presentation.scale);
        return;
    }
    struct wlr_gles2_texture_attribs attrs;
    wlr_gles2_texture_get_attribs(texture,&attrs);
    struct paint_texture *import = paint_texture_import(pass->paint,attrs.tex,attrs.target,
        texture->width,texture->height,attrs.has_alpha);
    if (!import) return;
    struct render_state *rs = pass->rs;
    if (rs->imports_len == rs->imports_cap) {
        rs->imports_cap = rs->imports_cap ? rs->imports_cap*2 : 16;
        p_realloc(&rs->imports,rs->imports_cap);
    }
    rs->imports[rs->imports_len++] = import;
    struct wlr_fbox source;
    wlr_surface_get_buffer_source_box(surface,&source);
    const struct wlr_alpha_modifier_surface_v1_state *alpha = wlr_alpha_modifier_v1_get_surface_state(surface);
    struct paint_texture_params draw = {.texture=import,.dst=dst,
        .src={source.x,source.y,source.width,source.height},.transform=wlr_output_transform_invert(surface->current.transform),
        .alpha=n->opacity*(alpha ? alpha->multiplier : 1)};
    draw.mask = node_coverage(rs, n, pass->paint);
    draw.mask_box = mask_presented(n, params);
    if (n->mask_owner && !draw.mask) return;
    draw.clips[draw.clips_len++].box = crop;
    struct paint_clip root = {.box=presented_box(n,n->box,params)};
    paint_radii(root.radii,n->data.custom.cornerRadius);
    bool rounded = false;
    for (int i=0;i<4;i++) {
        root.radii[i] *= params->scale*n->presentation.scale;
        rounded |= root.radii[i] > 0;
    }
    if (rounded) draw.clips[draw.clips_len++] = root;
    const struct clip_masks *masks = rnode_masks(rs,n);
    for (size_t i=masks ? masks->len : 0;i>0;i--) {
        const struct clip_mask *mask = &masks->items[i-1];
        if (mask->path || !rounded_mask_hits(mask,n->rbox)) continue;
        if (draw.clips_len == PAINT_CLIPS) { rs->clip_overflows++; break; }
        struct paint_clip *clip = &draw.clips[draw.clips_len++];
        clip->box = presented_box(n,mask->box,params);
        paint_radii(clip->radii,mask->radii);
        for (int j=0;j<4;j++) clip->radii[j] *= params->scale*n->presentation.scale;
    }
    paint_texture(pass->paint,&draw);
    if (pass->hooks && pass->hooks->drawn) pass->hooks->drawn(pass->data,n->handle,surface);
}

void render_finish(struct render_state *rs) {
    for (size_t i=0;i<rs->imports_len;i++) paint_texture_destroy(rs->imports[i]);
    rs->imports_len = 0;
}

void render_draw(struct render_state *rs, struct paint *p,
        const struct render_client_hooks *hooks, void *data,
        const struct render_draw_params *params) {
    if (!rs->enabled) return;
    for (size_t i=0;i<rs->order_len;i++) {
        struct rnode *n = &rs->nodes[rmap_get(rs,rs->order[i])];
        if (!record_draws(n)) continue;
        if (hooks->skip && hooks->skip(hooks->data,(uintptr_t)n->user_data & RENDER_UD_OWNER_MASK,
                params->skip_cursor,params->skip_wallpaper)) continue;
        if (n->borrowed) {
            struct wlr_surface *surface = hooks->resolve(hooks->data,n->handle);
            if (surface) {
                struct surface_pass pass = {rs,n,p,hooks,data,params};
                wlr_surface_for_each_surface(surface,draw_surface,&pass);
            }
            continue;
        }
        if (!p) continue;
        struct paint_box box = presented_box(n,n->rbox,params);
        if (!target_intersects(box,params)) continue;
        float scale = params->scale*n->presentation.scale;
        if (n->shadow_kind) {
            const struct render_shadow *style = &n->shadow;
            Clay_BoundingBox owner = style->owner_box;
            owner.x += style->offset_x-style->spread;
            owner.y += style->offset_y-style->spread;
            owner.width += 2*style->spread;
            owner.height += 2*style->spread;
            float alpha = style->rgba[3]*n->opacity;
            struct paint_shadow_params shadow = {.box=presented_box(n,owner,params),
                .blur=style->radius*scale,
                .color={style->rgba[0]*alpha,style->rgba[1]*alpha,style->rgba[2]*alpha,alpha}};
            for (int j=0;j<4;j++) shadow.radii[j] = style->corner_radius*scale;
            if (!box_contains(n->clip,n->box)) {
                shadow.clips_len = 1;
                shadow.clips[0].box = presented_box(n,n->clip,params);
            }
            paint_shadow(p,&shadow);
        } else if (n->raster) {
            rnode_upload(rs,n);
            if (!n->texture) continue;
            const struct raster_placement *placement = &n->raster_placement;
            struct paint_texture_params draw = {.texture=n->texture,.dst=box,.alpha=n->opacity,
                .src={placement->crop_x,placement->crop_y,placement->crop_w,placement->crop_h},
                .clips_len=n->paint.clips_len, .mask=node_coverage(rs,n,p),
                .mask_box=mask_presented(n,params)};
            if (n->mask_owner && !draw.mask) continue;
            if (!placement->crop_w) draw.src = (struct paint_box){0,0,n->raster_width,n->raster_height};
            memcpy(draw.clips,n->paint.clips,sizeof(draw.clips));
            transform_clips(n,draw.clips,draw.clips_len,params);
            for (int j=0;j<4;j++) draw.radii[j] = n->paint.radii[j]*scale;
            paint_texture(p,&draw);
        } else {
            struct paint_rect_params draw = n->paint;
            draw.box = box;
            draw.mask = node_coverage(rs,n,p);
            draw.mask_box = mask_presented(n,params);
            if (n->mask_owner && !draw.mask) continue;
            transform_clips(n,draw.clips,draw.clips_len,params);
            draw.cutout = presented_local(n,draw.cutout,params);
            for (int j=0;j<4;j++) {
                draw.radii[j] *= scale;
                draw.cutout_radii[j] *= scale;
            }
            if (n->paint.cutout.width && n->presentation.scale != 1) {
                float edges[4] = {n->paint.cutout.x,n->paint.cutout.y,
                    n->rbox.width-n->paint.cutout.x-n->paint.cutout.width,
                    n->rbox.height-n->paint.cutout.y-n->paint.cutout.height};
                for (int j=0;j<4;j++) edges[j] = edges[j]>0
                    ? MAX(1,lroundf(edges[j]*n->presentation.scale))*params->scale : 0;
                draw.cutout = (struct paint_box){box.x+edges[0],box.y+edges[1],
                    MAX(0,box.width-edges[0]-edges[2]),MAX(0,box.height-edges[1]-edges[3])};
            }
            paint_rect(p,&draw);
        }
    }
}

void render_draw_surface(struct render_state *rs, struct paint *p,
        struct wlr_surface *surface, int width, int height,
        struct render_surface_origin origin, const float radii[4])
{
    struct rnode n = {.mask_scope = SIZE_MAX};
    n.box = n.rbox = n.clip = (Clay_BoundingBox){0, 0, width, height};
    n.opacity = 1;
    n.presentation.scale = 1;
    n.surface_origin = origin;
    n.data.custom.cornerRadius = (Clay_CornerRadius){radii[0], radii[1], radii[3], radii[2]};
    struct render_draw_params params = {.scale = 1, .width = width, .height = height};
    struct surface_pass pass = {rs, &n, p, NULL, NULL, &params};
    wlr_surface_for_each_surface(surface, draw_surface, &pass);
}
