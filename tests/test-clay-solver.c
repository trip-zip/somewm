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

/* Every size below is checked after the first normal EndLayout, including
 * resizes in both directions. No previous host size or warm-up layout exists. */
static void test_intrinsic_images(void) {
    void *arena = start_context();
    const float heights[] = {24, 48, 12, 24};
    for (int cap = 0; cap < 2; cap++) {
        for (int grow = 0; grow < 2; grow++) {
            for (int frame = 0; frame < 4; frame++) {
                float h = heights[frame], ih = cap && h > 10 ? 10 : h;
                Clay_BeginLayout();
                open_node(100, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_FIXED(400), CLAY_SIZING_FIXED(h)}});
                open_node(101, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_FIT(0), CLAY_SIZING_GROW(0)}});
                open_node(102, (Clay_ElementDeclaration){
                    .layout.sizing = {grow ? CLAY_SIZING_GROW(0, cap ? 20 : 0) : CLAY_SIZING_FIT(0, cap ? 20 : 0),
                        grow ? CLAY_SIZING_GROW(0, cap ? 10 : 0) : CLAY_SIZING_FIT(0, cap ? 10 : 0)},
                    .aspectRatio = {.aspectRatio = 2, .sourceDimensions = {20, 10}},
                    .image.imageData = (void *)1});
                Clay__CloseElement(); Clay__CloseElement();
                open_node(103, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}});
                Clay__OpenTextElement(CLAY_STRING("text"), (Clay_TextElementConfig){.wrapMode = CLAY_TEXT_WRAP_WORDS});
                Clay__CloseElement(); Clay__CloseElement();
                Clay_EndLayout(0);
                box(Clay_GetElementData(id(101)).boundingBox, 0, 0, ih * 2, h);
                box(Clay_GetElementData(id(102)).boundingBox, 0, 0, ih * 2, ih);
                box(Clay_GetElementData(id(103)).boundingBox, ih * 2, 0, 400 - ih * 2, h);
                assert(element(102)->config.layout.sizing.height.size.minMax.max == (cap ? 10 : CLAY__MAXFLOAT));
            }
        }
    }
    for (int fixed = 0; fixed < 4; fixed++) {
        Clay_BeginLayout();
        open_node(100, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_FIT(0), CLAY_SIZING_FIT(0)}});
        open_node(101, (Clay_ElementDeclaration){
            .layout.sizing = {fixed & 1 ? CLAY_SIZING_FIXED(40) : CLAY_SIZING_FIT(0),
                fixed & 2 ? CLAY_SIZING_FIXED(30) : CLAY_SIZING_FIT(0)},
            .aspectRatio = {.aspectRatio = 2, .sourceDimensions = {20,10}},
            .image.imageData = (void *)1});
        Clay__CloseElement(); Clay__CloseElement(); Clay_EndLayout(0);
        float w = fixed == 0 ? 20 : fixed == 2 ? 60 : 40;
        float h = fixed == 0 ? 10 : fixed == 1 ? 20 : 30;
        box(Clay_GetElementData(id(101)).boundingBox, 0, 0, w, h);
        box(Clay_GetElementData(id(100)).boundingBox, 0, 0, w, h);
    }
    for (int frame = 0; frame < 4; frame++) {
        float w = heights[frame];
        Clay_BeginLayout();
        open_node(100, (Clay_ElementDeclaration){.layout = {
            .sizing = {CLAY_SIZING_FIXED(w), CLAY_SIZING_FIXED(400)}, .layoutDirection = CLAY_TOP_TO_BOTTOM}});
        open_node(101, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0)}});
        open_node(102, (Clay_ElementDeclaration){.aspectRatio = {.aspectRatio = 2, .sourceDimensions = {20,10}}, .image.imageData = (void *)1});
        Clay__CloseElement(); Clay__CloseElement();
        open_node(103, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}});
        Clay__CloseElement(); Clay__CloseElement(); Clay_EndLayout(0);
        box(Clay_GetElementData(id(101)).boundingBox, 0, 0, w, w/2);
        box(Clay_GetElementData(id(102)).boundingBox, 0, 0, w, w/2);
        box(Clay_GetElementData(id(103)).boundingBox, 0, w/2, w, 400-w/2);
    }
    Clay_BeginLayout();
    open_node(100, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_FIXED(0), CLAY_SIZING_FIT(0)},
        .aspectRatio = {.aspectRatio = 2, .sourceDimensions = {20,10}}, .image.imageData = (void *)1});
    Clay__CloseElement(); Clay_EndLayout(0);
    box(Clay_GetElementData(id(100)).boundingBox, 0, 0, 0, 0);
    const float sources[][4] = {{20,17,24,29},{17,20,24,21},{2,7,21,6},{13,7,21,39}};
    for (int i = 0; i < 4; i++) {
        Clay_BeginLayout();
        open_node(100, (Clay_ElementDeclaration){.layout.sizing = {CLAY_SIZING_FIXED(400),CLAY_SIZING_FIXED(sources[i][2])}});
        open_node(101, (Clay_ElementDeclaration){.aspectRatio = {.aspectRatio = sources[i][0]/sources[i][1],
            .sourceDimensions = {sources[i][0],sources[i][1]}}, .image.imageData = (void *)1});
        Clay__CloseElement(); Clay__CloseElement(); Clay_EndLayout(0);
        box(Clay_GetElementData(id(101)).boundingBox,0,0,sources[i][3],sources[i][2]);
    }
    stop_context(arena);
}

