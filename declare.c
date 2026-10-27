/*
 * declare.c - the per-output declare/solve boundary for the Clay tree
 *
 * Each output owns one Clay context sized to its effective resolution and
 * one render_state. Per dirty frame the declare pass rebuilds the output's
 * tree: every box somewm computes elsewhere enters as a fixed floating leaf
 * attached to Clay's root, so Clay places without solving it. While the
 * session is locked the same pass adds the lock section (the backdrop, the
 * covers, the lock surface) at the top of the same tree.
 *
 * Draw order is Clay's own: zIndex picks the band and declaration order
 * breaks ties inside it. The bands are the table below; within one, clients
 * follow the stack and layer-shell surfaces the oldest first.
 */

#define _DEFAULT_SOURCE
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wlr/backend/headless.h>
#include <wlr/backend/wayland.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_xcursor_manager.h>
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
#include "xwayland.h"
#include "common/buffer.h"
#include "common/lualib.h"
#include "luaa.h"
#include "common/util.h"
#include "objects/client.h"
#include "objects/drawin.h"
#include "objects/screen.h"

void luaA_drawin_set_solved_geometry(lua_State *L, drawin_t *drawin,
        int x, int y, int width, int height);

/* The output's Clay context plus the render_state its solved commands
 * reconcile into, and the readback the tree dump prints. */
struct declared_host {
    struct widget_host host;
    struct widget_tree *view;
};

/* What a track or thumb node declared from its scroll record: the thumb's
 * length and the track's offset along axis (2 is y), both 0 when the
 * content fits and the track collapses. The dump prints these. */
struct scrollbar_record {
	Clay_ElementId id, node;
	bool found, collapsed;
	uint8_t axis;
	float length, offset;
	Clay_Vector2 position;
	Clay_Dimensions content, box;
};

struct exit_owner { uint64_t handle; int ref; };

struct declare_band {
    bool exhausted, context_valid, inspector_refused;
    bool inspector_solving, inspector_collision_logged;
    int inspector_elements, inspector_strings, inspector_authored;
    char *retained_dump;
    struct clay_capacity committed_capacity;
    const struct declare_record *previous_records;
    size_t previous_records_len;
    struct clay_transition_baseline *transition_baselines;
    size_t transition_baselines_len, transition_baselines_cap;
    bool transition_budget_warned;
    const char *output_name;
    uint32_t *entrances;
    size_t entrances_len, entrances_cap;
    struct exit_owner *exit_owners;
    size_t exit_owners_len, exit_owners_cap;
    uint64_t *command_handles;
    size_t command_handles_len;
    struct declared_host *hosts;
    size_t hosts_len;
    struct widget_tree **retired;
    size_t retired_len;
    int fail_elements;
    size_t clips_declared;
    bool cut_pending;    /* configuring a cut node: no record is counted */
    /* The scrollbar records of this band's last frame. */
    struct scrollbar_record scrollbar_records[WIDGET_SCROLLS_OUTPUT_MAX * 2];
    size_t scrollbar_records_len;
	Clay_Context *clay;
	void *arena;
	struct wlr_scene_tree *tree;
	struct render_state *render;
	float scale;
	/* The last frame's readback for the tree dump: what the solve
	 * produced, what the reconcile changed, and how long each step took.
	 * Written by declare_output_frame only, so a band that has not drawn
	 * since the last dump reports the frame it did draw. */
	int commands, mutations;
	/* Frames this band has run, for the dump: a transition that has
	 * settled stops raising it. */
	int frames;
	/* A transition ran last frame: Clay takes a completed one back to its
	 * settled state on the frame after, which is where the next one
	 * starts from (third_party/clay.h:5068-5073). */
	bool transitioning;
	int64_t declare_us, solve_us, reconcile_us;
	/* What the last frame's pass declared, in declaration order, for the
	 * tree dump: the desktop-level elements (roots, client frames, bar
	 * slots, leaves) with their parent, sizing and where each number came
	 * from. A widget tree records its root only; the dump walks its nodes
	 * from the retained widget_tree. Filled by declare_output_frame's pass
	 * alone; queries read the completed declarations and commands. */
	struct declare_record *records;
	size_t records_len, records_cap;
	/* Words declared for elements no record stands for: Clay's root,
	 * sized by the output, and a slot Clay retains after its last
	 * declaration and solves from its transition record. */
	struct element_word {
		uint32_t id;
		uint8_t src[2];
	} *words;
	size_t words_len, words_cap;
	/* The client frames this pass declared whose box Clay solves, by
	 * handle and frame id: what clients_settle reads back. */
	struct settle_frame {
		uint64_t handle;
		uint32_t id, x11_configure_serial;
	} *settle;
	size_t settle_len, settle_cap;
};

const char *const declare_src_names[DECLARE_SRC_COUNT] = {
	[DECLARE_SRC_USER] = "user",
	[DECLARE_SRC_THEME] = "theme",
	[DECLARE_SRC_OUTPUT] = "output",
	[DECLARE_SRC_PROTOCOL] = "protocol",
	[DECLARE_SRC_LEGACY] = "legacy",
	[DECLARE_SRC_TRANSITION] = "transition",
	[DECLARE_SRC_SCROLL] = "scroll",
	[DECLARE_SRC_DERIVED] = "derived",
};

enum declare_src
declare_src_parse(const char *word)
{
	for (int i = DECLARE_SRC_USER; word && i <= DECLARE_SRC_DERIVED; i++)
		if (!strcmp(word, declare_src_names[i]))
			return i;
	return DECLARE_SRC_NONE;
}

struct declare_record {
    bool client_frame;
    uint32_t x11_configure_serial;
	const char *role;
	uint64_t handle;       /* the object it stands for, 0 for none */
	int screen_index;     /* SCREEN ownership captured at declaration */
	uint32_t id;           /* the Clay element id, for the solved box */
	Clay_Sizing sizing;
	uint8_t src[2];        /* enum declare_src per axis */
	bool floating;
	Clay_FloatingAttachToElement attach_to;
	uint32_t attach_id;
	Clay_Vector2 offset;
	Clay_Dimensions expand;
	Clay_FloatingAttachPoints points;
	bool passthrough;
	int16_t band;
	bool vertical;
	Clay_Padding padding;
	uint16_t gap;
	bool custom, image, clip;
	Clay_CornerRadius radius;
	/* A widget tree root: the host whose nodes the dump walks under it. */
	bool has_host;
    bool client_exit;
    struct widget_transition exit_policy;
	struct widget_host host;
};


struct declare_output {
	struct wlr_output *wlr_output;
	struct declare_band band;
	bool dirty;
	/* The frame deadline: a mark arms it, and an output the backend never
	 * frames (a nested window on an unviewed tag, an asleep monitor) runs
	 * its frame when it fires. */
	struct wl_event_source *deadline;
	bool deadline_armed;
	/* Shared wallpaper source and this output's layout-logical selection. */
	struct image_entry wallpaper;
	/* This output's copy of the themed pointer image at its scale, keyed
	 * on the xcursor frame it was built from and the seat's image
	 * generation; whether the last frame declared the pointer here. */
	struct image_entry cursor;
	const struct wlr_xcursor_image *cursor_frame;
	uint64_t cursor_gen;
	bool cursor_shown;
	/* Requested inspector visibility, committed panel width for input gating,
     * and the press latched for the next solve. Failed frames keep the
     * committed panel's hit area until a successful retry removes it. */
	bool inspecting;
    unsigned inspector_width;
	bool press_pending;
	double scroll_x, scroll_y;
	int64_t last_frame_us;
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
/* Whether this frame declares the debug panel. Clay declares it above every
 * band this file can name (clay.h:3765, 3890, 3912), so a locked screen
 * would show the desktop's whole tree through the lock; the screen's own
 * setting stays put and comes back on unlock. */
static bool inspector_declares(const struct declare_output *dout);
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
	uint8_t t = shape->transform;
	bool turn = t == WL_OUTPUT_TRANSFORM_90 || t == WL_OUTPUT_TRANSFORM_270;
	lua_pushnumber(L, turn ? h : w);
	lua_pushnumber(L, turn ? w : h);
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
	/* The path was drawn in the unrotated box; carry its points into (w, h). */
	for (size_t i = 0; t && len <= cap && i < len; ) {
		float op = ops[i++];
		size_t points = op == 0 || op == 1 ? 1 : op == 2 ? 3 : 0;
		for (size_t k = 0; k < points && i + 1 < len; k++, i += 2) {
			float x = ops[i], y = ops[i + 1];
			switch (t) {
			case WL_OUTPUT_TRANSFORM_90: ops[i] = y; ops[i + 1] = h - x; break;
			case WL_OUTPUT_TRANSFORM_180: ops[i] = w - x; ops[i + 1] = h - y; break;
			case WL_OUTPUT_TRANSFORM_270: ops[i] = w - y; ops[i + 1] = x; break;
			case WL_OUTPUT_TRANSFORM_FLIPPED: ops[i] = w - x; break;
			case WL_OUTPUT_TRANSFORM_FLIPPED_180: ops[i + 1] = h - y; break;
			}
		}
	}
	return len;
}

static size_t
text_attrs(void *data, void *userData, const char *base,
    const struct render_text_attr **attrs)
{
    enum declare_kind kind = 0;
    void *owner = declare_handle_get(declare_userdata_handle(userData), &kind);
    struct widget_tree *tree = NULL;
    *attrs = NULL;
    if (!owner) return 0;
    if (kind == DECLARE_KIND_DRAWIN) {
        tree = &((drawin_t *)owner)->widgets;
    } else if (kind == DECLARE_KIND_TITLEBAR) {
        drawable_t *drawable = owner;
        Client *c = drawable->owner_type == DRAWABLE_OWNER_CLIENT ? drawable->owner.client : NULL;
        if (c)
            for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++)
                if (c->titlebar[bar].drawable == drawable)
                    tree = &c->titlebar[bar].widgets;
    }
    if (!tree || !tree->text) return 0;
    for (size_t i = 0; i < tree->nodes_len; i++) {
        const struct widget_node *n = &tree->nodes[i];
        if (n->text && n->attr_len && tree->text + n->text_off == base) {
            *attrs = tree->text_attrs + n->attr_off;
            return n->attr_len;
        }
    }
    return 0;
}

/* Read after the solve, during the reconcile, like the shadow owner boxes:
 * Clay prunes every element the frame did not declare. */
static bool
declared(void *data, uint32_t id)
{
	(void)data;
	return Clay_GetElementData((Clay_ElementId){.id = id}).found;
}

void
declare_set_client_hooks(const struct render_client_hooks *hooks)
{
	client_hooks = *hooks;
	client_hooks.shape_ops = shape_ops;
	client_hooks.text_attrs = text_attrs;
	client_hooks.declared = declared;
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

static void
root_entrance(Clay_ElementId id, const Clay_ElementDeclaration *declaration)
{
    if (recording->exhausted) return;
    if (!declaration->transition.enter.setInitialState) return;
    for (size_t i = 0; i < recording->previous_records_len; i++)
        if (recording->previous_records[i].id == id.id) return;
    clay_reenter(id, true);
    if (recording->entrances_len == recording->entrances_cap) {
        recording->entrances_cap = recording->entrances_cap ? recording->entrances_cap * 2 : 8;
        p_realloc(&recording->entrances, recording->entrances_cap);
    }
    recording->entrances[recording->entrances_len++] = id.id;
}

static void
record_begin(struct declare_band *band)
{
	recording = band;
	band->records_len = 0;
    band->entrances_len = 0;
	band->settle_len = 0;
}

static void
record_end(void)
{
	recording = NULL;
}

static bool native_full(void)
{
    if (!recording) return false;
    if (!recording->exhausted && clay_declaration_full()) {
        recording->exhausted = true;
        fprintf(stderr, "clay element capacity exhausted; retained scene\n");
    }
    return recording->exhausted;
}

static void native_open(Clay_ElementId id)
{
    if (!native_full()) Clay__OpenElementWithId(id);
}

static void native_configure(const Clay_ElementDeclaration *declaration)
{
    if (recording && recording->exhausted) return;
    bool clip = declaration->clip.horizontal || declaration->clip.vertical;
    if (clip && recording && !recording->cut_pending
            && recording->clips_declared++ == WIDGET_SCROLLS_OUTPUT_MAX) {
        recording->exhausted = true;
        fprintf(stderr, "clay scrolling declarations exceed 100 records; retained scene\n");
        return;
    }
    Clay_ElementDeclaration configured = *declaration;
    if (configured.transition.handler) {
        if (!clay_transition_admit(recording->transition_baselines, recording->transition_baselines_len)) {
            configured.transition = (Clay_TransitionElementConfig){0};
            if (!recording->transition_budget_warned) {
                recording->transition_budget_warned = true;
                fprintf(stderr, "clay output %s: drawin %llu exceeds 200 transition records; remaining nodes snap\n",
                    recording->output_name, (unsigned long long)declare_userdata_handle(configured.userData));
            }
        }
    }
    Clay__ConfigureOpenElementPtr(&configured);
    if (clip) clay_clip_restore();
}

static void native_close(void)
{
    if (!recording || !recording->exhausted) Clay__CloseElement();
}

static void native_text(Clay_String text, Clay_TextElementConfig config)
{
    if (!native_full()) Clay__OpenTextElement(text, config);
}

/* Whether an axis carries a number (spec D060), so a word belongs to it. */
static bool
numbered(Clay_SizingAxis a)
{
	return a.type == CLAY__SIZING_TYPE_FIXED || a.type == CLAY__SIZING_TYPE_PERCENT
		|| a.size.minMax.min > 0 || a.size.minMax.max > 0;
}

/* Declare the words of an element no record stands for. */
static void
declare_element_word(struct declare_band *band, Clay_ElementId id,
	enum declare_src wsrc, enum declare_src hsrc)
{
	struct element_word *w = NULL;

	if (!band)
		return;
	for (size_t i = 0; i < band->words_len; i++)
		if (band->words[i].id == id.id)
			w = &band->words[i];
	if (!w) {
		if (band->words_len == band->words_cap) {
			band->words_cap = band->words_cap ? band->words_cap * 2 : 8;
			p_realloc(&band->words, band->words_cap);
		}
		w = &band->words[band->words_len++];
	}
	*w = (struct element_word) { .id = id.id, .src = { wsrc, hsrc } };
}

/* Exit subtrees still refer to their owners' shape and shadow storage. */
static void
hold_exit_owner(struct declare_band *band, uint64_t handle)
{
    for (size_t i = 0; i < band->exit_owners_len; i++)
        if (band->exit_owners[i].handle == handle) return;
    enum declare_kind kind;
    void *owner = declare_handle_get(handle, &kind);
    if (!owner || (kind != DECLARE_KIND_CLIENT && kind != DECLARE_KIND_DRAWIN)) return;
    if (band->exit_owners_len == band->exit_owners_cap) {
        band->exit_owners_cap = band->exit_owners_cap ? band->exit_owners_cap * 2 : 8;
        p_realloc(&band->exit_owners, band->exit_owners_cap);
    }
    luaA_object_push(globalconf_L, owner);
    band->exit_owners[band->exit_owners_len++] = (struct exit_owner) {
        handle, luaL_ref(globalconf_L, LUA_REGISTRYINDEX)};
}

static void
release_exit_owners(struct declare_band *band, const uint64_t *owners, size_t len)
{
    for (size_t i = 0; i < band->exit_owners_len;) {
        struct exit_owner owner = band->exit_owners[i];
        bool used = false;
        for (size_t j = 0; j < len; j++) used |= owners[j] == owner.handle;
        if (used) { i++; continue; }
        if (globalconf_L) luaL_unref(globalconf_L, LUA_REGISTRYINDEX, owner.ref);
        band->exit_owners[i] = band->exit_owners[--band->exit_owners_len];
    }
}

static void
record_open(const char *role, uint64_t handle, Clay_ElementId id,
	const Clay_ElementDeclaration *decl, enum declare_src wsrc,
	enum declare_src hsrc, const struct widget_host *host)
{
	struct declare_band *band = recording;
	struct declare_record *r;

	if (!band || band->exhausted)
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
		.sizing = decl->layout.sizing,
		.src = { numbered(decl->layout.sizing.width) ? wsrc : DECLARE_SRC_NONE,
			numbered(decl->layout.sizing.height) ? hsrc : DECLARE_SRC_NONE },
		.floating = decl->floating.attachTo != CLAY_ATTACH_TO_NONE,
		.attach_to = decl->floating.attachTo,
		.attach_id = decl->floating.parentId,
		.offset = decl->floating.offset,
		.expand = decl->floating.expand,
        .points = decl->floating.attachPoints,
        .passthrough = decl->floating.pointerCaptureMode == CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
		.band = decl->floating.zIndex,
		.vertical = decl->layout.layoutDirection == CLAY_TOP_TO_BOTTOM,
		.padding = decl->layout.padding,
		.gap = decl->layout.childGap,
		.custom = decl->custom.customData != NULL && decl->custom.customData != RENDER_CLIP_MARK,
		.radius = decl->cornerRadius,
		.image = decl->image.imageData != NULL,
		.clip = render_userdata_byte(decl->userData, RENDER_UD_OPENS_SHIFT) != 0,
		.has_host = host != NULL,
	};
	if (host)
		r->host = *host;
	band->records_len++;
    if (decl->transition.exit.setFinalState) hold_exit_owner(band, handle);
}

