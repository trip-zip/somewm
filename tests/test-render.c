/* Unit tests for the Clay reconciler: hand-built command arrays in, wlr_scene
 * out. No compositor and no output; wlr_scene is a plain data structure until
 * something drives an output from it, so the whole reconcile path runs in
 * process. Nothing in the compositor calls the renderer yet, so this is the
 * only thing exercising it. */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wlr/types/wlr_scene.h>

#include "clay.h"
#include "render.h"
#include "render_image.h"
#include "render_text.h"

static int failures;
static const char *current_test;

#define CHECK(cond) do { \
	if (!(cond)) { \
		fprintf(stderr, "%s:%d: %s: FAIL %s\n", __FILE__, __LINE__, \
			current_test, #cond); \
		failures++; \
	} \
} while (0)

#define CHECK_EQ(got, want) do { \
	long long g_ = (long long)(got), w_ = (long long)(want); \
	if (g_ != w_) { \
		fprintf(stderr, "%s:%d: %s: FAIL %s: got %lld, want %lld\n", \
			__FILE__, __LINE__, current_test, #got, g_, w_); \
		failures++; \
	} \
} while (0)

/* --- command builders --- */

static Clay_RenderCommand cmd_rect(uint32_t id, float x, float y, float w,
		float h, float radius) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_RECTANGLE;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.rectangle.backgroundColor = (Clay_Color) { 255, 0, 0, 255 };
	c.renderData.rectangle.cornerRadius =
		(Clay_CornerRadius) { radius, radius, radius, radius };
	return c;
}

static Clay_RenderCommand cmd_border(uint32_t id, float x, float y, float w,
		float h, int width, float radius) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_BORDER;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.border.color = (Clay_Color) { 0, 255, 0, 255 };
	c.renderData.border.width =
		(Clay_BorderWidth) { width, width, width, width, 0 };
	c.renderData.border.cornerRadius =
		(Clay_CornerRadius) { radius, radius, radius, radius };
	return c;
}

static Clay_RenderCommand cmd_text(uint32_t id, float x, float y, float w,
		float h, const char *text, bool ellipsize) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_TEXT;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.text.stringContents = (Clay_StringSlice) {
		.length = (int32_t)strlen(text), .chars = text, .baseChars = text };
	c.renderData.text.textColor = (Clay_Color) { 255, 255, 255, 255 };
	c.renderData.text.fontSize = 12;
	c.userData = ellipsize ? (void *)(uintptr_t)RENDER_TEXT_ELLIPSIZE : NULL;
	return c;
}

static Clay_RenderCommand cmd_image(uint32_t id, float x, float y, float w,
		float h, struct image_entry *entry) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_IMAGE;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.image.imageData = entry;
	return c;
}

static Clay_RenderCommand cmd_custom(uint32_t id, uint64_t handle, float x,
		float y, float w, float h) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_CUSTOM;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.custom.customData = (void *)(uintptr_t)handle;
	return c;
}

static Clay_RenderCommand cmd_clip(uint32_t id, float x, float y, float w,
		float h, bool horizontal, bool vertical) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_SCISSOR_START;
	c.id = id;
	c.boundingBox = (Clay_BoundingBox) { x, y, w, h };
	c.renderData.clip.horizontal = horizontal;
	c.renderData.clip.vertical = vertical;
	return c;
}

static Clay_RenderCommand cmd_clip_end(uint32_t id) {
	Clay_RenderCommand c = { 0 };
	c.commandType = CLAY_RENDER_COMMAND_TYPE_SCISSOR_END;
	c.id = id;
	return c;
}

static Clay_RenderCommandArray commands_of(Clay_RenderCommand *cmds, int32_t n) {
	return (Clay_RenderCommandArray) {
		.capacity = n, .length = n, .internalArray = cmds };
}

/* --- scene inspection ---
 *
 * render_create puts its retained nodes in a tree of its own under the parent
 * it was handed, so the parent's only child is that tree and its children are
 * the retained nodes, bottom to top. */

static struct wlr_scene_tree *render_tree(struct wlr_scene_tree *parent) {
	struct wlr_scene_node *node =
		wl_container_of(parent->children.next, node, link);
	return wlr_scene_tree_from_node(node);
}

static int child_count(struct wlr_scene_tree *tree) {
	return wl_list_length(&tree->children);
}

