/*
 * version.c - Version and environment info for --version
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>

#include "common/lualib.h"
#include "version.h"

/* Get distro name from /etc/os-release */
static const char *
get_distro_name(void)
{
	static char distro[256] = "unknown";
	char line[256];
	FILE *f;

	f = fopen("/etc/os-release", "r");
	if (!f)
		return distro;

	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
			char *start = line + 12;
			size_t len;
			/* Strip leading quote */
			if (*start == '"') start++;
			len = strlen(start);
			/* Strip trailing newline and quote */
			while (len > 0 && (start[len-1] == '\n' || start[len-1] == '"'))
				start[--len] = '\0';
			snprintf(distro, sizeof(distro), "%s", start);
			break;
		}
	}
	fclose(f);
	return distro;
}

/* Get GPU info from /sys/class/drm */
static const char *
get_gpu_info(void)
{
	static char gpu[256] = "unknown";
	char path[64];
	char line[128];
	char driver[64] = "";
	char pci_id[32] = "";
	FILE *f;
	int i;

	/* Try card0, card1, etc. */
	for (i = 0; i < 4; i++) {
		snprintf(path, sizeof(path), "/sys/class/drm/card%d/device/uevent", i);
		f = fopen(path, "r");
		if (!f)
			continue;

		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "DRIVER=", 7) == 0) {
				char *start = line + 7;
				size_t len = strlen(start);
				if (len > 0 && start[len-1] == '\n')
					start[len-1] = '\0';
				snprintf(driver, sizeof(driver), "%s", start);
			} else if (strncmp(line, "PCI_ID=", 7) == 0) {
				char *start = line + 7;
				size_t len = strlen(start);
				if (len > 0 && start[len-1] == '\n')
					start[len-1] = '\0';
				snprintf(pci_id, sizeof(pci_id), "%s", start);
			}
		}
		fclose(f);

		if (driver[0]) {
			snprintf(gpu, sizeof(gpu), "%s%s%s%s", driver,
				pci_id[0] ? " (" : "", pci_id,
				pci_id[0] ? ")" : "");
			break;
		}
	}
	return gpu;
}

/* Get Lua runtime version string */
static const char *
get_lua_runtime_version(lua_State *L)
{
	static char version[128];

	/* Check for LuaJIT first */
	lua_getglobal(L, "jit");
	if (lua_istable(L, -1)) {
		lua_getfield(L, -1, "version");
		if (lua_isstring(L, -1)) {
			snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
			lua_pop(L, 2);
			return version;
		}
		lua_pop(L, 1);
	}
	lua_pop(L, 1);

	/* Fall back to standard Lua _VERSION */
	lua_getglobal(L, "_VERSION");
	if (lua_isstring(L, -1)) {
		snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
	} else {
		snprintf(version, sizeof(version), "unknown");
	}
	lua_pop(L, 1);
	return version;
}

/* Get LGI version */
static const char *
get_lgi_version(lua_State *L)
{
#ifdef LGI_VERSION
	/* Use compile-time detected version */
	(void)L;
	return LGI_VERSION;
#else
	/* Fallback to runtime detection */
	static char version[64] = "unknown";

	/* Try: require('lgi.version') */
	if (luaL_dostring(L, "return require('lgi.version')") == 0) {
		if (lua_isstring(L, -1)) {
			snprintf(version, sizeof(version), "%s", lua_tostring(L, -1));
		}
	}
	lua_pop(L, 1);
	return version;
#endif
}

/* Add search paths to a Lua state's package.path and package.cpath */
static void
add_search_paths_to_lua(lua_State *L, const char **paths, int count)
{
	const char *cur_path;

	for (int i = 0; i < count; i++) {
		const char *dir = paths[i];

		/* Add to package.path */
		lua_getglobal(L, "package");
		lua_getfield(L, -1, "path");
		cur_path = lua_tostring(L, -1);
		lua_pop(L, 1);
		lua_pushfstring(L, "%s/?.lua;%s/?/init.lua;%s", dir, dir, cur_path);
		lua_setfield(L, -2, "path");

		/* Add to package.cpath */
		lua_getfield(L, -1, "cpath");
		cur_path = lua_tostring(L, -1);
		lua_pop(L, 1);
		lua_pushfstring(L, "%s/?.so;%s", dir, cur_path);
		lua_setfield(L, -2, "cpath");

		lua_pop(L, 1); /* pop package table */
	}
}

/* Print comprehensive version info in markdown format */
void
print_version_info(const char **paths, int num_paths)
{
	struct utsname uts;
	lua_State *L;
	const char *wayland_display, *xdg_session_type;
	int is_nested;

	/* Get kernel/arch info */
	if (uname(&uts) < 0) {
		strcpy(uts.sysname, "unknown");
		strcpy(uts.release, "unknown");
		strcpy(uts.machine, "unknown");
	}

	/* Create Lua state for version detection */
	L = luaL_newstate();
	luaL_openlibs(L);

	/* Apply any -L search paths so we can find lgi */
	if (num_paths > 0)
		add_search_paths_to_lua(L, paths, num_paths);

	/* Detect session environment */
	wayland_display = getenv("WAYLAND_DISPLAY");
	xdg_session_type = getenv("XDG_SESSION_TYPE");
	is_nested = (wayland_display != NULL);

	/* Print markdown-formatted version info */
	printf("## somewm version info\n\n");

	printf("**somewm:** %s (%s)\n", VERSION, COMMIT_DATE);
	printf("**wlroots:** %s\n", WLROOTS_VERSION);
	printf("**Lua:** %s (compiled: %s)\n", get_lua_runtime_version(L), LUA_RELEASE);
	printf("**LGI:** %s\n", get_lgi_version(L));

#ifdef WITH_DBUS
	printf("**Build:** D-Bus=yes");
#else
	printf("**Build:** D-Bus=no");
#endif
#ifdef XWAYLAND
	printf(", XWayland=yes\n");
#else
	printf(", XWayland=no\n");
#endif

	printf("\n**System:**\n");
	printf("- Distro: %s\n", get_distro_name());
	printf("- Kernel: %s\n", uts.release);
	printf("- Arch: %s\n", uts.machine);
	printf("- GPU: %s\n", get_gpu_info());
	printf("- Session: %s (nested: %s)\n",
		xdg_session_type ? xdg_session_type : "unknown",
		is_nested ? "yes" : "no");

	lua_close(L);
	exit(EXIT_SUCCESS);
}