static void
record_client_exit(const struct widget_node *n)
{
    if (!recording || recording->exhausted || !recording->records_len
            || !n->name || strcmp(n->name, "CLIENT") || !n->transition.enabled) return;
    struct declare_record *record = &recording->records[recording->records_len - 1];
    record->client_exit = true;
    record->exit_policy = n->transition;
    if (n->transition.exit_state || n->transition.tag_exit)
        hold_exit_owner(recording, n->client);
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
declare_leaf(const char *role, uint64_t handle, enum declare_src wsrc,
	enum declare_src hsrc, Clay_ElementId id, Clay_ElementDeclaration *decl)
{
	native_open(id);
	native_configure(decl);
	record_open(role, handle, id, decl, wsrc, hsrc, NULL);
	native_close();
}

/* --- the draw order ---
 *
 * A flow element has no band; a floating
 * element's band is its zIndex. Clay sorts floating tree roots by zIndex
 * (every floating element is one, clay.h:2154-2159; the sort is at
 * clay.h:2703-2714 and is stable), so declaration order decides only within
 * a band. A window's band comes from its stacking attribute; a transient
 * that sets none of its own inherits its parent's. Layer-shell background
 * and bottom, desktop clients and drawins, plain wiboxes and fullscreen
 * backing elements each use the bands declared below.
 * The flow root is in that sort too, at zIndex 0,
 * so what draws under the bars (a wallpaper wibox, a desktop client, the
 * background and bottom layers) carries a negative band.
 * Clay places each root from its parent's box (clay.h:2720-2726), which is
 * written when the parent is walked (clay.h:3091); a root below 0 is walked
 * before the flow root, so a parent inside the flow still has the last
 * frame's box. A band below the flow root therefore belongs only to a root
 * attached to the output: a tiled client's band floors at 0, and its
 * surface follows its frame. */
enum {
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
	/* The lock section. Above every band above, so a locked session shows
	 * the backdrop and nothing else whatever the desktop declared: the
	 * roots are sorted by zIndex (clay.h:3479-3492) and the reconcile
	 * keeps that order in the scene (render.c:2505-2528). The backdrop is
	 * also what stops the input walk (hit_accept, DECLARE_KIND_LOCK_BLOCK). */
	Z_LOCK_BACKDROP = 200,
	Z_LOCK_COVER = 210,
	Z_LOCK_SURFACE = 220,
	/* The pointer image, above the lock section and above Clay's own
	 * inspector panel (clay.h:3890-3912 declares that at 32765 and
	 * 32766), so the pointer is never under anything it points at. */
	Z_CURSOR = INT16_MAX,
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

/* The word with its two clip bytes (render.h): the scope a command opens
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
		ud = render_hit_userdata(dout->band.render, node, &client_hooks);
		if (ud)
			return declare_handle_get(
				declare_userdata_handle(ud), kind);
	}
	return NULL;
}

/* --- the input walk (declare.h) --- */

static bool declarable_client(Client *c);

struct hit_walk {
    struct render_state *render;
    Monitor *monitor;
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
	case DECLARE_KIND_LOCK_BLOCK:
		/* The lock backdrop. It answers the point with nothing, which
		 * ends the walk: the desktop nodes below it are retained and
		 * must not take input through the lock. */
		*out = (struct declare_hit) { 0 };
		return true;
	case DECLARE_KIND_DRAWIN: {
		drawin_t *d = obj;

		/* A retained node outlives a hidden drawin by one frame: the
		 * drawin is unregistered at once and stays in the order until
		 * the next solve. Only what the next frame would declare takes
		 * the point. */
		if (!d->visible)
			return false;
		double dx = w->lx - w->monitor->m.x, dy = w->ly - w->monitor->m.y;
		struct render_presentation pose = render_owner_presentation(w->render,
			declare_handle_for(d, DECLARE_KIND_DRAWIN));
		if (!render_unpresent(pose, &dx, &dy)) return false;
		dx += w->monitor->m.x - d->x;
		dy += w->monitor->m.y - d->y;
		if (!drawin_accepts_input_at(d, dx, dy))
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
		if (client_is_x11(c))
			surface = wlr_surface_surface_at(client_surface(c), sx, sy,
				&sub_x, &sub_y);
		else
		{
			struct wlr_box geo = c->surface.xdg->geometry;

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
	case DECLARE_KIND_CURSOR:
		/* The pointer image: what is under the pointer is under it. */
		return false;
	default:
		/* The output's own background, the drag icon: nothing takes the
		 * point here; whatever is below may. */
		return false;
	}
}

static bool
hit_band(struct declare_band *band, Monitor *m, struct hit_walk *w)
{
	w->render = band->render;
    w->monitor = m;
	return band->render && render_hit(band->render, w->lx - m->m.x,
		w->ly - m->m.y, hit_accept, w);
}

/* While locked the walk still starts at the top of the same order, where
 * the lock section is, and the backdrop takes the point (hit_accept,
 * DECLARE_KIND_LOCK_BLOCK), so no desktop node below it is ever asked. */
static bool
hit_output(Monitor *m, struct hit_walk *w)
{
	return m->declare && hit_band(&m->declare->band, m, w);
}

void
declare_hit_at(double lx, double ly, struct declare_hit *out)
{
	struct hit_walk w = {.out = out, .lx = lx, .ly = ly};
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

/* A shadow is paint: the renderer draws it from its owner's solved box and
 * the authored offset, spread and radius. Its element holds identity, band
 * and order only; Clay would place a lower-band float from its parent's
 * previous-frame box (clay.h:2720-2726), so no box of its own is declared. */
static void
declare_shadow(struct render_shadow *shadow, const shadow_config_t *override,
	bool drawin, uint64_t handle, const Clay_ElementDeclaration *owner)
{
	const shadow_config_t *config = shadow_get_effective_config(override, drawin);
	if (!config->enabled)
		return;
	struct render_shadow value = {
		.radius = MAX(0, config->radius),
		.corner_radius = MAX(0, config->corner_radius),
		.rgba = {config->color[0], config->color[1], config->color[2], shadow_paint(config)},
	};
	if (shadow->radius != value.radius || shadow->corner_radius != value.corner_radius
			|| memcmp(shadow->rgba, value.rgba, sizeof(value.rgba))) {
		value.gen = shadow->gen + 1;
		*shadow = value;
	}
    shadow->owner = handle;
	shadow->owner_id = Clay_GetOpenElementId();
	shadow->spread = config->spread;
	shadow->offset_x = config->offset_x;
	shadow->offset_y = config->offset_y;
	Clay_ElementDeclaration e = {
		.floating = {
			.attachTo = CLAY_ATTACH_TO_PARENT,
			/* A frame held in flow by a float (a point menu, a notification
			 * stack) carries its band in its own zIndex. */
			.zIndex = owner->floating.attachTo != CLAY_ATTACH_TO_NONE || owner->floating.zIndex
				? owner->floating.zIndex - 1 : -1,
			.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
			.clipTo = CLAY_CLIP_TO_NONE,
		},
		.custom.customData = render_shadow_tag(shadow),
	};
	enum declare_src src = override ? DECLARE_SRC_USER : DECLARE_SRC_THEME;
	declare_leaf("SHADOW", handle, src, src,
		Clay__HashStringWithOffset(CLAY_STRING("SHADOW"), (uint32_t)handle, 0), &e);
}

static void declare_widget_tree(const struct widget_host *host, int16_t z,
	void *userdata);
static void declare_widget_slot(const struct widget_host *host, Clay_ElementId id,
	const Clay_ElementDeclaration *slot, const char *role, enum declare_src wsrc,
	enum declare_src hsrc, int16_t z, void *userdata);
static Clay_ElementId output_id(Monitor *m);
static Clay_ElementId workarea_id(Monitor *m);

/* Each output pass pins its hosted screens and Lua descriptions until all
 * boxes have been published. The active entry scopes screen composition;
 * output-only declarations run with no active screen. */
struct screen_declaration {
    screen_t *screen;
    struct wlr_box geometry;
    int index, screen_ref;
};
static struct screen_declaration *screen_declarations, *active_screen;
static size_t screen_declarations_len;
static bool screen_subtrees;

static Clay_ElementId
screen_root_id(Monitor *m)
{
    return active_screen && screen_subtrees
        ? Clay__HashStringWithOffset(CLAY_STRING("SCREEN"), active_screen->index, output_id(m).id)
        : output_id(m);
}

static struct wlr_box
screen_origin(Monitor *m)
{
    return active_screen && screen_subtrees ? active_screen->geometry : m->m;
}

static bool
screen_hosted(screen_t *s, Monitor *m)
{
    if (!s || !s->valid || luaA_monitor_get_by_screen(globalconf_L, s) != m)
        return false;
    return s->monitor == m || (s->geometry.x >= m->m.x && s->geometry.y >= m->m.y
        && s->geometry.x + s->geometry.width <= m->m.x + m->m.width
        && s->geometry.y + s->geometry.height <= m->m.y + m->m.height);
}

/* The popups whose parent is `parent` (a toplevel's or a popup's surface),
 * each a borrowed surface leaf attached to the element `parent_id` and
 * offset by the protocol's popup geometry, then their own popups. The
 * parent's window geometry sits at (geo_x, geo_y) inside its element (0,0
 * for a toplevel's surface leaf, which is the window geometry), and the
 * popup's own geometry offset is folded in, so the leaf is the whole
 * surface, shadow margins included. Creation order keeps parents first. */
static void
declare_popups(struct wlr_surface *parent, Clay_ElementId parent_id,
	int geo_x, int geo_y, uint64_t ancestor)
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
        render_fade_alias(recording->render, handle, ancestor);
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
		declare_leaf("popup", handle, DECLARE_SRC_PROTOCOL, DECLARE_SRC_PROTOCOL, id, &s);
		declare_popups(surface, id, geo.x, geo.y, ancestor);
	}
}

static bool animations_disabled;

static bool animation_owner_disabled(void *userdata)
{
    enum declare_kind kind = 0;
    void *owner = declare_handle_get(declare_userdata_handle(userdata), &kind);
    if (!owner) return false;
    if (kind == DECLARE_KIND_DRAWIN) return ((drawin_t *)owner)->animation_disabled;
    Client *client = kind == DECLARE_KIND_CLIENT ? owner : NULL;
    if (kind == DECLARE_KIND_TITLEBAR) {
        drawable_t *drawable = owner;
        if (drawable->owner_type == DRAWABLE_OWNER_CLIENT) client = drawable->owner.client;
    }
    if (!client) return false;
    luaA_object_push(globalconf_L, client);
    lua_getfield(globalconf_L, -1, "animation");
    bool disabled = lua_isboolean(globalconf_L, -1) && !lua_toboolean(globalconf_L, -1);
    lua_pop(globalconf_L, 2);
    return disabled;
}

/* Clay's ease-out on whole pixels. The scene truncates at its boundary, so
 * a fractional box leaves a one pixel seam between an animating element and
 * its neighbour for as long as the animation runs. */
static bool
transition_ease_out(Clay_TransitionCallbackArguments arguments)
{
    clay_exit_initial(&arguments);
    if (animations_disabled || animation_owner_disabled(clay_transition_userdata(&arguments))) {
        arguments.duration = 0;
    }
	bool complete = Clay_EaseOut(arguments);
	Clay_BoundingBox *box = &arguments.current->boundingBox;

	*box = (Clay_BoundingBox) { roundf(box->x), roundf(box->y),
		roundf(box->width), roundf(box->height) };
	return complete;
}

static Clay_TransitionData
transition_compose(Clay_TransitionData state, Clay_TransitionProperty properties, uint16_t effects)
{
    if (effects & WIDGET_TRANSITION_SLIDE_LEFT) state.boundingBox.x = -state.boundingBox.width;
    if (effects & WIDGET_TRANSITION_SLIDE_RIGHT) state.boundingBox.x = Clay_GetLayoutDimensions().width;
    if (effects & WIDGET_TRANSITION_SLIDE_UP) state.boundingBox.y = -state.boundingBox.height;
    if (effects & WIDGET_TRANSITION_SLIDE_DOWN) state.boundingBox.y = Clay_GetLayoutDimensions().height;
    if (effects & WIDGET_TRANSITION_GROW) {
        if (properties & CLAY_TRANSITION_PROPERTY_WIDTH) state.boundingBox.width = 0;
        if (properties & CLAY_TRANSITION_PROPERTY_HEIGHT) state.boundingBox.height = 0;
    }
    if (effects & (WIDGET_TRANSITION_FADE | WIDGET_TRANSITION_SCALES)) {
        unsigned anchor = effects & WIDGET_TRANSITION_SCALE ? 1
            : effects & WIDGET_TRANSITION_SCALE_TOP ? 2
            : effects & WIDGET_TRANSITION_SCALE_BOTTOM ? 3
            : effects & WIDGET_TRANSITION_SCALE_LEFT ? 4
            : effects & WIDGET_TRANSITION_SCALE_RIGHT ? 5 : 0;
        state.overlayColor = (Clay_Color){anchor != 0, !!(effects & WIDGET_TRANSITION_FADE), anchor, 1};
    }
    return state;
}

#define TRANSITION_PAIR(X, name, bits) \
    X(name, bits) \
    X(name##_fade, (bits) | WIDGET_TRANSITION_FADE)
#define TRANSITION_VARIANTS(X, name, bits) \
    TRANSITION_PAIR(X, name, bits) \
    TRANSITION_PAIR(X, name##_grow, (bits) | WIDGET_TRANSITION_GROW) \
    TRANSITION_PAIR(X, name##_scale, (bits) | WIDGET_TRANSITION_SCALE) \
    TRANSITION_PAIR(X, name##_scale_top, (bits) | WIDGET_TRANSITION_SCALE_TOP) \
    TRANSITION_PAIR(X, name##_scale_bottom, (bits) | WIDGET_TRANSITION_SCALE_BOTTOM) \
    TRANSITION_PAIR(X, name##_scale_left, (bits) | WIDGET_TRANSITION_SCALE_LEFT) \
    TRANSITION_PAIR(X, name##_scale_right, (bits) | WIDGET_TRANSITION_SCALE_RIGHT)
#define TRANSITION_STATES(X) \
    TRANSITION_PAIR(X, grow, WIDGET_TRANSITION_GROW) \
    TRANSITION_PAIR(X, scale, WIDGET_TRANSITION_SCALE) \
    TRANSITION_PAIR(X, scale_top, WIDGET_TRANSITION_SCALE_TOP) \
    TRANSITION_PAIR(X, scale_bottom, WIDGET_TRANSITION_SCALE_BOTTOM) \
    TRANSITION_PAIR(X, scale_left, WIDGET_TRANSITION_SCALE_LEFT) \
    TRANSITION_PAIR(X, scale_right, WIDGET_TRANSITION_SCALE_RIGHT) \
    X(fade, WIDGET_TRANSITION_FADE) \
    TRANSITION_VARIANTS(X, slide_left, WIDGET_TRANSITION_SLIDE_LEFT) \
    TRANSITION_VARIANTS(X, slide_right, WIDGET_TRANSITION_SLIDE_RIGHT) \
    TRANSITION_VARIANTS(X, slide_up, WIDGET_TRANSITION_SLIDE_UP) \
    TRANSITION_VARIANTS(X, slide_down, WIDGET_TRANSITION_SLIDE_DOWN)
#define TRANSITION_ADAPTER(name, bits) \
    static Clay_TransitionData transition_##name(Clay_TransitionData state, Clay_TransitionProperty properties) \
    { return transition_compose(state, properties, bits); }
TRANSITION_STATES(TRANSITION_ADAPTER)
#undef TRANSITION_ADAPTER

typedef Clay_TransitionData (*transition_state_fn)(Clay_TransitionData, Clay_TransitionProperty);
static transition_state_fn const transition_states[] = {
#define TRANSITION_ENTRY(name, bits) [bits] = transition_##name,
    TRANSITION_STATES(TRANSITION_ENTRY)
#undef TRANSITION_ENTRY
};
#undef TRANSITION_STATES
#undef TRANSITION_VARIANTS
#undef TRANSITION_PAIR

static transition_state_fn
transition_state(uint16_t state)
{
    return state < LENGTH(transition_states) ? transition_states[state] : NULL;
}

static uint16_t
transition_effects(transition_state_fn state)
{
    if (state)
        for (size_t i = 1; i < LENGTH(transition_states); i++)
            if (transition_states[i] == state) return i;
    return 0;
}

static Clay_TransitionElementConfig
transition_config(const struct widget_transition *n)
{
    return (Clay_TransitionElementConfig) {
        .handler = transition_ease_out, .duration = n->duration,
        .properties = n->properties,
        .interactionHandling = CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION,
        .enter = {.setInitialState = transition_state(n->enter_state)},
        .exit = {.setFinalState = transition_state(n->exit_state ? n->exit_state : n->tag_exit),
            .siblingOrdering = n->exit_order},
    };
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

static void
screen_activate(struct screen_declaration *entry)
{
    active_screen = entry;
}

static void
screens_clear(void)
{
    for (size_t i = 0; i < screen_declarations_len; i++)
        luaL_unref(globalconf_L, LUA_REGISTRYINDEX, screen_declarations[i].screen_ref);
    free(screen_declarations);
    screen_declarations = NULL;
    screen_declarations_len = 0;
    screen_subtrees = false;
    screen_activate(NULL);
}

static bool
screens_prepare(Monitor *m)
{
    lua_State *L = globalconf_L;
    int count = 0;
    screens_clear();
    luaA_screen_get_all(L, NULL, &count);
    screen_t **screens = calloc(count ? count : 1, sizeof(*screens));
    screen_declarations = calloc(count ? count : 1, sizeof(*screen_declarations));
    if (!screens || !screen_declarations) {
        free(screens);
        recording->exhausted = true;
        return false;
    }
    luaA_screen_get_all(L, screens, &count);
    for (int i = 0; i < count; i++) {
        screen_t *screen = screens[i];
        if (!screen_hosted(screen, m)) continue;
        luaA_screen_push(L, screen);
        screen_declarations[screen_declarations_len++] = (struct screen_declaration) {
            .screen = screen, .geometry = screen->geometry, .index = screen->index,
            .screen_ref = luaL_ref(L, LUA_REGISTRYINDEX),
        };
    }
    free(screens);
    screen_subtrees = screen_declarations_len != 1;
    if (screen_declarations_len == 1) {
        struct wlr_box g = screen_declarations[0].geometry;
        screen_subtrees = g.x != m->m.x || g.y != m->m.y
            || g.width != m->m.width || g.height != m->m.height;
    }
    return true;
}

static area_t
client_solved_box(Client *c, Monitor *m, Clay_BoundingBox b)
{
    int x = lroundf(b.x), y = lroundf(b.y);
    /* The frame is described from border_width (awful.client.clay). */
    int border = 2 * client_border(c);
    return (area_t) {
        .x = m->m.x + x, .y = m->m.y + y,
        .width = MAX(1, lroundf(b.x + b.width) - x - border),
        .height = MAX(1, lroundf(b.y + b.height) - y - border),
    };
}

/* Queued geometry signals can arrive after publication. Compare against
 * the retained solve so an authored move or resize still invalidates layout. */
int
luaA_client_geometry_is_solved(lua_State *L)
{
    Client *c = luaA_checkudata(L, 1, &client_class);
    Monitor *m = c->mon;
    bool matches = false;
    if (m && m->declare && m->declare->band.clay) {
        Clay_Context *previous = Clay_GetCurrentContext();
        Clay_SetCurrentContext(m->declare->band.clay);
        Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("client"),
            (uint32_t)declare_handle_for(c, DECLARE_KIND_CLIENT), 0);
        Clay_ElementData data = Clay_GetElementData(id);
        if (data.found) {
            area_t box = client_solved_box(c, m, data.boundingBox);
            matches = AREA_EQUAL(c->geometry, box);
        }
        Clay_SetCurrentContext(previous);
    }
    lua_pushboolean(L, matches);
    return 1;
}

/* The frames declare_client_frame listed write their solved boxes back;
 * an authored box was never listed. */
static void
clients_settle(Monitor *m, struct declare_band *band)
{
    for (size_t i = 0; i < band->settle_len; i++) {
        Client *c = declare_handle_get(band->settle[i].handle, NULL);
        Clay_ElementData data = Clay_GetElementData((Clay_ElementId) { .id = band->settle[i].id });
        if (!c || c->mon != m || !data.found) continue;
        if (c->client_type == X11 && band->settle[i].x11_configure_serial
                && band->settle[i].x11_configure_serial != c->x11_configure.serial) continue;
        /* A pending configure means the chrome still wraps an older answer. */
        if (c->resize) continue;
        /* A fullscreen client's box is the monitor's. */
        if (c->fullscreen) continue;
        client_set_solved_geometry(c, client_solved_box(c, m, data.boundingBox));
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

/* Each unmanaged client is its surface leaf at the protocol's box, above
 * every band a managed client uses, with its popups. */
static void
declare_unmanaged_clients(Monitor *m)
{
	struct wlr_box origin = screen_origin(m);

	foreach(node, globalconf.stack) {
		Client *c = *node;

		if (!c || !client_is_unmanaged(c))
			continue;
		if (monitor_for_unmanaged(c) != m)
			continue;
		if (!declarable_client(c))
			continue;
		uint64_t handle = declare_handle_for(c, DECLARE_KIND_CLIENT);
		Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("SURFACE"),
			(uint32_t)handle, 0);
		Clay_ElementDeclaration s = leaf_at(client_z(c), c->geometry.x - origin.x,
			c->geometry.y - origin.y, c->geometry.width, c->geometry.height);

		s.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
		s.floating.parentId = screen_root_id(m).id;
		s.custom.customData = (void *)(uintptr_t)handle;
		s.userData = leaf_userdata(handle, 1.0f);
		declare_leaf("SURFACE", handle, DECLARE_SRC_PROTOCOL, DECLARE_SRC_PROTOCOL, id, &s);
		declare_popups(client_surface(c), id, 0, 0, handle);
	}
}

/* --- the converted widget tree (widget.h) ---
 *
 * One element per node, nested as lua/wibox/clay.lua compiled them. The
 * root is the drawable's box, or the host slot with the same area. Distinct
 * host insets keep a separate content element.
 * Hosts are cut by each node's userData scope: the scope
 * clipping it and the scope it opens (widget.c assigns scope numbers;
 * render.h defines their encoding). The renderer intersects these scopes
 * with scrolling scissors, keeping overflow inside the host and rounded
 * background children inside its arc.
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

/* Widget containers use stable placement tokens. Anonymous text uses Clay's
 * index hash, including floating siblings; other structure hashes its name, or
 * drawin.widget without one, under its parent's path. Emission, readback and
 * inspection share this rule. */
static Clay_ElementId
widget_child_id(struct widget_tree *d, size_t child, Clay_ElementId parent,
	uint16_t index)
{
	const char *name = d->nodes[child].name;
	Clay_String key = name
		? (Clay_String) { .isStaticallyAllocated = true, .length = (int32_t)strlen(name), .chars = name }
		: CLAY_STRING("drawin.widget");

	if (d->output_fill)
		return (Clay_ElementId) {.id = d->root_id};
	if (d->nodes[child].occurrence)
		return Clay__HashStringWithOffset(key, d->nodes[child].occurrence, 0);
	if (d->nodes[child].text)
		return (Clay_ElementId) { .id = clay_hash_number(index, parent.id) };
	return Clay__HashStringWithOffset(key, index, parent.id);
}

/* A PERCENT axis with its max zeroed. The percent shares a union with the
 * min/max pair, and CLAY_SIZING_PERCENT stores only the percent, leaving
 * max unspecified; Clay still clamps a container's height to that max
 * while it propagates its children's heights up (third_party/clay.h:
 * 2645-2690), so a stray max let a PERCENT container pass its content's
 * height to its parent, which a zero max reports as nothing, as Clay
 * reports a PERCENT element when it closes (third_party/clay.h:1934-1953).
 * The percent is written through min, the member it overlaps. */
static Clay_SizingAxis
clay_percent(float percent)
{
	return (Clay_SizingAxis) { .size.minMax = { percent, 0 }, .type = CLAY__SIZING_TYPE_PERCENT };
}

static Clay_SizingAxis
widget_sizing(const struct widget_node *n, int axis)
{
	switch (n->sizing[axis]) {
	case WIDGET_SIZING_FIXED:
		return CLAY_SIZING_FIXED(n->size[axis]);
	case WIDGET_SIZING_PERCENT:
		/* Percent has no min/max clamps (third_party/clay.h:1863-1871). */
		return clay_percent(n->size[axis]);
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
		.aspectRatio = {.aspectRatio = n->aspect},
		.cornerRadius = { n->radius, n->radius, n->radius, n->radius },
		.userData = userdata,
	};

	if (!n->shape && n->bg[3] > 0)
		e.backgroundColor = clay_color(n->bg);
	else if (render_userdata_byte(userdata, RENDER_UD_OPENS_SHIFT))
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
	if (n->scroll || n->cut) {
		e.clip = (Clay_ClipElementConfig) {
			.horizontal = (n->scroll | n->cut) & 1,
			.vertical = (n->scroll | n->cut) & 2,
		};
	}
	if (n->transition.enabled) e.transition = transition_config(&n->transition);
	if (n->floating) {
		/* A widget float: off the flow, attached to its parent, in the
		 * drawin's band (a floating element is its own tree root, sorted
		 * by zIndex and then declaration order, clay.h:2703-2714). */
		e.floating.offset = (Clay_Vector2) { n->offset[0], n->offset[1] };
		e.floating.attachTo = CLAY_ATTACH_TO_PARENT;
		e.floating.zIndex = z;
		e.floating.attachPoints = (Clay_FloatingAttachPoints) {
			.parent = n->parent, .element = n->own,
		};
		e.floating.pointerCaptureMode = n->passthrough
			? CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH : CLAY_POINTER_CAPTURE_MODE_CAPTURE;
	}
	return e;
}


static size_t
widget_subtree_end(const struct widget_tree *d, size_t i)
{
	size_t next = i + 1;
	for (uint16_t k = 0; k < d->nodes[i].children; k++)
		next = widget_subtree_end(d, next);
	return next;
}

/* Set while a frame that holds a configure probe declares its chrome: the
 * surface leaf in it sends no configure (render.h RENDER_PROBED_TAG). */
static bool composite_probed;

/* A node of a client composite as lua/awful/client/clay.lua describes it.
 * Every node carries the client's word, so a hit routes to the client and
 * its record prints the client's handle. A host node is a titlebar's
 * compiled tree in flow; a surface node is the pixels leaf, floating in its
 * slot: a float adds nothing to its parent's minimum (third_party/clay.h:
 * 2102-2107), so a protocol minimum sizes the surface and never the cell or
 * WORKAREA, and Clay sizes a GROW float to its parent and then clamps it to
 * its own minimum and maximum (third_party/clay.h:2298-2327). */
static size_t
declare_composite(const struct widget_host *host, size_t i, int16_t z,
	uint64_t handle, bool clamp, uint32_t *ids)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	const char *name = n->name ? n->name : "-";
	unsigned clip = clamp ? RENDER_CLIP_BOUNDS : 0;
	/* By name and client, so a node keeps its id when a bar comes or goes
	 * or the client moves between a cell and a root: the surface's scene
	 * tree is borrowed by its command's id. */
	Clay_ElementId id = Clay__HashStringWithOffset((Clay_String) {
		.isStaticallyAllocated = true, .length = (int32_t)strlen(name), .chars = name,
	}, (uint32_t)handle, 0);
	Clay_ElementDeclaration e = {
		.layout.sizing = { widget_sizing(n, 0), widget_sizing(n, 1) },
	};

	ids[i] = id.id;
	if (n->host) {
		drawable_t *drawable = declare_handle_get(n->host, NULL);
		struct widget_host bar;

		if (drawable && drawable_widget_host(drawable, &bar) && bar.tree->nodes_len > 0) {
			bar.flow = true;
            render_fade_alias(recording->render, n->host, handle);
			memcpy(bar.radii, n->radii, sizeof(bar.radii));
			declare_widget_slot(&bar, id, &e, name, n->src[0], n->src[1], z,
				leaf_userdata(n->host, 1.0f));
		} else {
			native_open(id);
			native_configure(&e);
			record_open(name, n->host, id, &e, n->src[0], n->src[1], NULL);
			native_close();
		}
		return widget_subtree_end(d, i);
	}
	if (n->surface) {
		Client *c = declare_handle_get(n->surface, NULL);

		if (!c)
			return i + 1;
		e.floating = (Clay_FloatingElementConfig) {
			.attachTo = CLAY_ATTACH_TO_PARENT,
			.zIndex = client_z(c) < 0 ? z : client_z(c),
			.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
			/* Clipped where an in-flow surface would be: by the slot's
			 * enclosing clip, a carousel's scroll among them. */
			.clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
		};
		e.custom.customData = (void *)(uintptr_t)(n->surface
			| (n->probe ? RENDER_PROBE_TAG : composite_probed ? RENDER_PROBED_TAG : 0));
		e.cornerRadius = (Clay_CornerRadius) { .topLeft = n->radii[0],
			.topRight = n->radii[1], .bottomRight = n->radii[2], .bottomLeft = n->radii[3] };
		e.userData = userdata_clip(leaf_userdata(n->surface, n->opacity), 0, clip);
		declare_leaf(name, n->surface, n->src[0], n->src[1], id, &e);
		/* The client's popups attach to its surface leaf. */
		if (!n->probe)
			declare_popups(client_surface(c), id, 0, 0, handle);
		return i + 1;
	}
	e = widget_node_decl(n, z, userdata_clip(leaf_userdata(handle, 1.0f), 0, clip));
	native_open(id);
	native_configure(&e);
	record_open(name, handle, id, &e, n->src[0], n->src[1], NULL);
    record_client_exit(n);
	size_t next = i + 1;
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_composite(host, next, z, handle, clamp, ids);
	native_close();
	return next;
}

/* A frame whose client drew a size other than the one configured holds
 * two children (awful.client.clay): the cut filling the frame, which holds
 * the chrome, the client's box around the size drawn, and the configure
 * probe filling the frame. */
static bool
frame_holds_chrome(const struct widget_tree *d, size_t i)
{
	return d->nodes[i].children == 2 && !d->nodes[i + 1].client
		&& d->nodes[i + 1].children == 1 && d->nodes[i + 2].client;
}

/* The composite's frame, under the id clients_settle reads it by. The
 * shadow is declared right after it opens, as for a root client. A frame
 * holding a chrome keeps the allocation, takes no input and is not read
 * back; the chrome is declared as the frame. */
static void
declare_client_frame(const struct widget_host *host, size_t i, int16_t z,
	Clay_ElementDeclaration *e, uint8_t wsrc, uint8_t hsrc, uint32_t *ids)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	Client *c = declare_handle_get(n->client, NULL);
	bool clamp = client_clamps_to_monitor(c);
    e->transition.enter.trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME;
	const char *name = n->name ? n->name : "-";

	if (frame_holds_chrome(d, i)) {
		Clay_ElementId frame = Clay__HashStringWithOffset((Clay_String) {
			.isStaticallyAllocated = true, .length = (int32_t)strlen(name), .chars = name,
		}, (uint32_t)n->client, 0);
		const struct widget_node *cut = &d->nodes[i + 1];
		const char *cut_name = cut->name ? cut->name : "-";
		Clay_ElementId cut_id = Clay__HashStringWithOffset((Clay_String) {
			.isStaticallyAllocated = true, .length = (int32_t)strlen(cut_name), .chars = cut_name,
		}, (uint32_t)n->client, 0);
		Clay_ElementDeclaration cut_e = widget_node_decl(cut, z, NULL);
		Clay_ElementDeclaration chrome = widget_node_decl(&d->nodes[i + 2], z, NULL);

		ids[i] = frame.id;
		ids[i + 1] = cut_id.id;
		native_open(frame);
        e->userData = leaf_userdata(n->client, 1.0f);
        native_configure(e);
		root_entrance(frame, e);
		record_open(name, n->client, frame, e, wsrc, hsrc, NULL);
    record_client_exit(n);
		native_open(cut_id);
		native_configure(&cut_e);
		record_open(cut_name, n->client, cut_id, &cut_e, cut->src[0], cut->src[1], NULL);
		composite_probed = true;
		declare_client_frame(host, i + 2, z, &chrome, d->nodes[i + 2].src[0],
			d->nodes[i + 2].src[1], ids);
		composite_probed = false;
		native_close();
		declare_composite(host, widget_subtree_end(d, i + 1), z, n->client, clamp, ids);
		native_close();
		return;
	}
	Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("client"),
		(uint32_t)n->client, 0);
	/* A box the user or a config's layout authored (both axes fixed, spec
	 * D050) is the client's geometry already, and a queued geometry change
	 * may be newer than the tree that declared it: it is never read back. */
	bool authored = !n->x11_configure_serial && n->sizing[0] == WIDGET_SIZING_FIXED && n->sizing[1] == WIDGET_SIZING_FIXED
		&& (n->src[0] == DECLARE_SRC_USER || n->src[0] == DECLARE_SRC_LEGACY);

	if (!authored && recording) {
		struct declare_band *band = recording;
		if (band->settle_len == band->settle_cap) {
			band->settle_cap = band->settle_cap ? band->settle_cap * 2 : 16;
			p_realloc(&band->settle, band->settle_cap);
		}
		band->settle[band->settle_len++] = (struct settle_frame) { n->client, id.id, n->x11_configure_serial };
	}
	ids[i] = id.id;
	e->userData = userdata_clip(leaf_userdata(n->client, 1.0f), 0,
		clamp ? RENDER_CLIP_BOUNDS : 0);
	native_open(id);
    native_configure(e);
    if (!e->transition.handler) clay_exit_transition(id, (Clay_TransitionElementConfig){0});
	root_entrance(id, e);
	record_open(name, n->client, id, e, wsrc, hsrc, NULL);
    if (recording && !recording->exhausted && recording->records_len) {
        struct declare_record *record = &recording->records[recording->records_len - 1];
        record->client_frame = true;
        record->x11_configure_serial = n->x11_configure_serial;
    }
    record_client_exit(n);
	declare_shadow(&c->shadow, c->shadow_config, false, n->client, e);
	size_t next = i + 1;
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_composite(host, next, z, n->client, clamp, ids);
	native_close();
}

/* A layout's client composite (spec D190). In flow in the normal layer the
 * frame takes the node's place with its sizing and words; in another layer
 * it floats over its cell, filling it (a GROW float takes its parent's box,
 * third_party/clay.h:2298-2309), at the layer's zIndex. A float node is
 * attached to its parent, or to the screen's root, at the client's band; a
 * padded float is the cell, holding the frame as its one child. */
static size_t
declare_layout_client(const struct widget_host *host, size_t i, Clay_ElementDeclaration *e,
	uint32_t *ids)
{
    struct widget_tree *d = host->tree;
    const struct widget_node *n = &d->nodes[i];
    size_t end = widget_subtree_end(d, i);
    Client *c = declare_handle_get(n->client, NULL);
    if (!c || !client_has_surface(c) || client_is_unmanaged(c) || !declarable_client(c))
        return end;
    /* A clamped root wholly off its monitor is not declared: the box inside
     * its border, from the node's offset (screen-relative) and fixed size. */
    if (n->attach == WIDGET_ATTACH_OUTPUT && n->sizing[0] == WIDGET_SIZING_FIXED
            && n->sizing[1] == WIDGET_SIZING_FIXED && client_clamps_to_monitor(c)) {
        struct wlr_box origin = screen_origin(host->m);
        int bw = client_border(c);
        int x = n->offset[0] + origin.x - host->m->m.x + bw;
        int y = n->offset[1] + origin.y - host->m->m.y + bw;
        if (x + n->size[0] - 2 * bw <= 0 || y + n->size[1] - 2 * bw <= 0
                || x >= host->m->m.width || y >= host->m->m.height)
            return end;
    }
    int16_t z = client_z(c);
    if (z < 0 && n->attach != WIDGET_ATTACH_OUTPUT)
        z = 0;
    Clay_ElementId cell = Clay__HashStringWithOffset(CLAY_STRING("client.cell"),
        (uint32_t)n->client, 0);
    if (n->floating) {
        if (!n->attach) {
            e->floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
            e->floating.parentId = Clay_GetOpenElementId();
        }
        e->floating.zIndex = z;
        e->floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
        if (!d->nodes[i + 1].client || frame_holds_chrome(d, i)) {
            declare_client_frame(host, i, z, e, n->src[0], n->src[1], ids);
            return end;
        }
        /* The inset is the allocation; surface protocol minima may
         * overhang it without expanding the client border/titlebar area. */
        ids[i] = cell.id;
        native_open(cell);
        native_configure(e);
        record_open("CELL", 0, cell, e, n->src[0], n->src[1], NULL);
        Clay_ElementDeclaration frame = widget_node_decl(&d->nodes[i + 1], z, NULL);
        declare_client_frame(host, i + 1, z, &frame, d->nodes[i + 1].src[0],
            d->nodes[i + 1].src[1], ids);
        native_close();
        return end;
    }
    if (z == Z_CLIENT_NORMAL || z == 0) {
        declare_client_frame(host, i, 0, e, n->src[0], n->src[1], ids);
        return end;
    }
    Clay_ElementDeclaration slot = { .layout.sizing = e->layout.sizing };
    native_open(cell);
    native_configure(&slot);
    record_open("CELL", n->client, cell, &slot, n->src[0], n->src[1], NULL);
    e->layout.sizing = (Clay_Sizing) { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) };
    e->floating = (Clay_FloatingElementConfig) {
        .attachTo = CLAY_ATTACH_TO_PARENT,
        .zIndex = z,
        .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
    };
    declare_client_frame(host, i, z, e, DECLARE_SRC_NONE, DECLARE_SRC_NONE, ids);
    native_close();
    return end;
}

static size_t
declare_widget_subtree(const struct widget_host *host, size_t i, Clay_ElementId id, int16_t z,
	void *userdata, size_t *leaf, const Clay_ElementDeclaration *root_decl, uint32_t *ids,
	Clay_ElementId scroll_id, uint8_t scroll_axis)
{
	struct widget_tree *d = host->tree;
    if (recording && recording->exhausted) return widget_subtree_end(d, i);
	const struct widget_node *n = &d->nodes[i];
	void *word = host->layout ? NULL : userdata_clip(userdata,
		i == 0 && (host->inner_clip || host->path_clip) ? 0 : n->clip_opens,
		i == 0 && (host->inner_clip || host->path_clip) ? n->clip_opens
		: i == 0 && host->frame_clip ? WIDGET_FRAME_SCOPE : n->clip_by);
	Clay_ElementDeclaration e;
	size_t next = i + 1;
	ids[i] = id.id;

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
			.fontId = render_font_transformed(n->font, n->transform),
			.wrapMode = n->wrap,
			.textAlignment = n->text_align,
		};
		native_text((Clay_String) {
			.length = (int32_t)n->text_len,
			.chars = d->text + n->text_off,
		}, cfg);
		return next;
	}

	for (uint32_t k = 0; k < n->binding_count; k++)
		attachment_bind(d->bindings[n->binding_start + k], host->id, id.id);

	e = root_decl ? *root_decl : widget_node_decl(n, z, word);
	if (n->attach) {
		e.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
		e.floating.parentId = screen_root_id(host->m).id;
	}
	if (n->client)
		return declare_layout_client(host, i, &e, ids);
	if (host->inner_clip && n->floating)
		e.floating.clipTo = CLAY_CLIP_TO_ATTACHED_PARENT;
	/* The root declares no Clay clip: a clipping parent never compresses its
	 * children (clay.h:2406-2408), and a root's content must fit its drawin.
	 * The root's renderer scope clips the pixels. */
	if (i == 0 && host->flow && !root_decl) {
		/* A bar's root fills the slot the frame sized for it; the
		 * drawin's geometry is what this element solves to. */
		e.layout.sizing = (Clay_Sizing) {
			host->fit[0] ? widget_sizing(n, 0) : host->told[0] ? CLAY_SIZING_FIXED(host->told[0]) : CLAY_SIZING_GROW(0),
			host->fit[1] ? widget_sizing(n, 1) : host->told[1] ? CLAY_SIZING_FIXED(host->told[1]) : CLAY_SIZING_GROW(0),
		};
	} else if (i == 0 && !root_decl) {
		/* A titlebar root attaches at its parent's origin; a drawin
		 * uses its screen's origin when split, otherwise the output's
		 * (third_party/clay.h:2074-2080,
		 * 2625-2677). Fixed axes use the host box, while an awful.popup
		 * fits within its tree's limits. */
		e.floating.offset = host->in_parent ? (Clay_Vector2) { 0, 0 }
			: (Clay_Vector2) { host->x, host->y };
		e.floating.attachTo = host->in_parent
			? CLAY_ATTACH_TO_PARENT : CLAY_ATTACH_TO_ROOT;
		e.floating.zIndex = z;
        if (!host->in_parent && active_screen && screen_subtrees) {
            e.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
            e.floating.parentId = screen_root_id(host->m).id;
            e.floating.offset.x -= active_screen->geometry.x - host->m->m.x;
            e.floating.offset.y -= active_screen->geometry.y - host->m->m.y;
        }
		e.layout.sizing = (Clay_Sizing) {
			n->sizing[0] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->w) : widget_sizing(n, 0),
			n->sizing[1] == WIDGET_SIZING_FIXED
				? CLAY_SIZING_FIXED(host->h) : widget_sizing(n, 1),
		};
	}
    /* A passthrough drawin's root and floating descendants must let Clay
     * reach the drawable below it, just as render_hit does. */
    if (e.floating.attachTo != CLAY_ATTACH_TO_NONE) {
        enum declare_kind kind;
        void *owner = declare_handle_get(declare_userdata_handle(userdata), &kind);
        if (owner && kind == DECLARE_KIND_DRAWIN && ((drawin_t *)owner)->input_passthrough)
            e.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
    }
	/* The content radius clips every node under a rounded drawin's root. */
	if (i == 0 && host->radius > 0)
		e.cornerRadius = (Clay_CornerRadius) { host->radius,
			host->radius, host->radius, host->radius };
	if (n->image && *leaf < d->leaves_len)
		e.image.imageData = &d->leaves[(*leaf)++];
	if (n->shape)
		e.custom.customData = render_shape_tag(&d->shapes[n->shape - 1].shape);

	/* Once it exits, Clay solves it from its transition record. */
	if (host->layout && n->transition.enabled)
		declare_element_word(recording, id, DECLARE_SRC_TRANSITION, DECLARE_SRC_TRANSITION);
	native_open(id);
	if (n->scroll) {
		e.clip.childOffset = clay_scroll_offset(id);
		float *scrolled = d->nodes[i].scrolled;
		if (scrolled[0] != e.clip.childOffset.x || scrolled[1] != e.clip.childOffset.y)
			d->publish_pending = true;
		scrolled[0] = e.clip.childOffset.x;
		scrolled[1] = e.clip.childOffset.y;
	}
	if (n->track || n->thumb) {
		Clay_ScrollContainerData data = Clay_GetScrollContainerData(scroll_id);
		bool is_y = scroll_axis == 2;
		float box = is_y ? data.scrollContainerDimensions.height
			: data.scrollContainerDimensions.width;
		float content = is_y ? data.contentDimensions.height : data.contentDimensions.width;
		bool collapsed = !data.found || content <= box;
		float len = 0;
		uint16_t offset = 0;
		if (!collapsed) {
			float position = is_y ? data.scrollPosition->y : data.scrollPosition->x;
			len = floorf(box / content * box);
			offset = floorf((box - len) * -position / (content - box));
			if (n->track) {
				if (is_y)
					e.layout.padding.top = offset;
				else
					e.layout.padding.left = offset;
			}
			if (n->thumb) {
				if (is_y)
					e.layout.sizing.height = CLAY_SIZING_FIXED(len);
				else
					e.layout.sizing.width = CLAY_SIZING_FIXED(len);
			}
		} else {
			if (n->thumb || is_y)
				e.layout.sizing.width = CLAY_SIZING_FIXED(0);
			if (n->thumb || !is_y)
				e.layout.sizing.height = CLAY_SIZING_FIXED(0);
		}
		struct declare_band *band = &host->m->declare->band;
		if (band->scrollbar_records_len < LENGTH(band->scrollbar_records)) {
			band->scrollbar_records[band->scrollbar_records_len++] = (struct scrollbar_record) {
				.id = scroll_id,
				.node = id,
				.found = data.found,
				.collapsed = collapsed,
				.axis = scroll_axis,
				.length = len,
				.offset = offset,
				.position = data.found ? *data.scrollPosition : (Clay_Vector2) {0},
				.content = data.contentDimensions,
				.box = data.scrollContainerDimensions,
			};
		} else {
			declare_output_mark_dirty(host->m->declare);
		}
	}
	if (n->cut) {
		recording->cut_pending = true;
		native_configure(&e);
		recording->cut_pending = false;
		if (!recording->exhausted)
			clay_clip_release();
	} else
		native_configure(&e);
    if (i == 0 && root_decl) root_entrance(id, &e);
	/* A layout prints a line per node; its tree has no widget lines. */
	if (host->layout)
		record_open(n->name ? n->name : "-", 0, id, &e, n->src[0], n->src[1], NULL);
	if (i == 0 && !host->flow) {
		/* The root stands for the drawin, at the box placement gave it;
		 * a titlebar's root fills the slot the theme sized. The nodes
		 * under it are the tree's own, walked from the store. A bar's
		 * slot recorded itself with this host. */
		record_open(host->in_parent ? "widgets" : "drawin",
			userdata ? declare_userdata_handle(userdata) : 0, id, &e,
			n->sizing[0] == WIDGET_SIZING_FIXED ? host->src[0] : n->src[0],
			n->sizing[1] == WIDGET_SIZING_FIXED ? host->src[1] : n->src[1], host);
	}
	if (!n->track) {
		scroll_id = (Clay_ElementId) {0};
		scroll_axis = 0;
	}
	size_t child = i + 1;
	for (uint16_t k = 0; k < n->children; k++) {
		if (d->nodes[child].scroll) {
			scroll_id = widget_child_id(d, child, id, k);
			scroll_axis = d->nodes[child].scroll;
			break;
		}
		child = widget_subtree_end(d, child);
	}
	for (uint16_t k = 0; k < n->children; k++)
		next = declare_widget_subtree(host, next,
			widget_child_id(d, next, id, k), z, userdata, leaf, NULL, ids,
			scroll_id, scroll_axis);
	native_close();
	return next;
}

/* Changed trees publish their boxes and ids after the next solve. */
static struct widget_host *solved_hosts;
static size_t solved_len, solved_cap;

static void
widget_host_bind(const struct widget_host *host, Clay_ElementId id)
{
    struct widget_tree *d = host->tree;
    if (!d->declared || d->root_id != id.id) d->publish_pending = true;
    d->root_id = id.id;
    d->declared = true;
    for (size_t i = 0; i < solved_len; i++)
        if (solved_hosts[i].tree == d) return;
    if (solved_len == solved_cap) {
        solved_cap = solved_cap ? solved_cap * 2 : 16;
        p_realloc(&solved_hosts, solved_cap);
    }
    solved_hosts[solved_len++] = *host;
}

static void
declare_widget_tree_at(const struct widget_host *host, Clay_ElementId id, int16_t z,
	void *userdata, const Clay_ElementDeclaration *root_decl)
{
	size_t leaf = 0;
	host->tree->output_fill = false;
	widget_host_bind(host, id);
	declare_widget_subtree(host, 0, id, z, userdata, &leaf, root_decl, host->tree->ids,
		(Clay_ElementId) {0}, 0);
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
	const Clay_ElementDeclaration *slot, const char *role, enum declare_src wsrc,
	enum declare_src hsrc, int16_t z, void *userdata)
{
	const struct widget_node *n = &host->tree->nodes[0];
	Clay_ElementDeclaration e = widget_node_decl(n, z,
		userdata_clip(userdata, n->clip_opens, n->clip_by));
	e.layout.sizing = slot->layout.sizing;
	/* An undecorated content host may itself be an authored fixed widget.
	 * Decorated hosts keep that fixed widget inside their FIT padded frame. */
	if (host->fit[0] && n->sizing[0] == WIDGET_SIZING_FIXED) {
		e.layout.sizing.width = widget_sizing(n, 0);
		wsrc = n->src[0];
	}
	if (host->fit[1] && n->sizing[1] == WIDGET_SIZING_FIXED) {
		e.layout.sizing.height = widget_sizing(n, 1);
		hsrc = n->src[1];
	}
	e.floating = slot->floating;
    if (slot->transition.handler) e.transition = slot->transition;
	if (!n->binding_count && n->children <= 1)
		e.layout.layoutDirection = slot->layout.layoutDirection;
	if (host->radius > 0)
		e.cornerRadius = (Clay_CornerRadius) {host->radius, host->radius,
			host->radius, host->radius};
	else if (host->radii[0] > 0 || host->radii[1] > 0 || host->radii[2] > 0
			|| host->radii[3] > 0)
		e.cornerRadius = (Clay_CornerRadius) { .topLeft = host->radii[0],
			.topRight = host->radii[1], .bottomRight = host->radii[2],
			.bottomLeft = host->radii[3] };
	record_open(role, declare_userdata_handle(userdata), id, &e, wsrc, hsrc, host);
	declare_widget_tree_at(host, id, z, userdata, &e);
}

/* The inner clip element of a decorated host, by the host's handle. */
static Clay_ElementId
inner_clip_id(uint64_t handle)
{
	return Clay__HashStringWithOffset(CLAY_STRING("CLIP"), (uint32_t)handle, 0);
}

static void
drawin_path_frame(drawin_t *d, Clay_ElementDeclaration *frame)
{
	const color_t *color = &d->border_color_parsed;
	d->shape.shape.stroke[0] = color->red;
	d->shape.shape.stroke[1] = color->green;
	d->shape.shape.stroke[2] = color->blue;
	d->shape.shape.stroke[3] = color->alpha;
	d->shape.shape.stroke_width = d->border_width;
	frame->custom.customData = render_shape_tag(&d->shape.shape);
	frame->userData = userdata_clip(leaf_userdata(
		declare_handle_for(d, DECLARE_KIND_DRAWIN), 1), d->widgets.nodes[0].clip_opens, 0);
	frame->border = (Clay_BorderElementConfig){0};
	frame->cornerRadius = (Clay_CornerRadius){0};
}

/* Clay moves only the transitioning frame's box; the tree inside solves at
 * its settled size. A grow clips that tree to the frame through a scope the
 * frame opens. A path frame already opens the root scope itself. */
static bool
frame_grow_clip(const drawin_t *d, Clay_ElementDeclaration *frame)
{
    if (!d->animation.enabled || frame->custom.customData
            || !((d->animation.enter_state | d->animation.exit_state | d->animation.tag_exit)
                & WIDGET_TRANSITION_GROW))
        return false;
    frame->custom.customData = RENDER_CLIP_MARK;
    frame->userData = userdata_clip(frame->userData, WIDGET_FRAME_SCOPE, 0);
    return true;
}

/* A decorated host clips its padded content through an inner renderer
 * element, while its border and shadow keep their own areas. Rounded
 * content retains its separate mask scope. */
static void
declare_widget_frame(drawin_t *d, struct widget_host *host, Clay_ElementId id,
	Clay_ElementDeclaration *slot, const char *role, enum declare_src wsrc,
	enum declare_src hsrc)
{
	uint64_t handle = declare_handle_for(d, DECLARE_KIND_DRAWIN);
	void *word = leaf_userdata(handle, d->opacity >= 0 ? (float)d->opacity : 1.0f);
	int16_t z = slot->floating.zIndex;
    if (d->animation.enabled) {
        /* A caller whose holder exits with the slot keeps its exit trigger. */
        Clay_TransitionExitTriggerType exit_trigger = slot->transition.exit.trigger;
        slot->transition = transition_config(&d->animation);
        slot->transition.enter.trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME;
        slot->transition.exit.trigger = exit_trigger;
    }
	const struct widget_node *n = &host->tree->nodes[0];
	if (!host->path_clip && !d->border_width && !shadow_get_effective_config(d->shadow_config, true)->enabled) {
		declare_widget_slot(host, id, slot, role, wsrc, hsrc, z, word);
		return;
	}
	host->inner_clip = !host->path_clip && host->radius <= 0 && n->radius == 0 && !n->shape;
	native_open(id);
    if (d->animation.enabled && !slot->userData)
        slot->userData = leaf_userdata(handle, 1.0f);
    host->frame_clip = frame_grow_clip(d, slot);
    native_configure(slot);
	root_entrance(id, slot);
	record_open(role, handle, id, slot, wsrc, hsrc, host);
	declare_shadow(&d->shadow, d->shadow_config, true, handle, slot);
	if (host->inner_clip) {
		/* Fills the slot's padded box and carries the root's clip scope,
		 * so the border paints outside it with the slot's own metadata.
		 * It declares no Clay clip, so the tree compresses into it. On an
		 * axis of definite length (fixed, or a fit whose floor is its
		 * ceiling) it is the frame's whole box and the renderer cuts what
		 * cannot compress. A PERCENT element reports no length while its
		 * parent closes (clay.h:1937-1945), so a content-sized axis grows. */
		bool definite[2];
		for (int a = 0; a < 2; a++)
			definite[a] = n->sizing[a] == WIDGET_SIZING_FIXED
				|| (n->sizing[a] == WIDGET_SIZING_FIT && n->max[a] > 0
					&& n->min[a] == n->max[a]);
		Clay_ElementDeclaration inner = {
			.layout = {
				.sizing = {
					definite[0] ? clay_percent(1) : CLAY_SIZING_GROW(0),
					definite[1] ? clay_percent(1) : CLAY_SIZING_GROW(0),
				},
				.layoutDirection = slot->layout.layoutDirection,
				.childAlignment = slot->layout.childAlignment,
			},
			.custom.customData = RENDER_CLIP_MARK,
			.userData = userdata_clip(word, n->clip_opens,
				host->frame_clip ? WIDGET_FRAME_SCOPE : 0),
		};
		native_open(inner_clip_id(handle));
		native_configure(&inner);
	}
	declare_widget_tree(host, z, word);
	if (host->inner_clip)
		native_close();
	native_close();
}

/* Keep slide entrances and exits on their declaring output. Settled drawins
 * may still overhang an output edge. Client borders wrap the visible part of
 * their committed chrome when the allocation is animating around it. Read the
 * solved tree so retained exits need no live Lua object or registry pointer. */
static void
animation_constraints(struct render_state *render, int32_t index, Clay_BoundingBox bounds)
{
    struct clay_element_view view;
    clay_element_view(index, &view);
    if (!view.text && view.config.transition.handler) {
        uint64_t owner = declare_userdata_handle(view.config.userData);
        unsigned kind = owner >> 32;
        Clay_TransitionElementConfig *transition = &view.config.transition;
        bool slide_in = transition_effects(transition->enter.setInitialState) & WIDGET_TRANSITION_SLIDE;
        bool slide_out = transition_effects(transition->exit.setFinalState) & WIDGET_TRANSITION_SLIDE;
        if (kind == DECLARE_KIND_DRAWIN && ((view.entering && slide_in) || (view.exiting && slide_out)))
            render_constraint(render, owner, bounds, false);
        if (kind == DECLARE_KIND_CLIENT && (transition->properties
                & (CLAY_TRANSITION_PROPERTY_WIDTH | CLAY_TRANSITION_PROPERTY_HEIGHT))) {
            Clay_ElementData data = Clay_GetElementData((Clay_ElementId){.id = view.id});
            if (data.found) render_constraint(render, owner, data.boundingBox, true);
        }
    }
    for (uint16_t i = 0; i < view.children_len; i++)
        animation_constraints(render, view.children[i], bounds);
}

/* --- drawins ---
 *
 * Native shadow float below the frame border and widget content.
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

	struct widget_host host;
	if (!drawin_widget_host(d, &host))
		return;
	if (!d->animation.enabled && !host.path_clip && !bw && !shadow_get_effective_config(d->shadow_config, true)->enabled) {
		declare_widget_tree(&host, z, leaf_userdata(handle, opacity));
		return;
	}
	Clay_ElementDeclaration frame = leaf_at(z, x - bw, y - bw,
		d->width + 2 * bw, d->height + 2 * bw);
	/* Content-sized popups keep their widget limits inside the frame.
	 * Its padding adds the border without constraining content to the
	 * drawin's initial geometry or the last animation sample. */
	const struct widget_node *root = &d->widgets.nodes[0];
	host.fit[0] = root->sizing[0] == WIDGET_SIZING_FIT;
	host.fit[1] = root->sizing[1] == WIDGET_SIZING_FIT;
	if (host.fit[0]) frame.layout.sizing.width = CLAY_SIZING_FIT(0);
	if (host.fit[1]) frame.layout.sizing.height = CLAY_SIZING_FIT(0);
    if (d->animation.enabled) {
        frame.transition = transition_config(&d->animation);
        frame.transition.enter.trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME;
    }
    if (d->animation.enabled) {
        frame.userData = leaf_userdata(handle,
            frame.transition.properties & CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR ? opacity : 1.0f);
    }
	frame.floating.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID;
	frame.floating.parentId = screen_root_id(m).id;
    struct wlr_box origin = screen_origin(m);
    frame.floating.offset.x += m->m.x - origin.x;
    frame.floating.offset.y += m->m.y - origin.y;
	frame.layout.padding = (Clay_Padding){bw, bw, bw, bw};
	const color_t *color = &d->border_color_parsed;
	frame.border = (Clay_BorderElementConfig){
		.color = {color->red, color->green, color->blue, color->alpha},
		.width = {bw, bw, bw, bw, 0},
	};
	if (host.radius > 0)
		frame.cornerRadius = (Clay_CornerRadius){host.radius, host.radius, host.radius, host.radius};
	if (host.path_clip)
		drawin_path_frame(d, &frame);
	host.frame_clip = frame_grow_clip(d, &frame);
	host.flow = true;
	host.told[0] = d->width;
	host.told[1] = d->height;
	Clay_ElementId frame_id = Clay__HashStringWithOffset(CLAY_STRING("WIBOX"), id, 0);
	native_open(frame_id);
    native_configure(&frame);
	root_entrance(frame_id, &frame);
	record_open("WIBOX", handle, frame_id, &frame, DECLARE_SRC_USER, DECLARE_SRC_USER, &host);
	declare_shadow(&d->shadow, d->shadow_config, true, handle, &frame);
	declare_widget_tree(&host, z, leaf_userdata(handle, opacity));
	native_close();

}

/* A desktop drawin covering its screen (awful.wallpaper): a slot floating
 * over the output, grow by grow, holding the tree as a child that fills it,
 * so no number of its own enters the tree. */
static bool
drawin_covers_output(drawin_t *d, Monitor *m)
{
	struct wlr_box g = screen_origin(m);
    return d->type == WINDOW_TYPE_DESKTOP && d->x == g.x && d->y == g.y
        && d->width == g.width && d->height == g.height;
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
			.parentId = screen_root_id(m).id,
			.zIndex = z,
			.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
		},
	};
	Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("WALLPAPER"),
		(uint32_t)handle, 0);

	if (!drawin_widget_host(d, &host))
		return;
	host.flow = true;
	declare_widget_slot(&host, id, &slot, "WALLPAPER", DECLARE_SRC_NONE, DECLARE_SRC_NONE,
		z, leaf_userdata(handle, opacity));
}

