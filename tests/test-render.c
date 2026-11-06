#include <librsvg/rsvg.h>
/* Unit tests for the Clay reconciler: hand-built commands, retained views,
 * rasters and hits. No compositor or output is needed. */

#include <assert.h>
#include <math.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include "paint.h"
#include "paint_context.h"
static struct paint *test_painter;

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

/* The userData word (render.h): the declarer's owner bits, the clip scope a
 * RECTANGLE opens, and the scope the command is clipped by. */
static void *word(uint64_t owner, unsigned opens, unsigned clipped_by) {
	return (void *)(uintptr_t)(owner
		| (uint64_t)opens << RENDER_UD_OPENS_SHIFT
		| (uint64_t)clipped_by << RENDER_UD_CLIP_SHIFT);
}

/* Frame bounds for the cases that name none. */
static const Clay_BoundingBox no_bounds = { 0, 0, 4096, 4096 };

/* Fake roots are opaque tokens. The surface hook tests never draw them. */

#define FAKE_CLIENTS 4

struct fake_clients {
	bool gone[FAKE_CLIENTS];
	void *owner[FAKE_CLIENTS];
	int borrows, releases, repositions;
	int configured_w, configured_h, configures;
	int clip_x, clip_y, clip_w, clip_h, clips;
	struct render_surface_origin origins[FAKE_CLIENTS];
	float radii[4];
	int corners;
};

static struct wlr_surface *fake_resolve(void *data, uint64_t handle) {
	struct fake_clients *fc = data;
	return fc->gone[handle] ? NULL : (struct wlr_surface *)(uintptr_t)(handle + 1);
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

static bool fake_release(void *data, uint64_t handle, void *owner) {
	struct fake_clients *fc = data;
	if (fc->owner[handle] != owner) {
		return false;   /* not the owner: the migration race, a no-op by contract */
	}
	fc->owner[handle] = NULL;
	fc->releases++;
	/* The renderer parks the tree itself, unless the client is gone. */
	return !fc->gone[handle];
}

static void fake_reposition(void *data, uint64_t handle, int x, int y) {
	struct fake_clients *fc = data;
	(void)handle; (void)x; (void)y;
	fc->repositions++;
}

static void fake_clip(void *data, uint64_t handle, int x, int y, int width, int height) {
	struct fake_clients *fc = data;
	(void)handle;
	fc->clip_x = x;
	fc->clip_y = y;
	fc->clip_w = width;
	fc->clip_h = height;
	fc->clips++;
}

static struct render_surface_origin fake_surface_origin(void *data, uint64_t handle) {
	struct fake_clients *fc = data;
	return fc->origins[handle];
}

static void fake_corners(void *data, uint64_t handle, const float radii[4]) {
	struct fake_clients *fc = data;
	(void)handle;
	memcpy(fc->radii, radii, sizeof(fc->radii));
	fc->corners++;
}

static void fake_clients_init(struct fake_clients *fc,
		struct render_client_hooks *hooks) {
	memset(fc, 0, sizeof(*fc));
	*hooks = (struct render_client_hooks) {
		.resolve = fake_resolve,
		.configure = fake_configure,
		.borrow = fake_borrow,
		.release = fake_release,
		.reposition = fake_reposition,
		.clip = fake_clip,
		.surface_origin = fake_surface_origin,
		.corners = fake_corners,
		.data = fc,
	};
}

/* For the cases that declare no CUSTOM command. Not a zeroed table: the
 * reconciler calls resolve for every CUSTOM command before anything is
 * borrowed, and marks the node borrowed either way, so the sweep calls release
 * too. Answering NULL degrades a stray CUSTOM command to "client is gone"
 * instead of a NULL call. */
static struct wlr_surface *no_resolve(void *data, uint64_t handle) {
	(void)data; (void)handle;
	return NULL;
}
static bool no_release(void *data, uint64_t handle, void *owner) {
	(void)data; (void)handle; (void)owner;
	return false;
}
static const struct render_client_hooks no_hooks = {
	.resolve = no_resolve,
	.release = no_release,
};

/* --- fixture --- */

struct fixture {
	struct render_state *rs;
	const struct render_client_hooks *hooks;
};

static void fixture_init(struct fixture *f) {
	f->rs = render_create();
	render_set_paint(f->rs, test_painter, 1);
	f->hooks = &no_hooks;
}

static void fixture_finish(struct fixture *f,
		const struct render_client_hooks *hooks) {
	render_destroy(f->rs, hooks);
}

/* A fixture with clients behind it, for the CUSTOM cases. */
static void fixture_init_clients(struct fixture *f, struct fake_clients *fc,
		struct render_client_hooks *hooks) {
	fixture_init(f);
	fake_clients_init(fc, hooks);
	f->hooks = hooks;
}

struct view_list {
	struct render_node_view nodes[512];
	size_t count;
};

static void collect_view(void *user, const struct render_node_view *view) {
	struct view_list *list = user;
	if ((!view->has_node && view->borrowed)
            || view->type == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START
            || view->type == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END
            || view->type == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START
            || view->type == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END) return;
	assert(list->count < sizeof(list->nodes) / sizeof(list->nodes[0]));
	list->nodes[list->count++] = *view;
}

static struct render_node_view view_at(struct fixture *f, size_t index) {
	struct view_list list = {0};
	render_walk(f->rs, f->hooks, collect_view, &list);
	CHECK(index < list.count);
	return index < list.count ? list.nodes[index] : (struct render_node_view){0};
}

static size_t view_count(struct fixture *f) {
	struct view_list list = {0};
	render_walk(f->rs, f->hooks, collect_view, &list);
	return list.count;
}

static bool accept_clip_child(void *user, const struct render_node_view *v,
		double sx, double sy) {
	return v->id == *(uint32_t *)user;
}

static void test_identical_frame_reconciles_to_zero(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 100, 20, 0),
		cmd_rect(2, 10, 30, 40, 40, 8),
		cmd_border(3, 0, 0, 100, 100, 2, 0),
	};
	Clay_RenderCommandArray arr = commands_of(cmds, 3);

	CHECK(render_reconcile(f.rs, arr, &no_hooks, no_bounds) > 0);
	CHECK_EQ(render_node_count(f.rs), 3);
	CHECK_EQ(render_reconcile(f.rs, arr, &no_hooks, no_bounds), 0);
	CHECK_EQ(render_reconcile(f.rs, arr, &no_hooks, no_bounds), 0);
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

	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&f), 2);
	CHECK_EQ(render_node_count(f.rs), 2);

	/* Add: the third command creates a node. */
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&f), 3);
	CHECK_EQ(render_node_count(f.rs), 3);

	/* Move: one position change, one mutation, no restack. */
	cmds[1].boundingBox.y = 35;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds), 1);
	CHECK_EQ(view_at(&f, 1).rbox.y, 35);

	/* Remove: the vanished id is swept. */
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds) > 0);
	CHECK_EQ(view_count(&f), 2);
	CHECK_EQ(render_node_count(f.rs), 2);

	fixture_finish(&f, &no_hooks);
}

/* Elements 1 to 3 are in the tree; 2 leaves when gone_2 is set. */
static bool gone_2;
static bool declared_1_to_3(void *data, uint32_t id) {
	(void)data;
	return id >= 1 && id <= 3 && !(id == 2 && gone_2);
}

static void test_retained_node_returns(void) {
	struct fixture f;
	fixture_init(&f);
	struct render_client_hooks hooks = no_hooks;
	hooks.declared = declared_1_to_3;
	gone_2 = false;
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 100, 20, 0),
		cmd_rect(2, 0, 30, 100, 20, 0),
		cmd_rect(3, 0, 60, 100, 20, 0),
	};
	Clay_RenderCommand without[] = { cmds[0], cmds[2] };

	render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);

	/* One record loses its draw. The next record changes draw position. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(without, 2), &hooks, no_bounds), 2);
	CHECK_EQ(render_node_count(f.rs), 3);
	CHECK_EQ(view_count(&f), 2);
	CHECK_EQ(view_at(&f, 1).id, 3);
	CHECK_EQ(render_nodes_swept(f.rs), 1);
	CHECK_EQ(render_reconcile(f.rs, commands_of(without, 2), &hooks, no_bounds), 0);

	/* The retained record gains a draw. The next record changes position. */
	cmds[1].renderData.rectangle.backgroundColor = (Clay_Color) { 0, 255, 0, 255 };
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds), 2);
	CHECK_EQ(render_nodes_created(f.rs), 1);
	CHECK_EQ(view_count(&f), 3);
	CHECK_EQ(view_at(&f, 1).id, 2);
	CHECK(view_at(&f, 1).shown);
	CHECK_EQ(view_at(&f, 1).color.r, 0);
	CHECK_EQ(view_at(&f, 1).color.g, 255);
	CHECK_EQ(view_at(&f, 1).color.a, 255);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds), 0);

	/* Removing an already hidden record loses no draw. */
	render_reconcile(f.rs, commands_of(without, 2), &hooks, no_bounds);
	gone_2 = true;
	render_reconcile(f.rs, commands_of(without, 2), &hooks, no_bounds);
	CHECK_EQ(render_nodes_swept(f.rs), 0);
	CHECK_EQ(render_node_count(f.rs), 2);
	CHECK_EQ(view_count(&f), 2);

	fixture_finish(&f, &hooks);
}

static void test_radius_toggle_keeps_the_node(void) {
	struct fixture f;
	fixture_init(&f);
	/* Check ordered ids and allocation counters across both radius changes. */
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 50, 50, 0),
		cmd_rect(2, 100, 0, 50, 50, 0),
	};
	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	CHECK(view_at(&f, 0).pixels == NULL);

	/* Square to rounded: the same rect with the radii on it; nothing is
	 * created, swept, rastered or restacked. */
	cmds[0] = cmd_rect(1, 0, 0, 50, 50, 8);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 1);
	CHECK_EQ(view_at(&f, 0).id, 1);
	CHECK_EQ(render_nodes_created(f.rs), 0);
	CHECK_EQ(render_nodes_swept(f.rs), 0);
	CHECK_EQ(view_at(&f, 1).rbox.x, 100);
	CHECK_EQ(view_at(&f, 0).radii.topLeft, 8);
	CHECK_EQ(render_nodes_created(f.rs), 0);
	CHECK_EQ(render_nodes_swept(f.rs), 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);

	/* And back. */
	cmds[0] = cmd_rect(1, 0, 0, 50, 50, 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 1);
	CHECK_EQ(view_at(&f, 0).id, 1);
	CHECK_EQ(render_nodes_created(f.rs), 0);
	CHECK_EQ(render_nodes_swept(f.rs), 0);
	CHECK_EQ(view_at(&f, 0).radii.topLeft, 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);

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

	render_reconcile(f.rs, commands_of(cmds, 8), &no_hooks, no_bounds);
	/* SCISSOR commands realize no node. */
	CHECK_EQ(view_count(&f), 4);

	CHECK_EQ(view_at(&f, 0).rbox.x, 25);
	CHECK_EQ(view_at(&f, 0).rbox.width, 25);
	CHECK_EQ(view_at(&f, 0).rbox.height, 25);

	/* Clipped to nothing: disabled, not drawn at a degenerate size. */
	CHECK(!view_at(&f, 1).shown);

	CHECK_EQ(view_at(&f, 2).rbox.x, 20);
	CHECK_EQ(view_at(&f, 2).rbox.width, 10);
	CHECK_EQ(view_at(&f, 2).rbox.height, 30);

	CHECK_EQ(view_at(&f, 3).rbox.x, 200);
	CHECK_EQ(view_at(&f, 3).rbox.width, 10);

	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 8), &no_hooks, no_bounds), 0);

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
		render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
		CHECK_EQ(view_at(&f, 0).rbox.width, cases[i].want_w);
		CHECK_EQ(view_at(&f, 0).rbox.height, cases[i].want_h);
		fixture_finish(&f, &no_hooks);
	}
}

