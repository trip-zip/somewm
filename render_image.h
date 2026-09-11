#ifndef SOMEWM_RENDER_IMAGE_H
#define SOMEWM_RENDER_IMAGE_H

#include <cairo.h>
#include <stdbool.h>
#include <stdint.h>

/* What an IMAGE command's imageData points at: one cairo surface the
 * renderer scales and rounds into the solved box. The entry's address is
 * stable for as long as its owner lives (a drawin's content, border, shadow
 * and widget images, objects/drawin.h), so Clay carries it across the solve;
 * gen bumps whenever the pixels change, which is what tells the renderer to
 * re-raster a node whose pointer never moved. */
struct image_entry {
	cairo_surface_t *native;
	int width, height;
	uint64_t gen;
	uint8_t filter;      /* cairo_filter_t + 1, 0 keeps cairo's default */
	bool stretch;       /* Rastered once at its own size, scaled to the box by the scene. */
	bool natural;       /* Paint at logical size from the top-left corner. */
};

/* Hand an entry a new owned surface, destroying the previous one, and bump
 * its generation so the renderer re-rasters. NULL clears the entry; clearing
 * an empty one is a no-op. */
static inline void
image_entry_set(struct image_entry *entry, cairo_surface_t *owned)
{
	if (!entry->native && !owned)
		return;
	if (entry->native)
		cairo_surface_destroy(entry->native);
	entry->native = owned;
	entry->width = owned ? cairo_image_surface_get_width(owned) : 0;
	entry->height = owned ? cairo_image_surface_get_height(owned) : 0;
	entry->gen++;
}

#endif