/* Lower-band child roots must read this solve's owner box. Paint order remains
 * upstream's stable z order, including whole scissor-balanced root ranges. */
static void test_root_position_and_paint_order(void) {
    for (int flow = 0; flow < 2; flow++) {
        void *arena = start_context();
        Clay_SetLayoutDimensions((Clay_Dimensions){1280,720});
        const int widths[] = {80,80,160,40};
        for (int frame = 0; frame < 4; frame++) {
            int x = flow ? 30 : frame ? 100 : 50, y = 40;
            Clay_BeginLayout();
            open_node(100, (Clay_ElementDeclaration){.layout = {
                .sizing = {CLAY_SIZING_FIXED(1280),CLAY_SIZING_FIXED(720)},
                .padding = {30,0,40,0}},
                .clip = {.horizontal=true,.vertical=true,.passive=true}});
            open_node(101, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIT(0),CLAY_SIZING_FIT(0)},
                .backgroundColor = {255,0,0,255},
                .floating = {.attachTo=flow ? CLAY_ATTACH_TO_NONE : CLAY_ATTACH_TO_PARENT,
                    .offset={x,y},.zIndex=20,.clipTo=CLAY_CLIP_TO_NONE},
                .clip = {.horizontal=true,.vertical=true,.passive=true}});
            open_node(102, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)},
                .floating = {.attachTo=CLAY_ATTACH_TO_PARENT,.offset={-15,-15},
                    .expand={12,12},.zIndex=flow ? -1 : 19,
                    .pointerCaptureMode=CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
                    .clipTo=CLAY_CLIP_TO_NONE},
                .custom.customData=(void *)1});
            Clay__CloseElement();
            open_node(103, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIXED(widths[frame]),CLAY_SIZING_FIXED(60)},
                .backgroundColor = {0,255,0,255}});
            Clay__CloseElement();
            open_node(104, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIXED(30),CLAY_SIZING_FIXED(30)},
                .floating = {.attachTo=CLAY_ATTACH_TO_PARENT,.offset={7,7},.zIndex=21,
                    .clipTo=CLAY_CLIP_TO_ATTACHED_PARENT},
                .backgroundColor = {0,0,255,255}});
            open_node(105, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIXED(10),CLAY_SIZING_FIXED(10)},
                .floating = {.attachTo=CLAY_ATTACH_TO_PARENT,.offset={3,3},.zIndex=22,
                    .clipTo=CLAY_CLIP_TO_ATTACHED_PARENT},
                .backgroundColor = {255,255,0,255}});
            Clay__CloseElement(); Clay__CloseElement();
            /* Same band as the owner: this later root still paints above it. */
            open_node(107, (Clay_ElementDeclaration){
                .layout.sizing = {CLAY_SIZING_FIXED(30),CLAY_SIZING_FIXED(30)},
                .floating = {.attachTo=CLAY_ATTACH_TO_PARENT,.offset={0,0},.zIndex=20},
                .backgroundColor = {255,0,255,255}});
            Clay__CloseElement(); Clay__CloseElement(); Clay__CloseElement();
            Clay_RenderCommandArray cmds = Clay_EndLayout(0);
            box(Clay_GetElementData(id(101)).boundingBox,x,y,widths[frame],60);
            box(Clay_GetElementData(id(102)).boundingBox,x-27,y-27,widths[frame]+24,84);
            box(Clay_GetElementData(id(104)).boundingBox,x+7,y+7,30,30);
            box(Clay_GetElementData(id(105)).boundingBox,x+10,y+10,10,10);
            int painted[] = {102,101,103,107,104,105}, next = 0;
            for (int i = 0; i < cmds.length; i++) {
                Clay_RenderCommand *cmd = &cmds.internalArray[i];
                if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE &&
                    cmd->commandType != CLAY_RENDER_COMMAND_TYPE_CUSTOM) continue;
                assert(next < 6 && cmd->id == (uint32_t)painted[next++]);
            }
            assert(next == 6);
            Clay_Context *ctx = Clay_GetCurrentContext();
            int total = 0, last_z = -32768;
            for (int i = 0; i < ctx->layoutElementTreeRoots.length; i++) {
                Clay__LayoutElementTreeRoot *r = &ctx->layoutElementTreeRoots.internalArray[i];
                assert(r->zIndex >= last_z);
                last_z = r->zIndex;
                assert(r->commandStart == total);
                int depth = 0;
                for (int j = 0; j < r->commandCount; j++) {
                    Clay_RenderCommand *cmd = &cmds.internalArray[total++];
                    if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) depth++;
                    if (cmd->commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END) depth--;
                    assert(depth >= 0);
                }
                assert(depth == 0);
            }
            assert(total == cmds.length);
            Clay_SetPointerState((Clay_Vector2){x+11,y+11},false);
            assert(Clay_PointerOver(id(105)));
            assert(!Clay_PointerOver(id(107)));
            /* Exercise the existing transition path's second traversal, whose
             * input roots are already sorted, without starting another layout. */
            Clay__CalculateFinalLayout(0,true,true);
            box(Clay_GetElementData(id(102)).boundingBox,x-27,y-27,widths[frame]+24,84);
        }
        stop_context(arena);
    }
}

