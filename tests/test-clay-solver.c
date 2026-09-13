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
static void test_text_area(void) {
	void *arena = start_context();
	void *owner = (void *)(uintptr_t)0x1234;
	Clay_TextElementConfig text = {.userData=owner, .fontId=9,
		.textColor={64,128,192,255}, .textAlignment=CLAY_TEXT_ALIGN_CENTER};
	Clay_TextElementLayout layout = {.growWidth=true, .growHeight=true,
		.verticalAlignment=CLAY_ALIGN_Y_CENTER};
	for (int inserted = 0; inserted < 2; inserted++) {
		Clay_BeginLayout();
		open_node(100, (Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(40)}});
		if (inserted) {
			open_node(150, (Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(5), CLAY_SIZING_FIXED(1)}});
			Clay__CloseElement();
		}
		Clay__OpenTextElementWithLayout(id(201), CLAY_STRING("X"), text, &layout);
		open_node(300, (Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(6)},
			.floating={.attachTo=CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId=201,
				.attachPoints={.parent=CLAY_ATTACH_POINT_RIGHT_BOTTOM, .element=CLAY_ATTACH_POINT_LEFT_TOP},
				.offset={2,3}, .zIndex=2}, .backgroundColor={0,255,0,255}});
		Clay__CloseElement();
		Clay__CloseElement();
		Clay_RenderCommandArray commands = Clay_EndLayout(0);
		assert(Clay_GetCurrentContext()->layoutElements.length == 4 + inserted);
		assert(element(201)->isTextElement && element(201)->hasTextLayout);
		assert(Clay__GetElementSizing(element(201), true).type == CLAY__SIZING_TYPE_GROW);
		box(Clay_GetElementData(id(201)).boundingBox, inserted ? 5 : 0, 0, inserted ? 95 : 100, 40);
		box(Clay_GetElementData(id(300)).boundingBox, 102, 43, 10, 6);
		int runs = 0;
		for (int i = 0; i < commands.length; i++) {
			Clay_RenderCommand *cmd = &commands.internalArray[i];
			if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
			assert(cmd->userData == owner && cmd->renderData.text.fontId == 9);
			assert(cmd->renderData.text.textColor.r == 64 && cmd->renderData.text.textColor.g == 128
				&& cmd->renderData.text.textColor.b == 192 && cmd->renderData.text.textColor.a == 255);
			box(cmd->boundingBox, inserted ? 48.5f : 46, 14, 8, 12);
			runs++;
		}
		assert(runs == 1);
		Clay_SetPointerState((Clay_Vector2){90,35}, false);
		assert(Clay_PointerOver(id(201))); /* Inside the widget, outside its glyph. */
	}
	Clay_BeginLayout();
	open_node(100, (Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(60)}});
	Clay__OpenTextElementWithLayout(id(201), CLAY_STRING("AA BB"), text, &layout);
	Clay__CloseElement();
	Clay_RenderCommandArray commands = Clay_EndLayout(0);
	box(Clay_GetElementData(id(201)).boundingBox, 0, 0, 30, 60);
	assert(commands.length == 2);
	for (int i = 0; i < commands.length; i++) {
		assert(commands.internalArray[i].commandType == CLAY_RENDER_COMMAND_TYPE_TEXT);
		assert(commands.internalArray[i].userData == owner && commands.internalArray[i].renderData.text.fontId == 9);
		box(commands.internalArray[i].boundingBox, 7, 18 + 12*i, 16, 12);
	}
	Clay_SetDebugModeEnabled(true);
	Clay_GetCurrentContext()->debugSelectedElementId = 201;
	Clay_BeginLayout();
	open_node(100, (Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(60)}});
	Clay__OpenTextElementWithLayout(id(201), CLAY_STRING("AA BB"), text, &layout);
	Clay__CloseElement();
	commands = Clay_EndLayout(0);
	bool alignment_shown = false;
	for (int i = 0; i < commands.length; i++) {
		Clay_RenderCommand *cmd = &commands.internalArray[i];
		if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
		Clay_StringSlice s = cmd->renderData.text.stringContents;
		if (s.length == 18 && !memcmp(s.chars, "Vertical Alignment", 18)) alignment_shown = true;
	}
	assert(alignment_shown);
	stop_context(arena);
}