/* A visible drawin declares once its first compile stores a tree. */
static bool
declarable_drawin(drawin_t *d, Monitor *m)
{
	return d->visible
		&& d->widgets.nodes_len > 0
		&& screen_hosted(d->screen, m)
        && (!active_screen || d->screen == active_screen->screen);
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
	native_open(slot_id);
	native_configure(&slot);
	record_open(edge != WLR_EDGE_NONE ? "LAYER_BAR" : "LAYER_OVERLAY", handle, slot_id,
		&slot, DECLARE_SRC_PROTOCOL, DECLARE_SRC_PROTOCOL, NULL);
    if (edge == WLR_EDGE_NONE && ((!st->desired_width && (st->margin.left < 0 || st->margin.right < 0))
            || (!st->desired_height && (st->margin.top < 0 || st->margin.bottom < 0)))) {
        /* Positive margins are padding. Negative protocol margins expand a
         * surface leaf about that inset; no sibling or output box is read. */
        Clay_ElementId inset_id = Clay__HashStringWithOffset(CLAY_STRING("layer.inset"), (uint32_t)handle, 0);
        Clay_ElementDeclaration inset = {.layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}};
        declare_leaf("layer.inset", handle, DECLARE_SRC_NONE, DECLARE_SRC_NONE, inset_id, &inset);
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
	enum declare_src src = edge == WLR_EDGE_NONE || told ? DECLARE_SRC_PROTOCOL : DECLARE_SRC_NONE;
	declare_leaf("layer.surface", handle, src, src, id, &leaf);
	native_close();
	declare_popups(ls->surface, id, 0, 0, handle);
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
	if (!bar->host.path_clip && d->bar.stretch && !mg[0] && !mg[1] && !mg[2] && !mg[3]) {
		declare_widget_slot(&bar->host, id, &slot, "WIBAR", DECLARE_SRC_THEME, DECLARE_SRC_THEME,
			z, leaf_userdata(handle, opacity));
		return;
	}
	native_open(id);
	native_configure(&slot);
	record_open("WIBAR", handle, id, &slot, DECLARE_SRC_THEME, DECLARE_SRC_THEME, &bar->host);
	if (bar->host.path_clip) {
		int bw = d->border_width;
		Clay_ElementDeclaration frame = {
			.layout = {
				.sizing = {
					bar->host.told[0] ? CLAY_SIZING_FIXED(bar->host.told[0] + 2 * bw) : CLAY_SIZING_GROW(0),
					bar->host.told[1] ? CLAY_SIZING_FIXED(bar->host.told[1] + 2 * bw) : CLAY_SIZING_GROW(0),
				},
				.padding = {bw, bw, bw, bw},
			},
		};
		drawin_path_frame(d, &frame);
		Clay_ElementId frame_id = Clay__HashStringWithOffset(CLAY_STRING("WIBOX"), (uint32_t)handle, 0);
		native_open(frame_id);
		native_configure(&frame);
		record_open("WIBOX", handle, frame_id, &frame, DECLARE_SRC_THEME, DECLARE_SRC_THEME, &bar->host);
	}
	declare_widget_tree(&bar->host, z, leaf_userdata(handle, opacity));
	if (bar->host.path_clip)
		native_close();
	native_close();
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
			if ((!active_screen || active_screen->screen->monitor == m)
                    && declarable_layer(l, m) && n < cap
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

/* Publish each bar or attachment root's solved box in layout coordinates. */
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
			luaA_drawin_set_solved_geometry(globalconf_L, d, x, y, w, h);
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
            luaA_drawin_set_solved_geometry(globalconf_L, d, d->x, d->y, w, h);
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

/* Only the authored border reserves space; shadow extents never size a slot. */
static Clay_Dimensions
attachment_decoration(drawin_t *d, Clay_ElementDeclaration *slot)
{
    int bw = d->border_width;
    const color_t *color = &d->border_color_parsed;
    slot->border = (Clay_BorderElementConfig) {
        .color = {color->red, color->green, color->blue, color->alpha},
        .width = {bw, bw, bw, bw, 0},
    };
    if (d->shape_radius > 0) {
        float r = d->shape_radius;
        slot->cornerRadius = (Clay_CornerRadius){r, r, r, r};
    }
    if (d->shape.ref != LUA_NOREF)
        drawin_path_frame(d, slot);
    return (Clay_Dimensions){bw, bw};
}

/* A spacer that grows up to the point, or nothing before a point at the
 * edge: a GROW max of 0 is unbounded (clay.h:1936-1948). */
static Clay_SizingAxis
point_spacer(float point)
{
    return point > 0 ? CLAY_SIZING_GROW(0, point) : CLAY_SIZING_FIXED(0);
}

/* A point attachment stays on its screen, as AwesomeWM's menu did: a float
 * over the screen holds the slot in flow behind a spacer on each axis, and
 * a spacer grows up to the point but only into the space the slot leaves
 * (clay.h:2447-2490), so the slot sits at the point or against the far
 * edge. The float paints nothing and passes the pointer through. The slot's
 * own floating config stays for its band; Clay reads it only when attachTo
 * is set. Closed by two native_close() calls. */
static void
open_point_area(Clay_ElementId id, Clay_ElementDeclaration *slot)
{
    Clay_ElementDeclaration area = {
        .layout = {
            .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .floating = slot->floating,
    };
    area.floating.offset = (Clay_Vector2){0, 0};
    area.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
    Clay_ElementId area_id = Clay__HashStringWithOffset(CLAY_STRING("POINT"), id.id, 0);
    native_open(area_id);
    native_configure(&area);
    record_open("POINT", 0, area_id, &area, DECLARE_SRC_NONE, DECLARE_SRC_NONE, NULL);

    Clay_ElementDeclaration above = {
        .layout.sizing = { CLAY_SIZING_GROW(0), point_spacer(slot->floating.offset.y) },
    };
    declare_leaf("POINT", 0, DECLARE_SRC_NONE, DECLARE_SRC_USER,
        Clay__HashStringWithOffset(CLAY_STRING("POINT.y"), id.id, 0), &above);
    Clay_ElementDeclaration row = {
        .layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0) },
    };
    Clay_ElementId row_id = Clay__HashStringWithOffset(CLAY_STRING("POINT.row"), id.id, 0);
    native_open(row_id);
    native_configure(&row);
    record_open("POINT", 0, row_id, &row, DECLARE_SRC_NONE, DECLARE_SRC_NONE, NULL);
    Clay_ElementDeclaration before = {
        .layout.sizing = { point_spacer(slot->floating.offset.x), CLAY_SIZING_GROW(0) },
    };
    declare_leaf("POINT", 0, DECLARE_SRC_USER, DECLARE_SRC_NONE,
        Clay__HashStringWithOffset(CLAY_STRING("POINT.x"), id.id, 0), &before);

    slot->floating.attachTo = CLAY_ATTACH_TO_NONE;
    slot->floating.offset = (Clay_Vector2){0, 0};
    slot->transition.exit.trigger = CLAY_TRANSITION_EXIT_TRIGGER_WHEN_PARENT_EXITS;
}

static bool
declare_attachment(drawin_t *d, Monitor *m)
{
    if (d->attachment.kind == 2 && !d->attachment.target) return false;
    bool bounded = d->attachment.kind == 3 && d->attachment.bounded;
    uint32_t target = bounded || d->attachment.workarea ? workarea_id(m).id
        : d->attachment.target ? attachment_target(d) : screen_root_id(m).id;
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
        .layout.sizing = {
            n->sizing[0] == WIDGET_SIZING_FIXED ? CLAY_SIZING_FIT(0) : widget_sizing(n, 0),
            n->sizing[1] == WIDGET_SIZING_FIXED ? CLAY_SIZING_FIT(0) : widget_sizing(n, 1) },
        .floating = {
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = target,
            .attachPoints = { .parent = d->attachment.parent, .element = d->attachment.own },
            .offset = { d->attachment.x, d->attachment.y },
            .zIndex = Z_POPUP,
            .pointerCaptureMode = d->attachment.passthrough || d->input_passthrough
                ? CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH : CLAY_POINTER_CAPTURE_MODE_CAPTURE,
        },
    };
    if (d->attachment.kind == 3) {
        slot.layout.layoutDirection = CLAY_TOP_TO_BOTTOM;
        slot.floating.zIndex = Z_NOTIFICATION;
        a->host.fit[0] = false;
        if (bounded) {
            a->host.fit[1] = false;
            slot.floating.attachPoints.parent = CLAY_ATTACH_POINT_CENTER_CENTER;
            slot.floating.attachPoints.element = CLAY_ATTACH_POINT_CENTER_CENTER;
        }
    }
    Clay_Dimensions decoration = attachment_decoration(d, &slot);
    slot.layout.padding = (Clay_Padding){decoration.width, decoration.width,
        decoration.height, decoration.height};
    /* Attach the content's own point; decoration extends around it. */
    slot.floating.offset.x += ((int)d->attachment.own / 3 - 1) * decoration.width;
    slot.floating.offset.y += ((int)d->attachment.own % 3 - 1) * decoration.height;
    if (d->attachment.kind == 3) {
        slot.layout.sizing.width = d->attachment.width_override >= 0
            ? CLAY_SIZING_FIXED(d->attachment.width_override + 2*decoration.width)
            : bounded ? CLAY_SIZING_GROW(0, d->attachment.width + 2*decoration.width)
            : d->attachment.width ? CLAY_SIZING_FIXED(d->attachment.width + 2*decoration.width)
            : CLAY_SIZING_GROW(0);
        if (bounded)
            slot.layout.sizing.height = CLAY_SIZING_GROW(0, d->attachment.height + 2*decoration.height);
    }
    Clay_ElementId id = Clay__HashStringWithOffset(CLAY_STRING("ATTACHMENT"),
        (uint32_t)handle, 0);
    const char *role = d->attachment.kind == 3 ? "LAUNCHER"
        : d->attachment.kind == 2 ? "TOOLTIP" : "POPUP";
    bool point = d->attachment.kind == 1 && !d->attachment.target && !d->attachment.workarea
        && d->attachment.parent == CLAY_ATTACH_POINT_LEFT_TOP
        && d->attachment.own == CLAY_ATTACH_POINT_LEFT_TOP;
    if (point)
        open_point_area(id, &slot);
    declare_widget_frame(d, &a->host, id, &slot, role,
        d->attachment.kind == 3 ? d->attachment.src[0] : n->src[0],
        bounded ? d->attachment.src[1] : n->src[1]);
    if (point) {
        native_close();
        native_close();
    }
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
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = screen_root_id(m).id,
                .attachPoints = { .parent = position, .element = position },
                .offset = {first->attachment.x, first->attachment.y},
                .zIndex = Z_NOTIFICATION,
                .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
            },
        };
        Clay_ElementId stack_id = Clay__HashStringWithOffset(CLAY_STRING("NOTIFICATIONS"), position,
            screen_subtrees ? screen_root_id(m).id : 0);
        native_open(stack_id);
        native_configure(&stack);
        record_open("NOTIFICATIONS", 0, stack_id, &stack, DECLARE_SRC_THEME, DECLARE_SRC_THEME, NULL);
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
            child.floating.zIndex = Z_NOTIFICATION;
            declare_widget_frame(d, &a->host, id, &child, "NOTIFICATION", DECLARE_SRC_NONE, DECLARE_SRC_NONE);
        }
        native_close();
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
		if (d->widgets.output_fill)
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
	declare_leaf("fullscreen_bg", 0, DECLARE_SRC_OUTPUT, DECLARE_SRC_OUTPUT,
		Clay__HashStringWithOffset(CLAY_STRING("fullscreen_bg"), 0, 0), &bg);
}