/* The nth child from the bottom of the draw order, or NULL. */
static struct wlr_scene_node *child_at(struct wlr_scene_tree *tree, int n) {
	struct wlr_scene_node *child;
	int i = 0;
	wl_list_for_each(child, &tree->children, link) {
		if (i++ == n) {
			return child;
		}
	}
	return NULL;
}

/* --- the client hooks fake ---
 *
 * One scene tree per handle, parented to a home tree the way a real client's
 * tree hangs off its layer, so release has somewhere to hand it back to. */

#define FAKE_CLIENTS 4

struct fake_clients {
	struct wlr_scene_tree *home;
	struct wlr_scene_tree *trees[FAKE_CLIENTS];
	bool gone[FAKE_CLIENTS];
	bool popup[FAKE_CLIENTS];
	void *owner[FAKE_CLIENTS];
	int borrows, releases, repositions;
	int configured_w, configured_h, configures;
};

static struct wlr_scene_tree *fake_resolve(void *data, uint64_t handle) {
	struct fake_clients *fc = data;
	return fc->gone[handle] ? NULL : fc->trees[handle];
}

static void fake_configure(void *data, uint64_t handle, int width, int height) {
	struct fake_clients *fc = data;
	(void)handle;
	fc->configured_w = width;
	fc->configured_h = height;
	fc->configures++;
}

static void fake_borrow(void *data, uint64_t handle, void *owner) {
	struct fake_clients *fc = data;
	fc->owner[handle] = owner;
	fc->borrows++;
}

static void fake_release(void *data, uint64_t handle, void *owner) {
	struct fake_clients *fc = data;
	if (fc->owner[handle] != owner) {
		return;   /* not the owner: the migration race, a no-op by contract */
	}
	fc->owner[handle] = NULL;
	fc->releases++;
	if (!fc->gone[handle]) {
		wlr_scene_node_reparent(&fc->trees[handle]->node, fc->home);
		wlr_scene_node_set_enabled(&fc->trees[handle]->node, false);
	}
}

static void fake_reposition(void *data, uint64_t handle) {
	struct fake_clients *fc = data;
	(void)handle;
	fc->repositions++;
}

static bool fake_has_popup(void *data, uint64_t handle) {
	struct fake_clients *fc = data;
	return fc->popup[handle];
}

static void fake_clients_init(struct fake_clients *fc,
		struct wlr_scene_tree *root, struct render_client_hooks *hooks) {
	memset(fc, 0, sizeof(*fc));
	fc->home = wlr_scene_tree_create(root);
	for (int i = 0; i < FAKE_CLIENTS; i++) {
		fc->trees[i] = wlr_scene_tree_create(fc->home);
		wlr_scene_node_set_enabled(&fc->trees[i]->node, false);
	}
	*hooks = (struct render_client_hooks) {
		.resolve = fake_resolve,
		.configure = fake_configure,
		.borrow = fake_borrow,
		.release = fake_release,
		.reposition = fake_reposition,
		.has_popup = fake_has_popup,
		.data = fc,
	};
}

/* For the cases that declare no CUSTOM command. Not a zeroed table: the
 * reconciler calls resolve for every CUSTOM command before anything is
 * borrowed, and marks the node borrowed either way, so the sweep calls release
 * too. Answering NULL degrades a stray CUSTOM command to "client is gone"
 * instead of a NULL call. */
static struct wlr_scene_tree *no_resolve(void *data, uint64_t handle) {
	(void)data; (void)handle;
	return NULL;
}
static void no_release(void *data, uint64_t handle, void *owner) {
	(void)data; (void)handle; (void)owner;
}
static const struct render_client_hooks no_hooks = {
	.resolve = no_resolve,
	.release = no_release,
};

/* --- fixture --- */

struct fixture {
	struct wlr_scene *scene;
	struct wlr_scene_tree *parent;
	struct render_state *rs;
};

static void fixture_init(struct fixture *f) {
	f->scene = wlr_scene_create();
	f->parent = wlr_scene_tree_create(&f->scene->tree);
	f->rs = render_create(f->parent);
}

static void fixture_finish(struct fixture *f,
		const struct render_client_hooks *hooks) {
	render_destroy(f->rs, hooks);
	wlr_scene_node_destroy(&f->scene->tree.node);
}

/* A fixture with clients behind it, for the CUSTOM cases. */
static void fixture_init_clients(struct fixture *f, struct fake_clients *fc,
		struct render_client_hooks *hooks) {
	fixture_init(f);
	fake_clients_init(fc, &f->scene->tree, hooks);
}

/* --- tests --- */

