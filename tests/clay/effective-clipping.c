#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CLAY_IMPLEMENTATION
#include <clay.h>

/* Bounded, test-private bridge for the first three clip-eligibility rows.
 * No production code, layout arithmetic, upstream writes, event dispatch,
 * rounding, transforms, scrolling, or snapshot-lifetime contract. */
enum { HORIZONTAL, NESTED, FLOATING, LIMIT = 16, SIDE = 200 };
static const char *case_names[] = {"horizontal-only", "nested", "floating-inherited"};
static int errors;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); return false; } } while (0)
#define FIX(n) CLAY_SIZING_FIXED(n)
#define PAINT .backgroundColor = {80, 100, 120, 255}
static Clay_ElementId id(const char *name) {
    return Clay_GetElementId((Clay_String){.length = (int32_t)strlen(name), .chars = name});
}
static void on_error(Clay_ErrorData e) {
    fprintf(stderr, "Clay error %d: %.*s\n", e.errorType, e.errorText.length, e.errorText.chars);
    ++errors;
}
static Clay_RenderCommandArray declare(int kind, int dx, int dy) {
    Clay_BeginLayout();
    CLAY(id("OUTPUT"), {.layout = {.sizing = {FIX(SIDE), FIX(SIDE)},
        .padding = {.left = dx, .top = dy}}}) {
        CLAY(id("OUTER"), {.layout = {.sizing = {FIX(50), FIX(50)}},
            .clip = {.horizontal = true, .vertical = kind != HORIZONTAL}}) {
            if (kind == HORIZONTAL) {
                CLAY(id("LEAF"), {.layout = {.sizing = {FIX(100), FIX(100)}}, PAINT}) {}
            } else {
                CLAY(id("INNER"), {.layout = {.sizing = {FIX(100), FIX(100)}},
                    .clip = {.horizontal = true, .vertical = true}}) {
                    CLAY(id("LEAF"), {.layout = {.sizing = {FIX(100), FIX(100)}}, PAINT}) {}
                }
            }
        }
    }
    if (kind == FLOATING) {
        /* Declared outside OUTPUT: inheritance must follow the actual target,
         * not declaration nesting, nearest clip ID, or coincident geometry. */
        CLAY(id("FLOAT"), {.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}},
            .floating = {.attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                .parentId = id("LEAF").id, .zIndex = 1,
                .attachPoints = {CLAY_ATTACH_POINT_LEFT_TOP, CLAY_ATTACH_POINT_LEFT_TOP},
                .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
                .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_CAPTURE}, PAINT}) {}
    }
    return Clay_EndLayout(0);
}

typedef struct {
    uint32_t id;
    int parent, clips[LIMIT], count;
    Clay_BoundingBox box;
    Clay_ClipElementConfig axes;
} Node;
typedef struct { Node nodes[LIMIT]; int count; } Bridge;
static int lookup(const Bridge *b, uint32_t needle) {
    for (int i = 0; i < b->count; ++i) if (b->nodes[i].id == needle) return i;
    return -1;
}
static bool same_box(Clay_BoundingBox a, Clay_BoundingBox b) {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}
/* Read actual current-frame declarations. Nothing here knows case names,
 * expected sizes, sample points, or the pin's nearest-clip bookkeeping. */
