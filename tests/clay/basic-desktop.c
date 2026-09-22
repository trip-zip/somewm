#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CLAY_IMPLEMENTATION
#include <clay.h>

/* Standalone declarations: no compositor, measurement pass, or solved input. */
typedef struct { float width, height, bar, ratio, tags; } Inputs;
static const Inputs variants[] = {
    {1200, 800, 28, .5f, 112}, {1200, 800, 40, .5f, 112},
    {1200, 800, 28, .6f, 112}, {1200, 800, 28, .5f, 240},
    {1440, 900, 28, .5f, 112},
};
static const char *cases[] = {"baseline", "bar-height", "split", "tags-width", "output-size"};
typedef struct {
    const char *name, *parent;
    Clay_ElementDeclaration declaration;
} Record;
static Record records[64];
static int count, errors;
static Clay_ElementId id(const char *name) {
    return Clay_GetElementId((Clay_String){.length = (int32_t)strlen(name), .chars = name});
}
static Clay_ElementDeclaration record(const char *name, const char *parent,
                                      Clay_ElementDeclaration declaration) {
    if (count == 64) abort();
    records[count++] = (Record){name, parent, declaration};
    return declaration;
}
#define NODE(name, parent, ...) CLAY(id(name), record(name, parent, (Clay_ElementDeclaration)__VA_ARGS__))
#define GROW CLAY_SIZING_GROW(0)
#define FIX(n) CLAY_SIZING_FIXED(n)
#define FILL .sizing = {GROW, GROW}
#define PAINT .backgroundColor = {80, 100, 120, 255}
static Clay_FloatingElementConfig attached(const char *target, int16_t band) {
    bool found = false;
    for (int i = 0; i < count; ++i) found |= strcmp(records[i].name, target) == 0;
    if (!found) { fprintf(stderr, "Undeclared attachment target: %s\n", target); abort(); }
    return (Clay_FloatingElementConfig){
        .parentId = id(target).id, .zIndex = band,
        .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        .attachPoints = {CLAY_ATTACH_POINT_LEFT_TOP, CLAY_ATTACH_POINT_LEFT_TOP},
        .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_CAPTURE,
    };
}
static Clay_RenderCommandArray declare(Inputs in, bool external_fixed) {
    count = 0;
    Clay_SetLayoutDimensions((Clay_Dimensions){in.width, in.height});
    Clay_BeginLayout();
    NODE("OUTPUT", "-", {.layout = {.sizing = {FIX(in.width), FIX(in.height)},
        .layoutDirection = CLAY_TOP_TO_BOTTOM}, PAINT}) {
        NODE("SCREEN", "OUTPUT", {.layout = {FILL, .layoutDirection = CLAY_TOP_TO_BOTTOM}}) {
            NODE("BAR_SLOT", "SCREEN", {.layout = {.sizing = {GROW, FIX(in.bar)}}}) {}
            NODE("WORKAREA", "SCREEN", {.layout = {FILL}}) {
                NODE("GHOSTTY_SLOT", "WORKAREA", {.layout = {
                    /* Deliberately forbidden, geometry-equivalent test variant. */
                    .sizing = {external_fixed ? FIX(in.width * in.ratio) :
                        CLAY_SIZING_PERCENT(in.ratio), GROW}}}) {}
                NODE("FIREFOX_SLOT", "WORKAREA", {.layout = {FILL}}) {}
            }
        }
    }
    NODE("GHOSTTY", "-", {.layout = {FILL, .layoutDirection = CLAY_TOP_TO_BOTTOM},
        .floating = attached("GHOSTTY_SLOT", 60)}) {
        NODE("GHOSTTY_TITLEBAR", "GHOSTTY", {.layout = {.sizing = {GROW, FIX(24)}}, PAINT}) {
            NODE("GHOSTTY_ICON", "GHOSTTY_TITLEBAR", {.layout = {.sizing = {FIX(24), FIX(24)}}, PAINT}) {}
            NODE("GHOSTTY_TITLE_SPACE", "GHOSTTY_TITLEBAR", {.layout = {FILL}}) {}
            NODE("GHOSTTY_CLOSE", "GHOSTTY_TITLEBAR", {.layout = {.sizing = {FIX(24), FIX(24)}}, PAINT}) {}
        }
        NODE("GHOSTTY_SURFACE", "GHOSTTY", {.layout = {FILL}, .custom = {.customData = "ghostty"}}) {}
    }
    NODE("FIREFOX", "-", {.layout = {FILL, .layoutDirection = CLAY_TOP_TO_BOTTOM},
        .floating = attached("FIREFOX_SLOT", 60)}) {
        NODE("FIREFOX_TITLEBAR", "FIREFOX", {.layout = {.sizing = {GROW, FIX(24)}}, PAINT}) {
            NODE("FIREFOX_ICON", "FIREFOX_TITLEBAR", {.layout = {.sizing = {FIX(24), FIX(24)}}, PAINT}) {}
            NODE("FIREFOX_TITLE_SPACE", "FIREFOX_TITLEBAR", {.layout = {FILL}}) {}
            NODE("FIREFOX_CLOSE", "FIREFOX_TITLEBAR", {.layout = {.sizing = {FIX(24), FIX(24)}}, PAINT}) {}
        }
        NODE("FIREFOX_SURFACE", "FIREFOX", {.layout = {FILL}, .custom = {.customData = "firefox"}}) {}
    }
    /* Accepted D01/D02: non-ontop wibar below ordinary clients. Reservation
     * still comes from BAR_SLOT; no numeric allocation changes. */
    NODE("WIBAR", "-", {.layout = {FILL}, .floating = attached("BAR_SLOT", 45), PAINT}) {
        NODE("BAR_LEFT", "WIBAR", {.layout = {FILL, .childGap = 8,
            .childAlignment = {.x = CLAY_ALIGN_X_LEFT, .y = CLAY_ALIGN_Y_CENTER}}}) {
            NODE("MENU", "BAR_LEFT", {.layout = {.sizing = {FIX(40), FIX(20)}}, PAINT}) {}
            NODE("TAGS", "BAR_LEFT", {.layout = {.sizing = {FIX(in.tags), FIX(20)}}, PAINT}) {}
        }
        NODE("BAR_CENTRE", "WIBAR", {.layout = {.sizing = {CLAY_SIZING_FIT(0), GROW},
            .childAlignment = {.x = CLAY_ALIGN_X_CENTER, .y = CLAY_ALIGN_Y_CENTER}}}) {
            NODE("CLOCK", "BAR_CENTRE", {.layout = {.sizing = {FIX(120), FIX(20)}}, PAINT}) {}
        }
        NODE("BAR_RIGHT", "WIBAR", {.layout = {FILL,
            .childAlignment = {.x = CLAY_ALIGN_X_RIGHT, .y = CLAY_ALIGN_Y_CENTER}}}) {
            NODE("STATUS", "BAR_RIGHT", {.layout = {.sizing = {FIX(80), FIX(20)}}, PAINT}) {}
        }
    }
    return Clay_EndLayout(0);
}
static void on_error(Clay_ErrorData error) {
    fprintf(stderr, "Clay error: %.*s\n", error.errorText.length, error.errorText.chars);
    ++errors;
}
static void axis(Clay_SizingAxis a) {
    switch (a.type) {
    case CLAY__SIZING_TYPE_FIXED: fprintf(stderr, "fixed(%g)", a.size.minMax.min); break;
    case CLAY__SIZING_TYPE_PERCENT: fprintf(stderr, "percent(%g)", a.size.percent); break;
    default: fprintf(stderr, "%s(min=%g,max=%g)", a.type == CLAY__SIZING_TYPE_GROW ? "grow" : "fit",
                     a.size.minMax.min, a.size.minMax.max); break;
    }
}
static void dump_constraints(void) {
    const char *align_x[] = {"left", "right", "centre"};
    const char *align_y[] = {"top", "bottom", "centre"};
    fputs("Declared constraints (padding/offsets zero; transitions/scroll disabled):\n", stderr);
    for (int i = 0; i < count; ++i) {
        Record r = records[i];
        fprintf(stderr, "  %s parent=%s width=", r.name, r.parent);
        axis(r.declaration.layout.sizing.width); fputs(" height=", stderr);
        axis(r.declaration.layout.sizing.height);
        fprintf(stderr, " flow=%s gap=%u align=(%s,%s)",
                r.declaration.layout.layoutDirection == CLAY_TOP_TO_BOTTOM ? "vertical" : "horizontal",
                r.declaration.layout.childGap, align_x[r.declaration.layout.childAlignment.x],
                align_y[r.declaration.layout.childAlignment.y]);
        if (r.declaration.floating.attachTo) {
            const char *target = "MISSING";
            for (int j = 0; j < count; ++j)
                if (id(records[j].name).id == r.declaration.floating.parentId) target = records[j].name;
            fprintf(stderr, " attach=%s top-left/top-left capture band=%d", target, r.declaration.floating.zIndex);
        }
        fputc('\n', stderr);
    }
}