/* The workarea: what the bars leave of the screen, where the clients go.
 * screen.workarea is the box this element solves to (workarea_settle). */
static Clay_ElementId
workarea_id(Monitor *m)
{
	return Clay__HashStringWithOffset(CLAY_STRING("WORKAREA"),
        active_screen && screen_subtrees ? (uint32_t)active_screen->index
            : (uint32_t)declare_handle_for(m, DECLARE_KIND_WALLPAPER),
        active_screen && screen_subtrees ? screen_root_id(m).id : 0);
}

/* After the solve: the screen's workarea is the WORKAREA box, in layout
 * coordinates. screen_set_workarea queues property::workarea when it
 * changed, and awful.layout arranges on it. */
static void
workarea_settle(Monitor *m)
{
	Clay_ElementData data = Clay_GetElementData(workarea_id(m));
	Clay_BoundingBox b = data.boundingBox;
	screen_t *s = active_screen->screen;
	struct wlr_box box;

	if (!data.found || !s->valid)
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

/* Keep the shared source and each output's logical crop as image inputs.
 * The fill belongs to OUTPUT, without a leaf, record or floating band. */
static void
output_background(Monitor *m, Clay_ElementDeclaration *o)
{
	struct image_entry *e = &m->declare->wallpaper;
	if (!globalconf.wallpaper) {
		image_entry_set(e, NULL);
	} else if (!e->native || e->gen != globalconf.wallpaper_gen
			|| e->src_x != m->m.x || e->src_y != m->m.y) {
		image_entry_set(e, cairo_surface_reference(globalconf.wallpaper));
		e->src_x = m->m.x;
		e->src_y = m->m.y;
		e->natural = true;
		e->gen = globalconf.wallpaper_gen;
	}
	if (e->native)
		o->image.imageData = e;
	else
		o->backgroundColor = clay_color(globalconf.appearance.rootcolor);
}

/* Only equal-area color/image contributions replace the output fill.
 * Layout-bearing images, gradients, layered images and decorations keep
 * their tree: folding those would erase a paint or allocation boundary. */
static void
output_wallpaper_fill(Monitor *m, Clay_ElementId id, Clay_ElementDeclaration *o)
{
	drawin_t *candidate = NULL;
	unsigned desktops = 0;
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;
		if (!screen_hosted(d->screen, m))
			continue;
		d->widgets.output_fill = false;
		if (!screen_subtrees && declarable_drawin(d, m) && d->type == WINDOW_TYPE_DESKTOP) {
			desktops++;
			candidate = d;
		}
	}
	if (desktops != 1 || !drawin_covers_output(candidate, m)
			|| candidate->bar.edge || candidate->attachment.kind
			|| candidate->ontop || candidate->border_width
			|| (candidate->opacity >= 0 && candidate->opacity != 1)
			|| candidate->shape_radius > 0 || candidate->shape.ref != LUA_NOREF)
		return;
	/* A desktop layer between OUTPUT and the wallpaper must retain its
	 * previous occlusion. The ordinary wallpaper float supplies that order. */
	if (!wl_list_empty(&m->layers[ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND]))
		return;
	foreach(item, globalconf.clients)
		if ((*item)->mon == m && (*item)->type == WINDOW_TYPE_DESKTOP
				&& declarable_client(*item))
			return;

	struct widget_host host;
	if (!drawin_widget_host(candidate, &host))
		return;
	struct widget_tree *tree = host.tree;
	const struct widget_node *fill = NULL;
	Clay_Color background = o->backgroundColor;
	bool layered_image = o->image.imageData != NULL;
	for (size_t i = 0; i < tree->nodes_len; i++) {
		const struct widget_node *n = &tree->nodes[i];
		if (n->children > 1 || n->shape || n->text || n->floating
				|| n->scroll || n->cut || n->radius || n->border[3] || n->aspect
				|| n->pad[0] || n->pad[1] || n->pad[2] || n->pad[3])
			return;
		/* The host's fixed axes already equal OUTPUT; descendants must
		 * fill that area without bounds of their own. */
		if (i && (n->sizing[0] != WIDGET_SIZING_GROW
				|| n->sizing[1] != WIDGET_SIZING_GROW
				|| n->min[0] || n->min[1] || n->max[0] || n->max[1]))
			return;
		if (n->bg[3]) {
			if (fill || n->image)
				return;
			float alpha = n->bg[3], under = background.a / 255;
			if (alpha == 1)
				layered_image = false;
			else if (layered_image)
				return;
			float combined = alpha + under * (1 - alpha);
			background = (Clay_Color){
				(n->bg[0] * alpha * 255 + background.r * under * (1-alpha)) / combined,
				(n->bg[1] * alpha * 255 + background.g * under * (1-alpha)) / combined,
				(n->bg[2] * alpha * 255 + background.b * under * (1-alpha)) / combined,
				combined * 255,
			};
		}
		if (n->image) {
			if (fill || n->children || layered_image)
				return;
			fill = n;
		}
	}
	if (layered_image)
		return;
	struct image_entry *image = tree->leaves_len == 1 ? tree->leaves : NULL;
	if (fill && (!image || !image->native))
		return;
	o->backgroundColor = background;
	o->image.imageData = fill ? image : NULL;
	/* root.content(true) included awful.wallpaper's drawin before this
	 * fold and still does. The root wallpaper keeps its output word. */
	o->userData = leaf_userdata(declare_handle_for(candidate, DECLARE_KIND_DRAWIN), 1);
	tree->output_fill = true;
	for (size_t i = 0; i < tree->nodes_len; i++)
		tree->ids[i] = id.id;
	widget_host_bind(&host, id);
	for (size_t i = 0; i < tree->bindings_len; i++)
		attachment_bind(tree->bindings[i], host.id, id.id);
}

