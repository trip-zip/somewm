#ifndef SOMEWM_RENDER_H
#define SOMEWM_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "clay.h"

struct wlr_surface;
struct paint;
struct render_box { float x, y, width, height; };

struct render_state;
struct render_text_attr;

struct render_surface_origin {
	int x, y;
};

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
	uint8_t transform;   /* wl_output_transform of the path and gradient */
};

/* resolve returns a live root surface or NULL. borrow and release track the
 * render_state owning the handle, so an old output cannot release a new owner.
 * configure and reposition receive solved logical geometry; reposition is
 * band-local. Draw callbacks use the render_draw data, other callbacks use data. */
struct render_client_hooks {
    void (*drawn)(void *data, uint64_t handle, struct wlr_surface *surface);
    void (*sample)(void *data, struct wlr_surface *surface, struct render_box box, float scale);
    bool (*skip)(void *data, uint64_t handle, bool cursor, bool wallpaper);
	struct wlr_surface *(*resolve)(void *data, uint64_t handle);
	void (*configure)(void *data, uint64_t handle, int width, int height);
	void (*borrow)(void *data, uint64_t handle, void *owner);
	bool (*release)(void *data, uint64_t handle, void *owner);
	void (*reposition)(void *data, uint64_t handle, int x, int y);
	/* The window origin in surface coordinates. A change invalidates the
	 * applied clip even when the solved box and crop are unchanged.
	 * NULL means a fixed origin at 0,0. */
	struct render_surface_origin (*surface_origin)(void *data, uint64_t handle);
	/* Realized origin relative to the solved origin; width 0 removes the crop.
	 * Optional, like reposition. */
	void (*clip)(void *data, uint64_t handle, int x, int y, int width, int height);
	/* The corner radii cutting the surface, logical pixels, top-left,
	 * top-right, bottom-right, bottom-left; 0 is a square corner. Called on
	 * the first borrow and on change. Optional, like reposition. */
	void (*corners)(void *data, uint64_t handle, const float radii[4]);
	/* Path floats for the solved logical box, 0 for no path. A count above
	 * cap reports overflow. NULL draws no shape leaves. */
	size_t (*shape_ops)(void *data, const struct render_shape *shape,
		float w, float h, float *ops, size_t cap);
	/* The attributes of the text element whose string starts at base, as
	 * byte ranges into that whole string. */
	size_t (*text_attrs)(void *data, void *userData, const char *base,
		const struct render_text_attr **attrs);
	/* Whether the element with this id is in the current frame's tree. A
	 * node whose command vanished is kept, disabled, while its element is;
	 * NULL sweeps it at once. */
	bool (*declared)(void *data, uint32_t id);
	void *data;
};

struct render_state *render_create(void);
struct render_draw_params {
    float scale;
    int origin_x, origin_y;
    bool skip_cursor, skip_wallpaper;
    int width, height;
};
/* A NULL paint visits visible surfaces for damage collection before acquisition. */
void render_draw(struct render_state *rs, struct paint *p,
    const struct render_client_hooks *hooks, void *data,
    const struct render_draw_params *params);
/* Release borrowed texture handles after paint_end. */
void render_finish(struct render_state *rs);
void render_set_paint(struct render_state *rs, struct paint *p, uint64_t generation);
size_t render_damage(struct render_state *rs, struct render_box *out, size_t cap);
size_t render_clip_overflows(struct render_state *rs);

/* Show or hide everything this render_state drew, without dropping the retained
 * nodes, so a band that is raised again does not first flash its last frame. */
void render_set_enabled(struct render_state *rs, bool on);
void render_destroy(struct render_state *rs,
	const struct render_client_hooks *hooks);

/* Returns the number of records whose draw changed, including order and
 * presence. bounds clips commands carrying RENDER_CLIP_BOUNDS. */
int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
	const struct render_client_hooks *hooks, Clay_BoundingBox bounds);

/* Per-frame owner bounds. A clip cuts all paint and input, including shadows.
 * A border bound fits the border ring to the visible frame without resizing
 * the owner's content or changing its protocol geometry. The owner's surface
 * is clipped inside that ring; its separate popup surfaces remain independent. */
void render_constraints_begin(struct render_state *rs);
void render_constraint(struct render_state *rs, uint64_t owner,
    Clay_BoundingBox box, bool border);

/* Identify OUTPUT, whose own rectangle and untinted image paint below all
 * other commands. Zero leaves every element in ordinary command order. */
void render_set_output_id(struct render_state *rs, uint32_t id);

/* Read the retained shadow geometry used for painting and dump records. */
bool render_shadow_box(struct render_state *rs, uint32_t id, Clay_BoundingBox *box);

/* Move the per-output UI tree to the output's position in the layout. */
void render_fades_begin(struct render_state *rs);
void render_fade_carrier(struct render_state *rs, const Clay_RenderCommand *cmd);
void render_fade_alias(struct render_state *rs, uint64_t owner, uint64_t ancestor);
struct render_presentation {
    float scale, fade;
    unsigned anchor;
    Clay_Vector2 origin;
};
struct render_presentation render_carrier_decode(Clay_Color color);
void render_carrier_box(struct render_state *rs, uint32_t id, Clay_BoundingBox box);
struct render_presentation render_owner_presentation(struct render_state *rs, uint64_t owner);
Clay_BoundingBox render_present_box(struct render_presentation pose, Clay_BoundingBox box);
bool render_unpresent(struct render_presentation pose, double *x, double *y);

