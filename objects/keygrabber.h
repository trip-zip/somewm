/*
 * keygrabber.h - Keygrabber object for modal key handling
 *
 * Copyright © 2024 somewm contributors
 * Based on AwesomeWM keygrabber patterns
 * Copyright © 2008-2009 Julien Danjou <julien@danjou.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#ifndef KEYGRABBER_H
#define KEYGRABBER_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>

void luaA_keygrabber_setup(lua_State *L);
bool some_keygrabber_is_running(void);
bool some_keygrabber_handle_key(uint32_t modifiers, uint32_t keysym, const char *keyname);

#endif /* KEYGRABBER_H */