static bool bridge(Bridge *b) {
    Clay_Context *ctx = Clay_GetCurrentContext();
    b->count = ctx->layoutElements.length;
    CHECK(b->count > 0 && b->count <= LIMIT, "Bridge capacity: %d", b->count);
    Clay_LayoutElement *elements = ctx->layoutElements.internalArray;
    for (int i = 0; i < b->count; ++i) {
        b->nodes[i] = (Node){.id = elements[i].id, .parent = -1, .axes = elements[i].config.clip};
        for (int j = 0; j < i; ++j) CHECK(elements[j].id != elements[i].id, "Duplicate ID");
        Clay_ElementData data = Clay_GetElementData((Clay_ElementId){.id = elements[i].id});
        CHECK(data.found, "No solved box for current-frame element %d", i);
        b->nodes[i].box = data.boundingBox;
    }
    for (int i = 0; i < b->count; ++i) {
        for (int j = 0; j < elements[i].children.length; ++j) {
            int child = elements[i].children.elements[j];
            CHECK(child > i && child < b->count && b->nodes[child].parent == -1,
                  "Invalid actual child edge %d -> %d", i, child);
            b->nodes[child].parent = i;
        }
    }
    for (int i = 1; i < b->count; ++i) {
        Node *n = &b->nodes[i];
        Clay_FloatingElementConfig f = elements[i].config.floating;
        int source = n->parent;
        bool include_source = true;
        if (f.attachTo != CLAY_ATTACH_TO_NONE) {
            CHECK(f.attachTo == CLAY_ATTACH_TO_ELEMENT_WITH_ID, "Unsupported bridge attachment");
            int target = lookup(b, f.parentId);
            CHECK(target >= 0 && target < i, "Target must precede dependant in this frame");
            source = f.clipTo == CLAY_CLIP_TO_ATTACHED_PARENT ? target : -1;
            /* Inherit the target's enclosing clips, not a new clip guessed
             * from its own allocation. This fixture targets a non-clip leaf. */
            include_source = false;
        } else CHECK(source >= 0, "Missing ordinary parent");
        if (source >= 0) {
            Node *p = &b->nodes[source];
            n->count = p->count;
            memcpy(n->clips, p->clips, sizeof(int) * p->count);
            if (include_source && (p->axes.horizontal || p->axes.vertical)) {
                CHECK(n->count < LIMIT, "Clip chain capacity");
                n->clips[n->count++] = source;
            }
        }
    }
    return true;
}
static bool contains(Clay_BoundingBox b, float x, float y) {
    return x >= b.x && y >= b.y && x < b.x + b.width && y < b.y + b.height;
}
static Clay_BoundingBox intersect(Clay_BoundingBox a, Clay_BoundingBox b, bool h, bool v) {
    float right = h ? fminf(a.x + a.width, b.x + b.width) : a.x + a.width;
    float bottom = v ? fminf(a.y + a.height, b.y + b.height) : a.y + a.height;
    if (h) a.x = fmaxf(a.x, b.x);
    if (v) a.y = fmaxf(a.y, b.y);
    a.width = fmaxf(0, right - a.x);
    a.height = fmaxf(0, bottom - a.y);
    return a;
}
/* Paint realization: replace raw scissor scopes for supported rectangle
 * commands with an effective clip, preserving command identity/box/order. */
static bool paint_mask(const Bridge *b, Clay_RenderCommandArray commands, uint32_t target,
                       bool raw, unsigned char mask[SIDE][SIDE]) {
    Clay_BoundingBox stack[LIMIT] = {{0, 0, SIDE, SIDE}};
    int depth = 0, matches = 0;
    memset(mask, 0, SIDE * SIDE);
    for (int i = 0; i < commands.length; ++i) {
        Clay_RenderCommand c = commands.internalArray[i];
        if (c.commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) {
            CHECK(depth + 1 < LIMIT, "Scissor capacity");
            bool both = !c.renderData.clip.horizontal && !c.renderData.clip.vertical;
            Clay_BoundingBox next = intersect(stack[depth], c.boundingBox,
                both || c.renderData.clip.horizontal, both || c.renderData.clip.vertical);
            stack[++depth] = next;
        } else if (c.commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END) {
            CHECK(depth > 0, "Unbalanced scissor end");
            --depth;
        } else {
            CHECK(c.commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE, "Unsupported paint command");
            int index = lookup(b, c.id);
            CHECK(index >= 0, "Paint ID missing from actual declarations");
            const Node *n = &b->nodes[index];
            CHECK(same_box(c.boundingBox, n->box), "Command/query geometry disagreement");
            Clay_BoundingBox clip = raw ? stack[depth] : (Clay_BoundingBox){0, 0, SIDE, SIDE};
            if (!raw) for (int j = 0; j < n->count; ++j) {
                const Node *ancestor = &b->nodes[n->clips[j]];
                clip = intersect(clip, ancestor->box, ancestor->axes.horizontal, ancestor->axes.vertical);
            }
            if (c.id != target) continue;
            ++matches;
            Clay_BoundingBox visible = intersect(c.boundingBox, clip, true, true);
            for (int y = 0; y < SIDE; ++y) for (int x = 0; x < SIDE; ++x)
                mask[y][x] |= contains(visible, x + .5f, y + .5f);
        }
    }
    CHECK(depth == 0 && matches == 1, "Unbalanced scopes or missing/duplicate target paint");
    return true;
}
/* Eligibility uses individual ancestor axis predicates, independently of the
 * paint intersection/raster path. It must not filter Clay_PointerOver: that
 * would make the horizontal-only false negative impossible to recover. */
