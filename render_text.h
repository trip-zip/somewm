#ifndef SOMEWM_RENDER_TEXT_H
#define SOMEWM_RENDER_TEXT_H

#include <pango/pango.h>
#include <stdint.h>

#include "clay.h"

/* The font table and the shared text setup, ported from kiln (ui.h:115-163,
 * ui.c). The table is file-static in render_text.c rather than a field of an
 * owner object because the raster path is handed a render command and a scale
 * and has no owner to reach, and the measure and the raster have to resolve an
 * id the same way or text wraps where it does not draw. */

/* Intern a Pango font description into the font table, returning the id a text
 * declaration carries as fontId, so a config names a face in the string form
 * Pango parses and never handles the integer Clay actually carries. Ids are
 * write-once, so one stays safe to hold for as long as the process lives.
 *
 * No length argument, because Pango wants the NUL a Lua string already carries,
 * not a count.
 *
 * Negative is a refusal:
 *
 *   RENDER_FONT_ERR_SIZE  the description carries a size, which would be
 *                         silently overridden because size is its own channel,
 *                         set at the output's device scale per call.
 *   RENDER_FONT_ERR_FULL  the table is at its cap.
 *
 * A family no font on the system provides is not a refusal; Pango substitutes,
 * which keeps a typo a visual bug instead of a dead session. */
#define RENDER_FONT_ERR_SIZE (-1)
#define RENDER_FONT_ERR_FULL (-2)
int32_t render_font_intern(const char *name);

/* Flags a text declaration carries through Clay's per-element userData, which is
 * documented as passed through untouched to the render command (clay.h:375-376,
 * 688-689) and is not part of the measure cache key (clay.h:1508-1531, which
 * hashes only the text, fontId, fontSize and letterSpacing). A flag word in a
 * pointer slot because that slot is the only channel from a text declaration
 * to the renderer that Clay leaves to its host: everything else on a text
 * config has a meaning Clay assigns. */
#define RENDER_TEXT_ELLIPSIZE 1u

/* Shared font and text setup so measurement and rasterization agree, on every
 * axis that decides a glyph run's extent. font_id resolves through the font
 * table above, and is in this signature rather than read from somewhere both
 * callers reach so that a face reaching one path and not the other is a compile
 * error: it would otherwise show up as text wrapping where it does not draw.
 * scale is the output's scale, and the font is set at device size (font_size *
 * scale) so measurement and the raster both work in device pixels, which is
 * what keeps a fractional output's text sharp and its wrap decisions matching
 * the raster.
 *
 * max_width is a device-pixel bound past which the run is truncated with an
 * ellipsis, or 0 for none. It is in this signature for the same reason font_id
 * is, and the measure path is the caller that must always pass 0: a measure
 * bounded by the same number the bound is derived FROM would shrink the box, and
 * a smaller box means a tighter bound, which is a run that truncates itself away
 * over a few frames. */
void render_set_text(PangoLayout *layout, const char *text, int len,
	uint16_t font_id, uint16_t font_size, float scale, int max_width);

/* The scale of the output currently solving, published before each Clay pass so
 * the measure callback below measures text at that output's device size. Its own
 * channel rather than the callback's userData because there is no per-output
 * object on this side of the port yet; the declare pass sets it in stage 4. */
void render_text_set_measure_scale(float scale);

/* Clay's measure callback, handed to Clay_SetMeasureTextFunction once per
 * context. Pure and callable at any point in a solve, because Clay caches
 * measured words across frames and only calls in on a miss. */
Clay_Dimensions render_measure_text(Clay_StringSlice text,
	Clay_TextElementConfig *config, void *user_data);

/* Drop the shared measure layout. The font table is process-lifetime by design
 * (ids are write-once), so it is not touched. */
void render_text_finish(void);

#endif
