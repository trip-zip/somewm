#ifndef AWESOME_GESTURE_H
#define AWESOME_GESTURE_H

#include <lua.h>
#include <stdint.h>
#include <stdbool.h>

void luaA_gesture_setup(lua_State *L);
int luaA_gesture_check_swipe_begin(uint32_t time_msec, uint32_t fingers);
int luaA_gesture_check_swipe_update(uint32_t time_msec, uint32_t fingers, double dx, double dy);
int luaA_gesture_check_swipe_end(uint32_t time_msec, bool cancelled);
int luaA_gesture_check_pinch_begin(uint32_t time_msec, uint32_t fingers);
int luaA_gesture_check_pinch_update(uint32_t time_msec, uint32_t fingers, double dx, double dy, double scale, double rotation);
int luaA_gesture_check_pinch_end(uint32_t time_msec, bool cancelled);
int luaA_gesture_check_hold_begin(uint32_t time_msec, uint32_t fingers);
int luaA_gesture_check_hold_end(uint32_t time_msec, bool cancelled);

#endif
// vim: filetype=c:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
