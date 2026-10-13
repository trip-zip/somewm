/* Solver fixtures for an image's sizing against the pinned header: the rows of
 * requirement R120 in ideas/clay-native-spec.md. Each row declares a parent
 * holding an image with an aspect ratio beside a GROW sibling and checks the
 * solved boxes to 0.01, the rounding somewm applies at the boundary. The pin is
 * compiled here, not linked, so the numbers are Clay's alone. */
#define CLAY_IMPLEMENTATION
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-variable"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wsign-compare"
#include "clay.h"
#pragma GCC diagnostic pop

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;

static void clay_error(Clay_ErrorData error)
{
	fprintf(stderr, "Clay: %.*s\n", error.errorText.length, error.errorText.chars);
	abort();
}

static Clay_Dimensions measure(Clay_StringSlice text, Clay_TextElementConfig *cfg, void *data)
{
	(void)cfg; (void)data;
	return (Clay_Dimensions) { text.length * 8, 12 };
}

struct box { float w, h, x, y; };

static bool near(float a, float b) { return fabsf(a - b) < 0.01f; }

static void expect(const char *row, const char *name, Clay_ElementId id, struct box want)
{
	Clay_BoundingBox got = Clay_GetElementData(id).boundingBox;
	if (!near(got.width, want.w) || !near(got.height, want.h) || !near(got.x, want.x) || !near(got.y, want.y)) {
		fprintf(stderr, "%s %s: got %gx%g at %g,%g; expected %gx%g at %g,%g\n", row, name,
			got.width, got.height, got.x, got.y, want.w, want.h, want.x, want.y);
		failures++;
	}
}

/* A parent sized pw x ph, 0 meaning FIT, laid out as a row or a column. With
 * `pad` set the image sits inside a padded wrap of sizing `wrap`, as a margin
 * container declares. With `two_rows` set the parent is a column of two GROW
 * rows, the image and its sibling in the first, a lone GROW child in the
 * second: the flow-axis GROW case of D045. */
struct fixture {
	const char *name;
	bool vertical, two_rows;
	float pw, ph;
	Clay_Sizing img;
	float aspect;
	Clay_Sizing wrap;
	uint16_t pad;
	struct box image, sibling, parent, row1, row2;
};

static void image(const struct fixture *f)
{
	if (f->pad) {
		CLAY(CLAY_ID("wrap"), { .layout = { .sizing = f->wrap,
				.padding = { f->pad, f->pad, f->pad, f->pad } } }) {
			CLAY(CLAY_ID("image"), { .layout = { .sizing = f->img },
				.aspectRatio = f->aspect, .image = { .imageData = (void *)1 } }) {}
		}
	} else {
		CLAY(CLAY_ID("image"), { .layout = { .sizing = f->img },
			.aspectRatio = f->aspect, .image = { .imageData = (void *)1 } }) {}
	}
}

static void sibling(void)
{
	CLAY(CLAY_ID("sibling"), { .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } } }) {}
}

static void run(const struct fixture *f)
{
	Clay_BeginLayout();
	CLAY(CLAY_ID("root"), { .layout = { .sizing = { CLAY_SIZING_FIXED(400), CLAY_SIZING_FIXED(400) } } }) {
		CLAY(CLAY_ID("parent"), { .layout = {
				.layoutDirection = f->vertical || f->two_rows ? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT,
				.sizing = { f->pw ? CLAY_SIZING_FIXED(f->pw) : CLAY_SIZING_FIT(0),
					f->ph ? CLAY_SIZING_FIXED(f->ph) : CLAY_SIZING_FIT(0) } } }) {
			if (f->two_rows) {
				CLAY(CLAY_ID("row1"), { .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } } }) {
					image(f);
					sibling();
				}
				CLAY(CLAY_ID("row2"), { .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } } }) {
					CLAY(CLAY_ID("lone"), { .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } } }) {}
				}
			} else {
				image(f);
				sibling();
			}
		}
	}
	Clay_EndLayout(0);
	expect(f->name, "image", CLAY_ID("image"), f->image);
	expect(f->name, "sibling", CLAY_ID("sibling"), f->sibling);
	expect(f->name, "parent", CLAY_ID("parent"), f->parent);
	if (f->two_rows) {
		expect(f->name, "row1", CLAY_ID("row1"), f->row1);
		expect(f->name, "row2", CLAY_ID("row2"), f->row2);
	}
}