/* Raster density only. The layout stays in logical pixels. */
void render_set_scale(struct render_state *rs, float scale);

/* The device length of a logical span, rounded at both edges: what every
 * raster buffer is sized by, so a surface sized with it lands in its box
 * without resampling. */
int render_device_len(int origin, int len, float scale);

/* The userData channel: Clay carries each element's userData word into its
 * render commands untouched, and the renderer retains it per node. The word
 * is a packed integer, never a pointer, so a retained command can never
 * dangle into freed declarer state. Bits 0-39 are the declarer's to encode
 * and to read through render_node_view.user_data; the renderer reads the three
 * bytes above them:
 *
 * - bits 40-47, the opacity of an IMAGE command: 0 means unset, fully
 *   opaque, else 1 + opacity * 254.
 * - bits 48-55, the clip scope a RECTANGLE or CUSTOM shape or clip mark
 *   opens, 0 for none. A scope is the host's box and radius or path, named by this
 *   number under the word's bits 0-39, so two declarers never share one; it
 *   lives for the frame. A TEXT command opens no scope and carries its text
 *   flags here instead (render_text.h).
 * - bits 56-63, the scope the command is clipped by: 0 for none, a number a
 *   command earlier in the frame opened under the same bits 0-39, or
 *   RENDER_CLIP_BOUNDS for the bounds render_reconcile() was handed. A
 *   command is cut to the scope's box and all its masks; a command that
 *   opens a scope of its own intersects it with the one it is clipped by.
 *
 * These scopes provide shaped clipping. Clay's SCISSOR commands provide
 * rectangular clipping for passive hosts, scrolling and the inspector;
 * the renderer intersects both kinds of clip when they overlap. */
#define RENDER_UD_OWNER_MASK 0xFFFFFFFFFFULL

/* An input host that opens a clip scope without drawing pixels. */
#define RENDER_CLIP_MARK ((void *)(uintptr_t)UINT64_MAX)
struct render_shadow {
	uint64_t gen;
    uint64_t owner;
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

/* A client's configure probe: a CUSTOM leaf naming the client's handle
 * that realizes nothing and sends its solved size as the configure. A
 * surface leaf drawn beside a probe carries RENDER_PROBED_TAG and sends
 * none. */
#define RENDER_PROBE_TAG (UINT64_C(1) << 61)
#define RENDER_PROBED_TAG (UINT64_C(1) << 60)

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

struct render_node_view {
	uint32_t type;   /* Clay_RenderCommandType */
	uint32_t id;     /* the Clay element id; TEXT and BORDER carry a
			  * Clay-derived per-line / per-side hash instead */
	int16_t z;
	Clay_BoundingBox box;   /* solved geometry, or owner-relative shadow geometry */
	Clay_BoundingBox rbox;  /* what was realized, after the clip */
	Clay_BoundingBox presented;
	Clay_Color color;
	Clay_CornerRadius radii;
	float opacity;
	bool shown;
	/* ARGB32 pixels borrowed until the next reconcile or render_destroy. */
	const unsigned char *pixels;
	size_t stride;
	int raster_width, raster_height;
	/* Submitted source crop in device pixels; zero means the full raster. */
	Clay_BoundingBox crop;
	int dst_width, dst_height;
	size_t raster_bytes;    /* nonzero for a node holding a cairo raster */
	bool borrowed;
	bool has_node;          /* false for a SCISSOR marker, a clip mark or a
				 * dead surface */
	bool clip_mark;         /* a CUSTOM command carrying RENDER_CLIP_MARK */
	bool probe;             /* a CUSTOM command carrying RENDER_PROBE_TAG */
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

/* Filter a Clay element candidate at a band-local point through its retained
 * masks and its own shaped host. An element with no paint record adds no
 * restriction; its ancestors still filter the subtree in the widget walk. */
bool render_point_in_masks(struct render_state *rs, uint32_t element_id,
	double x, double y);

/* Visits retained records in draw order. A dead surface reads as no draw. */
void render_walk(struct render_state *rs, const struct render_client_hooks *hooks,
	void (*fn)(void *user, const struct render_node_view *view), void *user);

/* Profiling readback, logged on every solve so a long-running session can
 * assert growth stays proportional to on-screen content: live retained nodes
 * (including those kept disabled for an element still in the tree), resident
 * cairo raster bytes across them, and buffers allocated by the last
 * reconcile pass. */
size_t render_node_count(struct render_state *rs);
size_t render_raster_bytes(struct render_state *rs);
int render_buffers_created(struct render_state *rs);

/* Draws gained and lost during the last reconcile. */
int render_nodes_created(struct render_state *rs);
int render_nodes_swept(struct render_state *rs);

void render_draw_surface(struct render_state *, struct paint *, struct wlr_surface *,
    int width, int height, struct render_surface_origin, const float radii[4]);

#endif