static void test_opacity_from_the_word(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(1, 0, 0, 20, 20, 0),
		cmd_rect(2, 20, 0, 20, 20, 4),
		cmd_border(3, 40, 0, 20, 20, 2, 0),
		cmd_text(4, 60, 0, 20, 20, "hi", false),
	};
	for (unsigned byte = 128; byte <= 255; byte += 127) {
		for (int i = 0; i < 4; i++)
			cmds[i].userData = (void *)((uintptr_t)word(7, 0, 0)
				| (uint64_t)byte << RENDER_UD_OPACITY_SHIFT);
		CHECK(render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds) > 0);
		float opacity = byte == 128 ? 0.5f : 1.0f;
		CHECK_EQ(view_at(&f, 0).color.r, 255);
		CHECK_EQ(view_at(&f, 0).color.g, 0);
		CHECK_EQ(view_at(&f, 0).color.a, 255);
		for (int i = 0; i < 4; i++) CHECK(view_at(&f, i).opacity == opacity);
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds), 0);
		cmds[2].renderData.border.cornerRadius = (Clay_CornerRadius){4,4,4,4};
		CHECK(render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds) > 0);
		CHECK_EQ(view_count(&f), 4);
		CHECK(view_at(&f, 2).opacity == opacity);
		CHECK_EQ(render_buffers_created(f.rs), 0);
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds), 0);
		cmds[2].renderData.border.cornerRadius = (Clay_CornerRadius){0};
		render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds);
		cmds[2].id++;
		render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds);
	}
	fixture_finish(&f, &no_hooks);
}

static void test_full_clip_budget(void) {
    struct fixture f;
    fixture_init(&f);
    Clay_RenderCommand cmds[204];
    for (int i = 0; i < 101; i++)
        cmds[i] = cmd_clip(i + 1, i, 0, 200 - i, 24, true, true);
    cmds[101] = cmd_rect(102, 0, 0, 300, 24, 0);
    for (int i = 0; i < 101; i++) cmds[102 + i] = cmd_clip_end(101 - i);
    cmds[203] = cmd_rect(103, 0, 30, 300, 24, 0);
    render_reconcile(f.rs, commands_of(cmds, 204), &no_hooks, no_bounds);
    CHECK_EQ(view_count(&f), 2);
    CHECK_EQ(view_at(&f, 0).rbox.x, 100);
    CHECK_EQ(view_at(&f, 0).rbox.width, 100);
    CHECK_EQ(view_at(&f, 1).rbox.width, 300);
    fixture_finish(&f, &no_hooks);
}

static void test_many_host_scopes(void) {
    struct fixture f;
    fixture_init(&f);
    Clay_RenderCommand cmds[240];
    for (int i = 0; i < 120; i++) {
        cmds[i * 2] = cmd_custom(i * 2 + 1,
            (uint64_t)(uintptr_t)RENDER_CLIP_MARK, i * 3, 0, 2, 24);
        cmds[i * 2].userData = word(i + 1, 1, 0);
        cmds[i * 2 + 1] = cmd_rect(i * 2 + 2, i * 3, 0, 100, 24, 0);
        cmds[i * 2 + 1].userData = word(i + 1, 0, 1);
    }
    render_reconcile(f.rs, commands_of(cmds, 240), &no_hooks, no_bounds);
    CHECK_EQ(view_count(&f), 240);
    for (int i = 0; i < 120; i++) {
        CHECK_EQ(view_at(&f, i * 2 + 1).rbox.width, 2);
        CHECK_EQ(view_at(&f, i * 2 + 1).rbox.height, 24);
        CHECK_EQ(view_at(&f, i * 2 + 1).rbox.x, i * 3);
    }
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 240), &no_hooks, no_bounds), 0);
    fixture_finish(&f, &no_hooks);
}

static void test_scopes_from_the_word(void) {
	struct fixture f;
	fixture_init(&f);
	/* Owner 7 opens scope 1 with its box; a leaf clipped by it straddles;
	 * owner 8 names scope 1 and is not clipped, the number is 7's; a rounded
	 * rectangle under 1 opens scope 2, gives a square leaf at its corner its
	 * arcs as a clip, and cuts a leaf over the whole output to scope 2's box;
	 * a leaf naming a scope nobody opened is unclipped. */
	Clay_RenderCommand cmds[] = {
		cmd_rect(10, 0, 0, 50, 50, 0),
		cmd_rect(1, 25, 25, 50, 50, 0),
		cmd_rect(2, 25, 25, 50, 50, 0),
		cmd_rect(11, 10, 10, 30, 30, 8),
		cmd_rect(3, 10, 10, 10, 10, 0),
		cmd_rect(4, 0, 0, 100, 100, 0),
		cmd_rect(5, 200, 0, 10, 10, 0),
		cmd_custom(12, (uint64_t)(uintptr_t)RENDER_CLIP_MARK, 60, 60, 30, 30),
		cmd_rect(6, 55, 55, 50, 50, 0),
	};
	cmds[0].userData = word(7, 1, 0);
	cmds[1].userData = word(7, 0, 1);
	cmds[2].userData = word(8, 0, 1);
	cmds[3].userData = word(7, 2, 1);
	cmds[4].userData = word(7, 0, 2);
	cmds[5].userData = word(7, 0, 2);
	cmds[6].userData = word(7, 0, 9);
	/* A clip mark: a rounded scope with no fill, realized as a transparent
	 * rect that takes input, cutting the leaf under it to its box and arc. */
	cmds[7].userData = word(7, 3, 0);
	cmds[7].renderData.custom.cornerRadius = (Clay_CornerRadius) { 6, 6, 6, 6 };
	cmds[8].userData = word(7, 0, 3);

	render_reconcile(f.rs, commands_of(cmds, 9), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&f), 9);

	CHECK_EQ(view_at(&f, 1).rbox.x, 25);
	CHECK_EQ(view_at(&f, 1).rbox.width, 25);
	CHECK_EQ(view_at(&f, 1).rbox.height, 25);

	CHECK_EQ(view_at(&f, 2).rbox.width, 50);

	CHECK(view_at(&f, 4).pixels == NULL);
	CHECK_EQ(view_at(&f, 4).rbox.x, 10);

	CHECK(view_at(&f, 5).pixels == NULL);
	CHECK_EQ(view_at(&f, 5).rbox.x, 10);
	CHECK_EQ(view_at(&f, 5).rbox.y, 10);
	CHECK_EQ(view_at(&f, 5).rbox.width, 30);
	CHECK_EQ(view_at(&f, 5).rbox.height, 30);

	CHECK_EQ(view_at(&f, 6).rbox.x, 200);
	CHECK_EQ(view_at(&f, 6).rbox.width, 10);

	CHECK(view_at(&f, 7).pixels == NULL);
	CHECK_EQ(view_at(&f, 7).rbox.x, 60);
	CHECK_EQ(view_at(&f, 7).rbox.width, 30);
	CHECK(view_at(&f, 7).clip_mark);

	CHECK(view_at(&f, 8).pixels == NULL);
	CHECK_EQ(view_at(&f, 8).rbox.x, 60);
	CHECK_EQ(view_at(&f, 8).rbox.width, 30);

	uint32_t child = 3;
	CHECK(!render_hit(f.rs, 10.5, 10.5, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 18, 18, accept_clip_child, &child));
	child = 4;
	CHECK(!render_hit(f.rs, 10.5, 10.5, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 20, 20, accept_clip_child, &child));
	CHECK(!render_hit(f.rs, 41, 20, accept_clip_child, &child));
	child = 6;
	CHECK(!render_hit(f.rs, 60.5, 60.5, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 66, 66, accept_clip_child, &child));
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 9), &no_hooks, no_bounds), 0);

	/* Text clips to a scope too: the run is wider than scope 1, so it crops
	 * and truncates there, and widening the scope re-rasters it. */
	Clay_RenderCommand text[] = {
		cmd_rect(10, 0, 0, 40, 16, 0),
		cmd_text(1, 0, 0, 80, 16, "a long enough run", true),
	};
	text[0].userData = word(7, 1, 0);
	text[1].userData = (void *)((uintptr_t)word(7, 0, 1) | RENDER_TEXT_ELLIPSIZE);
	CHECK(render_reconcile(f.rs, commands_of(text, 2), &no_hooks, no_bounds) > 0);
	CHECK_EQ(view_at(&f, 1).dst_width, 40);
	text[0].boundingBox.width = 60;
	CHECK(render_reconcile(f.rs, commands_of(text, 2), &no_hooks, no_bounds) > 0);
	CHECK_EQ(view_at(&f, 1).dst_width, 60);

	fixture_finish(&f, &no_hooks);
}

static size_t circle_ops(void *data, const struct render_shape *shape,
		float w, float h, float *ops, size_t cap) {
	float x = w / 2, y = h / 2, r = fminf(w, h) / 2;
	float k = r * 0.55228475f;
	float path[] = { 0, x + r, y,
		2, x + r, y + k, x + k, y + r, x, y + r,
		2, x - k, y + r, x - r, y + k, x - r, y,
		2, x - r, y - k, x - k, y - r, x, y - r,
		2, x + k, y - r, x + r, y - k, x + r, y, 3 };
	CHECK(cap >= sizeof(path) / sizeof(*path));
	memcpy(ops, path, sizeof(path));
	return sizeof(path) / sizeof(*path);
}

static uint32_t raster_pixel(struct render_node_view view, int x, int y) {
	CHECK(view.pixels != NULL);
	CHECK(x >= 0 && x < view.raster_width && y >= 0 && y < view.raster_height);
	if (!view.pixels || x < 0 || x >= view.raster_width || y < 0 || y >= view.raster_height) return 0;
	return ((const uint32_t *)(view.pixels + y * view.stride))[x];
}

/* A path cuts the rects under it as a raster of their fill, with their own
 * arcs as the buffer's radii; a rect clear of the path is a scene rect, and
 * a rounded host's arcs reach either as clips. */
