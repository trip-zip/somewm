#ifndef SOMEWM_RENDER_H
#define SOMEWM_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "clay.h"

struct wlr_scene_tree;
struct wlr_scene_node;

struct render_state;

/* How the renderer reaches client surfaces. resolve returns the client's
 * scene tree for a handle, or NULL if the client is gone (then the
 * renderer must not touch any stored pointer). configure asks the client
 * to match its solved box. borrow records the render_state that reparented
 * the tree as its current owner. release returns a borrowed tree to its
 * home parent, disabled, but only if the caller is still the owner: after a
 * client migrates to another output, the old output's sweep must not
 * disable a node the new owner is showing. The owner token is an opaque
 * render_state pointer. reposition notes that a borrowed tree moved this
 * frame (its solved position changed), so the owner can re-derive anything
 * keyed to the tree's scene position, namely xdg-popup unconstrain and X11
 * root coordinates. C to C, never Lua; optional (a NULL reposition is not
 * called).
 *
 * The renderer holds no client knowledge. Nothing implements these hooks yet:
 * somewm's mapping (handle = the client, resolve returns c->scene) arrives with
 * the declare pass in stage 4. */
struct render_client_hooks {
	struct wlr_scene_tree *(*resolve)(void *data, uint64_t handle);
	void (*configure)(void *data, uint64_t handle, int width, int height);
	void (*borrow)(void *data, uint64_t handle, void *owner);
	void (*release)(void *data, uint64_t handle, void *owner);
	void (*reposition)(void *data, uint64_t handle);
	/* True while the client presents a live xdg-popup: the reconciler folds it
	 * to the top of the draw order so the popup, which may overhang into a
	 * neighbor tile, is not occluded by that sibling. C to C, never Lua;
	 * optional (a NULL has_popup means no client is ever folded up). */
	bool (*has_popup)(void *data, uint64_t handle);
	void *data;
};

struct render_state *render_create(struct wlr_scene_tree *parent);

/* Show or hide everything this render_state drew, without dropping the retained
 * nodes, so a band that is raised again does not first flash its last frame. */
void render_set_enabled(struct render_state *rs, bool on);
void render_destroy(struct render_state *rs,
	const struct render_client_hooks *hooks);

/* Reconcile a solved command array into the scene. Returns the number of
 * scene mutations performed (0 for an identical frame). Afterwards, in builds
 * compiled with SOMEWM_RENDER_VERIFY, the tree==scene verifier compares every
 * command box against the scene and aborts on divergence. */
int render_reconcile(struct render_state *rs, Clay_RenderCommandArray commands,
	const struct render_client_hooks *hooks);

/* Move the per-output UI tree to the output's position in the layout. */
void render_set_position(struct render_state *rs, int x, int y);

/* The output's scale, applied to every raster from the next reconcile on: buffers
 * are sized in device pixels (edges rounded in device space, so shared tile edges
 * cannot seam) and content is drawn at device density, so a fractional output is
 * sharp. Clay still solves in logical px (wlr_output_effective_resolution divides
 * by scale), so this touches only the raster, never the layout. A change re-rasters
 * this output's nodes (scale joins the raster cache key). */
void render_set_scale(struct render_state *rs, float scale);

/* The userData channel: Clay carries each element's userData word into its
 * render commands untouched, and the renderer retains it per node. The word
 * is a packed integer, never a pointer, so a retained command can never
 * dangle into freed declarer state. The renderer itself reads only the
 * opacity byte (bits 40-47, IMAGE commands; 0 means unset, fully opaque,
 * else 1 + opacity * 254); everything else in the word is the declarer's to
 * encode and to get back from render_hit_userdata(). */
static inline float
render_userdata_opacity(void *ud)
{
	unsigned byte = ((uintptr_t)ud >> 40) & 0xff;
	return byte ? (float)(byte - 1) / 254.0f : 1.0f;
}

/* The retained userData word of the command that drew node (the node itself,
 * or an ancestor for a border's side rects), or 0 for a node this
 * render_state did not draw. Works for every command type, which is what
 * makes it the input backmap: BORDER and TEXT nodes carry no element id
 * (render_hit_id below) but do carry their element's word. */
void *render_hit_userdata(struct render_state *rs, struct wlr_scene_node *node);

/* The scene-node-to-Clay-id backmap: given a scene node the scene hit test
 * returned, find the retained chrome node that drew it (the node itself, or an
 * ancestor for a square border's side rects) and return that command's Clay
 * element id. Only RECTANGLE, IMAGE, and CUSTOM commands carry the element id
 * directly; TEXT and BORDER commands carry a Clay-derived per-line / per-side
 * hash that is not the element id, so those report 0 (not comparable to
 * Clay_GetPointerOverIds). Also 0 for a node this render_state did not draw (a
 * client surface, another output's chrome). Chrome is small and hit events are
 * rare, so a linear scan is fine.
 *
 * One RECTANGLE is not an element: for a border with betweenChildren > 0 Clay
 * emits a divider rectangle per gap carrying Clay__HashNumber(parentId, n)
 * (clay.h:3002, 3017). That id is well-formed but names no element, and the
 * command array carries no flag telling it apart from a real one, so a caller
 * must treat an id that resolves to nothing as no match rather than as an
 * unknown widget. */
uint32_t render_hit_id(struct render_state *rs, struct wlr_scene_node *node);

/* Profiling readback, logged on every solve so a long-running session can
 * assert growth stays proportional to on-screen content: live retained nodes,
 * resident cairo raster bytes across them, and buffers allocated by the last
 * reconcile pass. */
size_t render_node_count(struct render_state *rs);
size_t render_raster_bytes(struct render_state *rs);
int render_buffers_created(struct render_state *rs);

#endif
