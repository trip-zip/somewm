/**
 * somewm-client - CLI tool for controlling somewm compositor
 *
 * Connects to the somewm IPC socket and sends commands.
 *
 * Usage:
 *   somewm-client tag view 2
 *   somewm-client client list
 *   somewm-client ping
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define BUFFER_SIZE 4096
#define SOCKET_NAME "somewm-socket"

static void
print_usage(const char *progname)
{
	fprintf(stderr, "Usage: %s [--json] COMMAND [ARGS...]\n\n", progname);
	fprintf(stderr, "OPTIONS:\n");
	fprintf(stderr, "  --json                         Output in JSON format\n\n");

	fprintf(stderr, "BASIC COMMANDS:\n");
	fprintf(stderr, "  ping                           Test connection\n");
	fprintf(stderr, "  exec <command...>              Spawn a process\n");
	fprintf(stderr, "  quit                           Exit compositor\n\n");

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
	fprintf(stderr, "  client kill <ID|focused>       Kill a client\n");
	fprintf(stderr, "  client close <ID|focused>      Close a client\n");
	fprintf(stderr, "  client focus <ID|next|prev>    Focus a client\n");
	fprintf(stderr, "  client movetotag <N> [ID]      Move client to tag N (clears other tags)\n");
	fprintf(stderr, "  client toggletag <N> [ID]      Toggle tag N on client\n\n");

	fprintf(stderr, "CLIENT GEOMETRY:\n");
	fprintf(stderr, "  client geometry <ID> [x y w h] Get or set client geometry\n");
	fprintf(stderr, "  client move <ID> <x> <y>       Move client to position\n");
	fprintf(stderr, "  client resize <ID> <w> <h>     Resize client\n");
	fprintf(stderr, "  client moveresize <ID> <dx> <dy> <dw> <dh>\n");
	fprintf(stderr, "                                 Move and resize relatively\n");
	fprintf(stderr, "  client center <ID|focused>     Center client on screen\n\n");

	fprintf(stderr, "CLIENT PROPERTIES:\n");
	fprintf(stderr, "  client floating <ID> [true|false]    Get or set floating state\n");
	fprintf(stderr, "  client fullscreen <ID> [true|false]  Get or set fullscreen state\n");
	fprintf(stderr, "  client sticky <ID> [true|false]      Get or set sticky state\n");
	fprintf(stderr, "  client ontop <ID> [true|false]       Get or set ontop state\n\n");

	fprintf(stderr, "CLIENT STACK OPERATIONS:\n");
	fprintf(stderr, "  client raise <ID|focused>      Raise client to top\n");
	fprintf(stderr, "  client lower <ID|focused>      Lower client to bottom\n");
	fprintf(stderr, "  client swap <ID1> <ID2>        Swap two clients\n");
	fprintf(stderr, "  client swapidx <±N> [ID]       Swap with Nth client in stack\n");
	fprintf(stderr, "  client zoom <ID|focused>       Swap client with master\n\n");

	fprintf(stderr, "CLIENT QUERIES:\n");
	fprintf(stderr, "  client visible                 List visible clients on current tags\n");
	fprintf(stderr, "  client tiled                   List tiled (non-floating) clients\n");
	fprintf(stderr, "  client master                  Get master client\n");
	fprintf(stderr, "  client info <ID|focused>       Get comprehensive client info\n\n");

	fprintf(stderr, "SCREEN COMMANDS:\n");
	fprintf(stderr, "  screen list                    List all screens/monitors\n");
	fprintf(stderr, "  screen focused                 Get focused screen info\n");
	fprintf(stderr, "  screen count                   Get number of screens\n");
	fprintf(stderr, "  screen clients <ID>            List clients on a screen\n\n");

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
	fprintf(stderr, "  reload                         Reload configuration (validates first)\n");
	fprintf(stderr, "  restart                        Full compositor restart\n\n");

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

	fprintf(stderr, "MULTI-MONITOR:\n");
	fprintf(stderr, "  screen focus <id|next|prev>    Focus a screen\n");
	fprintf(stderr, "  client movetoscreen <scr> [ID] Move client to screen\n\n");

	fprintf(stderr, "NOTIFICATIONS:\n");
	fprintf(stderr, "  notify <msg> [--title T] [--timeout N] [--urgency U]\n");
	fprintf(stderr, "                                 Send a notification\n\n");

	fprintf(stderr, "ADVANCED:\n");
	fprintf(stderr, "  eval <lua_code>                Execute arbitrary Lua code\n");
	fprintf(stderr, "  hotkeys                        Show hotkeys popup\n");
	fprintf(stderr, "  menubar                        Show menubar application launcher\n");
	fprintf(stderr, "  launcher                       Show application launcher (alias for menubar)\n\n");

	fprintf(stderr, "Examples:\n");
	fprintf(stderr, "  %s tag view 2\n", progname);
	fprintf(stderr, "  %s client list\n", progname);
	fprintf(stderr, "  %s client floating focused true\n", progname);
	fprintf(stderr, "  %s client center focused\n", progname);
	fprintf(stderr, "  %s client info focused\n", progname);
	fprintf(stderr, "  %s screen list\n", progname);
	fprintf(stderr, "  %s eval 'print(awesome.version)'\n", progname);
	fprintf(stderr, "  %s input tap_to_click 1\n", progname);
	fprintf(stderr, "  %s exec firefox\n", progname);
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

	/* Build address */
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path),
	         "%s/%s", runtime_dir, SOCKET_NAME);

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
