/* TODO: Rename this module to something better than "awesome"
 * Options: somewm, core, compositor
 * Current name chosen for AwesomeWM API compatibility
 */

#ifndef OBJECTS_AWESOME_H
#define OBJECTS_AWESOME_H

#include <lua.h>

void luaA_awesome_setup(lua_State *L);
void luaA_awesome_set_conffile(lua_State *L, const char *conffile);

#endif /* OBJECTS_AWESOME_H */
