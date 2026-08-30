/* The font table and the shared Pango setup both the measure callback and the
 * raster path go through, ported from kiln (ui.c). */

#include <string.h>
#include <pango/pangocairo.h>

#include "render_text.h"

/* Entry 0 of the font table, and the face a declaration naming none gets.
 * Clay passes fontId 0 for its debug view's own text (clay.h:380-381), so entry
 * 0 has to name a face that exists whatever a config does with the rest of the
 * table. */
#define RENDER_FONT_FAMILY "Sans"

/* The font table's cap. An interned face is never evicted and its id never
 * reused, so this is what bounds a config building description strings in a
 * loop instead of naming a fixed set: past it interning refuses. */
#define RENDER_MAX_FONTS 64

/* Ids are write-once: an entry is appended, never rewritten, so a live
 * declaration's id keeps meaning the face it was interned for. Rewriting one
 * would leave Clay's measure cache answering with the old face's widths for
 * good, because that cache keys on the id (clay.h:1508-1531). */
static struct {
	const char *name;
	PangoFontDescription *desc;
} render_fonts[RENDER_MAX_FONTS];
static int render_fonts_len;

/* The layout every measurement is taken on, and the scale it is taken at. */
static PangoContext *render_pango;
static PangoLayout *render_measure_layout;
static float render_measure_scale = 1.0f;

static void render_fonts_init(void) {
	if (render_fonts_len > 0) {
		return;
	}
	render_fonts[0].name = RENDER_FONT_FAMILY;
	render_fonts[0].desc = pango_font_description_from_string(RENDER_FONT_FAMILY);
	render_fonts_len = 1;
}

int32_t render_font_intern(const char *name) {
	render_fonts_init();
	for (int i = 0; i < render_fonts_len; i++) {
		if (strcmp(render_fonts[i].name, name) == 0) {
			return i;
		}
	}

	/* Pango's own parser is the only thing that knows what a description means,
	 * so a carried size is its set-fields mask rather than a scan for a trailing
	 * number: a family whose name ends in a digit is not a size. Refused before
	 * the cap is consulted, so a bad description names its real problem even
	 * with the table full. */
	PangoFontDescription *desc = pango_font_description_from_string(name);
	if (pango_font_description_get_set_fields(desc) & PANGO_FONT_MASK_SIZE) {
		pango_font_description_free(desc);
		return RENDER_FONT_ERR_SIZE;
	}
	if (render_fonts_len == RENDER_MAX_FONTS) {
		pango_font_description_free(desc);
		return RENDER_FONT_ERR_FULL;
	}

	render_fonts[render_fonts_len].name = strdup(name);
	render_fonts[render_fonts_len].desc = desc;
	return render_fonts_len++;
}

void render_set_text(PangoLayout *layout, const char *text, int len,
		uint16_t font_id, uint16_t font_size, float scale, int max_width) {
	render_fonts_init();
	/* An id past the table resolves to entry 0 rather than aborting: the id is
	 * whatever a declaration put in the field, and Clay's debug view writes 0
	 * into it without interning anything. */
	PangoFontDescription *desc = font_id < render_fonts_len
		? render_fonts[font_id].desc : render_fonts[0].desc;
	pango_font_description_set_absolute_size(desc,
		(double)font_size * scale * PANGO_SCALE);
	pango_layout_set_font_description(layout, desc);

	/* Both set unconditionally, because the measure layout is reused across
	 * every leaf on the output: a bound left behind by the previous call would
	 * truncate the next run. Unbounded is Pango's -1 rather than 0, which is a
	 * layout zero pixels wide. Where the cut lands is Pango's to choose, since
	 * only it knows where a cluster ends. */
	pango_layout_set_width(layout,
		max_width > 0 ? max_width * PANGO_SCALE : -1);
	pango_layout_set_ellipsize(layout,
		max_width > 0 ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE);
	pango_layout_set_text(layout, text, len);
}

void render_text_set_measure_scale(float scale) {
	render_measure_scale = scale > 0.0f ? scale : 1.0f;
}

Clay_Dimensions render_measure_text(Clay_StringSlice text,
		Clay_TextElementConfig *config, void *user_data) {
	(void)user_data;
	if (render_measure_layout == NULL) {
		render_pango = pango_font_map_create_context(
			pango_cairo_font_map_get_default());
		render_measure_layout = pango_layout_new(render_pango);
	}
	float scale = render_measure_scale;

	/* Measure at device size, report logical: Pango rounds glyph advances to
	 * whole DEVICE pixels, so dividing the device extent by scale hands Clay the
	 * exact logical size the raster will reproduce (the raster path uses the same
	 * device font size). Wrap and box sizing then match the raster to the pixel.
	 *
	 * Never bounded, whatever the declaration asked for: what a truncated run is
	 * bounded BY is derived from the box this measurement produces, so bounding
	 * the measurement too would feed that derivation its own output. */
	render_set_text(render_measure_layout, text.chars, text.length,
		config->fontId, config->fontSize, scale, 0);
	int width, height;
	pango_layout_get_pixel_size(render_measure_layout, &width, &height);

	return (Clay_Dimensions) { .width = width / scale, .height = height / scale };
}

void render_text_finish(void) {
	if (render_measure_layout != NULL) {
		g_object_unref(render_measure_layout);
		g_object_unref(render_pango);
		render_measure_layout = NULL;
		render_pango = NULL;
	}
}