static void test_identical_frame_reconciles_to_zero(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 100, 20, 0),
		cmd_rect(2, 10, 30, 40, 40, 8),
		cmd_border(3, 0, 0, 100, 100, 2, 0),
	};
	Clay_RenderCommandArray arr = commands_of(cmds, 3);

	CHECK(render_reconcile(f.rs, arr, &no_hooks) > 0);
	CHECK_EQ(render_node_count(f.rs), 3);
	CHECK_EQ(render_reconcile(f.rs, arr, &no_hooks), 0);
	CHECK_EQ(render_reconcile(f.rs, arr, &no_hooks), 0);
	/* Nothing re-rastered on the identical frames. */
	CHECK_EQ(render_buffers_created(f.rs), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_add_remove_move(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 100, 20, 0),
		cmd_rect(2, 0, 30, 100, 20, 0),
		cmd_rect(3, 0, 60, 100, 20, 0),
	};
	struct wlr_scene_tree *rt;

	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks);
	rt = render_tree(f.parent);
	CHECK_EQ(child_count(rt), 2);
	CHECK_EQ(render_node_count(f.rs), 2);

	/* Add: the third command creates a node. */
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks);
	CHECK_EQ(child_count(rt), 3);
	CHECK_EQ(render_node_count(f.rs), 3);

	/* Move: one position change, one mutation, no restack. */
	cmds[1].boundingBox.y = 35;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks), 1);
	CHECK_EQ(child_at(rt, 1)->y, 35);

	/* Remove: the vanished id is swept. */
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks) > 0);
	CHECK_EQ(child_count(rt), 2);
	CHECK_EQ(render_node_count(f.rs), 2);

	fixture_finish(&f, &no_hooks);
}

