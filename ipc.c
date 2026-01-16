/**
 * ipc.c - Unix socket IPC for somewm
 *
 * Provides a command interface for external tools (like somewm-client)
 * to control the compositor. Uses a simple line-based text protocol:
 *
 * Request:  COMMAND [ARGS...]\n
 * Response: STATUS [MESSAGE]\n[DATA...]\n\n
 *
 * Example:
 *   → tag view 2\n
 *   ← OK\n\n
 */

#include "ipc.h"
#include "common/util.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-server-core.h>

#define IPC_SOCKET_NAME "somewm-socket"
#define IPC_MAX_CLIENTS 10
#define IPC_BUFFER_SIZE 4096

/** Connected IPC client */
struct ipc_client {
	int fd;
	struct wl_event_source *event_source;
	char *buffer;
	size_t buffer_size;
	size_t buffer_used;
	struct wl_list link;
};

/* Forward declarations */
static int ipc_handle_connection(int fd, uint32_t mask, void *data);
static int ipc_handle_client_data(int fd, uint32_t mask, void *data);
static void ipc_client_destroy(struct ipc_client *client);
static void ipc_process_command(struct ipc_client *client, const char *command);

/* Global state */
static int ipc_socket_fd = -1;
static struct wl_event_source *ipc_event_source = NULL;
static struct wl_event_loop *ipc_event_loop = NULL;
static struct wl_list ipc_clients;
static char ipc_socket_path[256];

const char *
ipc_get_socket_path(void)
{
	return ipc_socket_path;
}

int
ipc_init(struct wl_event_loop *event_loop)
{
	struct sockaddr_un addr = {0};
	const char *runtime_dir;

	/* Store event loop for later use */
	ipc_event_loop = event_loop;

	/* Initialize client list */
	wl_list_init(&ipc_clients);

	/* Get runtime directory */
	runtime_dir = getenv("XDG_RUNTIME_DIR");
	if (!runtime_dir) {
		fprintf(stderr, "IPC: XDG_RUNTIME_DIR not set\n");
		return -1;
	}

	/* Build socket path - check for override first */
	const char *socket_override = getenv("SOMEWM_SOCKET");
	if (socket_override && socket_override[0]) {
		snprintf(ipc_socket_path, sizeof(ipc_socket_path), "%s", socket_override);
	} else {
		snprintf(ipc_socket_path, sizeof(ipc_socket_path),
		         "%s/%s", runtime_dir, IPC_SOCKET_NAME);
	}

	/* Create socket */
	ipc_socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (ipc_socket_fd < 0) {
		fprintf(stderr, "IPC: Failed to create socket: %s\n", strerror(errno));
		return -1;
	}

	/* Remove stale socket file if it exists */
	unlink(ipc_socket_path);

	/* Bind to path */
	addr.sun_family = AF_UNIX;
	size_t path_len = strlen(ipc_socket_path);
	if (path_len >= sizeof(addr.sun_path)) {
		fprintf(stderr, "IPC: Socket path too long (%zu >= %zu)\n",
		        path_len, sizeof(addr.sun_path));
		close(ipc_socket_fd);
		ipc_socket_fd = -1;
		return -1;
	}
	memcpy(addr.sun_path, ipc_socket_path, path_len + 1);

	if (bind(ipc_socket_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "IPC: Failed to bind socket to %s: %s\n",
		        ipc_socket_path, strerror(errno));
		close(ipc_socket_fd);
		ipc_socket_fd = -1;
		return -1;
	}

	/* Listen for connections */
	if (listen(ipc_socket_fd, IPC_MAX_CLIENTS) < 0) {
		fprintf(stderr, "IPC: Failed to listen on socket: %s\n", strerror(errno));
		close(ipc_socket_fd);
		unlink(ipc_socket_path);
		ipc_socket_fd = -1;
		return -1;
	}

	/* Add to event loop */
	ipc_event_source = wl_event_loop_add_fd(
	    event_loop,
	    ipc_socket_fd,
	    WL_EVENT_READABLE,
	    ipc_handle_connection,
	    NULL);

	if (!ipc_event_source) {
		fprintf(stderr, "IPC: Failed to add socket to event loop\n");
		close(ipc_socket_fd);
		unlink(ipc_socket_path);
		ipc_socket_fd = -1;
		return -1;
	}

	log_info("IPC listening on %s", ipc_socket_path);
	return 0;
}

void
ipc_cleanup(void)
{
	struct ipc_client *client, *tmp;

	/* Destroy all clients */
	wl_list_for_each_safe(client, tmp, &ipc_clients, link) {
		ipc_client_destroy(client);
	}

	/* Remove event source */
	if (ipc_event_source) {
		wl_event_source_remove(ipc_event_source);
		ipc_event_source = NULL;
	}

	/* Close listening socket */
	if (ipc_socket_fd >= 0) {
		close(ipc_socket_fd);
		ipc_socket_fd = -1;
	}

	/* Remove socket file */
	if (ipc_socket_path[0]) {
		unlink(ipc_socket_path);
		ipc_socket_path[0] = '\0';
	}
}