static void test_path_scopes_from_the_word(void) {
	struct fixture f;
	fixture_init(&f);
	struct render_shape shape = { .gen = 1, .fill = { 1, 0, 0, 1 } };
	struct render_client_hooks hooks = no_hooks;
	hooks.shape_ops = circle_ops;
	Clay_RenderCommand cmds[] = {
		cmd_custom(10, (uintptr_t)render_shape_tag(&shape), 10, 20, 40, 40),
		cmd_rect(1, 10, 20, 40, 40, 0),
		cmd_rect(2, 25, 35, 10, 10, 0),
		cmd_rect(11, 10, 20, 40, 40, 4),
		cmd_rect(3, 10, 20, 40, 40, 0),
		cmd_rect(12, 20, 30, 20, 20, 8),
		cmd_rect(4, 20, 30, 20, 20, 0),
	};
	cmds[0].userData = word(7, 1, 0);
	cmds[1].userData = word(7, 0, 1);
	cmds[2].userData = word(7, 0, 1);
	cmds[3].userData = word(7, 2, 1);
	cmds[4].userData = word(7, 0, 2);
	cmds[5].userData = word(7, 3, 2);
	cmds[6].userData = word(7, 0, 3);
	render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds);
	CHECK(view_at(&f, 1).pixels != NULL);
	CHECK(view_at(&f, 2).pixels == NULL);
	CHECK_EQ(raster_pixel(view_at(&f, 1), 1, 1), 0);
	CHECK_EQ(raster_pixel(view_at(&f, 1), 20, 20), 0xffff0000u);
	/* The rounded host the circle cuts: its fill rastered square, its own
	 * arcs on the buffer. */
	CHECK(view_at(&f, 3).pixels != NULL);
	CHECK_EQ(view_at(&f, 3).radii.topLeft, 4);
	/* This point clears the inner radius of four but is outside the circle;
	 * the inner radius itself is a clip on the buffer. */
	CHECK_EQ(raster_pixel(view_at(&f, 4), 4, 2), 0);
	uint32_t clipped = 3;
	CHECK(!render_hit(f.rs, 10.5, 20.5, accept_clip_child, &clipped));
	CHECK(render_hit(f.rs, 30, 40, accept_clip_child, &clipped));
	/* This smaller host is inside the circle: a scene rect with its radii,
	 * and the rect under it a scene rect with those arcs as a clip. */
	CHECK(view_at(&f, 5).pixels == NULL);
	CHECK_EQ(view_at(&f, 5).radii.topLeft, 8);
	CHECK(view_at(&f, 6).pixels == NULL);
	clipped = 4;
	CHECK(!render_hit(f.rs, 21, 31, accept_clip_child, &clipped));
	CHECK(render_hit(f.rs, 30, 40, accept_clip_child, &clipped));
	CHECK(!render_point_in_masks(f.rs, 1, 11, 21));
	CHECK(render_point_in_masks(f.rs, 1, 30, 40));
	CHECK(!render_point_in_masks(f.rs, 10, 11, 21));
	CHECK(render_point_in_masks(f.rs, 10, 30, 40));
	CHECK(!render_point_in_masks(f.rs, 4, 21, 31));
	CHECK(render_point_in_masks(f.rs, 4, 30, 40));
	CHECK(render_point_in_masks(f.rs, 999, 11, 21));
	uint32_t child = 1;
	CHECK(!render_hit(f.rs, 11, 21, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 30, 40, accept_clip_child, &child));
	child = 4;
	CHECK(!render_hit(f.rs, 21, 31, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 30, 40, accept_clip_child, &child));
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds), 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	/* An earlier scope shifts indices without changing the masks or pixels. */
	Clay_RenderCommand shifted[8];
	shifted[0] = cmd_rect(99, 100, 100, 20, 20, 5);
	shifted[0].userData = word(7, 4, 0);
	memcpy(shifted + 1, cmds, sizeof(cmds));
	render_reconcile(f.rs, commands_of(shifted, 8), &hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK(!render_point_in_masks(f.rs, 1, 11, 21));
	CHECK(render_point_in_masks(f.rs, 1, 30, 40));
	CHECK(render_hit(f.rs, 30, 40, accept_clip_child, &child));
	render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK(!render_point_in_masks(f.rs, 1, 11, 21));
	CHECK(render_point_in_masks(f.rs, 1, 30, 40));
	/* Changing the shape generation invalidates every raster under the path:
	 * the shape and the three rects it cuts, not the two inside it. */
	shape.gen++;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds) > 0);
	CHECK_EQ(render_buffers_created(f.rs), 4);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds), 0);
	/* An unpainted shape still supplies its path to the clipping query. */
	shape.fill[3] = 0;
	shape.gen++;
	render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds);
	CHECK(!render_point_in_masks(f.rs, 10, 11, 21));
	CHECK(render_point_in_masks(f.rs, 10, 30, 40));
	/* Moving under a stationary mask must redraw its buffer-local clip. */
	cmds[1].boundingBox.x += 10;
	render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds);
	CHECK_EQ(raster_pixel(view_at(&f, 1), 10, 1), 0xffff0000u);
	/* A child moving clear of a path becomes a scene rectangle again. */
	cmds[1].boundingBox = (Clay_BoundingBox){25, 35, 10, 10};
	render_reconcile(f.rs, commands_of(cmds, 7), &hooks, no_bounds);
	CHECK(view_at(&f, 1).pixels == NULL);
	/* Removing the host clears the retained scope before its ops are freed. */
	cmds[1].boundingBox = (Clay_BoundingBox){10, 20, 40, 40};
	render_reconcile(f.rs, commands_of(&cmds[1], 1), &hooks, no_bounds);
	CHECK(render_point_in_masks(f.rs, 1, 11, 21));
	child = 1;
	CHECK(render_hit(f.rs, 11, 21, accept_clip_child, &child));
	fixture_finish(&f, &hooks);
}

static void test_border_clips_to_the_bounds(void) {
	struct fixture f;
	fixture_init(&f);
	/* A border straddling the right edge of a 100x100 frame, clipped to it:
	 * one rect cropped to the 10 columns inside the frame, its hole where
	 * the solved box puts it. Without the word's flag the same border draws
	 * whole. */
	Clay_BoundingBox bounds = { 0, 0, 100, 100 };
	Clay_RenderCommand c = cmd_border(1, 90, 0, 40, 40, 2, 0);
	c.userData = word(7, 0, RENDER_CLIP_BOUNDS);

	render_reconcile(f.rs, commands_of(&c, 1), &no_hooks, bounds);
	CHECK(view_at(&f, 0).pixels == NULL);
	CHECK_EQ(view_at(&f, 0).rbox.x, 90);
	CHECK_EQ(view_at(&f, 0).rbox.width, 10);
	CHECK_EQ(view_at(&f, 0).rbox.height, 40);

	uint32_t leaf = 1;
	CHECK(render_hit(f.rs, 91, 20, accept_clip_child, &leaf));
	CHECK(!render_hit(f.rs, 93, 20, accept_clip_child, &leaf));
	CHECK(!render_hit(f.rs, 101, 1, accept_clip_child, &leaf));
	c.userData = word(7, 0, 0);
	CHECK(render_reconcile(f.rs, commands_of(&c, 1), &no_hooks, bounds) > 0);
	CHECK_EQ(view_at(&f, 0).rbox.width, 40);

	CHECK_EQ(render_reconcile(f.rs, commands_of(&c, 1), &no_hooks, bounds), 0);

	CHECK(render_hit(f.rs, 129, 20, accept_clip_child, &leaf));
	CHECK(!render_hit(f.rs, 127, 20, accept_clip_child, &leaf));

	/* Cropped from the left, the hole moves with the solved box. */
	c.boundingBox.x = -20;
	c.userData = word(7, 0, RENDER_CLIP_BOUNDS);
	render_reconcile(f.rs, commands_of(&c, 1), &no_hooks, bounds);
	CHECK_EQ(view_at(&f, 0).rbox.x, 0);
	CHECK_EQ(view_at(&f, 0).rbox.width, 20);

	uint32_t border = 1;
	CHECK(render_hit(f.rs, 19, 20, accept_clip_child, &border));
	CHECK(!render_hit(f.rs, 17, 20, accept_clip_child, &border));
	CHECK(render_hit(f.rs, 10, 1, accept_clip_child, &border));
	CHECK(!render_hit(f.rs, 20, 20, accept_clip_child, &border));
	fixture_finish(&f, &no_hooks);
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

	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	/* Borrowed, not owned: the client's own tree is reparented in. */
	CHECK_EQ(view_count(&f), 2);
	CHECK_EQ(view_at(&f, 0).id, 1);
	CHECK(fc.owner[0] == f.rs);
	CHECK_EQ(view_at(&f, 1).id, 2);
	CHECK(fc.owner[1] == f.rs);
	CHECK(view_at(&f, 0).shown);
	CHECK_EQ(fc.borrows, 2);
	CHECK_EQ(fc.configures, 2);
	CHECK_EQ(fc.configured_w, 400);
	CHECK_EQ(fc.configured_h, 300);
	/* Both placements fire reposition; the borrow's configure ran before the
	 * position existed. */
	CHECK_EQ(fc.repositions, 2);

	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds), 0);
	CHECK_EQ(fc.repositions, 2);

	/* Changing the window origin reapplies only that surface's logical clip. */
	int clips = fc.clips;
	fc.origins[1] = (struct render_surface_origin){20, 30};
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds) > 0);
	CHECK_EQ(fc.clips, clips + 1);
	CHECK_EQ(fc.clip_x, 0);
	CHECK_EQ(fc.clip_y, 0);
	CHECK_EQ(fc.clip_w, 0);
	CHECK_EQ(fc.configures, 2);
	CHECK_EQ(fc.repositions, 2);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds), 0);
	CHECK_EQ(fc.clips, clips + 1);

	/* A move re-derives anything keyed to the tree's scene position. */
	cmds[1].boundingBox.x = 500;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	CHECK_EQ(fc.repositions, 3);
	CHECK_EQ(view_at(&f, 1).box.x, 500);

	/* A resize configures, without a reposition. */
	cmds[1].boundingBox.width = 300;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	CHECK_EQ(fc.configures, 3);
	CHECK_EQ(fc.configured_w, 300);
	CHECK_EQ(fc.repositions, 3);

	/* Undeclared: the sweep hands the tree back, disabled, at home. */
	render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds);
	CHECK_EQ(fc.releases, 1);
	CHECK_EQ(view_count(&f), 1);
	CHECK(fc.owner[1] == NULL);

	/* A client that died between declare and reconcile realizes no node. */
	fc.gone[1] = true;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	CHECK_EQ(view_count(&f), 1);

	fixture_finish(&f, &hooks);
}

static void test_client_corners_call_the_hook(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	Clay_RenderCommand cmds[] = { cmd_custom(1, 0, 0, 0, 400, 300) };
	cmds[0].renderData.custom.cornerRadius = (Clay_CornerRadius) {
		.topLeft = 24, .topRight = 16, .bottomRight = 8, .bottomLeft = 4 };

	/* The first borrow hands the four radii over, top-left first. */
	render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds);
	CHECK_EQ(fc.corners, 1);
	CHECK(fc.radii[0] == 24 && fc.radii[1] == 16 && fc.radii[2] == 8 && fc.radii[3] == 4);

	/* A repeat frame calls nothing. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds), 0);
	CHECK_EQ(fc.corners, 1);

	/* A change calls again with the new radii. */
	cmds[0].renderData.custom.cornerRadius.bottomRight = 12;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds) > 0);
	CHECK_EQ(fc.corners, 2);
	CHECK(fc.radii[2] == 12 && fc.radii[3] == 4);

	fixture_finish(&f, &hooks);
}