/* The workarea: the active screen's layout tree (screen:_clay_layout), its
 * root filling what the bars leave, or an empty element without one. */
static void
declare_workarea(Monitor *m)
{
    struct widget_tree *tree = &active_screen->screen->layout;
    Clay_ElementId id = workarea_id(m);
    if (!tree->nodes_len) {
        Clay_ElementDeclaration e = {
            .layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
        };
        declare_leaf("WORKAREA", 0, DECLARE_SRC_NONE, DECLARE_SRC_NONE, id, &e);
        return;
    }
    struct widget_host host = {
        .tree = tree, .m = m, .id = id.id, .flow = true, .in_parent = true, .layout = true,
    };
    Clay_ElementDeclaration root = widget_node_decl(&tree->nodes[0], 0, NULL);
    size_t leaf = 0;
    root.layout.sizing = (Clay_Sizing) { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) };
    tree->root_id = id.id;
    declare_widget_subtree(&host, 0, id, 0, NULL, &leaf, &root, tree->ids,
        (Clay_ElementId) {0}, 0);
}

/* Edge bars and native tile runs use the active screen's own allocation. */
static void
declare_screen_contents(Monitor *m)
{
	declare_edge(m, DRAWIN_EDGE_TOP);
	if (edge_has_bars(m, DRAWIN_EDGE_LEFT) || edge_has_bars(m, DRAWIN_EDGE_RIGHT)) {
		Clay_ElementDeclaration middle = {
			.layout.sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
		};
		Clay_ElementId middle_id = Clay__HashStringWithOffset(
			CLAY_STRING("MIDDLE"), (uint32_t)declare_handle_for(m, DECLARE_KIND_WALLPAPER),
            screen_subtrees ? screen_root_id(m).id : 0);

		native_open(middle_id);
		native_configure(&middle);
		record_open("MIDDLE", 0, middle_id, &middle, DECLARE_SRC_NONE, DECLARE_SRC_NONE, NULL);
		declare_edge(m, DRAWIN_EDGE_LEFT);
		declare_workarea(m);
		declare_edge(m, DRAWIN_EDGE_RIGHT);
		native_close();
	} else {
		declare_workarea(m);
	}
	declare_edge(m, DRAWIN_EDGE_BOTTOM);
	declare_floating_bars(m);
}

/* OUTPUT owns the fill. A sole full-output screen keeps its edge column
 * here; split outputs give each screen a fixed floating subtree.
 * The renderer places its backdrop below all roots; flow children retain band 0.
 * The root wallpaper carries the Monitor's word for screenshot exclusion;
 * an awful.wallpaper fill keeps its drawin's ownership and widget bindings. */
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

	output_background(m, &o);
	output_wallpaper_fill(m, id, &o);

	/* The inspector's panel takes the right edge while it is up (Clay
	 * narrows its own root by the same width, clay.h:4363): the desktop
	 * reflows into what is left, as beside a right bar. */
	if (inspector_declares(m->declare))
		o.layout.padding.right = (uint16_t)Clay__debugViewWidth;
	native_open(id);
	native_configure(&o);
	record_open("OUTPUT", handle, id, &o, DECLARE_SRC_OUTPUT, DECLARE_SRC_OUTPUT, NULL);
    for (size_t i = 0; i < screen_declarations_len; i++) {
        screen_activate(&screen_declarations[i]);
        if (screen_subtrees) {
            struct wlr_box g = active_screen->geometry;
            Clay_ElementId screen_id = screen_root_id(m);
            Clay_ElementDeclaration screen = {
                .layout = {
                    .sizing = {CLAY_SIZING_FIXED(g.width), CLAY_SIZING_FIXED(g.height)},
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .floating = {
                    .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = id.id,
                    .offset = {g.x - m->m.x, g.y - m->m.y},
                    .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
                },
            };
            native_open(screen_id);
            native_configure(&screen);
            record_open("SCREEN", 0, screen_id, &screen, DECLARE_SRC_USER, DECLARE_SRC_USER, NULL);
            if (!recording->exhausted)
                recording->records[recording->records_len - 1].screen_index = active_screen->index;
        }
        declare_screen_contents(m);
        if (screen_subtrees) {
            declare_drawins(m);
            native_close();
        }
    }
    screen_activate(NULL);
	native_close();
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
	declare_leaf("drag.icon", handle, DECLARE_SRC_USER, DECLARE_SRC_USER,
		Clay__HashStringWithOffset(CLAY_STRING("drag.icon"),
		(uint32_t)handle, 0), &s);
}

/* --- the pointer image ---
 *
 * The seat's pointer image (input.h, cursor_image) is a leaf of the output
 * under the pointer, at the pointer less its hotspot: a client's cursor
 * surface as a borrowed surface leaf, or the themed xcursor at this
 * output's scale as an image leaf built from the frame's pixels. It passes
 * every hit through (hit_accept) and Clay's pointer query skips it like
 * every root here (place_fixed). Nothing sets an image on the wlr_cursor,
 * so wlroots' output cursors stay empty and the leaf is the only pointer
 * painted. Where the last frame put it, for declare_cursor_changed(). */
static int cursor_declared_x = INT_MIN, cursor_declared_y = INT_MIN;
static uint64_t cursor_declared_gen;

static void
cursor_mark(void)
{
	Monitor *under = xytomon(cursor->x, cursor->y), *m;

	wl_list_for_each(m, &mons, link)
		if (m->declare && (m == under || m->declare->cursor_shown))
			declare_output_mark_dirty(m->declare);
}

/* Magnification is sampled on the output frame clock before authoring the
 * cursor box. Position and hotspot always use the latest pointer, so moving
 * during inflation never interpolates pointer motion. One seat-wide clock
 * keeps an interrupted animation continuous when crossing outputs. */
static double cursor_scale_from = 1, cursor_scale_target = 1;
static double cursor_scale_duration;
static int64_t cursor_scale_started;

double
declare_cursor_magnification(void)
{
    if (cursor_scale_duration <= 0) return cursor_scale_target;
    double t = (g_get_monotonic_time() - cursor_scale_started) / (cursor_scale_duration * 1e6);
    if (t >= 1) {
        cursor_scale_duration = 0;
        return cursor_scale_target;
    }
    t = fmax(0, t);
    double eased = t < .5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
    return cursor_scale_from + (cursor_scale_target - cursor_scale_from) * eased;
}

void
declare_cursor_magnify(double scale, double duration)
{
    cursor_scale_from = declare_cursor_magnification();
    cursor_scale_target = scale;
    cursor_scale_started = g_get_monotonic_time();
    cursor_scale_duration = cursor_scale_from == scale ? 0 : duration;
    cursor_mark();
}

/* The xcursor frame this output shows for the themed name, or NULL when the
 * theme has neither it nor "default". An animated cursor shows its first
 * frame: a frame per animation step would keep an idle output declaring
 * for as long as a busy cursor is up. */
static const struct wlr_xcursor_image *
cursor_xcursor_frame(Monitor *m, float multiplier)
{
	float scale = m->wlr_output->scale * multiplier;
	struct wlr_xcursor *xc;

	wlr_xcursor_manager_load(cursor_mgr, scale);
	xc = wlr_xcursor_manager_get_xcursor(cursor_mgr, cursor_image.name, scale);
	if (!xc)
		xc = wlr_xcursor_manager_get_xcursor(cursor_mgr, "default", scale);
	return xc && xc->image_count ? xc->images[0] : NULL;
}

/* A copy of an xcursor frame's pixels: ARGB32 premultiplied in both. */
static cairo_surface_t *
cursor_frame_surface(const struct wlr_xcursor_image *frame)
{
	cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
		frame->width, frame->height);
	int stride = cairo_image_surface_get_stride(s);
	unsigned char *dst = cairo_image_surface_get_data(s);

	if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS || !dst) {
		cairo_surface_destroy(s);
		return NULL;
	}
	cairo_surface_flush(s);
	for (uint32_t y = 0; y < frame->height; y++)
		memcpy(dst + y * stride, frame->buffer + (size_t)y * frame->width * 4,
			(size_t)frame->width * 4);
	cairo_surface_mark_dirty(s);
	return s;
}

static void
declare_cursor(Monitor *m)
{
	struct declare_output *dout = m->declare;
	int x = (int)round(cursor->x), y = (int)round(cursor->y);
	uint64_t handle;
	Clay_ElementDeclaration s;

	dout->cursor_shown = false;
	if (xytomon(cursor->x, cursor->y) != m)
		return;
	cursor_declared_x = x;
	cursor_declared_y = y;
	cursor_declared_gen = cursor_image.gen;
	x -= m->m.x;
	y -= m->m.y;
	if (cursor_image.surface) {
		struct wlr_surface *surface = cursor_image.surface;
		int w = surface->current.width, h = surface->current.height;

		if (!cursor_image.tree || w < 1 || h < 1)
			return;
		handle = declare_handle_for(surface, DECLARE_KIND_CURSOR);
		s = leaf_at(Z_CURSOR, x - cursor_image.hotspot_x,
			y - cursor_image.hotspot_y, w, h);
		s.custom.customData = (void *)(uintptr_t)handle;
		s.userData = leaf_userdata(handle, 1.0f);
		declare_leaf("cursor", handle, DECLARE_SRC_PROTOCOL, DECLARE_SRC_PROTOCOL,
			Clay__HashStringWithOffset(CLAY_STRING("cursor"),
			(uint32_t)handle, 0), &s);
	} else if (cursor_image.name) {
		const struct wlr_xcursor_image *normal = cursor_xcursor_frame(m, 1);
        double magnification = declare_cursor_magnification();
        const struct wlr_xcursor_image *frame = magnification > 1
            ? cursor_xcursor_frame(m, 4) : normal;
        if (!frame) frame = normal;
        float scale = m->wlr_output->scale / magnification;
        if (cursor_scale_duration > 0)
            declare_output_mark_dirty(dout);

		if (!frame || !normal)
			return;
		if (dout->cursor_frame != frame || dout->cursor_gen != cursor_image.gen) {
			image_entry_set(&dout->cursor, cursor_frame_surface(frame));
			dout->cursor_frame = frame;
			dout->cursor_gen = cursor_image.gen;
		}
		if (!dout->cursor.native)
			return;
		handle = declare_handle_for(cursor, DECLARE_KIND_CURSOR);
        int width = (int)round(normal->width / scale);
        int height = (int)round(normal->height / scale);
        /* Theme sizes may use different artwork and hotspot proportions.
         * Anchor the image actually displayed at its own scaled hotspot. */
        int hx = (int)round((double)frame->hotspot_x * width / frame->width);
        int hy = (int)round((double)frame->hotspot_y * height / frame->height);
        s = leaf_at(Z_CURSOR, x - hx, y - hy, width, height);
		s.image.imageData = &dout->cursor;
		s.userData = leaf_userdata(handle, 1.0f);
		declare_leaf("cursor", handle, DECLARE_SRC_THEME, DECLARE_SRC_THEME,
			Clay__HashStringWithOffset(CLAY_STRING("cursor"),
			(uint32_t)handle, 0), &s);
	} else
		return;
	dout->cursor_shown = true;
}

void
declare_cursor_changed(void)
{
	if ((int)round(cursor->x) == cursor_declared_x
			&& (int)round(cursor->y) == cursor_declared_y
			&& cursor_image.gen == cursor_declared_gen)
		return;
	cursor_mark();
}

/* The lock section: the top of the output's own tree while the session is
 * locked, in some_activate_lua_lock()'s order, the covers then the lock
 * surface drawin on top.
 *
 * The backdrop is declared by the compositor, not the config, at a fixed
 * output size and fully opaque, so an output with no cover drawin (one
 * plugged in while locked, before the config's screen handler runs) still
 * shows nothing of the desktop. It carries a DECLARE_KIND_LOCK_BLOCK handle,
 * which is what ends the input walk at it (hit_accept). */
static void
declare_lock_section(Monitor *m)
{
	drawin_t *lock_surface = some_get_lua_lock_surface();
	int cover_count;
	drawin_t **covers = some_get_lua_lock_covers(&cover_count);
	uint64_t block = declare_handle_for(m->declare, DECLARE_KIND_LOCK_BLOCK);
	Clay_ElementDeclaration backdrop = leaf_at(Z_LOCK_BACKDROP, 0, 0,
		m->m.width, m->m.height);

	backdrop.backgroundColor = (Clay_Color) { 0.1f * 255, 0.1f * 255,
		0.1f * 255, 255 };
	backdrop.userData = leaf_userdata(block, 1.0f);
	declare_leaf("LOCK", block, DECLARE_SRC_OUTPUT, DECLARE_SRC_OUTPUT,
		Clay__HashStringWithOffset(CLAY_STRING("LOCK"), 0, 0), &backdrop);

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
		declare_leaf("lock.surface", handle, DECLARE_SRC_OUTPUT, DECLARE_SRC_OUTPUT,
			Clay__HashStringWithOffset(CLAY_STRING("lock.surface"),
			(uint32_t)handle, 0), &s);
	}
}

/* Reserve authored scrolling before any host is configured. Hidden widget
 * trees retain their admission reservation so becoming visible cannot let
 * an earlier host take their records. The inspector has a main pane and
 * two alternative details panes whose records can coexist across frames. */
static bool clips_prepare(Monitor *m)
{
    size_t scrolls = 0;
    foreach(item, globalconf.drawins) {
        drawin_t *d = *item;
        if (screen_hosted(d->screen, m)) scrolls += d->widgets.scrolls;
    }
    foreach(item, globalconf.clients) {
        Client *c = *item;
        if (c->mon != m) continue;
        for (int bar = 0; bar < CLIENT_TITLEBAR_COUNT; bar++)
            scrolls += c->titlebar[bar].widgets.scrolls;
    }
    for (size_t i = 0; i < screen_declarations_len; i++)
        scrolls += screen_declarations[i].screen->layout.scrolls;
    size_t inspector = Clay_IsDebugModeEnabled() ? 3 : 0;
    /* One record stays free for cut nodes to pass through (widget.h). */
    if (scrolls + inspector >= WIDGET_SCROLLS_OUTPUT_MAX) {
        recording->exhausted = true;
        recording->inspector_refused = inspector != 0;
        fprintf(stderr, "clay scrolling budget exhausted on %s: %zu scrolling records and %zu inspector records; retained scene\n",
            m->wlr_output->name, scrolls, inspector);
        return false;
    }
    recording->clips_declared = inspector;
    return true;
}

static void
declare_scene(Monitor *m)
{
	attachment_targets_len = 0;
	bars_len = 0;
    if (!screens_prepare(m) || !clips_prepare(m)) return;
	declare_output(m);
    if (recording->exhausted) return;
	declare_floating_layers(m);
    if (recording->exhausted) return;
    if (!screen_subtrees && screen_declarations_len == 1) {
        screen_activate(&screen_declarations[0]);
        declare_drawins(m);
        screen_activate(NULL);
        if (recording->exhausted) return;
    }
	declare_fullscreen_bg(m);
    if (recording->exhausted) return;
	declare_unmanaged_clients(m);
    if (recording->exhausted) return;
	declare_drag_icon(m);
    if (recording->exhausted) return;
	if (session_is_locked())
		declare_lock_section(m);
	declare_cursor(m);
    if (recording->exhausted) return;
}

/* The boxes of one subtree, in the preorder the tree table uses, rounded
 * against the root's own box so a box crossing into Lua is the whole
 * drawin-local pixel. Edges round, not the size, so two boxes that share an
 * edge in the solved layout share it here. */