/* Independent reference oracle, never populated from NODE/Record or solved
 * boxes. Read the pin's actual current-frame elements and child indices: the
 * caller-supplied diagnostic parent strings cannot establish containment.
 * Private inspection stays in this standalone binary; the header is pristine. */
typedef enum { EXPECT_GROW, EXPECT_FIT, EXPECT_FIXED, EXPECT_PERCENT } AxisKind;
typedef struct { AxisKind kind; float value; } ExpectedAxis;
typedef struct {
    const char *name, *parent, *target;
    ExpectedAxis width, height;
    Clay_LayoutDirection direction;
    uint16_t gap;
    Clay_LayoutAlignmentX align_x;
    Clay_LayoutAlignmentY align_y;
    int16_t band;
} ExpectedNode;
enum { BAD_SPLIT = 1, BAD_STRUCTURE = 2 };
static uint32_t stable_ids[26];

static bool axis_matches(Clay_SizingAxis actual, ExpectedAxis expected) {
    switch (expected.kind) {
    case EXPECT_PERCENT:
        return actual.type == CLAY__SIZING_TYPE_PERCENT && actual.size.percent == expected.value;
    case EXPECT_FIXED:
        return actual.type == CLAY__SIZING_TYPE_FIXED &&
            actual.size.minMax.min == expected.value && actual.size.minMax.max == expected.value;
    default:
        /* Clay normalises unspecified maxima when it closes each element. */
        return actual.type == (expected.kind == EXPECT_GROW ? CLAY__SIZING_TYPE_GROW : CLAY__SIZING_TYPE_FIT) &&
            actual.size.minMax.min == 0 && actual.size.minMax.max == CLAY__MAXFLOAT;
    }
}
static unsigned structure(Inputs in) {
    const ExpectedNode expected[] = {
        {.name="OUTPUT", .width={EXPECT_FIXED,in.width}, .height={EXPECT_FIXED,in.height}, .direction=CLAY_TOP_TO_BOTTOM},
        {.name="SCREEN", .parent="OUTPUT", .direction=CLAY_TOP_TO_BOTTOM},
        {.name="BAR_SLOT", .parent="SCREEN", .height={EXPECT_FIXED,in.bar}},
        {.name="WORKAREA", .parent="SCREEN"},
        {.name="GHOSTTY_SLOT", .parent="WORKAREA", .width={EXPECT_PERCENT,in.ratio}},
        {.name="FIREFOX_SLOT", .parent="WORKAREA"},
        {.name="GHOSTTY", .target="GHOSTTY_SLOT", .direction=CLAY_TOP_TO_BOTTOM, .band=60},
        {.name="GHOSTTY_TITLEBAR", .parent="GHOSTTY", .height={EXPECT_FIXED,24}},
        {.name="GHOSTTY_ICON", .parent="GHOSTTY_TITLEBAR", .width={EXPECT_FIXED,24}, .height={EXPECT_FIXED,24}},
        {.name="GHOSTTY_TITLE_SPACE", .parent="GHOSTTY_TITLEBAR"},
        {.name="GHOSTTY_CLOSE", .parent="GHOSTTY_TITLEBAR", .width={EXPECT_FIXED,24}, .height={EXPECT_FIXED,24}},
        {.name="GHOSTTY_SURFACE", .parent="GHOSTTY"},
        {.name="FIREFOX", .target="FIREFOX_SLOT", .direction=CLAY_TOP_TO_BOTTOM, .band=60},
        {.name="FIREFOX_TITLEBAR", .parent="FIREFOX", .height={EXPECT_FIXED,24}},
        {.name="FIREFOX_ICON", .parent="FIREFOX_TITLEBAR", .width={EXPECT_FIXED,24}, .height={EXPECT_FIXED,24}},
        {.name="FIREFOX_TITLE_SPACE", .parent="FIREFOX_TITLEBAR"},
        {.name="FIREFOX_CLOSE", .parent="FIREFOX_TITLEBAR", .width={EXPECT_FIXED,24}, .height={EXPECT_FIXED,24}},
        {.name="FIREFOX_SURFACE", .parent="FIREFOX"},
        {.name="WIBAR", .target="BAR_SLOT", .band=45},
        {.name="BAR_LEFT", .parent="WIBAR", .gap=8, .align_y=CLAY_ALIGN_Y_CENTER},
        {.name="MENU", .parent="BAR_LEFT", .width={EXPECT_FIXED,40}, .height={EXPECT_FIXED,20}},
        {.name="TAGS", .parent="BAR_LEFT", .width={EXPECT_FIXED,in.tags}, .height={EXPECT_FIXED,20}},
        {.name="BAR_CENTRE", .parent="WIBAR", .width={EXPECT_FIT,0}, .align_x=CLAY_ALIGN_X_CENTER, .align_y=CLAY_ALIGN_Y_CENTER},
        {.name="CLOCK", .parent="BAR_CENTRE", .width={EXPECT_FIXED,120}, .height={EXPECT_FIXED,20}},
        {.name="BAR_RIGHT", .parent="WIBAR", .align_x=CLAY_ALIGN_X_RIGHT, .align_y=CLAY_ALIGN_Y_CENTER},
        {.name="STATUS", .parent="BAR_RIGHT", .width={EXPECT_FIXED,80}, .height={EXPECT_FIXED,20}},
    };
    Clay_Context *ctx = Clay_GetCurrentContext();
    const int n = sizeof expected / sizeof *expected;
    unsigned faults = 0;
#define REQUIRE(condition, fault, name, field) do { \
    if (!(condition)) { \
        fprintf(stderr, "Structure: %s %s mismatch\n", name, field); \
        faults |= fault; \
    } \
} while (0)
    /* One implicit Clay container plus exactly the 26 named declarations.
     * Array order is emission order, independent of sorted floating roots. */
    REQUIRE(ctx->layoutElements.length == n + 1, BAD_STRUCTURE, "desktop", "element count");
    if (ctx->layoutElements.length != n + 1) return faults;
    Clay_LayoutElement *elements = ctx->layoutElements.internalArray;
    REQUIRE(elements[0].children.length == 1 && elements[0].children.elements[0] == 1 &&
        elements[0].floatingChildrenCount == 3, BAD_STRUCTURE, "desktop", "root containment");
    for (int i = 0; i < n; ++i) {
        const ExpectedNode *e = &expected[i];
        Clay_LayoutElement *a = &elements[i + 1];
        Clay_LayoutConfig l = a->config.layout;
        REQUIRE(a->id == id(e->name).id, BAD_STRUCTURE, e->name, "identity/declaration order");
        if (!stable_ids[i]) stable_ids[i] = a->id;
        REQUIRE(a->id == stable_ids[i], BAD_STRUCTURE, e->name, "stable identity");
        for (int j = 0; j <= i; ++j)
            REQUIRE(a->id != elements[j].id, BAD_STRUCTURE, e->name, "duplicate identity");
        REQUIRE(!a->isTextElement && !a->exiting && a->floatingChildrenCount == 0,
            BAD_STRUCTURE, e->name, "element kind");
        REQUIRE(axis_matches(l.sizing.width, e->width),
            strcmp(e->name, "GHOSTTY_SLOT") == 0 ? BAD_SPLIT : BAD_STRUCTURE, e->name, "width");
        REQUIRE(axis_matches(l.sizing.height, e->height), BAD_STRUCTURE, e->name, "height");
        REQUIRE(l.layoutDirection == e->direction && l.childGap == e->gap &&
            l.childAlignment.x == e->align_x && l.childAlignment.y == e->align_y &&
            !l.padding.left && !l.padding.right && !l.padding.top && !l.padding.bottom,
            BAD_STRUCTURE, e->name, "flow/padding/gap/alignment");
        int child = 0;
        for (int j = 0; j < n; ++j) {
            if (!expected[j].parent || strcmp(expected[j].parent, e->name)) continue;
            REQUIRE(child < a->children.length && a->children.elements[child] == j + 1,
                BAD_STRUCTURE, e->name, "ordered children");
            ++child;
        }
        REQUIRE(a->children.length == child, BAD_STRUCTURE, e->name, "child count");
        Clay_FloatingElementConfig f = a->config.floating;
        if (e->target) {
            REQUIRE(f.attachTo == CLAY_ATTACH_TO_ELEMENT_WITH_ID && f.parentId == id(e->target).id &&
                f.attachPoints.element == CLAY_ATTACH_POINT_LEFT_TOP &&
                f.attachPoints.parent == CLAY_ATTACH_POINT_LEFT_TOP &&
                f.pointerCaptureMode == CLAY_POINTER_CAPTURE_MODE_CAPTURE && f.zIndex == e->band &&
                f.clipTo == CLAY_CLIP_TO_NONE && !f.offset.x && !f.offset.y && !f.expand.width && !f.expand.height,
                BAD_STRUCTURE, e->name, "attachment");
            /* Search this frame's actual declarations, never persistent .found. */
            int targets = 0;
            for (int j = 1; j <= i; ++j) targets += elements[j].id == f.parentId;
            REQUIRE(targets == 1, BAD_STRUCTURE, e->name, "earlier current-frame target");
        } else {
            REQUIRE(f.attachTo == CLAY_ATTACH_TO_NONE, BAD_STRUCTURE, e->name, "ordinary flow");
        }
    }
    const char *roots[] = {NULL, "WIBAR", "GHOSTTY", "FIREFOX"};
    REQUIRE(ctx->layoutElementTreeRoots.length == 4, BAD_STRUCTURE, "desktop", "root count");
    for (int i = 0; i < ctx->layoutElementTreeRoots.length && i < 4; ++i) {
        int index = ctx->layoutElementTreeRoots.internalArray[i].layoutElementIndex;
        REQUIRE(index >= 0 && index <= n &&
            (i == 0 ? index == 0 : elements[index].id == id(roots[i]).id),
            BAD_STRUCTURE, "desktop", "paint root order");
    }