int main(void)
{
	uint32_t size = Clay_MinMemorySize();
	void *arena = malloc(size);
	Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, arena),
		(Clay_Dimensions) { 400, 400 }, (Clay_ErrorHandler) { clay_error, NULL });
	Clay_SetMeasureTextFunction(measure, NULL);
	Clay_SetCullingEnabled(false);

	/* 64x32 source, aspect 2, unless the row says otherwise. */
	const struct fixture rows[] = {
		{ "R120 row 1: 200x24, FIT(64) x FIT(0)", false, false, 200, 24,
			{ CLAY_SIZING_FIT(64), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 48, 24, 0, 0 }, { 136, 24, 48, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 2: FIT x 24, FIT(64) x FIT(0)", false, false, 0, 24,
			{ CLAY_SIZING_FIT(64), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 48, 24, 0, 0 }, { 0, 24, 48, 0 }, { 64, 24, 0, 0 } },
		{ "R120 row 3: 200x24, FIT(128) x FIT(0), 128x128 source", false, false, 200, 24,
			{ CLAY_SIZING_FIT(128), CLAY_SIZING_FIT(0) }, 1, {0}, 0,
			{ 24, 24, 0, 0 }, { 72, 24, 24, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 4: 200x100, FIT(64) x FIT(0)", false, false, 200, 100,
			{ CLAY_SIZING_FIT(64), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 64, 32, 0, 0 }, { 136, 100, 64, 0 }, { 200, 100, 0, 0 } },
		{ "R120 row 5: 200x24, FIXED(20) x FIT(0)", false, false, 200, 24,
			{ CLAY_SIZING_FIXED(20), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 20, 10, 0, 0 }, { 180, 24, 20, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 6: 200x24, FIT(0) x FIXED(16)", false, false, 200, 24,
			{ CLAY_SIZING_FIT(0), CLAY_SIZING_FIXED(16) }, 2, {0}, 0,
			{ 32, 16, 0, 0 }, { 168, 24, 32, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 7: 200x24, FIT(0,64) x FIT(0,32)", false, false, 200, 24,
			{ CLAY_SIZING_FIT(0, 64), CLAY_SIZING_FIT(0, 32) }, 2, {0}, 0,
			{ 0, 0, 0, 0 }, { 200, 24, 0, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 8: 200x24, FIT(64) x FIT(32)", false, false, 200, 24,
			{ CLAY_SIZING_FIT(64), CLAY_SIZING_FIT(32) }, 2, {0}, 0,
			{ 64, 32, 0, 0 }, { 136, 24, 64, 0 }, { 200, 24, 0, 0 } },
		{ "R120 row 9: column 24x200, FIT(0) x FIT(32)", true, false, 24, 200,
			{ CLAY_SIZING_FIT(0), CLAY_SIZING_FIT(32) }, 2, {0}, 0,
			{ 24, 12, 0, 0 }, { 24, 188, 0, 12 }, { 24, 200, 0, 0 } },
		{ "R120 row 10: column 24x200, FIT(64) x FIT(0)", true, false, 24, 200,
			{ CLAY_SIZING_FIT(64), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 64, 32, 0, 0 }, { 24, 168, 0, 32 }, { 24, 200, 0, 0 } },
		/* The authored bound (D045): 24 * 2 = 48 as the flow-axis minimum. */
		{ "R120 row 11: 200x24, FIT(48) x FIT(0), bound 48", false, false, 200, 24,
			{ CLAY_SIZING_FIT(48), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 48, 24, 0, 0 }, { 152, 24, 48, 0 }, { 200, 24, 0, 0 } },
		/* The bound through a GROW cross axis and 2 px padding: (24 - 4) * 2 = 40. */
		{ "R120 row 12: 200x24 > GROW wrap pad 2 > FIT(40) x FIT(0), bound 40", false, false, 200, 24,
			{ CLAY_SIZING_FIT(40), CLAY_SIZING_FIT(0) }, 2,
			{ CLAY_SIZING_FIT(0), CLAY_SIZING_GROW(0) }, 2,
			{ 40, 20, 2, 2 }, { 156, 24, 44, 0 }, { 200, 24, 0, 0 } },
		/* A FIT cross axis passes the bound as a cap: (24 - 4) * 2 = 40. */
		{ "R120 row 13: 200x24 > FIT wrap pad 2 > FIT(40) x FIT(0), cap 40", false, false, 200, 24,
			{ CLAY_SIZING_FIT(40), CLAY_SIZING_FIT(0) }, 2,
			{ CLAY_SIZING_FIT(0), CLAY_SIZING_FIT(0) }, 2,
			{ 40, 20, 2, 2 }, { 156, 24, 44, 0 }, { 200, 24, 0, 0 } },
		/* A GROW row on its parent's flow axis with a sibling row: the column's
		 * 24 is not the row's bound. Declared as if it were, the aspect height
		 * takes the whole column and the second row gets nothing. */
		{ "R120 row 14: column 200x24 > two GROW rows, FIT(48) x FIT(0), wrong bound", false, true, 200, 24,
			{ CLAY_SIZING_FIT(48), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 48, 24, 0, 0 }, { 152, 24, 48, 0 }, { 200, 24, 0, 0 },
			{ 200, 24, 0, 0 }, { 200, 0, 0, 24 } },
		/* The same tree with the bound undefined: natural 64 would be row 14's
		 * overflow; declared from the true inner height 12 the rows share. */
		{ "R120 row 15: column 200x24 > two GROW rows, FIT(24) x FIT(0)", false, true, 200, 24,
			{ CLAY_SIZING_FIT(24), CLAY_SIZING_FIT(0) }, 2, {0}, 0,
			{ 24, 12, 0, 0 }, { 176, 12, 24, 0 }, { 200, 24, 0, 0 },
			{ 200, 12, 0, 0 }, { 200, 11.9941f, 0, 12 } },
		/* Upscale to the bound: 16x16 source in a 24 px row. */
		{ "R120 row 16: 200x24, 16x16 source, FIT(24) x FIT(0), bound 24", false, false, 200, 24,
			{ CLAY_SIZING_FIT(24), CLAY_SIZING_FIT(0) }, 1, {0}, 0,
			{ 24, 24, 0, 0 }, { 176, 24, 24, 0 }, { 200, 24, 0, 0 } },
		/* A column's height through a FIT wrap padded 7: cap 28 - 14, 48x48 source. */
		{ "R120 row 17: column 200x28 > FIT wrap pad 7 > FIT(14) x FIT(0), cap 14", true, false, 200, 28,
			{ CLAY_SIZING_FIT(14), CLAY_SIZING_FIT(0) }, 1,
			{ CLAY_SIZING_FIT(0), CLAY_SIZING_FIT(0) }, 7,
			{ 14, 14, 7, 7 }, { 200, 0, 0, 28 }, { 200, 28, 0, 0 } },
	};
	for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++)
		run(&rows[i]);

	Clay_SetCurrentContext(NULL);
	free(arena);
	if (failures) {
		fprintf(stderr, "%d fixture box(es) differ\n", failures);
		return 1;
	}
	printf("clay-aspect: %zu rows\n", sizeof rows / sizeof rows[0]);
	return 0;
}
