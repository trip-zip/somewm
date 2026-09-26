/* Production-pin solver -> renderer regression tests. Compile the same bundled
 * header here (instead of linking clay_lib) to inspect actual stored declarations.
 * Structural expectations below are independent of the declaration builder.
 * Includes the native representation extensions used by widget declarations. */
#define CLAY_IMPLEMENTATION
/* Upstream implementation warnings stay scoped to the bundled include. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-variable"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wsign-compare"
#include "clay.h"
#pragma GCC diagnostic pop
#include "render.h"
#include "render_image.h"
#include "render_text.h"

#include <assert.h>
#include <signal.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wlr/types/wlr_scene.h>

static Clay_ElementId id(uint32_t value) { return (Clay_ElementId){ .id = value }; }
static void clay_error(Clay_ErrorData error) {
	fprintf(stderr, "Clay: %.*s\n", error.errorText.length, error.errorText.chars);
	abort();
}
static Clay_Dimensions measure(Clay_StringSlice text, Clay_TextElementConfig *cfg, void *data) {
	(void)cfg; (void)data;
	return (Clay_Dimensions){ text.length * 8, 12 };
}
static void *start_context(void) {
	assert(Clay_GetCurrentContext() == NULL);
	uint32_t size = Clay_MinMemorySize();
	void *arena = malloc(size);
	assert(arena);
	Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, arena),
		(Clay_Dimensions){200, 160}, (Clay_ErrorHandler){clay_error, NULL});
	Clay_SetMeasureTextFunction(measure, NULL);
	Clay_SetCullingEnabled(false);
	return arena;
}
static void stop_context(void *arena) {
	/* Preserve production's teardown guard: MinMemorySize consults current. */
	Clay_SetCurrentContext(NULL);
	free(arena);
}
static void open_node(uint32_t key, Clay_ElementDeclaration decl) {
	Clay__OpenElementWithId(id(key));
	Clay__ConfigureOpenElementPtr(&decl);
}
static Clay_LayoutElement *element(uint32_t key) {
	Clay_Context *ctx = Clay_GetCurrentContext();
	for (int i = 0; i < ctx->layoutElements.length; i++)
		if (ctx->layoutElements.internalArray[i].id == key)
			return &ctx->layoutElements.internalArray[i];
	abort();
}
static void box(Clay_BoundingBox got, float x, float y, float w, float h) {
	if (got.x != x || got.y != y || got.width != w || got.height != h) {
		fprintf(stderr, "box got %g,%g %gx%g; expected %g,%g %gx%g\n",
			got.x,got.y,got.width,got.height,x,y,w,h);
	}
	assert(got.x == x && got.y == y && got.width == w && got.height == h);
}
static struct wlr_scene_tree *resolve(void *data, uint64_t handle) {
	assert(handle == 1);
	return data;
}
static bool release(void *data, uint64_t handle, void *owner) {
	(void)data; (void)owner;
	assert(handle == 1);
	return true;   /* the renderer parks the tree */
}
static void borrow(void *data, uint64_t handle, void *owner) {
	(void)data; (void)owner;
	assert(handle == 1);
}
static void configure(void *data, uint64_t handle, int w, int h) {
	(void)data;
	assert(handle == 1 && w == 24 && h == 16);
}

static Clay_RenderCommandArray primitives(struct image_entry *image, float width) {
	Clay_BeginLayout();
	open_node(100, (Clay_ElementDeclaration){
		.layout = { .sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(120)},
			.padding = CLAY_PADDING_ALL(4), .childGap = 4,
			.layoutDirection = CLAY_TOP_TO_BOTTOM }});
	open_node(101, (Clay_ElementDeclaration){
		.layout.sizing = {CLAY_SIZING_PERCENT(.5), CLAY_SIZING_FIXED(16)},
		.backgroundColor = {255, 0, 0, 255}});
	Clay__CloseElement();
	for (int i = 0; i < 2; i++) {
		open_node(102 + i, (Clay_ElementDeclaration){
			.layout.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)},
			.floating = {.attachTo = CLAY_ATTACH_TO_PARENT, .zIndex = 2,
				.offset = {100 + 24 * i, 0},
				.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH},
			.backgroundColor = {0, 255, 0, 255}});
		Clay__CloseElement();
		Clay__OpenTextElement(i ? CLAY_STRING("BBB") : CLAY_STRING("AA"),
			(Clay_TextElementConfig){.fontSize = 12, .textColor = {255,255,255,255},
				.wrapMode = CLAY_TEXT_WRAP_NONE});
	}
	open_node(105, (Clay_ElementDeclaration){
		.layout.sizing = {CLAY_SIZING_FIXED(16), CLAY_SIZING_FIXED(16)},
		.image.imageData = image});
	Clay__CloseElement();
	open_node(106, (Clay_ElementDeclaration){
		.layout.sizing = {CLAY_SIZING_FIXED(24), CLAY_SIZING_FIXED(16)},
		.custom.customData = (void *)(uintptr_t)1});
	Clay__CloseElement();
	open_node(107, (Clay_ElementDeclaration){
		.layout.sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(16)},
		.border = {.color = {255,255,255,255}, .width = CLAY_BORDER_ALL(1)}});
	Clay__CloseElement();
	Clay__CloseElement();
	return Clay_EndLayout(0);
}