/* Host content and attached overflow share the native padded clip. The
 * border retains its own command metadata and paints outside that scope. */
static void test_padding_clip(void) {
    void *arena = start_context();
    int host;
    for (int frame = 0; frame < 3; frame++) {
        float width = frame == 1 ? 60 : 40;
        Clay_BeginLayout();
        open_node(301, (Clay_ElementDeclaration){
            .layout = {.sizing={CLAY_SIZING_FIXED(width),CLAY_SIZING_FIXED(30)},
                .padding={2,3,4,5}},
            .border={.color={255,0,0,255},.width={1,1,1,1,0}},
            .userData=&host});
        open_node(304, (Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)},
            .clip={.horizontal=true,.vertical=true,.passive=true},
            .userData=arena});
        open_node(302, (Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(50)},
            .backgroundColor={0,0,255,255}});
        Clay__CloseElement();
        open_node(303, (Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(50)},
            .floating={.attachTo=CLAY_ATTACH_TO_PARENT,.zIndex=1,
                .clipTo=CLAY_CLIP_TO_ATTACHED_PARENT,
                .pointerCaptureMode=CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH},
            .backgroundColor={0,255,0,255}});
        Clay__CloseElement(); Clay__CloseElement(); Clay__CloseElement();
        Clay_RenderCommandArray commands = Clay_EndLayout(0);
        int depth=0, starts=0, borders=0;
        for (int i=0;i<commands.length;i++) {
            Clay_RenderCommand *cmd=&commands.internalArray[i];
            if (cmd->commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) {
                box(cmd->boundingBox,2,4,width-5,21);
                if (starts++ == 0) assert(cmd->userData==arena);
                depth++;
            } else if (cmd->commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_END) {
                assert(--depth==0);
            } else if (cmd->commandType==CLAY_RENDER_COMMAND_TYPE_BORDER) {
                assert(depth==0 && cmd->userData==&host);
                box(cmd->boundingBox,0,0,width,30);
                borders++;
            } else assert(depth==1);
        }
        assert(depth==0 && starts==2 && borders==1);
        assert(Clay_GetCurrentContext()->scrollContainerDatas.length==0);
        Clay_SetPointerState((Clay_Vector2){3,5},false);
        assert(Clay_PointerOver(id(302)) && Clay_PointerOver(id(303)));
        Clay_SetPointerState((Clay_Vector2){width-2,5},false);
        assert(!Clay_PointerOver(id(302)) && !Clay_PointerOver(id(303)));
        Clay_SetPointerState((Clay_Vector2){3,26},false);
        assert(!Clay_PointerOver(id(302)) && !Clay_PointerOver(id(303)));
    }
    stop_context(arena);
}

