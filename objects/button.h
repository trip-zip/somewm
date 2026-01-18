#ifndef SOMEWM_BUTTON_H
#define SOMEWM_BUTTON_H

#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stdbool.h>
#include "common/luaclass.h"
#include "common/luaobject.h"
#include "common/array.h"
#include "common/util.h"
#include "../globalconf.h"

/* Forward declarations */
typedef struct button_t button_t;

/* Button modifiers - match wlr_keyboard_modifiers */
#define BUTTON_MODIFIER_SHIFT   (1 << 0)
#define BUTTON_MODIFIER_CAPS    (1 << 1)
#define BUTTON_MODIFIER_CTRL    (1 << 2)
#define BUTTON_MODIFIER_ALT     (1 << 3)
#define BUTTON_MODIFIER_MOD2    (1 << 4)
#define BUTTON_MODIFIER_MOD3    (1 << 5)
#define BUTTON_MODIFIER_SUPER   (1 << 6)  /* Mod4/Super/Windows key */
#define BUTTON_MODIFIER_MOD5    (1 << 7)
#define BUTTON_MODIFIER_ANY     0xFFFF    /* Match any modifiers */

/* Button object structure - AwesomeWM compatible */
struct button_t {
    /* AwesomeWM object header (signals, ref counting, etc.) */
    LUA_OBJECT_HEADER

    /* Modifier mask (shift, ctrl, alt, super, etc.) */
    uint16_t modifiers;

    /* Button number (1=left, 2=middle, 3=right, 4/5=scroll, 0=any) */
    uint32_t button;
};

/* AwesomeWM class system - button class */
extern lua_class_t button_class;

/* Generate helper functions for button class lifecycle */
LUA_OBJECT_FUNCS(button_class, button_t, button)

/* Button array functions - AwesomeWM ARRAY_FUNCS macro generates:
 * - button_array_init/wipe/append/splice/take/remove functions
 * Typedef created in globalconf.h via ARRAY_TYPE(button_t *, button)
 * DO_NOTHING = no destructor (Lua GC manages button objects) */
ARRAY_FUNCS(button_t *, button, DO_NOTHING)

/* Lua button array conversions (AwesomeWM compatible) */
void luaA_button_array_set(lua_State *L, int oidx, int idx, button_array_t *buttons);
int luaA_button_array_get(lua_State *L, int oidx, button_array_t *buttons);

/* Check if a button event matches any button in array */
bool button_array_check(button_array_t *buttons, uint16_t modifiers, uint32_t button,
                        lua_State *L, int drawin_idx);

/* Legacy button checking functions (for backward compatibility with somewm.c) */
int luaA_button_check(uint32_t mods, uint32_t button);

/* AwesomeWM-compatible button checking (two-stage signal emission)
 * \param drawin_ptr Drawin pointer
 * \param x Relative X coordinate (drawin-relative)
 * \param y Relative Y coordinate (drawin-relative)
 * \param button Button code
 * \param mods Modifier mask
 * \param is_press true for button press, false for release
 * \return 1 if handled, 0 otherwise
 */
int luaA_drawin_button_check(void *drawin_ptr, int x, int y, uint32_t button,
                             uint32_t mods, bool is_press);

/* Emit button signals directly on a drawable (for titlebars)
 * \param client_ptr Client pointer (client_t*) - needed to access titlebar drawable
 * \param drawable_ptr Drawable pointer (drawable_t*)
 * \param x Relative X coordinate
 * \param y Relative Y coordinate
 * \param button Button code
 * \param mods Modifier mask
 * \param is_press true for press, false for release
 */
void luaA_drawable_button_emit(void *client_ptr, void *drawable_ptr, int x, int y,
                               uint32_t button, uint32_t mods, bool is_press);

/* AwesomeWM-compatible client button checking (two-stage signal emission)
 * \param client_ptr Client pointer (client_t*)
 * \param x Relative X coordinate (client-relative)
 * \param y Relative Y coordinate (client-relative)
 * \param button Button code
 * \param mods Modifier mask
 * \param is_press true for button press, false for release
 * \return 1 if handled, 0 otherwise
 */
int luaA_client_button_check(void *client_ptr, int x, int y, uint32_t button,
                             uint32_t mods, bool is_press);

/* Translate Linux input button code to X11-style button number */
uint32_t translate_button_code(uint32_t linux_button);

/* Button class setup (AwesomeWM class system) */
void button_class_setup(lua_State *L);

#endif /* SOMEWM_BUTTON_H */