static void test_click_in_a_client_corner_falls_through(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	/* A rect below, the client above it with 24 pixel corners. */
	Clay_RenderCommand cmds[] = {
		cmd_rect(10, 0, 0, 400, 300, 0),
		cmd_custom(1, 0, 0, 0, 400, 300),
	};
	cmds[1].renderData.custom.cornerRadius = (Clay_CornerRadius) { 24, 24, 24, 24 };
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);

	uint32_t below = 10, client = 1;
	/* The corner point is not the client's; the rect below takes it. */
	CHECK(!render_hit(f.rs, 1, 1, accept_clip_child, &client));
	CHECK(render_hit(f.rs, 1, 1, accept_clip_child, &below));
	CHECK(!render_hit(f.rs, 398, 298, accept_clip_child, &client));
	/* Inside the arc, and along the edges away from the corners, it is. */
	CHECK(render_hit(f.rs, 24, 24, accept_clip_child, &client));
	CHECK(render_hit(f.rs, 200, 0, accept_clip_child, &client));
	CHECK(render_hit(f.rs, 0, 150, accept_clip_child, &client));

	fixture_finish(&f, &hooks);
}

static void test_custom_crops_to_its_clip(void) {
	struct fixture f;
	struct fake_clients fc;
	struct render_client_hooks hooks;
	fixture_init_clients(&f, &fc, &hooks);

	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 0, 0, 50, 50, true, true),
		cmd_custom(1, 0, 25, 25, 400, 300),
		cmd_clip_end(10),
	};
	render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).box.x, 25);
	CHECK_EQ(view_at(&f, 0).box.y, 25);
	CHECK(view_at(&f, 0).shown);
	CHECK_EQ(fc.configured_w, 400);
	CHECK_EQ(fc.configured_h, 300);

	CHECK_EQ(fc.clips, 1);
	CHECK_EQ(fc.clip_x, 0);
	CHECK_EQ(fc.clip_y, 0);
	CHECK_EQ(fc.clip_w, 25);
	CHECK_EQ(fc.clip_h, 25);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds), 0);

	cmds[1].boundingBox.x = cmds[1].boundingBox.y = -10;
	render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).box.x, -10);
	CHECK_EQ(view_at(&f, 0).box.y, -10);
	CHECK(view_at(&f, 0).shown);
	CHECK_EQ(fc.clip_x, 10);
	CHECK_EQ(fc.clip_y, 10);
	CHECK_EQ(fc.clip_w, 50);
	CHECK_EQ(fc.clip_h, 50);

	cmds[1].boundingBox.x = cmds[1].boundingBox.y = 100;
	render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);
	CHECK(!view_at(&f, 0).shown);
	render_reconcile(f.rs, commands_of(&cmds[1], 1), &hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).box.x, 100);
	CHECK_EQ(view_at(&f, 0).box.y, 100);
	CHECK(view_at(&f, 0).shown);
	CHECK_EQ(fc.clip_w, 0);

	fixture_finish(&f, &hooks);
}

static void test_float_boxes_round(void) {
	struct fixture f;
	fixture_init(&f);
	/* Clay solves in float32, and the reconciler rounds both edges of every
	 * box at the scene boundary, the rule client_solved_box uses. Here
	 * [10.6, 41.3) rounds to [11, 41) and [20.4, 60.6) to [20, 61), so the
	 * width stays 30 while the height grows to 41. */
	Clay_RenderCommand cmds[] = { cmd_rect(1, 10.6f, 20.4f, 30.7f, 40.2f, 0) };
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).rbox.x, 11);
	CHECK_EQ(view_at(&f, 0).rbox.y, 20);
	CHECK_EQ(view_at(&f, 0).rbox.width, 30);
	CHECK_EQ(view_at(&f, 0).rbox.height, 41);

	/* A sub-pixel drift whose edges round to the same integers is not a
	 * change: [10.7, 41.4) rounds to [11, 41) again. */
	Clay_RenderCommand drift[] = { cmd_rect(1, 10.7f, 20.4f, 30.7f, 40.2f, 0) };
	CHECK_EQ(render_reconcile(f.rs, commands_of(drift, 1), &no_hooks, no_bounds), 0);

	fixture_finish(&f, &no_hooks);
}

static void test_text_rasters_once_per_change(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = { cmd_text(1, 0, 0, 80, 16, "hello", false) };

	CHECK(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds) > 0);
	CHECK_EQ(view_count(&f), 1);
	CHECK(view_at(&f, 0).pixels != NULL);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);

	/* New content re-rasters, and nothing else moves. */
	cmds[0] = cmd_text(1, 0, 0, 80, 16, "goodbye", false);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 1);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);

	/* A style change with the same string re-rasters too. */
	cmds[0].renderData.text.textColor = (Clay_Color) { 0, 0, 0, 255 };
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 1);

	/* An empty run: a real case (a label with nothing in it), and the one that
	 * puts NULL through the content compare, which UBSan rejects. */
	cmds[0] = cmd_text(2, 0, 0, 80, 16, "", false);
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);

	fixture_finish(&f, &no_hooks);
}

/* Clay's line of length -1: a word wider than its box, a space, a newline
 * (clay.h:2614-2615). Its chars sit at the newline and its box is
 * -spaceWidth wide. It draws nothing and copies nothing. */
static void test_text_negative_length_is_empty(void) {
	struct fixture f;
	fixture_init(&f);
	const char *rest = "\nb";
	Clay_RenderCommand cmds[] = { cmd_text(1, 0, 20, -7, 20, rest, false) };
	cmds[0].renderData.text.stringContents.length = -1;

	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&f), 1);
	CHECK(!view_at(&f, 0).shown);
	CHECK_EQ(render_raster_bytes(f.rs), 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);

	/* The same line with real text draws. */
	cmds[0] = cmd_text(1, 0, 20, 7, 20, "b", false);
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK(view_at(&f, 0).shown);
	CHECK(render_raster_bytes(f.rs) > 0);

	fixture_finish(&f, &no_hooks);
}

static size_t markup_attrs(void *data, void *word, const char *base,
        const struct render_text_attr **attrs) {
    (void)word;
    CHECK(strcmp(base, "abcdef") == 0);
    *attrs = data;
    return 1;
}

static void test_text_attributes(void) {
    struct fixture f;
    fixture_init(&f);
    struct render_text_attr attr = {
        .start = 0, .end = 3, .kind = RENDER_TEXT_FOREGROUND, .value = {1, 0, 0, 1},
    };
    struct render_client_hooks hooks = {.text_attrs = markup_attrs, .data = &attr};
    Clay_RenderCommand cmds[] = {cmd_text(1, 0, 0, 80, 20, "abcdef", false)};
    cmds[0].renderData.text.fontId = render_font_intern("monospace 12px");
    CHECK(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds) > 0);
    Clay_TextElementConfig config = {.fontId = cmds[0].renderData.text.fontId, .fontSize = 12};
    Clay_Dimensions prefix = render_measure_text((Clay_StringSlice){.chars="abcde", .length=5}, &config, NULL);
    Clay_Dimensions full = render_measure_text(cmds[0].renderData.text.stringContents, &config, NULL);
    /* The first glyph's columns and the last glyph's. No brightness or grey
     * test: the font, hinting and subpixel order are the host's. */
    int w = (int)(full.width - prefix.width), last = (int)prefix.width;
    uint32_t first_px[20][16], last_px[20][16];
    CHECK(w > 0 && w <= 16);
    bool red = false, only_red = true;
    for (int y = 0; y < 20; y++) {
        for (int x = 0; x < w; x++) {
            first_px[y][x] = raster_pixel(view_at(&f, 0), x, y);
            last_px[y][x] = raster_pixel(view_at(&f, 0), last + x, y);
            red |= (first_px[y][x] & 0x00ff0000) != 0;
            only_red &= (first_px[y][x] & 0x0000ffff) == 0;
        }
    }
    CHECK(red);
    CHECK(only_red);
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds), 0);
    attr.value[0] = 0;
    attr.value[1] = 1;
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds), 1);
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &hooks, no_bounds), 0);

    /* With no attributes the last glyph is the same pixels, the first is not. */
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 1);
    bool first_same = true, last_same = true;
    for (int y = 0; y < 20; y++) {
        for (int x = 0; x < w; x++) {
            first_same &= raster_pixel(view_at(&f, 0), x, y) == first_px[y][x];
            last_same &= raster_pixel(view_at(&f, 0), last + x, y) == last_px[y][x];
        }
    }
    CHECK(!first_same);
    CHECK(last_same);
    fixture_finish(&f, &hooks);
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
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).rbox.x, 0);
	CHECK_EQ(view_at(&f, 0).dst_width, 40);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds), 0);

	/* Narrowing the clip re-rasters at the tighter bound. */
	cmds[0].boundingBox.width = 20;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds) > 0);
	CHECK_EQ(view_at(&f, 0).dst_width, 20);

	fixture_finish(&f, &no_hooks);
}

/* Independent Pango reference: no renderer measurement or clip helper. */
static PangoLayout *fractional_reference(cairo_t *cr, float scale, int bound)
{
	/* The renderer's font options, so the host's antialiasing cannot differ. */
	PangoContext *context = render_text_context();
	pango_cairo_update_context(cr, context);
	PangoLayout *layout = pango_layout_new(context);
	g_object_unref(context);
	PangoFontDescription *font = pango_font_description_from_string("monospace 13.333333px");
	pango_font_description_set_absolute_size(font, pango_font_description_get_size(font) *
													   (double)scale);
	pango_layout_set_font_description(layout, font);
	pango_font_description_free(font);
	pango_layout_set_text(layout, "Su", 2);
	pango_layout_set_width(layout, bound > 0 ? bound * PANGO_SCALE : -1);
	pango_layout_set_ellipsize(layout, bound > 0 ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE);
	return layout;
}