#undef REQUIRE
    return faults;
}
static bool same(Clay_BoundingBox a, Clay_BoundingBox b) {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}
static bool geometry(const char *path, const char *variant, bool dump) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); exit(2); }
    char line[256], which[32], name[64];
    bool seen[64] = {false}, ok = true;
    while (fgets(line, sizeof line, f)) {
        Clay_BoundingBox expected;
        if (line[0] == '#') continue;
        if (sscanf(line, "%31s %63s %f %f %f %f", which, name, &expected.x,
                   &expected.y, &expected.width, &expected.height) != 6) {
            fprintf(stderr, "Invalid expectation: %s", line); exit(2);
        }
        if (strcmp(which, variant)) continue;
        int i = 0;
        while (i < count && strcmp(records[i].name, name)) ++i;
        if (i == count || seen[i]) { fprintf(stderr, "Unknown/duplicate expected element %s\n", name); ok = false; continue; }
        seen[i] = true;
        Clay_ElementData got = Clay_GetElementData(id(name));
        bool match = got.found && same(got.boundingBox, expected);
        ok &= match;
        if (dump || !match) fprintf(stderr,
            "  %s %s expected=(%g,%g %gx%g) solved=(%g,%g %gx%g) found=%d\n",
            match ? "OK" : "FAIL", name, expected.x, expected.y, expected.width, expected.height,
            got.boundingBox.x, got.boundingBox.y, got.boundingBox.width, got.boundingBox.height, got.found);
    }
    fclose(f);
    for (int i = 0; i < count; ++i) if (!seen[i]) {
        fprintf(stderr, "Missing expectation for %s\n", records[i].name); ok = false;
    }
    return ok;
}
static bool commands(Clay_RenderCommandArray cmds) {
    const char *expected[] = {"OUTPUT", "WIBAR", "MENU", "TAGS", "CLOCK", "STATUS",
        "GHOSTTY_TITLEBAR", "GHOSTTY_ICON", "GHOSTTY_CLOSE",
        "GHOSTTY_SURFACE", "FIREFOX_TITLEBAR", "FIREFOX_ICON", "FIREFOX_CLOSE",
        "FIREFOX_SURFACE"};
    bool ok = cmds.length == (int)(sizeof expected / sizeof *expected);
    for (int i = 0; i < cmds.length; ++i) {
        Clay_RenderCommand *c = Clay_RenderCommandArray_Get(&cmds, i);
        if (i >= 14) { ok = false; continue; }
        bool surface = i == 9 || i == 13;
        int band = i == 0 ? 0 : i < 6 ? 45 : 60;
        bool match = c->id == id(expected[i]).id && c->zIndex == band &&
            c->commandType == (surface ? CLAY_RENDER_COMMAND_TYPE_CUSTOM : CLAY_RENDER_COMMAND_TYPE_RECTANGLE) &&
            same(c->boundingBox, Clay_GetElementData(id(expected[i])).boundingBox);
        if (surface) match &= c->renderData.custom.customData &&
            strcmp(c->renderData.custom.customData, i == 9 ? "ghostty" : "firefox") == 0;
        if (!match) fprintf(stderr, "Command %d expected=%s band=%d; got id=%u band=%d type=%d\n",
                            i, expected[i], band, c->id, c->zIndex, c->commandType);
        ok &= match;
    }
    if (!ok) fprintf(stderr, "Render command order/resource/box mismatch (count=%d expected=14)\n", cmds.length);
    return ok;
}
static bool hit(float x, float y, const char *target) {
    Clay_SetPointerState((Clay_Vector2){x, y}, false);
    const char *leaves[] = {"GHOSTTY_CLOSE", "FIREFOX_CLOSE", "GHOSTTY_SURFACE", "FIREFOX_SURFACE", "GHOSTTY_TITLE_SPACE"};
    bool ok = true;
    for (int i = 0; i < 5; ++i) {
        bool expected = strcmp(leaves[i], target) == 0;
        if (Clay_PointerOver(id(leaves[i])) != expected) {
            fprintf(stderr, "Pointer (%g,%g): %s expected over=%d\n", x, y, leaves[i], expected); ok = false;
        }
    }
    return ok;
}
static bool solve(const char *path, int variant, const char *mode, bool external_fixed) {
    errors = 0;
    Clay_RenderCommandArray cmds = declare(variants[variant], external_fixed);
    bool ok = geometry(path, cases[variant], false);
    ok = commands(cmds) && ok;
    unsigned faults = structure(variants[variant]);
    if (variant == 0) {
        ok = hit(588, 40, "GHOSTTY_CLOSE") && ok;
        ok = hit(1188, 40, "FIREFOX_CLOSE") && ok;
        ok = hit(300, 400, "GHOSTTY_SURFACE") && ok;
        ok = hit(900, 400, "FIREFOX_SURFACE") && ok;
    } else if (variant == 2) {
        ok = hit(708, 40, "GHOSTTY_CLOSE") && ok;
        ok = hit(588, 40, "GHOSTTY_TITLE_SPACE") && ok;
    }
    ok &= errors == 0;
    /* The negative is valid evidence only when all non-structural checks pass
     * and the oracle rejects exactly the forbidden split constraint. */
    ok &= faults == (external_fixed ? BAD_SPLIT : 0);
    if (!ok) {
        fprintf(stderr, "FAILED %s/%s\n", mode, cases[variant]);
        dump_constraints(); geometry(path, cases[variant], true);
    } else printf("%s %s/%s: %d solved boxes, 14 paint commands, one solve; %s\n",
        external_fixed ? "REJECT external-FIXED" : "PASS", mode, cases[variant], count,
        external_fixed ? "geometry/input pass, structure rejects GHOSTTY_SLOT width" : "structure/input pass");
    return ok;
}
static void *context(void) {
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    if (!memory) exit(2);
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
                    (Clay_Dimensions){1200, 800}, (Clay_ErrorHandler){.errorHandlerFunction = on_error});
    return memory;
}
int main(int argc, char **argv) {
    bool external_fixed = argc == 3 && strcmp(argv[2], "--external-fixed") == 0;
    if (argc != 2 && !external_fixed) {
        fprintf(stderr, "Usage: %s expectations.tsv [--external-fixed]\n", argv[0]); return 2;
    }
    bool ok = true;
    for (int i = 0; i < 5; ++i) {
        void *memory = context();
        ok = solve(argv[1], i, "cold", external_fixed) && ok;
        /* Clay_MinMemorySize consults the current context on the next iteration. */
        Clay_SetCurrentContext(NULL);
        free(memory);
    }
    void *memory = context();
    ok = solve(argv[1], 0, "warm", external_fixed) && ok;
    for (int i = 1; i < 5; ++i) {
        ok = solve(argv[1], i, "warm", external_fixed) && ok;
        ok = solve(argv[1], 0, "restore", external_fixed) && ok;
    }
    Clay_SetCurrentContext(NULL);
    free(memory);
    /* 1 means the negative was rejected for the required reason in every frame;
     * unexpected failures use 2 so the runner cannot mistake a crash/error or
     * a weakened oracle accepting FIXED for a successful negative test. */
    return !ok ? 2 : external_fixed ? 1 : 0;
}
