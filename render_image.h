#ifndef SOMEWM_RENDER_IMAGE_H
#define SOMEWM_RENDER_IMAGE_H

#include <cairo.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The image cache, ported from kiln (ui.h:165-205, ui.c). One entry per key,
 * decoded once (gdk-pixbuf) to a cairo surface the renderer scales and rounds
 * into the solved box. The entry pointer is stable for the process (it is what
 * Clay carries as imageData across the solve); only its contents change on
 * reload. gen bumps on every successful (re)decode so the renderer knows to
 * re-raster.
 *
 * Decoded pixels live under a byte budget, enforced after every decode and
 * again at the end of every solve: least-recently-declared surfaces are dropped
 * (pixels only; the entry struct stays, preserving pointer stability) and
 * re-decode on their next declare. Entries declared by the in-progress solve are
 * never dropped, so a live command's native pointer stays valid through its
 * reconcile. bytes is the decoded surface size; touch is the solve clock of the
 * last declare that asked for the entry.
 *
 * The cache is an explicit object rather than a field of an owner, because the
 * owner it hung off in kiln has no counterpart here yet; the declare pass takes
 * one in stage 4. */
struct image_entry {
	char *path;
	cairo_surface_t *native;
	int width, height;
	uint64_t gen;
	size_t bytes;
	uint64_t touch;
	bool decoded, failed;
	/* A surface made for one box and not yet painted: whoever draws into
	 * it paints it whole once, wherever their dirty region reaches. */
	bool fresh;
};

struct image_cache;

/* SOMEWM_IMAGE_BUDGET_MB overrides the default decode budget. */
struct image_cache *image_cache_create(void);
void image_cache_destroy(struct image_cache *ic);

/* Advance the eviction clock, once per solve before the declare pass: entries
 * this solve declares are stamped with the new value and exempt from eviction
 * until it passes. */
void image_cache_begin_declare(struct image_cache *ic);

/* Enforce the budget, once per solve after the reconcile. Not only at decode
 * time: a declare that stopped mentioning images must release their pixels, or
 * the cache is monotonic until the next unrelated decode. This solve's entries
 * are exempt by their touch stamp, and the reconcile is done, so nothing still
 * reads an older entry's surface. */
void image_cache_sweep(struct image_cache *ic);

/* Resolves path to its stable cache entry, decoding on first sight. Never stats
 * an already-cached path (the declare pass stays I/O free). */
struct image_entry *image_cache_get(struct image_cache *ic, const char *path);

/* Puts already-decoded pixels in the cache under a key, for images that arrive
 * in a message rather than on disk: the notification image-data hint, and tray
 * icons. The pixel layout is the hint's own (iiibiiay: width, height, rowstride,
 * has_alpha, bits_per_sample, channels, data), which is gdk-pixbuf's layout, so
 * the caller forwards it verbatim and owns nothing afterwards. false if the
 * message's own numbers do not describe the buffer it sent.
 *
 * The key is not a path and never resolves to one, which makes the entry
 * unre-decodable: an eviction is permanent and the leaf renders blank. That is
 * the existing failed-entry path, and it is not reachable for a displayed image,
 * since eviction claims the least-recently-DECLARED pixels. */
bool image_cache_put(struct image_cache *ic, const char *key, int width,
	int height, int rowstride, bool has_alpha, int bits_per_sample,
	int channels, const uint8_t *pixels, size_t pixels_len);

/* Drops the decoded surface so the next image_cache_get re-decodes and bumps
 * gen. The only invalidation there is; nothing implicit. */
void image_cache_reload(struct image_cache *ic, const char *path);

/* Profiling readback: resident decoded bytes. */
size_t image_cache_bytes(struct image_cache *ic);

#endif