static void test_fractional_text_clipping(void)
{
	const float scales[] = {1, 1.5f, 2};
	const float origins[] = {10, 119.999985f};
	int font = render_font_intern("monospace 13.333333px");
	CHECK(font > 0);
	for (size_t si = 0; si < 3; si++) {
		float scale = scales[si];
		cairo_surface_t *scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
		cairo_t *measure = cairo_create(scratch);
		PangoLayout *natural = fractional_reference(measure, scale, 0);
		int nw, nh;
		pango_layout_get_pixel_size(natural, &nw, &nh);
		g_object_unref(natural);
		cairo_destroy(measure);
		cairo_surface_destroy(scratch);
		for (size_t oi = 0; oi < 2; oi++)
			for (int ellipsize = 0; ellipsize < 2; ellipsize++) {
				struct fixture f;
				fixture_init(&f);
				render_set_scale(f.rs, scale);
				float x = origins[oi];
				/* Full, one-pixel right, larger right, left-only, both, restored,
				 * just either side of a device-width boundary, exact, oversized. */
				const float cuts[] = {0, 1, 6, 0, 6, 0, .6f, .4f, 0, -1, 0};
				for (size_t k = 0; k < sizeof(cuts) / sizeof(*cuts); k++) {
					float left = k == 3 || k == 4 ? 3.0f / scale : 0;
					float right = k == 0 || k == 3 || k == 5 ? 100 : (nw - cuts[k]) / scale;
					Clay_RenderCommand cmds[] = {
						cmd_clip(10, x + left, 0, right - left, 100, true, true),
						cmd_text(1, x, 0, nw / scale, nh / scale, "Su", ellipsize),
						cmd_clip_end(10),
					};
					cmds[1].renderData.text.fontId = font;
					cmds[1].renderData.text.fontSize = 0;
					Clay_RenderCommandArray commands =
						k == 10 ? commands_of(&cmds[1], 1) : commands_of(cmds, 3);
					render_reconcile(f.rs, commands, &no_hooks, no_bounds);
					CHECK(view_at(&f, 0).raster_width >= nw);
					CHECK(view_at(&f, 0).raster_height >= nh);
					int bound =
						!ellipsize || cuts[k] < .5f ? 0 : nw - (k == 6 ? 1 : (int)cuts[k]);
					cairo_surface_t *ref = cairo_image_surface_create(
						CAIRO_FORMAT_ARGB32, view_at(&f, 0).raster_width, view_at(&f, 0).raster_height);
					cairo_t *cr = cairo_create(ref);
					PangoLayout *layout = fractional_reference(cr, scale, bound);
					cairo_set_source_rgba(cr, 1, 1, 1, 1);
					pango_cairo_show_layout(cr, layout);
					g_object_unref(layout);
					cairo_destroy(cr);
					cairo_surface_flush(ref);

					size_t pitch;
					const unsigned char *data = view_at(&f, 0).pixels;
					pitch = view_at(&f, 0).stride;
					bool readable = data != NULL;
					CHECK(readable);
					if (readable) {
						int mismatch = 0;
						for (int y = 0; y < view_at(&f, 0).raster_height; y++)
							mismatch += memcmp((char *)data + y * pitch,
											   cairo_image_surface_get_data(ref) +
												   y * cairo_image_surface_get_stride(ref),
											   view_at(&f, 0).raster_width * 4) != 0;
						if (mismatch)
							fprintf(stderr,
									"  fractional text scale=%g origin=%g ellipsize=%d "
									"case=%zu Pango-bound=%d mismatched-rows=%d\n",
									scale, x, ellipsize, k, bound, mismatch);
						CHECK_EQ(mismatch, 0);
						const char *evidence = getenv("SOMEWM_TEXT_EVIDENCE");
						if (evidence != NULL) {
							char path[1024];
							snprintf(path, sizeof(path), "%s/s%g-o%zu-e%d-c%zu-reference.png",
									 evidence, scale, oi, ellipsize, k);
							CHECK_EQ(cairo_surface_write_to_png(ref, path),
									 CAIRO_STATUS_SUCCESS);
							cairo_surface_t *actual = cairo_image_surface_create_for_data(
								(unsigned char *)data, CAIRO_FORMAT_ARGB32, view_at(&f, 0).raster_width,
								view_at(&f, 0).raster_height, pitch);
							snprintf(path, sizeof(path), "%s/s%g-o%zu-e%d-c%zu-actual.png",
									 evidence, scale, oi, ellipsize, k);
							CHECK_EQ(cairo_surface_write_to_png(actual, path),
									 CAIRO_STATUS_SUCCESS);
							cairo_surface_destroy(actual);
							printf("text scale=%g origin=%.9g ellipsize=%d case=%zu "
								   "natural=%dx%d clip=%.9g+%.9g pango-bound=%d raster=%dx%d "
								   "dest=%d+%d source=%g+%g\n",
								   scale, x, ellipsize, k, nw, nh, cmds[0].boundingBox.x,
								   cmds[0].boundingBox.width, bound, view_at(&f, 0).raster_width,
								   view_at(&f, 0).raster_height, (int)view_at(&f, 0).rbox.x, view_at(&f, 0).dst_width,
								   view_at(&f, 0).crop.x, view_at(&f, 0).crop.width);
						}
					}
					cairo_surface_destroy(ref);
					CHECK(view_at(&f, 0).crop.x >= 0 && view_at(&f, 0).crop.y >= 0);
					CHECK(view_at(&f, 0).crop.x + view_at(&f, 0).crop.width <= view_at(&f, 0).raster_width);
					CHECK(view_at(&f, 0).crop.y + view_at(&f, 0).crop.height <= view_at(&f, 0).raster_height);
					if (left > 0)
						CHECK(view_at(&f, 0).crop.x > 0);
					if (cuts[k] / scale >= 1)
						CHECK(view_at(&f, 0).crop.width > 0 && view_at(&f, 0).crop.width < view_at(&f, 0).raster_width);
					CHECK_EQ(render_reconcile(f.rs, commands, &no_hooks, no_bounds), 0);
					CHECK_EQ(render_buffers_created(f.rs), 0);
				}
				fixture_finish(&f, &no_hooks);
			}
	}
}

static void test_raster_readback_lifetime(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmd = cmd_text(1, 0, 0, 80, 16, "first", false);
	render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds);
	struct render_node_view old = view_at(&f, 0);
	CHECK(old.pixels != NULL);
	CHECK_EQ(render_raster_bytes(f.rs), old.stride * old.raster_height);
	unsigned char *saved = malloc(old.stride * old.raster_height);
	assert(saved);
	memcpy(saved, old.pixels, old.stride * old.raster_height);
	cmd = cmd_text(1, 0, 0, 120, 24, "replacement", false);
	render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds);
	struct render_node_view current = view_at(&f, 0);
	CHECK(current.pixels != NULL);
	CHECK_EQ(current.raster_width, 120);
	CHECK_EQ(current.raster_height, 24);
	CHECK_EQ(render_raster_bytes(f.rs), current.stride * current.raster_height);
	CHECK(current.raster_bytes > old.raster_bytes);
	bool changed = false;
	for (int y = 0; y < old.raster_height; y++)
		changed |= memcmp(saved + y * old.stride, current.pixels + y * current.stride, 80 * 4) != 0;
	CHECK(changed);
	free(saved);
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 0);
	CHECK(view_at(&f, 0).pixels == current.pixels);
	render_reconcile(f.rs, commands_of(&cmd, 0), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&f), 0);
	CHECK_EQ(render_raster_bytes(f.rs), 0);
	fixture_finish(&f, &no_hooks);
}

static void fake_image_entry(struct image_entry *e, int w, int h) {
	memset(e, 0, sizeof(*e));
	e->native = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
	e->width = w;
	e->height = h;
	e->gen = 1;
}

static void test_output_backdrop(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry;
	fake_image_entry(&entry, 8, 8);
	cairo_t *cr = cairo_create(entry.native);
	cairo_set_source_rgba(cr, 0, 1, 0, 0.5);
	cairo_rectangle(cr, 0, 0, 4, 8);
	cairo_fill(cr);
	cairo_destroy(cr);
	entry.natural = true;
	render_set_output_id(f.rs, 1);
	Clay_RenderCommand cmds[] = {
		cmd_rect(2, 20, 0, 8, 8, 0),
		cmd_image(1, 0, 0, 8, 8, &entry),
		cmd_rect(1, 0, 0, 8, 8, 0),
		cmd_rect(3, 30, 0, 8, 8, 0),
		cmd_rect(4, 40, 0, 8, 8, 0),
	};
	cmds[0].zIndex = -4;
	cmds[4].zIndex = 200;
	cmds[1].renderData.image.backgroundColor = (Clay_Color){255, 0, 0, 255};
	for (int scale = 0; scale < 2; scale++) {
		render_set_scale(f.rs, scale ? 1.5f : 1);
		render_reconcile(f.rs, commands_of(cmds, 5), &no_hooks, no_bounds);
		CHECK(view_at(&f, 0).pixels == NULL);
		CHECK(view_at(&f, 1).pixels != NULL);
		CHECK_EQ(view_at(&f, 2).rbox.x, 20);
		CHECK_EQ(view_at(&f, 3).rbox.x, 30);
		CHECK_EQ(view_at(&f, 4).rbox.x, 40);

		size_t pitch;
		const unsigned char *data = view_at(&f, 1).pixels;
		pitch = view_at(&f, 1).stride;
		bool readable = data != NULL;
		CHECK(readable);
		if (readable) {
			uint32_t *row = (uint32_t *)((char *)data + 2 * pitch);
			CHECK_EQ(row[2], 0x80008000u);
			CHECK_EQ(row[view_at(&f, 1).raster_width - 2], 0);
		}
		CHECK_EQ(cmds[1].renderData.image.backgroundColor.a, 255);
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 5), &no_hooks, no_bounds), 0);
		/* Clay may place OUTPUT after a negative root or before it. */
		Clay_RenderCommand reordered[] = {cmds[2], cmds[1], cmds[0], cmds[3], cmds[4]};
		CHECK_EQ(render_reconcile(f.rs, commands_of(reordered, 5), &no_hooks, no_bounds), 0);
		/* Unlock removes only the top overlay; image/colour swaps sweep the
		 * vanished node while keeping the remaining paint below the desktop. */
		render_reconcile(f.rs, commands_of(cmds, 4), &no_hooks, no_bounds);
		CHECK_EQ(render_node_count(f.rs), 4);
		Clay_RenderCommand solid[] = {cmds[0], cmds[2], cmds[3]};
		render_reconcile(f.rs, commands_of(solid, 3), &no_hooks, no_bounds);
		CHECK(view_at(&f, 0).pixels == NULL);
		CHECK_EQ(view_at(&f, 1).rbox.x, 20);
		Clay_RenderCommand image[] = {cmds[0], cmds[1], cmds[3]};
		render_reconcile(f.rs, commands_of(image, 3), &no_hooks, no_bounds);
		CHECK(view_at(&f, 0).pixels != NULL);
		CHECK_EQ(view_at(&f, 1).rbox.x, 20);
		CHECK_EQ(render_reconcile(f.rs, commands_of(image, 3), &no_hooks, no_bounds), 0);
	}
	fixture_finish(&f, &no_hooks);
	cairo_surface_destroy(entry.native);
}

static void test_image_rerasters_on_generation_bump(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry;
	fake_image_entry(&entry, 4, 4);
	Clay_RenderCommand cmds[] = { cmd_image(1, 0, 0, 32, 32, &entry) };

	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	CHECK(render_raster_bytes(f.rs) > 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);

	/* The entry pointer never changes across a reload, so gen is what tells the
	 * renderer the pixels are new. */
	entry.gen++;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 1);
	CHECK_EQ(render_buffers_created(f.rs), 1);

	fixture_finish(&f, &no_hooks);
	cairo_surface_destroy(entry.native);

	/* An entry with no surface draws nothing at all. */
	struct image_entry failed = { 0 };
	Clay_RenderCommand miss[] = { cmd_image(2, 0, 0, 32, 32, &failed) };
	struct fixture g;
	fixture_init(&g);
	render_reconcile(g.rs, commands_of(miss, 1), &no_hooks, no_bounds);
	CHECK_EQ(view_count(&g), 1);
	CHECK_EQ(render_buffers_created(g.rs), 0);
	CHECK_EQ(render_raster_bytes(g.rs), 0);
	fixture_finish(&g, &no_hooks);
}