static void test_kind_swap_destroys_and_restacks(void) {
	struct fixture f;
	fixture_init(&f);
	/* The swapping command is FIRST, so a recreated node appended at the top
	 * of the sibling list is in the wrong place unless the swap forces a
	 * restack. With the verifier compiled in, a missed restack aborts here. */
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 50, 50, 0),
		cmd_rect(2, 100, 0, 50, 50, 0),
	};
	struct wlr_scene_tree *rt;

	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks);
	rt = render_tree(f.parent);
	CHECK_EQ(child_at(rt, 0)->type, WLR_SCENE_NODE_RECT);
	CHECK_EQ(child_at(rt, 0)->x, 0);

	/* Square to rounded: a scene rect cannot draw an arc, so the node kind
	 * changes and the old node is destroyed. */
	cmds[0] = cmd_rect(1, 0, 0, 50, 50, 8);
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks) > 0);
	CHECK_EQ(child_count(rt), 2);
	CHECK_EQ(child_at(rt, 0)->type, WLR_SCENE_NODE_BUFFER);
	CHECK_EQ(child_at(rt, 0)->x, 0);
	CHECK_EQ(child_at(rt, 1)->x, 100);

	/* And back, with the frame after each swap settling to zero. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks), 0);
	cmds[0] = cmd_rect(1, 0, 0, 50, 50, 0);
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks) > 0);
	CHECK_EQ(child_at(rt, 0)->type, WLR_SCENE_NODE_RECT);
	CHECK_EQ(child_at(rt, 0)->x, 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_restack_only_when_order_changed(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 10, 10, 0),
		cmd_rect(2, 20, 0, 10, 10, 0),
		cmd_rect(3, 40, 0, 10, 10, 0),
	};
	struct wlr_scene_tree *rt;

	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks);
	rt = render_tree(f.parent);
	CHECK_EQ(child_at(rt, 0)->x, 0);
	CHECK_EQ(child_at(rt, 2)->x, 40);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks), 0);

	/* Same commands, new draw order: the scene follows, and the restack is
	 * the only mutation (one raise per node). */
	Clay_RenderCommand swapped[] = { cmds[2], cmds[0], cmds[1] };
	CHECK_EQ(render_reconcile(f.rs, commands_of(swapped, 3), &no_hooks), 3);
	CHECK_EQ(child_at(rt, 0)->x, 40);
	CHECK_EQ(child_at(rt, 1)->x, 0);
	CHECK_EQ(child_at(rt, 2)->x, 20);

	/* Settled again in the new order. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(swapped, 3), &no_hooks), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_clip_stack(void) {
	struct fixture f;
	fixture_init(&f);
	/* A clip scope, a leaf straddling it, a leaf entirely outside it, a
	 * nested scope, and a leaf after the scope closes. */
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 0, 0, 50, 50, true, true),
		cmd_rect(1, 25, 25, 50, 50, 0),          /* clipped to 25x25 */
		cmd_rect(2, 100, 100, 10, 10, 0),        /* fully outside */
		cmd_clip(11, 0, 0, 30, 100, true, true), /* nested: intersects to 30x50 */
		cmd_rect(3, 20, 20, 40, 40, 0),          /* clipped to 10x30 */
		cmd_clip_end(11),
		cmd_clip_end(10),
		cmd_rect(4, 200, 0, 10, 10, 0),          /* unclipped */
	};
	struct wlr_scene_tree *rt;

	render_reconcile(f.rs, commands_of(cmds, 8), &no_hooks);
	rt = render_tree(f.parent);
	/* SCISSOR commands realize no node. */
	CHECK_EQ(child_count(rt), 4);

	struct wlr_scene_rect *r = wlr_scene_rect_from_node(child_at(rt, 0));
	CHECK_EQ(child_at(rt, 0)->x, 25);
	CHECK_EQ(r->width, 25);
	CHECK_EQ(r->height, 25);

	/* Clipped to nothing: disabled, not drawn at a degenerate size. */
	CHECK(!child_at(rt, 1)->enabled);

	r = wlr_scene_rect_from_node(child_at(rt, 2));
	CHECK_EQ(child_at(rt, 2)->x, 20);
	CHECK_EQ(r->width, 10);
	CHECK_EQ(r->height, 30);

	r = wlr_scene_rect_from_node(child_at(rt, 3));
	CHECK_EQ(child_at(rt, 3)->x, 200);
	CHECK_EQ(r->width, 10);

	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 8), &no_hooks), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_clip_axes(void) {
	/* Naming neither axis means both, not none: Clay emits an unfilled clip
	 * config for a floating element whose clipTo names an ancestor, and its own
	 * hit test clips such a root on both axes. A single named axis leaves the
	 * other one unbounded. */
	static const struct {
		bool horizontal, vertical;
		int want_w, want_h;
	} cases[] = {
		{ false, false, 25, 25 },
		{ true,  false, 25, 50 },
		{ false, true,  50, 25 },
		{ true,  true,  25, 25 },
	};

	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		struct fixture f;
		fixture_init(&f);
		Clay_RenderCommand cmds[] = {
			cmd_clip(10, 0, 0, 50, 50, cases[i].horizontal, cases[i].vertical),
			cmd_rect(1, 25, 25, 50, 50, 0),
			cmd_clip_end(10),
		};
		render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks);
		struct wlr_scene_rect *r =
			wlr_scene_rect_from_node(child_at(render_tree(f.parent), 0));
		CHECK_EQ(r->width, cases[i].want_w);
		CHECK_EQ(r->height, cases[i].want_h);
		fixture_finish(&f, &no_hooks);
	}
}

static void test_client_surface_hooks(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	Clay_RenderCommand cmds[] = {
		cmd_custom(1, 0, 0, 0, 400, 300),
		cmd_custom(2, 1, 400, 0, 400, 300),
	};

	render_reconcile(f.rs, commands_of(cmds, 2), &hooks);
	struct wlr_scene_tree *rt = render_tree(f.parent);
	/* Borrowed, not owned: the client's own tree is reparented in. */
	CHECK_EQ(child_count(rt), 2);
	CHECK_EQ(child_at(rt, 0), &fc.trees[0]->node);
	CHECK_EQ(child_at(rt, 1), &fc.trees[1]->node);
	CHECK(child_at(rt, 0)->enabled);
	CHECK_EQ(fc.borrows, 2);
	CHECK_EQ(fc.configures, 2);
	CHECK_EQ(fc.configured_w, 400);
	CHECK_EQ(fc.configured_h, 300);
	/* Both placements fire reposition; the borrow's configure ran before the
	 * position existed. */
	CHECK_EQ(fc.repositions, 2);

	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &hooks), 0);
	CHECK_EQ(fc.repositions, 2);

	/* A move re-derives anything keyed to the tree's scene position. */
	cmds[1].boundingBox.x = 500;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks);
	CHECK_EQ(fc.repositions, 3);
	CHECK_EQ(fc.trees[1]->node.x, 500);

	/* A resize configures, without a reposition. */
	cmds[1].boundingBox.width = 300;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks);
	CHECK_EQ(fc.configures, 3);
	CHECK_EQ(fc.configured_w, 300);
	CHECK_EQ(fc.repositions, 3);

	/* Undeclared: the sweep hands the tree back, disabled, at home. */
	render_reconcile(f.rs, commands_of(cmds, 1), &hooks);
	CHECK_EQ(fc.releases, 1);
	CHECK_EQ(child_count(rt), 1);
	CHECK(!fc.trees[1]->node.enabled);
	CHECK_EQ(fc.trees[1]->node.parent, fc.home);

	/* A client that died between declare and reconcile realizes no node. */
	fc.gone[1] = true;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks);
	CHECK_EQ(child_count(rt), 1);

	fixture_finish(&f, &hooks);
}