/* Constants from the pre-migration number hash, offsets 2 and 4 under ID 100.
 * Do not derive these expected IDs via the solver's own hashing functions. */
static const uint32_t text_ids[] = {1905845001u, 3653481309u};
static bool structure_matches(void) {
	Clay_LayoutElement *root = element(100), *rect = element(101);
	const uint32_t children[] = {101, 1905845001u, 3653481309u, 105, 106, 107};
	if (root->children.length != 6 || root->floatingChildrenCount != 2
			|| root->config.layout.layoutDirection != CLAY_TOP_TO_BOTTOM
			|| root->config.layout.childGap != 4
			|| rect->config.layout.sizing.width.type != CLAY__SIZING_TYPE_PERCENT
			|| rect->config.layout.sizing.width.size.percent != .5f)
		return false;
	for (int i = 0; i < 6; i++)
		if (Clay_GetCurrentContext()->layoutElements.internalArray[
			root->children.elements[i]].id != children[i])
			return false;
	for (int i = 0; i < 2; i++) {
		Clay_LayoutElement *floating = element(102 + i);
		if (floating->config.floating.attachTo != CLAY_ATTACH_TO_PARENT
				|| floating->config.floating.parentId != 100
				|| floating->config.floating.zIndex != 2
				|| !element(text_ids[i])->isTextElement)
			return false;
	}
	return true;
}
static void inspect_primitive(void *data, const struct render_node_view *v) {
	int *count = data;
	assert(!v->mismatch && v->has_node);
	if (v->type == CLAY_RENDER_COMMAND_TYPE_TEXT || v->type == CLAY_RENDER_COMMAND_TYPE_IMAGE)
		assert(v->raster_bytes > 0);
	(*count)++;
}
static void test_primitives(void) {
	/* Repeated construction after teardown also catches stale current-context use. */
	for (int cycle = 0; cycle < 3; cycle++) {
		void *arena = start_context();
		struct wlr_scene *scene = wlr_scene_create();
		struct wlr_scene_tree *surface = wlr_scene_tree_create(&scene->tree);
		struct render_state *rs = render_create(&scene->tree);
		struct render_client_hooks hooks = {.resolve = resolve, .release = release,
			.configure = configure, .borrow = borrow, .data = surface};
		struct image_entry image = {0};
		image_entry_set(&image, cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 16, 16));
		for (int frame = 0; frame < 4; frame++) {
			float width = frame >= 2 ? 160 : 200;
			Clay_RenderCommandArray commands = primitives(&image, width);
			assert(structure_matches());
			/* A geometry-preserving FIXED mutation must fail the structure oracle. */
			Clay_SizingAxis saved = element(101)->config.layout.sizing.width;
			element(101)->config.layout.sizing.width = CLAY_SIZING_FIXED((width - 8) / 2);
			assert(!structure_matches());
			element(101)->config.layout.sizing.width = saved;
			assert(commands.length == 8);
			const Clay_RenderCommandType kinds[] = {
				CLAY_RENDER_COMMAND_TYPE_RECTANGLE, CLAY_RENDER_COMMAND_TYPE_TEXT,
				CLAY_RENDER_COMMAND_TYPE_TEXT, CLAY_RENDER_COMMAND_TYPE_IMAGE,
				CLAY_RENDER_COMMAND_TYPE_CUSTOM, CLAY_RENDER_COMMAND_TYPE_BORDER,
				CLAY_RENDER_COMMAND_TYPE_RECTANGLE, CLAY_RENDER_COMMAND_TYPE_RECTANGLE};
			for (int i = 0; i < 8; i++) assert(commands.internalArray[i].commandType == kinds[i]);
			box(Clay_GetElementData(id(101)).boundingBox, 4, 4, (width - 8) / 2, 16);
			box(Clay_GetElementData(id(text_ids[0])).boundingBox, 4, 24, 16, 12);
			box(Clay_GetElementData(id(text_ids[1])).boundingBox, 4, 40, 24, 12);
			box(Clay_GetElementData(id(105)).boundingBox, 4, 56, 16, 16);
			box(Clay_GetElementData(id(106)).boundingBox, 4, 76, 24, 16);
			box(Clay_GetElementData(id(107)).boundingBox, 4, 96, 40, 16);
			box(Clay_GetElementData(id(102)).boundingBox, 100, 0, 20, 20);
			int mutations = render_reconcile(rs, commands, &hooks, (Clay_BoundingBox){0,0,200,160});
			assert(frame % 2 ? mutations == 0 : mutations > 0);
			assert(surface->node.x == 4 && surface->node.y == 76 && surface->node.enabled);
			int count = 0;
			render_walk(rs, inspect_primitive, &count);
			assert(count == 8);
		}
		render_destroy(rs, &hooks);
		wlr_scene_node_destroy(&scene->tree.node);
		image_entry_set(&image, NULL);
		stop_context(arena);
	}
}

