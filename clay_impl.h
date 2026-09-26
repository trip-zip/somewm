#pragma once
#include "clay.h"

struct clay_capacity {
    int32_t elements, capacity, map, freeIds, transitions;
};
struct clay_capacity clay_capacity(void);
/* Inspect borrowed payloads in the current context after Clay_EndLayout. */
bool clay_references_memory(const void *memory, size_t size, uintptr_t mask);

bool clay_declaration_full(void);
bool clay_capacity_failed(void);
bool clay_inspector_fits(int *elements, int *strings);
bool clay_inspector_duplicate(int first_inspector_element);

void clay_scroll_set(Clay_ElementId id, float x, float y);
void clay_clips_begin(int inspector_start, bool inspecting);
Clay_Vector2 clay_scroll_offset(Clay_ElementId id);
void clay_clip_restore(void);
/* Read a non-text element in the current declaration, without solving it. */
bool clay_element_declaration(Clay_ElementId id, Clay_ElementDeclaration *out);
/* Borrow the current context's last completed command array for readback. */
Clay_RenderCommandArray clay_render_commands(void);

/* Whether the current context holds a transition that has not settled. */
bool clay_transitions_active(void);

/* The solved tree as Clay holds it after Clay_EndLayout, for the dump:
 * roots in the order of the command array, each root's element index, and
 * one element by index. Reads only; nothing here declares or solves. */
struct clay_element_view {
	uint32_t id;
	Clay_String name;         /* the id string it was declared with */
	bool text;
	bool floating;
	bool exiting;
	Clay_ElementDeclaration config;   /* when !text */
	Clay_String text_string;          /* when text */
	uint16_t font;                    /* when text */
	const int32_t *children;
	uint16_t children_len;
};
int32_t clay_root_count(void);
int32_t clay_root_element(int32_t root);
void clay_element_view(int32_t index, struct clay_element_view *out);