static void test_passive_clips(void) {
	void *arena = start_context();
	for (int passive = 0; passive < 2; passive++) {
		Clay_BeginLayout();
		open_node(100, (Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_FIXED(20),CLAY_SIZING_FIXED(20)},
			.clip={.horizontal=true,.vertical=true,.passive=passive,.childOffset={-3,-4}}});
		open_node(101, (Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)}});
		open_node(102, (Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_FIXED(40),CLAY_SIZING_FIXED(40)},
			.backgroundColor={255,0,0,255}});
		Clay__CloseElement();Clay__CloseElement();Clay__CloseElement();
		Clay_RenderCommandArray commands=Clay_EndLayout(0);
		box(Clay_GetElementData(id(100)).boundingBox,0,0,20,20);
		box(Clay_GetElementData(id(101)).boundingBox,-3,-4,40,40);
		box(Clay_GetElementData(id(102)).boundingBox,-3,-4,40,40);
		assert(commands.length==3);
		assert(commands.internalArray[0].commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_START);
		assert(commands.internalArray[1].commandType==CLAY_RENDER_COMMAND_TYPE_RECTANGLE);
		assert(commands.internalArray[2].commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_END);
		assert(Clay_GetCurrentContext()->scrollContainerDatas.length==!passive);
		assert(Clay_GetScrollContainerData(id(100)).found==!passive);
		Clay_SetPointerState((Clay_Vector2){1,1},false);
		assert(Clay_PointerOver(id(102)));
		Clay_SetPointerState((Clay_Vector2){21,1},false);
		assert(!Clay_PointerOver(id(102)));
	}
	Clay_SetDebugModeEnabled(true);
	Clay_GetCurrentContext()->debugSelectedElementId=100;
	Clay_BeginLayout();
	open_node(100,(Clay_ElementDeclaration){
		.layout.sizing={CLAY_SIZING_FIXED(20),CLAY_SIZING_FIXED(20)},
		.clip={.horizontal=true,.vertical=true,.passive=true}});
	Clay__CloseElement();
	Clay_RenderCommandArray inspected=Clay_EndLayout(0);
	bool passive_shown=false;
	for (int i=0;i<inspected.length;i++) {
		Clay_RenderCommand *cmd=&inspected.internalArray[i];
		if (cmd->commandType!=CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
		Clay_StringSlice text=cmd->renderData.text.stringContents;
		if (text.length==7 && !memcmp(text.chars,"Passive",7)) passive_shown=true;
	}
	assert(passive_shown);
	stop_context(arena);
	/* Capacity is independent of the inspector's own scrolling panes. */
	arena=start_context();
	Clay_BeginLayout();
	for (int i=0;i<121;i++) {
		open_node(1000+i*2,(Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_FIXED(1),CLAY_SIZING_FIXED(1)},
			.clip={.horizontal=true,.vertical=true,.passive=i<120}});
		open_node(1001+i*2,(Clay_ElementDeclaration){
			.layout.sizing={CLAY_SIZING_FIXED(2),CLAY_SIZING_FIXED(2)},
			.backgroundColor={255,0,0,255}});
		Clay__CloseElement();Clay__CloseElement();
	}
	Clay_RenderCommandArray commands=Clay_EndLayout(0);
	assert(commands.length==121*3);
	assert(Clay_GetCurrentContext()->scrollContainerDatas.length==1);
	assert(!Clay_GetScrollContainerData(id(1000)).found);
	assert(Clay_GetScrollContainerData(id(1240)).found);
	stop_context(arena);
}

