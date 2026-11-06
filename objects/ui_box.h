#ifndef SOMEWM_UI_BOX_H
#define SOMEWM_UI_BOX_H

#include <lua.h>
#include "../node.h"

int ui_box_new(lua_State *L);
bool ui_box_get(lua_State *L, struct node *n, const char *word);
int ui_box_set(lua_State *L, struct node *n, const char *word, int value);
void ui_box_transition(lua_State *L, struct node *box, bool off,
	struct widget_transition *out);
void ui_box_dirty(struct node *n);
void ui_box_detach(lua_State *L, struct node *n);
void ui_box_release(struct node *n);
void ui_box_pointer_move(lua_State *L, drawin_t *d, int x, int y);
void ui_box_pointer_leave(lua_State *L);
const char *ui_box_pointer_cursor(drawin_t *d);
void ui_box_button(lua_State *L, drawin_t *d, int x, int y, uint32_t button,
	uint32_t mods, bool press);

#endif
