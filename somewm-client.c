/**
 * somewm-client - CLI tool for controlling somewm compositor
 *
 * Connects to the somewm IPC socket and sends commands.
 *
 * Usage:
 *   somewm-client tag view 2
 *   somewm-client client list
 *   somewm-client --subscribe client_focus tag_switch
 */

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define BUFFER_SIZE 65536
#define SOCKET_NAME "somewm-socket"

static volatile sig_atomic_t running = 1;

static void
signal_handler(int sig)
{
	(void)sig;
	running = 0;
}

static void
print_usage(const char *progname)
{
	fprintf(stderr, "Usage: %s [OPTIONS] COMMAND [ARGS...]\n\n", progname);
	fprintf(stderr, "OPTIONS:\n");
	fprintf(stderr, "  --json                         Output in JSON format\n");
	fprintf(stderr, "  --subscribe [event_types...]    Subscribe to events (persistent)\n");
	fprintf(stderr, "  --completions <shell>           Output shell completion script\n\n");

	fprintf(stderr, "BASIC COMMANDS:\n");
	fprintf(stderr, "  ping                           Test connection\n");
	fprintf(stderr, "  exec <command...>              Spawn a process\n");
	fprintf(stderr, "  quit                           Exit compositor\n");
	fprintf(stderr, "  commands                       List all registered commands\n\n");

	fprintf(stderr, "TAG COMMANDS:\n");
	fprintf(stderr, "  tag view <N>                   Switch to tag N\n");
	fprintf(stderr, "  tag toggle <N>                 Toggle tag N visibility\n");
	fprintf(stderr, "  tag current                    Get current tag(s)\n");
	fprintf(stderr, "  tag list                       List all tags\n");
	fprintf(stderr, "  tag add <name> [screen]        Create a new tag\n");
	fprintf(stderr, "  tag delete <name|N>            Delete a tag\n");
	fprintf(stderr, "  tag rename <old> <new>         Rename a tag\n");
	fprintf(stderr, "  tag screen <name> [screen]     Get or move tag to screen\n");
	fprintf(stderr, "  tag swap <tag1> <tag2>         Swap tag positions\n");
	fprintf(stderr, "  tag layout <name> [layout]     Get or set tag layout\n");
	fprintf(stderr, "  tag gap <name> [pixels]        Get or set tag gap\n");
	fprintf(stderr, "  tag mwfact <name> [factor]     Get or set master width factor\n\n");

	fprintf(stderr, "KEYBIND COMMANDS:\n");
	fprintf(stderr, "  keybind list [client]          List all keybindings\n");
	fprintf(stderr, "  keybind add <mods> <key> <cmd> Add global keybind\n");
	fprintf(stderr, "  keybind remove <mods> <key>    Remove global keybind\n");
	fprintf(stderr, "  keybind trigger <mods> <key>   Manually trigger keybind\n\n");

	fprintf(stderr, "CLIENT MANAGEMENT:\n");
	fprintf(stderr, "  client list                    List all clients\n");
	fprintf(stderr, "  client kill <ID|focused> [--force]  Kill a client\n");
	fprintf(stderr, "  client close <ID|focused>      Close a client\n");
	fprintf(stderr, "  client focus <ID|next|prev|up|down|left|right>\n");
	fprintf(stderr, "                                 Focus a client\n");
	fprintf(stderr, "  client movetotag <N> [ID]      Move client to tag N\n");
	fprintf(stderr, "  client toggletag <N> [ID]      Toggle tag N on client\n");
	fprintf(stderr, "  client movetoscreen <scr> [ID] Move client to screen\n\n");

	fprintf(stderr, "CLIENT GEOMETRY:\n");
	fprintf(stderr, "  client geometry <ID> [x y w h] Get or set client geometry\n");
	fprintf(stderr, "  client move <ID> <x> <y>       Move client to position\n");
	fprintf(stderr, "  client resize <ID> <w> <h>     Resize client\n");
	fprintf(stderr, "  client moveresize <ID> <dx> <dy> <dw> <dh>\n");
	fprintf(stderr, "                                 Move and resize relatively\n");
	fprintf(stderr, "  client center <ID|focused>     Center client on screen\n");
	fprintf(stderr, "  client placement <func> [ID]   Apply placement function\n\n");

	fprintf(stderr, "CLIENT PROPERTIES:\n");
	fprintf(stderr, "  client floating <ID> [bool]    Get or set floating state\n");
	fprintf(stderr, "  client fullscreen <ID> [bool]  Get or set fullscreen state\n");
	fprintf(stderr, "  client sticky <ID> [bool]      Get or set sticky state\n");
	fprintf(stderr, "  client ontop <ID> [bool]       Get or set ontop state\n");
	fprintf(stderr, "  client minimized <ID> [bool]   Get or set minimized state\n");
	fprintf(stderr, "  client maximized <ID> [bool]   Get or set maximized state\n");
	fprintf(stderr, "  client maximized_horizontal <ID> [bool]\n");
	fprintf(stderr, "  client maximized_vertical <ID> [bool]\n");
	fprintf(stderr, "  client hidden <ID> [bool]      Get or set hidden state\n");
	fprintf(stderr, "  client modal <ID> [bool]       Get or set modal state\n");
	fprintf(stderr, "  client focusable <ID> [bool]   Get or set focusable state\n");
	fprintf(stderr, "  client urgent <ID> [bool]      Get or set urgent state\n");
	fprintf(stderr, "  client above <ID> [bool]       Get or set above state\n");
	fprintf(stderr, "  client below <ID> [bool]       Get or set below state\n");
	fprintf(stderr, "  client skip_taskbar <ID> [bool] Get or set skip_taskbar\n");
	fprintf(stderr, "  client opacity <ID> [0.0-1.0]  Get or set opacity\n\n");

	fprintf(stderr, "CLIENT STACK OPERATIONS:\n");
	fprintf(stderr, "  client raise <ID|focused>      Raise client to top\n");
	fprintf(stderr, "  client lower <ID|focused>      Lower client to bottom\n");
	fprintf(stderr, "  client swap <ID1> <ID2>        Swap two clients\n");
	fprintf(stderr, "  client swapidx <+/-N> [ID]     Swap with Nth client in stack\n");
	fprintf(stderr, "  client zoom <ID|focused>       Swap client with master\n\n");

	fprintf(stderr, "CLIENT QUERIES:\n");
	fprintf(stderr, "  client visible                 List visible clients\n");
	fprintf(stderr, "  client tiled                   List tiled clients\n");
	fprintf(stderr, "  client master                  Get master client\n");
	fprintf(stderr, "  client info <ID|focused>       Get comprehensive client info\n\n");

	fprintf(stderr, "SCREEN COMMANDS:\n");
	fprintf(stderr, "  screen list                    List all screens/monitors\n");
	fprintf(stderr, "  screen focused                 Get focused screen info\n");
	fprintf(stderr, "  screen count                   Get number of screens\n");
	fprintf(stderr, "  screen clients <ID>            List clients on a screen\n");
	fprintf(stderr, "  screen scale [screen] [value]  Get or set screen scale\n");
	fprintf(stderr, "  screen focus <id|next|prev>    Focus a screen\n\n");

	fprintf(stderr, "MOUSE COMMANDS:\n");
	fprintf(stderr, "  mouse coords [x y]             Get or set cursor position\n");
	fprintf(stderr, "  mouse screen                   Get screen under cursor\n\n");

	fprintf(stderr, "SCREENSHOT COMMANDS:\n");
	fprintf(stderr, "  screenshot save <path> [--transparent]\n");
	fprintf(stderr, "                                 Save full desktop screenshot\n");
	fprintf(stderr, "  screenshot client <path> [ID]  Save client window screenshot\n");
	fprintf(stderr, "  screenshot screen <path> [ID]  Save single screen screenshot\n\n");

	fprintf(stderr, "INPUT SETTINGS:\n");
	fprintf(stderr, "  input                          Show all input settings\n");
	fprintf(stderr, "  input <setting> [value]        Get or set an input setting\n");
	fprintf(stderr, "    Pointer: tap_to_click, natural_scrolling, accel_speed, ...\n");
	fprintf(stderr, "    Keyboard: xkb_layout, xkb_options, keyboard_repeat_rate, ...\n\n");

	fprintf(stderr, "SESSION:\n");
	fprintf(stderr, "  version                        Show compositor version\n");
	fprintf(stderr, "  lock                           Lock the session\n");
	fprintf(stderr, "  reload                         Reload configuration\n");
	fprintf(stderr, "  restart                        Full compositor restart\n\n");

	fprintf(stderr, "DISPLAY MANAGEMENT:\n");
	fprintf(stderr, "  output list                    List all outputs\n");
	fprintf(stderr, "  dpms <on|off|status>           Control display power\n");
	fprintf(stderr, "  idle <timeout|status|clear>    Manage idle timeouts\n\n");

	fprintf(stderr, "RULES:\n");
	fprintf(stderr, "  rule list                      List all client rules\n");
	fprintf(stderr, "  rule add <json>                Add rule from JSON\n");
	fprintf(stderr, "  rule remove <id>               Remove rule by ID\n");
	fprintf(stderr, "  rule test <client_id>          Show which rules match client\n\n");

	fprintf(stderr, "WIBAR:\n");
	fprintf(stderr, "  wibar list                     List all wibars\n");
	fprintf(stderr, "  wibar show <screen|all>        Show wibar(s)\n");
	fprintf(stderr, "  wibar hide <screen|all>        Hide wibar(s)\n");
	fprintf(stderr, "  wibar toggle <screen|all>      Toggle wibar(s)\n\n");

	fprintf(stderr, "TITLEBAR:\n");
	fprintf(stderr, "  titlebar show [ID] [position]  Show titlebar\n");
	fprintf(stderr, "  titlebar hide [ID] [position]  Hide titlebar\n");
	fprintf(stderr, "  titlebar toggle [ID] [position] Toggle titlebar\n\n");

	fprintf(stderr, "THEME:\n");
	fprintf(stderr, "  theme get [key]                Get theme value(s)\n");
	fprintf(stderr, "  theme set <key> <value>        Set theme value\n\n");

	fprintf(stderr, "WALLPAPER:\n");
	fprintf(stderr, "  wallpaper set <path> [screen]  Set wallpaper from image\n");
	fprintf(stderr, "  wallpaper color <hex> [screen]  Set solid color wallpaper\n\n");

	fprintf(stderr, "NOTIFICATIONS:\n");
	fprintf(stderr, "  notify <msg> [--title T] [--timeout N] [--urgency U]\n");
	fprintf(stderr, "                                 Send a notification\n\n");

	fprintf(stderr, "ADVANCED:\n");
	fprintf(stderr, "  eval <lua_code>                Execute arbitrary Lua code\n");
	fprintf(stderr, "  hotkeys                        Show hotkeys popup\n");
	fprintf(stderr, "  menubar                        Show menubar launcher\n");
	fprintf(stderr, "  launcher                       Alias for menubar\n\n");

	fprintf(stderr, "EVENT SUBSCRIPTION:\n");
	fprintf(stderr, "  --subscribe [event_types...]   Subscribe to compositor events\n");
	fprintf(stderr, "    Event types: client_manage, client_unmanage, client_focus,\n");
	fprintf(stderr, "                 client_unfocus, client_title, client_urgent,\n");
	fprintf(stderr, "                 client_fullscreen, client_floating, client_minimized,\n");
	fprintf(stderr, "                 tag_switch, screen_add, screen_remove, all\n\n");

	fprintf(stderr, "Examples:\n");
	fprintf(stderr, "  %s tag view 2\n", progname);
	fprintf(stderr, "  %s client list\n", progname);
	fprintf(stderr, "  %s client floating focused true\n", progname);
	fprintf(stderr, "  %s client focus next\n", progname);
	fprintf(stderr, "  %s client info focused\n", progname);
	fprintf(stderr, "  %s client kill focused --force\n", progname);
	fprintf(stderr, "  %s client placement maximize focused\n", progname);
	fprintf(stderr, "  %s mouse coords 100 200\n", progname);
	fprintf(stderr, "  %s dpms off\n", progname);
	fprintf(stderr, "  %s theme get font\n", progname);
	fprintf(stderr, "  %s --json client list\n", progname);
	fprintf(stderr, "  %s --subscribe client_focus tag_switch\n", progname);
	fprintf(stderr, "  %s eval 'print(awesome.version)'\n", progname);
}

