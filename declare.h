#ifndef SOMEWM_DECLARE_H
#define SOMEWM_DECLARE_H

#include <stdbool.h>
#include <stdint.h>

struct wlr_output;
struct Monitor;
struct render_client_hooks;

/* Per-output declare/solve state: the output's Clay context, the retained
 * render_state its solved commands reconcile into, and the dirty flag the
 * frame handler consumes. Inert until the frame handler runs declare, solve,
 * reconcile; created early so the flip edits the frame path, not the output
 * lifecycle. */
struct declare_output;

struct declare_output *declare_output_create(struct wlr_output *wlr_output);
void declare_output_destroy(struct declare_output *dout);

/* Layout position and scale, re-applied on every updatemons pass. */
void declare_output_update(struct declare_output *dout, int lx, int ly);

/* Mark the output's tree stale and schedule a frame to rebuild it. */
void declare_output_mark_dirty(struct declare_output *dout);

/* If dirty, declare the output's scene into its Clay context, solve, and
 * reconcile into wlr_scene. Returns the mutation count, or -1 when the
 * output was clean and nothing ran. While the lua lock is active
 * (lock_active), the lock scene solves instead, in a second per-output
 * context reconciling into a band in LyrBlock; the desktop band keeps its
 * last scene, occluded by locked_bg below that band. */
int declare_output_frame(struct declare_output *dout, struct Monitor *m,
	bool lock_active);

/* Show or hide every output's retained lock band, and dirty all outputs;
 * called on lua lock engage and disengage. Hiding keeps the retained nodes,
 * so re-engaging does not first flash the previous lock frame. */
void declare_lock_set_visible(bool on);

/* How the reconciler reaches surface scene trees (render.h); implemented by
 * window.c, set once at startup, before any output declares. */
void declare_set_client_hooks(const struct render_client_hooks *hooks);

/* Renderer handles: what the declare pass stores in a CUSTOM command and the
 * hooks get back. The kind rides the top 32 bits, a registry id the bottom.
 * Ids are assigned lazily at first declare; declare_handle_drop at object
 * destroy is what makes a later resolve of the dead handle return NULL. */
enum declare_kind {
	DECLARE_KIND_CLIENT = 1,
	DECLARE_KIND_LAYER,
	DECLARE_KIND_DRAWIN,
};

void *declare_handle_get(uint64_t handle, enum declare_kind *kind);
void declare_handle_drop(void *object);

/* The input backmap: the object whose leaf drew node (renderer-owned image
 * nodes, border sides, borrowed surface trees), or NULL for a node this
 * output's bands did not draw. Checks the desktop band, then the lock band. */
struct wlr_scene_node;
void *declare_output_hit(struct declare_output *dout,
	struct wlr_scene_node *node, enum declare_kind *kind);

#endif
