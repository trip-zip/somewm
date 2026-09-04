#ifndef SOMEWM_WIDGET_H
#define SOMEWM_WIDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <cairo.h>
#include <lua.h>

typedef struct drawin_t drawin_t;

/* One converted widget node, as lua/wibox/clay.lua describes it.
 *
 * The tree is stored in preorder: a node's subtree is the `children` nodes
 * that follow it, each with its own subtree. A node is pure description: what
 * it is (direction, sizing, gap, alignment, padding, colors, radius), never
 * where it is. A raster leaf carries a widget subtree the compile step could
 * not express, drawn by Lua into a surface of its own (the drawin's
 * widget_leaves, numbered in preorder too).
 *
 * Colors are straight alpha, 0-1, as everywhere else on this side; an alpha
 * of zero means the node draws no fill or no ring. */
struct widget_node {
	/* The widget's class name (wibox.widget.base's widget_name), interned
	 * so the whole struct still compares by memcmp. Only the tree dump
	 * (somewm-client clay tree) reads it: Clay carries no string from an
	 * element id to a render command. NULL for a node that stands for no
	 * widget. */
	const char *cls;
	uint16_t pad[4];     /* left, right, top, bottom */
	uint16_t bw[4];      /* border widths, same order */
	float bg[4];
	float border[4];
	float radius;
	bool fixed[2];       /* sized to size[] on this axis, else grows */
	float size[2];
	float max[2];        /* the grow ceiling per axis, 0 for none */
	uint8_t align[2];    /* child alignment per axis, Clay_LayoutAlignmentX/Y */
	uint16_t gap;        /* between children, along the direction */
	bool vertical;       /* children top to bottom, else left to right */
	bool floating;       /* attached to the parent's top left, off the flow */
	bool raster;         /* an image leaf */
	bool widget;         /* stands for a widget the layout engine also placed */
	uint16_t children;
};

/* A tree with more nodes than this is refused rather than truncated. A busy
 * bar (taglist plus tasklist) is a few hundred nodes; Clay's default context
 * holds 8192 elements (clay.h:1019), shared by every drawin on the output. */
#define WIDGET_NODES_MAX 1024

/* Whether d has to paint itself whole: shape_bounding and shape_clip are
 * applied to the drawable's own pixels (objects/drawin.c), which a converted
 * node is no longer part of; shape_input's pass-through would be swallowed by
 * a converted node's scene rect, which takes input everywhere it draws; a
 * translucent drawin blends once as one layer, where a tree of nodes each
 * carrying the opacity would blend every overlap twice; and the legacy tray
 * (awesome.systray) composites into the drawable's pixels. */
bool widget_nodes_refused(drawin_t *d);

/* For the setters that change that answer: when it flips, drop the tree and
 * ask Lua for a complete repaint (property::surface on the drawable), so the
 * drawable moves between painting whole and converting without a widget
 * having to redraw first. udx is the drawin's stack index, or 0 for a caller
 * that does not have it on the stack. */
void widget_nodes_gate(lua_State *L, drawin_t *d, int udx);

/* Read a tree from the table at absolute stack index idx (what
 * lua/wibox/clay.lua returns) and the leaf boxes at leaves_idx, and store
 * them on d, replacing whatever was there. Returns false and stores nothing
 * when the tree is malformed or the drawin is refused, which is Lua's signal
 * to paint the whole drawable itself. Leaf surfaces hold device pixels with
 * no device scale set, like every other image entry; a kept surface keeps
 * its pixels, so Lua repaints only what its dirty region says. */
bool widget_nodes_set(lua_State *L, drawin_t *d, int idx, int leaves_idx,
	float scale);
void widget_nodes_clear(drawin_t *d);

/* A new reference to leaf i's surface, for Lua to draw into and own the
 * reference of (the drawable.surface convention); NULL past the last leaf. */
cairo_surface_t *widget_leaf_surface(drawin_t *d, size_t i);

/* Bump the generation of every leaf whose index is a key in the table at
 * idx, so the renderer re-rasters exactly the leaves Lua redrew. */
void widget_leaves_drawn(lua_State *L, drawin_t *d, int idx);

#endif