static void test_output_backdrop(void) {
    void *arena = start_context();
    for (int frame = 0; frame < 3; frame++) {
        Clay_BeginLayout();
        open_node(201, (Clay_ElementDeclaration){
            .layout.sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(160)},
            .backgroundBeforeRoots = true,
            .backgroundColor = frame == 1 ? (Clay_Color){0} : (Clay_Color){255,0,0,255},
            .image.imageData = frame > 0 ? arena : NULL});
        open_node(202, (Clay_ElementDeclaration){
            .layout.sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(20)},
            .backgroundColor = {0,255,0,255}});
        Clay__CloseElement();
        open_node(203, (Clay_ElementDeclaration){
            .layout.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)},
            .floating = {.attachTo=CLAY_ATTACH_TO_PARENT, .zIndex=-4},
            .backgroundColor = {0,0,255,255}});
        Clay__CloseElement(); Clay__CloseElement();
        Clay_RenderCommandArray commands = Clay_EndLayout(0);
        int underlay = frame == 2;
        assert(commands.length == 3 + underlay);
        assert(commands.internalArray[0].id == 201);
        assert(commands.internalArray[0].commandType == (frame == 1
            ? CLAY_RENDER_COMMAND_TYPE_IMAGE : CLAY_RENDER_COMMAND_TYPE_RECTANGLE));
        if (underlay) {
            assert(commands.internalArray[1].id == 201);
            assert(commands.internalArray[1].commandType == CLAY_RENDER_COMMAND_TYPE_IMAGE);
            assert(commands.internalArray[1].renderData.image.backgroundColor.a == 0);
        }
        assert(commands.internalArray[1+underlay].id == 203);
        assert(commands.internalArray[2+underlay].id == 202);
        assert(Clay_GetCurrentContext()->layoutElementTreeRoots.length == 2);
        box(commands.internalArray[0].boundingBox,0,0,200,160);
        /* Re-enter the transition command traversal with already sorted roots. */
        Clay__CalculateFinalLayout(0,true,true);
        assert(Clay_GetCurrentContext()->renderCommands.length == 3 + underlay);
        assert(Clay_GetCurrentContext()->renderCommands.internalArray[0].id == 201);
    }
    stop_context(arena);
}

