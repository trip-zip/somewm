#ifndef SOMEWM_DECLARE_H
#define SOMEWM_DECLARE_H

#include <stdbool.h>
#include <stdint.h>

struct wlr_output;
struct Monitor;
struct render_client_hooks;
typedef struct drawin_t drawin_t;

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

/* Mark every output dirty: for facts without one owning output (stacking
 * order, banning, a drawin whose screen assignment may be stale). */
void declare_mark_all_dirty(void);

/* Run the declare pass for every dirty output now; called from the poll
 * function each loop iteration so input hit-testing reads a current scene
 * even when the backend delivers no frame events (a hidden nested output,
 * an asleep monitor). Returns the scene mutations that took. */
int declare_flush(void);

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

/* Test hook (awesome._test_widget_boxes): the boxes the last solve gave a
 * drawin's converted widget tree (widget.h), in the tree's preorder, one per
 * node that stands for a widget, drawin-local and rounded. Reads the output's
 * own context, so it reports what the frame drew rather than a second solve
 * of its own, and reports nothing until the declare pass has put the current
 * tree in front of Clay. Writes at most WIDGET_NODES_MAX entries and returns
 * how many. */
int declare_widget_boxes(drawin_t *d, int (*boxes)[4]);

/* Test hook (awesome._test_declare_order): the desktop band's draw order for
 * m, bottom to top, one entry per declared object. A fresh solve of the
 * current state with no reconcile, so it reads what the next frame would
 * draw without touching the scene; while the lua lock is up it still reports
 * the desktop band, which is the one it solves. Returns the entries written. */
int declare_output_order(struct declare_output *dout, struct Monitor *m,
	void **objects, int cap);

/* The declare handle inside a retained userData word (render.h): the low 40
 * bits are kind and registry id, the opacity byte rides above them. */
static inline uint64_t
declare_userdata_handle(void *userdata)
{
	return (uint64_t)(uintptr_t)userdata & 0xFFFFFFFFFFULL;
}

/* The solved tree of every output (or of `only`), in draw order: one header
 * line of counters per band, then one line per retained node naming its
 * element id, command type, z, solved box, realized box and what it is.
 * Reads back the last reconcile rather than solving again, and marks a node
 * the scene disagrees with, so a release build without the tree==scene
 * verifier still reports a divergence. The caller frees the string. */
char *declare_dump(struct Monitor *only);

/* The input backmap: the object whose leaf drew node (renderer-owned image
 * nodes, border sides, borrowed surface trees), or NULL for a node no band
 * drew. Searches every output's bands, desktop then lock, because the band
 * that drew a node is not always the one the node is over. */
struct wlr_scene_node;
void *declare_hit(struct wlr_scene_node *node, enum declare_kind *kind);

#endif