static int
connect_to_socket(void)
{
	struct sockaddr_un addr = {0};
	const char *runtime_dir;
	int sock;

	/* Get runtime directory */
	runtime_dir = getenv("XDG_RUNTIME_DIR");
	if (!runtime_dir) {
		fprintf(stderr, "Error: XDG_RUNTIME_DIR not set\n");
		return -1;
	}

	/* Create socket */
	sock = socket(AF_UNIX, SOCK_STREAM, 0);
	if (sock < 0) {
		perror("socket");
		return -1;
	}

	/* Build address - check for override first */
	addr.sun_family = AF_UNIX;
	const char *socket_override = getenv("SOMEWM_SOCKET");
	if (socket_override && socket_override[0]) {
		snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_override);
	} else {
		snprintf(addr.sun_path, sizeof(addr.sun_path),
		         "%s/%s", runtime_dir, SOCKET_NAME);
	}

	/* Connect */
	if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "Error: Failed to connect to %s\n", addr.sun_path);
		fprintf(stderr, "Is somewm running?\n");
		perror("connect");
		close(sock);
		return -1;
	}

	return sock;
}

static int
send_command(int sock, int argc, char *argv[], int json_mode, int start_arg)
{
	char command[BUFFER_SIZE];
	int offset = 0;
	int i;

	/* Prepend --json if requested */
	if (json_mode) {
		offset = snprintf(command, BUFFER_SIZE, "--json ");
	}

	/* Build command string from argv */
	for (i = start_arg; i < argc; i++) {
		if (offset > 0 && offset < BUFFER_SIZE - 1 && command[offset - 1] != ' ') {
			command[offset++] = ' ';
		}
		offset += snprintf(command + offset, BUFFER_SIZE - offset - 1,
		                   "%s", argv[i]);
		if (offset >= BUFFER_SIZE - 1) {
			fprintf(stderr, "Error: Command too long\n");
			return -1;
		}
	}

	/* Add newline */
	if (offset < BUFFER_SIZE - 1) {
		command[offset++] = '\n';
		command[offset] = '\0';
	}

	/* Send command */
	if (write(sock, command, offset) != offset) {
		perror("write");
		return -1;
	}

	return 0;
}

