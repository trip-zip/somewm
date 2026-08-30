/* The image cache: decode once per key, hand the renderer a stable entry, and
 * keep resident pixels under a byte budget. Ported from kiln (ui.c). */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <wlr/util/log.h>

#include "common/util.h"
#include "render_image.h"

/* Default image decode budget, MB. Two panel-sized wallpapers plus icon change;
 * a working set larger than the budget stays correct but re-decodes per frame.
 * SOMEWM_IMAGE_BUDGET_MB overrides. */
#define IMAGE_BUDGET_MB 64

struct image_cache {
	/* Entries are heap-stable for the process (Clay carries their addresses as
	 * imageData), so this holds pointers. */
	struct image_entry **images;
	size_t images_len, images_cap;
	size_t bytes, budget;
	uint64_t clock;
};

/* gdk-pixbuf gives non-premultiplied R,G,B[,A] bytes; cairo ARGB32 wants a
 * native-endian uint32 with premultiplied alpha (little-endian here, so the
 * bytes land B,G,R,A). Written from the gdk-pixbuf/cairo contracts, not lifted. */
static cairo_surface_t *pixbuf_to_cairo(GdkPixbuf *pb) {
	int w = gdk_pixbuf_get_width(pb);
	int h = gdk_pixbuf_get_height(pb);
	int channels = gdk_pixbuf_get_n_channels(pb);
	int pb_stride = gdk_pixbuf_get_rowstride(pb);
	bool has_alpha = gdk_pixbuf_get_has_alpha(pb);
	const guchar *pixels = gdk_pixbuf_get_pixels(pb);

	cairo_surface_t *surface = cairo_image_surface_create(
		CAIRO_FORMAT_ARGB32, w, h);
	if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(surface);
		return NULL;
	}
	int c_stride = cairo_image_surface_get_stride(surface);
	unsigned char *dst = cairo_image_surface_get_data(surface);
	for (int y = 0; y < h; y++) {
		const guchar *s = pixels + (size_t)y * pb_stride;
		uint32_t *d = (uint32_t *)(dst + (size_t)y * c_stride);
		for (int x = 0; x < w; x++) {
			uint8_t r = s[0], g = s[1], b = s[2];
			uint8_t a = has_alpha ? s[3] : 0xff;
			r = (uint8_t)((uint32_t)r * a / 255);
			g = (uint8_t)((uint32_t)g * a / 255);
			b = (uint8_t)((uint32_t)b * a / 255);
			d[x] = ((uint32_t)a << 24) | ((uint32_t)r << 16) |
				((uint32_t)g << 8) | (uint32_t)b;
			s += channels;
		}
	}
	cairo_surface_mark_dirty(surface);
	return surface;
}

static struct image_entry *image_find(struct image_cache *ic, const char *path) {
	for (size_t i = 0; i < ic->images_len; i++) {
		if (strcmp(ic->images[i]->path, path) == 0) {
			return ic->images[i];
		}
	}
	return NULL;
}

static void image_decode(struct image_entry *e) {
	e->decoded = true;
	GError *err = NULL;
	GdkPixbuf *pb = gdk_pixbuf_new_from_file(e->path, &err);
	if (pb == NULL) {
		e->failed = true;
		wlr_log(WLR_ERROR, "image decode failed for %s: %s", e->path,
			err != NULL ? err->message : "unknown");
		if (err != NULL) {
			g_error_free(err);
		}
		return;
	}
	e->native = pixbuf_to_cairo(pb);
	g_object_unref(pb);
	if (e->native == NULL) {
		e->failed = true;
		return;
	}
	e->width = cairo_image_surface_get_width(e->native);
	e->height = cairo_image_surface_get_height(e->native);
	e->failed = false;
	e->gen++;
}

/* Drop least-recently-declared decoded pixels until the budget holds. Entries
 * touched by the in-progress solve are exempt: their native pointer may be read
 * by this solve's reconcile. If everything resident is exempt, the budget yields
 * to the live set. Pixels only; the entry struct and its imageData pointer are
 * stable for the process. */
static void image_evict(struct image_cache *ic) {
	while (ic->bytes > ic->budget) {
		struct image_entry *lru = NULL;
		for (size_t i = 0; i < ic->images_len; i++) {
			struct image_entry *e = ic->images[i];
			if (e->native == NULL || e->touch >= ic->clock) {
				continue;
			}
			if (lru == NULL || e->touch < lru->touch) {
				lru = e;
			}
		}
		if (lru == NULL) {
			return;
		}
		cairo_surface_destroy(lru->native);
		lru->native = NULL;
		lru->decoded = false;
		ic->bytes -= lru->bytes;
		lru->bytes = 0;
	}
}

/* Find or create the entry for a key, without deciding anything about pixels.
 * The key is only a path when something means to decode a file from it. */