static void test_popup_owner_folds_to_top(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	Clay_RenderCommand cmds[] = {
		cmd_custom(1, 0, 0, 0, 400, 300),
		cmd_custom(2, 1, 400, 0, 400, 300),
	};
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks);
	struct wlr_scene_tree *rt = render_tree(f.parent);
	CHECK_EQ(child_at(rt, 0), &fc.trees[0]->node);

	/* The lower client opens a popup that may overhang its neighbor, so it is
	 * folded to the top of the draw order. */
	fc.popup[0] = true;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &hooks) > 0);
	CHECK_EQ(child_at(rt, 0), &fc.trees[1]->node);
	CHECK_EQ(child_at(rt, 1), &fc.trees[0]->node);

	/* A steadily-open popup yields the identical order every frame. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &hooks), 0);

	fc.popup[0] = false;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &hooks) > 0);
	CHECK_EQ(child_at(rt, 0), &fc.trees[0]->node);

	fixture_finish(&f, &hooks);
}

static void test_custom_is_never_clipped(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	/* A client subtree is exempt from the clip stack, so a popup that overhangs
	 * its tile is not cropped. */
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 0, 0, 50, 50, true, true),
		cmd_custom(1, 0, 25, 25, 400, 300),
		cmd_clip_end(10),
	};
	render_reconcile(f.rs, commands_of(cmds, 3), &hooks);
	CHECK_EQ(fc.trees[0]->node.x, 25);
	CHECK(fc.trees[0]->node.enabled);
	CHECK_EQ(fc.configured_w, 400);
	CHECK_EQ(fc.configured_h, 300);

	fixture_finish(&f, &hooks);
}

static void test_float_boxes_truncate(void) {
	struct fixture f;
	fixture_init(&f);
	/* Clay solves in float32, and the reconciler truncates at the scene
	 * boundary. Anything that wants pixel parity with somewm's integer
	 * geometry has to round before it declares, not after. */
	Clay_RenderCommand cmds[] = { cmd_rect(1, 10.6f, 20.4f, 30.7f, 40.2f, 0) };
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks);
	struct wlr_scene_tree *rt = render_tree(f.parent);
	struct wlr_scene_rect *r = wlr_scene_rect_from_node(child_at(rt, 0));
	CHECK_EQ(child_at(rt, 0)->x, 10);
	CHECK_EQ(child_at(rt, 0)->y, 20);
	CHECK_EQ(r->width, 30);
	CHECK_EQ(r->height, 40);

	/* A sub-pixel drift that truncates to the same integers is not a change. */
	cmds[0].boundingBox.x = 10.9f;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_text_rasters_once_per_change(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = { cmd_text(1, 0, 0, 80, 16, "hello", false) };

	CHECK(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks) > 0);
	struct wlr_scene_tree *rt = render_tree(f.parent);
	CHECK_EQ(child_count(rt), 1);
	CHECK_EQ(child_at(rt, 0)->type, WLR_SCENE_NODE_BUFFER);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 0);

	/* New content re-rasters, and nothing else moves. */
	cmds[0] = cmd_text(1, 0, 0, 80, 16, "goodbye", false);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 1);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 0);

	/* A style change with the same string re-rasters too. */
	cmds[0].renderData.text.textColor = (Clay_Color) { 0, 0, 0, 255 };
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 1);

	/* An empty run: a real case (a label with nothing in it), and the one that
	 * puts NULL through the content compare, which UBSan rejects. */
	cmds[0] = cmd_text(2, 0, 0, 80, 16, "", false);
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_text_crops_to_its_clip(void) {
	struct fixture f;
	fixture_init(&f);
	/* The run is wider than the clip, so it crops. Its own box never moves, so
	 * only the clip can tell the raster where to truncate. */
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 0, 0, 40, 16, true, true),
		cmd_text(1, 0, 0, 80, 16, "a long enough run", true),
		cmd_clip_end(10),
	};
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks);
	struct wlr_scene_tree *rt = render_tree(f.parent);
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(child_at(rt, 0));
	CHECK_EQ(child_at(rt, 0)->x, 0);
	CHECK_EQ(sb->dst_width, 40);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks), 0);

	/* Narrowing the clip re-rasters at the tighter bound. */
	cmds[0].boundingBox.width = 20;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks) > 0);
	CHECK_EQ(sb->dst_width, 20);

	fixture_finish(&f, &no_hooks);
}