static size_t
widget_boxes_walk(struct widget_tree *d, size_t i, Clay_ElementId id, int (*boxes)[4],
	int *n, Clay_BoundingBox root, uint32_t *ids, float *scrolled)
{
	const struct widget_node *node = &d->nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	size_t next = i + 1;

	/* A client composite publishes nothing; its frame is the client's. */
	if (node->client)
		return widget_subtree_end(d, i);
	if (!node->text && data.found && (node->widget || (ids && node->scroll))) {
		Clay_BoundingBox b = data.boundingBox;
		int x0 = (int)floorf(b.x - root.x + 0.5f);
		int y0 = (int)floorf(b.y - root.y + 0.5f);

		if (ids)
			ids[*n] = d->ids[i];
		/* A scroll node's declared offset as the dump prints it, NAN for
		 * others. */
		if (scrolled) {
			float offset = node->scroll && node->scroll < 3 ? node->scrolled[node->scroll - 1] : 0;
			scrolled[*n] = !node->scroll ? NAN : offset == 0 ? 0 : -offset;
		}
		boxes[*n][0] = x0;
		boxes[*n][1] = y0;
		boxes[*n][2] = (int)floorf(b.x + b.width - root.x + 0.5f) - x0;
		boxes[*n][3] = (int)floorf(b.y + b.height - root.y + 0.5f) - y0;
		(*n)++;
	}
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_boxes_walk(d, next, widget_child_id(d, next, id, k),
			boxes, n, root, ids, scrolled);
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

/* Clay supplies candidates in preorder. Renderer masks remove a rejected
 * element and all its descendants without changing Clay's capture state. */
static size_t
widget_hits_walk(struct widget_tree *d, size_t i, Clay_ElementId id,
	Clay_ElementIdArray ids, int *out, int *n, int cap, bool *captured,
	struct render_state *render, double x, double y, bool masked)
{
	const struct widget_node *node = &d->nodes[i];
	size_t next = i + 1;

	masked = masked || !render_point_in_masks(render, id.id, x, y);
	if (pointer_over(ids, id)) {
		if (!masked && node->widget && *n < cap)
			out[(*n)++] = (int)i;
		/* The scene==clay check describes Clay's rectangular traversal,
		 * including capturing floats whose shaped pixels reject this point. */
		if (node->floating && !node->passthrough)
			*captured = true;
	}
	for (uint16_t k = 0; k < node->children; k++)
		next = widget_hits_walk(d, next, widget_child_id(d, next, id, k),
			ids, out, n, cap, captured, render, x, y, masked);
	return next;
}

Clay_Context *
declare_output_context(struct declare_output *dout)
{
    return dout ? dout->band.clay : NULL;
}

Clay_Context *
declare_widget_context(const struct widget_host *host)
{
	struct declare_output *dout = host->m ? host->m->declare : NULL;

	return dout ? dout->band.clay : NULL;
}

static const struct widget_tree *published_tree(const struct widget_host *host)
{
    if (!host->m || !host->m->declare) return NULL;
    struct declare_band *band = &host->m->declare->band;
    for (size_t i = 0; i < band->hosts_len; i++)
        if (band->hosts[i].host.id == host->id && band->hosts[i].host.drawable == host->drawable)
            return band->hosts[i].view;
    return NULL;
}

static struct render_presentation host_presentation(const struct widget_host *host)
{
    if (!host->m || !host->m->declare || !host->drawable)
        return (struct render_presentation){.scale = 1, .fade = 1};
    enum declare_kind kind = host->drawable->owner_type == DRAWABLE_OWNER_DRAWIN
        ? DECLARE_KIND_DRAWIN : DECLARE_KIND_TITLEBAR;
    return render_owner_presentation(host->m->declare->band.render, handle_pack(kind, host->id));
}

int
declare_widget_hits(const struct widget_host *host, double x, double y, int *out, int cap)
{
	x += host->x;
	y += host->y;
	if (!render_unpresent(host_presentation(host), &x, &y)) return 0;
	x -= host->x;
	y -= host->y;
	if (!host->visible || x < 0 || y < 0 || x >= host->w || y >= host->h)
		return 0;

	struct widget_tree *d = (struct widget_tree *)published_tree(host);
	Monitor *m = host->m;
	struct declare_output *dout = m ? m->declare : NULL;
	struct declare_band *band;
	Clay_Context *previous;
	Clay_ElementId root_id;
	Clay_ElementIdArray ids;
	int n = 0;

	if (!dout || !d || !d->declared || !(band = dout->band.clay ? &dout->band : NULL)
			|| !band->context_valid)
		return 0;
	/* The query answers only a visible host inside its box. It runs against
	 * the boxes of the output's last solve, in output coordinates, and
	 * answers every element under the point across the whole context:
	 * this tree's nodes are picked out of it. */
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	Clay_SetPointerState((Clay_Vector2) {
		(float)(host->x + x), (float)(host->y + y) }, false);
	ids = Clay_GetPointerOverIds();
	root_id = (Clay_ElementId) {.id = d->root_id};
	bool captured = false;
	widget_hits_walk(d, 0, root_id, ids, out, &n, cap, &captured,
		band->render, host->x + x, host->y + y, false);
#ifdef SOMEWM_RENDER_VERIFY
	/* A capturing widget float stops Clay before the host root. It still
	 * belongs to the scene's drawable; otherwise the query must reach the
	 * root to agree with the scene hit. */
	if (!pointer_over(ids, root_id) && !captured) {
		wlr_log(WLR_ERROR, "scene==clay: the scene hit drawable %dx%d+%d+%d "
			"at %g,%g but Clay's query does not reach its root",
			host->w, host->h, host->x + m->m.x, host->y + m->m.y, x, y);
		abort();
	}
#endif
	Clay_SetCurrentContext(previous);
	return n;
}

/* The boxes of host's tree in the current context: one lookup per node
 * against what that context last solved. */
static int
widget_boxes_read(const struct widget_host *host, int (*boxes)[4], uint32_t *ids,
	float *scrolled)
{
	Clay_ElementId root_id = {.id = host->tree->root_id};
	Clay_ElementData root = Clay_GetElementData(root_id);
	int n = 0;

	if (root.found)
		widget_boxes_walk(host->tree, 0, root_id, boxes, &n,
			root.boundingBox, ids, scrolled);
	return n;
}

int
declare_widget_boxes(const struct widget_host *host, int (*boxes)[4])
{
    struct widget_host committed = *host;
    committed.tree = (struct widget_tree *)published_tree(host);
    if (!committed.tree) return 0;
    host = &committed;
	struct declare_band *band;
	Clay_Context *previous;
	int n;

	/* Clay's hashmap answers with the last box an id ever had, so a tree
	 * the declare pass has not reached yet would read back the boxes of
	 * the one it replaced. Report nothing until it has. */
	if (!host->m || !host->m->declare || !host->tree->declared
			|| !(band = host->m->declare->band.clay
				? &host->m->declare->band : NULL))
		return 0;
	previous = Clay_GetCurrentContext();
	Clay_SetCurrentContext(band->clay);
	n = widget_boxes_read(host, boxes, NULL, NULL);
	Clay_SetCurrentContext(previous);
	return n;
}

/* Send the object on top of the stack clay::solved with the boxes and ids
 * of tree, and pop it. */
static void
solved_signal(lua_State *L, struct widget_tree *tree)
{
	static int boxes[WIDGET_NODES_MAX][4];
	static uint32_t ids[WIDGET_NODES_MAX];
	static float scrolled[WIDGET_NODES_MAX];
	static const char *keys[] = { "x", "y", "width", "height" };
	struct widget_host host = { .tree = tree };
	int top = lua_gettop(L) - 1;
	int n = widget_boxes_read(&host, boxes, ids, scrolled);

	lua_createtable(L, n, 0);
	for (int k = 0; k < n; k++) {
		lua_createtable(L, 0, 6);
		lua_pushinteger(L, ids[k]);
		lua_setfield(L, -2, "id");
		if (!isnan(scrolled[k])) {
			lua_pushnumber(L, scrolled[k]);
			lua_setfield(L, -2, "scrolled");
		}
		for (int j = 0; j < 4; j++) {
			lua_pushinteger(L, boxes[k][j]);
			lua_setfield(L, -2, keys[j]);
		}
		lua_rawseti(L, -2, k + 1);
	}
	luaA_object_emit_signal(L, -2, "clay::solved", 1);
	lua_settop(L, top);
}

/* Publish changed trees' boxes and IDs through the public signal. */
static void
solved_emit(void)
{
	lua_State *L = globalconf_L;
	size_t len = solved_len;

	if (!L)
		return;
	for (size_t i = 0; i < len; i++) {
        if (!solved_hosts[i].tree->publish_pending) continue;
        solved_hosts[i].tree->publish_pending = false;
		drawable_push(L, solved_hosts[i].drawable);
		solved_signal(L, solved_hosts[i].tree);
	}
}


int
declare_output_order(struct declare_output *dout, void **objects,
	int cap)
{
	int n = 0;

	if (!dout->band.clay)
		return 0;
    struct declare_band *band = &dout->band;
    for (size_t i = 0; i < band->command_handles_len && n < cap; i++) {
        enum declare_kind kind = 0;
        void *object = declare_handle_get(band->command_handles[i], &kind);

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

static int context_capacity = CLAY_ELEMENTS_MAX;
static int allocation_failures;

size_t declare_widget_budget(struct declare_output *dout)
{
    int capacity = CLAY_ELEMENTS_MAX;
    if (dout && dout->band.clay) {
        Clay_Context *previous = Clay_GetCurrentContext();
        Clay_SetCurrentContext(dout->band.clay);
        capacity = clay_capacity().capacity;
        Clay_SetCurrentContext(previous);
    }
    return capacity > 8192 ? MIN((size_t)(capacity / 2 - 4096), (size_t)12288) : 256;
}

bool declare_measure_text(Monitor *m, int32_t font, const char *text,
	size_t len, float *width, float *height)
{
    struct declare_band *band = m && m->declare ? &m->declare->band : NULL;
    if (!band || !band->clay) return false;
    Clay_Context *previous = Clay_GetCurrentContext();
    /* The cache holds widths at the band's scale until declare_band_update
     * resets it, so measure at that scale. */
    float scale = render_text_set_measure_scale(
        band->scale > 0.0f ? band->scale : m->declare->wlr_output->scale);
    Clay_SetCurrentContext(band->clay);
    Clay_Dimensions d = clay_measure_text(
        (Clay_String){.length = (int32_t)len, .chars = text}, font);
    Clay_SetCurrentContext(previous);
    render_text_set_measure_scale(scale);
    *width = d.width;
    *height = d.height;
    return true;
}

void declare_output_resource_failure(struct declare_output *dout)
{
    if (dout) dout->band.exhausted = true;
}

void declare_test_capacity(int capacity, int failures)
{
    context_capacity = capacity;
    allocation_failures = failures;
}

void declare_test_failure(struct declare_output *dout, int elements)
{
    dout->band.fail_elements = elements;
    declare_output_mark_dirty(dout);
}

static void
handle_clay_error(Clay_ErrorData error)
{
    struct declare_band *band = error.userData;
    /* The full debug view can hash two generated rows to the same ID. Clay
     * marks those rows as collisions. Only tolerate that diagnostic when
     * both elements belong to the inspector, never for desktop declarations. */
    if (error.errorType == CLAY_ERROR_TYPE_DUPLICATE_ID && band->inspector_solving
            && clay_inspector_duplicate(band->inspector_authored)) {
        if (!band->inspector_collision_logged)
            fprintf(stderr, "clay inspector: generated row ID collision\n");
        band->inspector_collision_logged = true;
        return;
    }
    switch (error.errorType) {
    case CLAY_ERROR_TYPE_ARENA_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_TEXT_MEASUREMENT_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED:
    /* Pinned Clay reports full working arrays with its internal-error type. */
    case CLAY_ERROR_TYPE_INTERNAL_ERROR:
        band->exhausted = true;
        fprintf(stderr, "clay resource %d: %.*s\n", error.errorType,
            error.errorText.length, error.errorText.chars);
        return;
    default:
        fprintf(stderr, "clay invariant %d: %.*s\n", error.errorType,
            error.errorText.length, error.errorText.chars);
        abort();
    }
}

/* One band: an arena-backed Clay context and a render_state reconciling
 * into a fresh tree under parent. */
static void
declare_band_init(struct declare_band *band, struct wlr_output *wlr_output,
	struct wlr_scene_tree *parent)
{
    Clay_SetCurrentContext(NULL);
    Clay_SetMaxElementCount(context_capacity);
    uint32_t arena_size = Clay_MinMemorySize();
	int width, height;

	wlr_output_effective_resolution(wlr_output, &width, &height);
    /* Sparse fixed arenas should fault ordinary pages, rather than a huge page
     * for every small used array prefix. Align the allocation so the advice
     * cannot affect unrelated allocator storage. */
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    size_t allocation_size = (arena_size + page - 1) / page * page;
    if (allocation_failures > 0) {
        allocation_failures--;
    } else if (posix_memalign(&band->arena, page, allocation_size) == 0) {
        madvise(band->arena, allocation_size, MADV_NOHUGEPAGE);
    }
    if (!band->arena) return;
	band->clay = Clay_Initialize(
		Clay_CreateArenaWithCapacityAndMemory(arena_size, band->arena),
		(Clay_Dimensions) { .width = width, .height = height },
		(Clay_ErrorHandler) { .errorHandlerFunction = handle_clay_error, .userData = band });
    if (!band->clay) {
        free(band->arena);
        band->arena = NULL;
        return;
    }
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
    for (size_t i = 0; i < band->hosts_len; i++) widget_tree_release(band->hosts[i].view);
    free(band->hosts);
    for (size_t i = 0; i < band->retired_len; i++) widget_tree_release(band->retired[i]);
    free(band->retired);
    free(band->retained_dump);
    free(band->words);
    free(band->settle);
    free(band->command_handles);
    release_exit_owners(band, NULL, 0);
    free(band->exit_owners);
    free(band->entrances);
    free(band->transition_baselines);
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
	declare_element_word(band, CLAY_ID("Clay__RootContainer"),
		DECLARE_SRC_OUTPUT, DECLARE_SRC_OUTPUT);
	render_set_position(band->render, lx, ly);
	render_set_scale(band->render, wlr_output->scale);
	if (band->scale != wlr_output->scale) {
		/* Clay keys cached text widths on content and text config, while
		 * render_measure_text also depends on the output's scale. */
		Clay_ResetMeasureTextCache();
		band->scale = wlr_output->scale;
	}
}

struct declare_output *
declare_output_create(struct wlr_output *wlr_output)
{
	struct declare_output *dout = calloc(1, sizeof(*dout));

	dout->wlr_output = wlr_output;
	dout->deadline = wl_event_loop_add_timer(
		wl_display_get_event_loop(some_get_display()), deadline_fire, dout);
	/* Every band lives in LyrDesktop; LyrBlock above it is the parent an
	 * ext-session-lock client's surfaces are created under, before the
	 * declare pass borrows them into this tree. */
	declare_band_init(&dout->band, wlr_output, layers[LyrDesktop]);
	dout->dirty = true;
	return dout;
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
	declare_band_wipe(&dout->band);
	declare_handle_drop(dout);
	image_entry_set(&dout->wallpaper, NULL);
	image_entry_set(&dout->cursor, NULL);
	free(dout);
}

void
declare_output_update(struct declare_output *dout, int lx, int ly)
{
	declare_band_update(&dout->band, dout->wlr_output, lx, ly);
	declare_output_mark_dirty(dout);
}

/* Release references owned by the departing Lua VM before its registry dies.
 * Reinitialize the existing arena so no transition or input map retains a
 * pointer into that VM's native widget payloads. */
void
declare_state_clear(void)
{
    Monitor *m;
    screens_clear();
    solved_len = 0;
    wl_list_for_each(m, &mons, link) {
        if (!m->declare) continue;
        struct declare_band *band = &m->declare->band;
        if (!band->clay) continue;
        for (size_t i = 0; i < band->hosts_len; i++) widget_tree_release(band->hosts[i].view);
        free(band->hosts);
        band->hosts = NULL;
        band->hosts_len = 0;
        for (size_t i = 0; i < band->retired_len; i++) widget_tree_release(band->retired[i]);
        free(band->retired);
        band->retired = NULL;
        band->retired_len = 0;
        band->records_len = 0;
        band->settle_len = 0;
        band->context_valid = false;
        free(band->retained_dump);
        band->retained_dump = NULL;
        band->command_handles_len = 0;
        release_exit_owners(band, NULL, 0);
        Clay_SetCurrentContext(band->clay);
        int width, height;
        wlr_output_effective_resolution(m->declare->wlr_output, &width, &height);
        Clay_Dimensions dimensions = {width, height};
        band->clay = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(
            Clay_MinMemorySize(), band->arena), dimensions,
            (Clay_ErrorHandler) { .errorHandlerFunction = handle_clay_error, .userData = band });
        Clay_SetCullingEnabled(false);
        Clay_SetMeasureTextFunction(render_measure_text, NULL);
    }
}

void
declare_hot_reload(void)
{
	Monitor *m;

	wl_list_for_each(m, &mons, link) {
		struct declare_output *dout = m->declare;
		if (!dout || !dout->band.render)
			continue;
		render_destroy(dout->band.render, &client_hooks);
		dout->band.render = render_create(dout->band.tree);
		declare_band_update(&dout->band, dout->wlr_output, m->m.x, m->m.y);
		declare_output_mark_dirty(dout);
	}
}

void
declare_output_mark_dirty(struct declare_output *dout)
{
	dout->dirty = true;
	wlr_output_schedule_frame(dout->wlr_output);
	if (!dout->deadline_armed) {
		bool is_virtual = wlr_output_is_headless(dout->wlr_output)
				|| wlr_output_is_wl(dout->wlr_output);
		dout->deadline_armed = true;
		wl_event_source_timer_update(dout->deadline,
				is_virtual ? 16 : DECLARE_DEADLINE_MS);
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
			&& declare_output_frame(dout, m) > 0)
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

struct native_pass {
    struct declare_band *band;
    Monitor *m;
    float elapse;
    Clay_RenderCommandArray *commands;
    int64_t *declared;
};

static bool native_try(struct native_pass *pass)
{
    struct declare_band *band = pass->band;
    record_begin(band);
    band->output_name = pass->m->declare->wlr_output->name;
    clay_clips_begin(band->inspector_authored, Clay_IsDebugModeEnabled());
    band->transition_baselines_len = clay_transition_snapshot(&band->transition_baselines, &band->transition_baselines_cap);
    declare_begin_layout();
    declare_scene(pass->m);
    if (!band->exhausted && band->fail_elements) {
        for (int i = 0; i < band->fail_elements && !band->exhausted; i++) {
            native_open(Clay__HashStringWithOffset(CLAY_STRING("capacity.probe"), i, 0));
            native_configure(&(Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIXED(1), CLAY_SIZING_FIXED(1)},
            });
            native_close();
        }
    }
    record_end();
    *pass->declared = now_us();
    if (band->exhausted) return false;
    if (Clay_IsDebugModeEnabled()) {
        int elements, strings;
        bool fits = clay_inspector_fits(&elements, &strings);
        band->inspector_authored = clay_capacity().elements;
        band->inspector_elements = elements;
        band->inspector_strings = strings;
        if (!fits) {
            fprintf(stderr, "clay inspector refused on %s: authored %d, element bound %d, string bound %d, capacity %d; debug view disabled\n",
                pass->m->declare->wlr_output->name, clay_capacity().elements,
                elements, strings, clay_capacity().capacity);
            band->inspector_refused = true;
            Clay_SetDebugModeEnabled(false);
        }
    } else band->inspector_authored = 0;
    band->inspector_solving = Clay_IsDebugModeEnabled();
    clay_entrances_first();
    *pass->commands = Clay_EndLayout(pass->elapse);
    /* A new entrance starts on this frame, regardless of the band's prior frame interval. */
    for (size_t i = 0; i < band->entrances_len; i++)
        clay_reenter((Clay_ElementId){.id = band->entrances[i]}, false);
    band->inspector_solving = false;
    band->exhausted |= clay_capacity_failed();
    return !band->exhausted;
}

static void dump_tree(buffer_t *buf, struct declare_band *band);

static bool shares_payload(struct widget_tree *tree, struct declared_host *hosts, size_t length)
{
	for (size_t i = 0; i < length; i++)
		if (tree->storage == hosts[i].view->storage) return true;
	return false;
}

int
declare_output_frame(struct declare_output *dout, Monitor *m)
{
	static bool in_pass;
	struct declare_band *band = &dout->band;
	Clay_RenderCommandArray commands;
	Clay_Vector2 insp_point = { -1, -1 };
	bool inspecting, insp_edge = false, insp_closed = false;
    unsigned panel_width = 0;
	int64_t start, declared, solved;
    float dt = 0, elapse = 0;
    int lua_top = lua_gettop(globalconf_L);
    struct declare_record *old_records = band->records;
    size_t old_len = band->records_len, old_cap = band->records_cap;
    struct declared_host *next_hosts = NULL;
    size_t next_len = 0;
    struct widget_tree **retired = NULL;
    size_t retired_len = 0, retired_bytes = 0;
    struct clay_capacity failed_counts = {0};
    uint64_t *next_handles = NULL;

	/* A clay::solved handler that runs a frame of its own (awesome
	 * ._test_redeclare) finds this one mid-pass. */
	if (!dout->dirty || in_pass)
		return -1;
    in_pass = true;
    if (!band->clay) {
        declare_band_init(band, dout->wlr_output, layers[LyrDesktop]);
        if (!band->clay) { dout->dirty = false; in_pass = false; return -1; }
        declare_band_update(band, dout->wlr_output, m->m.x, m->m.y);
    }
    band->exhausted = false;
    band->inspector_refused = false;
    Clay_SetCurrentContext(band->clay);
    if (band->context_valid) {
        buffer_t previous_tree = BUFFER_INIT;
        dump_tree(&previous_tree, band);
        free(band->retained_dump);
        band->retained_dump = buffer_detach(&previous_tree);
    }
    band->records = NULL;
    band->records_len = band->records_cap = 0;

	band->frames++;
	inspecting = inspector_declares(dout);

	/* Compile pending inputs, declare and solve once, then reconcile.
	 * Dirty marks raised from here on schedule the next frame. */
	dout->dirty = false;
    band->scrollbar_records_len = 0;
    solved_len = 0;
    luaA_emit_signal_global("clay::declare");
    lua_getfield(globalconf_L, LUA_REGISTRYINDEX, "_LOADED");
    lua_getfield(globalconf_L, -1, "somewm.animation");
    animations_disabled = globalconf.mousegrabber != LUA_REFNIL;
    if (lua_istable(globalconf_L, -1)) {
        lua_getfield(globalconf_L, -1, "enabled");
        animations_disabled = animations_disabled || !lua_toboolean(globalconf_L, -1);
        lua_pop(globalconf_L, 1);
    }
    lua_pop(globalconf_L, 2);
    if (band->exhausted) goto failed;
	start = now_us();
    in_frame = true;
    Clay_SetCurrentContext(band->clay);
	/* Clay draws the panel from this flag inside Clay_EndLayout, and
	 * reserves its width in Clay_BeginLayout (clay.h:4716), so it is
	 * written before the layout opens and from the same answer
	 * OUTPUT's padding used. */
	if (Clay_IsDebugModeEnabled() != inspecting)
		Clay_SetDebugModeEnabled(inspecting);
	render_text_set_measure_scale(dout->wlr_output->scale);
	if (inspecting) {
		insp_edge = inspector_feed(dout, m, &insp_point);
		if (!Clay_IsDebugModeEnabled()) {
			/* The x button's hover handler ran inside inspector_feed's third
			 * pointer call, before Clay_BeginLayout, so this frame's layout
			 * has no panel and OUTPUT must not pad for one. */
			dout->inspecting = false;
			inspecting = false;
			insp_closed = true;
			inspector_resync();
		}
	}
	if (!inspecting) {
		Clay_Vector2 point = xytomon(cursor->x, cursor->y) == m
			? (Clay_Vector2) { cursor->x - m->m.x, cursor->y - m->m.y }
			: (Clay_Vector2) { -1, -1 };
		Clay_SetPointerState(point, false);
		Clay_SetPointerState(point, false);
	}
	dt = dout->last_frame_us ? (start - dout->last_frame_us) / 1e6 : 0;
	dout->last_frame_us = start;
	/* A transition's clock only runs while one is running. An
	 * idle output frames when something dirties it, so the
	 * frame that starts a transition arrives an arbitrary time
	 * after the last one, and that gap is not animation time. */
	elapse = band->transitioning ? dt : 0;
	Clay_UpdateScrollContainers(false,
		(Clay_Vector2) { dout->scroll_x, dout->scroll_y }, dt);
	dout->scroll_x = dout->scroll_y = 0;
    /* Select the authored departure policy before Clay copies an omitted client subtree. */
    for (size_t i = 0; i < old_len; i++) {
        struct declare_record *record = &old_records[i];
        if (!record->client_exit) continue;
        Client *c = declare_handle_get(record->handle, NULL);
        if (c && declarable_client(c)) {
            clay_exit_transition((Clay_ElementId){.id = record->id}, (Clay_TransitionElementConfig){0});
            continue;
        }
        struct widget_transition policy = record->exit_policy;
        bool tagged = c && client_has_surface(c);
        if (tagged) policy.exit_state = policy.tag_exit;
        policy.duration = tagged ? policy.tag_duration : policy.exit_duration;
        policy.properties |= widget_transition_properties(policy.exit_state);
        clay_exit_transition((Clay_ElementId){.id = record->id}, transition_config(&policy));
    }
    band->previous_records = old_records;
    band->previous_records_len = old_len;
    struct native_pass pass = {band, m, elapse, &commands, &declared};
    if (!native_try(&pass)) goto failed;
	/* Collapsing a track changes the content's box too. Compare both
	 * dimensions even when the record has no overflow. A changed record
	 * supplies the next frame's thumb declaration. */
	for (size_t i = 0; i < band->scrollbar_records_len; i++) {
		const struct scrollbar_record *record = &band->scrollbar_records[i];
		Clay_ScrollContainerData data = Clay_GetScrollContainerData(record->id);
		Clay_Vector2 position = data.found ? *data.scrollPosition : (Clay_Vector2) {0};
		if (record->found != data.found
				|| record->position.x != position.x || record->position.y != position.y
				|| record->content.width != data.contentDimensions.width
				|| record->content.height != data.contentDimensions.height
				|| record->box.width != data.scrollContainerDimensions.width
				|| record->box.height != data.scrollContainerDimensions.height)
			declare_output_mark_dirty(dout);
	}
	solved = now_us();
	in_frame = false;
	panel_width = inspecting && !band->inspector_refused ? Clay__debugViewWidth : 0;
	/* Retire the edge now that the pass that wanted it is over
	 * (inspector_feed says why). */
	if (insp_edge)
		Clay_SetPointerState(insp_point, insp.down);
	if (inspecting && band->inspector_refused) {
		dout->inspecting = false;
		inspecting = false;
		insp_closed = true;
		inspector_resync();
		declare_output_mark_dirty(dout);
	}
	band->declare_us = declared - start;
	band->solve_us = solved - declared;
    /* Every frame: a scroll moves a layout's boxes without a new tree. */
    for (size_t i = 0; i < screen_declarations_len; i++) {
        screen_t *screen = screen_declarations[i].screen;
        if (!screen->valid || !screen->layout.nodes_len) continue;
        luaA_screen_push(globalconf_L, screen);
        solved_signal(globalconf_L, &screen->layout);
    }

    next_handles = malloc((size_t)(commands.length + 1) * sizeof(*next_handles));
    if (!next_handles) goto failed;
    /* A shadow is emitted before its frame, so collect the frame carrier with the owner handles. */
    render_fades_begin(band->render);
    for (int i = 0; i < commands.length; i++) {
        Clay_RenderCommand *cmd = &commands.internalArray[i];
        next_handles[i] = declare_userdata_handle(cmd->userData);
        if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START) {
            render_fade_carrier(band->render, cmd);
            Clay_ElementData element = Clay_GetElementData((Clay_ElementId){.id = cmd->id});
            assert(element.found);
            render_carrier_box(band->render, cmd->id, element.boundingBox);
        }
    }
    next_len = solved_len;
    next_hosts = calloc(next_len ? next_len : 1, sizeof(*next_hosts));
    if (!next_hosts) goto failed;
    for (size_t i = 0; i < next_len; i++) {
        next_hosts[i].host = solved_hosts[i];
        next_hosts[i].view = widget_tree_hold(solved_hosts[i].tree);
        if (!next_hosts[i].view) goto failed;
    }
    retired = calloc(band->retired_len + band->hosts_len + 1, sizeof(*retired));
    if (!retired) goto failed;
    for (size_t i = 0; i < band->retired_len + band->hosts_len; i++) {
        struct widget_tree *tree = i < band->retired_len ? band->retired[i] : band->hosts[i - band->retired_len].view;
        if (!shares_payload(tree, next_hosts, next_len) && widget_tree_referenced(tree)) {
            retired_bytes += widget_tree_bytes(tree);
            if (retired_bytes > 8 * 1024 * 1024) {
                fprintf(stderr, "clay output %s: retained widget payloads exceed 8 MiB\n", dout->wlr_output->name);
                goto failed;
            }
            retired[retired_len++] = tree;
        }
    }
    for (size_t i = 0; i < band->retired_len + band->hosts_len; i++) {
        struct widget_tree *tree = i < band->retired_len ? band->retired[i] : band->hosts[i - band->retired_len].view;
        bool keep = false;
        for (size_t j = 0; j < retired_len; j++) if (retired[j] == tree) keep = true;
        if (!keep) widget_tree_release(tree);
    }
    free(band->retired);
    band->retired = retired;
    band->retired_len = retired_len;
    free(band->hosts);
    band->hosts = next_hosts;
    band->hosts_len = next_len;
    for (size_t i = 0; i < band->records_len; i++) {
        struct declare_record *record = &band->records[i];
        if (!record->has_host) continue;
        for (size_t j = 0; j < next_len; j++)
            if (record->host.tree == next_hosts[j].host.tree)
                record->host.tree = next_hosts[j].view;
    }
    band->previous_records = NULL;
    band->previous_records_len = 0;
    free(old_records);
    free(band->command_handles);
    band->command_handles = next_handles;
    band->command_handles_len = commands.length;
    release_exit_owners(band, next_handles, commands.length);
    band->committed_capacity = clay_capacity();
    band->context_valid = true;
    free(band->retained_dump);
    band->retained_dump = NULL;
    dout->inspector_width = panel_width;
    bars_settle(m);
    popups_settle(m);
    for (size_t i = 0; i < screen_declarations_len; i++) {
        screen_activate(&screen_declarations[i]);
        workarea_settle(m);
    }
    screen_activate(NULL);
    clients_settle(m, band);
    solved_emit();
    for (size_t i = 0; i < screen_declarations_len; i++) {
        screen_t *screen = screen_declarations[i].screen;
        if (screen->valid) luaA_emit_signal_global_with_screen("clay::_commit", screen);
    }
    screens_clear();
    solved_len = 0;

	/* The reconcile rasterises shape leaves through their Lua callbacks,
	 * which must not change the tree it is drawing. */
	start = now_us();
	in_frame = true;
	band->commands = commands.length;
	/* Pass every owner's completed layout box alongside its shadow,
	 * including owners without a paint command. */
	for (int32_t i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = &commands.internalArray[i];
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM ||
				cmd->renderData.custom.customData == RENDER_CLIP_MARK ||
				!((uintptr_t)cmd->renderData.custom.customData & RENDER_SHADOW_TAG))
			continue;
		struct render_shadow *shadow = render_shadow_of(cmd->renderData.custom.customData);
		Clay_ElementData owner = Clay_GetElementData((Clay_ElementId){.id = shadow->owner_id});
		assert(owner.found);
		shadow->owner_box = owner.boundingBox;
	}
    render_constraints_begin(band->render);
    for (int32_t i = 0; i < clay_root_count(); i++) {
        animation_constraints(band->render, clay_root_element(i),
            (Clay_BoundingBox){0, 0, m->m.width, m->m.height});
    }
	render_set_output_id(band->render, output_id(m).id);
	band->mutations = render_reconcile(band->render, commands,
		&client_hooks, (Clay_BoundingBox) { 0, 0, m->m.width, m->m.height });
	in_frame = false;
	band->reconcile_us = now_us() - start;
    /* X11 carries position and size in one reply. All render hooks must
     * have installed this solve before any managed X11 client sees it. */
    for (size_t i = 0; i < band->records_len; i++) {
        struct declare_record *record = &band->records[i];
        if (!record->client_frame) continue;
        Client *c = declare_handle_get(record->handle, NULL);
        if (!c || c->client_type != X11 || c->mon != m) continue;
        Clay_ElementData data = Clay_GetElementData((Clay_ElementId){.id = record->id});
        if (!data.found) continue;
        Clay_BoundingBox b = data.boundingBox;
        int x = lroundf(b.x), y = lroundf(b.y);
        xwayland_publish_geometry(c, (struct wlr_box){m->m.x + x, m->m.y + y,
            lroundf(b.x + b.width) - x, lroundf(b.y + b.height) - y},
            record->x11_configure_serial);
    }
	in_pass = false;
	/* A transition that has not settled needs the next frame to advance
	 * it, and one more to settle on; when every record is idle the output
	 * stays clean. */
	Clay_SetCurrentContext(band->clay);
	bool transitioning = clay_transitions_active();
	if (transitioning || band->transitioning)
		declare_output_mark_dirty(dout);
	band->transitioning = transitioning;
	if (insp_closed)
		inspector_emit_closed(m);
    return band->mutations;

failed:
    in_frame = false;
    screens_clear();
    record_end();
    lua_settop(globalconf_L, lua_top);
    Clay_SetCurrentContext(band->clay);
    failed_counts = clay_capacity();
    Clay_Dimensions dimensions = Clay_GetLayoutDimensions();
    band->clay = Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(
        Clay_MinMemorySize(), band->arena), dimensions,
        (Clay_ErrorHandler){handle_clay_error, band});
    Clay_SetCullingEnabled(false);
    Clay_SetMeasureTextFunction(render_measure_text, NULL);
    band->context_valid = false;
    band->transitioning = false;
    dout->last_frame_us = 0;
    free(next_handles);
    for (size_t i = 0; i < next_len; i++)
        if (next_hosts) widget_tree_release(next_hosts[i].view);
    free(next_hosts);
    free(retired);
    free(band->records);
    band->previous_records = NULL;
    band->previous_records_len = 0;
    band->records = old_records;
    band->records_len = old_len;
    band->records_cap = old_cap;
    for (size_t i = 0; i < solved_len; i++) solved_hosts[i].tree->declared = false;
    solved_len = band->scrollbar_records_len = bars_len = 0;
    dout->dirty = false;
    fprintf(stderr, "clay output %s capacity exhausted: elements %d/%d map %d free %d transitions %d inspector %s; retained scene, context reinitialized\n",
        dout->wlr_output->name, failed_counts.elements, failed_counts.capacity,
        failed_counts.map, failed_counts.freeIds, failed_counts.transitions, inspecting ? "on" : "off");
    if (inspecting) {
        declare_inspector_set(dout, false);
        inspector_emit_closed(m);
    }
    in_pass = false;
    return -1;
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