static void test_vector_image(void) {
	struct fixture f;
	fixture_init(&f);
	const char svg[] = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'>"
		"<circle cx='8' cy='8' r='8' fill='red'/></svg>";
	GError *error = NULL;
	RsvgHandle *handle = rsvg_handle_new_from_data((const guint8 *)svg,
		sizeof(svg) - 1, &error);
	CHECK(handle != NULL);
	CHECK(error == NULL);
	struct image_entry entry = { .vector = handle, .width = 16, .height = 16, .gen = 1 };
	Clay_RenderCommand cmds[] = { cmd_image(1, 0, 0, 32, 32, &entry) };
	render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
	CHECK(view_at(&f, 0).pixels != NULL);
	if (view_at(&f, 0).pixels) {

		size_t pitch;
		const unsigned char *data = view_at(&f, 0).pixels;
		pitch = view_at(&f, 0).stride;
		bool readable = data != NULL;
		CHECK(readable);
		if (readable) {
			CHECK_EQ(((uint32_t *)((char *)data + 16 * pitch))[16], 0xffff0000u);
			CHECK_EQ(((uint32_t *)data)[0], 0);
		}
	}
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);
	entry.gen++;
	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 1);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	fixture_finish(&f, &no_hooks);
	g_object_unref(handle);
}

/* Read the actual device raster at integer and fractional scales.
 * A coordinate-coded source distinguishes origin selection from stretching. */
static void test_image_source_origin(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry = { .natural = true,
		.filter = CAIRO_FILTER_NEAREST + 1, .src_x = 8, .src_y = 12 };
	cairo_surface_t *source = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 64, 64);
	uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(source);
	int stride = cairo_image_surface_get_stride(source) / 4;
	for (int y = 0; y < 64; y++)
		for (int x = 0; x < 64; x++)
			pixels[y * stride + x] = 0xff000040u | (x * 3u << 16) | (y * 3u << 8);
	cairo_surface_mark_dirty(source);
	image_entry_set(&entry, source);
	CHECK_EQ(entry.src_x, 8);
	CHECK_EQ(entry.src_y, 12);
	Clay_RenderCommand cmds[] = { cmd_image(1, 0, 0, 16, 12, &entry) };
	const float scales[] = { 1.0f, 1.25f };
	for (size_t i = 0; i < sizeof(scales) / sizeof(scales[0]); i++) {
		render_set_scale(f.rs, scales[i]);
		for (int move = 0; move < 3; move++) {
			if (move == 1) entry.src_x += 4;
			if (move == 2) entry.src_y += 4;
			CHECK(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds) > 0);
			CHECK_EQ(render_buffers_created(f.rs), 1);
			int w = (int)(16 * scales[i]), h = (int)(12 * scales[i]);
			CHECK_EQ(view_at(&f, 0).raster_width, w);
			CHECK_EQ(view_at(&f, 0).raster_height, h);
			CHECK_EQ(render_raster_bytes(f.rs), w * h * 4);

			size_t pitch;
			const unsigned char *data = view_at(&f, 0).pixels;
			pitch = view_at(&f, 0).stride;
			bool readable = data != NULL;
			CHECK(readable);
			if (readable) {
				for (int y = 0; y < h; y++) {
					uint32_t *row = (uint32_t *)((char *)data + y * pitch);
					for (int x = 0; x < w; x++) {
						int sx = entry.src_x + (int)floor((x + 0.5) / scales[i]);
						int sy = entry.src_y + (int)floor((y + 0.5) / scales[i]);
						/* At an exact texel boundary Cairo's fixed-point
						 * nearest filter may choose either neighbor. */
						double px = (x + 0.5) / scales[i];
						double py = (y + 0.5) / scales[i];
						if (scales[i] == 1 || (fabs(px - round(px)) > 0.001
								&& fabs(py - round(py)) > 0.001))
							CHECK_EQ(row[x], pixels[sy * stride + sx]);
					}
				}
			}
			CHECK_EQ(entry.gen, 1);
			CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);
			CHECK_EQ(render_buffers_created(f.rs), 0);
		}
	}
	fixture_finish(&f, &no_hooks);
	image_entry_set(&entry, NULL);
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

/* A clipped raster is a crop of the full-box buffer, so the crop has to be
 * expressed on the grid that buffer was sized on: device_len from the box's
 * rounded logical origin. Reading the crop origin off the unrounded box.x
 * instead moves the whole raster by a pixel whenever the solved origin is
 * fractional. */
static void test_clip_source_matches_the_buffer_grid(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry;
	fake_image_entry(&entry, 40, 20);
	/* [10.6, 50.6) rounds to [11, 51), so the buffer spans logical [11, 51)
	 * and the clip starting at 15 takes it from the 4th column. */
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 15, 0, 100, 20, true, true),
		cmd_image(1, 10.6f, 0, 40, 20, &entry),
		cmd_clip_end(10),
	};
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).rbox.x, 15);
	CHECK_EQ((int)view_at(&f, 0).crop.x, 4);
	CHECK_EQ((int)view_at(&f, 0).crop.width, 36);
	CHECK_EQ(view_at(&f, 0).dst_width, 36);
	fixture_finish(&f, &no_hooks);
	cairo_surface_destroy(entry.native);
}

static bool accept_any(void *user, const struct render_node_view *v,
		double sx, double sy) {
	(void)user; (void)v; (void)sx; (void)sy;
	return true;
}

static size_t triangle_ops(void *data, const struct render_shape *shape,
		float w, float h, float *ops, size_t cap) {
	static const float path[] = { 0, 0, 0, 1, 40, 0, 1, 0, 40, 3 };
	CHECK(cap >= sizeof(path) / sizeof(*path));
	memcpy(ops, path, sizeof(path));
	return sizeof(path) / sizeof(*path);
}

/* A logical move can change the rounded device extent at fractional scale.
 * The crashing tasklist retained 343 columns and submitted a 344-column crop. */
static void test_fractional_moves_refresh_rasters(void) {
	struct image_entry entry = { 0 };
	image_entry_set(&entry, cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 32, 32));
	cairo_t *cr = cairo_create(entry.native);
	cairo_set_source_rgb(cr, 0, 1, 0);
	cairo_paint(cr);
	cairo_destroy(cr);
	struct render_shape shape = { .gen = 1, .fill = { 1, 0, 0, 1 } };
	struct render_client_hooks hooks = no_hooks;
	hooks.shape_ops = triangle_ops;
	const float scales[] = { 1, 1.25f, 1.5f, 2 };
	for (int kind = 0; kind < 3; kind++) {
		struct fixture f;
		fixture_init(&f);
		Clay_RenderCommand leaf;
		switch (kind) {
		case 0: leaf = cmd_text(1, 0, 0, 229.999985f, 20, "tasklist", false); break;
		case 1: leaf = cmd_image(1, 0, 0, 229.999985f, 21, &entry); break;
		default: leaf = cmd_custom(1, (uint64_t)(uintptr_t)render_shape_tag(&shape),
			0, 0, 229.999985f, 21); break;
		}
		Clay_RenderCommand cmds[] = {
			cmd_clip(10, 348.333313f, 0, 260, 100, true, true), leaf, cmd_clip_end(10),
		};
		for (size_t si = 0; si < sizeof(scales) / sizeof(*scales); si++) {
			render_set_scale(f.rs, scales[si]);
			int prev_w = 0, prev_h = 0;
			for (int move = 0; move < 6; move++) {
				cmds[1].boundingBox.x = 371.333313f + move;
				cmds[1].boundingBox.y = 6 + move;
				render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);
				/* [371.333, 601.333) rounds to [371, 601): 230 logical. */
				int w = render_device_len(371 + move, 230, scales[si]);
				int h = render_device_len(6 + move, kind == 0 ? 20 : 21, scales[si]);
				CHECK_EQ(render_buffers_created(f.rs), move == 0 || w != prev_w || h != prev_h);
				CHECK_EQ(view_at(&f, 0).raster_width, w);
				CHECK_EQ(view_at(&f, 0).raster_height, h);
				CHECK(view_at(&f, 0).crop.x >= 0 && view_at(&f, 0).crop.y >= 0);
				CHECK(view_at(&f, 0).crop.x + view_at(&f, 0).crop.width <= view_at(&f, 0).raster_width);
				CHECK(view_at(&f, 0).crop.y + view_at(&f, 0).crop.height <= view_at(&f, 0).raster_height);
				/* The retained result must contain exactly the freshly drawn pixels. */
				struct fixture fresh;
				fixture_init(&fresh);
				render_set_scale(fresh.rs, scales[si]);
				render_reconcile(fresh.rs, commands_of(cmds, 3), &hooks, no_bounds);

				size_t ap, bp;
				const unsigned char *a = view_at(&f, 0).pixels;
				ap = view_at(&f, 0).stride;
				bool ar = a != NULL;
				const unsigned char *b = view_at(&fresh, 0).pixels;
				bp = view_at(&fresh, 0).stride;
				bool br = b != NULL;
				CHECK(ar && br);
				if (ar && br && view_at(&f, 0).raster_width == w && view_at(&f, 0).raster_height == h) {
					for (int y = 0; y < h; y++)
						CHECK(memcmp((char *)a + y * ap, (char *)b + y * bp, w * 4) == 0);
				}
				fixture_finish(&fresh, &hooks);
				CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds), 0);
				CHECK_EQ(render_buffers_created(f.rs), 0);
				prev_w = w; prev_h = h;
			}
		}
		fixture_finish(&f, &hooks);
	}
	cairo_surface_destroy(entry.native);
}

static void test_stretched_image_crop_uses_source_extent(void) {
	struct fixture f;
	fixture_init(&f);
	struct image_entry entry = { .stretch = true };
	image_entry_set(&entry, cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 20, 10));
	Clay_RenderCommand cmds[] = {
		cmd_clip(10, 50, 10, 50, 20, true, true),
		cmd_image(1, 0, 0, 100, 40, &entry), cmd_clip_end(10),
	};
	render_set_scale(f.rs, 1.5f);
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(view_at(&f, 0).raster_width, 30);
	CHECK_EQ(view_at(&f, 0).raster_height, 15);
	CHECK(view_at(&f, 0).crop.x == 15 && view_at(&f, 0).crop.width == 15);
	CHECK(view_at(&f, 0).crop.y == 3.75 && view_at(&f, 0).crop.height == 7.5);
	CHECK_EQ(view_at(&f, 0).dst_width, 50);
	CHECK_EQ(view_at(&f, 0).dst_height, 20);
	/* A one-logical-pixel crop can cover less than one source pixel. */
	cmds[0].boundingBox = (Clay_BoundingBox){ 99, 0, 1, 40 };
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK(fabs(view_at(&f, 0).crop.x - 29.8) < 0.00001);
	CHECK(fabs(view_at(&f, 0).crop.width - 0.2) < 0.00001);
	/* Moving the source under a stationary clip must update its source box. */
	cmds[1].boundingBox.x = 1;
	render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK(fabs(view_at(&f, 0).crop.x - 29.4) < 0.00001);
	fixture_finish(&f, &no_hooks);
	cairo_surface_destroy(entry.native);
}

/* Whether a pixel centre is inside a box with its corners cut by radii fitted
 * by the edge rule: what the scene draws for a rect or a cutout. */