static void test_grow_rounding(void) {
    void *arena = start_context();
    for (int vertical = 0; vertical < 2; vertical++) {
        for (int enabled = 0; enabled < 2; enabled++) {
            Clay_BeginLayout();
            open_node(100, (Clay_ElementDeclaration){.layout = {
                .sizing = {CLAY_SIZING_FIXED(vertical ? 10 : 1280), CLAY_SIZING_FIXED(vertical ? 1280 : 10)},
                .layoutDirection = vertical ? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT,
                .ceilGrow = enabled}});
            for (int i = 0; i < 3; i++) {
                open_node(101+i, (Clay_ElementDeclaration){
                    .layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)},
                    .backgroundColor = {255, 0, 0, 255}});
                Clay__CloseElement();
            }
            Clay__CloseElement();
            Clay_EndLayout(0);
            for (int i = 0; i < 3; i++) {
                Clay_BoundingBox b = Clay_GetElementData(id(101+i)).boundingBox;
                float extent = vertical ? b.height : b.width;
                float origin = vertical ? b.y : b.x;
                if (enabled) {
                    assert(extent == (i == 2 ? 426 : 427));
                    assert(origin == i * 427);
                } else {
                    assert(extent > 426 && extent < 427);
                }
                assert(element(101+i)->config.layout.sizing.width.type == CLAY__SIZING_TYPE_GROW);
                assert(element(101+i)->config.layout.sizing.height.type == CLAY__SIZING_TYPE_GROW);
            }
        }
    }
    // Authored fractional bounds win over rounding; minima can overflow.
    for (int minimum = 0; minimum < 2; minimum++) {
        Clay_BeginLayout();
        open_node(100, (Clay_ElementDeclaration){.layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(10)}, .ceilGrow = true}});
        open_node(101, (Clay_ElementDeclaration){.layout.sizing = {
            minimum ? CLAY_SIZING_GROW(0) : CLAY_SIZING_GROW(0,30.5), CLAY_SIZING_GROW(0)}});
        Clay__CloseElement();
        open_node(102, (Clay_ElementDeclaration){.layout.sizing = {
            CLAY_SIZING_GROW(minimum ? 70.5 : 0), CLAY_SIZING_GROW(0)}});
        Clay__CloseElement();Clay__CloseElement();Clay_EndLayout(0);
        assert(Clay_GetElementData(id(101)).boundingBox.width == (minimum ? 30 : 30.5));
        assert(Clay_GetElementData(id(102)).boundingBox.width == (minimum ? 70.5 : 69.5));
    }
    // Fixed siblings, gaps and padding retain their declared sizes.
    Clay_BeginLayout();
    open_node(100, (Clay_ElementDeclaration){.layout = {
        .sizing = {CLAY_SIZING_FIXED(1280), CLAY_SIZING_FIXED(10)},
        .ceilGrow = true, .padding = {.left=2,.right=2}, .childGap=3}});
    open_node(101, (Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(9),CLAY_SIZING_GROW(0)}});
    Clay__CloseElement();
    for (int i=0;i<3;i++) {
        open_node(102+i,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)}});
        Clay__CloseElement();
    }
    Clay__CloseElement();Clay_EndLayout(0);
    box(Clay_GetElementData(id(101)).boundingBox,2,0,9,10);
    box(Clay_GetElementData(id(102)).boundingBox,14,0,420,10);
    box(Clay_GetElementData(id(103)).boundingBox,437,0,420,10);
    box(Clay_GetElementData(id(104)).boundingBox,860,0,418,10);
    Clay_SetDebugModeEnabled(true);
    Clay_GetCurrentContext()->debugSelectedElementId=100;
    Clay_BeginLayout();
    open_node(100,(Clay_ElementDeclaration){.layout={
        .sizing={CLAY_SIZING_FIXED(100),CLAY_SIZING_FIXED(100)},.ceilGrow=true}});
    Clay__CloseElement();
    Clay_RenderCommandArray inspected=Clay_EndLayout(0);
    bool shown=false;
    for (int i=0;i<inspected.length;i++) {
        Clay_RenderCommand *cmd=&inspected.internalArray[i];
        if (cmd->commandType!=CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
        Clay_StringSlice text=cmd->renderData.text.stringContents;
        if (text.length==13 && !memcmp(text.chars,"Grow Rounding",13)) shown=true;
    }
    assert(shown);
    stop_context(arena);
}