static struct image_entry *image_intern(struct image_cache *ic, const char *key) {
	struct image_entry *e = image_find(ic, key);
	if (e != NULL) {
		return e;
	}
	e = calloc(1, sizeof(*e));
	e->path = strdup(key);
	p_grow(&ic->images, ic->images_len + 1, &ic->images_cap);
	ic->images[ic->images_len++] = e;
	return e;
}

struct image_entry *image_cache_get(struct image_cache *ic, const char *path) {
	struct image_entry *e = image_intern(ic, path);
	e->touch = ic->clock;
	if (!e->decoded) {
		image_decode(e);
		if (e->native != NULL) {
			e->bytes = (size_t)cairo_image_surface_get_stride(e->native) *
				e->height;
			ic->bytes += e->bytes;
			image_evict(ic);
		}
	}
	return e;
}

bool image_cache_put(struct image_cache *ic, const char *key, int width,
		int height, int rowstride, bool has_alpha, int bits_per_sample,
		int channels, const uint8_t *pixels, size_t pixels_len) {
	int want_channels = has_alpha ? 4 : 3;
	/* The row span is compared in 64 bits: these numbers come straight off the
	 * D-Bus image-data hint, and width * channels overflows int to a negative
	 * (so passes this check) from width 2^29 up with four channels. The length
	 * check below still catches such a message on a 64-bit size_t, so this is
	 * the guard holding on its own rather than a reachable overread. */
	if (width <= 0 || height <= 0 || rowstride <= 0 || bits_per_sample != 8 ||
			channels != want_channels ||
			(int64_t)rowstride < (int64_t)width * channels) {
		return false;
	}
	/* The sender's own numbers say how much it should have sent. A message that
	 * disagrees with itself is a short buffer we would read off the end of. */
	size_t need = (size_t)rowstride * (size_t)(height - 1) +
		(size_t)width * (size_t)channels;
	if (pixels_len < need) {
		return false;
	}

	/* Borrowed, not owned: the pixbuf is a view over the caller's bytes for the
	 * length of the conversion, which copies into the cairo surface. */
	GdkPixbuf *pb = gdk_pixbuf_new_from_data(pixels, GDK_COLORSPACE_RGB,
		has_alpha, bits_per_sample, width, height, rowstride, NULL, NULL);
	if (pb == NULL) {
		return false;
	}
	cairo_surface_t *native = pixbuf_to_cairo(pb);
	g_object_unref(pb);
	if (native == NULL) {
		return false;
	}

	struct image_entry *e = image_intern(ic, key);
	if (e->native != NULL) {
		cairo_surface_destroy(e->native);
		ic->bytes -= e->bytes;
	}
	e->native = native;
	e->width = cairo_image_surface_get_width(native);
	e->height = cairo_image_surface_get_height(native);
	e->decoded = true;
	e->failed = false;
	/* gen is what tells the renderer to re-raster an entry whose pointer never
	 * changes, so a replacing image (a progress icon, a tray item swapping its
	 * icon) redraws instead of showing the old pixels. */
	e->gen++;
	e->bytes = (size_t)cairo_image_surface_get_stride(native) * e->height;
	e->touch = ic->clock;
	ic->bytes += e->bytes;
	image_evict(ic);
	return true;
}

void image_cache_reload(struct image_cache *ic, const char *path) {
	struct image_entry *e = image_find(ic, path);
	if (e == NULL) {
		return;
	}
	if (e->native != NULL) {
		cairo_surface_destroy(e->native);
		e->native = NULL;
		ic->bytes -= e->bytes;
		e->bytes = 0;
	}
	/* decoded=false forces the next declare's image_cache_get to re-decode and
	 * bump gen; the entry pointer (live imageData) is untouched. */
	e->decoded = false;
	e->failed = false;
}

void image_cache_begin_declare(struct image_cache *ic) {
	ic->clock++;
}

void image_cache_sweep(struct image_cache *ic) {
	image_evict(ic);
}

size_t image_cache_bytes(struct image_cache *ic) {
	return ic->bytes;
}

struct image_cache *image_cache_create(void) {
	struct image_cache *ic = calloc(1, sizeof(*ic));
	ic->budget = (size_t)IMAGE_BUDGET_MB << 20;
	const char *budget_mb = getenv("SOMEWM_IMAGE_BUDGET_MB");
	if (budget_mb != NULL && atoi(budget_mb) > 0) {
		ic->budget = (size_t)atoi(budget_mb) << 20;
	}
	return ic;
}

void image_cache_destroy(struct image_cache *ic) {
	for (size_t i = 0; i < ic->images_len; i++) {
		if (ic->images[i]->native != NULL) {
			cairo_surface_destroy(ic->images[i]->native);
		}
		free(ic->images[i]->path);
		free(ic->images[i]);
	}
	free(ic->images);
	free(ic);
}