static int
read_response(int sock)
{
	char buffer[BUFFER_SIZE];
	ssize_t n;
	int found_end = 0;
	int is_error = 0;

	/* Read response until we see double newline */
	while (!found_end) {
		n = read(sock, buffer, sizeof(buffer) - 1);
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			perror("read");
			return -1;
		}

		if (n == 0) {
			/* Connection closed */
			break;
		}

		buffer[n] = '\0';

		/* Print response */
		printf("%s", buffer);

		/* Check for error status */
		if (strncmp(buffer, "ERROR", 5) == 0) {
			is_error = 1;
		}

		/* Check for end marker (double newline) */
		if (strstr(buffer, "\n\n")) {
			found_end = 1;
		}
	}

	return is_error ? 1 : 0;
}

/**
 * Subscribe mode: read initial response, then continuously read events
 * until the connection is closed or SIGINT is received.
 */
static int
subscribe_mode(int sock)
{
	char buffer[BUFFER_SIZE];
	ssize_t n;

	/* Set up signal handler for clean shutdown */
	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);

	/* Read initial response */
	int got_initial = 0;
	while (!got_initial && running) {
		n = read(sock, buffer, sizeof(buffer) - 1);
		if (n <= 0) {
			if (n < 0 && errno == EINTR)
				continue;
			break;
		}
		buffer[n] = '\0';

		/* Check if initial response is an error */
		if (strncmp(buffer, "ERROR", 5) == 0) {
			fprintf(stderr, "%s", buffer);
			return 1;
		}

		/* Check for end of initial response (double newline) */
		if (strstr(buffer, "\n\n")) {
			got_initial = 1;
			/* Print any event data that came after the initial response */
			char *after = strstr(buffer, "\n\n") + 2;
			if (*after) {
				printf("%s", after);
				fflush(stdout);
			}
		}
	}

	/* Continuously read and print events */
	while (running) {
		n = read(sock, buffer, sizeof(buffer) - 1);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (n == 0) {
			/* Server closed connection */
			break;
		}
		buffer[n] = '\0';
		printf("%s", buffer);
		fflush(stdout);
	}

	return 0;
}