static bool in_fitted_box(double px, double py, int x, int y, int w, int h,
		const float radii[4]) {
	float r[4];
	paint_fit_radii(r, radii, w, h);
	if (px < x || py < y || px >= x + w || py >= y + h) {
		return false;
	}
	for (int i = 0; i < 4; i++) {
		bool left = i == 0 || i == 3, top = i == 0 || i == 1;
		double cx = left ? x + r[i] : x + w - r[i];
		double cy = top ? y + r[i] : y + h - r[i];
		double dx = left ? cx - px : px - cx, dy = top ? cy - py : py - cy;
		if (r[i] > 0 && dx > 0 && dy > 0 && dx * dx + dy * dy > r[i] * r[i]) {
			return false;
		}
	}
	return true;
}

/* Compare every pixel centre with the authored outer and inner rounded boxes.
 * Border widths that meet leave no hole. */
static void test_border_ring_matches_its_rect(void) {
	static const struct { int width, radius; } cases[] = {
		{ 5, 0 }, { 5, 3 }, { 5, 5 }, { 5, 10 }, { 2, 8 }, { 8, 1 }, { 60, 10 },
	};
	const int size = 100;
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		struct fixture f;
		fixture_init(&f);
		int bw = cases[i].width;
		Clay_RenderCommand c = cmd_border(1, 0, 0, (float)size, (float)size,
			bw, (float)cases[i].radius);
		render_reconcile(f.rs, commands_of(&c, 1), &no_hooks, no_bounds);
		CHECK_EQ(view_count(&f), 1);
		CHECK(view_at(&f, 0).pixels == NULL);
		bool hole = 2 * bw < size;
		CHECK_EQ(view_at(&f, 0).rbox.width, size);
		CHECK_EQ(view_at(&f, 0).radii.topLeft, cases[i].radius);
		float outer[4], inner[4];
		for (int j = 0; j < 4; j++) {
			outer[j] = cases[i].radius;
			inner[j] = fmax(0, cases[i].radius - bw);
		}
		CHECK_EQ(render_raster_bytes(f.rs), 0);

		int disagree = 0;
		for (int y = 0; y < size; y++) {
			for (int x = 0; x < size; x++) {
				double px = x + 0.5, py = y + 0.5;
				bool drawn = in_fitted_box(px, py, 0, 0, size, size,
						outer) &&
					!(hole && in_fitted_box(px, py, bw,
						bw, size - 2 * bw,
						size - 2 * bw, inner));
				if (drawn != render_hit(f.rs, px, py, accept_any, NULL)) {
					disagree++;
				}
			}
		}
		if (disagree != 0) {
			fprintf(stderr, "  width %d radius %d: %d px disagree\n",
				bw, cases[i].radius, disagree);
		}
		CHECK_EQ(disagree, 0);
		fixture_finish(&f, &no_hooks);
	}
}

/* A TEXT under a rounded host rasters once; a move inside the host rasters
 * nothing, since the arcs are a clip on the buffer, not in its pixels. */
static void test_text_under_radius_scope_rasters_once(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(10, 0, 0, 100, 40, 8),
		cmd_text(1, 2, 2, 60, 16, "hello", false),
	};
	cmds[0].userData = word(7, 1, 0);
	cmds[1].userData = word(7, 0, 1);
	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	uint32_t text = 1;
	CHECK(!render_hit(f.rs, 2, 2, accept_clip_child, &text));
	CHECK(render_hit(f.rs, 8, 8, accept_clip_child, &text));

	CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);

	cmds[1].boundingBox.x = 4;
	CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds) > 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);

	CHECK(render_hit(f.rs, 4, 2, accept_clip_child, &text));
	CHECK(render_hit(f.rs, 8, 8, accept_clip_child, &text));

	/* Moved clear of every corner square, the clip goes. */
	cmds[1].boundingBox = (Clay_BoundingBox) { 20, 10, 60, 16 };
	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);

	CHECK(render_hit(f.rs, 20, 10, accept_clip_child, &text));
	fixture_finish(&f, &no_hooks);
}

/* The edge rule: two radii of 24 on top of a 1000 by 30 rect stay 24 (a
 * half-height clamp would make them 15), so the point 6 in from the top-left
 * corner on both axes is outside the arc and reaches the rect below. Four
 * equal radii beyond the box still fit to half its height: a pill. */
static void test_edge_rule_hit(void) {
	struct fixture f;
	fixture_init(&f);
	Clay_RenderCommand cmds[] = {
		cmd_rect(10, 0, 0, 1000, 30, 0),
		cmd_rect(1, 0, 0, 1000, 30, 0),
	};
	cmds[1].renderData.rectangle.cornerRadius = (Clay_CornerRadius) {
		.topLeft = 24, .topRight = 24 };
	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	uint32_t below = 10, bar = 1;
	CHECK(!render_hit(f.rs, 6, 6, accept_clip_child, &bar));
	CHECK(render_hit(f.rs, 6, 6, accept_clip_child, &below));
	CHECK(!render_hit(f.rs, 994, 6, accept_clip_child, &bar));
	/* Inside the arc, and at the square bottom-left corner, the bar. */
	CHECK(render_hit(f.rs, 24, 24, accept_clip_child, &bar));
	CHECK(render_hit(f.rs, 0, 29, accept_clip_child, &bar));

	cmds[1].renderData.rectangle.cornerRadius = (Clay_CornerRadius) {
		1e6, 1e6, 1e6, 1e6 };
	render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
	CHECK(!render_hit(f.rs, 2, 2, accept_clip_child, &bar));
	CHECK(render_hit(f.rs, 15, 2, accept_clip_child, &bar));
	CHECK(render_hit(f.rs, 2, 15, accept_clip_child, &bar));

	fixture_finish(&f, &no_hooks);
}

static void test_shape_leaf(void) {
	struct fixture f;
	fixture_init(&f);
	struct render_shape shape = { .gen = 1, .fill = { 1, 0, 0, 1 } };
	struct render_client_hooks hooks = no_hooks;
	hooks.shape_ops = triangle_ops;
	Clay_RenderCommand cmd = cmd_custom(1,
		(uint64_t)(uintptr_t)render_shape_tag(&shape), 0, 0, 40, 40);
	CHECK(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds) > 0);
	CHECK(view_at(&f, 0).pixels != NULL);
	CHECK(render_raster_bytes(f.rs) > 0);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds), 0);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	/* The input walk admits a point inside the path and refuses one in the
	 * leaf's box but outside it. */
	CHECK(render_hit(f.rs, 5, 5, accept_any, NULL));
	CHECK(!render_hit(f.rs, 35, 35, accept_any, NULL));
	cmd.boundingBox.width = 50;
	CHECK(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds) > 0);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	shape.gen++;
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds), 1);
	CHECK_EQ(render_buffers_created(f.rs), 1);
	shape.gradient = (struct render_gradient) {
		.kind = 1, .points = { 0, 0, 40, 40 }, .count = 2,
		.stops = { { 0, 1, 0, 0, 1 }, { 1, 0, 0, 1, 1 } },
	};
	CHECK(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds) > 0);
	CHECK(view_at(&f, 0).pixels != NULL);
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds), 0);
	shape.gradient.stops[0][2] = 1;
	CHECK(render_reconcile(f.rs, commands_of(&cmd, 1), &hooks, no_bounds) > 0);
	fixture_finish(&f, &hooks);

	fixture_init(&f);
	/* No path producer means no draw and no draw mutation. */
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 0);
	CHECK_EQ(render_raster_bytes(f.rs), 0);
	CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 0);
	fixture_finish(&f, &no_hooks);
}

static void test_shape_stroke_scope(void) {
	struct fixture f;
	fixture_init(&f);
	struct render_shape shape = { .gen = 1,
		.stroke = {0, 1, 0, 1}, .stroke_width = 4 };
	struct render_client_hooks hooks = no_hooks;
	hooks.shape_ops = circle_ops;
	Clay_RenderCommand cmds[] = {
		cmd_custom(10, (uintptr_t)render_shape_tag(&shape), 0, 0, 40, 40),
		cmd_rect(11, 0, 0, 40, 40, 0),
	};
	cmds[0].userData = word(7, 1, 0);
	cmds[1].userData = word(7, 0, 1);
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	uint32_t leaf = 10;
	CHECK(render_hit(f.rs, 20, 1, accept_clip_child, &leaf));
	CHECK(!render_hit(f.rs, 20, 20, accept_clip_child, &leaf));
	uint32_t child = 11;
	CHECK(!render_hit(f.rs, 1, 1, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 20, 20, accept_clip_child, &child));
	CHECK_EQ(raster_pixel(view_at(&f, 1), 1, 1), 0);
	CHECK_EQ(raster_pixel(view_at(&f, 1), 20, 20), 0xffff0000u);
	shape.stroke_width = 0;
	render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
	CHECK_EQ(render_buffers_created(f.rs), 0);
	CHECK_EQ(view_at(&f, 0).pixels, NULL);
	CHECK(!render_point_in_masks(f.rs, 10, 1, 1));
	CHECK(render_point_in_masks(f.rs, 10, 20, 20));
	CHECK(!render_hit(f.rs, 1, 1, accept_clip_child, &child));
	CHECK(render_hit(f.rs, 20, 20, accept_clip_child, &child));
	fixture_finish(&f, &hooks);
}

static void test_shadow_record(void) {
    struct fixture f;
    fixture_init(&f);
    struct render_shadow style = {.radius = 12, .corner_radius = 8,
        .rgba = {0, 0, 0, .75f}, .owner_box = {22, 22, 4000, 2160}};
    Clay_RenderCommand cmd = cmd_custom(1, (uintptr_t)render_shadow_tag(&style), 10, 10, 4024, 2184);
    CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 1);
    CHECK_EQ(view_count(&f), 1);
    CHECK_EQ(view_at(&f, 0).rbox.width, 4024);
    CHECK_EQ(render_raster_bytes(f.rs), 0);
    CHECK_EQ(render_buffers_created(f.rs), 0);
    CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 0);
    style.owner_box.width = 1000;
    CHECK_EQ(render_reconcile(f.rs, commands_of(&cmd, 1), &no_hooks, no_bounds), 1);
    CHECK_EQ(view_at(&f, 0).rbox.width, 1024);
    fixture_finish(&f, &no_hooks);
}

static void test_animated_border_surface(void) {
    struct fixture f;
    struct fake_clients fc;
    struct render_client_hooks hooks;
    fixture_init_clients(&f, &fc, &hooks);
    Clay_RenderCommand cmds[] = {
        cmd_border(10, 20, 30, 100, 80, 6, 0),
        cmd_custom(11, 1, 26, 36, 88, 68),
        cmd_custom(12, 2, 70, 40, 40, 30),
    };
    for (size_t i = 0; i < 3; i++) cmds[i].userData = (void *)(uintptr_t)1;
    render_constraints_begin(f.rs);
    render_constraint(f.rs, 1, (Clay_BoundingBox){20, 30, 60, 50}, true);
    render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
    CHECK_EQ(fc.clip_w, 48);
    CHECK_EQ(fc.clip_h, 38);
    CHECK_EQ(fc.configured_w, 88);
    CHECK_EQ(fc.configured_h, 68);
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds), 0);
    /* A popup shares input ownership, but has its own surface handle. */
    render_reconcile(f.rs, commands_of(cmds, 3), &hooks, no_bounds);
    CHECK_EQ(fc.clip_w, 0);
    CHECK_EQ(fc.clip_h, 0);
    render_constraints_begin(f.rs);
    render_reconcile(f.rs, commands_of(cmds, 2), &hooks, no_bounds);
    CHECK_EQ(fc.clip_w, 0);
    CHECK_EQ(fc.clip_h, 0);
    fixture_finish(&f, &hooks);
}

