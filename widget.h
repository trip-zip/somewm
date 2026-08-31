#ifndef SOMEWM_WIDGET_H
#define SOMEWM_WIDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <lua.h>

typedef struct drawin_t drawin_t;

/* One converted widget container, as lua/wibox/clay.lua describes it.
 *
 * The chain is a list, not a tree: conversion walks down from the drawable's
 * root widget and stops at the first node it cannot express, so every node
 * has exactly one child and the last node is always the raster leaf, the
 * drawable's own surface holding whatever the walk did not reach.
 *
 * Colors are straight alpha, 0-1, as everywhere else on this side; an alpha
 * of zero means the node draws no fill or no ring. */
struct widget_node {
	uint16_t pad[4];     /* left, right, top, bottom */
	uint16_t bw[4];      /* border widths, same order */
	float bg[4];
	float border[4];
	float radius;
	bool raster;
};

/* A chain longer than this is refused rather than truncated. Deep enough
 * that no real config reaches it, and it bounds the per-drawin element
 * count the output's Clay arena has to hold. */
#define WIDGET_NODES_MAX 32

/* Read a chain from the array at absolute stack index idx (what
 * lua/wibox/clay.lua returns) and store it on d, replacing whatever was
 * there. Returns false
 * and stores nothing when the chain is malformed or the drawin cannot take
 * one, which is Lua's signal to paint the whole drawable itself.
 *
 * A shaped drawin is refused: shape_bounding and shape_clip are applied to
 * the drawable's own pixels (objects/drawin.c), which a converted container
 * is no longer part of, and shape_input's pass-through would be swallowed by
 * the converted node's scene rect, which takes input everywhere it draws. */
bool widget_nodes_set(lua_State *L, drawin_t *d, int idx);
void widget_nodes_clear(drawin_t *d);

#endif