/**
 * Output shell completion script
 */
static void
print_completions(const char *shell)
{
	if (strcmp(shell, "bash") == 0) {
		printf("_somewm_client() {\n");
		printf("  local cur prev commands\n");
		printf("  COMPREPLY=()\n");
		printf("  cur=\"${COMP_WORDS[COMP_CWORD]}\"\n");
		printf("  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n");
		printf("\n");
		printf("  # Top-level commands\n");
		printf("  local categories=\"client dpms eval exec hotkeys idle input keybind launcher layout lock menubar mouse notify output ping quit reload restart rule screen screenshot subscribe tag theme titlebar version wallpaper wibar\"\n");
		printf("\n");
		printf("  if [[ ${COMP_CWORD} -eq 1 ]]; then\n");
		printf("    COMPREPLY=( $(compgen -W \"${categories} --json --subscribe --help\" -- \"${cur}\") )\n");
		printf("    return 0\n");
		printf("  fi\n");
		printf("\n");
		printf("  case \"${COMP_WORDS[1]}\" in\n");
		printf("    tag)\n");
		printf("      COMPREPLY=( $(compgen -W \"view toggle current list add delete rename screen swap layout gap mwfact\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    client)\n");
		printf("      COMPREPLY=( $(compgen -W \"list kill close focus movetotag toggletag movetoscreen geometry move resize moveresize center placement floating fullscreen sticky ontop minimized maximized maximized_horizontal maximized_vertical hidden modal focusable urgent above below skip_taskbar opacity raise lower swap swapidx zoom visible tiled master info\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    screen)\n");
		printf("      COMPREPLY=( $(compgen -W \"list focused count clients scale focus\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    layout)\n");
		printf("      COMPREPLY=( $(compgen -W \"list get set next prev\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    keybind)\n");
		printf("      COMPREPLY=( $(compgen -W \"list add remove trigger\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    rule)\n");
		printf("      COMPREPLY=( $(compgen -W \"list add remove test\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    wibar)\n");
		printf("      COMPREPLY=( $(compgen -W \"list show hide toggle\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    screenshot)\n");
		printf("      COMPREPLY=( $(compgen -W \"save client screen\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    mouse)\n");
		printf("      COMPREPLY=( $(compgen -W \"coords screen\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    mousegrabber)\n");
		printf("      COMPREPLY=( $(compgen -W \"isrunning stop test track\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    titlebar)\n");
		printf("      COMPREPLY=( $(compgen -W \"show hide toggle\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    theme)\n");
		printf("      COMPREPLY=( $(compgen -W \"get set\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    wallpaper)\n");
		printf("      COMPREPLY=( $(compgen -W \"set color\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    output)\n");
		printf("      COMPREPLY=( $(compgen -W \"list\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    dpms)\n");
		printf("      COMPREPLY=( $(compgen -W \"on off status\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("    idle)\n");
		printf("      COMPREPLY=( $(compgen -W \"timeout status clear\" -- \"${cur}\") )\n");
		printf("      ;;\n");
		printf("  esac\n");
		printf("}\n");
		printf("complete -F _somewm_client somewm-client\n");
	} else if (strcmp(shell, "zsh") == 0) {
		printf("#compdef somewm-client\n\n");
		printf("_somewm_client() {\n");
		printf("  local -a categories\n");
		printf("  categories=(\n");
		printf("    'client:Client management'\n");
		printf("    'dpms:Display power management'\n");
		printf("    'eval:Execute Lua code'\n");
		printf("    'exec:Spawn a process'\n");
		printf("    'hotkeys:Show hotkeys popup'\n");
		printf("    'idle:Idle timeout management'\n");
		printf("    'input:Input settings'\n");
		printf("    'keybind:Keybinding management'\n");
		printf("    'launcher:Application launcher'\n");
		printf("    'layout:Layout management'\n");
		printf("    'lock:Lock session'\n");
		printf("    'menubar:Menubar launcher'\n");
		printf("    'mouse:Mouse/cursor control'\n");
		printf("    'notify:Send notification'\n");
		printf("    'output:Output/display management'\n");
		printf("    'ping:Test connection'\n");
		printf("    'quit:Exit compositor'\n");
		printf("    'reload:Reload configuration'\n");
		printf("    'restart:Restart compositor'\n");
		printf("    'rule:Client rules'\n");
		printf("    'screen:Screen management'\n");
		printf("    'screenshot:Screenshot capture'\n");
		printf("    'tag:Tag management'\n");
		printf("    'theme:Theme queries'\n");
		printf("    'titlebar:Titlebar management'\n");
		printf("    'version:Version info'\n");
		printf("    'wallpaper:Wallpaper management'\n");
		printf("    'wibar:Wibar management'\n");
		printf("  )\n\n");
		printf("  _arguments -C \\\n");
		printf("    '--json[Output in JSON format]' \\\n");
		printf("    '--subscribe[Subscribe to events]' \\\n");
		printf("    '--completions[Output completion script]:shell:(bash zsh fish)' \\\n");
		printf("    '--help[Show help]' \\\n");
		printf("    '1:command:->cmd' \\\n");
		printf("    '*::arg:->args'\n\n");
		printf("  case $state in\n");
		printf("    cmd)\n");
		printf("      _describe 'command' categories\n");
		printf("      ;;\n");
		printf("    args)\n");
		printf("      case ${words[1]} in\n");
		printf("        tag) _values 'subcommand' view toggle current list add delete rename screen swap layout gap mwfact ;;\n");
		printf("        client) _values 'subcommand' list kill close focus movetotag toggletag movetoscreen geometry move resize moveresize center placement floating fullscreen sticky ontop minimized maximized hidden modal focusable urgent above below skip_taskbar opacity raise lower swap swapidx zoom visible tiled master info ;;\n");
		printf("        screen) _values 'subcommand' list focused count clients scale focus ;;\n");
		printf("        layout) _values 'subcommand' list get set next prev ;;\n");
		printf("        keybind) _values 'subcommand' list add remove trigger ;;\n");
		printf("        rule) _values 'subcommand' list add remove test ;;\n");
		printf("        wibar) _values 'subcommand' list show hide toggle ;;\n");
		printf("        screenshot) _values 'subcommand' save client screen ;;\n");
		printf("        mouse) _values 'subcommand' coords screen ;;\n");
		printf("        titlebar) _values 'subcommand' show hide toggle ;;\n");
		printf("        theme) _values 'subcommand' get set ;;\n");
		printf("        wallpaper) _values 'subcommand' set color ;;\n");
		printf("        output) _values 'subcommand' list ;;\n");
		printf("        dpms) _values 'subcommand' on off status ;;\n");
		printf("        idle) _values 'subcommand' timeout status clear ;;\n");
		printf("      esac\n");
		printf("      ;;\n");
		printf("  esac\n");
		printf("}\n\n");
		printf("_somewm_client \"$@\"\n");
	} else if (strcmp(shell, "fish") == 0) {
		printf("# Fish completions for somewm-client\n\n");
		printf("set -l categories client dpms eval exec hotkeys idle input keybind launcher layout lock menubar mouse notify output ping quit reload restart rule screen screenshot tag theme titlebar version wallpaper wibar\n\n");
		printf("complete -c somewm-client -f\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -l json -d 'Output in JSON format'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -l subscribe -d 'Subscribe to events'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -l completions -d 'Output completion script'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -l help -d 'Show help'\n\n");
		printf("# Top-level commands\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'client' -d 'Client management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'dpms' -d 'Display power management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'eval' -d 'Execute Lua code'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'exec' -d 'Spawn a process'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'hotkeys' -d 'Show hotkeys popup'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'idle' -d 'Idle timeout management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'input' -d 'Input settings'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'keybind' -d 'Keybinding management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'launcher' -d 'Application launcher'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'layout' -d 'Layout management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'lock' -d 'Lock session'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'menubar' -d 'Menubar launcher'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'mouse' -d 'Mouse/cursor control'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'notify' -d 'Send notification'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'output' -d 'Output/display management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'ping' -d 'Test connection'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'quit' -d 'Exit compositor'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'reload' -d 'Reload configuration'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'restart' -d 'Restart compositor'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'rule' -d 'Client rules'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'screen' -d 'Screen management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'screenshot' -d 'Screenshot capture'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'tag' -d 'Tag management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'theme' -d 'Theme queries'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'titlebar' -d 'Titlebar management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'version' -d 'Version info'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'wallpaper' -d 'Wallpaper management'\n");
		printf("complete -c somewm-client -n '__fish_use_subcommand' -a 'wibar' -d 'Wibar management'\n\n");
		printf("# Tag subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from tag' -a 'view toggle current list add delete rename screen swap layout gap mwfact'\n");
		printf("# Client subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from client' -a 'list kill close focus movetotag toggletag movetoscreen geometry move resize moveresize center placement floating fullscreen sticky ontop minimized maximized hidden modal focusable urgent above below skip_taskbar opacity raise lower swap swapidx zoom visible tiled master info'\n");
		printf("# Screen subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from screen' -a 'list focused count clients scale focus'\n");
		printf("# Layout subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from layout' -a 'list get set next prev'\n");
		printf("# Keybind subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from keybind' -a 'list add remove trigger'\n");
		printf("# Rule subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from rule' -a 'list add remove test'\n");
		printf("# Wibar subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from wibar' -a 'list show hide toggle'\n");
		printf("# Screenshot subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from screenshot' -a 'save client screen'\n");
		printf("# Mouse subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from mouse' -a 'coords screen'\n");
		printf("# Titlebar subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from titlebar' -a 'show hide toggle'\n");
		printf("# Theme subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from theme' -a 'get set'\n");
		printf("# Wallpaper subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from wallpaper' -a 'set color'\n");
		printf("# Output subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from output' -a 'list'\n");
		printf("# DPMS subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from dpms' -a 'on off status'\n");
		printf("# Idle subcommands\n");
		printf("complete -c somewm-client -n '__fish_seen_subcommand_from idle' -a 'timeout status clear'\n");
	} else {
		fprintf(stderr, "Unknown shell: %s (supported: bash, zsh, fish)\n", shell);
	}
}

