#include "check_config.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>

/** Pattern severity levels for config scanner */
typedef enum {
	SEVERITY_INFO,      /* May not work, but won't break config */
	SEVERITY_WARNING,   /* Needs Wayland alternative */
	SEVERITY_CRITICAL   /* Will fail or hang on Wayland */
} x11_severity_t;

/** Pattern entry for config scanning.
 * Used for both X11 compat checks and deprecated API detection.
 */
typedef struct {
	const char *pattern;      /* Simple substring to search for */
	const char *description;  /* Human-readable description */
	const char *suggestion;   /* How to fix it */
	x11_severity_t severity;  /* How serious the issue is */
} check_pattern_t;

static const check_pattern_t x11_patterns[] = {
	/* === CRITICAL: Will fail or hang === */

	/* X11 property APIs - safe no-op stubs that won't hang
	 * Downgraded to WARNING since they just return nil, not block */
	{"awesome.get_xproperty", "awesome.get_xproperty() [X11 only]",
	 "Use persistent storage (gears.filesystem) or remove", SEVERITY_WARNING},
	{"awesome.set_xproperty", "awesome.set_xproperty() [X11 only]",
	 "Use persistent storage (gears.filesystem) or remove", SEVERITY_WARNING},
	{"awesome.register_xproperty", "awesome.register_xproperty() [X11 only]",
	 "Remove - X11 properties don't exist on Wayland", SEVERITY_WARNING},

	/* Blocking X11 tool calls that will hang */
	{"io.popen(\"xrandr", "io.popen with xrandr (blocks)",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"io.popen('xrandr", "io.popen with xrandr (blocks)",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"io.popen(\"xwininfo", "io.popen with xwininfo (blocks)",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"io.popen('xwininfo", "io.popen with xwininfo (blocks)",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"io.popen(\"xdotool", "io.popen with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"io.popen('xdotool", "io.popen with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"io.popen(\"xprop", "io.popen with xprop (blocks)",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"io.popen('xprop", "io.popen with xprop (blocks)",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"io.popen(\"xrdb", "io.popen with xrdb (blocks)",
	 "Use beautiful.xresources.get_current_theme() instead", SEVERITY_CRITICAL},
	{"io.popen('xrdb", "io.popen with xrdb (blocks)",
	 "Use beautiful.xresources.get_current_theme() instead", SEVERITY_CRITICAL},

	/* os.execute blocks even harder */
	{"os.execute(\"xrandr", "os.execute with xrandr (blocks)",
	 "Use awful.spawn.easy_async instead", SEVERITY_CRITICAL},
	{"os.execute('xrandr", "os.execute with xrandr (blocks)",
	 "Use awful.spawn.easy_async instead", SEVERITY_CRITICAL},
	{"os.execute(\"xdotool", "os.execute with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"os.execute('xdotool", "os.execute with xdotool (blocks)",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},

	/* Shell subcommand patterns in strings */
	{"$(xrandr", "shell subcommand with xrandr",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"`xrandr", "shell subcommand with xrandr",
	 "Use screen:geometry() or screen.outputs instead", SEVERITY_CRITICAL},
	{"$(xwininfo", "shell subcommand with xwininfo",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"`xwininfo", "shell subcommand with xwininfo",
	 "Use client.geometry or mouse.coords instead", SEVERITY_CRITICAL},
	{"$(xdotool", "shell subcommand with xdotool",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"`xdotool", "shell subcommand with xdotool",
	 "Use awful.spawn or client:send_key() instead", SEVERITY_CRITICAL},
	{"$(xprop", "shell subcommand with xprop",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},
	{"`xprop", "shell subcommand with xprop",
	 "Use client.class or client.instance instead", SEVERITY_CRITICAL},

	/* GTK/GDK loading via LGI - display init during config load.
	 * GTK: somewm preloads empty lgi.override.Gtk to prevent deadlock,
	 *       but display-dependent GTK features won't work.
	 * GDK: no mitigation exists, will deadlock. */
	{"lgi.require(\"Gtk", "lgi.require(\"Gtk\") - GTK loading (partially mitigated)",
	 "somewm prevents the deadlock, but display-dependent GTK features won't work", SEVERITY_WARNING},
	{"lgi.require('Gtk", "lgi.require('Gtk') - GTK loading (partially mitigated)",
	 "somewm prevents the deadlock, but display-dependent GTK features won't work", SEVERITY_WARNING},
	{"lgi.require(\"Gdk", "lgi.require(\"Gdk\") - GDK initialization deadlock",
	 "GDK init connects to display server and will deadlock. Load lazily after startup", SEVERITY_CRITICAL},
	{"lgi.require('Gdk", "lgi.require('Gdk') - GDK initialization deadlock",
	 "GDK init connects to display server and will deadlock. Load lazily after startup", SEVERITY_CRITICAL},

	/* === WARNING: Needs Wayland alternative === */

	/* Screenshot tools (start of string or mid-command) */
	{"\"maim", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'maim", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{" maim ", "maim screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"scrot", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'scrot", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{" scrot ", "scrot screenshot tool",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"import ", "ImageMagick import (screenshot)",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"'import ", "ImageMagick import (screenshot)",
	 "Use awful.screenshot or grim instead", SEVERITY_WARNING},
	{"\"flameshot", "flameshot screenshot tool",
	 "Use awful.screenshot, grim, or flameshot with XDG portal", SEVERITY_WARNING},
	{"'flameshot", "flameshot screenshot tool",
	 "Use awful.screenshot, grim, or flameshot with XDG portal", SEVERITY_WARNING},

	/* Clipboard tools (start of string or piped) */
	{"\"xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"'xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"| xclip", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{" xclip ", "xclip clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"\"xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"'xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},
	{"| xsel", "xsel clipboard tool",
	 "Use wl-copy/wl-paste instead", SEVERITY_WARNING},

	/* Display/input tools used async */
	{"\"xset", "xset display settings",
	 "Most settings are handled by compositor or wlr-randr", SEVERITY_WARNING},
	{"'xset", "xset display settings",
	 "Most settings are handled by compositor or wlr-randr", SEVERITY_WARNING},
	{"\"xinput", "xinput device settings",
	 "Use compositor input settings or libinput config", SEVERITY_WARNING},
	{"'xinput", "xinput device settings",
	 "Use compositor input settings or libinput config", SEVERITY_WARNING},
	{"\"xmodmap", "xmodmap keyboard settings",
	 "Use xkb_options in compositor config", SEVERITY_WARNING},
	{"'xmodmap", "xmodmap keyboard settings",
	 "Use xkb_options in compositor config", SEVERITY_WARNING},
	{"\"setxkbmap", "setxkbmap keyboard layout",
	 "Use awful.keyboard.set_layouts() or compositor config", SEVERITY_WARNING},
	{"'setxkbmap", "setxkbmap keyboard layout",
	 "Use awful.keyboard.set_layouts() or compositor config", SEVERITY_WARNING},

	/* Spawn tools that won't work */
	{"\"xdg-screensaver", "xdg-screensaver",
	 "Use swayidle or compositor idle settings", SEVERITY_WARNING},
	{"'xdg-screensaver", "xdg-screensaver",
	 "Use swayidle or compositor idle settings", SEVERITY_WARNING},

	/* === INFO: May not work, usually harmless === */

	/* Compositor references (no-op on Wayland - built-in) */
	{"\"picom", "picom compositor",
	 "Compositing is built into Wayland, remove picom references", SEVERITY_INFO},
	{"'picom", "picom compositor",
	 "Compositing is built into Wayland, remove picom references", SEVERITY_INFO},
	{"\"compton", "compton compositor",
	 "Compositing is built into Wayland, remove compton references", SEVERITY_INFO},
	{"'compton", "compton compositor",
	 "Compositing is built into Wayland, remove compton references", SEVERITY_INFO},

	/* Tray tools (layer-shell based trays work differently) */
	{"\"stalonetray", "stalonetray system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"'stalonetray", "stalonetray system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"\"trayer", "trayer system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},
	{"'trayer", "trayer system tray",
	 "Wayland has no XEmbed; use waybar or compositor tray", SEVERITY_INFO},

	/* Theming tools that read X resources */
	{"\"lxappearance", "lxappearance GTK theme tool",
	 "GTK themes work, but use gsettings or gtk config files", SEVERITY_INFO},
	{"'lxappearance", "lxappearance GTK theme tool",
	 "GTK themes work, but use gsettings or gtk config files", SEVERITY_INFO},
	{"\"qt5ct", "qt5ct Qt theme tool",
	 "Qt5/6 themes work, but configure via qt5ct/qt6ct config", SEVERITY_INFO},
	{"'qt5ct", "qt5ct Qt theme tool",
	 "Qt5/6 themes work, but configure via qt5ct/qt6ct config", SEVERITY_INFO},

	/* X11-only utilities that silently fail */
	{"\"xhost", "xhost X11 access control",
	 "Wayland has different security model, remove xhost", SEVERITY_INFO},
	{"'xhost", "xhost X11 access control",
	 "Wayland has different security model, remove xhost", SEVERITY_INFO},
	{"\"xauth", "xauth X11 authentication",
	 "Wayland uses different auth, remove xauth", SEVERITY_INFO},
	{"'xauth", "xauth X11 authentication",
	 "Wayland uses different auth, remove xauth", SEVERITY_INFO},

	{NULL, NULL, NULL, 0}
};

/** Deprecated API patterns - APIs removed in somewm 2.0 Phase 0.
 * Deleted modules cause CRITICAL (require fails, config won't load).
 * Removed functions cause WARNING (runtime error when called).
 */
static const check_pattern_t deprecated_patterns[] = {
	/* === CRITICAL: Deleted modules (require will fail) === */

	{"require(\"awful.wibox\"", "awful.wibox removed in 2.0",
	 "Use awful.wibar instead", SEVERITY_CRITICAL},
	{"require('awful.wibox'", "awful.wibox removed in 2.0",
	 "Use awful.wibar instead", SEVERITY_CRITICAL},

	{"require(\"awful.rules\"", "awful.rules removed in 2.0",
	 "Use ruled.client instead", SEVERITY_CRITICAL},
	{"require('awful.rules'", "awful.rules removed in 2.0",
	 "Use ruled.client instead", SEVERITY_CRITICAL},

	{"require(\"awful.ewmh\"", "awful.ewmh removed in 2.0",
	 "Use awful.permissions instead", SEVERITY_CRITICAL},
	{"require('awful.ewmh'", "awful.ewmh removed in 2.0",
	 "Use awful.permissions instead", SEVERITY_CRITICAL},

	{"require(\"awful.util\"", "awful.util removed in 2.0",
	 "Functions moved to gears.* modules (gears.string, gears.table, gears.filesystem, etc.)", SEVERITY_CRITICAL},
	{"require('awful.util'", "awful.util removed in 2.0",
	 "Functions moved to gears.* modules (gears.string, gears.table, gears.filesystem, etc.)", SEVERITY_CRITICAL},

	{"require(\"awful.widget.graph\"", "awful.widget.graph redirect removed in 2.0",
	 "Use wibox.widget.graph directly", SEVERITY_CRITICAL},
	{"require('awful.widget.graph'", "awful.widget.graph redirect removed in 2.0",
	 "Use wibox.widget.graph directly", SEVERITY_CRITICAL},

	{"require(\"awful.widget.progressbar\"", "awful.widget.progressbar redirect removed in 2.0",
	 "Use wibox.widget.progressbar directly", SEVERITY_CRITICAL},
	{"require('awful.widget.progressbar'", "awful.widget.progressbar redirect removed in 2.0",
	 "Use wibox.widget.progressbar directly", SEVERITY_CRITICAL},

	{"require(\"awful.widget.textclock\"", "awful.widget.textclock redirect removed in 2.0",
	 "Use wibox.widget.textclock directly", SEVERITY_CRITICAL},
	{"require('awful.widget.textclock'", "awful.widget.textclock redirect removed in 2.0",
	 "Use wibox.widget.textclock directly", SEVERITY_CRITICAL},

	{"require(\"wibox.widget.background\"", "wibox.widget.background redirect removed in 2.0",
	 "Use wibox.container.background instead", SEVERITY_CRITICAL},
	{"require('wibox.widget.background'", "wibox.widget.background redirect removed in 2.0",
	 "Use wibox.container.background instead", SEVERITY_CRITICAL},

	{"require(\"wibox.layout.margin\"", "wibox.layout.margin redirect removed in 2.0",
	 "Use wibox.container.margin instead", SEVERITY_CRITICAL},
	{"require('wibox.layout.margin'", "wibox.layout.margin redirect removed in 2.0",
	 "Use wibox.container.margin instead", SEVERITY_CRITICAL},

	{"require(\"wibox.layout.constraint\"", "wibox.layout.constraint redirect removed in 2.0",
	 "Use wibox.container.constraint instead", SEVERITY_CRITICAL},
	{"require('wibox.layout.constraint'", "wibox.layout.constraint redirect removed in 2.0",
	 "Use wibox.container.constraint instead", SEVERITY_CRITICAL},

	{"require(\"wibox.layout.scroll\"", "wibox.layout.scroll redirect removed in 2.0",
	 "Use wibox.container.scroll instead", SEVERITY_CRITICAL},
	{"require('wibox.layout.scroll'", "wibox.layout.scroll redirect removed in 2.0",
	 "Use wibox.container.scroll instead", SEVERITY_CRITICAL},

	{"require(\"wibox.layout.mirror\"", "wibox.layout.mirror redirect removed in 2.0",
	 "Use wibox.container.mirror instead", SEVERITY_CRITICAL},
	{"require('wibox.layout.mirror'", "wibox.layout.mirror redirect removed in 2.0",
	 "Use wibox.container.mirror instead", SEVERITY_CRITICAL},

	{"require(\"wibox.layout.rotate\"", "wibox.layout.rotate redirect removed in 2.0",
	 "Use wibox.container.rotate instead", SEVERITY_CRITICAL},
	{"require('wibox.layout.rotate'", "wibox.layout.rotate redirect removed in 2.0",
	 "Use wibox.container.rotate instead", SEVERITY_CRITICAL},

	/* === WARNING: Removed naughty functions === */

	{"naughty.notify(", "naughty.notify() removed in 2.0",
	 "Use naughty.notification{} constructor instead", SEVERITY_WARNING},
	{"naughty.notify {", "naughty.notify() removed in 2.0",
	 "Use naughty.notification{} constructor instead", SEVERITY_WARNING},

	{"naughty.is_suspended(", "naughty.is_suspended() removed in 2.0",
	 "Read naughty.suspended property instead", SEVERITY_WARNING},

	{"naughty.suspend(", "naughty.suspend() removed in 2.0",
	 "Set naughty.suspended = true instead", SEVERITY_WARNING},

	{"naughty.resume(", "naughty.resume() removed in 2.0",
	 "Set naughty.suspended = false instead", SEVERITY_WARNING},

	{"naughty.toggle(", "naughty.toggle() removed in 2.0",
	 "Set naughty.suspended = not naughty.suspended instead", SEVERITY_WARNING},

	{"naughty.destroy(", "naughty.destroy() removed in 2.0",
	 "Use notification:destroy() method instead", SEVERITY_WARNING},

	{"naughty.getById(", "naughty.getById() removed in 2.0",
	 "Use naughty.get_by_id() instead", SEVERITY_WARNING},

	{"naughty.reset_timeout(", "naughty.reset_timeout() removed in 2.0",
	 "Use notification:reset_timeout(new_timeout) method instead", SEVERITY_WARNING},

	{"naughty.replace_text(", "naughty.replace_text() removed in 2.0",
	 "Set notification.title and notification.message directly", SEVERITY_WARNING},

	/* === WARNING: Removed awful.tag functions === */

	{"awful.tag.viewonly(", "awful.tag.viewonly() removed in 2.0",
	 "Use tag:view_only() method instead", SEVERITY_WARNING},

	{"awful.tag.setmwfact(", "awful.tag.setmwfact() removed in 2.0",
	 "Set tag.master_width_factor property instead", SEVERITY_WARNING},
	{"awful.tag.getmwfact(", "awful.tag.getmwfact() removed in 2.0",
	 "Read tag.master_width_factor property instead", SEVERITY_WARNING},

	{"awful.tag.setlayout(", "awful.tag.setlayout() removed in 2.0",
	 "Set tag.layout property instead", SEVERITY_WARNING},

	{"awful.tag.setnmaster(", "awful.tag.setnmaster() removed in 2.0",
	 "Set tag.master_count property instead", SEVERITY_WARNING},
	{"awful.tag.getnmaster(", "awful.tag.getnmaster() removed in 2.0",
	 "Read tag.master_count property instead", SEVERITY_WARNING},

	{"awful.tag.setncol(", "awful.tag.setncol() removed in 2.0",
	 "Set tag.column_count property instead", SEVERITY_WARNING},
	{"awful.tag.getncol(", "awful.tag.getncol() removed in 2.0",
	 "Read tag.column_count property instead", SEVERITY_WARNING},

	{"awful.tag.setgap(", "awful.tag.setgap() removed in 2.0",
	 "Set tag.gap property instead", SEVERITY_WARNING},
	{"awful.tag.getgap(", "awful.tag.getgap() removed in 2.0",
	 "Read tag.gap property instead", SEVERITY_WARNING},

	{"awful.tag.selectedlist(", "awful.tag.selectedlist() removed in 2.0",
	 "Use screen.selected_tags instead", SEVERITY_WARNING},
	{"awful.tag.selected(", "awful.tag.selected() removed in 2.0",
	 "Use screen.selected_tag instead", SEVERITY_WARNING},

	{"awful.tag.gettags(", "awful.tag.gettags() removed in 2.0",
	 "Use screen.tags instead", SEVERITY_WARNING},
	{"awful.tag.getidx(", "awful.tag.getidx() removed in 2.0",
	 "Read tag.index property instead", SEVERITY_WARNING},

	{"awful.tag.move(", "awful.tag.move() removed in 2.0",
	 "Set tag.index property instead", SEVERITY_WARNING},
	{"awful.tag.swap(", "awful.tag.swap() removed in 2.0",
	 "Use tag:swap() method instead", SEVERITY_WARNING},
	{"awful.tag.delete(", "awful.tag.delete() removed in 2.0",
	 "Use tag:delete() method instead", SEVERITY_WARNING},

	{"awful.tag.setscreen(", "awful.tag.setscreen() removed in 2.0",
	 "Set tag.screen property instead", SEVERITY_WARNING},
	{"awful.tag.getscreen(", "awful.tag.getscreen() removed in 2.0",
	 "Read tag.screen property instead", SEVERITY_WARNING},

	{"awful.tag.setvolatile(", "awful.tag.setvolatile() removed in 2.0",
	 "Set tag.volatile property instead", SEVERITY_WARNING},
	{"awful.tag.getvolatile(", "awful.tag.getvolatile() removed in 2.0",
	 "Read tag.volatile property instead", SEVERITY_WARNING},

	{"awful.tag.setmfpol(", "awful.tag.setmfpol() removed in 2.0",
	 "Set tag.master_fill_policy property instead", SEVERITY_WARNING},
	{"awful.tag.getmfpol(", "awful.tag.getmfpol() removed in 2.0",
	 "Read tag.master_fill_policy property instead", SEVERITY_WARNING},

	{"awful.tag.seticon(", "awful.tag.seticon() removed in 2.0",
	 "Set tag.icon property instead", SEVERITY_WARNING},
	{"awful.tag.geticon(", "awful.tag.geticon() removed in 2.0",
	 "Read tag.icon property instead", SEVERITY_WARNING},

	{"awful.tag.withcurrent(", "awful.tag.withcurrent() removed in 2.0",
	 "Use awful.tag.attached_connect_signal() instead", SEVERITY_WARNING},

	/* === WARNING: Removed awful.client functions === */

	{"awful.client.getmaster(", "awful.client.getmaster() removed in 2.0",
	 "Removed - use layout-specific logic or client.focus", SEVERITY_WARNING},
	{"awful.client.setmaster(", "awful.client.setmaster() removed in 2.0",
	 "Removed - manage master via layout directly", SEVERITY_WARNING},
	{"awful.client.setslave(", "awful.client.setslave() removed in 2.0",
	 "Removed - manage client order via layout directly", SEVERITY_WARNING},
	{"awful.client.getmarked(", "awful.client.getmarked() removed in 2.0",
	 "Removed - track marked clients in your own config if needed", SEVERITY_WARNING},
	{"awful.client.floating.toggle(", "awful.client.floating.toggle() removed in 2.0",
	 "Use c.floating = not c.floating instead", SEVERITY_WARNING},

	/* === WARNING: Removed awful.util references (accessed via module, not require) === */

	{"awful.util.spawn(", "awful.util.spawn() removed in 2.0",
	 "Use awful.spawn() instead", SEVERITY_WARNING},
	{"awful.util.spawn_with_shell(", "awful.util.spawn_with_shell() removed in 2.0",
	 "Use awful.spawn.with_shell() instead", SEVERITY_WARNING},
	{"awful.util.pread(", "awful.util.pread() removed in 2.0",
	 "Use awful.spawn.easy_async() instead", SEVERITY_WARNING},
	{"awful.util.eval(", "awful.util.eval() removed in 2.0",
	 "Removed - use loadstring() directly if needed", SEVERITY_WARNING},
	{"awful.util.restart(", "awful.util.restart() removed in 2.0",
	 "Use awesome.restart() instead", SEVERITY_WARNING},
	{"awful.util.table", "awful.util.table removed in 2.0",
	 "Use gears.table instead", SEVERITY_WARNING},
	{"awful.util.shell", "awful.util.shell removed in 2.0",
	 "Removed - awful.spawn handles shell detection", SEVERITY_WARNING},

	/* === WARNING: Other removed functions === */

	{"awful.key.execute(", "awful.key.execute() removed in 2.0",
	 "Removed", SEVERITY_WARNING},

	{"beautiful.get(", "beautiful.get() removed in 2.0",
	 "Access theme values directly: beautiful.property_name", SEVERITY_WARNING},

	{"menubar.get(", "menubar.get() removed in 2.0",
	 "Removed", SEVERITY_WARNING},

	{"gears.surface.widget_to_svg(", "gears.surface.widget_to_svg() removed in 2.0",
	 "Removed", SEVERITY_WARNING},
	{"gears.surface.widget_to_surface(", "gears.surface.widget_to_surface() removed in 2.0",
	 "Removed", SEVERITY_WARNING},

	{NULL, NULL, NULL, 0}
};

/* All pattern tables to scan */
static const check_pattern_t *all_pattern_tables[] = {
	x11_patterns, deprecated_patterns, NULL
};

/** Check if a line contains "somewm:ignore" suppression marker.
 * Allows users to suppress pattern detection on specific lines, e.g.:
 *   local cmd = "flameshot gui" -- somewm:ignore guarded by runtime check
 */
static bool
line_has_suppression(const char *line_start, int line_len)
{
	if (line_len < 13)  /* strlen("somewm:ignore") */
		return false;
	int len = line_len < 200 ? line_len : 200;
	char buf[201];
	memcpy(buf, line_start, len);
	buf[len] = '\0';
	return strstr(buf, "somewm:ignore") != NULL;
}

/* ============================================================================
 * Shared: File tracking (used by both prescan and check mode)
 * ============================================================================ */

/* Maximum recursion depth for require scanning */
#define PRESCAN_MAX_DEPTH 8
/* Maximum number of files to scan */
#define PRESCAN_MAX_FILES 100

/* Track already-scanned files to avoid duplicates */
static const char *prescan_visited[PRESCAN_MAX_FILES];
static int prescan_visited_count = 0;

/** Check if a file was already scanned */
static bool
prescan_already_visited(const char *path)
{
	int i;
	for (i = 0; i < prescan_visited_count; i++) {
		if (strcmp(prescan_visited[i], path) == 0)
			return true;
	}
	return false;
}

/** Mark a file as visited (strdup'd - caller must free prescan_visited array) */
static void
prescan_mark_visited(const char *path)
{
	if (prescan_visited_count < PRESCAN_MAX_FILES)
		prescan_visited[prescan_visited_count++] = strdup(path);
}

/** Free all visited path strings */
static void
prescan_cleanup_visited(void)
{
	int i;
	for (i = 0; i < prescan_visited_count; i++)
		free((void *)prescan_visited[i]);
	prescan_visited_count = 0;
}

/* ============================================================================
 * Prescan: Runtime pre-scan before config execution (blocks dangerous configs)
 * ============================================================================ */

/** Internal recursive pre-scan function */
static bool
prescan_file(const char *config_path, const char *config_dir, int depth,
             prescan_result_t *result);

/** Extract and scan all require()d files from content
 * \param content File content to scan
 * \param config_dir Directory for resolving relative requires
 * \param depth Current recursion depth
 * \param result Output struct for first fatal pattern
 * \return true if all required files are safe, false if dangerous patterns found
 */
static bool
prescan_requires(const char *content, const char *config_dir, int depth,
                 prescan_result_t *result)
{
	const char *pos = content;
	char module_name[256];
	char resolved_path[PATH_MAX];
	bool all_safe = true;

	if (depth >= PRESCAN_MAX_DEPTH || !config_dir)
		return true;

	/* Scan for require("module") and require('module') patterns */
	while ((pos = strstr(pos, "require")) != NULL) {
		const char *start;
		const char *end;
		char quote;
		size_t len;

		pos += 7;  /* Skip "require" */

		/* Skip whitespace and optional ( */
		while (*pos == ' ' || *pos == '\t' || *pos == '(')
			pos++;

		/* Check for string delimiter */
		if (*pos != '"' && *pos != '\'')
			continue;

		quote = *pos++;
		start = pos;

		/* Find end of string */
		end = strchr(pos, quote);
		if (!end || (end - start) >= (int)sizeof(module_name) - 1)
			continue;

		len = end - start;
		memcpy(module_name, start, len);
		module_name[len] = '\0';
		pos = end + 1;

		/* Skip standard library modules (no dots = likely stdlib) */
		/* We only care about local modules like "fishlive.helpers" */
		if (strchr(module_name, '.') == NULL &&
		    strcmp(module_name, "fishlive") != 0 &&
		    strcmp(module_name, "lain") != 0 &&
		    strcmp(module_name, "freedesktop") != 0)
			continue;

		/* Convert module.name to module/name */
		{
			char *p;
			for (p = module_name; *p; p++) {
				if (*p == '.') *p = '/';
			}
		}

		/* Try module_name.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s.lua", config_dir, module_name);

		if (access(resolved_path, R_OK) == 0) {
			if (!prescan_file(resolved_path, config_dir, depth + 1, result))
				all_safe = false;
			continue;
		}

		/* Try module_name/init.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s/init.lua", config_dir, module_name);

		if (access(resolved_path, R_OK) == 0) {
			if (!prescan_file(resolved_path, config_dir, depth + 1, result))
				all_safe = false;
		}
	}

	return all_safe;
}

/** Internal pre-scan implementation with recursion
 * \param config_path Path to the config file
 * \param config_dir Directory containing the config (for require resolution)
 * \param depth Current recursion depth
 * \param result Output struct for first fatal pattern
 * \return true if config is safe to load, false if dangerous patterns found
 */
static bool
prescan_file(const char *config_path, const char *config_dir, int depth,
             prescan_result_t *result)
{
	FILE *fp;
	char *content = NULL;
	long file_size;
	const check_pattern_t *pattern;
	bool found_fatal = false;
	int line_num;
	char *line_start;
	char *match_pos;
	char *newline;

	/* Check recursion depth */
	if (depth >= PRESCAN_MAX_DEPTH)
		return true;

	/* Skip already-visited files */
	if (prescan_already_visited(config_path))
		return true;
	prescan_mark_visited(config_path);

	fp = fopen(config_path, "r");
	if (!fp) {
		/* File doesn't exist - not a pre-scan failure, let normal loading handle it */
		return true;
	}

	/* Get file size */
	fseek(fp, 0, SEEK_END);
	file_size = ftell(fp);
	fseek(fp, 0, SEEK_SET);

	if (file_size <= 0 || file_size > 10 * 1024 * 1024) {
		/* Empty or too large (>10MB) - skip pre-scan */
		fclose(fp);
		return true;
	}

	content = malloc(file_size + 1);
	if (!content) {
		fclose(fp);
		return true;
	}

	if (fread(content, 1, file_size, fp) != (size_t)file_size) {
		free(content);
		fclose(fp);
		return true;
	}
	content[file_size] = '\0';
	fclose(fp);

	/* Scan for each dangerous pattern (prescan only checks x11_patterns) */
	for (pattern = x11_patterns; pattern->pattern != NULL; pattern++) {
		match_pos = strstr(content, pattern->pattern);
		if (match_pos) {
			int line_len;

			/* Found a match - calculate line number */
			line_num = 1;
			for (line_start = content; line_start < match_pos; line_start++) {
				if (*line_start == '\n')
					line_num++;
			}

			/* Find the actual line for context */
			line_start = match_pos;
			while (line_start > content && *(line_start - 1) != '\n')
				line_start--;
			newline = strchr(line_start, '\n');
			line_len = newline ? (int)(newline - line_start) : (int)strlen(line_start);
			if (line_len > 200) line_len = 200;  /* Truncate long lines */

			/* Skip if line is a Lua comment (starts with -- after whitespace) */
			{
				const char *p = line_start;
				while (p < match_pos && (*p == ' ' || *p == '\t'))
					p++;
				if (p[0] == '-' && p[1] == '-')
					continue;  /* Skip commented lines */
			}

			/* Skip lines with somewm:ignore suppression */
			if (line_has_suppression(line_start, line_len))
				continue;

			fprintf(stderr, "\n");
			fprintf(stderr, "somewm: *** X11 PATTERN DETECTED ***\n");
			fprintf(stderr, "somewm: File: %s:%d\n", config_path, line_num);
			fprintf(stderr, "somewm: Pattern: %s\n", pattern->description);
			fprintf(stderr, "somewm: \n");
			fprintf(stderr, "somewm: This may hang on Wayland (no X11 display).\n");
			fprintf(stderr, "somewm: Suggestion: %s\n", pattern->suggestion);
			fprintf(stderr, "somewm: \n");

			/* Show the offending line */
			if (line_len > 0) {
				fprintf(stderr, "somewm: Line %d: %.*s\n", line_num,
				        line_len, line_start);
			}

			/* Store first detected pattern for Lua notification */
			if (!found_fatal && result) {
				result->config_path = strdup(config_path);
				result->line_number = line_num;
				result->pattern_desc = strdup(pattern->description);
				result->suggestion = strdup(pattern->suggestion);
				result->line_content = strndup(line_start, line_len);
			}

			found_fatal = true;
			/* Continue scanning to report all issues */
		}
	}

	/* Recursively scan required files */
	if (!found_fatal && config_dir) {
		if (!prescan_requires(content, config_dir, depth, result))
			found_fatal = true;
	}

	free(content);
	return !found_fatal;
}

bool
check_config_prescan(const char *config_path, const char *config_dir,
                     prescan_result_t *result)
{
	bool safe;
	char dir_buf[PATH_MAX];
	const char *dir = config_dir;

	/* Reset visited tracking */
	prescan_cleanup_visited();

	if (result)
		result->found_fatal = false;

	/* If no config_dir provided, derive from config_path */
	if (!dir && config_path) {
		char *last_slash;
		strncpy(dir_buf, config_path, sizeof(dir_buf) - 1);
		dir_buf[sizeof(dir_buf) - 1] = '\0';
		last_slash = strrchr(dir_buf, '/');
		if (last_slash) {
			*last_slash = '\0';
			dir = dir_buf;
		}
	}

	safe = prescan_file(config_path, dir, 0, result);

	if (!safe) {
		if (result)
			result->found_fatal = true;
		fprintf(stderr, "\n");
		fprintf(stderr, "somewm: Skipping this config to prevent hang.\n");
		fprintf(stderr, "somewm: Falling back to default somewmrc.lua...\n");
		fprintf(stderr, "\n");
	}

	prescan_cleanup_visited();
	return safe;
}

/* ============================================================================
 * Check Mode: `somewm --check <config>` for config compatibility analysis
 * ============================================================================
 * Scans config without starting compositor and outputs a report.
 */

/* Maximum issues to track in check mode */
#define CHECK_MAX_ISSUES 200

/* Stored issue for check mode report */
typedef struct {
	char *file_path;
	int line_number;
	char *line_content;
	const char *pattern_desc;   /* Points into pattern tables - don't free */
	const char *suggestion;     /* Points into pattern tables - don't free */
	x11_severity_t severity;
	bool is_syntax_error;       /* If true, pattern_desc is dynamically allocated */
} check_issue_t;

/* Global state for check mode */
static check_issue_t check_issues[CHECK_MAX_ISSUES];
static int check_issue_count = 0;
static int check_counts[3] = {0, 0, 0};  /* info, warning, critical */

/** Reset check mode state */
static void
check_mode_reset(void)
{
	int i;
	for (i = 0; i < check_issue_count; i++) {
		free(check_issues[i].file_path);
		free(check_issues[i].line_content);
		if (check_issues[i].is_syntax_error)
			free((void *)check_issues[i].pattern_desc);
	}
	check_issue_count = 0;
	check_counts[0] = check_counts[1] = check_counts[2] = 0;
}

/** Store an issue found during check mode scan */
static void
check_mode_add_issue(const char *file_path, int line_num, const char *line_content,
                     const check_pattern_t *pattern)
{
	check_issue_t *issue;

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup(line_content);
	issue->pattern_desc = pattern->description;
	issue->suggestion = pattern->suggestion;
	issue->severity = pattern->severity;
	issue->is_syntax_error = false;

	check_counts[pattern->severity]++;
}

/** Store a syntax error found during check mode */
static void
check_mode_add_syntax_error(const char *file_path, const char *error_msg)
{
	check_issue_t *issue;
	int line_num = 0;
	const char *line_start;
	char *colon;

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	/* Try to extract line number from Lua error message format: "file:line: message" */
	colon = strrchr(file_path, '/');
	line_start = colon ? colon + 1 : file_path;
	colon = strstr(error_msg, line_start);
	if (colon) {
		colon = strchr(colon, ':');
		if (colon)
			line_num = atoi(colon + 1);
	}

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(error_msg);
	issue->suggestion = "Fix the syntax error before running";
	issue->severity = SEVERITY_CRITICAL;
	issue->is_syntax_error = true;

	check_counts[SEVERITY_CRITICAL]++;
}

/** Store a missing module error found during check mode */
static void
check_mode_add_missing_module(const char *source_file, const char *module_name,
                              const char *tried_path1, const char *tried_path2)
{
	check_issue_t *issue;
	char desc[512];

	(void)tried_path1;
	(void)tried_path2;

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	snprintf(desc, sizeof(desc), "require('%s') - module not found", module_name);

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(source_file);
	issue->line_number = 0;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(desc);
	issue->suggestion = "Check module path or install missing dependency";
	issue->severity = SEVERITY_WARNING;
	issue->is_syntax_error = true;  /* pattern_desc is dynamically allocated */

	check_counts[SEVERITY_WARNING]++;
}

/* Track if luacheck is available (checked once) */
static int luacheck_available = -1;  /* -1 = unchecked, 0 = no, 1 = yes */

/** Check if luacheck is installed */
static bool
check_luacheck_available(void)
{
	if (luacheck_available < 0) {
		/* Check if luacheck exists in PATH */
		int ret = system("command -v luacheck >/dev/null 2>&1");
		luacheck_available = (ret == 0) ? 1 : 0;
	}
	return luacheck_available == 1;
}

/** Store a luacheck issue */
static void
check_mode_add_luacheck_issue(const char *file_path, int line_num,
                              const char *code, const char *message,
                              x11_severity_t severity)
{
	check_issue_t *issue;
	char desc[512];

	if (check_issue_count >= CHECK_MAX_ISSUES)
		return;

	snprintf(desc, sizeof(desc), "[%s] %s", code, message);

	issue = &check_issues[check_issue_count++];
	issue->file_path = strdup(file_path);
	issue->line_number = line_num;
	issue->line_content = strdup("");
	issue->pattern_desc = strdup(desc);
	issue->suggestion = "See luacheck documentation for details";
	issue->severity = severity;
	issue->is_syntax_error = true;  /* pattern_desc is dynamically allocated */

	check_counts[severity]++;
}

/** Run luacheck on a file and collect issues
 * \param file_path Path to the Lua file to check
 * \return Number of issues found, or -1 if luacheck not available
 */
static int
check_mode_run_luacheck(const char *file_path)
{
	char cmd[PATH_MAX + 256];
	FILE *pipe;
	char line[1024];
	int issues_found = 0;

	if (!check_luacheck_available())
		return -1;

	/* Run luacheck with parseable output format
	 * File path must come first, then options
	 * --std luajit: use LuaJIT standard
	 * --no-color: plain text output
	 * --codes: include warning codes
	 * --quiet: don't print summary line
	 * --allow-defined-top: allow globals defined at top level (normal for rc.lua)
	 * --globals: AwesomeWM global objects
	 */
	snprintf(cmd, sizeof(cmd),
	         "luacheck '%s' --std luajit --no-color --codes --quiet "
	         "--allow-defined-top "
	         "--globals awesome client screen tag mouse root "
	         "beautiful awful gears wibox naughty menubar ruled "
	         "2>&1", file_path);

	pipe = popen(cmd, "r");
	if (!pipe)
		return -1;

	/* Parse luacheck output: "filename:line:col: (Wcode) message" */
	while (fgets(line, sizeof(line), pipe)) {
		char *colon1, *colon2, *colon3, *paren_open, *paren_close;
		char *nl;
		int line_num = 0;
		char code[16] = "";
		char *message;
		x11_severity_t severity = SEVERITY_WARNING;

		/* Skip lines that don't match the pattern */
		colon1 = strchr(line, ':');
		if (!colon1) continue;
		colon2 = strchr(colon1 + 1, ':');
		if (!colon2) continue;
		colon3 = strchr(colon2 + 1, ':');
		if (!colon3) continue;

		/* Extract line number */
		line_num = atoi(colon1 + 1);

		/* Find the code in parentheses */
		paren_open = strchr(colon3, '(');
		paren_close = paren_open ? strchr(paren_open, ')') : NULL;
		if (paren_open && paren_close) {
			size_t code_len = paren_close - paren_open - 1;
			if (code_len < sizeof(code)) {
				memcpy(code, paren_open + 1, code_len);
				code[code_len] = '\0';
			}
			message = paren_close + 2;  /* Skip ") " */
		} else {
			message = colon3 + 2;
		}

		/* Remove trailing newline */
		nl = strchr(message, '\n');
		if (nl) *nl = '\0';

		/* Determine severity based on code
		 * E = error (syntax errors, etc.)
		 * W = warning
		 */
		if (code[0] == 'E')
			severity = SEVERITY_CRITICAL;
		else
			severity = SEVERITY_WARNING;

		check_mode_add_luacheck_issue(file_path, line_num, code, message, severity);
		issues_found++;
	}

	pclose(pipe);
	return issues_found;
}

/** Check Lua syntax of a file using luaL_loadfile
 * Creates a temporary Lua state just for parsing.
 * \param file_path Path to the Lua file to check
 * \return true if syntax is valid, false if error (and adds issue)
 */
static bool
check_mode_syntax_check(const char *file_path)
{
	lua_State *L;
	int status;
	const char *err_msg;

	L = luaL_newstate();
	if (!L)
		return true;  /* Can't check, assume OK */

	status = luaL_loadfile(L, file_path);
	if (status != 0) {
		err_msg = lua_tostring(L, -1);
		if (err_msg)
			check_mode_add_syntax_error(file_path, err_msg);
		lua_close(L);
		return false;
	}

	lua_close(L);
	return true;
}

/* ANSI color codes */
#define COL_RESET   "\033[0m"
#define COL_RED     "\033[1;31m"
#define COL_YELLOW  "\033[1;33m"
#define COL_CYAN    "\033[1;36m"
#define COL_GREEN   "\033[1;32m"
#define COL_GRAY    "\033[0;37m"
#define COL_BOLD    "\033[1m"

/** Print check mode report to stdout with colors */
static void
check_mode_print_report(const char *config_path, bool use_color)
{
	int i;
	int total;
	const char *sev_colors[] = {COL_CYAN, COL_YELLOW, COL_RED};
	const char *sev_names[] = {"INFO", "WARNING", "CRITICAL"};
	const char *sev_symbols[] = {"i", "!", "X"};

	total = check_counts[0] + check_counts[1] + check_counts[2];

	printf("\n");
	if (use_color)
		printf("%ssomewm config compatibility report%s\n", COL_BOLD, COL_RESET);
	else
		printf("somewm config compatibility report\n");
	printf("====================================\n");
	printf("Config: %s\n\n", config_path);

	if (total == 0) {
		if (use_color)
			printf("%s✓ No compatibility issues found!%s\n\n", COL_GREEN, COL_RESET);
		else
			printf("✓ No compatibility issues found!\n\n");
		return;
	}

	/* Print issues grouped by severity (critical first) */
	for (int sev = SEVERITY_CRITICAL; sev >= SEVERITY_INFO; sev--) {
		bool printed_header = false;

		for (i = 0; i < check_issue_count; i++) {
			check_issue_t *issue = &check_issues[i];
			if ((int)issue->severity != sev)
				continue;

			if (!printed_header) {
				if (use_color)
					printf("%s%s %s:%s\n", sev_colors[sev],
					       sev_symbols[sev], sev_names[sev], COL_RESET);
				else
					printf("%s %s:\n", sev_symbols[sev], sev_names[sev]);
				printed_header = true;
			}

			/* File:line - description */
			if (use_color)
				printf("  %s%s:%d%s - %s\n",
				       COL_BOLD, issue->file_path, issue->line_number, COL_RESET,
				       issue->pattern_desc);
			else
				printf("  %s:%d - %s\n",
				       issue->file_path, issue->line_number,
				       issue->pattern_desc);

			/* Suggestion */
			if (use_color)
				printf("    %s→ %s%s\n", COL_GRAY, issue->suggestion, COL_RESET);
			else
				printf("    → %s\n", issue->suggestion);
		}
		if (printed_header)
			printf("\n");
	}

	/* Summary line */
	if (use_color) {
		printf("%sSummary:%s ", COL_BOLD, COL_RESET);
		if (check_counts[2] > 0)
			printf("%s%d critical%s", COL_RED, check_counts[2], COL_RESET);
		if (check_counts[1] > 0)
			printf("%s%s%d warnings%s",
			       check_counts[2] ? ", " : "",
			       COL_YELLOW, check_counts[1], COL_RESET);
		if (check_counts[0] > 0)
			printf("%s%s%d info%s",
			       (check_counts[2] || check_counts[1]) ? ", " : "",
			       COL_CYAN, check_counts[0], COL_RESET);
		printf("\n\n");
	} else {
		printf("Summary: ");
		if (check_counts[2] > 0)
			printf("%d critical", check_counts[2]);
		if (check_counts[1] > 0)
			printf("%s%d warnings",
			       check_counts[2] ? ", " : "", check_counts[1]);
		if (check_counts[0] > 0)
			printf("%s%d info",
			       (check_counts[2] || check_counts[1]) ? ", " : "",
			       check_counts[0]);
		printf("\n\n");
	}
}

/** Scan a file in check mode (all severities, no blocking) */
static void
check_mode_scan_file(const char *config_path, const char *config_dir, int depth);

/** Scan requires in check mode */
static void
check_mode_scan_requires(const char *content, const char *config_dir,
                         const char *source_file, int depth)
{
	const char *pos = content;
	char module_name[256];
	char module_path[256];
	char resolved_path[PATH_MAX];
	char resolved_path2[PATH_MAX];

	if (depth >= PRESCAN_MAX_DEPTH || !config_dir)
		return;

	while ((pos = strstr(pos, "require")) != NULL) {
		const char *start;
		const char *end;
		char quote;
		size_t len;

		/* Skip lgi.require, some_module.require, etc. */
		if (pos > content && *(pos - 1) == '.') {
			pos += 7;
			continue;
		}

		/* Skip if line is a Lua comment (starts with -- after whitespace) */
		{
			const char *line_start = pos;
			while (line_start > content && *(line_start - 1) != '\n')
				line_start--;
			const char *p = line_start;
			while (p < pos && (*p == ' ' || *p == '\t'))
				p++;
			if (p[0] == '-' && p[1] == '-') {
				pos += 7;
				continue;
			}
		}

		pos += 7;

		while (*pos == ' ' || *pos == '\t' || *pos == '(')
			pos++;

		if (*pos != '"' && *pos != '\'')
			continue;

		quote = *pos++;
		start = pos;
		end = strchr(pos, quote);
		if (!end || (end - start) >= (int)sizeof(module_name) - 1)
			continue;

		len = end - start;
		memcpy(module_name, start, len);
		module_name[len] = '\0';
		pos = end + 1;

		/* Skip standard Lua library modules */
		if (strcmp(module_name, "string") == 0 ||
		    strcmp(module_name, "table") == 0 ||
		    strcmp(module_name, "math") == 0 ||
		    strcmp(module_name, "io") == 0 ||
		    strcmp(module_name, "os") == 0 ||
		    strcmp(module_name, "debug") == 0 ||
		    strcmp(module_name, "coroutine") == 0 ||
		    strcmp(module_name, "package") == 0 ||
		    strcmp(module_name, "utf8") == 0 ||
		    strcmp(module_name, "bit") == 0 ||
		    strcmp(module_name, "bit32") == 0 ||
		    strcmp(module_name, "ffi") == 0 ||
		    strcmp(module_name, "jit") == 0)
			continue;

		/* Skip AwesomeWM library modules (they're in system paths) */
		if (strncmp(module_name, "awful", 5) == 0 ||
		    strncmp(module_name, "gears", 5) == 0 ||
		    strncmp(module_name, "wibox", 5) == 0 ||
		    strncmp(module_name, "naughty", 7) == 0 ||
		    strncmp(module_name, "beautiful", 9) == 0 ||
		    strncmp(module_name, "menubar", 7) == 0 ||
		    strcmp(module_name, "ruled") == 0 ||
		    strncmp(module_name, "ruled.", 6) == 0)
			continue;

		/* Skip common third-party modules (installed separately) */
		if (strcmp(module_name, "lgi") == 0 ||
		    strncmp(module_name, "lgi.", 4) == 0 ||
		    strcmp(module_name, "lain") == 0 ||
		    strncmp(module_name, "lain.", 5) == 0 ||
		    strcmp(module_name, "freedesktop") == 0 ||
		    strncmp(module_name, "freedesktop.", 12) == 0 ||
		    strcmp(module_name, "vicious") == 0 ||
		    strncmp(module_name, "vicious.", 8) == 0 ||
		    strcmp(module_name, "revelation") == 0 ||
		    strcmp(module_name, "collision") == 0 ||
		    strcmp(module_name, "tyrannical") == 0 ||
		    strcmp(module_name, "cyclefocus") == 0 ||
		    strcmp(module_name, "radical") == 0 ||
		    strcmp(module_name, "cairo") == 0 ||
		    strcmp(module_name, "posix") == 0 ||
		    strncmp(module_name, "posix.", 6) == 0 ||
		    strcmp(module_name, "cjson") == 0 ||
		    strncmp(module_name, "cjson.", 6) == 0 ||
		    strcmp(module_name, "dkjson") == 0 ||
		    strcmp(module_name, "json") == 0 ||
		    strcmp(module_name, "socket") == 0 ||
		    strncmp(module_name, "socket.", 7) == 0 ||
		    strcmp(module_name, "http") == 0 ||
		    strncmp(module_name, "pl.", 3) == 0 ||
		    strcmp(module_name, "penlight") == 0 ||
		    strcmp(module_name, "inspect") == 0 ||
		    strcmp(module_name, "luassert") == 0 ||
		    strcmp(module_name, "busted") == 0)
			continue;

		/* Save original module name for error reporting */
		snprintf(module_path, sizeof(module_path), "%s", module_name);

		/* Convert module.name to module/name */
		for (char *p = module_name; *p; p++) {
			if (*p == '.') *p = '/';
		}

		/* Try module_name.lua */
		snprintf(resolved_path, sizeof(resolved_path),
		         "%s/%s.lua", config_dir, module_name);
		if (access(resolved_path, R_OK) == 0) {
			check_mode_scan_file(resolved_path, config_dir, depth + 1);
			continue;
		}

		/* Try module_name/init.lua */
		snprintf(resolved_path2, sizeof(resolved_path2),
		         "%s/%s/init.lua", config_dir, module_name);
		if (access(resolved_path2, R_OK) == 0) {
			check_mode_scan_file(resolved_path2, config_dir, depth + 1);
			continue;
		}

		/* Module not found - report it */
		check_mode_add_missing_module(source_file, module_path,
		                              resolved_path, resolved_path2);
	}
}

/** Check mode: scan a file and store all issues found */
static void
check_mode_scan_file(const char *config_path, const char *config_dir, int depth)
{
	FILE *fp;
	char *content = NULL;
	long file_size;
	const check_pattern_t *pattern;

	if (depth >= PRESCAN_MAX_DEPTH)
		return;

	if (prescan_already_visited(config_path))
		return;
	prescan_mark_visited(config_path);

	/* Check Lua syntax first */
	check_mode_syntax_check(config_path);

	fp = fopen(config_path, "r");
	if (!fp)
		return;

	fseek(fp, 0, SEEK_END);
	file_size = ftell(fp);
	fseek(fp, 0, SEEK_SET);

	if (file_size <= 0 || file_size > 10 * 1024 * 1024) {
		fclose(fp);
		return;
	}

	content = malloc(file_size + 1);
	if (!content) {
		fclose(fp);
		return;
	}

	if (fread(content, 1, file_size, fp) != (size_t)file_size) {
		free(content);
		fclose(fp);
		return;
	}
	content[file_size] = '\0';
	fclose(fp);

	/* Scan for all patterns (X11 compat and deprecated APIs) */
	for (int t = 0; all_pattern_tables[t] != NULL; t++) {
		for (pattern = all_pattern_tables[t]; pattern->pattern != NULL; pattern++) {
			char *match_pos = strstr(content, pattern->pattern);
			if (match_pos) {
				int line_num = 1;
				char *line_start;
				char *newline;
				int line_len;
				char line_buf[201];

				/* Calculate line number */
				for (line_start = content; line_start < match_pos; line_start++) {
					if (*line_start == '\n')
						line_num++;
				}

				/* Find the actual line */
				line_start = match_pos;
				while (line_start > content && *(line_start - 1) != '\n')
					line_start--;
				newline = strchr(line_start, '\n');
				line_len = newline ? (int)(newline - line_start) : (int)strlen(line_start);
				if (line_len > 200) line_len = 200;

				/* Skip commented lines */
				{
					const char *p = line_start;
					while (p < match_pos && (*p == ' ' || *p == '\t'))
						p++;
					if (p[0] == '-' && p[1] == '-')
						continue;
				}

				/* Skip lines with somewm:ignore suppression */
				if (line_has_suppression(line_start, line_len))
					continue;

				memcpy(line_buf, line_start, line_len);
				line_buf[line_len] = '\0';

				check_mode_add_issue(config_path, line_num, line_buf, pattern);
			}
		}
	}

	/* Recursively scan required files */
	if (config_dir)
		check_mode_scan_requires(content, config_dir, config_path, depth);

	free(content);
}

int
check_config_run(const char *config_path, bool use_color, int min_severity)
{
	char dir_buf[PATH_MAX];
	const char *dir = NULL;
	char *last_slash;
	int result;

	/* Reset state */
	check_mode_reset();
	prescan_cleanup_visited();

	/* Derive config_dir from config_path */
	strncpy(dir_buf, config_path, sizeof(dir_buf) - 1);
	dir_buf[sizeof(dir_buf) - 1] = '\0';
	last_slash = strrchr(dir_buf, '/');
	if (last_slash) {
		*last_slash = '\0';
		dir = dir_buf;
	}

	/* Scan the config and all its dependencies */
	check_mode_scan_file(config_path, dir, 0);

	/* Run luacheck if available (gracefully skips if not installed) */
	check_mode_run_luacheck(config_path);

	/* Print the report */
	check_mode_print_report(config_path, use_color);

	/* Determine exit code based on min_severity filter.
	 * The report always shows all issues; the filter only affects exit code.
	 * min_severity: 0=info, 1=warning, 2=critical */
	{
		int highest = -1;
		if (check_counts[SEVERITY_CRITICAL] > 0)
			highest = SEVERITY_CRITICAL;
		else if (check_counts[SEVERITY_WARNING] > 0)
			highest = SEVERITY_WARNING;
		else if (check_counts[SEVERITY_INFO] > 0)
			highest = SEVERITY_INFO;

		if (highest >= 0 && highest >= min_severity)
			result = (highest == SEVERITY_CRITICAL) ? 2 : 1;
		else
			result = 0;
	}

	/* Cleanup */
	check_mode_reset();
	prescan_cleanup_visited();

	return result;
}