static jmp_buf capacity_jump;
static Clay_ErrorType capacity_error;
static void capacity_handler(Clay_ErrorData error) {
    capacity_error = error.errorType;
    switch (error.errorType) {
    case CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_ARRAY_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED:
    case CLAY_ERROR_TYPE_TEXT_MEASUREMENT_CAPACITY_EXCEEDED:
        longjmp(capacity_jump, 1);
    default: clay_error(error);
    }
}
static void capacity_leaves(int first, int count) {
    Clay_BeginLayout();
    for (int i = 0; i < count; i++) {
        open_node(first+i, (Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_FIXED(10),CLAY_SIZING_FIXED(10)},
            .backgroundColor={255,0,0,255}});
        Clay__CloseElement();
    }
    Clay_EndLayout(0);
}
static void capacity_transitions(void) {
    Clay_BeginLayout();
    for (int i=0;i<201;i++) {
        open_node(100+i,(Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_FIXED(10),CLAY_SIZING_FIXED(10)},
            .transition={.handler=Clay_EaseOut,.duration=1,.properties=CLAY_TRANSITION_PROPERTY_WIDTH}});
        Clay__CloseElement();
    }
}
static bool capacity_try(int first, int count, bool transitions) {
    if (setjmp(capacity_jump)) return true;
    if (transitions) capacity_transitions();
    else capacity_leaves(first,count);
    return false;
}
static void allocation_handler(Clay_ErrorData error) {
    assert(error.errorType == CLAY_ERROR_TYPE_ARENA_CAPACITY_EXCEEDED);
    capacity_error = error.errorType;
}
static void test_capacity_recovery(void) {
    Clay_SetMaxElementCount(128);
    void *arena = start_context();
    Clay_Context *context=Clay_GetCurrentContext();
    context->errorHandler.errorHandlerFunction=capacity_handler;
    for (int frame=0; frame<20; frame++) {
        capacity_leaves(1000+100*frame,63);
        assert(!context->booleanWarnings.hashMapCapacityExceeded);
    }
    assert(context->layoutElementsHashMapInternal.length==127);
    assert(context->layoutElementsHashMapFreeList.length==63);
    Clay_SetPointerState((Clay_Vector2){5,5},false);
    assert(Clay_PointerOver(id(2900)));
    size_t size=Clay__StateSize();
    void *saved=malloc(size);assert(saved);
    assert(!Clay__StateSave(saved,size-1));
    assert(Clay__StateSave(saved,size));
    assert(capacity_try(5000,100,false));
    assert(capacity_error==CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED);
    Clay__StateRestore(saved);
    assert(context==Clay_GetCurrentContext());
    Clay_SetPointerState((Clay_Vector2){5,5},false);
    assert(Clay_PointerOver(id(2900)) && !Clay_PointerOver(id(5000)));
    capacity_leaves(2900,1);
    assert(context->layoutElements.length==2);
    assert(Clay_GetElementData(id(2900)).found);
    free(saved);
    stop_context(arena);

    Clay_SetMaxElementCount(64);
    arena=start_context();
    context=Clay_GetCurrentContext();
    context->errorHandler.errorHandlerFunction=capacity_handler;
    assert(capacity_try(100,100,false));
    assert(capacity_error==CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED);
    assert(context->booleanWarnings.maxElementsExceeded);
    stop_context(arena);

    Clay_SetMaxElementCount(32768);
    arena=start_context();
    context=Clay_GetCurrentContext();
    context->errorHandler.errorHandlerFunction=capacity_handler;
    assert(capacity_try(0,0,true));
    assert(capacity_error==CLAY_ERROR_TYPE_ARRAY_CAPACITY_EXCEEDED);
    assert(context->transitionDatas.length==200);
    Clay_ErrorHandler handler={allocation_handler,NULL};
    assert(!Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(Clay_MinMemorySize(),NULL),
        (Clay_Dimensions){200,160},handler));
    assert(Clay_GetCurrentContext()==context);
    assert(!Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(sizeof(Clay_Context),arena),
        (Clay_Dimensions){200,160},handler));
    assert(Clay_GetCurrentContext()==context);
    stop_context(arena);
    Clay_SetMaxElementCount(8192);
}
static Clay_TransitionData capacity_exit(Clay_TransitionData data, Clay_TransitionProperty properties) {
    (void)properties;
    data.boundingBox.width=0;
    return data;
}
static void capacity_scroll_transition(float width, bool show, const char *text, float dt) {
    Clay_BeginLayout();
    open_node(71,(Clay_ElementDeclaration){
        .layout={.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(60)},.layoutDirection=CLAY_TOP_TO_BOTTOM},
        .clip={.vertical=true,.childOffset=Clay_GetScrollOffset()}});
    open_node(72,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(60),CLAY_SIZING_FIXED(200)}});
    CLAY_TEXT(((Clay_String){.length=(int)strlen(text),.chars=text}),CLAY_TEXT_CONFIG({.fontSize=12}));
    Clay__CloseElement();
    Clay__CloseElement();
    if(show) {
        open_node(73,(Clay_ElementDeclaration){
            .layout.sizing={CLAY_SIZING_FIXED(width),CLAY_SIZING_FIXED(60)},
            .backgroundColor={255,0,0,255},
            .transition={.handler=Clay_EaseOut,.duration=1,.properties=CLAY_TRANSITION_PROPERTY_WIDTH,
                .exit.setFinalState=capacity_exit}});
        Clay__CloseElement();
    }
    Clay_EndLayout(dt);
}
static void test_capacity_persistent_state(void) {
    Clay_SetMaxElementCount(32768);
    void *arena=start_context();
    Clay_Context *c=Clay_GetCurrentContext();
    c->errorHandler.errorHandlerFunction=capacity_handler;
    char *old=strdup("retained text"), *pending=strdup("pending text");
    assert(old && pending);
    capacity_scroll_transition(60,true,old,0);
    capacity_scroll_transition(60,true,old,0);
    capacity_scroll_transition(60,true,old,0);
    Clay_ScrollContainerData scroll=Clay_GetScrollContainerData(id(71));
    assert(scroll.found);
    scroll.scrollPosition->y=-40;
    capacity_scroll_transition(120,true,old,.1f);
    capacity_scroll_transition(120,true,old,.1f);
    Clay_ElementData before=Clay_GetElementData(id(73));
    assert(before.found && before.boundingBox.width>60 && before.boundingBox.width<120);
    size_t size=Clay__StateSize();void *saved=malloc(size);assert(saved);
    assert(Clay__StateSave(saved,size));
    capacity_scroll_transition(180,true,pending,.1f);
    assert(capacity_try(1000,32768,false));
    Clay__StateRestore(saved);
    assert(Clay_GetElementData(id(73)).boundingBox.width==before.boundingBox.width);
    assert(Clay_GetScrollContainerData(id(71)).scrollPosition->y==-40);
    assert(Clay__ReferencesMemory(old,strlen(old),UINTPTR_MAX));
    assert(!Clay__ReferencesMemory(pending,strlen(pending),UINTPTR_MAX));
    free(pending);
    capacity_scroll_transition(120,false,old,.1f);
    assert(c->exitingElementsLength>0 && c->transitionDatas.length==1);
    free(saved);size=Clay__StateSize();saved=malloc(size);assert(saved);
    assert(Clay__StateSave(saved,size));
    int tails=c->exitingElementsLength;
    assert(capacity_try(1000,32768,false));
    Clay__StateRestore(saved);
    assert(c->exitingElementsLength==tails);
    assert(Clay_GetScrollContainerData(id(71)).scrollPosition->y==-40);
    for(int i=0;i<20;i++) capacity_scroll_transition(120,false,old,.1f);
    assert(c->transitionDatas.length==0 && c->exitingElementsLength==0);
    free(saved);free(old);stop_context(arena);
    Clay_SetMaxElementCount(8192);
}