static void test_size_containment(void) {
    void *arena=start_context();
    for (int enabled=0;enabled<2;enabled++) {
        Clay_BeginLayout();
        open_node(100,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(100),CLAY_SIZING_FIXED(100)}});
        open_node(101,(Clay_ElementDeclaration){.layout={
            .sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)},.sizeContain=enabled}});
        open_node(102,(Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_GROW(80),CLAY_SIZING_GROW(150)},
            .backgroundColor={255,0,0,255}});
        Clay__CloseElement();Clay__CloseElement();
        open_node(103,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)}});
        Clay__CloseElement();Clay__CloseElement();
        Clay_RenderCommandArray commands=Clay_EndLayout(0);
        box(Clay_GetElementData(id(101)).boundingBox,0,0,enabled?50:80,enabled?100:150);
        box(Clay_GetElementData(id(102)).boundingBox,0,0,80,150);
        Clay_BoundingBox sibling=Clay_GetElementData(id(103)).boundingBox;
        if (enabled) box(sibling,50,0,50,100);
        else {
            // The unchanged upstream growth loop stops at its epsilon.
            assert(sibling.x==80 && sibling.y==0 && sibling.height==100);
            assert(sibling.width>19.98 && sibling.width<=20);
        }
        assert(commands.length==1 && commands.internalArray[0].boundingBox.width==80);
        assert(element(102)->config.layout.sizing.width.size.minMax.min==80);
        assert(element(102)->config.layout.sizing.height.size.minMax.min==150);
        Clay_SetPointerState((Clay_Vector2){70,120},false);
        assert(Clay_PointerOver(id(102))); // containment adds no clip
    }
    // Own authored bounds and padding still contribute intrinsic size.
    Clay_SetDebugModeEnabled(true);
    Clay_GetCurrentContext()->debugSelectedElementId=101;
    Clay_BeginLayout();
    open_node(100,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(100),CLAY_SIZING_FIXED(100)}});
    open_node(101,(Clay_ElementDeclaration){.layout={
        .sizing={CLAY_SIZING_FIT(20),CLAY_SIZING_FIT(30)},.padding=CLAY_PADDING_ALL(4),.sizeContain=true}});
    open_node(102,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(150)}});
    Clay__CloseElement();Clay__CloseElement();Clay__CloseElement();
    Clay_RenderCommandArray inspected=Clay_EndLayout(0);
    bool shown=false;
    for (int i=0;i<inspected.length;i++) {
        Clay_RenderCommand *cmd=&inspected.internalArray[i];
        if (cmd->commandType!=CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
        Clay_StringSlice text=cmd->renderData.text.stringContents;
        if (text.length==16 && !memcmp(text.chars,"Size Containment",16)) shown=true;
    }
    assert(shown);
    box(Clay_GetElementData(id(101)).boundingBox,0,0,20,30);
    box(Clay_GetElementData(id(102)).boundingBox,4,4,80,150);
    stop_context(arena);
}

int main(void) {
	test_primitives(); puts("ok pinned primitives, mixed identities, structural negative, repeated frames and teardown");
	test_clips(); puts("ok 12 nested clips, three frames");
	test_overlay_rejected(); puts("ok unsupported overlay start/end rejected");
	test_text_area(); puts("ok native text area, glyph paint/owner, wrapping, input and stable attachment identity");
	test_passive_clips(); puts("ok passive clip overflow, offsets, input, state retirement and 120 roots without scroll allocation");
	test_grow_rounding(); puts("ok opt-in native GROW whole-pixel allocation, both axes, bounds, padding and fixed siblings");
	test_size_containment(); puts("ok native size containment, surface minima, independent allocation, bounds and unclipped input");
	render_text_finish();
	return 0;
}