/* A decoded entry built by hand, so the image path is testable without going
 * through a file. The cache produces exactly this shape. */
static void fake_image_entry(struct image_entry *e, int w, int h) {
	memset(e, 0, sizeof(*e));
	e->path = NULL;
	e->native = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
	e->width = w;
	e->height = h;
	e->decoded = true;
	e->gen = 1;
}

static void test_image_rerasters_on_generation_bump(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry;
	fake_image_entry(&entry, 4, 4);
	Clay_RenderCommand cmds[] = { cmd_image(1, 0, 0, 32, 32, &entry) };

	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	CHECK(render_raster_bytes(f.rs) > 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);

	/* The entry pointer never changes across a reload, so gen is what tells the
	 * renderer the pixels are new. */
	entry.gen++;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks), 1);
	CHECK_EQ(render_buffers_created(f.rs), 1);

	fixture_finish(&f, &no_hooks);
	cairo_surface_destroy(entry.native);

	/* An entry that never decoded draws nothing at all. */
	struct image_entry failed = { .decoded = true, .failed = true };
	Clay_RenderCommand miss[] = { cmd_image(2, 0, 0, 32, 32, &failed) };
	struct fixture g;
	fixture_init(&g);
	render_reconcile(g.rs, commands_of(miss, 1), &no_hooks);
	CHECK_EQ(child_count(render_tree(g.parent)), 1);
	CHECK_EQ(render_buffers_created(g.rs), 0);
	CHECK_EQ(render_raster_bytes(g.rs), 0);
	fixture_finish(&g, &no_hooks);
}

static void test_image_cache_rejects_bad_messages(void) {
	struct image_cache *ic = image_cache_create();
	uint8_t pixels[4 * 4 * 4] = { 0 };

	/* A message whose own numbers do not describe the buffer it sent. */
	CHECK(!image_cache_put(ic, "k", 4, 4, 16, true, 8, 4, pixels, 16));
	CHECK(!image_cache_put(ic, "k", 4, 4, 16, true, 8, 3, pixels, sizeof(pixels)));
	CHECK(!image_cache_put(ic, "k", 4, 4, 4, true, 8, 4, pixels, sizeof(pixels)));
	CHECK(!image_cache_put(ic, "k", 0, 4, 16, true, 8, 4, pixels, sizeof(pixels)));
	CHECK(!image_cache_put(ic, "k", 4, 4, 16, true, 16, 4, pixels, sizeof(pixels)));
	/* width * channels overflows int to a negative here, so a rowstride far too
	 * short for the claimed row passes a 32-bit comparison. */
	CHECK(!image_cache_put(ic, "k", 1 << 29, 4, 16, true, 8, 4, pixels,
		sizeof(pixels)));
	CHECK(!image_cache_put(ic, "k", 4, 4, -1, true, 8, 4, pixels, sizeof(pixels)));
	CHECK_EQ(image_cache_bytes(ic), 0);

	CHECK(image_cache_put(ic, "k", 4, 4, 16, true, 8, 4, pixels, sizeof(pixels)));
	CHECK(image_cache_bytes(ic) > 0);

	image_cache_destroy(ic);
}

static void test_image_cache_evicts_least_recently_declared(void) {
	setenv("SOMEWM_IMAGE_BUDGET_MB", "1", 1);
	struct image_cache *ic = image_cache_create();
	unsetenv("SOMEWM_IMAGE_BUDGET_MB");

	/* Over a megabyte each, so two of them do not fit the budget. */
	const int side = 600;
	uint8_t *pixels = calloc((size_t)side * side, 4);

	image_cache_begin_declare(ic);
	CHECK(image_cache_put(ic, "a", side, side, side * 4, true, 8, 4,
		pixels, (size_t)side * side * 4));
	size_t one = image_cache_bytes(ic);
	CHECK(one > (size_t)1 << 20);

	/* The budget yields to the live set: everything resident was declared by
	 * this solve, so there is nothing evictable. */
	image_cache_sweep(ic);
	CHECK_EQ(image_cache_bytes(ic), one);

	/* Next solve: "a" was not declared again, so it is the one that goes. */
	image_cache_begin_declare(ic);
	CHECK(image_cache_put(ic, "b", side, side, side * 4, true, 8, 4,
		pixels, (size_t)side * side * 4));
	CHECK_EQ(image_cache_bytes(ic), one);

	free(pixels);
	image_cache_destroy(ic);
}