int
main(int argc, char *argv[])
{
	int sock;
	int exit_code;
	int json_mode = 0;
	int start_arg = 1;

	/* Check arguments */
	if (argc < 2) {
		print_usage(argv[0]);
		return 1;
	}

	/* Handle --help */
	if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
		print_usage(argv[0]);
		return 0;
	}

	/* Handle --completions */
	if (strcmp(argv[1], "--completions") == 0) {
		if (argc < 3) {
			fprintf(stderr, "Error: --completions requires a shell name (bash, zsh, fish)\n");
			return 1;
		}
		print_completions(argv[2]);
		return 0;
	}

	/* Handle --json flag */
	if (strcmp(argv[1], "--json") == 0) {
		json_mode = 1;
		start_arg = 2;
		if (argc < 3) {
			fprintf(stderr, "Error: --json requires a command\n");
			print_usage(argv[0]);
			return 1;
		}
	}

	/* Handle --subscribe mode */
	if (strcmp(argv[start_arg], "--subscribe") == 0 ||
	    (start_arg < argc && strcmp(argv[start_arg], "subscribe") == 0)) {
		sock = connect_to_socket();
		if (sock < 0)
			return 2;

		/* Build subscribe command with optional event type filters */
		char command[BUFFER_SIZE];
		int offset = 0;

		if (json_mode) {
			offset = snprintf(command, BUFFER_SIZE, "--json ");
		}

		offset += snprintf(command + offset, BUFFER_SIZE - offset, "subscribe");

		/* Add event type filters if provided */
		int filter_start = (strcmp(argv[start_arg], "--subscribe") == 0)
		                   ? start_arg + 1 : start_arg + 1;
		for (int i = filter_start; i < argc; i++) {
			offset += snprintf(command + offset, BUFFER_SIZE - offset,
			                   " %s", argv[i]);
		}

		offset += snprintf(command + offset, BUFFER_SIZE - offset, "\n");
		if (write(sock, command, offset) != offset) {
			perror("write");
			close(sock);
			return 1;
		}

		exit_code = subscribe_mode(sock);
		close(sock);
		return exit_code;
	}

	/* Connect to compositor */
	sock = connect_to_socket();
	if (sock < 0) {
		return 2;
	}

	/* Send command */
	if (send_command(sock, argc, argv, json_mode, start_arg) < 0) {
		close(sock);
		return 1;
	}

	/* Read and print response */
	exit_code = read_response(sock);

	close(sock);
	return exit_code;
}