static void inspect_clip(void *data, const struct render_node_view *v) {
	int *count = data;
	assert(!v->mismatch);
	if (v->type == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
		box(v->rbox, 0, 0, 68, 68);
		assert(v->has_node);
		(*count)++;
	}
}
/* Twelve ordinary two-axis scopes exceed the old ten-record capacity.
 * Raw pointer ancestry/axis filtering and floating clip inheritance remain
 * M0b gaps; this test does not certify either contract or unbounded capacity. */
static void test_clips(void) {
	void *arena = start_context();
	struct wlr_scene *scene = wlr_scene_create();
	struct render_state *rs = render_create(&scene->tree);
	struct render_client_hooks hooks = {0}; /* No CUSTOM commands. */
	for (int frame = 0; frame < 3; frame++) {
		Clay_BeginLayout();
		for (int i = 0; i < 12; i++)
			open_node(200 + i, (Clay_ElementDeclaration){
				.layout.sizing = {CLAY_SIZING_FIXED(90 - i * 2), CLAY_SIZING_FIXED(90 - i * 2)},
				.clip = {.horizontal = true, .vertical = true}});
		open_node(300, (Clay_ElementDeclaration){
			.layout.sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
			.backgroundColor = {255,0,0,255}});
		Clay__CloseElement();
		for (int i = 0; i < 12; i++) Clay__CloseElement();
		Clay_RenderCommandArray commands = Clay_EndLayout(0);
		assert(Clay_GetCurrentContext()->scrollContainerDatas.length == 12);
		assert(commands.length == 25);
		for (int i = 0; i < 12; i++) {
			assert(element(200 + i)->config.clip.horizontal);
			assert(element(200 + i)->config.clip.vertical);
			assert(commands.internalArray[i].commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START);
			assert(commands.internalArray[24 - i].commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END);
		}
		assert(commands.internalArray[12].commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE);
		int mutations = render_reconcile(rs, commands, &hooks, (Clay_BoundingBox){0,0,200,160});
		assert(frame ? mutations == 0 : mutations > 0);
		int count = 0;
		render_walk(rs, inspect_clip, &count);
		assert(count == 1);
	}
	render_destroy(rs, &hooks);
	wlr_scene_node_destroy(&scene->tree.node);
	stop_context(arena);
}
static void test_overlay_rejected(void) {
	/* Properties remain unexposed. Verify each new command still aborts if
	 * it reaches the renderer; tint has no implemented group-opacity meaning. */
	void *arena = start_context();
	Clay_BeginLayout();
	open_node(400, (Clay_ElementDeclaration){
		.layout.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)},
		.backgroundColor = {255,255,255,255}, .overlayColor = {255,0,0,128}});
	Clay__CloseElement();
	Clay_RenderCommandArray commands = Clay_EndLayout(0);
	assert(commands.length == 3);
	assert(commands.internalArray[0].commandType == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START);
	assert(commands.internalArray[2].commandType == CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END);
	for (int end = 0; end < 2; end++) {
		pid_t child = fork();
		assert(child >= 0);
		if (!child) {
			setrlimit(RLIMIT_CORE, &(struct rlimit){0, 0});
			if (end) { commands.internalArray += 2; commands.length = 1; }
			struct wlr_scene *scene = wlr_scene_create();
			struct render_state *rs = render_create(&scene->tree);
			render_reconcile(rs, commands, &(struct render_client_hooks){0}, (Clay_BoundingBox){0,0,200,160});
			_exit(0);
		}
		int status;
		assert(waitpid(child, &status, 0) == child);
		assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
	}
	stop_context(arena);
}
int main(void) {
	test_primitives(); puts("ok pinned primitives, mixed identities, structural negative, repeated frames and teardown");
	test_clips(); puts("ok 12 nested clips, three frames");
	test_overlay_rejected(); puts("ok unsupported overlay start/end rejected");
	render_text_finish();
	return 0;
}