static void inspector_layout(void) {
    Clay_BeginLayout();
    open_node(700,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_GROW(0),CLAY_SIZING_GROW(0)}});
    for(int i=0;i<3000;i++){
        open_node(10000+i,(Clay_ElementDeclaration){.layout.sizing={CLAY_SIZING_FIXED(1),CLAY_SIZING_FIXED(1)}});
        Clay__CloseElement();
    }
    Clay__CloseElement();
    Clay_EndLayout(0);
}
static void test_inspector_capacity(void) {
    Clay_SetMaxElementCount(32768);
    void *arena=start_context();
    Clay_Context *c=Clay_GetCurrentContext();
    Clay_SetLayoutDimensions((Clay_Dimensions){1280,720});
    Clay_SetDebugModeEnabled(true);
    inspector_layout();
    Clay_ElementId pane=CLAY_ID("Clay__DebugViewOuterScrollPane");
    Clay_ScrollContainerData data=Clay_GetScrollContainerData(pane);
    assert(data.found && data.contentDimensions.height==3002*30);
    assert(c->layoutElements.length-3002<512);
    assert(!Clay_GetElementData(CLAY_IDI("Clay__DebugView_ElementOuter",12999)).found);
    data.scrollPosition->y=-(data.contentDimensions.height-data.scrollContainerDimensions.height);
    inspector_layout();
    assert(c->layoutElements.length-3002<512);
    Clay_ElementData last=Clay_GetElementData(CLAY_IDI("Clay__DebugView_ElementOuter",12999));
    assert(last.found);
    Clay_SetPointerState((Clay_Vector2){last.boundingBox.x+30,last.boundingBox.y+15},false);
    Clay_SetPointerState((Clay_Vector2){last.boundingBox.x+30,last.boundingBox.y+15},true);
    inspector_layout();
    assert(c->debugSelectedElementId==12999);
    data=Clay_GetScrollContainerData(pane);data.scrollPosition->y=0;
    Clay_SetPointerState((Clay_Vector2){-1,-1},false);
    inspector_layout();
    assert(c->debugSelectedElementId==12999);
    Clay_ElementData collapse=Clay_GetElementData(CLAY_IDI("Clay__DebugView_CollapseElement",700));
    assert(collapse.found);
    Clay_SetPointerState((Clay_Vector2){collapse.boundingBox.x+8,collapse.boundingBox.y+8},true);
    inspector_layout();
    Clay_SetPointerState((Clay_Vector2){-1,-1},false);
    inspector_layout();
    data=Clay_GetScrollContainerData(pane);
    assert(data.contentDimensions.height<3002*30);
    assert(Clay__GetHashMapItem(700)->debugData.collapsed);
    collapse=Clay_GetElementData(CLAY_IDI("Clay__DebugView_CollapseElement",700));
    Clay_SetPointerState((Clay_Vector2){collapse.boundingBox.x+8,collapse.boundingBox.y+8},true);
    inspector_layout();
    Clay_SetPointerState((Clay_Vector2){-1,-1},false);
    inspector_layout();
    data=Clay_GetScrollContainerData(pane);
    assert(data.contentDimensions.height==3002*30);
    assert(!Clay__GetHashMapItem(700)->debugData.collapsed);
    /* Clicking the collapse control also selects its owning row. */
    assert(c->debugSelectedElementId==700);
    stop_context(arena);
    Clay_SetMaxElementCount(8192);
}