static void test_font_interning(void) {
	/* Entry 0 is the fallback face, and Clay's debug view writes fontId 0
	 * without interning anything. */
	CHECK_EQ(render_font_intern("Sans"), 0);
	int32_t mono = render_font_intern("Monospace");
	CHECK(mono > 0);
	/* Write-once: the same description resolves to the same id. */
	CHECK_EQ(render_font_intern("Monospace"), mono);

	/* A description carrying a size is refused, because size is its own
	 * channel and would be silently overridden. */
	CHECK_EQ(render_font_intern("Monospace 12"), RENDER_FONT_ERR_SIZE);
	/* Pango's parser is what decides: it reads a trailing number as a size, and
	 * a family whose name ends in a digit with no space before it as a family. */
	CHECK(render_font_intern("M+ 1c") > 0);
}

static void test_measure_is_monotonic(void) {
	/* Font availability is the system's, so the only claims here are the ones
	 * that hold with any face, including none at all. */
	render_text_set_measure_scale(1.0f);
	Clay_TextElementConfig config = { .fontId = 0, .fontSize = 12 };
	Clay_StringSlice empty = { .length = 0, .chars = "", .baseChars = "" };
	Clay_StringSlice run = { .length = 5, .chars = "hello", .baseChars = "hello" };

	Clay_Dimensions d_empty = render_measure_text(empty, &config, NULL);
	Clay_Dimensions d_run = render_measure_text(run, &config, NULL);
	CHECK_EQ(d_empty.width, 0);
	CHECK(d_run.width >= d_empty.width);
	/* Same input, same answer: the measure callback is pure. */
	CHECK_EQ(render_measure_text(run, &config, NULL).width, d_run.width);
}

/* The verifier aborts the process, so the divergence runs in a child. */
/* Every box a border draws, whether it is an edge rect or a corner tile. */
static int ring_cover(struct wlr_scene_tree *bt, int px, int py) {
	int n = 0;
	struct wlr_scene_node *child;
	wl_list_for_each(child, &bt->children, link) {
		if (!child->enabled) {
			continue;
		}
		int w, h;
		if (child->type == WLR_SCENE_NODE_RECT) {
			struct wlr_scene_rect *r = wlr_scene_rect_from_node(child);
			w = r->width;
			h = r->height;
		} else {
			struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(child);
			w = b->dst_width;
			h = b->dst_height;
		}
		if (px >= child->x && px < child->x + w &&
				py >= child->y && py < child->y + h) {
			n++;
		}
	}
	return n;
}

/* The four edges and the corner tiles must partition the border frame: every
 * pixel of it drawn, and no pixel drawn twice (the border color can be
 * translucent, so a double-draw shows as plainly as a hole). The case that
 * fails when the edges are inset by the radius on one axis and the border width
 * on the other is 0 < radius < width: nothing then draws the band between them
 * at any corner. */
static void test_border_ring_has_no_gap_or_overlap(void) {
	static const struct { int width, radius; } cases[] = {
		{ 5, 0 }, { 5, 3 }, { 5, 5 }, { 5, 10 }, { 2, 8 }, { 8, 1 },
	};
	const int size = 100;
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		struct fixture f;
		fixture_init(&f);
		int bw = cases[i].width;
		Clay_RenderCommand c = cmd_border(1, 0, 0, (float)size, (float)size,
			bw, (float)cases[i].radius);
		render_reconcile(f.rs, commands_of(&c, 1), &no_hooks);
		struct wlr_scene_tree *bt =
			wlr_scene_tree_from_node(child_at(render_tree(f.parent), 0));

		int gaps = 0, overlaps = 0;
		for (int y = 0; y < size; y++) {
			for (int x = 0; x < size; x++) {
				bool frame = x < bw || y < bw ||
					x >= size - bw || y >= size - bw;
				int n = ring_cover(bt, x, y);
				if (frame && n == 0) {
					gaps++;
				}
				if (n > 1) {
					overlaps++;
				}
			}
		}
		if (gaps != 0 || overlaps != 0) {
			fprintf(stderr, "  width %d radius %d: %d gap px, %d overlap px\n",
				bw, cases[i].radius, gaps, overlaps);
		}
		CHECK_EQ(gaps, 0);
		CHECK_EQ(overlaps, 0);
		fixture_finish(&f, &no_hooks);
	}
}