static int
ipc_handle_connection(int fd, uint32_t mask, void *data)
{
	struct ipc_client *client;
	struct sockaddr_un client_addr;
	socklen_t client_len = sizeof(client_addr);
	int client_fd;
	int count = 0;

	/* Count current clients */
	wl_list_for_each(client, &ipc_clients, link) {
		count++;
	}

	/* Check client limit */
	if (count >= IPC_MAX_CLIENTS) {
		/* Accept and immediately close to prevent connection queue buildup */
		client_fd = accept(fd, (struct sockaddr *)&client_addr, &client_len);
		if (client_fd >= 0) {
			const char *msg = "ERROR Too many clients\n\n";
			(void)!write(client_fd, msg, strlen(msg));
			close(client_fd);
		}
		return 0;
	}

	/* Accept connection */
	client_fd = accept(fd, (struct sockaddr *)&client_addr, &client_len);
	if (client_fd < 0) {
		if (errno != EINTR && errno != EAGAIN) {
			fprintf(stderr, "IPC: Failed to accept connection: %s\n",
			        strerror(errno));
		}
		return 0;
	}

	/* Create client structure */
	client = ecalloc(1, sizeof(*client));
	client->fd = client_fd;
	client->buffer_size = IPC_BUFFER_SIZE;
	client->buffer = ecalloc(1, client->buffer_size);
	client->buffer_used = 0;

	/* Add to event loop */
	client->event_source = wl_event_loop_add_fd(
	    ipc_event_loop,
	    client_fd,
	    WL_EVENT_READABLE,
	    ipc_handle_client_data,
	    client);

	if (!client->event_source) {
		fprintf(stderr, "IPC: Failed to add client to event loop\n");
		free(client->buffer);
		free(client);
		close(client_fd);
		return 0;
	}

	/* Add to client list */
	wl_list_insert(&ipc_clients, &client->link);

	return 0;
}

static int
ipc_handle_client_data(int fd, uint32_t mask, void *data)
{
	struct ipc_client *client = data;
	char *newline;
	ssize_t n;

	/* Read data */
	n = read(client->fd, client->buffer + client->buffer_used,
	         client->buffer_size - client->buffer_used - 1);

	if (n <= 0) {
		/* Connection closed or error */
		if (n < 0 && errno != EINTR && errno != EAGAIN) {
			fprintf(stderr, "IPC: Client read error: %s\n", strerror(errno));
		}
		ipc_client_destroy(client);
		return 0;
	}

	client->buffer_used += n;
	client->buffer[client->buffer_used] = '\0';

	/* Process complete commands (lines ending with \n) */
	while ((newline = strchr(client->buffer, '\n')) != NULL) {
		size_t command_len = newline - client->buffer;
		char *command;

		/* Extract command */
		command = ecalloc(1, command_len + 1);
		memcpy(command, client->buffer, command_len);
		command[command_len] = '\0';

		/* Process it */
		if (command_len > 0) {
			ipc_process_command(client, command);
		}
		free(command);

		/* Remove processed command from buffer */
		client->buffer_used -= (command_len + 1);
		memmove(client->buffer, newline + 1, client->buffer_used + 1);
	}

	/* Check for buffer overflow */
	if (client->buffer_used >= client->buffer_size - 1) {
		const char *msg = "ERROR Command too long\n\n";
		(void)!write(client->fd, msg, strlen(msg));
		ipc_client_destroy(client);
		return 0;
	}

	return 0;
}

static void
ipc_client_destroy(struct ipc_client *client)
{
	if (client->event_source) {
		wl_event_source_remove(client->event_source);
	}

	if (client->fd >= 0) {
		close(client->fd);
	}

	wl_list_remove(&client->link);
	free(client->buffer);
	free(client);
}

/**
 * Send response to IPC client
 * Format: STATUS MESSAGE\n[DATA]\n\n
 */
void
ipc_send_response(int client_fd, const char *response)
{
	if (client_fd >= 0 && response) {
		(void)!write(client_fd, response, strlen(response));
		/* Ensure response ends with double newline */
		if (!strstr(response + strlen(response) - 2, "\n\n")) {
			(void)!write(client_fd, "\n", 1);
		}
	}
}

/**
 * Process IPC command
 * This is where we bridge to Lua - for now, just echo back
 */
static void
ipc_process_command(struct ipc_client *client, const char *command)
{
	extern void ipc_dispatch_to_lua(int client_fd, const char *command);

	/* Dispatch to Lua layer */
	ipc_dispatch_to_lua(client->fd, command);
}