static bool eligible(const Bridge *b, int index, float x, float y) {
    const Node *n = &b->nodes[index];
    if (!contains(n->box, x, y) || x < 0 || y < 0 || x >= SIDE || y >= SIDE) return false;
    for (int j = 0; j < n->count; ++j) {
        const Node *a = &b->nodes[n->clips[j]];
        if (a->axes.horizontal && (x < a->box.x || x >= a->box.x + a->box.width)) return false;
        if (a->axes.vertical && (y < a->box.y || y >= a->box.y + a->box.height)) return false;
    }
    return true;
}
/* Independent reference oracle; never used to emit declarations or bridge
 * geometry. Translation is a declaration padding input, not a solved input. */
static bool expected(int kind, float x, float y, int dx, int dy) {
    return x >= dx && x < dx + 50 && y >= dy && y < dy + (kind == HORIZONTAL ? 100 : 50);
}
static bool structure(const Bridge *b, int kind, int dx, int dy) {
    const char *names[] = {"OUTPUT", "OUTER", kind == HORIZONTAL ? "LEAF" : "INNER", "LEAF", "FLOAT"};
    int count = kind == HORIZONTAL ? 4 : kind == NESTED ? 5 : 6;
    CHECK(b->count == count, "Unexpected declaration count");
    Clay_LayoutElement *elements = Clay_GetCurrentContext()->layoutElements.internalArray;
    for (int i = 1; i < count; ++i) {
        const Node *n = &b->nodes[i];
        CHECK(n->id == id(names[i - 1]).id, "Actual declaration order/ID: %d", i);
        CHECK(n->parent == (i == 5 ? -1 : i - 1), "Actual containment: %s", names[i - 1]);
        Clay_BoundingBox box = i == 1 ? (Clay_BoundingBox){0, 0, 200, 200} :
            i == 2 ? (Clay_BoundingBox){dx, dy, 50, 50} : (Clay_BoundingBox){dx, dy, 100, 100};
        CHECK(same_box(n->box, box), "%s box: %.0f,%.0f %.0fx%.0f", names[i - 1],
              n->box.x, n->box.y, n->box.width, n->box.height);
        bool clip = i == 2 || (i == 3 && kind != HORIZONTAL);
        CHECK(n->axes.horizontal == clip && n->axes.vertical == (clip && kind != HORIZONTAL), "Clip axes");
        int clips = i <= 2 ? 0 : i == 3 ? 1 : 2;
        CHECK(n->count == clips, "Effective ancestry length: %s", names[i - 1]);
        for (int j = 0; j < clips; ++j) CHECK(n->clips[j] == j + 2, "Effective ancestry identity/order");
        if (i == 5) {
            Clay_ElementDeclaration d = elements[i].config;
            CHECK(d.layout.sizing.width.type == CLAY__SIZING_TYPE_GROW &&
                d.layout.sizing.height.type == CLAY__SIZING_TYPE_GROW &&
                d.layout.sizing.width.size.minMax.min == 0 && d.layout.sizing.height.size.minMax.min == 0 &&
                d.layout.sizing.width.size.minMax.max == CLAY__MAXFLOAT &&
                d.layout.sizing.height.size.minMax.max == CLAY__MAXFLOAT &&
                d.floating.attachTo == CLAY_ATTACH_TO_ELEMENT_WITH_ID && d.floating.parentId == id("LEAF").id &&
                d.floating.clipTo == CLAY_CLIP_TO_ATTACHED_PARENT && d.floating.zIndex == 1 &&
                d.floating.attachPoints.element == CLAY_ATTACH_POINT_LEFT_TOP &&
                d.floating.attachPoints.parent == CLAY_ATTACH_POINT_LEFT_TOP &&
                d.floating.pointerCaptureMode == CLAY_POINTER_CAPTURE_MODE_CAPTURE &&
                !d.floating.offset.x && !d.floating.offset.y && !d.floating.expand.width && !d.floating.expand.height,
                "Floating allocation/attachment declaration");
        }
    }
    return true;
}
static bool solve(int kind, int dx, int dy, const char *phase) {
    errors = 0;
    Clay_RenderCommandArray commands = declare(kind, dx, dy);
    Bridge b = {0};
    CHECK(errors == 0 && bridge(&b) && structure(&b, kind, dx, dy), "Declaration/bridge failure");
    const char *target = kind == FLOATING ? "FLOAT" : "LEAF";
    int index = lookup(&b, id(target).id);
    CHECK(index >= 0, "Missing target");
    unsigned char raw[SIDE][SIDE], effective[SIDE][SIDE];
    CHECK(paint_mask(&b, commands, id(target).id, true, raw) &&
        paint_mask(&b, commands, id(target).id, false, effective), "Paint realization failed");
    int expected_commands = kind == HORIZONTAL ? 3 : kind == NESTED ? 5 : 8;
    CHECK(commands.length == expected_commands, "Command count: %d", commands.length);
    for (int y = 0; y < SIDE; ++y) for (int x = 0; x < SIDE; ++x) {
        bool want = expected(kind, x + .5f, y + .5f, dx, dy);
        bool raw_want = kind == FLOATING ? x >= dx && x < dx + 100 && y >= dy && y < dy + 100 : want;
        CHECK(effective[y][x] == want && eligible(&b, index, x + .5f, y + .5f) == want && raw[y][x] == raw_want,
              "%s/%s coverage at %d,%d: effective=%d eligible=%d expected=%d raw=%d expected-raw=%d",
              case_names[kind], phase, x, y, effective[y][x], eligible(&b, index, x + .5f, y + .5f), want, raw[y][x], raw_want);
    }
    float px = dx + (kind == HORIZONTAL ? 25 : 75), py = dy + (kind == HORIZONTAL ? 75 : 25);
    Clay_SetPointerState((Clay_Vector2){px, py}, false);
    bool raw_hit = Clay_PointerOver(id(target));
    bool want = kind == HORIZONTAL;
    CHECK(raw_hit == !want && eligible(&b, index, px, py) == want && effective[(int)py][(int)px] == want,
          "Required raw/effective discrepancy at %.0f,%.0f", px, py);
    /* An interior control prevents a bridge that hides/rejects everything. */
    Clay_SetPointerState((Clay_Vector2){dx + 25, dy + 25}, false);
    CHECK(Clay_PointerOver(id(target)) && eligible(&b, index, dx + 25, dy + 25), "Interior control");
    CHECK(errors == 0, "Unexpected Clay error");
    printf("PASS %s/%s offset=%d,%d: 40000 paint/eligibility samples; raw hit=%d effective=%d at %.0f,%.0f\n",
           case_names[kind], phase, dx, dy, raw_hit, want, px, py);
    return true;
}
static void *context(void) {
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    if (!memory) exit(2);
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
        (Clay_Dimensions){SIDE, SIDE}, (Clay_ErrorHandler){.errorHandlerFunction = on_error});
    return memory;
}
static void release(void *memory) {
    Clay_SetCurrentContext(NULL);
    free(memory);
}
int main(void) {
    bool ok = true;
    for (int kind = 0; kind < 3; ++kind) {
        void *memory = context();
        ok = solve(kind, 0, 0, "cold") && ok;
        release(memory);
    }
    void *memory = context();
    for (int kind = 0; kind < 3; ++kind) {
        ok = solve(kind, 0, 0, "warm") && ok;
        ok = solve(kind, 10, 20, "translated") && ok;
        ok = solve(kind, 0, 0, "restored") && ok;
    }
    release(memory);
    return ok ? 0 : 1;
}