static bool
inspector_declares(const struct declare_output *dout)
{
	return dout->inspecting && !session_is_locked();
}

bool
declare_inspector_get(struct declare_output *dout)
{
	/* The screen's own setting, not Clay's flag: the frame writes that
	 * flag from this one and forces it off while the session is locked,
	 * so reading it back would report the lock rather than the screen.
	 * A panel that closed itself from inside the solve is mirrored here
	 * by the frame that saw it (declare_output_frame). */
	return dout->inspecting;
}

void
declare_inspector_set(struct declare_output *dout, bool on)
{
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
		if (font && !err && m->declare->band.clay) {
			Clay_SetCurrentContext(m->declare->band.clay);
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
declare_wheel(double dx, double dy)
{
	Monitor *m = xytomon(cursor->x, cursor->y);

	if (!m || !m->declare)
		return;
	m->declare->scroll_x += dx;
	m->declare->scroll_y += dy;
	declare_output_mark_dirty(m->declare);
}

bool
declare_inspector_covers(double lx, double ly)
{
	Monitor *m = xytomon(lx, ly);

	/* A locked session never declares the panel (declare_output_frame),
	 * so nothing there can own the point either. */
	if (!m || !m->declare || !m->declare->inspector_width || session_is_locked())
		return false;
	return lx - m->m.x >= m->m.width - (double)m->declare->inspector_width;
}

/* Feed the panel the current output's pointer before BeginLayout. Two calls
 * pin the edge machine to pressed or released; a latched press instead feeds
 * an up/down pair for PRESSED_THIS_FRAME, then a third call hands that edge
 * to the previous layout's hover handlers so the x button can close the panel.
 * If the panel stays open, another up/down pair pins PRESSED_THIS_FRAME for
 * row selection and collapse during layout. Outputs away from the cursor
 * receive an off-panel point and a released button. The caller retires the
 * press edge after EndLayout. */
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
			Clay_SetPointerState(*point, true);
			if (Clay_IsDebugModeEnabled()) {
				Clay_SetPointerState(*point, false);
				Clay_SetPointerState(*point, true);
			}
			edge = true;
		}
	}
	if (!edge) {
		bool down = insp.down && mine;

		Clay_SetPointerState(*point, down);
		Clay_SetPointerState(*point, down);
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
 * Per band: a header of counters (the frame's commands, its scene mutations,
 * the scene nodes it created and swept, the nodes held including those kept
 * dark for an element still in the tree), the root and derived counts, the
 * tree as Clay holds it after the solve (its roots in command order, one
 * element per line, indented, named by what somewm recorded for the id), the
 * drawins it refused, then the realized list: one line per node the frame's
 * commands drew, in draw order, read back from the last reconcile (render.h).
 * Nothing here solves or declares: the dump reports the frame the output drew.
 * The realized list doubles as a tree==scene check in release builds, where
 * the verifier is compiled out, by printing the renderer's own mismatch
 * answer.
 *
 * Every box a line prints is in logical coordinates with both edges rounded
 * to whole pixels, so an element's box is the box the scene realizes and the
 * one a client's configure and geometry carry.
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
    case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START: return "FADE_START";
    case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END: return "FADE_END";
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
	[DECLARE_KIND_LOCK_BLOCK] = "lock",
	[DECLARE_KIND_DRAG] = "drag",
	[DECLARE_KIND_POPUP] = "popup",
	[DECLARE_KIND_CURSOR] = "cursor",
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
	case DECLARE_KIND_LOCK_BLOCK:
		buffer_adds(buf, ((struct declare_output *)object)->wlr_output->name);
		break;
	case DECLARE_KIND_DRAG:
		buffer_adds(buf, "icon");
		break;
	case DECLARE_KIND_CURSOR:
		buffer_adds(buf, object != cursor ? "surface"
			: cursor_image.name ? cursor_image.name : "-");
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
 * its name, since a converted drawin declares no leaf of its own and every
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
			buffer_addf(buf, "widget %s%s", n->name ? n->name : "-",
				n->image ? " image" : "");
			return;
		}
	}
	buffer_addf(buf, "%s ", kind_names[kind]);
	dump_object(buf, handle);
}

/* A dump line's box is whole pixels, and an element's solved box is a float.
 * Round both of its edges, the rule render.c realizes a box with and
 * client_solved_box writes a client's geometry with, so the line prints the
 * box on screen. Truncating instead loses the fractional edge of a GROW
 * split and reads a pixel short of what the scene and the configure carry.
 * These stay logical coordinates; the scale is applied further down. */