int main(void) {
    test_capacity_persistent_state(); puts("ok intermediate rollback, native text lifetime, scrolling and retained exits");
    test_capacity_recovery(); puts("ok capacity rollback, map reuse, bounded transitions and allocation rejection");
    test_inspector_capacity(); puts("ok bounded inspector rows, full extent, selection and collapse");
	test_padding_clip(); puts("ok inner passive host clip, flow/floating input, resize, border order and independent metadata without scroll state");
	test_output_backdrop(); puts("ok OUTPUT color/image before negative-band roots, flow children above them, repeated traversal");
	test_root_position_and_paint_order(); puts("ok root first-open/move/FIT grow/shrink/in-flow, stable paint and pointer order, nested scissor ranges");
	test_primitives(); puts("ok pinned primitives, mixed identities, structural negative, repeated frames and teardown");
	test_clips(); puts("ok 12 nested clips, three frames");
	test_overlay_rejected(); puts("ok unsupported overlay start/end rejected");
	test_text_area(); puts("ok native text area, glyph paint/owner, wrapping, input and stable attachment identity");
	test_passive_clips(); puts("ok passive clip overflow, offsets, input, state retirement and 120 roots without scroll allocation");
	test_size_containment(); puts("ok native size containment, surface minima, independent allocation, bounds and unclipped input");
	test_intrinsic_images(); puts("ok intrinsic image first solve, resize, caps, FIT/GROW/FIXED and independent text allocation");
	render_text_finish();
	return 0;
}
