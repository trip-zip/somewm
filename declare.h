#ifndef SOMEWM_DECLARE_H
#define SOMEWM_DECLARE_H

#include <stdbool.h>
#include <stdint.h>

#include "render.h"

struct widget_host;
struct wlr_output;
struct Monitor;
struct render_client_hooks;
typedef struct drawin_t drawin_t;

/* Per-output declare/solve state: the output's one Clay context, the
 * retained render_state its solved commands reconcile into, and the dirty
 * flag the frame handler consumes. The lock screen is part of that tree,
 * not a second one. */
struct declare_output;
#define CLAY_ELEMENTS_MAX 65536
size_t declare_widget_budget(struct declare_output *dout);
void declare_output_resource_failure(struct declare_output *dout);
/* Private test-build controls for newly created contexts and solve failures. */
void declare_test_capacity(int capacity, int allocation_failures);
void declare_test_failure(struct declare_output *dout, int pass, int elements);

struct declare_output *declare_output_create(struct wlr_output *wlr_output);
void declare_output_destroy(struct declare_output *dout);

/* Layout position and scale, re-applied on every updatemons pass. */
void declare_output_update(struct declare_output *dout, int lx, int ly);

/* Mark the output's tree stale and schedule a frame to rebuild it. The mark
 * also arms a short deadline: an output whose backend sends no frame event
 * (a nested window on an unviewed tag, an asleep monitor) runs its frame
 * when that fires, so its scene and its Lua boxes still settle. */
void declare_output_mark_dirty(struct declare_output *dout);
/* Private grid readback changed declarations; finish its dependency stages
 * within the frame transaction before pixels and native input become visible. */
void declare_output_grid_pending(struct declare_output *dout);

/* Mark every output dirty: for facts without one owning output (stacking
 * order, banning, a drawin whose screen assignment may be stale). */
void declare_mark_all_dirty(void);

/* The pointer moved or its image changed: the output under the pointer and
 * every output whose tree shows the pointer run a frame. A no-op while the
 * pointer is where the last frame declared it with the same image, so the
 * hit-test rerun a frame ends with cannot start another frame. */
void declare_cursor_changed(void);
/* How long a tiled client's box takes to reach a new allocation, in
 * seconds. Zero snaps. */
void declare_client_transition(float seconds);
/* Release retained nodes while their owning objects are still alive. */
void declare_hot_reload(void);
void declare_state_clear(void);
bool declare_in_frame(void);

/* If dirty, run the frame: the global signal clay::declare has Lua compile
 * the drawables that changed and store their trees, the output's scene
 * declares into its Clay context and solves. Changed trees and trees with
 * scroll records send clay::solved with their boxes and ids, and the commands
 * reconcile into wlr_scene. A clay::solved handler
 * that dirties the output again gets one more declare and solve before the
 * reconcile. Returns the mutation count, or -1 when the output was clean
 * and nothing ran. While the session is locked the same pass adds the lock
 * section on top of the same tree, and the frame reads the lock state
 * itself rather than taking it from the caller. */
int declare_output_frame(struct declare_output *dout, struct Monitor *m);

/* The Clay debug inspector (clay.h:897-899, Clay__RenderDebugView at
 * clay.h:3378). Clay draws the panel inside Clay_EndLayout when the
 * context's flag is set, so its commands reconcile like every other. The
 * flag is per screen, read back rather than copied, since the panel closes
 * itself from inside the solve. Clay declares the panel above every band
 * this compositor can name, so a locked session never sets the flag for
 * the solve (declare_output_frame). */
bool declare_inspector_get(struct declare_output *dout);
void declare_inspector_set(struct declare_output *dout, bool on);

/* The panel's style is process-global (the palette and width are globals in
 * clay.h, the font is entry 0 of the font table), so a write is addressed
 * to no screen: every output showing the panel is marked dirty. Colors are
 * 0-255 in the order bg, bg_alt, border, fg, bg_selected, highlight. font
 * is a Pango description for entry 0, or NULL to leave it; the return is
 * render_font_set_default's. */
struct declare_inspector_style {
	float colors[6][4];
	float width;
};
int declare_inspector_style(const struct declare_inspector_style *style,
	const char *font);

/* The seat mirror the panel's own click handling reads through
 * the frame: facts only, no policy. down is 1, 0, or -1 for unchanged
 * (motion); press_edge latches a press onto the output under the cursor for
 * its next solve to turn into Clay's PRESSED_THIS_FRAME. Position is read
 * from the cursor at feed time. A no-op while no screen has the panel up. */
void declare_inspector_pointer(int down, bool press_edge);
/* Accumulate wheel input for the output under the cursor. */
void declare_wheel(double dx, double dy);
/* True when the point lies inside the panel of an inspecting output: input
 * there is the panel's, and input.c gives none of it to Lua or clients. */
