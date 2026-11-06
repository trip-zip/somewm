#ifndef SOMEWM_NODE_FACE_H
#define SOMEWM_NODE_FACE_H

#include <lua.h>

struct node;

struct node *node_face_check(lua_State *L, int index);
void node_face_forget(lua_State *L, struct node *n);
void node_face_class_setup(lua_State *L);
int node_owner_push(lua_State *L, struct node *n);
int node_face_push(lua_State *L, struct node *n);
int node_face_children(lua_State *L, struct node *n);

#endif
