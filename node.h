#ifndef SOMEWM_NODE_H
#define SOMEWM_NODE_H

#include <stdbool.h>
#include <stdint.h>
#include <wayland-util.h>
#include <wlr/util/box.h>

#include "somewm_types.h"
#include "shadow.h"
#include "widget.h"

typedef struct screen_t screen_t;
typedef struct tag_t tag_t;

enum declare_kind {
	DECLARE_KIND_CLIENT = 1,
	DECLARE_KIND_LAYER,
	DECLARE_KIND_DRAWIN,
	DECLARE_KIND_TITLEBAR,
	/* The object is the Monitor whose wallpaper crop OUTPUT shows. */
	DECLARE_KIND_WALLPAPER,
	/* The object is a wlr_session_lock_surface_v1 (ext-session-lock);
	 * its output's Monitor holds the borrow owner slot. */
	DECLARE_KIND_LOCK,
	/* The lock backdrop, whose object is the output's declare_output. It
	 * draws the opaque cover and it answers the input walk with nothing,
	 * which is what keeps the desktop below it from taking input. */
	DECLARE_KIND_LOCK_BLOCK,
	/* The object is the seat's wlr_drag_icon; its data is the scene tree
	 * wlr_scene_drag_icon_create made for it. */
	DECLARE_KIND_DRAG,
	/* The object is a Popup (window.h): an xdg popup with its own tree. */
	DECLARE_KIND_POPUP,
	/* The pointer image (input.h, cursor_image): the object is the
	 * wlr_cursor for a themed image leaf, or the client's cursor surface
	 * for a borrowed one. It passes every hit through. */
	DECLARE_KIND_CURSOR,
	DECLARE_KIND_SCREEN,
};

enum node_kind {
	NODE_OUTPUT, NODE_SCREEN, NODE_BRANCH, NODE_CLIENT, NODE_WIBOX, NODE_SURFACE
};

/* Bottom to top draw order; declare.c's layer_band maps each name to its band. */
enum node_layer {
	LAYER_INHERIT = 0,
	LAYER_BACKGROUND,
	LAYER_DESKTOP,
	LAYER_WIBOX_DESKTOP,
	LAYER_BOTTOM,
	LAYER_BELOW,
	LAYER_NORMAL,
	LAYER_WIBOX,
	LAYER_ABOVE,
	LAYER_FULLSCREEN,
	LAYER_ONTOP,
	LAYER_BAR_ONTOP,
	LAYER_TOP,
	LAYER_WIBOX_ONTOP,
	LAYER_NOTIFICATION,
	LAYER_OVERLAY,
	LAYER_UNMANAGED,
	LAYER_CURSOR
};

struct node_words {
	uint8_t sizing[2]; /* enum widget_sizing per axis */
	float size[2];
	float min[2];
	float max[2];
	uint16_t pad[4]; /* left, right, top, bottom */
	uint16_t gap;
	bool vertical;
	uint8_t align[2]; /* Clay_LayoutAlignmentX/Y per axis */
	float bg[4];
	uint16_t bw[4];
	float border[4];
	float radius; /* 0 for an unshaped client, -1 for an unshaped drawin */
	float opacity;
	shadow_config_t *shadow; /* owned, NULL selects the theme */
	struct widget_transition transition;
	uint8_t scroll;
};

struct node {
	uint32_t id;
	enum node_kind kind;
	enum node_layer layer;
	struct node *parent;
	struct wl_list link; /* parent->children, tail is top */
	struct wl_list children;
	bool hidden;
	bool protected;
	const char *label; /* owned copy, NULL allowed */
	struct node_words words;
	bool has_box;
	struct wlr_box box;
	struct wlr_box solved; /* layout coordinates, from the last completed solve */
	uint32_t solved_gen;
	enum declare_kind owner_kind;
	void *owner;
	struct node_tree *tree;
};

struct node_tree {
	Monitor *m;
	struct node root;
	bool dirty;
};

static inline uint64_t node_handle(const struct node *n)
{
	return ((uint64_t)n->owner_kind << 32) | n->id;
}

struct node_tree *node_tree_create(Monitor *m);
void node_tree_destroy(struct node_tree *t);
struct node *node_create(struct node_tree *t, enum node_kind kind);
void node_destroy(struct node *n);
struct node *node_by_id(uint32_t id);
bool node_append(struct node *parent, struct node *n);
bool node_push(struct node *parent, struct node *n);
bool node_insert_before(struct node *sibling, struct node *n);
bool node_insert_after(struct node *sibling, struct node *n);
bool node_swap(struct node *a, struct node *b);
bool node_detach(struct node *n);
bool node_join(struct node *n);
bool node_raise(struct node *n);
bool node_lower(struct node *n);
void node_set_label(struct node *n, const char *label);
bool node_check_integrity(const struct node *root);

#ifndef NDEBUG
void node_selftest(void);
#endif

#endif