bool declare_inspector_covers(double lx, double ly);

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
	DECLARE_KIND_TITLEBAR,
	/* The object is the Monitor whose wallpaper crop OUTPUT shows. */
	DECLARE_KIND_WALLPAPER,
	/* The object is a wlr_session_lock_surface_v1 (ext-session-lock);
	 * its output's Monitor holds the borrow owner slot. */
	DECLARE_KIND_LOCK,
	/* The lock backdrop, whose object is the output's declare_output. It
	 * draws the opaque cover and it answers the input walk with nothing,
	 * which is what keeps the desktop below it from taking input. */
	DECLARE_KIND_LOCK_BLOCK,
	/* The object is the seat's wlr_drag_icon; its data is the scene tree
	 * wlr_scene_drag_icon_create made for it. */
	DECLARE_KIND_DRAG,
	/* The object is a Popup (window.h): an xdg popup with its own tree. */
	DECLARE_KIND_POPUP,
	/* The pointer image (input.h, cursor_image): the object is the
	 * wlr_cursor for a themed image leaf, or the client's cursor surface
	 * for a borrowed one. It passes every hit through. */
	DECLARE_KIND_CURSOR,
};

uint64_t declare_handle_for(void *object, enum declare_kind kind);
void *declare_handle_get(uint64_t handle, enum declare_kind *kind);
void declare_handle_drop(void *object);

/* Test hook (awesome._test_widget_boxes): the boxes the last solve gave a
 * drawin's converted widget tree (widget.h), in the tree's preorder, one per
 * node that stands for a widget, drawin-local and rounded. Reads the output's
 * own context, so it reports what the frame drew rather than a second solve
 * of its own, and reports nothing until the declare pass has put the current
 * tree in front of Clay. Writes at most WIDGET_NODES_MAX entries and returns
 * how many. */
int declare_widget_boxes(const struct widget_host *host, int (*boxes)[4]);
Clay_Context *declare_output_context(struct declare_output *dout);
Clay_Context *declare_widget_context(const struct widget_host *host);

/* The widget nodes of d's converted tree under a drawin-local point, as
 * Clay's pointer query answers it against the output's last solve
 * (Clay_SetPointerState, Clay_GetPointerOverIds): preorder indices of the
 * nodes that stand for a widget, outermost first, up to cap. 0 until the
 * tree has been declared, and while a failed context awaits a valid frame. */
int declare_widget_hits(const struct widget_host *host, double x, double y, int *out, int cap);

/* Test hook (awesome._test_declare_order): the output's draw order for the
 * last completed solve, bottom to top. No declaration, solve or scene
 * mutation occurs. */
int declare_output_order(struct declare_output *dout,
	void **objects, int cap);

/* The declare handle inside a retained userData word (render.h): the low 40
 * bits are kind and registry id, the renderer's three bytes ride above
 * them. */
static inline uint64_t
declare_userdata_handle(void *userdata)
{
	return (uint64_t)(uintptr_t)userdata & RENDER_UD_OWNER_MASK;
}

/* The tree of every output (or of `only`): a header of counters,
 * the flow-root, floating-root and derived counts, the declared hierarchy
 * as the last frame's pass recorded it (role, object, sizing and its
 * source, flow, attachment, solved box), the drawins it refused, and the
 * realized list of retained nodes in draw order with their element id,
 * command type, z, solved and realized boxes. Reads back the last frame
 * rather than solving again, and marks a node the scene disagrees with, so
 * a release build without the tree==scene verifier still reports a
 * divergence. The caller frees the string. */
char *declare_dump(struct Monitor *only);

/* What is under a layout point, by walking the declared tree: the retained
 * draw order from the top, the output under the point first, then the other
 * outputs', so chrome overhanging onto a neighbor is still found. While the
 * session is locked the lock backdrop is at the top of that order and takes
 * every point, so nothing below it answers. A
 * candidate is accepted by what it stands for: a surface at its input
 * region, a drawin by its shape and pass-through flag, a titlebar or a
 * client's border anywhere; a refusal continues below. kind is 0 when
 * nothing accepts. For a popup the object is its toplevel. */
struct declare_hit {
	enum declare_kind kind;
	void *object;
	struct wlr_surface *surface;   /* the leaf surface, for surface kinds */
	double sx, sy;                 /* surface-local */
};
void declare_hit_at(double lx, double ly, struct declare_hit *out);

/* The screenshot backmap: the object whose leaf drew node, or NULL for a
 * node no band drew. Searches every output's band. */
struct wlr_scene_node;
void *declare_hit(struct wlr_scene_node *node, enum declare_kind *kind);

#endif
