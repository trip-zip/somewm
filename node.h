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

enum node_kind {
	NODE_OUTPUT, NODE_SCREEN, NODE_BRANCH, NODE_CLIENT, NODE_WIBOX, NODE_SURFACE
};

enum node_layer {
	LAYER_INHERIT = 0,
	LAYER_DESKTOP,
	LAYER_BELOW,
	LAYER_NORMAL,
	LAYER_ABOVE,
	LAYER_FULLSCREEN,
	LAYER_ONTOP,
	LAYER_BACKGROUND,
	LAYER_BOTTOM,
	LAYER_TOP,
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
	float radius;
	float opacity;
	shadow_config_t *shadow;
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
	bool mounted;
	bool hidden;
	bool protected;
	const char *label; /* owned copy, NULL allowed */
	struct node_words words;
	bool has_box;
	struct wlr_box box;
	struct wlr_box solved;
	union {
		screen_t *screen;
		tag_t *tag;
		client_t *client;
		drawin_t *drawin;
		struct wlr_surface *surface;
	} owner;
	struct node_tree *tree;
};

struct node_tree {
	Monitor *m;
	struct node root;
	bool dirty;
};

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