static void test_owner_bounds(void) {
    struct fixture f;
    fixture_init(&f);
    struct render_shadow style = {.gen = 1, .owner = 42, .radius = 12,
        .rgba = {0, 0, 0, .75f}, .owner_box = {-30, 50, 80, 60}};
    Clay_RenderCommand cmds[] = {
        cmd_custom(1, (uintptr_t)render_shadow_tag(&style), 0, 0, 0, 0),
        cmd_border(2, 10, 10, 100, 80, 4, 0),
        cmd_rect(3, -30, 50, 80, 60, 0),
    };
    cmds[1].userData = (void *)(uintptr_t)43;
    cmds[2].userData = (void *)(uintptr_t)42;
    render_constraints_begin(f.rs);
    render_constraint(f.rs, 42, (Clay_BoundingBox){0, 0, 200, 200}, false);
    render_constraint(f.rs, 43, (Clay_BoundingBox){10, 10, 60, 50}, true);
    CHECK(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds) > 0);
    CHECK_EQ(view_at(&f, 0).rbox.x, 0);
    CHECK_EQ(view_at(&f, 1).rbox.width, 60);
    CHECK_EQ(view_at(&f, 1).rbox.height, 50);
    uint32_t border = 2;
    CHECK(render_hit(f.rs, 69, 30, accept_clip_child, &border));
    CHECK(!render_hit(f.rs, 65, 30, accept_clip_child, &border));
    CHECK(render_hit(f.rs, 30, 59, accept_clip_child, &border));
    CHECK(!render_hit(f.rs, 30, 55, accept_clip_child, &border));
    CHECK_EQ(view_at(&f, 2).rbox.width, 50);
    CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds), 0);
    render_constraints_begin(f.rs);
    render_reconcile(f.rs, commands_of(cmds, 3), &no_hooks, no_bounds);
    CHECK_EQ(view_at(&f, 0).rbox.x, -42);
    CHECK_EQ(view_at(&f, 1).rbox.width, 100);
    CHECK(render_hit(f.rs, 109, 30, accept_clip_child, &border));
    CHECK(!render_hit(f.rs, 105, 30, accept_clip_child, &border));
    CHECK_EQ(view_at(&f, 2).rbox.width, 80);
    fixture_finish(&f, &no_hooks);
}

/* Author expected positions independently of the stale decoration command. */
static void test_shadow_current_owner(void) {
	struct fixture f;
	fixture_init(&f);
	struct render_shadow style = {.gen = 1, .radius = 12,
		.rgba = {0, 0, 0, 0.75f}, .owner_id = 2,
		.offset_x = -15, .offset_y = -15};
	Clay_RenderCommand cmds[] = {
		cmd_custom(1, (uintptr_t)render_shadow_tag(&style), -27, -27, 104, 84),
		cmd_rect(2, 50, 40, 80, 60, 0),
	};
	cmds[0].zIndex = -1;
	for (int scale = 0; scale < 2; scale++) {
		render_set_scale(f.rs, scale ? 1.5f : 1);
		style.owner_box = cmds[1].boundingBox = (Clay_BoundingBox){50, 40, 80, 60};
		render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
		CHECK_EQ(view_at(&f, 0).rbox.x, 23);
		CHECK_EQ(view_at(&f, 0).rbox.y, 13);
		CHECK_EQ(view_at(&f, 1).rbox.x, 50);
		Clay_BoundingBox box;
		CHECK(render_shadow_box(f.rs, 1, &box));
		CHECK_EQ(box.width, 104);
		CHECK_EQ(box.height, 84);
		cmds[0].boundingBox = (Clay_BoundingBox){23, 13, 104, 84};
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);
		style.owner_box.x = cmds[1].boundingBox.x = 100;
		CHECK(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds) > 0);
		CHECK_EQ(view_at(&f, 0).rbox.x, 73);
		CHECK_EQ(render_buffers_created(f.rs), 0);
		cmds[0].boundingBox.x = 73;
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);
		/* Centered FIT growth changes both the owner's width and origin. */
		style.owner_box = cmds[1].boundingBox = (Clay_BoundingBox){60, 40, 160, 60};
		render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
		CHECK_EQ(view_at(&f, 0).rbox.x, 33);
		CHECK(render_shadow_box(f.rs, 1, &box));
		CHECK_EQ(box.width, 184);
		CHECK_EQ(render_buffers_created(f.rs), 0);
		cmds[0].boundingBox = (Clay_BoundingBox){33, 13, 184, 84};
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);
		style.owner_box = cmds[1].boundingBox = (Clay_BoundingBox){120, 40, 40, 60};
		render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
		CHECK_EQ(view_at(&f, 0).rbox.x, 93);
		CHECK(render_shadow_box(f.rs, 1, &box));
		CHECK_EQ(box.width, 64);
		cmds[0].boundingBox = (Clay_BoundingBox){93, 13, 64, 84};
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds), 0);
		CHECK_EQ(view_at(&f, 0).id, 1);
	CHECK_EQ(render_nodes_created(f.rs), 0);
	CHECK_EQ(render_nodes_swept(f.rs), 0);
		/* A transparent borderless owner has no command. */
		style.owner_box = (Clay_BoundingBox){200, 80, 100, 60};
		style.spread = 3;
		render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds);
		CHECK_EQ(view_at(&f, 0).rbox.x, 170);
		CHECK_EQ(view_at(&f, 0).rbox.y, 50);
		CHECK(render_shadow_box(f.rs, 1, &box));
		CHECK_EQ(box.width, 130);
		CHECK_EQ(box.height, 90);
		cmds[0].boundingBox = (Clay_BoundingBox){170, 50, 130, 90};
		CHECK_EQ(render_reconcile(f.rs, commands_of(cmds, 1), &no_hooks, no_bounds), 0);
		style.spread = 0;
	}
	render_reconcile(f.rs, commands_of(cmds, 0), &no_hooks, no_bounds);
	CHECK_EQ(render_node_count(f.rs), 0);
	fixture_finish(&f, &no_hooks);
}

static void test_draw_rect_and_shadow_pixels(void) {
    struct fixture f;
    fixture_init(&f);
    struct paint_target *target = paint_target_create(test_painter, 64, 64);
    CHECK(target);
    struct render_shadow style = {.radius = 8, .corner_radius = 8,
        .rgba = {0, 0, 0, .75f}, .owner_box = {20, 20, 24, 24}};
    Clay_RenderCommand cmds[] = {
        cmd_custom(1, (uintptr_t)render_shadow_tag(&style), 12, 12, 40, 40),
        cmd_rect(2, 20, 20, 24, 24, 8),
    };
    render_reconcile(f.rs, commands_of(cmds, 2), &no_hooks, no_bounds);
    CHECK(paint_begin(test_painter, paint_target_fbo(target), 64, 64, 0, NULL, 0));
    paint_clear(test_painter, (struct paint_color){0});
    struct render_draw_params params = {.scale = 1, .width = 64, .height = 64};
    render_draw(f.rs, test_painter, &no_hooks, NULL, &params);
    CHECK(paint_end(test_painter));
    render_finish(f.rs);
    uint32_t pixels[64 * 64];
    CHECK(paint_readback(test_painter, (struct paint_box){0, 0, 64, 64}, 64 * 4, pixels));
    CHECK_EQ(pixels[32 * 64 + 32], 0xffff0000u);
    CHECK_EQ(pixels[0], 0);
    CHECK_EQ(pixels[20 * 64 + 20] & 0x00ffffffu, 0);
    unsigned previous = 0;
    for (int x = 8; x < 20; x++) {
        unsigned alpha = pixels[32 * 64 + x] >> 24;
        CHECK(alpha >= previous);
        previous = alpha;
    }
    CHECK(previous > 0);
    paint_target_destroy(target);
    fixture_finish(&f, &no_hooks);
}

int main(void) {
    if (!init_context()) return 77;
    test_painter = paint_create();
    CHECK(test_painter);
	static const struct {
		const char *name;
		void (*fn)(void);
	} tests[] = {
        { "rect and shadow pixels", test_draw_rect_and_shadow_pixels },
		{ "identical frame reconciles to zero", test_identical_frame_reconciles_to_zero },
		{ "add, remove and move", test_add_remove_move },
		{ "retained node returns", test_retained_node_returns },
		{ "a radius toggle keeps the node", test_radius_toggle_keeps_the_node },
		{ "clip stack", test_clip_stack },
        { "full clip budget inside a floating root", test_full_clip_budget },
		{ "clip axes", test_clip_axes },
		{ "opacity from the word", test_opacity_from_the_word },
		{ "scopes from the word", test_scopes_from_the_word },
        { "120 renderer host scopes without native clips", test_many_host_scopes },
		{ "border clips to the bounds", test_border_clips_to_the_bounds },
		{ "client surface hooks", test_client_surface_hooks },
		{ "custom crops to its clip", test_custom_crops_to_its_clip },
		{ "client corners call the hook", test_client_corners_call_the_hook },
		{ "a click in a client's corner falls through", test_click_in_a_client_corner_falls_through },
		{ "float boxes round", test_float_boxes_round },
		{ "text rasters once per change", test_text_rasters_once_per_change },
		{ "text of length -1 is an empty line", test_text_negative_length_is_empty },
		{ "text attributes", test_text_attributes },
		{ "text crops to its clip", test_text_crops_to_its_clip },
		{ "fractional text matches Pango", test_fractional_text_clipping },
		{ "raster readback lifetime", test_raster_readback_lifetime },
		{ "output backdrop", test_output_backdrop },
		{ "image rerasters on generation bump", test_image_rerasters_on_generation_bump },
		{ "vector image", test_vector_image },
		{ "image source origin", test_image_source_origin },
		{ "shape leaf", test_shape_leaf },
		{ "shape stroke scope", test_shape_stroke_scope },
		{ "path scopes from the word", test_path_scopes_from_the_word },
		{ "fractional moves refresh rasters", test_fractional_moves_refresh_rasters },
		{ "stretched image crop uses source extent", test_stretched_image_crop_uses_source_extent },
		{ "shadow record", test_shadow_record },
		{ "shadow follows current owner", test_shadow_current_owner },
        { "owner bounds fit borders and crop shadows", test_owner_bounds },
        { "animated borders exclude their surface pixels", test_animated_border_surface },
		{ "font interning", test_font_interning },
		{ "measure is monotonic", test_measure_is_monotonic },
		{ "a border's ring matches its rect", test_border_ring_matches_its_rect },
		{ "text under a radius scope rasters once", test_text_under_radius_scope_rasters_once },
		{ "the edge rule in the hit test", test_edge_rule_hit },
		{ "clip source matches the buffer grid", test_clip_source_matches_the_buffer_grid },
	};

	for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		current_test = tests[i].name;
		int before = failures;
		tests[i].fn();
		printf("%s %s\n", failures == before ? "ok  " : "FAIL", tests[i].name);
	}
	if (failures > 0) {
		fprintf(stderr, "%d check(s) failed\n", failures);
	}
	paint_destroy(test_painter);
	finish_context();
	return failures > 0 ? 1 : 0;
}