static Clay_BoundingBox
dump_box(Clay_BoundingBox b)
{
	float x = lroundf(b.x), y = lroundf(b.y);

	return (Clay_BoundingBox) { x, y,
		lroundf(b.x + b.width) - x, lroundf(b.y + b.height) - y };
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
	Clay_BoundingBox box = dump_box(v->box), rbox = dump_box(v->rbox);
	buffer_addf(buf, "box %d,%d %dx%d rbox %d,%d %dx%d ",
		(int)box.x, (int)box.y,
		(int)box.width, (int)box.height,
		(int)rbox.x, (int)rbox.y,
		(int)rbox.width, (int)rbox.height);
	Clay_BoundingBox pbox = v->presented;
	if (memcmp(&pbox, &v->rbox, sizeof(pbox))) {
		buffer_addf(buf, "presented %d,%d %dx%d ", (int)pbox.x, (int)pbox.y, (int)pbox.width, (int)pbox.height);
	}
	dump_what(buf, v->id, v->user_data);
	if (v->raster_bytes)
		buffer_addf(buf, " raster=%zu", v->raster_bytes);
	/* A SCISSOR marker, a clip mark and a configure probe realize no node
	 * by design; anything else that did not is a surface whose client died
	 * mid-frame. */
	if (v->clip_mark)
		buffer_adds(buf, " clip");
	else if (v->probe)
		buffer_adds(buf, " configure");
	else if (!v->has_node && v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_START
			&& v->type != CLAY_RENDER_COMMAND_TYPE_SCISSOR_END
			&& v->type != CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START
			&& v->type != CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END)
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
dump_word(buffer_t *buf, uint8_t src)
{
	if (declare_src_names[src])
		buffer_addf(buf, " %s", declare_src_names[src]);
}

static void
dump_sizing(buffer_t *buf, const struct widget_node *n, int axis)
{
	if (n->sizing[axis] == WIDGET_SIZING_FIXED)
		buffer_addf(buf, "fixed(%g)", n->size[axis]);
	else if (n->sizing[axis] == WIDGET_SIZING_PERCENT)
		buffer_addf(buf, "percent(%g)", n->size[axis]);
	else {
		buffer_adds(buf, n->sizing[axis] == WIDGET_SIZING_GROW ? "grow" : "fit");
		if (n->min[axis] > 0)
			buffer_addf(buf, ">=%g", n->min[axis]);
		if (n->max[axis] > 0)
			buffer_addf(buf, "<=%g", n->max[axis]);
	}
	dump_word(buf, n->src[axis]);
}

/* The record a track or thumb element declared from in the last frame, or
 * NULL when the band's record array was full. */
static const struct scrollbar_record *
scrollbar_record_for(const struct declare_band *band, Clay_ElementId node)
{
	for (size_t i = 0; i < band->scrollbar_records_len; i++)
		if (band->scrollbar_records[i].node.id == node.id)
			return &band->scrollbar_records[i];
	return NULL;
}

/* One axis of a track or thumb as the frame declared it from its record:
 * the thumb's length along the scroll axis, nothing across a collapsed
 * track, the authored sizing otherwise. */
static void
dump_scrollbar_sizing(buffer_t *buf, const struct widget_node *n,
	const struct scrollbar_record *r, int axis)
{
	bool along = axis == (r->axis == 2);

	if (n->thumb && along)
		buffer_addf(buf, "fixed(%g)", r->length);
	else if (r->collapsed && !along)
		buffer_adds(buf, "fixed(0)");
	else {
		dump_sizing(buf, n, axis);
		return;
	}
	dump_word(buf, DECLARE_SRC_SCROLL);
}

/* A gradient fill record, as the describer declared it. */
static void
dump_gradient(buffer_t *buf, const struct render_gradient *g)
{
	const float *p = g->points;

	if (g->kind == 1)
		buffer_addf(buf, " fill linear %g,%g %g,%g stops", p[0], p[1], p[2], p[3]);
	else
		buffer_addf(buf, " fill radial %g,%g,%g %g,%g,%g stops",
			p[0], p[1], p[2], p[3], p[4], p[5]);
	for (int i = 0; i < g->count; i++) {
		const float *c = g->stops[i];
		buffer_addf(buf, " %g:%g,%g,%g,%g", c[0], c[1], c[2], c[3], c[4]);
	}
}

/* One line for a widget node: what the tree says the node is and the box
 * the last solve gave it. Widget lines carry the element id and a four
 * space prefix, which is what the widget tests read. */
static void
dump_widget_line(buffer_t *buf, const struct widget_host *host, size_t i, Clay_ElementId id,
	int depth)
{
	struct widget_tree *d = host->tree;
	const struct widget_node *n = &d->nodes[i];
	Clay_ElementData data = Clay_GetElementData(id);
	const struct scrollbar_record *bar = (n->track || n->thumb)
			&& host->m && host->m->declare
		? scrollbar_record_for(&host->m->declare->band, id) : NULL;

	buffer_addf(buf, "    %08x %*s%s", id.id, depth * 2, "",
		n->name ? n->name : "-");
	if (n->image) {
		buffer_addf(buf, " image %dx%d", n->vector ? (int)n->image_size[0]
			: cairo_image_surface_get_width((cairo_surface_t *)n->image),
			n->vector ? (int)n->image_size[1]
			: cairo_image_surface_get_height((cairo_surface_t *)n->image));
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
	static const char *const transforms[] = {
		"normal", "90", "180", "270",
		"flipped", "flipped-90", "flipped-180", "flipped-270",
	};
	if (n->transform && !n->text)
		buffer_addf(buf, " transform %s", transforms[n->transform]);
	if (n->gradient.kind)
		dump_gradient(buf, &n->gradient);
	if (!n->widget && !n->text && !n->image)
		buffer_adds(buf, " spacer");
	if (n->clip_opens && !(i == 0 && (host->inner_clip || host->path_clip)))
		buffer_adds(buf, " clip");
	if (n->scroll) {
		Clay_ElementDeclaration e = { 0 };
		clay_element_declaration(id, &e);
		float offset = n->scroll == 1 ? e.clip.childOffset.x : e.clip.childOffset.y;
		buffer_addf(buf, " scroll=%s scrolled=%g", n->scroll == 1 ? "x" : "y",
			offset == 0 ? 0 : -offset);
	}
	if (n->cut)
		buffer_addf(buf, " cut=%s", n->cut == 1 ? "x" : n->cut == 2 ? "y" : "both");
	if (n->text) {
		buffer_addf(buf, " \"%.*s\" font=%u", (int)n->text_len,
			d->text + n->text_off, n->font);
		if (n->transform)
			buffer_addf(buf, " transform %s", transforms[n->transform]);
	} else if (i == 0 && host->flow) {
		for (int axis = 0; axis < 2; axis++) {
			buffer_adds(buf, axis ? " h=" : " w=");
			if (host->fit[axis])
				dump_sizing(buf, n, axis);
			else if (host->told[axis]) {
				buffer_addf(buf, "fixed(%d)", host->told[axis]);
				dump_word(buf, host->src[axis]);
			} else
				buffer_adds(buf, "grow");
		}
	} else if (i == 0 && n->sizing[0] == WIDGET_SIZING_FIXED
			&& n->sizing[1] == WIDGET_SIZING_FIXED) {
		buffer_addf(buf, " w=fixed(%d)", host->w);
		dump_word(buf, host->src[0]);
		buffer_addf(buf, " h=fixed(%d)", host->h);
		dump_word(buf, host->src[1]);
	} else if (bar) {
		buffer_adds(buf, " w=");
		dump_scrollbar_sizing(buf, n, bar, 0);
		buffer_adds(buf, " h=");
		dump_scrollbar_sizing(buf, n, bar, 1);
	} else {
		buffer_adds(buf, " w=");
		dump_sizing(buf, n, 0);
		buffer_adds(buf, " h=");
		dump_sizing(buf, n, 1);
	}
	if (!n->text) {
		uint16_t pad[4] = { n->pad[0], n->pad[1], n->pad[2], n->pad[3] };
		/* A track's offset is the padding before the thumb. */
		if (bar && n->track && !bar->collapsed)
			pad[bar->axis == 2 ? 2 : 0] = bar->offset;
		if (!n->image && !n->shape)
			buffer_adds(buf, n->vertical ? " column" : " row");
		if (pad[0] || pad[1] || pad[2] || pad[3])
			buffer_addf(buf, " pad %u,%u,%u,%u", pad[0], pad[1], pad[2], pad[3]);
		if (n->gap)
			buffer_addf(buf, " gap %u", n->gap);
		if (n->floating && data.found) {
			Clay_ElementDeclaration declared;
			if (clay_element_declaration(id, &declared)) {
				const Clay_FloatingElementConfig *f = &declared.floating;
				static const char *points[] = { "LEFT_TOP", "LEFT_CENTER", "LEFT_BOTTOM",
					"TOP_CENTER", "CENTER", "BOTTOM_CENTER", "RIGHT_TOP", "RIGHT_CENTER", "RIGHT_BOTTOM" };
				buffer_addf(buf, " attach %s target %08x parent %s own %s pointer %s band %d",
					f->attachTo == CLAY_ATTACH_TO_ELEMENT_WITH_ID ? "ELEMENT" : "PARENT",
					f->parentId, points[f->attachPoints.parent], points[f->attachPoints.element],
					f->pointerCaptureMode == CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH
						? "passthrough" : "capture", f->zIndex);
			}
		}
	}
	if (data.found) {
		Clay_BoundingBox b = dump_box(data.boundingBox);

		buffer_addf(buf, " box %d,%d %dx%d",
			(int)b.x, (int)b.y, (int)b.width, (int)b.height);
		Clay_BoundingBox pbox = render_present_box(host_presentation(host), data.boundingBox);
		if (host_presentation(host).scale != 1)
			buffer_addf(buf, " presented %d,%d %dx%d", (int)pbox.x, (int)pbox.y, (int)pbox.width, (int)pbox.height);
	} else
		buffer_adds(buf, " box -");
	buffer_adds(buf, "\n");
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
dump_axis(buffer_t *buf, Clay_SizingAxis a, uint8_t src)
{
	switch (a.type) {
	case CLAY__SIZING_TYPE_FIXED:
		buffer_addf(buf, "fixed(%g)", a.size.minMax.min);
		break;
	case CLAY__SIZING_TYPE_PERCENT:
		buffer_addf(buf, "percent(%g)", a.size.percent);
		break;
	default:
		buffer_adds(buf, a.type == CLAY__SIZING_TYPE_GROW ? "grow" : "fit");
		if (a.size.minMax.min > 0)
			buffer_addf(buf, ">=%g", a.size.minMax.min);
		if (a.size.minMax.max > 0)
			buffer_addf(buf, "<=%g", a.size.minMax.max);
	}
	dump_word(buf, src);
}

static void dump_presentation(buffer_t *buf, struct render_state *render, uint64_t owner,
		Clay_Color color, Clay_BoundingBox box)
{
	static const char *const anchors[] = {"none", "center", "top", "bottom", "left", "right"};
	struct render_presentation pose = render_carrier_decode(color);
	Clay_BoundingBox presented = render_present_box(render_owner_presentation(render, owner), box);
	buffer_addf(buf, " scale %.6f anchor %s presented %d,%d %dx%d",
		pose.scale, anchors[pose.anchor], (int)presented.x, (int)presented.y,
		(int)presented.width, (int)presented.height);
}

/* One line for a recorded element: its role, the object it stands for,
 * its sizing with where a fixed number came from, its flow, its attachment
 * when it floats, and its box. SHADOW reports the renderer's owner-relative
 * box; other elements report their solved box. Nonzero floating expand
 * follows offset and precedes band. */
static void
dump_record_line(buffer_t *buf, struct declare_band *band,
	struct declare_record *r, int d)
{
	static const char *const attach_names[] = {
		[CLAY_ATTACH_TO_NONE] = "none",
		[CLAY_ATTACH_TO_PARENT] = "PARENT",
		[CLAY_ATTACH_TO_ELEMENT_WITH_ID] = "ELEMENT",
		[CLAY_ATTACH_TO_ROOT] = "ROOT",
	};
	Clay_ElementData data = Clay_GetElementData((Clay_ElementId) { .id = r->id });
	if (!strcmp(r->role, "SHADOW"))
		data.found = render_shadow_box(band->render, r->id, &data.boundingBox);

	buffer_addf(buf, "  %*s%s ", d * 2, "", r->role);
	if (r->screen_index)
		buffer_addf(buf, "%d", r->screen_index);
	else if (r->handle)
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
	/* A surface leaf's or titlebar host's corners from the client's shape. */
	if ((r->has_host ? r->host.radius <= 0 : r->custom)
			&& (r->radius.topLeft > 0 || r->radius.topRight > 0
				|| r->radius.bottomRight > 0 || r->radius.bottomLeft > 0))
		buffer_addf(buf, " radii %g,%g,%g,%g", r->radius.topLeft, r->radius.topRight,
			r->radius.bottomRight, r->radius.bottomLeft);
	if (r->clip)
		buffer_adds(buf, " clip");
	buffer_adds(buf, " w=");
	dump_axis(buf, r->sizing.width, r->src[0]);
	buffer_adds(buf, " h=");
	dump_axis(buf, r->sizing.height, r->src[1]);
	/* OUTPUT keeps its column even when its fill is an image. */
	if ((!r->custom && !r->image) || !strcmp(r->role, "OUTPUT"))
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
	if (r->floating) {
		buffer_addf(buf, " attach %s offset %g,%g", attach, r->offset.x, r->offset.y);
		if (r->expand.width || r->expand.height)
			buffer_addf(buf, " expand %g,%g", r->expand.width, r->expand.height);
		buffer_addf(buf, " band %d", r->band);
	}
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
	Clay_ElementDeclaration declaration;
	if (clay_element_declaration((Clay_ElementId){.id = r->id}, &declaration)
			&& (declaration.transition.properties & CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR)) {
		buffer_addf(buf, " fade_alpha %.6f", declaration.overlayColor.g > 0 ? declaration.overlayColor.a : 0);
		dump_presentation(buf, band->render, r->handle, declaration.overlayColor, data.boundingBox);
	}
	if (data.found) {
		Clay_BoundingBox b = dump_box(data.boundingBox);

		buffer_addf(buf, " box %d,%d %dx%d\n",
			(int)b.x, (int)b.y, (int)b.width, (int)b.height);
	} else
		buffer_adds(buf, " box -\n");
}

/* One line for an element Clay holds that nothing here recorded: the id
 * string it was declared with (the inspector's own rows, for one), its
 * sizing, flow and attachment read from its declaration, and its box. */
static void
dump_clay_line(buffer_t *buf, struct declare_band *band,
	const struct clay_element_view *el, int d)
{
	Clay_ElementData data = Clay_GetElementData((Clay_ElementId) { .id = el->id });

	buffer_addf(buf, "  %*s", d * 2, "");
	if (el->name.length)
		buffer_addf(buf, "%.*s", (int)el->name.length, el->name.chars);
	else
		buffer_adds(buf, "-");
	if (el->text) {
		buffer_addf(buf, " text \"%.*s\" font=%u", (int)el->text_string.length,
			el->text_string.chars, el->font);
	} else {
		const Clay_ElementDeclaration *c = &el->config;
		uint8_t src[2] = { DECLARE_SRC_NONE, DECLARE_SRC_NONE };

		for (size_t i = 0; i < band->words_len; i++)
			if (band->words[i].id == el->id)
				memcpy(src, band->words[i].src, sizeof(src));
		buffer_adds(buf, " w=");
		dump_axis(buf, c->layout.sizing.width,
			numbered(c->layout.sizing.width) ? src[0] : DECLARE_SRC_NONE);
		buffer_adds(buf, " h=");
		dump_axis(buf, c->layout.sizing.height,
			numbered(c->layout.sizing.height) ? src[1] : DECLARE_SRC_NONE);
		buffer_adds(buf, c->layout.layoutDirection == CLAY_TOP_TO_BOTTOM
			? " column" : " row");
		if (c->layout.padding.left || c->layout.padding.right
				|| c->layout.padding.top || c->layout.padding.bottom)
			buffer_addf(buf, " pad %u,%u,%u,%u", c->layout.padding.left,
				c->layout.padding.right, c->layout.padding.top,
				c->layout.padding.bottom);
		if (c->layout.childGap)
			buffer_addf(buf, " gap %u", c->layout.childGap);
		if (el->floating)
			buffer_addf(buf, " attach %s offset %g,%g band %d",
				c->floating.attachTo == CLAY_ATTACH_TO_PARENT ? "PARENT"
				: c->floating.attachTo == CLAY_ATTACH_TO_ROOT ? "ROOT" : "ELEMENT",
				c->floating.offset.x, c->floating.offset.y, c->floating.zIndex);
	}
	if (!el->text && (el->config.transition.properties & CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR)) {
		buffer_addf(buf, " fade_alpha %.6f", el->config.overlayColor.g > 0 ? el->config.overlayColor.a : 0);
		dump_presentation(buf, band->render, declare_userdata_handle(el->config.userData),
			el->config.overlayColor, data.boundingBox);
	}
	if (data.found) {
		Clay_BoundingBox b = dump_box(data.boundingBox);

		buffer_addf(buf, " box %d,%d %dx%d\n",
			(int)b.x, (int)b.y, (int)b.width, (int)b.height);
	} else
		buffer_adds(buf, " box -\n");
}

/* What somewm knows about a Clay element, by id: the record that declared
 * it, or the widget node it was compiled from. Records come first so a
 * host slot that is also its tree's root prints as the record. */
struct dump_ann {
	uint32_t id;
	struct declare_record *record;
	const struct widget_host *host;
	size_t node;
	bool clip;   /* the inner clip element of a decorated host */
};

static struct dump_ann *anns;
static size_t anns_len, anns_cap;

static void
ann_add(uint32_t id, struct declare_record *r, const struct widget_host *host,
	size_t node, bool clip)
{
	if (anns_len == anns_cap) {
		anns_cap = anns_cap ? anns_cap * 2 : 256;
		p_realloc(&anns, anns_cap);
	}
	anns[anns_len++] = (struct dump_ann) {
		.id = id, .record = r, .host = host, .node = node, .clip = clip,
	};
}

static const struct dump_ann *
ann_find(uint32_t id)
{
	for (size_t i = 0; i < anns_len; i++)
		if (anns[i].id == id)
			return &anns[i];
	return NULL;
}

/* The ids a host tree's nodes were declared with, by the same rule the
 * declaration used (widget_child_id). */
static size_t
ann_widget_tree(const struct widget_host *host, size_t i, Clay_ElementId id)
{
	struct widget_tree *d = host->tree;
	size_t next = i + 1;

	ann_add(id.id, NULL, host, i, false);
	for (uint16_t k = 0; k < d->nodes[i].children; k++)
		next = ann_widget_tree(host, next, widget_child_id(d, next, id, k));
	return next;
}

static void
ann_build(struct declare_band *band)
{
	anns_len = 0;
	for (size_t i = 0; i < band->records_len; i++)
		ann_add(band->records[i].id, &band->records[i], NULL, 0, false);
	for (size_t i = 0; i < band->records_len; i++) {
		struct declare_record *r = &band->records[i];
		struct widget_tree *tree;
		Clay_ElementId root_id;

		if (!r->has_host)
			continue;
		tree = r->host.tree;
		root_id = (Clay_ElementId) { .id = tree->root_id };
		if (r->id == root_id.id) {
			size_t next = 1;

			for (uint16_t k = 0; k < tree->nodes[0].children; k++)
				next = ann_widget_tree(&r->host, next,
					widget_child_id(tree, next, root_id, k));
		} else
			ann_widget_tree(&r->host, 0, root_id);
		if (r->host.inner_clip)
			ann_add(inner_clip_id(r->handle).id, NULL, &r->host, 0, true);
	}
}

/* The inner clip element of a decorated host: a widget-style line at the
 * host's widget indentation, with the widget lines under it no deeper. Its
 * sizing is the declaration's, as every other line prints (Clay rewrites an
 * unbounded GROW max after the solve). A percent fills the host box and
 * carries the host's words. */
static void
dump_clip_line(buffer_t *buf, const struct clay_element_view *el,
	const struct widget_host *host, int depth)
{
	Clay_ElementData data = Clay_GetElementData((Clay_ElementId) { .id = el->id });

	buffer_addf(buf, "    %08x %*sclip", el->id, depth * 2, "");
	if (el->config.layout.sizing.width.type == CLAY__SIZING_TYPE_PERCENT) {
		buffer_adds(buf, " w=percent(1)");
		dump_word(buf, host->src[0]);
		buffer_adds(buf, " h=percent(1)");
		dump_word(buf, host->src[1]);
	} else
		buffer_adds(buf, " w=grow h=grow");
	buffer_adds(buf, el->config.layout.layoutDirection == CLAY_TOP_TO_BOTTOM
		? " column" : " row");
	if (data.found) {
		Clay_BoundingBox b = dump_box(data.boundingBox);

		buffer_addf(buf, " box %d,%d %dx%d\n",
			(int)b.x, (int)b.y, (int)b.width, (int)b.height);
	} else
		buffer_adds(buf, " box -\n");
}

/* One element of Clay's tree and, in Clay's child order, the elements
 * under it. A floating element is not among its parent's children
 * (third_party/clay.h:2027-2029); it is a root of its own, so it never
 * prints here under the element it was declared in. A widget line under a
 * recorded host is indented one level less than its Clay depth, so a
 * host's nodes print beside the host's own line, in the shape the widget
 * tests read; a widget tree that is a root of its own starts at zero. */
static void
dump_clay_element(buffer_t *buf, struct declare_band *band, int32_t index,
	int depth, int wdepth)
{
	struct clay_element_view el;
	const struct dump_ann *a;

	clay_element_view(index, &el);
	a = ann_find(el.id);
	if (a && a->record) {
		dump_record_line(buf, band, a->record, depth);
		wdepth = depth;
	} else if (a && a->clip) {
		dump_clip_line(buf, &el, a->host, wdepth);
	} else if (a) {
		dump_widget_line(buf, a->host, a->node,
			(Clay_ElementId) { .id = el.id }, wdepth);
		wdepth++;
	} else {
		dump_clay_line(buf, band, &el, depth);
		wdepth++;
	}
	if (el.text)
		return;
	for (uint16_t k = 0; k < el.children_len; k++)
		dump_clay_element(buf, band, el.children[k], depth + 1, wdepth);
}

/* The tree as Clay holds it after the solve: its roots in the order of
 * the command array the renderer was handed (third_party/clay.h:3434-3461
 * sorts the roots by band and lays their command ranges out in that order),
 * each root's elements under it in Clay's child order. The flow root is
 * the output; every other root is a floating element. The counts come from
 * the same roots; the derived count is somewm's, from the records, since
 * Clay does not know where a number came from. */
static void
count_words(const uint8_t src[2], int *derived, int *legacy)
{
	if (src[0] == DECLARE_SRC_DERIVED || src[1] == DECLARE_SRC_DERIVED)
		(*derived)++;
	if (src[0] == DECLARE_SRC_LEGACY || src[1] == DECLARE_SRC_LEGACY)
		(*legacy)++;
}

static void
dump_tree(buffer_t *buf, struct declare_band *band)
{
	int32_t roots = clay_root_count();
	int flow = 0, floating = 0, derived = 0, legacy = 0;

	for (int32_t i = 0; i < roots; i++) {
		struct clay_element_view el;

		clay_element_view(clay_root_element(i), &el);
		if (el.floating)
			floating++;
		else
			flow++;
	}
	for (size_t i = 0; i < band->records_len; i++) {
		const struct declare_record *r = &band->records[i];
		const struct widget_tree *t = r->has_host ? r->host.tree : NULL;

		count_words(r->src, &derived, &legacy);
		for (size_t j = 0; t && j < i; j++)
			if (band->records[j].has_host && band->records[j].host.tree == t)
				t = NULL;
		for (size_t k = 0; t && k < t->nodes_len; k++)
			count_words(t->nodes[k].src, &derived, &legacy);
	}
	buffer_addf(buf, "  roots flow %d floating %d derived %d legacy %d\n",
		flow, floating, derived, legacy);
	ann_build(band);
	for (int32_t i = 0; i < roots; i++)
		dump_clay_element(buf, band, clay_root_element(i), 0, 0);
}

/* Visible drawins the band shows nothing for, with why (the states in
 * widget.h): a tree that failed to convert is left out of the tree by name,
 * never drawn by a fallback. */
static void
dump_refused(buffer_t *buf, Monitor *m)
{
	foreach(item, globalconf.drawins) {
		drawin_t *d = *item;

		if (!d->visible || !screen_hosted(d->screen, m)
				|| d->widgets.nodes_len > 0)
			continue;
		buffer_addf(buf, "  drawin screen %d %dx%d+%d+%d nothing:",
			d->screen->index, d->width, d->height, d->x, d->y);
		dump_whole(buf, d);
	}
}

static void
dump_band(buffer_t *buf, struct declare_band *band, Monitor *m)
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
	struct clay_capacity capacity = band->context_valid ? clay_capacity() : band->committed_capacity;
	if (!capacity.capacity) capacity.capacity = clay_capacity().capacity;
	buffer_addf(buf, "output %s scale %.2f inspector %s frames %d elements %d/%d map %d free %d inspector_input %d bounds %d/%d\n",
		o->name, o->scale, m->declare->inspector_width ? "on" : "off",
		band->frames, capacity.elements, capacity.capacity, capacity.map, capacity.freeIds,
		band->inspector_authored, band->inspector_elements, band->inspector_strings);
	buffer_addf(buf, "  commands %d mutations %d created %d swept %d nodes %zu "
		"raster_bytes %zu buffers %d batched %d declare %" PRId64 "us solve %" PRId64 "us "
		"reconcile %" PRId64 "us\n",
		band->commands, band->mutations,
		render_nodes_created(band->render), render_nodes_swept(band->render),
		render_node_count(band->render),
		render_raster_bytes(band->render),
		render_buffers_created(band->render),
		render_visibility_batched(band->render),
		band->declare_us, band->solve_us, band->reconcile_us);
	if (band->context_valid) dump_tree(buf, band);
	else if (band->retained_dump) buffer_adds(buf, band->retained_dump);
	dump_refused(buf, m);
	buffer_adds(buf, "  realized:\n");
	render_walk(band->render, &client_hooks, dump_node, buf);
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
		dump_band(&buf, &m->declare->band, m);
	}
	return buffer_detach(&buf);
}