/* A clipped raster is a crop of the full-box buffer, so the crop has to be
 * expressed on the grid that buffer was sized on: device_len from the truncated
 * logical origin. Reading the crop origin off the unrounded box.x instead moves
 * the whole raster by a pixel whenever the solved origin is fractional. */
static void test_clip_source_matches_the_buffer_grid(void) {
	struct fixture f;
	fixture_init(&f);
	/* The buffer spans logical [10, 50); the clip starts at 15, its 5th column.
	 * Rounding 10.6 to 11 instead would call it the 4th. */
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 15, 0, 100, 20, true, true),
		cmd_rect(1, 10.6f, 0, 40, 20, 4),
		cmd_clip_end(10),
	};
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks);
	struct wlr_scene_node *node = child_at(render_tree(f.parent), 0);
	struct wlr_scene_buffer *sb = wlr_scene_buffer_from_node(node);
	CHECK_EQ(node->x, 15);
	CHECK_EQ((int)sb->src_box.x, 5);
	CHECK_EQ((int)sb->src_box.width, 35);
	CHECK_EQ(sb->dst_width, 35);
	fixture_finish(&f, &no_hooks);
}

static void test_verifier_catches_divergence(void) {
#ifndef SOMEWM_RENDER_VERIFY
	fprintf(stderr, "skipped: built without SOMEWM_RENDER_VERIFY\n");
	return;
#else
	pid_t pid = fork();
	CHECK(pid >= 0);
	if (pid == 0) {
		/* The abort's own diagnostic is the expected output here, not a
		 * failure to report. */
		freopen("/dev/null", "w", stderr);
		struct fixture f;
		fixture_init(&f);
		Clay_RenderCommand cmds[] = { cmd_rect(1, 0, 0, 10, 10, 0) };
		render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks);
		/* Move the node behind the reconciler's back. The next pass sees an
		 * unchanged command, so nothing repositions it and the scene no longer
		 * agrees with the tree. */
		wlr_scene_node_set_position(child_at(render_tree(f.parent), 0), 999, 999);
		render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks);
		_exit(0);   /* reached only if the verifier let the divergence stand */
	}
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid);
	CHECK(WIFSIGNALED(status));
	CHECK_EQ(WTERMSIG(status), SIGABRT);
#endif
}

int main(void) {
	static const struct {
		const char *name;
		void (*fn)(void);
	} tests[] = {
		{ "identical frame reconciles to zero", test_identical_frame_reconciles_to_zero },
		{ "add, remove and move", test_add_remove_move },
		{ "kind swap destroys and restacks", test_kind_swap_destroys_and_restacks },
		{ "restack only when order changed", test_restack_only_when_order_changed },
		{ "clip stack", test_clip_stack },
		{ "clip axes", test_clip_axes },
		{ "client surface hooks", test_client_surface_hooks },
		{ "popup owner folds to top", test_popup_owner_folds_to_top },
		{ "custom is never clipped", test_custom_is_never_clipped },
		{ "float boxes truncate", test_float_boxes_truncate },
		{ "text rasters once per change", test_text_rasters_once_per_change },
		{ "text crops to its clip", test_text_crops_to_its_clip },
		{ "image rerasters on generation bump", test_image_rerasters_on_generation_bump },
		{ "image cache rejects bad messages", test_image_cache_rejects_bad_messages },
		{ "image cache evicts least recently declared", test_image_cache_evicts_least_recently_declared },
		{ "font interning", test_font_interning },
		{ "measure is monotonic", test_measure_is_monotonic },
		{ "border ring has no gap or overlap", test_border_ring_has_no_gap_or_overlap },
		{ "clip source matches the buffer grid", test_clip_source_matches_the_buffer_grid },
		{ "verifier catches divergence", test_verifier_catches_divergence },
	};

	for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		current_test = tests[i].name;
		int before = failures;
		tests[i].fn();
		printf("%s %s\n", failures == before ? "ok  " : "FAIL", tests[i].name);
	}
	render_text_finish();
	if (failures > 0) {
		fprintf(stderr, "%d check(s) failed\n", failures);
	}
	return failures > 0 ? 1 : 0;
}
